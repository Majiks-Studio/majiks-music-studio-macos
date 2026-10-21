import Foundation

/// Swift HTTP client for ACE Music Cloud API (https://api.acemusic.ai).
/// Uses the native async REST API: submit task, poll for result, download audio.
/// Provides free cloud-based music generation using ACE-Step v1.5 without
/// requiring a local Python backend or GPU.
actor ACEMusicCloudService {
    nonisolated let apiKey: String
    private let baseURL: String
    private let session: URLSession

    /// When true, use the native async API (/release_task + /query_result).
    /// When false, use the OpenAI-compatible /v1/chat/completions endpoint.
    /// The public cloud at api.acemusic.ai only supports completions; self-hosted
    /// servers typically expose the native async API.
    private let useNativeAPI: Bool

    init(apiKey: String, baseURL: String = "https://api.acemusic.ai") {
        self.apiKey = apiKey
        let normalizedURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.baseURL = normalizedURL
        // Public ACE Music Cloud only supports /v1/chat/completions.
        // Self-hosted servers expose the native /release_task + /query_result flow.
        self.useNativeAPI = !normalizedURL.contains("acemusic.ai")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 660  // Up to 600s generation + overhead
        self.session = URLSession(configuration: config)
    }

    // MARK: - Native Async API Methods

    /// Submit a generation task to the ACE Music Cloud.
    /// Returns the task ID for polling.
    func submitTask(params: CloudGenerationParams) async throws -> String {
        guard let url = URL(string: "\(baseURL)/release_task") else {
            throw CloudGenerationError.invalidResponse("Invalid API URL for /release_task")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let body = params.toNativeRequestBody(apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudGenerationError.invalidResponse("Response is not valid JSON")
        }

        // Extract task_id from response
        if let taskId = json["task_id"] as? String {
            return taskId
        } else if let taskId = json["id"] as? String {
            return taskId
        }

        // Check for error in response
        if let error = json["error"] as? String {
            throw CloudGenerationError.generationFailed(error)
        }
        if let message = json["message"] as? String, message.lowercased().contains("error") {
            throw CloudGenerationError.generationFailed(message)
        }

        throw CloudGenerationError.invalidResponse("No task_id in response: \(json.keys.joined(separator: ", "))")
    }

    /// Query the result of a submitted task.
    func queryResult(taskId: String) async throws -> TaskResult {
        guard let url = URL(string: "\(baseURL)/query_result") else {
            throw CloudGenerationError.invalidResponse("Invalid API URL for /query_result")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let body: [String: Any] = ["task_ids": [taskId]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudGenerationError.invalidResponse("Response is not valid JSON")
        }

        // Response may contain the task result directly or nested under "results"
        let taskData: [String: Any]
        if let results = json["results"] as? [[String: Any]], let first = results.first {
            taskData = first
        } else if let results = json["results"] as? [String: [String: Any]], let first = results[taskId] {
            taskData = first
        } else {
            taskData = json
        }

        // Parse status: 0=queued, 2=processing, 1=success, -1=failed
        let statusRaw: Int
        if let s = taskData["status"] as? Int {
            statusRaw = s
        } else if let s = taskData["code"] as? Int {
            statusRaw = s
        } else {
            statusRaw = 0  // Default to queued if status not found
        }

        guard let status = CloudTaskStatus(rawValue: statusRaw) else {
            throw CloudGenerationError.invalidResponse("Unknown task status: \(statusRaw)")
        }

        // Extract audio paths
        var audioPaths: [String] = []
        if let paths = taskData["audio_paths"] as? [String] {
            audioPaths = paths
        } else if let path = taskData["audio_path"] as? String {
            audioPaths = [path]
        } else if let resultData = taskData["data"] as? [String: Any] {
            if let paths = resultData["audio_paths"] as? [String] {
                audioPaths = paths
            } else if let path = resultData["audio_path"] as? String {
                audioPaths = [path]
            }
        }

        // Extract metadata
        let duration = taskData["duration"] as? Double
            ?? (taskData["data"] as? [String: Any])?["duration"] as? Double
        let bpm = taskData["bpm"] as? Int
            ?? (taskData["data"] as? [String: Any])?["bpm"] as? Int
        let keyScale = taskData["key_scale"] as? String
            ?? (taskData["data"] as? [String: Any])?["key_scale"] as? String
        let error = taskData["error"] as? String
            ?? taskData["message"] as? String

        return TaskResult(
            status: status,
            audioPaths: audioPaths,
            duration: duration,
            bpm: bpm,
            keyScale: keyScale,
            error: status == .failed ? (error ?? "Unknown error") : nil
        )
    }

    /// Download audio from a remote path on the cloud server.
    func downloadAudio(remotePath: String, localDir: URL) async throws -> URL {
        guard var components = URLComponents(string: "\(baseURL)/v1/audio") else {
            throw CloudGenerationError.invalidResponse("Invalid API URL for /v1/audio")
        }
        components.queryItems = [URLQueryItem(name: "path", value: remotePath)]

        guard let url = components.url else {
            throw CloudGenerationError.invalidResponse("Could not construct audio download URL")
        }

        var request = URLRequest(url: url)
        request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard !data.isEmpty else {
            throw CloudGenerationError.emptyResponse
        }

        // Determine file extension from remote path or content type
        let ext: String
        if remotePath.hasSuffix(".flac") {
            ext = "flac"
        } else if remotePath.hasSuffix(".mp3") {
            ext = "mp3"
        } else if remotePath.hasSuffix(".wav") {
            ext = "wav"
        } else if let httpResponse = response as? HTTPURLResponse,
                  let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
            if contentType.contains("flac") { ext = "flac" }
            else if contentType.contains("mp3") || contentType.contains("mpeg") { ext = "mp3" }
            else { ext = "wav" }
        } else {
            ext = "wav"
        }

        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        // If the audio is WAV, save directly. Otherwise, save and convert.
        let outputURL: URL
        if ext == "wav" || isWAVData(data) {
            outputURL = localDir.appendingPathComponent("variant-1.wav")
            try data.write(to: outputURL)
        } else {
            // Save the original format, then convert to WAV using afconvert
            let tempFile = localDir.appendingPathComponent("temp-cloud.\(ext)")
            outputURL = localDir.appendingPathComponent("variant-1.wav")
            try data.write(to: tempFile)
            try await convertToWAV(inputPath: tempFile.path, outputPath: outputURL.path)
            try? FileManager.default.removeItem(at: tempFile)
        }

        return outputURL
    }

    /// Check server load statistics.
    func checkServerStats() async throws -> ServerStats {
        guard let url = URL(string: "\(baseURL)/v1/stats") else {
            throw CloudGenerationError.invalidResponse("Invalid API URL for /v1/stats")
        }

        var request = URLRequest(url: url)
        request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudGenerationError.invalidResponse("Stats response is not valid JSON")
        }

        let queueDepth = json["queue_depth"] as? Int
            ?? json["pending_tasks"] as? Int ?? 0
        let averageJobTime = json["average_job_time"] as? Double
            ?? json["avg_time"] as? Double ?? 0
        let activeJobs = json["active_jobs"] as? Int
            ?? json["running_tasks"] as? Int ?? 0

        return ServerStats(queueDepth: queueDepth, averageJobTime: averageJobTime, activeJobs: activeJobs)
    }

    /// List available models on the cloud server.
    func listModels() async throws -> [[String: Any]] {
        guard let url = URL(string: "\(baseURL)/v1/models") else {
            throw CloudGenerationError.invalidResponse("Invalid API URL for /v1/models")
        }

        var request = URLRequest(url: url)
        request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] ?? json["models"] as? [[String: Any]] else {
            return []
        }

        return models
    }

    /// List available model IDs as strings (e.g. "acemusic/acestep-v1.5-turbo").
    /// Returns an empty array if the query fails.
    func listModelIds() async -> [String] {
        do {
            let models = try await listModels()
            return models.compactMap { $0["id"] as? String }
        } catch {
            return []
        }
    }

    // MARK: - High-Level Generate (submit -> poll -> download)

    /// Generate music via ACE Music Cloud API.
    /// Routes between the native async flow (self-hosted servers) and the
    /// OpenAI-compatible /v1/chat/completions endpoint (public cloud).
    /// Returns the local WAV file URL and metadata dictionary.
    ///
    /// This method maintains the same signature as the original sync implementation
    /// so callers do not need to change.
    func generate(
        parameters: CloudGenerationParams,
        outputDir: URL,
        progressCallback: (@Sendable (String, Double, String) -> Void)? = nil
    ) async throws -> (URL, [String: String]) {
        if useNativeAPI {
            return try await generateViaNativeAPI(
                parameters: parameters,
                outputDir: outputDir,
                progressCallback: progressCallback
            )
        } else {
            return try await generateViaCompletions(
                parameters: parameters,
                outputDir: outputDir,
                progressCallback: progressCallback
            )
        }
    }

    // MARK: - Native Async Flow (self-hosted servers)

    /// Generate via the native /release_task + /query_result + /v1/audio flow.
    private func generateViaNativeAPI(
        parameters: CloudGenerationParams,
        outputDir: URL,
        progressCallback: (@Sendable (String, Double, String) -> Void)? = nil
    ) async throws -> (URL, [String: String]) {
        // 1. Submit task
        progressCallback?("submitting", 5, "Submitting to ACE Music Cloud...")
        let taskId = try await submitTask(params: parameters)
        progressCallback?("submitted", 10, "Task submitted, waiting for generation...")

        // 2. Poll for result
        let pollInterval: UInt64 = 2_500_000_000  // 2.5 seconds
        let maxPollTime: TimeInterval = 660  // 11 minutes max
        let expectedDuration = Double(parameters.duration)
        let startTime = Date()

        var audioPaths: [String] = []
        var resultMetadata: (duration: Double?, bpm: Int?, keyScale: String?) = (nil, nil, nil)

        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: pollInterval)

            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > maxPollTime {
                throw CloudGenerationError.timeout
            }

            let result = try await queryResult(taskId: taskId)

            switch result.status {
            case .queued:
                let waitProgress = min(0.15, elapsed / maxPollTime * 0.15)
                progressCallback?("queued", 10 + waitProgress * 100, "Queued on ACE Music Cloud...")

            case .processing:
                // Estimate progress based on elapsed time vs expected generation time
                // Cloud generation typically takes 1.5-3x the audio duration
                let estimatedTotal = max(expectedDuration * 2.0, 30)
                let ratio = min(0.85, elapsed / estimatedTotal)
                let percent = 15 + ratio * 65  // Map to 15-80%
                progressCallback?("generating", percent, "Generating on ACE Music Cloud...")

            case .success:
                audioPaths = result.audioPaths
                resultMetadata = (result.duration, result.bpm, result.keyScale)
                break

            case .failed:
                throw CloudGenerationError.generationFailed(result.error ?? "Cloud generation failed")
            }

            // Break out of the while loop on success
            if result.status == .success {
                break
            }
        }

        // 3. Download audio
        progressCallback?("downloading", 85, "Downloading audio from cloud...")

        let outputURL: URL
        if let firstPath = audioPaths.first, !firstPath.isEmpty {
            outputURL = try await downloadAudio(remotePath: firstPath, localDir: outputDir)
        } else {
            throw CloudGenerationError.invalidResponse("No audio paths returned in successful task result")
        }

        progressCallback?("saved", 95, "Audio saved")

        // 4. Build metadata
        var metadata: [String: String] = [
            "file_path": outputURL.path,
            "generated_by": "ace-music-cloud",
            "cloud_task_id": taskId,
            "caption": parameters.caption,
            "model": parameters.model.isEmpty ? "acemusic/acestep-v15-turbo" : parameters.model,
        ]

        if let bpm = parameters.bpm { metadata["bpm"] = "\(bpm)" }
        if let bpm = resultMetadata.bpm { metadata["bpm"] = "\(bpm)" }
        if let key = parameters.key { metadata["key"] = key }
        if let key = resultMetadata.keyScale { metadata["key"] = key }
        if !parameters.lyrics.isEmpty { metadata["lyrics"] = parameters.lyrics }
        if let dur = resultMetadata.duration { metadata["duration"] = "\(dur)" }
        if parameters.audioFormat != "wav" { metadata["cloud_format"] = parameters.audioFormat }

        progressCallback?("done", 100, "Generation complete")

        return (outputURL, metadata)
    }

    // MARK: - Completions Flow (public ACE Music Cloud)

    /// Generate via the OpenAI-compatible /v1/chat/completions endpoint.
    /// The public cloud at api.acemusic.ai only supports this endpoint.
    /// Returns the audio as base64 in the response — no polling needed.
    private func generateViaCompletions(
        parameters: CloudGenerationParams,
        outputDir: URL,
        progressCallback: (@Sendable (String, Double, String) -> Void)? = nil
    ) async throws -> (URL, [String: String]) {
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw CloudGenerationError.invalidResponse("Invalid API URL for /v1/chat/completions")
        }

        progressCallback?("generating", 0, "Generating on ACE Music Cloud...")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // Completions can take a long time for long durations
        request.timeoutInterval = TimeInterval(max(parameters.duration * 4, 180))

        let body = parameters.toCompletionsRequestBody()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        progressCallback?("processing", 80, "Processing response...")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudGenerationError.invalidResponse("Completions response is not valid JSON")
        }

        // Parse: choices[0].message.audio[0].audio_url.url
        guard let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            // Check for top-level error
            if let error = json["error"] as? [String: Any],
               let errorMessage = error["message"] as? String {
                throw CloudGenerationError.generationFailed(errorMessage)
            }
            if let error = json["error"] as? String {
                throw CloudGenerationError.generationFailed(error)
            }
            throw CloudGenerationError.invalidResponse(
                "No choices in completions response: \(json.keys.sorted().joined(separator: ", "))")
        }

        // Extract base64 audio from the response
        // Format: choices[0].message.audio[0].audio_url.url = "data:audio/mpeg;base64,..."
        guard let audioArray = message["audio"] as? [[String: Any]],
              let firstAudio = audioArray.first,
              let audioURLObj = firstAudio["audio_url"] as? [String: Any],
              let dataURLString = audioURLObj["url"] as? String else {
            throw CloudGenerationError.invalidResponse(
                "No audio data in completions response. Message keys: \(message.keys.sorted().joined(separator: ", "))")
        }

        // Strip the data URI prefix (e.g. "data:audio/mpeg;base64,")
        let base64String: String
        let audioMIME: String
        if let commaIndex = dataURLString.firstIndex(of: ",") {
            let prefix = String(dataURLString[dataURLString.startIndex..<commaIndex])
            base64String = String(dataURLString[dataURLString.index(after: commaIndex)...])
            // Extract MIME type from prefix like "data:audio/mpeg;base64"
            if prefix.hasPrefix("data:") {
                let mimeStart = prefix.index(prefix.startIndex, offsetBy: 5)
                let mimeEnd = prefix.firstIndex(of: ";") ?? prefix.endIndex
                audioMIME = String(prefix[mimeStart..<mimeEnd])
            } else {
                audioMIME = "audio/mpeg"
            }
        } else {
            // No data URI prefix — treat as raw base64
            base64String = dataURLString
            audioMIME = "audio/mpeg"
        }

        guard let audioData = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
            throw CloudGenerationError.invalidResponse("Failed to decode base64 audio data (\(base64String.count) chars)")
        }

        guard !audioData.isEmpty else {
            throw CloudGenerationError.emptyResponse
        }

        progressCallback?("saving", 90, "Saving audio...")

        // Determine format from MIME and save
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL: URL

        if isWAVData(audioData) {
            // Already WAV — save directly
            outputURL = outputDir.appendingPathComponent("variant-1.wav")
            try audioData.write(to: outputURL)
        } else {
            // MP3 or other format — save temp file and convert to WAV via afconvert
            let ext: String
            if audioMIME.contains("wav") { ext = "wav" }
            else if audioMIME.contains("flac") { ext = "flac" }
            else { ext = "mp3" }  // Default to mp3 for audio/mpeg

            let tempFile = outputDir.appendingPathComponent("temp-cloud.\(ext)")
            outputURL = outputDir.appendingPathComponent("variant-1.wav")
            try audioData.write(to: tempFile)
            try await convertToWAV(inputPath: tempFile.path, outputPath: outputURL.path)
            try? FileManager.default.removeItem(at: tempFile)
        }

        // Build metadata
        let modelUsed = parameters.model.isEmpty ? "acemusic/acestep-v1.5-turbo" : parameters.model
        var metadata: [String: String] = [
            "file_path": outputURL.path,
            "generated_by": "ace-music-cloud",
            "caption": parameters.caption,
            "model": modelUsed,
        ]

        if let bpm = parameters.bpm { metadata["bpm"] = "\(bpm)" }
        if let key = parameters.key { metadata["key"] = key }
        if !parameters.lyrics.isEmpty { metadata["lyrics"] = parameters.lyrics }
        metadata["duration"] = "\(parameters.duration)"
        metadata["cloud_api"] = "completions"

        progressCallback?("done", 100, "Generation complete")

        return (outputURL, metadata)
    }

    /// Test the API connection.
    /// For native API servers: tries /v1/stats first, falls back to /health.
    /// For completions-only servers (public cloud): tries /v1/models.
    func testConnection() async throws -> String {
        if useNativeAPI {
            // Self-hosted: try /v1/stats first (lightweight health check)
            if let statsURL = URL(string: "\(baseURL)/v1/stats") {
                var request = URLRequest(url: statsURL)
                request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")
                if !apiKey.isEmpty {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                request.timeoutInterval = 15

                do {
                    let (data, response) = try await session.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse,
                       (200...299).contains(httpResponse.statusCode) {
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            let queueDepth = json["queue_depth"] as? Int ?? json["pending_tasks"] as? Int
                            if let depth = queueDepth {
                                return "Connected to ACE Music Cloud (queue: \(depth) jobs)"
                            }
                        }
                        return "Connected to ACE Music Cloud (HTTP \(httpResponse.statusCode))"
                    } else if let httpResponse = response as? HTTPURLResponse,
                              httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                        throw CloudGenerationError.authenticationFailed("Invalid API key (HTTP \(httpResponse.statusCode))")
                    }
                } catch let error as CloudGenerationError {
                    throw error
                } catch {
                    // Fall through to /health
                }
            }

            // Fallback: try /health
            if let healthURL = URL(string: "\(baseURL)/health") {
                var request = URLRequest(url: healthURL)
                request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 15

                let (_, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) {
                    return "Connected to ACE Music Cloud (HTTP \(httpResponse.statusCode))"
                }
            }
        } else {
            // Public cloud (completions-only): try /v1/models
            if let modelsURL = URL(string: "\(baseURL)/v1/models") {
                var request = URLRequest(url: modelsURL)
                request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")
                if !apiKey.isEmpty {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                request.timeoutInterval = 15

                do {
                    let (data, response) = try await session.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                            throw CloudGenerationError.authenticationFailed("Invalid API key (HTTP \(httpResponse.statusCode))")
                        }
                        if (200...299).contains(httpResponse.statusCode) {
                            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let models = json["data"] as? [[String: Any]] {
                                return "Connected to ACE Music Cloud (\(models.count) models, completions API)"
                            }
                            return "Connected to ACE Music Cloud (completions API)"
                        }
                    }
                } catch let error as CloudGenerationError {
                    throw error
                } catch {
                    // Fall through to generic error
                }
            }
        }

        throw CloudGenerationError.invalidResponse("Could not reach ACE Music Cloud API")
    }

    // MARK: - Helpers

    /// Check if data starts with WAV header ("RIFF....WAVE")
    private func isWAVData(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let header = data.prefix(4)
        let format = data[8..<12]
        return header == Data([0x52, 0x49, 0x46, 0x46])  // "RIFF"
            && format == Data([0x57, 0x41, 0x56, 0x45])   // "WAVE"
    }

    /// Convert audio to WAV using macOS built-in afconvert (no ffmpeg needed).
    private func convertToWAV(inputPath: String, outputPath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [inputPath, outputPath, "-d", "LEI16", "-f", "WAVE"]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw CloudGenerationError.conversionFailed("afconvert failed (\(process.terminationStatus)): \(errorMessage)")
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw CloudGenerationError.conversionFailed("afconvert produced no output file")
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudGenerationError.invalidResponse("Not an HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw CloudGenerationError.authenticationFailed("Invalid API key (HTTP \(httpResponse.statusCode))")
            }
            throw CloudGenerationError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }
}

