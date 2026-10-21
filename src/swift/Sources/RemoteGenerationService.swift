import Foundation

/// Swift HTTP client for direct communication with the remote ACE-Step generation server.
/// Enables "Both" mode where local generation goes through Python and remote goes through Swift simultaneously.
actor RemoteGenerationService {
    nonisolated let serverURL: String
    nonisolated let apiKey: String
    private let session: URLSession

    init(serverURL: String, apiKey: String) {
        self.serverURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    // MARK: - API Methods

    /// Submit a generation job to the remote server
    func submitJob(parameters: RemoteGenerationParams) async throws -> String {
        let urlString = "\(serverURL)/api/v1/studio/generate"
        guard let url = URL(string: urlString) else {
            throw RemoteGenerationError.invalidURL("Invalid server URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = ["params": parameters.toDictionary()]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobId = json["id"] as? String ?? json["job_id"] as? String else {
            throw RemoteGenerationError.invalidResponse("No job ID in response")
        }

        return jobId
    }

    /// Poll a job for status
    func pollJob(jobId: String) async throws -> RemoteJobStatus {
        let urlString = "\(serverURL)/api/v1/studio/jobs/\(jobId)"
        guard let url = URL(string: urlString) else {
            throw RemoteGenerationError.invalidURL("Invalid server URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteGenerationError.invalidResponse("Invalid JSON in poll response")
        }

        let status = (json["status"] as? String ?? "").lowercased()

        switch status {
        case "completed", "complete":
            // Extract metadata from result.variants[].metadata if available
            var serverMetadata: [String: String] = [:]
            if let result = json["result"] as? [String: Any],
               let variants = result["variants"] as? [[String: Any]],
               let firstVariant = variants.first,
               let meta = firstVariant["metadata"] as? [String: Any] {
                for (key, value) in meta {
                    serverMetadata[key] = "\(value)"
                }
            }
            return .completed(metadata: serverMetadata)
        case "failed", "error":
            let errorMsg = json["error"] as? String ?? json["message"] as? String ?? "Unknown error"
            return .failed(message: errorMsg)
        default:
            return .running(status: status)
        }
    }

    /// Download audio for a completed job
    func downloadAudio(jobId: String, variant: Int = 0) async throws -> Data {
        let urlString = "\(serverURL)/api/v1/studio/jobs/\(jobId)/audio?variant=\(variant)"
        guard let url = URL(string: urlString) else {
            throw RemoteGenerationError.invalidURL("Invalid server URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard !data.isEmpty else {
            throw RemoteGenerationError.emptyResponse
        }

        return data
    }

    /// Save a generated track to the server's library
    func saveToServerLibrary(jobId: String, metadata: [String: Any]? = nil) async throws {
        let urlString = "\(serverURL)/api/v1/studio/jobs/\(jobId)/save"
        guard let url = URL(string: urlString) else {
            throw RemoteGenerationError.invalidURL("Invalid server URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")

        if let metadata {
            request.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        }

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
    }

    /// List available models on the remote server.
    /// Returns model ID strings (e.g. "acestep-v15-turbo").
    /// Returns an empty array if the query fails or the endpoint is not supported.
    func listModels() async -> [String] {
        let urlString = "\(serverURL)/v1/models"
        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("MajiksMusicStudio/3.2.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] ?? json["models"] as? [[String: Any]] else {
                return []
            }
            return models.compactMap { $0["id"] as? String }
        } catch {
            return []
        }
    }

    /// Full generation pipeline: submit → poll → download → save locally + optionally to server
    func generate(
        parameters: RemoteGenerationParams,
        outputDir: URL,
        saveToServer: Bool = true,
        progressCallback: (@Sendable (String, Double, String) -> Void)? = nil
    ) async throws -> (URL, [String: String]) {
        // 1. Submit
        progressCallback?("submitting", 5, "Submitting to remote server...")
        let jobId = try await submitJob(parameters: parameters)
        progressCallback?("generating", 10, "Job submitted, generating...")

        // 2. Poll
        let pollTimeout: TimeInterval = 300 + Double(parameters.duration) * 180
        let deadline = Date().addingTimeInterval(pollTimeout)
        var completionMetadata: [String: String] = [:]
        var jobCompleted = false

        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            let status = try await pollJob(jobId: jobId)
            switch status {
            case .completed(let metadata):
                completionMetadata = metadata
                jobCompleted = true
            case .failed(let message):
                throw RemoteGenerationError.generationFailed(message)
            case .running(let statusStr):
                let elapsed = Date().timeIntervalSince(deadline.addingTimeInterval(-pollTimeout))
                let ratio = min(0.9, elapsed / pollTimeout)
                let percent = 10 + ratio * 70
                progressCallback?("generating", percent, "Generating on remote server (\(statusStr))...")
                continue
            }
            break
        }

        guard jobCompleted else {
            throw RemoteGenerationError.timeout("Generation timed out after \(Int(pollTimeout)) seconds")
        }

        // 3. Download
        progressCallback?("downloading", 85, "Downloading audio...")
        let audioData = try await downloadAudio(jobId: jobId)

        // 4. Save locally
        let fileName = "variant-1.wav"
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent(fileName)
        try audioData.write(to: outputURL)

        progressCallback?("saved", 95, "Audio saved")

        // 5. Optionally save to server library
        if saveToServer {
            try? await saveToServerLibrary(jobId: jobId)
        }

        // Build metadata
        var metadata: [String: String] = [
            "file_path": outputURL.path,
            "remote_server": serverURL,
            "caption": parameters.tags,
            "model": "acestep-v15-turbo",
        ]

        // Merge server-returned metadata
        for (key, value) in completionMetadata {
            metadata[key] = value
        }

        if let bpm = parameters.tempo { metadata["bpm"] = "\(bpm)" }
        if let key = parameters.key { metadata["key"] = key }
        if !parameters.lyrics.isEmpty { metadata["lyrics"] = parameters.lyrics }

        progressCallback?("done", 100, "Generation complete")

        return (outputURL, metadata)
    }

    // MARK: - Helpers

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteGenerationError.invalidResponse("Not an HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw RemoteGenerationError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }
}

// MARK: - Supporting Types

struct RemoteGenerationParams {
    var tags: String
    var lyrics: String = ""
    var instrumental: Bool = true
    var duration: Int = 150
    var tempo: Int? = nil
    var key: String? = nil
    var seed: Int? = nil
    var numInferenceSteps: Int = 8
    var guidanceScale: Double = 4.5
    var genre: String? = nil
    var mood: String? = nil
    var artist: String? = nil
    var album: String? = nil
    var modelId: String? = nil  // ACE-Step DiT model (e.g. "acestep-v15-turbo")
    var lmModel: String? = nil  // Language model (e.g. "acestep-5Hz-lm-1.7B")
    var lmTemperature: Double = 0.9  // LM creativity (0.1-2.0)
    var lmCfgScale: Double = 2.5  // LM guidance strength (0.5-10.0)

    var timeSignature: String = "4"
    var vocalLanguage: String = ""

    // ACE-Step v1.5 advanced diffusion parameters
    var shift: Double = 3.0
    var inferMethod: String = "ode"
    var useAdg: Bool = false
    var cfgIntervalStart: Double = 0.0
    var cfgIntervalEnd: Double = 1.0

    // ACE-Step v1.5 advanced LM parameters
    var thinking: Bool = true
    var lmTopK: Int = 0
    var lmTopP: Double = 0.9
    var lmRepetitionPenalty: Double = 1.0
    var lmNegativePrompt: String = "NO USER INPUT"
    var constrainedDecoding: Bool = true

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "tags": tags,
            "lyrics": lyrics,
            "instrumental": instrumental,
            "duration": Double(duration),
            "num_inference_steps": numInferenceSteps,
            "guidance_scale": guidanceScale,
            "lm_temperature": lmTemperature,
            "lm_cfg_scale": lmCfgScale,
            // ACE-Step v1.5 advanced diffusion parameters
            "shift": shift,
            "infer_method": inferMethod,
            "use_adg": useAdg,
            "cfg_interval_start": cfgIntervalStart,
            "cfg_interval_end": cfgIntervalEnd,
            // ACE-Step v1.5 advanced LM parameters
            "thinking": thinking,
            "lm_top_k": lmTopK,
            "lm_top_p": lmTopP,
            "lm_repetition_penalty": lmRepetitionPenalty,
            "lm_negative_prompt": lmNegativePrompt,
            "constrained_decoding": constrainedDecoding,
            "time_signature": timeSignature,
            "vocal_language": vocalLanguage,
        ]
        if let tempo { dict["tempo"] = tempo }
        if let key { dict["key"] = key }
        if let seed { dict["seed"] = seed }
        if let genre { dict["genre"] = genre }
        if let mood { dict["mood"] = mood }
        if let artist { dict["artist"] = artist }
        if let album { dict["album"] = album }
        if let modelId { dict["model_id"] = modelId }
        if let lmModel { dict["lm_model"] = lmModel }
        return dict
    }
}

enum RemoteJobStatus: Sendable {
    case running(status: String)
    case completed(metadata: [String: String])
    case failed(message: String)
}

enum RemoteGenerationError: LocalizedError {
    case invalidResponse(String)
    case httpError(statusCode: Int, body: String)
    case generationFailed(String)
    case timeout(String)
    case emptyResponse
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .generationFailed(let msg): return "Generation failed: \(msg)"
        case .timeout(let msg): return "Remote generation timed out: \(msg)"
        case .emptyResponse: return "Empty response from server"
        case .invalidURL(let msg): return "Invalid URL: \(msg)"
        }
    }
}
