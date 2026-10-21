import Foundation

/// Canonical, reusable logic for managing on-disk generation models (ACE-Step
/// DiT) and the stem separation model (htdemucs). This is the single place that
/// resolves model paths, downloads, removes, and measures disk use, so the
/// Manage Models pane and the LLM & Models tab share one mechanism instead of
/// competing copies.
///
/// Download state is published through the existing `DownloadManager.shared`
/// singleton (DiT fields). Generation downloads reuse the same huggingface-cli
/// invocation the app already uses; the stem model is fetched by the demucs
/// Python package on first separation, so this store only detects, measures,
/// and removes its weights.
enum GenerationModelStore {

    // MARK: - Errors

    enum ModelStoreError: LocalizedError {
        case aceStepNotConfigured
        case pathUnsafe(String)
        case notInstalled(String)
        case nothingToRemove

        var errorDescription: String? {
            switch self {
            case .aceStepNotConfigured:
                return "ACE-Step is not installed. Install it from the LLM and Models tab first."
            case .pathUnsafe(let path):
                return "Refused to remove a path outside the model directory: \(path)"
            case .notInstalled(let name):
                return "\(name) is not installed."
            case .nothingToRemove:
                return "There is nothing to remove."
            }
        }
    }

    // MARK: - Generation (ACE-Step DiT) model paths

    /// The parent directory that holds per-model checkpoint folders.
    /// Mirrors the existing download logic: prefer `<aceStepPath>/checkpoints`
    /// when it exists, otherwise the ACE-Step path itself.
    static func modelsBaseDir(aceStepPath: String) -> URL? {
        guard !aceStepPath.isEmpty else { return nil }
        let base = URL(fileURLWithPath: aceStepPath)
        let checkpoints = base.appendingPathComponent("checkpoints")
        if FileManager.default.fileExists(atPath: checkpoints.path) {
            return checkpoints
        }
        return base
    }

    /// The directory a specific model is installed in, if present. Checks both
    /// `<aceStepPath>/checkpoints/<id>` and `<aceStepPath>/<id>`.
    static func installedModelDir(id: String, aceStepPath: String) -> URL? {
        guard !aceStepPath.isEmpty else { return nil }
        let base = URL(fileURLWithPath: aceStepPath)
        let nested = base.appendingPathComponent("checkpoints").appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        let direct = base.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        return nil
    }

    static func isInstalled(id: String, aceStepPath: String) -> Bool {
        installedModelDir(id: id, aceStepPath: aceStepPath) != nil
    }

    /// On-disk size of an installed generation model, or 0 if not installed.
    static func installedSize(id: String, aceStepPath: String) -> Int64 {
        guard let dir = installedModelDir(id: id, aceStepPath: aceStepPath) else { return 0 }
        return directorySize(at: dir)
    }

    // MARK: - Generation model download

    /// Download a DiT model with the same huggingface-cli mechanism the app
    /// already uses, publishing progress through `DownloadManager.shared`.
    /// `onComplete` runs on the main actor after the attempt so callers can
    /// refresh their local size/status caches.
    @MainActor
    static func download(
        model: LLMSettingsView.DiTModelInfo,
        aceStepPath: String,
        onComplete: (@MainActor () -> Void)? = nil
    ) {
        DownloadManager.shared.startDiTDownload(modelId: model.id)

        Task.detached(priority: .userInitiated) {
            guard !aceStepPath.isEmpty else {
                await MainActor.run {
                    DownloadManager.shared.completeDiTDownload(
                        modelId: model.id, success: false,
                        error: "ACE-Step path not configured")
                    onComplete?()
                }
                return
            }

            guard let targetParent = modelsBaseDir(aceStepPath: aceStepPath) else {
                await MainActor.run {
                    DownloadManager.shared.completeDiTDownload(
                        modelId: model.id, success: false,
                        error: "Could not resolve the model directory")
                    onComplete?()
                }
                return
            }
            let localDir = targetParent.appendingPathComponent(model.id).path

            await MainActor.run {
                DownloadManager.shared.updateDiTProgress("Downloading \(model.displayName)...")
            }

            // No silent last resort. The old `else` branch spawned
            // `/usr/bin/env python3` — on a customer's Mac that is the system
            // Python, which has no huggingface_hub, so the download failed with
            // a traceback instead of a sentence. If we have no interpreter we
            // can vouch for, say which one is missing and stop.
            guard let hf = huggingFaceDownloadCommand(aceStepPath: aceStepPath) else {
                await MainActor.run {
                    DownloadManager.shared.completeDiTDownload(
                        modelId: model.id, success: false,
                        error: "No usable Python was found to download with. The app's bundled "
                             + "interpreter (Contents/Frameworks/Python.framework/Versions/3.12/bin/python3.12) "
                             + "is missing or not executable — reinstall Majiks Music Studio.")
                    onComplete?()
                }
                return
            }

            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: hf.executable)
            process.arguments = hf.argPrefix + [
                model.huggingFaceRepo, "--local-dir", localDir, "--local-dir-use-symlinks", "False"
            ]
            process.standardOutput = outPipe
            process.standardError = errPipe
            // Never let a spawned Python write .pyc into the signed bundle; that
            // invalidates the code-signature seal.
            var env = ProcessInfo.processInfo.environment
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            process.environment = env

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                await MainActor.run {
                    DownloadManager.shared.completeDiTDownload(
                        modelId: model.id, success: false,
                        error: error.localizedDescription)
                    onComplete?()
                }
                return
            }