// MARK: - Cloud Generation Parameters

struct CloudGenerationParams {
    // Core parameters
    var caption: String  // Style/tags description (prompt)
    var lyrics: String = ""
    var instrumental: Bool = true
    var duration: Int = 60  // 10-600 seconds (native API supports up to 600)
    var bpm: Int? = nil  // 30-300
    var key: String? = nil  // e.g. "E minor", "C major"

    // Generation settings
    var seed: Int? = nil
    var inferenceSteps: Int = 8
    var guidanceScale: Double = 4.5
    var shift: Double? = nil
    var inferMethod: String? = nil  // e.g. "euler", "dpm"

    // Language model settings
    var thinking: Bool = false  // Enable chain-of-thought in LM
    var useFormat: Bool = true  // Enable LM prompt enhancement
    var constrainedDecoding: Bool = false
    var lmTemperature: Double = 0.9
    var lmCfgScale: Double = 2.5
    var lmTopP: Double? = nil

    // Audio settings
    var audioFormat: String = "flac"  // "flac", "mp3", "wav"
    var batchSize: Int = 1  // Number of variants
    var vocalLanguage: String = ""  // en, zh, ja, ko, etc.
    var timeSignature: String = "4"  // "2", "3", "4", "6"

    // Model selection
    var model: String = ""  // DiT model name (empty = server default)
    var lmModel: String = ""  // LM model name (empty = server default)

