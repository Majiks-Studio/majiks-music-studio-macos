import Foundation
import SwiftUI

@MainActor
final class BackendViewModel: ObservableObject {
    @Published var statusMessage: String = "Starting backend..."
    @Published var lastReply: String = ""
    @Published var isThinking: Bool = false
    @Published var isConnected: Bool = false
    @Published var generationProgress: Double = 0
    @Published var generationStage: String = ""
    @Published var generationMessage: String = ""
    /// Partial chat response streamed token-by-token from the backend.
    /// Updated via ``chat_partial`` progress notifications during MLX inference.
    @Published var partialReply: String = ""
    private var client: JSONRPCClient?
    private var lastEnvironment: [String: String] = [:]

    // MARK: - Auto-Restart State
    private var intentionalShutdown = false
    private var restartCount = 0
    private let maxRestarts = 3
    private var lastRestartTime: Date?
    private var restartStabilityTimer: Task<Void, Never>?

    func start(apiKey: String?, model: String?) {
        var environment: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty {
            environment["OPENROUTER_API_KEY"] = apiKey
        }
        if let model, !model.isEmpty {
            environment["OPENROUTER_MODEL"] = model
        }
        start(environment: environment)
    }

    func start(environment: [String: String] = [:]) {
        lastEnvironment = environment
        intentionalShutdown = false

        // Python module validation (pythonSupportsRequiredModules) spawns a
        // subprocess and calls waitUntilExit(), which blocks the calling
        // thread. Wrap the entire boot sequence in a Task so the main thread
        // can return to the run loop and the window paints immediately.
        Task { @MainActor in
            await self._startAsync(environment: environment)
        }
    }