            if process.terminationStatus == 0 {
                await MainActor.run {
                    DownloadManager.shared.completeDiTDownload(modelId: model.id, success: true)
                    onComplete?()
                }
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errString = String(data: errData, encoding: .utf8) ?? "Unknown error"
                let lastLine = errString.split(separator: "\n").last.map(String.init) ?? errString
                await MainActor.run {
                    DownloadManager.shared.completeDiTDownload(
                        modelId: model.id, success: false, error: lastLine)
                    onComplete?()
                }
            }
        }
    }

    /// The bundled Python interpreter, if we are running from a .app that
    /// carries one. This is the only interpreter a shipped build may assume.
    static func bundledInterpreter() -> String? {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else { return nil }
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.12/bin/python3.12")
            .path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// How to run `huggingface-cli download`: an executable plus the argument
    /// prefix that turns it into that command.
    ///
    /// ⚠️ This used to look for `/opt/homebrew/bin/huggingface-cli` before
    /// anything else, which is a path that exists on the machine that builds
    /// the app and on no machine that installs it. That is worse than having no
    /// fallback: on the dev box it works, so nobody sees that the shipped app
    /// then drops to `/usr/bin/env python3` — the macOS system Python, which
    /// has never had huggingface_hub — and every model download dies with an
    /// ImportError the user cannot act on.
    ///
    /// The bundle ships huggingface_hub in its own site-packages, so the
    /// bundled interpreter's `-m huggingface_hub.commands.huggingface_cli` is
    /// both the correct answer and the one that needs no console script, no
    /// shebang and no PATH.
    static func huggingFaceDownloadCommand(aceStepPath: String) -> (executable: String, argPrefix: [String])? {
        let fm = FileManager.default

        // 1. The bundle's own interpreter. In a shipped app this is the answer.
        if let python = bundledInterpreter() {
            return (python, ["-m", "huggingface_hub.commands.huggingface_cli", "download"])
        }

        // 2. A user-configured ACE-Step venv — a real path the user chose.
        if !aceStepPath.isEmpty {
            let venvCli = URL(fileURLWithPath: aceStepPath).appendingPathComponent(".venv/bin/huggingface-cli").path
            if fm.isExecutableFile(atPath: venvCli) { return (venvCli, ["download"]) }
            let venvPython = URL(fileURLWithPath: aceStepPath).appendingPathComponent(".venv/bin/python").path
            if fm.isExecutableFile(atPath: venvPython) {
                return (venvPython, ["-m", "huggingface_hub.commands.huggingface_cli", "download"])
            }
        }

        // 3. Developer checkout only (not a .app): whatever this machine has.
        //    Never reached in a shipped build, because step 1 always answers.
        //
        //    ⚠️ #if DEBUG, not just a runtime check. A literal is emitted into
        //    the binary's string table whether or not its branch executes, so a
        //    runtime-guarded "/opt/homebrew/bin/huggingface-cli" still ships
        //    inside the release binary — which is how the shipped 3.5.0 app
        //    came to name a Homebrew path it could never use. The build gate
        //    reads that string table and refuses it.
        #if DEBUG
        if Bundle.main.bundleURL.pathExtension.lowercased() != "app" {
            for path in ["/opt/homebrew/bin/huggingface-cli", "/usr/local/bin/huggingface-cli"] {
                if fm.isExecutableFile(atPath: path) { return (path, ["download"]) }
            }
            let userCli = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/huggingface-cli").path
            if fm.isExecutableFile(atPath: userCli) { return (userCli, ["download"]) }
        }
        #endif

        return nil
    }

    // MARK: - Generation model removal

    /// Remove an installed generation model's weights. Returns the number of
    /// bytes reclaimed. Deletes ONLY the model's own folder inside the resolved
    /// ACE-Step model directory, never a user path and never Studio Storage.
    @discardableResult
    static func removeGenerationModel(id: String, aceStepPath: String) throws -> Int64 {
        guard !aceStepPath.isEmpty else { throw ModelStoreError.aceStepNotConfigured }
        guard let target = installedModelDir(id: id, aceStepPath: aceStepPath) else {
            throw ModelStoreError.notInstalled(id)
        }
        // The target must be a folder named exactly for this model, sitting
        // strictly inside the ACE-Step install (covers both the checkpoints/<id>
        // and <id> layouts). Never a user path, never Studio Storage.
        let root = URL(fileURLWithPath: aceStepPath)
        guard target.lastPathComponent == id,
              isDeletionSafe(target, mustBeStrictlyUnder: root) else {
            throw ModelStoreError.pathUnsafe(target.path)
        }
        let freed = directorySize(at: target)
        try FileManager.default.removeItem(at: target)
        return freed
    }

    // MARK: - Stem (htdemucs) model

    /// Where demucs / torch.hub caches separation model weights.
    static func stemCheckpointsDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/torch/hub/checkpoints")
    }

    /// The demucs weight files (`.th`) currently cached, with their sizes.
    static func stemWeightFiles() -> [(url: URL, size: Int64)] {
        let dir = stemCheckpointsDir()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "th" }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return (url: url, size: Int64(size))
            }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    static func stemInstalled() -> Bool { !stemWeightFiles().isEmpty }

    static func stemTotalSize() -> Int64 { stemWeightFiles().reduce(0) { $0 + $1.size } }

    /// Remove the cached demucs weight files. Returns bytes reclaimed. Deletes
    /// ONLY `.th` files inside the torch hub checkpoints directory.
    @discardableResult
    static func removeStemWeights() throws -> Int64 {
        let files = stemWeightFiles()
        guard !files.isEmpty else { throw ModelStoreError.nothingToRemove }
        let base = stemCheckpointsDir()
        var freed: Int64 = 0
        for file in files {
            guard file.url.pathExtension.lowercased() == "th",
                  isDeletionSafe(file.url, mustBeStrictlyUnder: base) else {
                throw ModelStoreError.pathUnsafe(file.url.path)
            }
            try FileManager.default.removeItem(at: file.url)
            freed += file.size
        }
        return freed
    }

    // MARK: - Safety + sizing

    /// True only when `target` sits strictly inside `base`, is not the user
    /// home or filesystem root, and touches nothing under Studio Storage.
    static func isDeletionSafe(_ target: URL, mustBeStrictlyUnder base: URL) -> Bool {
        let t = target.standardizedFileURL.resolvingSymlinksInPath().path
        let b = base.standardizedFileURL.resolvingSymlinksInPath().path
        let forbidden = "/Volumes/Studio Storage"
        if t == forbidden || t.hasPrefix(forbidden + "/") { return false }
        if b == forbidden || b.hasPrefix(forbidden + "/") { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        if t == home || t == "/" || t.isEmpty { return false }
        // Strictly inside base (never base itself).
        return t.hasPrefix(b + "/") && t != b
    }

    /// Recursive on-disk size of a file or directory.
    static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return Int64(size)
        }
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  let isDirectory = values.isDirectory, !isDirectory,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// Human-readable byte count, matching the app's other size labels.
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