    // Task type and advanced modes
    var taskType: String = "text2music"  // text2music, cover, repaint, extract, lego, complete
    var referenceAudioPath: String = ""  // For cover/style transfer
    var sourceAudioPath: String = ""  // For continuation/repaint
    var repaintStart: Double? = nil
    var repaintEnd: Double? = nil
    var coverStrength: Double? = nil  // 0.0-1.0

    /// Build the JSON request body for the native /release_task API.
    func toNativeRequestBody(apiKey: String) -> [String: Any] {
        var body: [String: Any] = [
            "prompt": caption,
            "audio_duration": min(max(duration, 10), 600),
            "task_type": taskType,
            "batch_size": batchSize,
            "inference_steps": inferenceSteps,
            "guidance_scale": guidanceScale,
            "audio_format": audioFormat,
            "thinking": thinking,
            "use_format": useFormat,
            "constrained_decoding": constrainedDecoding,
            "lm_temperature": lmTemperature,
            "lm_cfg_scale": lmCfgScale,
        ]

        // Include API key in body if set (some endpoints use this instead of header)
        if !apiKey.isEmpty {
            body["ai_token"] = apiKey
        }

        // Lyrics
        if !lyrics.isEmpty {
            body["lyrics"] = lyrics
        }

        // Optional numeric parameters
        if let bpm { body["bpm"] = bpm }
        if let key { body["key_scale"] = key }
        if let seed { body["seed"] = seed }
        if let shift { body["shift"] = shift }
        if let lmTopP { body["lm_top_p"] = lmTopP }

        // String parameters (only include if non-empty)
        if !vocalLanguage.isEmpty { body["vocal_language"] = vocalLanguage }
        if !timeSignature.isEmpty { body["time_signature"] = timeSignature }
        if let inferMethod, !inferMethod.isEmpty { body["infer_method"] = inferMethod }

        // Model selection
        if !model.isEmpty { body["model"] = model }
        if !lmModel.isEmpty { body["lm_model_path"] = lmModel }

        // Mode-specific parameters
        if !referenceAudioPath.isEmpty { body["reference_audio_path"] = referenceAudioPath }
        if !sourceAudioPath.isEmpty { body["source_audio_path"] = sourceAudioPath }
        if let repaintStart { body["repaint_start"] = repaintStart }
        if let repaintEnd { body["repaint_end"] = repaintEnd }
        if let coverStrength { body["cover_strength"] = coverStrength }

        return body
    }