    private func _startAsync(environment: [String: String]) async {
        do {
            let pythonPath = try resolvePythonExecutable()

            // Resolve Python package directory (production bundle first, then local dev paths)
            let projectDir = try resolvePythonProjectDirectory()

            // Run as Python module instead of script to fix relative imports
            let scriptPath = "-m"
            let moduleName = "majik_backend.rpc_server"

            // Add project directory to PYTHONPATH
            var env = environment
            if let existingPath = ProcessInfo.processInfo.environment["PYTHONPATH"] {
                env["PYTHONPATH"] = "\(projectDir):\(existingPath)"
            } else {
                env["PYTHONPATH"] = projectDir
            }

            // Never let Python write .pyc into the signed app bundle — runtime bytecode
            // invalidates the code-signature seal (Gatekeeper rejects on later launches).
            env["PYTHONDONTWRITEBYTECODE"] = "1"

            // Enable CPU fallback for MPS ops exceeding hardware limits (e.g. >65536 channels)
            env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

            // Add bundled ffmpeg path if available
            if let resourcesPath = Bundle.main.resourceURL?.path,
               FileManager.default.fileExists(atPath: "\(resourcesPath)/bin/ffmpeg") {
                env["MAJIK_FFMPEG_PATH"] = "\(resourcesPath)/bin/ffmpeg"
            }

            // Add bundled ACE-Step paths if available
            if let resourcesPath = Bundle.main.resourceURL?.path {
                let aceStepPath = "\(resourcesPath)/ACE-Step"
                let checkpointsPath = "\(aceStepPath)/checkpoints"

                if FileManager.default.fileExists(atPath: aceStepPath) {
                    env["ACE_STEP_ROOT"] = aceStepPath
                    print("✅ Found bundled ACE-Step at: \(aceStepPath)")
                }

                if FileManager.default.fileExists(atPath: checkpointsPath) {
                    env["ACE_STEP_CHECKPOINT_DIR"] = checkpointsPath
                    print("✅ Found bundled ACE-Step checkpoints at: \(checkpointsPath)")
                }
            }

            let client = try JSONRPCClient(
                pythonPath: pythonPath,
                scriptPath: scriptPath,
                moduleName: moduleName,
                environment: env
            )
            try client.start()
            self.client = client
            isConnected = true
            AppLog.info("Backend Python executable: \(pythonPath)")

            // Set up progress handler to consume progress notifications
            client.progressHandler = { [weak self] progress in
                Task { @MainActor in
                    guard let self = self else { return }

                    // Route streaming chat text to partialReply for progressive display
                    if progress.stage == "chat_partial" {
                        self.partialReply = progress.message
                        return
                    }

                    // Route download progress to DownloadManager
                    if progress.stage == "download" || progress.stage == "loading" {
                        let progressMessage = String(format: "%@ (%d%%)", progress.message, Int(progress.percent))

                        // Check if this is an MLX download (message will contain model name)
                        if progress.message.contains("Downloading") || progress.message.contains("Loading") {
                            DownloadManager.shared.updateMLXProgress(progressMessage)
                        }
                    }

                    // Always update generation progress too (for music generation)
                    self.generationProgress = progress.percent
                    self.generationStage = progress.stage
                    self.generationMessage = progress.message
                }
            }

            // Set up auto-restart on unexpected termination
            client.terminationHandler = { [weak self] exitCode in
                Task { @MainActor [weak self] in
                    self?.handleUnexpectedTermination(exitCode: exitCode)
                }
            }

            // Reset restart count after 60 seconds of stable operation
            restartStabilityTimer?.cancel()
            restartStabilityTimer = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                guard !Task.isCancelled else { return }
                self.restartCount = 0
            }

            statusMessage = "Backend running (majik_backend)"
        } catch {
            isConnected = false
            statusMessage = "Backend failed to start: \(error.localizedDescription)"
        }
    }

    private func resolvePythonProjectDirectory() throws -> String {
        let fileManager = FileManager.default
        let marker = "majik_backend/rpc_server.py"

        if let override = ProcessInfo.processInfo.environment["MAJIK_PYTHON_PROJECT_DIR"],
           !override.isEmpty {
            let candidate = URL(fileURLWithPath: override, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(marker).path) {
                return candidate.path
            }
        }

        if let resourcePath = Bundle.main.resourceURL?.appendingPathComponent("python", isDirectory: true),
           fileManager.fileExists(atPath: resourcePath.appendingPathComponent(marker).path) {
            return resourcePath.path
        }

        let cwd = fileManager.currentDirectoryPath
        let devCandidates = [
            URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent("../python", isDirectory: true),
            URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent("src/python", isDirectory: true),
            URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent("../../src/python", isDirectory: true)
        ]
        for candidate in devCandidates {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(marker).path) {
                return candidate.standardized.path
            }
        }

        throw NSError(
            domain: "BackendViewModel",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate bundled Python backend at Resources/python."]
        )
    }

    private func resolvePythonExecutable() throws -> String {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let isBundledApp = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        let allowSystemFallbackInBundle = env["MAJIK_ALLOW_SYSTEM_PYTHON"] == "1"
        let requiredModules = ["librosa", "mlx_lm"]

        var candidates: [(path: String, source: String)] = []

        if let override = env["MAJIK_PYTHON"], !override.isEmpty {
            candidates.append((override, "MAJIK_PYTHON"))
        }
        if let override = env["ACE_STEP_PYTHON"], !override.isEmpty {
            candidates.append((override, "ACE_STEP_PYTHON"))
        }

        let aceRoots = [
            homeDir.appendingPathComponent("ACE-Step-1.5"),
            homeDir.appendingPathComponent("ACE-Step"),
            homeDir.appendingPathComponent("Projects/ACE-Step-1.5"),
            homeDir.appendingPathComponent("Developer/ACE-Step-1.5")
        ]
        for root in aceRoots {
            candidates.append((root.appendingPathComponent(".venv/bin/python").path, "ACE-Step venv"))
        }

        // Bundled Python.framework (standalone, no venv needed)
        let bundledFrameworkPython = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.12/bin/python3.12")
            .path

        // In bundled app builds, strongly prefer the bundled framework first.
        if !bundledFrameworkPython.isEmpty {
            candidates.insert((bundledFrameworkPython, "bundled framework"), at: 0)
        }

        // ⚠️ A FALLBACK TO A PATH THAT EXISTS ONLY ON THE DEVELOPER'S MACHINE IS
        // WORSE THAN NO FALLBACK. /opt/homebrew/bin/python3 is present on this
        // Mac and on no customer's, so as a shipped fallback it does not make
        // anything work — it converts a loud, immediate failure here into a
        // silent one there, and the log line "Selected Python from homebrew"
        // makes the dev box look healthy while every install is dead.
        //
        // So outside a .app these stay (a source checkout legitimately runs on
        // whatever interpreter the developer has); inside a .app the bundled
        // framework is the only correct answer, and if it cannot run we say so
        // rather than reaching onto a disk we do not have.
        //
        // ⚠️ The `!isBundledApp` runtime guard alone is NOT enough, and this was
        // measured, not assumed: a release build still carried the two literals
        //     /opt/homebrew/bin/python3
        //     /opt/homebrew/bin/huggingface-cli
        // in its string table, because the compiler emits a literal whether or
        // not its branch runs. So the shipped binary still ADVERTISED a
        // dependency on the developer's Homebrew, and the build gate — which
        // reads the string table, since a spawn path is not a load command —
        // correctly refused it. #if DEBUG is what actually keeps the path out
        // of the artifact. The runtime guard stays as the second lock for debug
        // builds run from a .app.
        #if DEBUG
        if !isBundledApp {
            candidates.append(("/opt/homebrew/bin/python3", "homebrew"))
            candidates.append(("/usr/local/bin/python3", "usr-local"))
            candidates.append(("/usr/bin/python3", "system"))
        }
        #endif

        var seen = Set<String>()
        let orderedCandidates = candidates.filter { candidate in
            if seen.contains(candidate.path) {
                return false
            }
            seen.insert(candidate.path)
            return true
        }

        var executableCandidates: [String] = []
        for candidate in orderedCandidates {
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            guard fileManager.isExecutableFile(atPath: candidate.path) else {
                AppLog.info("Python candidate is not executable: \(candidate.path)")
                continue
            }

            executableCandidates.append(candidate.path)
            let probe = probePython(atPath: candidate.path, modules: requiredModules)
            if case .ok = probe {
                AppLog.info("Selected Python from \(candidate.source): \(candidate.path)")
                return candidate.path
            }
            AppLog.error("Rejected Python at \(candidate.path): \(probe.diagnostic)")

            if isBundledApp,
               candidate.source == "bundled framework",
               !allowSystemFallbackInBundle {
                // Say what actually happened. The old text asserted "missing
                // librosa, mlx_lm" for EVERY failure — including the one that
                // shipped, where the interpreter could not be loaded at all
                // because it linked an absolute Homebrew Cellar path. A wrong
                // diagnosis costs more than no diagnosis.
                throw NSError(
                    domain: "BackendViewModel",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The bundled Python runtime is unusable. \(probe.diagnostic) "
                            + "Set MAJIK_ALLOW_SYSTEM_PYTHON=1 to allow a system-Python fallback for debugging."
                    ]
                )
            }
        }

        if isBundledApp && !allowSystemFallbackInBundle {
            throw NSError(
                domain: "BackendViewModel",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No valid bundled Python runtime found. Refusing system Python fallback in app bundle mode."
                ]
            )
        }

        if let fallback = executableCandidates.first {
            AppLog.error("No Python candidate contained required modules. Falling back to: \(fallback)")
            return fallback
        }

        throw NSError(
            domain: "BackendViewModel",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "No usable Python executable found. The bundled Python framework may be corrupted. Try reinstalling the app."
            ]
        )
    }

    /// Why an interpreter was rejected. "Could not be launched at all" and
    /// "launched fine but has no librosa" are different faults with different
    /// fixes, and reporting the second when it was the first is what made the
    /// Homebrew-dependency bug look like a packaging-of-wheels problem.
    enum PythonProbeResult {
        case ok
        case missingModules([String])
        case unusable(String)

        var diagnostic: String {
            switch self {
            case .ok:
                return "usable"
            case .missingModules(let mods):
                return "Missing required module(s): \(mods.joined(separator: ", "))."
            case .unusable(let reason):
                return "The interpreter could not be run: \(reason)"
            }
        }
    }

    private func probePython(atPath pythonPath: String, modules: [String]) -> PythonProbeResult {
        guard
            let json = try? JSONSerialization.data(withJSONObject: modules, options: []),
            let moduleList = String(data: json, encoding: .utf8)
        else {
            return .unusable("could not encode the module list to probe for.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        // Print the missing names rather than only signalling with an exit code,
        // so the caller can report which module is absent instead of guessing.
        process.arguments = [
            "-c",
            "import importlib.util as u,sys; mods=\(moduleList); missing=[m for m in mods if u.find_spec(m) is None]; sys.stdout.write(','.join(missing)); raise SystemExit(0 if not missing else 1)"
        ]
        // Probing the bundled interpreter must not write .pyc into the signed
        // bundle — a runtime write here invalidates the code-signature seal.
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus == 0 { return .ok }

            // A dyld failure or a code-signature kill is NOT a missing module.
            // dyld exits 133/SIGABRT-ish and prints "Library not loaded:"; an
            // invalid signature is SIGKILL (9). Either way the interpreter
            // never got as far as importing anything.
            if process.terminationReason == .uncaughtSignal {
                return .unusable("it was killed by a signal (status \(process.terminationStatus)). "
                                 + (text.isEmpty ? "" : text))
            }
            if text.contains("Library not loaded") || text.contains("image not found")
                || text.contains("dyld") {
                return .unusable(text)
            }
            if !text.isEmpty, !text.contains(" ") {
                return .missingModules(text.split(separator: ",").map(String.init))
            }
            return .unusable("exit status \(process.terminationStatus). \(text)")
        } catch {
            AppLog.error("Failed to validate Python modules for \(pythonPath): \(error.localizedDescription)")
            return .unusable(error.localizedDescription)
        }
    }

    func stop() {
        intentionalShutdown = true
        restartStabilityTimer?.cancel()
        client?.stop()
        client = nil
        isConnected = false
        statusMessage = "Backend stopped"
    }

    /// Reset the crash counter so intentional restarts aren't blocked by previous crashes.
    func resetRestartCount() {
        restartCount = 0
    }

    private func handleUnexpectedTermination(exitCode: Int32) {
        // Ignore if this was an intentional shutdown (stop() or restart flow)
        guard !intentionalShutdown else { return }

        AppLog.error("Backend process terminated unexpectedly (exit code \(exitCode)), attempting restart...")

        // Clean up stale client state
        client = nil
        isConnected = false

        // Check if we've exceeded restart limit
        guard restartCount < maxRestarts else {
            statusMessage = "Backend crashed repeatedly"
            ToastManager.shared.show("Backend crashed repeatedly. Please restart the app.", style: .error)
            return
        }

        // Rate-limit restarts: minimum 5 seconds between attempts
        if let lastRestart = lastRestartTime, Date().timeIntervalSince(lastRestart) < 5.0 {
            let delay = 5.0 - Date().timeIntervalSince(lastRestart)
            statusMessage = "Backend crashed — restarting in \(Int(delay))s..."
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self.performAutoRestart()
            }
        } else {
            performAutoRestart()
        }
    }

    private func performAutoRestart() {
        guard restartCount < maxRestarts else {
            statusMessage = "Backend crashed repeatedly"
            ToastManager.shared.show("Backend crashed repeatedly. Please restart the app.", style: .error)
            return
        }

        restartCount += 1
        lastRestartTime = Date()
        statusMessage = "Backend crashed — restarting (attempt \(restartCount)/\(maxRestarts))..."
        ToastManager.shared.show("Backend crashed — restarting (attempt \(restartCount)/\(maxRestarts))...", style: .warning)
        start(environment: lastEnvironment)
    }

    func restart(apiKey: String?, model: String?) {
        stop()
        statusMessage = "Restarting backend..."
        start(apiKey: apiKey, model: model)
    }

    /// Restart the backend process to reclaim leaked MPS/GPU memory before generation.
    /// The OS reclaims all memory when the process exits, giving ACE-Step a clean slate.
    func restartForGeneration() async {
        AppLog.info("Restarting backend for clean memory before generation...")
        // Reset crash counter so previous crashes don't prevent this restart
        restartCount = 0
        stop()
        // Brief pause for clean shutdown
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        start(environment: lastEnvironment)
        // Wait for backend to be ready (poll with timeout)
        let deadline = Date().addingTimeInterval(10)
        while !isConnected && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s
        }
        if isConnected {
            AppLog.info("Backend restarted successfully, ready for generation")
        } else {
            AppLog.error("Backend restart timed out after 10s — proceeding anyway")
        }
    }

    /// Send a cancel_generation RPC to abort any in-progress generation on the Python backend.
    func cancelGeneration() async {
        guard let client else { return }
        _ = try? await client.send(method: "cancel_generation", timeout: 5)
    }

    func ping() async {
        guard let client else {
            statusMessage = "Backend not available"
            return
        }
        do {
            let response = try await client.send(method: "ping")
            statusMessage = "Ping ok: \(response.result?.description ?? "unknown")"
        } catch {
            statusMessage = "Ping failed: \(error.localizedDescription)"
        }
    }

    func sendChat(_ message: String) async {
        guard let client else {
            statusMessage = "Backend not available"
            return
        }
        isThinking = true
        defer { isThinking = false }

        do {
            let params: JSONValue = .object([
                "message": .string(message)
            ])
            // Longer timeout for tool calling (music generation takes 2-5 minutes)
            let response = try await client.send(method: "ask_majik", params: params, timeout: 300)
            if case .object(let object)? = response.result,
               case .string(let text)? = object["text"] {
                lastReply = text
            } else {
                lastReply = "No response text"
            }
        } catch {
            lastReply = "Chat failed: \(error.localizedDescription)"
        }
    }

    func sendChatWithHistory(
        _ message: String,
        history: [[String: String]],
        agentConfig: JSONValue? = nil,
        allowAutoGeneration: Bool = false,
        advancedOverrides: LLMAdvancedChatOverrides? = nil
    ) async {
        guard let client else {
            statusMessage = "Backend not available"
            return
        }
        isThinking = true
        partialReply = ""
        defer {
            isThinking = false
            partialReply = ""
        }

        do {
            var paramObject: [String: JSONValue] = [
                "message": .string(message),
                "history": .array(history.map { dict in
                    .object(dict.mapValues { .string($0) })
                }),
                "allow_auto_generation": .bool(allowAutoGeneration)
            ]
            if let agentConfig {
                paramObject["agent_config"] = agentConfig
            }
            if let customSystemPrompt = advancedOverrides?.customSystemPrompt {
                paramObject["custom_system_prompt"] = .string(customSystemPrompt)
            }
            if let temperature = advancedOverrides?.temperatureOverride {
                paramObject["temperature_override"] = .number(temperature)
            }
            if let maxTokens = advancedOverrides?.maxTokensOverride {
                paramObject["max_tokens_override"] = .number(Double(maxTokens))
            }
            if let topP = advancedOverrides?.topPOverride {
                paramObject["top_p_override"] = .number(topP)
            }
            let params: JSONValue = .object(paramObject)
            // Longer timeout for tool calling (music generation takes 2-5 minutes)
            let response = try await client.send(method: "ask_majik", params: params, timeout: 300)

            AppLog.debug("Received response: \(debugString(for: response.result))")

            if case .object(let object)? = response.result {
                // Extract text response
                var replyText = ""
                if case .string(let text)? = object["text"] {
                    replyText = text
                } else {
                    AppLog.error("No text field in response, keys: \(object.keys)")
                    replyText = "Received response but no text field"
                }

                // Check if tools were executed
                if case .array(let toolCalls)? = object["tool_calls"], !toolCalls.isEmpty {
                    AppLog.debug("Tool calls detected in response: \(toolCalls.count)")

                    // Add tool execution info to reply
                    replyText += "\n\n✨ Tool Execution:\n"
                    for toolCall in toolCalls {
                        if case .object(let tc) = toolCall,
                           case .string(let toolName)? = tc["tool_name"],
                           case .object(let result)? = tc["result"] {

                            AppLog.debug("Tool executed: \(toolName)")

                            // Format tool result for display
                            if case .bool(let success)? = result["success"], success {
                                if case .string(let trackId)? = result["track_id"] {
                                    replyText += "✓ Generated music (ID: \(trackId))\n"
                                } else {
                                    replyText += "✓ \(toolName) completed successfully\n"
                                }

                                // Add variant count if present
                                if case .number(let count)? = result["variant_count"] {
                                    replyText += "  Created \(Int(count)) variant(s)\n"
                                }
                            } else {
                                replyText += "✗ \(toolName) failed\n"
                                if case .string(let error)? = result["error"] {
                                    replyText += "  Error: \(error)\n"
                                }
                            }
                        }
                    }
                }

                lastReply = replyText.isEmpty ? "No response text" : replyText
            } else {
                AppLog.error("Response result is not an object: \(debugString(for: response.result))")
                lastReply = "Invalid response format"
            }
        } catch {
            AppLog.error("Chat RPC failed: \(error)")
            lastReply = "Chat failed: \(error.localizedDescription)"
        }
    }

    private func debugString(for value: JSONValue?) -> String {
        guard let value else { return "nil" }
        do {
            let data = try JSONEncoder().encode(value)
            return String(data: data, encoding: .utf8) ?? String(describing: value)
        } catch {
            return String(describing: value)
        }
    }
    // MARK: - Parameter Extraction

    struct MusicParameters: Equatable {
        var caption: String = ""
        var duration: Int = 90
        var variantCount: Int = 1
        var bpm: Int?
        var key: String?
        var lyrics: String?
    }

    func extractMusicParameters(from history: [[String: String]]) async throws -> MusicParameters {
        guard let client else {
            throw RPCClientError.processNotRunning
        }

        let params: JSONValue = .object([
            "history": .array(history.map { dict in
                .object(dict.mapValues { .string($0) })
            })
        ])

        // Longer timeout for LLM parameter extraction (can take time if provider is slow)
        let response = try await client.send(method: "extract_music_parameters", params: params, timeout: 120)

        guard case .object(let result)? = response.result,
              case .object(let parameters)? = result["parameters"] else {
            throw RPCClientError.invalidResponse
        }

        var musicParams = MusicParameters()

        if case .string(let caption)? = parameters["caption"] {
            musicParams.caption = caption
        }
        if case .number(let duration)? = parameters["duration"] {
            musicParams.duration = Int(duration)
        }
        // count from extraction is ignored — variantCount is controlled by the Swift UI
        if case .number(let bpm)? = parameters["bpm"] {
            musicParams.bpm = Int(bpm)
        }
        if case .string(let key)? = parameters["key"] {
            musicParams.key = key
        }
        if case .string(let lyrics)? = parameters["lyrics"] {
            musicParams.lyrics = lyrics
        }

        return musicParams
    }

    /// Analyze an existing audio file with The Engineer to extract BPM, key, duration, genre, and lyrics.
    /// This bypasses the chat flow entirely — sends the file path directly to the backend.
    func analyzeAudioFile(path: String, caption: String = "", title: String = "") async throws -> MusicParameters {
        guard let client else {
            throw RPCClientError.processNotRunning
        }

        var paramsDict: [String: JSONValue] = [
            "file_path": .string(path)
        ]
        if !caption.isEmpty {
            paramsDict["caption"] = .string(caption)
        }
        if !title.isEmpty {
            paramsDict["title"] = .string(title)
        }
        let params: JSONValue = .object(paramsDict)

        // Audio analysis + optional LLM extraction can take time
        let response = try await client.send(method: "analyze_audio_file", params: params, timeout: 120)

        guard case .object(let result)? = response.result,
              case .object(let parameters)? = result["parameters"] else {
            throw RPCClientError.invalidResponse
        }

        var musicParams = MusicParameters()

        if case .string(let caption)? = parameters["caption"] {
            musicParams.caption = caption
        }
        if case .number(let duration)? = parameters["duration"] {
            musicParams.duration = Int(duration)
        }
        if case .number(let bpm)? = parameters["bpm"] {
            musicParams.bpm = Int(bpm)
        }
        if case .string(let key)? = parameters["key"] {
            musicParams.key = key
        }
        if case .string(let lyrics)? = parameters["lyrics"] {
            musicParams.lyrics = lyrics
        }

        return musicParams
    }

    func enhanceCaption(_ caption: String) async throws -> String {
        guard let client else {
            throw RPCClientError.processNotRunning
        }

        let params: JSONValue = .object(["caption": .string(caption)])

        // Timeout for LLM caption enhancement
        let response = try await client.send(method: "enhance_caption", params: params, timeout: 60)

        guard case .object(let result)? = response.result,
              case .string(let enhanced)? = result["enhanced_caption"] else {
            throw RPCClientError.invalidResponse
        }

        return enhanced
    }

    // MARK: - Music Generation

    func generateMusic(
        caption: String,
        duration: Int,
        count: Int = 1,
        model: String = "acestep-v15-turbo",
        lmModel: String = LMModel.defaultRawValueForCurrentMac,
        guidanceScale: Double = 4.5,
        bpm: Int? = nil,
        key: String? = nil,
        lyrics: String? = nil,
        outputDir: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        mood: String? = nil,
        seed: Int? = nil,
        numInferenceSteps: Int = 8,
        lmTemperature: Double = 0.9,
        lmCfgScale: Double = 2.5,
        timeSignature: String = "4",
        vocalLanguage: String = "",
        // ACE-Step v1.5 advanced diffusion parameters
        shift: Double = 3.0,
        inferMethod: String = "ode",
        useAdg: Bool = false,
        cfgIntervalStart: Double = 0.0,
        cfgIntervalEnd: Double = 1.0,
        // ACE-Step v1.5 advanced LM parameters
        thinking: Bool = true,
        lmTopK: Int = 0,
        lmTopP: Double = 0.9,
        lmRepetitionPenalty: Double = 1.0,
        lmNegativePrompt: String = "NO USER INPUT",
        constrainedDecoding: Bool = true
    ) async throws -> [(URL, JSONValue)] {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let outputDir = outputDir ?? FileStore.shared.audioDirectory.path
        var paramsDict: [String: JSONValue] = [
            "caption": .string(caption),
            "duration": .number(Double(duration)),
            "count": .number(Double(count)),
            "model": .string(model),
            "lm_model": .string(lmModel),
            "guidance_scale": .number(guidanceScale),
            "output_dir": .string(outputDir),
            "num_inference_steps": .number(Double(numInferenceSteps)),
            "lm_temperature": .number(lmTemperature),
            "lm_cfg_scale": .number(lmCfgScale),
            // ACE-Step v1.5 advanced diffusion parameters
            "shift": .number(shift),
            "infer_method": .string(inferMethod),
            "use_adg": .bool(useAdg),
            "cfg_interval_start": .number(cfgIntervalStart),
            "cfg_interval_end": .number(cfgIntervalEnd),
            // ACE-Step v1.5 advanced LM parameters
            "thinking": .bool(thinking),
            "lm_top_k": .number(Double(lmTopK)),
            "lm_top_p": .number(lmTopP),
            "lm_repetition_penalty": .number(lmRepetitionPenalty),
            "lm_negative_prompt": .string(lmNegativePrompt),
            "constrained_decoding": .bool(constrainedDecoding)
        ]
        if let seed {
            paramsDict["seed"] = .number(Double(seed))
        }
        if !timeSignature.isEmpty {
            paramsDict["time_signature"] = .string(timeSignature)
        }
        if !vocalLanguage.isEmpty {
            paramsDict["vocal_language"] = .string(vocalLanguage)
        }
        if let bpm {
            paramsDict["bpm"] = .number(Double(bpm))
        }
        if let key {
            paramsDict["key"] = .string(key)
        }
        if let lyrics {
            paramsDict["lyrics"] = .string(lyrics)
        }
        if let artist, !artist.isEmpty {
            paramsDict["artist"] = .string(artist)
        }
        if let album, !album.isEmpty {
            paramsDict["album"] = .string(album)
        }
        if let genre, !genre.isEmpty {
            paramsDict["genre"] = .string(genre)
        }
        if let mood, !mood.isEmpty {
            paramsDict["mood"] = .string(mood)
        }
        let params: JSONValue = .object(paramsDict)
        // Scale timeout with track duration: base 5min + 3min per minute of audio
        // e.g. 2.5min track = 5 + 7.5 = 12.5min timeout; 10min track = 5 + 30 = 35min timeout
        let timeoutSeconds = Double(300 + (duration * 180))
        let response = try await client.send(method: "generate_music", params: params, timeout: timeoutSeconds)

        // Handle single variant response (count=1)
        if case .object(let object)? = response.result,
           case .string(let path)? = object["audio_path"] {
            return [(URL(fileURLWithPath: path), object["metadata"] ?? .null)]
        }

        // Handle multi-variant response (count>1)
        guard case .object(let object)? = response.result,
              case .array(let variantsArray)? = object["variants"] else {
            throw RPCClientError.invalidResponse
        }

        return try variantsArray.map { variantValue in
            guard case .object(let variant) = variantValue,
                  case .string(let path)? = variant["audio_path"] else {
                throw RPCClientError.invalidResponse
            }
            return (URL(fileURLWithPath: path), variant["metadata"] ?? .null)
        }
    }

    // MARK: - Cover / Style Transfer

    func generateCover(
        referenceAudioPath: String,
        caption: String,
        coverStrength: Double = 0.5,
        duration: Int = 0,
        lyrics: String? = nil,
        bpm: Int? = nil,
        key: String? = nil,
        model: String = "acestep-v15-turbo",
        lmModel: String = LMModel.defaultRawValueForCurrentMac,
        guidanceScale: Double = 4.5,
        seed: Int? = nil,
        numInferenceSteps: Int = 8,
        lmTemperature: Double = 0.9,
        lmCfgScale: Double = 2.5,
        timeSignature: String = "4",
        vocalLanguage: String = "",
        outputDir: String? = nil,
        // ACE-Step v1.5 advanced diffusion parameters
        shift: Double = 3.0,
        inferMethod: String = "ode",
        useAdg: Bool = false,
        cfgIntervalStart: Double = 0.0,
        cfgIntervalEnd: Double = 1.0,
        // ACE-Step v1.5 advanced LM parameters
        thinking: Bool = true,
        lmTopK: Int = 0,
        lmTopP: Double = 0.9,
        lmRepetitionPenalty: Double = 1.0,
        lmNegativePrompt: String = "NO USER INPUT",
        constrainedDecoding: Bool = true
    ) async throws -> (URL, JSONValue) {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let outputDir = outputDir ?? FileStore.shared.audioDirectory.path
        var paramsDict: [String: JSONValue] = [
            "reference_audio": .string(referenceAudioPath),
            "caption": .string(caption),
            "cover_strength": .number(coverStrength),
            "duration": .number(Double(duration)),
            "model": .string(model),
            "lm_model": .string(lmModel),
            "guidance_scale": .number(guidanceScale),
            "output_dir": .string(outputDir),
            "num_inference_steps": .number(Double(numInferenceSteps)),
            "lm_temperature": .number(lmTemperature),
            "lm_cfg_scale": .number(lmCfgScale),
            // ACE-Step v1.5 advanced diffusion parameters
            "shift": .number(shift),
            "infer_method": .string(inferMethod),
            "use_adg": .bool(useAdg),
            "cfg_interval_start": .number(cfgIntervalStart),
            "cfg_interval_end": .number(cfgIntervalEnd),
            // ACE-Step v1.5 advanced LM parameters
            "thinking": .bool(thinking),
            "lm_top_k": .number(Double(lmTopK)),
            "lm_top_p": .number(lmTopP),
            "lm_repetition_penalty": .number(lmRepetitionPenalty),
            "lm_negative_prompt": .string(lmNegativePrompt),
            "constrained_decoding": .bool(constrainedDecoding)
        ]
        if let seed {
            paramsDict["seed"] = .number(Double(seed))
        }
        if !timeSignature.isEmpty {
            paramsDict["time_signature"] = .string(timeSignature)
        }
        if !vocalLanguage.isEmpty {
            paramsDict["vocal_language"] = .string(vocalLanguage)
        }
        if let bpm {
            paramsDict["bpm"] = .number(Double(bpm))
        }
        if let key {
            paramsDict["key"] = .string(key)
        }
        if let lyrics {
            paramsDict["lyrics"] = .string(lyrics)
        }
        let params: JSONValue = .object(paramsDict)
        let timeoutSeconds = Double(300 + (max(duration, 60) * 180))
        let response = try await client.send(method: "generate_cover", params: params, timeout: timeoutSeconds)

        guard case .object(let object)? = response.result,
              case .string(let path)? = object["audio_path"] else {
            throw RPCClientError.invalidResponse
        }
        return (URL(fileURLWithPath: path), object["metadata"] ?? .null)
    }

    // MARK: - Audio Continuation

    func generateContinuation(
        sourceAudioPath: String,
        caption: String,
        duration: Int = 0,
        lyrics: String? = nil,
        bpm: Int? = nil,
        key: String? = nil,
        model: String = "acestep-v15-turbo",
        lmModel: String = LMModel.defaultRawValueForCurrentMac,
        guidanceScale: Double = 4.5,
        seed: Int? = nil,
        numInferenceSteps: Int = 8,
        lmTemperature: Double = 0.9,
        lmCfgScale: Double = 2.5,
        timeSignature: String = "4",
        vocalLanguage: String = "",
        outputDir: String? = nil,
        // ACE-Step v1.5 advanced diffusion parameters
        shift: Double = 3.0,
        inferMethod: String = "ode",
        useAdg: Bool = false,
        cfgIntervalStart: Double = 0.0,
        cfgIntervalEnd: Double = 1.0,
        // ACE-Step v1.5 advanced LM parameters
        thinking: Bool = true,
        lmTopK: Int = 0,
        lmTopP: Double = 0.9,
        lmRepetitionPenalty: Double = 1.0,
        lmNegativePrompt: String = "NO USER INPUT",
        constrainedDecoding: Bool = true
    ) async throws -> (URL, JSONValue) {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let outputDir = outputDir ?? FileStore.shared.audioDirectory.path
        var paramsDict: [String: JSONValue] = [
            "source_audio": .string(sourceAudioPath),
            "caption": .string(caption),
            "duration": .number(Double(duration)),
            "model": .string(model),
            "lm_model": .string(lmModel),
            "guidance_scale": .number(guidanceScale),
            "output_dir": .string(outputDir),
            "num_inference_steps": .number(Double(numInferenceSteps)),
            "lm_temperature": .number(lmTemperature),
            "lm_cfg_scale": .number(lmCfgScale),
            // ACE-Step v1.5 advanced diffusion parameters
            "shift": .number(shift),
            "infer_method": .string(inferMethod),
            "use_adg": .bool(useAdg),
            "cfg_interval_start": .number(cfgIntervalStart),
            "cfg_interval_end": .number(cfgIntervalEnd),
            // ACE-Step v1.5 advanced LM parameters
            "thinking": .bool(thinking),
            "lm_top_k": .number(Double(lmTopK)),
            "lm_top_p": .number(lmTopP),
            "lm_repetition_penalty": .number(lmRepetitionPenalty),
            "lm_negative_prompt": .string(lmNegativePrompt),
            "constrained_decoding": .bool(constrainedDecoding)
        ]
        if let seed {
            paramsDict["seed"] = .number(Double(seed))
        }
        if !timeSignature.isEmpty {
            paramsDict["time_signature"] = .string(timeSignature)
        }
        if !vocalLanguage.isEmpty {
            paramsDict["vocal_language"] = .string(vocalLanguage)
        }
        if let bpm {
            paramsDict["bpm"] = .number(Double(bpm))
        }
        if let key {
            paramsDict["key"] = .string(key)
        }
        if let lyrics {
            paramsDict["lyrics"] = .string(lyrics)
        }
        let params: JSONValue = .object(paramsDict)
        let timeoutSeconds = Double(300 + (max(duration, 60) * 180))
        let response = try await client.send(method: "generate_continuation", params: params, timeout: timeoutSeconds)

        guard case .object(let object)? = response.result,
              case .string(let path)? = object["audio_path"] else {
            throw RPCClientError.invalidResponse
        }
        return (URL(fileURLWithPath: path), object["metadata"] ?? .null)
    }

    // MARK: - Repaint (Time-Range Audio Editing)

    func generateRepaint(
        sourceAudioPath: String,
        repaintStart: Double,
        repaintEnd: Double,
        caption: String,
        duration: Int = 0,
        lyrics: String? = nil,
        bpm: Int? = nil,
        key: String? = nil,
        model: String = "acestep-v15-base",
        lmModel: String = LMModel.defaultRawValueForCurrentMac,
        guidanceScale: Double = 4.5,
        seed: Int? = nil,
        numInferenceSteps: Int = 50,
        lmTemperature: Double = 0.9,
        lmCfgScale: Double = 2.5,
        timeSignature: String = "4",
        vocalLanguage: String = "",
        outputDir: String? = nil
    ) async throws -> (URL, JSONValue) {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let outputDir = outputDir ?? FileStore.shared.audioDirectory.path
        var paramsDict: [String: JSONValue] = [
            "source_audio": .string(sourceAudioPath),
            "repainting_start": .number(repaintStart),
            "repainting_end": .number(repaintEnd),
            "caption": .string(caption),
            "duration": .number(Double(duration)),
            "model": .string(model),
            "lm_model": .string(lmModel),
            "guidance_scale": .number(guidanceScale),
            "output_dir": .string(outputDir),
            "num_inference_steps": .number(Double(numInferenceSteps)),
            "lm_temperature": .number(lmTemperature),
            "lm_cfg_scale": .number(lmCfgScale)
        ]
        if let seed {
            paramsDict["seed"] = .number(Double(seed))
        }
        if !timeSignature.isEmpty {
            paramsDict["time_signature"] = .string(timeSignature)
        }
        if !vocalLanguage.isEmpty {
            paramsDict["vocal_language"] = .string(vocalLanguage)
        }
        if let bpm {
            paramsDict["bpm"] = .number(Double(bpm))
        }
        if let key {
            paramsDict["key"] = .string(key)
        }
        if let lyrics {
            paramsDict["lyrics"] = .string(lyrics)
        }
        let params: JSONValue = .object(paramsDict)
        let timeoutSeconds = Double(300 + (max(duration, 60) * 180))
        let response = try await client.send(method: "generate_repaint", params: params, timeout: timeoutSeconds)

        guard case .object(let object)? = response.result,
              case .string(let path)? = object["audio_path"] else {
            throw RPCClientError.invalidResponse
        }
        return (URL(fileURLWithPath: path), object["metadata"] ?? .null)
    }

    // MARK: - Extract (Stem Isolation)

    func generateExtract(
        sourceAudioPath: String,
        stems: [String],
        caption: String = "",
        duration: Int = 0,
        bpm: Int? = nil,
        key: String? = nil,
        model: String = "acestep-v15-base",
        lmModel: String = LMModel.defaultRawValueForCurrentMac,
        guidanceScale: Double = 4.5,
        seed: Int? = nil,
        numInferenceSteps: Int = 50,
        lmTemperature: Double = 0.9,
        lmCfgScale: Double = 2.5,
        timeSignature: String = "4",
        vocalLanguage: String = "",
        outputDir: String? = nil
    ) async throws -> (URL, JSONValue) {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let outputDir = outputDir ?? FileStore.shared.audioDirectory.path
        let instruction = stems.joined(separator: ", ")
        var paramsDict: [String: JSONValue] = [
            "source_audio": .string(sourceAudioPath),
            "instruction": .string(instruction),
            "caption": .string(caption),
            "duration": .number(Double(duration)),
            "model": .string(model),
            "lm_model": .string(lmModel),
            "guidance_scale": .number(guidanceScale),
            "output_dir": .string(outputDir),
            "num_inference_steps": .number(Double(numInferenceSteps)),
            "lm_temperature": .number(lmTemperature),
            "lm_cfg_scale": .number(lmCfgScale)
        ]
        if let seed {
            paramsDict["seed"] = .number(Double(seed))
        }
        if !timeSignature.isEmpty {
            paramsDict["time_signature"] = .string(timeSignature)
        }
        if !vocalLanguage.isEmpty {
            paramsDict["vocal_language"] = .string(vocalLanguage)
        }
        if let bpm {
            paramsDict["bpm"] = .number(Double(bpm))
        }
        if let key {
            paramsDict["key"] = .string(key)
        }
        let params: JSONValue = .object(paramsDict)
        let timeoutSeconds = Double(300 + (max(duration, 60) * 180))
        let response = try await client.send(method: "generate_extract", params: params, timeout: timeoutSeconds)

        guard case .object(let object)? = response.result,
              case .string(let path)? = object["audio_path"] else {
            throw RPCClientError.invalidResponse
        }
        return (URL(fileURLWithPath: path), object["metadata"] ?? .null)
    }

    // MARK: - Lego (Multi-Track Contextual Generation)

    func generateLego(
        sourceAudioPath: String,
        instruction: String,
        caption: String,
        duration: Int = 0,
        lyrics: String? = nil,
        bpm: Int? = nil,
        key: String? = nil,
        model: String = "acestep-v15-base",
        lmModel: String = LMModel.defaultRawValueForCurrentMac,
        guidanceScale: Double = 4.5,
        seed: Int? = nil,
        numInferenceSteps: Int = 50,
        lmTemperature: Double = 0.9,
        lmCfgScale: Double = 2.5,
        timeSignature: String = "4",
        vocalLanguage: String = "",
        outputDir: String? = nil
    ) async throws -> (URL, JSONValue) {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let outputDir = outputDir ?? FileStore.shared.audioDirectory.path
        var paramsDict: [String: JSONValue] = [
            "source_audio": .string(sourceAudioPath),
            "instruction": .string(instruction),
            "caption": .string(caption),
            "duration": .number(Double(duration)),
            "model": .string(model),
            "lm_model": .string(lmModel),
            "guidance_scale": .number(guidanceScale),
            "output_dir": .string(outputDir),
            "num_inference_steps": .number(Double(numInferenceSteps)),
            "lm_temperature": .number(lmTemperature),
            "lm_cfg_scale": .number(lmCfgScale)
        ]
        if let seed {
            paramsDict["seed"] = .number(Double(seed))
        }
        if !timeSignature.isEmpty {
            paramsDict["time_signature"] = .string(timeSignature)
        }
        if !vocalLanguage.isEmpty {
            paramsDict["vocal_language"] = .string(vocalLanguage)
        }
        if let bpm {
            paramsDict["bpm"] = .number(Double(bpm))
        }
        if let key {
            paramsDict["key"] = .string(key)
        }
        if let lyrics {
            paramsDict["lyrics"] = .string(lyrics)
        }
        let params: JSONValue = .object(paramsDict)
        let timeoutSeconds = Double(300 + (max(duration, 60) * 180))
        let response = try await client.send(method: "generate_lego", params: params, timeout: timeoutSeconds)

        guard case .object(let object)? = response.result,
              case .string(let path)? = object["audio_path"] else {
            throw RPCClientError.invalidResponse
        }
        return (URL(fileURLWithPath: path), object["metadata"] ?? .null)
    }

    // MARK: - Auto-Complete (Fill Missing Instruments)

    func generateAutoComplete(
        sourceAudioPath: String,
        caption: String,
        duration: Int = 0,
        lyrics: String? = nil,
        bpm: Int? = nil,
        key: String? = nil,
        model: String = "acestep-v15-base",
        lmModel: String = LMModel.defaultRawValueForCurrentMac,
        guidanceScale: Double = 4.5,
        seed: Int? = nil,
        numInferenceSteps: Int = 50,
        lmTemperature: Double = 0.9,
        lmCfgScale: Double = 2.5,
        timeSignature: String = "4",
        vocalLanguage: String = "",
        outputDir: String? = nil
    ) async throws -> (URL, JSONValue) {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let outputDir = outputDir ?? FileStore.shared.audioDirectory.path
        var paramsDict: [String: JSONValue] = [
            "source_audio": .string(sourceAudioPath),
            "caption": .string(caption),
            "duration": .number(Double(duration)),
            "model": .string(model),
            "lm_model": .string(lmModel),
            "guidance_scale": .number(guidanceScale),
            "output_dir": .string(outputDir),
            "num_inference_steps": .number(Double(numInferenceSteps)),
            "lm_temperature": .number(lmTemperature),
            "lm_cfg_scale": .number(lmCfgScale)
        ]
        if let seed {
            paramsDict["seed"] = .number(Double(seed))
        }
        if !timeSignature.isEmpty {
            paramsDict["time_signature"] = .string(timeSignature)
        }
        if !vocalLanguage.isEmpty {
            paramsDict["vocal_language"] = .string(vocalLanguage)
        }
        if let bpm {
            paramsDict["bpm"] = .number(Double(bpm))
        }
        if let key {
            paramsDict["key"] = .string(key)
        }
        if let lyrics {
            paramsDict["lyrics"] = .string(lyrics)
        }
        let params: JSONValue = .object(paramsDict)
        let timeoutSeconds = Double(300 + (max(duration, 60) * 180))
        let response = try await client.send(method: "generate_auto_complete", params: params, timeout: timeoutSeconds)

        guard case .object(let object)? = response.result,
              case .string(let path)? = object["audio_path"] else {
            throw RPCClientError.invalidResponse
        }
        return (URL(fileURLWithPath: path), object["metadata"] ?? .null)
    }

    // MARK: - Audio Import

    func importAudio(filePath: String) async throws -> (URL, JSONValue) {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let outputDir = FileStore.shared.audioDirectory.path
        let params: JSONValue = .object([
            "file_path": .string(filePath),
            "output_dir": .string(outputDir)
        ])
        let response = try await client.send(method: "import_audio", params: params, timeout: 60)
        guard case .object(let object)? = response.result,
              case .string(let path)? = object["audio_path"] else {
            throw RPCClientError.invalidResponse
        }
        return (URL(fileURLWithPath: path), object["metadata"] ?? .null)
    }

    /// Use ACE-Step music understanding to extract metadata (caption, lyrics,
    /// BPM, key, duration, language, time signature) from an audio file.
    /// Falls back to basic librosa extraction when ACE-Step models are unavailable.
    struct MusicUnderstanding {
        var caption: String
        var lyrics: String
        var bpm: Double?
        var key: String?
        var duration: Double?
        var language: String?
        var timeSignature: String?
    }

    func understandMusic(audioPath: String) async throws -> MusicUnderstanding {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let params: JSONValue = .object([
            "audio_path": .string(audioPath)
        ])
        // Music understanding can take a while when loading models
        let response = try await client.send(method: "understand_music", params: params, timeout: 300)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }

        let caption: String
        if case .string(let c) = result["caption"] { caption = c } else { caption = "" }

        let lyrics: String
        if case .string(let l) = result["lyrics"] { lyrics = l } else { lyrics = "" }

        let bpm: Double?
        if case .number(let b) = result["bpm"] { bpm = b } else { bpm = nil }

        let key: String?
        if case .string(let k) = result["key"] { key = k } else { key = nil }

        let duration: Double?
        if case .number(let d) = result["duration"] { duration = d } else { duration = nil }

        let language: String?
        if case .string(let lang) = result["language"] { language = lang.isEmpty ? nil : lang } else { language = nil }

        let timeSignature: String?
        if case .string(let ts) = result["time_signature"] { timeSignature = ts.isEmpty ? nil : ts } else { timeSignature = nil }

        return MusicUnderstanding(
            caption: caption,
            lyrics: lyrics,
            bpm: bpm,
            key: key,
            duration: duration,
            language: language,
            timeSignature: timeSignature
        )
    }

    // MARK: - Audio Export

    func exportTrack(
        filePath: String,
        outputPath: String,
        format: String = "wav",
        bitrate: String? = nil,
        metadata: [String: String]? = nil
    ) async throws -> String {
        guard let client else {
            throw RPCClientError.processNotRunning
        }

        var paramsDict: [String: JSONValue] = [
            "file_path": .string(filePath),
            "output_path": .string(outputPath),
            "format": .string(format)
        ]

        if let bitrate = bitrate {
            paramsDict["bitrate"] = .string(bitrate)
        }

        if let metadata = metadata {
            var metaDict: [String: JSONValue] = [:]
            for (key, value) in metadata {
                metaDict[key] = .string(value)
            }
            paramsDict["metadata"] = .object(metaDict)
        }

        let params: JSONValue = .object(paramsDict)
        let response = try await client.send(method: "export_track", params: params, timeout: 120)

        guard case .object(let object)? = response.result,
              case .string(let exportedPath)? = object["file_path"] else {  // FIXED: was "exported_path"
            throw RPCClientError.invalidResponse
        }
        return exportedPath
    }

    func exportStems(filePath: String, outputDir: String) async throws -> [String: String] {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let params: JSONValue = .object([
            "file_path": .string(filePath),
            "output_dir": .string(outputDir)
        ])
        let response = try await client.send(method: "export_stems", params: params, timeout: 300)
        guard case .object(let object)? = response.result,
              case .object(let stemsDict)? = object["stems"] else {
            throw RPCClientError.invalidResponse
        }

        var stems: [String: String] = [:]
        for (key, value) in stemsDict {
            if case .string(let path) = value {
                stems[key] = path
            }
        }
        return stems
    }

    func tagAudioMetadata(filePath: String, metadata: [String: String]) async throws {
        guard let client else { throw RPCClientError.processNotRunning }

        var metaDict: [String: JSONValue] = [:]
        for (key, value) in metadata {
            metaDict[key] = .string(value)
        }

        let params: JSONValue = .object([
            "file_path": .string(filePath),
            "metadata": .object(metaDict)
        ])
        _ = try await client.send(method: "tag_audio_metadata", params: params, timeout: 30)
    }

    // MARK: - Track Naming

    func generateTrackName(
        caption: String?,
        lyrics: String?,
        bpm: Double?,
        key: String?,
        artist: String?,
        genre: String?
    ) async throws -> (name: String, genre: String?) {
        guard let client else {
            throw RPCClientError.processNotRunning
        }

        var paramsDict: [String: JSONValue] = [:]
        if let caption {
            paramsDict["caption"] = .string(caption)
        }
        if let lyrics {
            paramsDict["lyrics"] = .string(lyrics)
        }
        if let bpm {
            paramsDict["bpm"] = .number(bpm)
        }
        if let key {
            paramsDict["key"] = .string(key)
        }
        if let artist {
            paramsDict["artist"] = .string(artist)
        }
        if let genre {
            paramsDict["genre"] = .string(genre)
        }

        let params: JSONValue = .object(paramsDict)
        let response = try await client.send(method: "generate_track_name", params: params, timeout: 60)

        guard case .object(let object)? = response.result,
              case .string(let trackName)? = object["track_name"] else {
            throw RPCClientError.invalidResponse
        }

        var resultGenre: String?
        if case .string(let g)? = object["genre"] {
            resultGenre = g
        }

        return (name: trackName, genre: resultGenre)
    }

    // MARK: - Model Management

    func listModels() async throws -> [String] {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let response = try await client.send(method: "list_models", params: nil, timeout: 30)
        guard case .object(let object)? = response.result,
              case .array(let modelsArray)? = object["models"] else {
            throw RPCClientError.invalidResponse
        }

        return modelsArray.compactMap { value in
            if case .string(let model) = value {
                return model
            }
            return nil
        }
    }

    func unloadLLM() async throws -> String {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let response = try await client.send(method: "unload_llm", params: nil, timeout: 30)
        guard case .object(let object)? = response.result,
              case .string(let message)? = object["message"] else {
            throw RPCClientError.invalidResponse
        }
        return message
    }

    func unloadModels() async throws -> String {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let response = try await client.send(method: "unload_models", params: nil, timeout: 30)
        guard case .object(let object)? = response.result,
              case .string(let message)? = object["message"] else {
            throw RPCClientError.invalidResponse
        }
        return message
    }

    func downloadMLXModel(model: String) async throws -> String {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let params: JSONValue = .object(["model": .string(model)])
        // Longer timeout for large model downloads (11GB can take 5-10 minutes)
        let response = try await client.send(method: "download_mlx_model", params: params, timeout: 900) // 15 minutes
        guard case .object(let object)? = response.result,
              case .string(let status)? = object["status"] else {
            throw RPCClientError.invalidResponse
        }
        return status
    }

    func listAvailableModels() async throws -> [String: LLMSettingsView.ModelInfo] {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        // Longer timeout in case backend is busy with other operations (like model downloads)
        let response = try await client.send(method: "list_available_models", params: nil, timeout: 30)
        guard case .object(let resultObj)? = response.result else {
            throw RPCClientError.invalidResponse
        }

        var models: [String: LLMSettingsView.ModelInfo] = [:]
        for (modelId, value) in resultObj {
            guard case .object(let modelObj) = value,
                  case .string(let name) = modelObj["name"],
                  case .number(let sizeGB) = modelObj["size_gb"],
                  case .string(let description) = modelObj["description"],
                  case .bool(let installed) = modelObj["installed"] else {
                continue
            }

            let path: String? = if case .string(let p) = modelObj["path"] { p } else { nil }

            models[modelId] = LLMSettingsView.ModelInfo(
                name: name,
                size_gb: sizeGB,
                description: description,
                installed: installed,
                path: path
            )
        }

        return models
    }

    func downloadModel(modelId: String) async throws -> [String: Any] {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let params: JSONValue = .object(["model_id": .string(modelId)])
        let response = try await client.send(method: "download_model", params: params, timeout: 600) // 10 min timeout for large downloads

        guard case .object(let resultObj)? = response.result else {
            throw RPCClientError.invalidResponse
        }

        // Convert JSONValue to Dictionary
        var result: [String: Any] = [:]
        for (key, value) in resultObj {
            switch value {
            case .string(let str): result[key] = str
            case .number(let num): result[key] = num
            case .bool(let bool): result[key] = bool
            default: break
            }
        }

        return result
    }

    // MARK: - LLM Provider Management

    func listLLMProviders() async throws -> LLMProviderInfo {
        guard let client else {
            throw RPCClientError.processNotRunning
        }
        let response = try await client.send(method: "list_llm_providers", params: nil, timeout: 30)
        guard case .object(let object)? = response.result,
              case .array(let availableArray)? = object["available"],
              case .string(let current)? = object["current"] else {
            throw RPCClientError.invalidResponse
        }

        let available = availableArray.compactMap { value -> String? in
            if case .string(let provider) = value {
                return provider
            }
            return nil
        }

        var fallback: String?
        if case .string(let fb)? = object["fallback"] {
            fallback = fb
        }

        var models: [String: String] = [:]
        if case .object(let modelsDict)? = object["models"] {
            for (key, value) in modelsDict {
                if case .string(let model) = value {
                    models[key] = model
                }
            }
        }

        return LLMProviderInfo(
            available: available,
            current: current,
            fallback: fallback,
            models: models
        )
    }

    func setLLMProvider(provider: String, fallbackProvider: String? = nil) async throws -> (String, String?) {
        guard let client else {
            throw RPCClientError.processNotRunning
        }

        var params: [String: JSONValue] = ["provider": .string(provider)]
        if let fallback = fallbackProvider {
            params["fallback_provider"] = .string(fallback)
        }

        let response = try await client.send(method: "set_llm_provider", params: .object(params), timeout: 30)
        guard case .object(let object)? = response.result,
              case .string(let resultProvider)? = object["provider"] else {
            throw RPCClientError.invalidResponse
        }

        var resultFallback: String?
        if case .string(let fb)? = object["fallback"] {
            resultFallback = fb
        }

        return (resultProvider, resultFallback)
    }

    // MARK: - System & Installation Methods

    /// Test if ACE-Step installation is working
    func testAceStepInstallation() async throws -> ACEStepTestResult {
        guard let client else { throw RPCClientError.processNotRunning }
        let response = try await client.send(method: "validate_ace_step", timeout: 30)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }

        var isWorking = false
        if case .bool(let value)? = result["valid"] {
            isWorking = value
        }

        var path: String?
        if case .string(let value)? = result["path"] {
            path = value
        }

        var message: String?
        if case .string(let value)? = result["message"] {
            message = value
        }

        return ACEStepTestResult(isWorking: isWorking, path: path, message: message)
    }

    /// Install ACE-Step automatically
    func installAceStep() async throws -> ACEStepInstallResult {
        guard let client else { throw RPCClientError.processNotRunning }
        let response = try await client.send(method: "install_ace_step", timeout: 300) // 5 min timeout

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }

        var status: String?
        if case .string(let value)? = result["status"] {
            status = value
        }

        var path: String?
        if case .string(let value)? = result["path"] {
            path = value
        }

        let success = (status == "installed" || status == "already_installed")

        var error: String?
        if !success {
            if case .string(let value)? = result["message"] {
                error = value
            } else {
                error = "Unknown installation status"
            }
        }

        return ACEStepInstallResult(success: success, status: status, path: path, error: error)
    }

    /// Test connection to a remote ACE-Step server
    func testRemoteACEStep(serverURL: String) async throws -> RemoteACEStepTestResult {
        guard let client else { throw RPCClientError.processNotRunning }
        let params: JSONValue = .object(["server_url": .string(serverURL)])
        let response = try await client.send(method: "test_remote_ace_step", params: params, timeout: 15)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }

        var success = false
        if case .bool(let value)? = result["success"] {
            success = value
        }

        var message = ""
        if case .string(let value)? = result["message"] {
            message = value
        }

        return RemoteACEStepTestResult(success: success, message: message)
    }

    /// Get system information (RAM, disk, architecture)
    func getSystemInfo() async throws -> SystemInfo {
        guard let client else { throw RPCClientError.processNotRunning }
        let response = try await client.send(method: "get_system_info", timeout: 10)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }

        var totalRAM: Double = 0
        if case .number(let value)? = result["total_ram_gb"] {
            totalRAM = value
        }

        var availableDisk: Double = 0
        if case .number(let value)? = result["available_disk_gb"] {
            availableDisk = value
        }

        var architecture = "Unknown"
        if case .string(let value)? = result["cpu_architecture"] {
            architecture = value
        }

        var osVersion = "Unknown"
        if case .string(let value)? = result["macos_version"] {
            osVersion = value
        }

        return SystemInfo(totalRAM: totalRAM, availableDisk: availableDisk, architecture: architecture, osVersion: osVersion)
    }

    // MARK: - Artist Profiles

    func listArtistProfiles(keycloakId: String, accessToken: String? = nil) async throws -> (profiles: [[String: JSONValue]], maxArtists: Int) {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsBase: [String: JSONValue] = ["keycloak_id": .string(keycloakId)]
        if let accessToken, !accessToken.isEmpty { paramsBase["access_token"] = .string(accessToken) }
        let params: JSONValue = .object(paramsBase)
        let response = try await client.send(method: "list_artist_profiles", params: params, timeout: 30)

        guard case .object(let result)? = response.result,
              case .object(let data)? = result["data"] else {
            throw RPCClientError.invalidResponse
        }

        var profiles: [[String: JSONValue]] = []
        if case .array(let profilesArray)? = data["profiles"] {
            profiles = profilesArray.compactMap { value in
                if case .object(let dict) = value { return dict }
                return nil
            }
        }

        var maxArtists = 1
        if case .number(let n)? = data["maxArtists"] ?? data["max_artists"] {
            maxArtists = Int(n)
        }

        return (profiles, maxArtists)
    }

    func createArtistProfile(keycloakId: String, artistName: String, accessToken: String? = nil) async throws -> [String: JSONValue] {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "keycloak_id": .string(keycloakId),
            "artist_name": .string(artistName),
        ]
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }
        let params: JSONValue = .object(paramsDict)
        let response = try await client.send(method: "create_artist_profile", params: params, timeout: 30)

        guard case .object(let result)? = response.result,
              case .object(let data)? = result["data"] else {
            throw RPCClientError.invalidResponse
        }
        return data
    }

    func updateArtistProfile(
        profileId: String,
        keycloakId: String,
        artistName: String? = nil,
        website: String? = nil,
        socialLinks: [String: String]? = nil,
        accessToken: String? = nil
    ) async throws {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "profile_id": .string(profileId),
            "keycloak_id": .string(keycloakId),
        ]
        if let artistName { paramsDict["artist_name"] = .string(artistName) }
        if let website { paramsDict["website"] = .string(website) }
        if let socialLinks {
            paramsDict["social_links"] = .object(socialLinks.mapValues { .string($0) })
        }
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }

        _ = try await client.send(method: "update_artist_profile", params: .object(paramsDict), timeout: 30)
    }

    func deleteArtistProfile(profileId: String, keycloakId: String, accessToken: String? = nil) async throws {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "profile_id": .string(profileId),
            "keycloak_id": .string(keycloakId),
        ]
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }
        _ = try await client.send(method: "delete_artist_profile", params: .object(paramsDict), timeout: 30)
    }

    // MARK: - Publishing

    func convertAudioForPublish(sourcePath: String) async throws -> (flacPath: String, m4aPath: String, m4aLowPath: String, sourceSizeMB: Double, flacSizeMB: Double, m4aSizeMB: Double, m4aLowSizeMB: Double) {
        guard let client else { throw RPCClientError.processNotRunning }

        let params: JSONValue = .object([
            "source_path": .string(sourcePath)
        ])

        let response = try await client.send(method: "convert_audio_for_publish", params: params, timeout: 120)

        guard case .object(let result)? = response.result,
              case .string(let flacPath)? = result["flac_path"],
              case .string(let m4aPath)? = result["m4a_path"],
              case .string(let m4aLowPath)? = result["m4a_low_path"],
              case .number(let sourceSizeMB)? = result["source_size_mb"],
              case .number(let flacSizeMB)? = result["flac_size_mb"],
              case .number(let m4aSizeMB)? = result["m4a_size_mb"],
              case .number(let m4aLowSizeMB)? = result["m4a_low_size_mb"] else {
            throw RPCClientError.invalidResponse
        }

        return (flacPath, m4aPath, m4aLowPath, sourceSizeMB, flacSizeMB, m4aSizeMB, m4aLowSizeMB)
    }

    func publishTrack(
        m4aPath: String,
        keycloakId: String,
        title: String,
        studioTrackId: String,
        artist: String? = nil,
        genre: String? = nil,
        album: String? = nil,
        bpm: Double? = nil,
        musicalKey: String? = nil,
        lyrics: String? = nil,
        duration: Double? = nil,
        fingerprint: String? = nil,
        generationParams: String? = nil,
        artistProfileId: String? = nil,
        artworkPath: String? = nil,
        parentTrackId: String? = nil,
        lyricsLrc: String? = nil,
        albumArtworkPath: String? = nil,
        audioPath: String? = nil,
        streamPath: String? = nil,
        streamLowPath: String? = nil,
        description: String? = nil,
        backstory: String? = nil,
        backstoryVisibility: String? = nil,
        subgenre: String? = nil,
        mood: String? = nil,
        energy: Double? = nil,
        language: String? = nil,
        isExplicit: Bool? = nil,
        tags: String? = nil,
        credits: String? = nil,
        scheduledAt: String? = nil,
        isrc: String? = nil,
        requestISRC: Bool = false,
        accessToken: String? = nil
    ) async throws -> (trackId: String, slug: String, url: String, isrc: String?) {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "m4a_path": .string(m4aPath),
            "keycloak_id": .string(keycloakId),
            "title": .string(title),
            "studio_track_id": .string(studioTrackId),
        ]
        if let artist, !artist.isEmpty { paramsDict["artist"] = .string(artist) }
        if let genre, !genre.isEmpty { paramsDict["genre"] = .string(genre) }
        if let album, !album.isEmpty { paramsDict["album"] = .string(album) }
        if let bpm { paramsDict["bpm"] = .string(String(Int(bpm))) }
        if let musicalKey, !musicalKey.isEmpty { paramsDict["musical_key"] = .string(musicalKey) }
        if let lyrics, !lyrics.isEmpty { paramsDict["lyrics"] = .string(lyrics) }
        if let duration { paramsDict["duration"] = .string(String(duration)) }
        if let fingerprint, !fingerprint.isEmpty { paramsDict["fingerprint"] = .string(fingerprint) }
        if let generationParams, !generationParams.isEmpty { paramsDict["generation_params"] = .string(generationParams) }
        if let artistProfileId, !artistProfileId.isEmpty { paramsDict["artist_profile_id"] = .string(artistProfileId) }
        if let artworkPath, !artworkPath.isEmpty { paramsDict["artwork_path"] = .string(artworkPath) }
        if let parentTrackId, !parentTrackId.isEmpty { paramsDict["parent_track_id"] = .string(parentTrackId) }
        if let lyricsLrc, !lyricsLrc.isEmpty { paramsDict["lyrics_lrc"] = .string(lyricsLrc) }
        if let albumArtworkPath, !albumArtworkPath.isEmpty { paramsDict["album_artwork_path"] = .string(albumArtworkPath) }
        if let audioPath, !audioPath.isEmpty { paramsDict["audio_path"] = .string(audioPath) }
        if let streamPath, !streamPath.isEmpty { paramsDict["stream_path"] = .string(streamPath) }
        if let streamLowPath, !streamLowPath.isEmpty { paramsDict["stream_low_path"] = .string(streamLowPath) }
        if let description, !description.isEmpty { paramsDict["description"] = .string(description) }
        if let backstory, !backstory.isEmpty { paramsDict["backstory"] = .string(backstory) }
        if let backstoryVisibility, !backstoryVisibility.isEmpty { paramsDict["backstory_visibility"] = .string(backstoryVisibility) }
        if let subgenre, !subgenre.isEmpty { paramsDict["subgenre"] = .string(subgenre) }
        if let mood, !mood.isEmpty { paramsDict["mood"] = .string(mood) }
        if let energy { paramsDict["energy"] = .string(String(energy)) }
        if let language, !language.isEmpty { paramsDict["language"] = .string(language) }
        if let isExplicit { paramsDict["explicit"] = .string(isExplicit ? "true" : "false") }
        if let tags, !tags.isEmpty { paramsDict["tags"] = .string(tags) }
        if let credits, !credits.isEmpty { paramsDict["credits"] = .string(credits) }
        if let scheduledAt, !scheduledAt.isEmpty { paramsDict["scheduled_at"] = .string(scheduledAt) }
        if let isrc, !isrc.isEmpty { paramsDict["isrc"] = .string(isrc) }
        if requestISRC { paramsDict["request_isrc"] = .bool(true) }
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }

        let params: JSONValue = .object(paramsDict)

        let response = try await client.send(method: "publish_track", params: params, timeout: 180)

        guard case .object(let result)? = response.result,
              case .string(let trackId)? = result["track_id"],
              case .string(let slug)? = result["track_slug"],
              case .string(let url)? = result["url"] else {
            throw RPCClientError.invalidResponse
        }

        let returnedISRC = result["isrc"]?.stringValue ?? result["isrcFormatted"]?.stringValue

        return (trackId, slug, url, returnedISRC)
    }

    // MARK: - Fingerprinting

    func computeFingerprint(audioPath: String) async throws -> (fingerprint: String?, available: Bool) {
        guard let client else { throw RPCClientError.processNotRunning }

        let params: JSONValue = .object(["audio_path": .string(audioPath)])
        let response = try await client.send(method: "compute_fingerprint", params: params, timeout: 90)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }

        var available = false
        if case .bool(let val)? = result["available"] {
            available = val
        }

        let fingerprint = result["fingerprint"]?.stringValue

        return (fingerprint, available)
    }

    func fingerprintLookup(fingerprint: String, keycloakId: String, accessToken: String? = nil) async throws -> [[String: JSONValue]] {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "fingerprint": .string(fingerprint),
            "keycloak_id": .string(keycloakId),
        ]
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }
        let params: JSONValue = .object(paramsDict)
        let response = try await client.send(method: "fingerprint_lookup", params: params, timeout: 30)

        guard case .object(let result)? = response.result,
              case .array(let matches)? = result["matches"] else {
            return []
        }

        return matches.compactMap { value in
            if case .object(let dict) = value { return dict }
            return nil
        }
    }

    // MARK: - LRC Lyrics Timestamp Generation

    /// Generate a timestamped LRC lyrics file by aligning known lyrics to audio using forced alignment.
    /// Returns the output path on success, or nil if generation failed (non-fatal).
    func generateLyricsTimestamps(audioPath: String, lyrics: String, outputPath: String) async throws -> String {
        guard let client else { throw RPCClientError.processNotRunning }

        let params: JSONValue = .object([
            "audio_path": .string(audioPath),
            "lyrics": .string(lyrics),
            "output_path": .string(outputPath),
        ])

        // Forced alignment can take a while on long audio + first-run model download (~300MB)
        let response = try await client.send(method: "generate_lyrics_timestamps", params: params, timeout: 300)

        guard case .object(let result)? = response.result,
              case .string(let resultPath)? = result["output_path"] else {
            throw RPCClientError.invalidResponse
        }

        return resultPath
    }

    // MARK: - Provenance

    func fetchProvenance(trackId: String) async throws -> ProvenanceCertificate? {
        guard let client else { throw RPCClientError.processNotRunning }

        let params: JSONValue = .object(["track_id": .string(trackId)])
        let response = try await client.send(method: "fetch_provenance", params: params, timeout: 15)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }

        // Check for pending or not_found status
        if case .string(let status)? = result["status"] {
            if status == "pending" || status == "not_found" {
                return nil
            }
        }

        let trackIdVal = result["trackId"]?.stringValue ?? result["track_id"]?.stringValue ?? ""
        let title = result["title"]?.stringValue ?? ""
        let artist = result["artist"]?.stringValue ?? ""
        let publishedAt = result["publishedAt"]?.stringValue ?? result["published_at"]?.stringValue ?? ""
        let provenanceHash = result["provenanceHash"]?.stringValue ?? result["provenance_hash"]?.stringValue ?? ""
        let verificationUrl = result["verificationUrl"]?.stringValue ?? result["verification_url"]?.stringValue ?? ""

        return ProvenanceCertificate(
            trackId: trackIdVal,
            title: title,
            artist: artist,
            publishedAt: publishedAt,
            provenanceHash: provenanceHash,
            verificationUrl: verificationUrl
        )
    }

    // MARK: - Catalogue

    func fetchCatalogue(keycloakId: String, offset: Int = 0, limit: Int = 50, accessToken: String? = nil) async throws -> (tracks: [[String: JSONValue]], total: Int) {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "keycloak_id": .string(keycloakId),
            "offset": .number(Double(offset)),
            "limit": .number(Double(limit)),
        ]
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }
        let params: JSONValue = .object(paramsDict)
        let response = try await client.send(method: "fetch_catalogue", params: params, timeout: 30)

        guard case .object(let result)? = response.result,
              case .object(let data)? = result["data"] else {
            throw RPCClientError.invalidResponse
        }

        var tracks: [[String: JSONValue]] = []
        if case .array(let tracksArray)? = data["tracks"] {
            tracks = tracksArray.compactMap { value in
                if case .object(let dict) = value { return dict }
                return nil
            }
        }

        var total = 0
        if case .number(let n)? = data["total"] {
            total = Int(n)
        }

        return (tracks, total)
    }

    func updatePublishedTrack(
        trackId: String,
        keycloakId: String,
        title: String? = nil,
        genre: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        bpm: String? = nil,
        musicalKey: String? = nil,
        lyrics: String? = nil,
        artistProfileId: String? = nil,
        syncedLyrics: String? = nil,
        description: String? = nil,
        backstory: String? = nil,
        backstoryVisibility: String? = nil,
        subgenre: String? = nil,
        mood: String? = nil,
        energy: Double? = nil,
        language: String? = nil,
        isExplicit: Bool? = nil,
        tags: String? = nil,
        credits: String? = nil,
        isrc: String? = nil,
        accessToken: String? = nil
    ) async throws {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "track_id": .string(trackId),
            "keycloak_id": .string(keycloakId),
        ]
        if let title { paramsDict["title"] = .string(title) }
        if let genre { paramsDict["genre"] = .string(genre) }
        if let artist { paramsDict["artist"] = .string(artist) }
        if let album { paramsDict["album"] = .string(album) }
        if let bpm { paramsDict["bpm"] = .string(bpm) }
        if let musicalKey { paramsDict["musical_key"] = .string(musicalKey) }
        if let lyrics { paramsDict["lyrics"] = .string(lyrics) }
        if let artistProfileId { paramsDict["artist_profile_id"] = .string(artistProfileId) }
        if let syncedLyrics { paramsDict["lyrics_lrc"] = .string(syncedLyrics) }
        if let description { paramsDict["description"] = .string(description) }
        if let backstory { paramsDict["backstory"] = .string(backstory) }
        if let backstoryVisibility { paramsDict["backstory_visibility"] = .string(backstoryVisibility) }
        if let subgenre { paramsDict["subgenre"] = .string(subgenre) }
        if let mood { paramsDict["mood"] = .string(mood) }
        if let energy { paramsDict["energy"] = .string(String(energy)) }
        if let language { paramsDict["language"] = .string(language) }
        if let isExplicit { paramsDict["explicit"] = .string(isExplicit ? "true" : "false") }
        if let tags { paramsDict["tags"] = .string(tags) }
        if let credits { paramsDict["credits"] = .string(credits) }
        if let isrc, !isrc.isEmpty { paramsDict["isrc"] = .string(isrc) }
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }

        _ = try await client.send(method: "update_published_track", params: .object(paramsDict), timeout: 30)
    }

    func unpublishTrack(trackId: String, keycloakId: String, accessToken: String? = nil) async throws {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "track_id": .string(trackId),
            "keycloak_id": .string(keycloakId),
        ]
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }
        _ = try await client.send(method: "unpublish_track", params: .object(paramsDict), timeout: 30)
    }

    // MARK: - Creator Dashboard

    func fetchCreatorSales(keycloakId: String, view: String = "summary", period: String = "month", accessToken: String? = nil) async throws -> [String: JSONValue] {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "keycloak_id": .string(keycloakId),
            "view": .string(view),
            "period": .string(period),
        ]
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }
        let params: JSONValue = .object(paramsDict)
        let response = try await client.send(method: "fetch_creator_sales", params: params, timeout: 30)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }
        return result
    }

    func fetchCreatorEarnings(keycloakId: String, view: String = "summary", accessToken: String? = nil) async throws -> [String: JSONValue] {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "keycloak_id": .string(keycloakId),
            "view": .string(view),
        ]
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }
        let params: JSONValue = .object(paramsDict)
        let response = try await client.send(method: "fetch_creator_earnings", params: params, timeout: 30)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }
        return result
    }

    func fetchCreatorCatalog(keycloakId: String, view: String = "summary", query: String = "", status: String = "", page: Int = 1, limit: Int = 50, accessToken: String? = nil) async throws -> [String: JSONValue] {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "keycloak_id": .string(keycloakId),
            "view": .string(view),
            "page": .number(Double(page)),
            "limit": .number(Double(limit)),
        ]
        if !query.isEmpty { paramsDict["q"] = .string(query) }
        if !status.isEmpty { paramsDict["status"] = .string(status) }
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }

        let response = try await client.send(method: "fetch_creator_catalog", params: .object(paramsDict), timeout: 30)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }
        return result
    }

    func fileDMCAClaim(
        keycloakId: String,
        trackId: String,
        reason: String,
        claimantName: String,
        claimantEmail: String,
        provenanceCertId: String = "",
        evidenceUrls: [String] = [],
        accessToken: String? = nil
    ) async throws -> [String: JSONValue] {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "keycloak_id": .string(keycloakId),
            "track_id": .string(trackId),
            "reason": .string(reason),
            "claimant_name": .string(claimantName),
            "claimant_email": .string(claimantEmail),
        ]
        if !provenanceCertId.isEmpty {
            paramsDict["provenance_cert_id"] = .string(provenanceCertId)
        }
        if !evidenceUrls.isEmpty {
            paramsDict["evidence_urls"] = .array(evidenceUrls.map { .string($0) })
        }
        if let accessToken, !accessToken.isEmpty { paramsDict["access_token"] = .string(accessToken) }

        let response = try await client.send(method: "file_dmca_claim", params: .object(paramsDict), timeout: 30)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }
        return result
    }

    // MARK: - Art Studio

    func checkArtStudioHealth() async throws -> (available: Bool, version: String?) {
        guard let client else { throw RPCClientError.processNotRunning }

        let response = try await client.send(method: "art_studio_health", params: .object([:]), timeout: 10)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }

        let available: Bool
        if case .bool(let val) = result["available"] {
            available = val
        } else {
            available = false
        }
        let version = result["version"]?.stringValue
        return (available, version)
    }

    func generateTrackArtwork(
        trackId: String, title: String, artist: String,
        album: String? = nil, genre: String? = nil, prompt: String? = nil
    ) async throws -> (imagePath: String, prompt: String) {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "track_id": .string(trackId),
            "title": .string(title),
            "artist": .string(artist),
        ]
        if let album, !album.isEmpty { paramsDict["album"] = .string(album) }
        if let genre, !genre.isEmpty { paramsDict["genre"] = .string(genre) }
        if let prompt, !prompt.isEmpty { paramsDict["prompt"] = .string(prompt) }

        let response = try await client.send(method: "generate_track_artwork", params: .object(paramsDict), timeout: 320)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }
        if let error = result["error"]?.stringValue {
            throw RPCClientError.serverError(RPCErrorPayload(code: -32010, message: error, data: nil))
        }

        let imagePath = result["local_path"]?.stringValue ?? result["image_path"]?.stringValue ?? ""
        let usedPrompt = result["prompt"]?.stringValue ?? ""
        return (imagePath, usedPrompt)
    }

    func generateAlbumArtwork(
        title: String, artist: String,
        genre: String? = nil, trackCount: Int? = nil, prompt: String? = nil
    ) async throws -> (imagePath: String, prompt: String) {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "title": .string(title),
            "artist": .string(artist),
        ]
        if let genre, !genre.isEmpty { paramsDict["genre"] = .string(genre) }
        if let trackCount { paramsDict["track_count"] = .number(Double(trackCount)) }
        if let prompt, !prompt.isEmpty { paramsDict["prompt"] = .string(prompt) }

        let response = try await client.send(method: "generate_album_artwork", params: .object(paramsDict), timeout: 320)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }
        if let error = result["error"]?.stringValue {
            throw RPCClientError.serverError(RPCErrorPayload(code: -32010, message: error, data: nil))
        }

        let imagePath = result["local_path"]?.stringValue ?? result["image_path"]?.stringValue ?? ""
        let usedPrompt = result["prompt"]?.stringValue ?? ""
        return (imagePath, usedPrompt)
    }

    func generateArtistArtwork(
        name: String, role: String? = nil, prompt: String? = nil
    ) async throws -> (imagePath: String, prompt: String) {
        guard let client else { throw RPCClientError.processNotRunning }

        var paramsDict: [String: JSONValue] = [
            "name": .string(name),
        ]
        if let role, !role.isEmpty { paramsDict["role"] = .string(role) }
        if let prompt, !prompt.isEmpty { paramsDict["prompt"] = .string(prompt) }

        let response = try await client.send(method: "generate_artist_artwork", params: .object(paramsDict), timeout: 320)

        guard case .object(let result)? = response.result else {
            throw RPCClientError.invalidResponse
        }
        if let error = result["error"]?.stringValue {
            throw RPCClientError.serverError(RPCErrorPayload(code: -32010, message: error, data: nil))
        }

        let imagePath = result["local_path"]?.stringValue ?? result["image_path"]?.stringValue ?? ""
        let usedPrompt = result["prompt"]?.stringValue ?? ""
        return (imagePath, usedPrompt)
    }
}

// MARK: - Result Structs

struct ProvenanceCertificate {
    let trackId: String
    let title: String
    let artist: String
    let publishedAt: String
    let provenanceHash: String
    let verificationUrl: String
}

struct ACEStepTestResult {
    let isWorking: Bool
    let path: String?
    let message: String?
}

struct RemoteACEStepTestResult {
    let success: Bool
    let message: String
}

struct ACEStepInstallResult {
    let success: Bool
    let status: String?
    let path: String?
    let error: String?
}

struct SystemInfo {
    let totalRAM: Double
    let availableDisk: Double
    let architecture: String
    let osVersion: String
}

struct LLMProviderInfo {
    let available: [String]
    let current: String
    let fallback: String?
    let models: [String: String]
}

private extension JSONValue {
    var description: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .object(let value):
            return String(describing: value)
        case .array(let value):
            return String(describing: value)
        case .null:
            return "null"
        }
    }
}