    /// Build the JSON request body for the /v1/chat/completions endpoint.
    /// Uses an OpenAI-compatible format with additional ACE-Step parameters.
    func toCompletionsRequestBody() -> [String: Any] {
        // Build the user message content: style prompt + optional lyrics
        let fullContent: String
        if lyrics.isEmpty {
            fullContent = caption
        } else {
            fullContent = "\(caption)\nLyrics:\n\(lyrics)"
        }

        var body: [String: Any] = [
            "model": model.isEmpty ? "acemusic/acestep-v1.5-turbo" : model,
            "messages": [
                ["role": "user", "content": fullContent]
            ],
            "audio_duration": min(max(duration, 10), 600),
        ]

        // Optional parameters — only include if set
        if let bpm { body["bpm"] = bpm }
        if let key { body["key_scale"] = key }
        if let seed { body["seed"] = seed }
        if inferenceSteps != 8 { body["inference_steps"] = inferenceSteps }
        if guidanceScale != 4.5 { body["guidance_scale"] = guidanceScale }
        if let shift { body["shift"] = shift }
        if let inferMethod, !inferMethod.isEmpty { body["infer_method"] = inferMethod }
        if thinking { body["thinking"] = true }
        if !useFormat { body["use_format"] = false }
        if constrainedDecoding { body["constrained_decoding"] = true }
        if lmTemperature != 0.9 { body["lm_temperature"] = lmTemperature }
        if lmCfgScale != 2.5 { body["lm_cfg_scale"] = lmCfgScale }
        if let lmTopP { body["lm_top_p"] = lmTopP }
        if !vocalLanguage.isEmpty { body["vocal_language"] = vocalLanguage }
        if !timeSignature.isEmpty && timeSignature != "4" { body["time_signature"] = timeSignature }
        if batchSize > 1 { body["batch_size"] = batchSize }
        if taskType != "text2music" { body["task_type"] = taskType }
        if instrumental { body["instrumental"] = true }
        if !lmModel.isEmpty { body["lm_model_path"] = lmModel }

        return body
    }
}

// MARK: - Cloud Task Types

enum CloudTaskStatus: Int, Sendable {
    case queued = 0
    case success = 1
    case processing = 2
    case failed = -1
}

struct TaskResult: Sendable {
    let status: CloudTaskStatus
    let audioPaths: [String]
    let duration: Double?
    let bpm: Int?
    let keyScale: String?
    let error: String?
}

struct ServerStats: Sendable {
    let queueDepth: Int
    let averageJobTime: Double
    let activeJobs: Int
}

// MARK: - Cloud Generation Errors

enum CloudGenerationError: LocalizedError {
    case invalidResponse(String)
    case httpError(statusCode: Int, body: String)
    case authenticationFailed(String)
    case generationFailed(String)
    case conversionFailed(String)
    case timeout
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .authenticationFailed(let msg): return "Authentication failed: \(msg)"
        case .generationFailed(let msg): return "Cloud generation failed: \(msg)"
        case .conversionFailed(let msg): return "Audio conversion failed: \(msg)"
        case .timeout: return "Cloud generation timed out (exceeded 11 minutes)"
        case .emptyResponse: return "Empty response from cloud API"
        }
    }
}
