import Foundation
import SwiftUI

// MARK: - Generation Job Status

enum GenerationJobStatus: Equatable {
    case queued
    case generating(progress: Double)
    case completed
    case failed(message: String)
    case cancelled
}

// MARK: - Generation Target

enum GenerationTarget: Equatable {
    case local
    case remote
    case cloud
}

// MARK: - Generation Job

struct GenerationJob: Identifiable, Equatable {
    let id: UUID
    let variantId: String  // Short unique ID (first 8 chars of UUID) — stable across deletions
    let displayLabel: String  // Human-readable label ("A", "B", "C") for UI display
    let parameters: MusicParameters  // Snapshot of parameters at enqueue time
    let sessionId: UUID
    var target: GenerationTarget = .local  // Where to generate
    var assignedServerId: UUID?  // Specific server for manual routing
    var status: GenerationJobStatus
    var audioPath: String?
    var metadata: [String: String]?
    var progressMessage: String = ""
    let createdAt: Date

    var isActive: Bool {
        if case .generating = status { return true }
        return false
    }

    var isPending: Bool {
        if case .queued = status { return true }
        return false
    }

    var isFinished: Bool {
        switch status {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

// MARK: - Generation Queue

@MainActor
final class GenerationQueue: ObservableObject {
    @Published var jobs: [GenerationJob] = []
    @Published var isProcessing: Bool = false

    private weak var activeBackend: BackendViewModel?
    private var localProcessingTask: Task<Void, Never>?
    private var remoteProcessingTask: Task<Void, Never>?
    private var cloudProcessingTask: Task<Void, Never>?

    // MARK: - Queue Management

    /// Enqueue N generation jobs with unique variant IDs.
    /// Job targets are assigned based on the generation mode.
    /// When `assignToServer` is provided, sets `assignedServerId` on each job for manual routing.
    func enqueue(
        count: Int,
        parameters: MusicParameters,
        sessionId: UUID,
        existingVariantCount: Int,
        generationMode: GenerationMode = .auto,
        hasRemoteServer: Bool = false,
        hasCloudKey: Bool = false,
        assignToServer: UUID? = nil
    ) -> [GenerationJob] {
        let variantLetters = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J",
                              "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T",
                              "U", "V", "W", "X", "Y", "Z"]

        var newJobs: [GenerationJob] = []
        for i in 0..<count {
            let letterIndex = existingVariantCount + i
            let letter = letterIndex < variantLetters.count ? variantLetters[letterIndex] : "\(letterIndex + 1)"

            // Generate a short unique ID from UUID (first 8 hex chars)
            let uniqueId = String(UUID().uuidString.prefix(8)).lowercased()

            // Assign target based on generation mode
            let target: GenerationTarget
            switch generationMode {
            case .auto:
                if hasRemoteServer {
                    target = .remote
                } else if hasCloudKey {
                    target = .cloud
                } else {
                    target = .local
                }
            case .localOnly:
                target = .local
            case .remoteOnly:
                target = .remote
            case .both:
                // Round-robin: even index = local, odd index = remote
                target = (i % 2 == 0) ? .local : .remote
            case .cloudOnly:
                target = .cloud
            case .localAndCloud:
                // Round-robin: even index = local, odd index = cloud
                target = (i % 2 == 0) ? .local : .cloud
            }

            var job = GenerationJob(
                id: UUID(),
                variantId: uniqueId,
                displayLabel: letter,
                parameters: parameters,
                sessionId: sessionId,
                target: target,
                status: .queued,
                createdAt: Date()
            )
            if let serverId = assignToServer {
                job.assignedServerId = serverId
            }
            newJobs.append(job)
        }

        jobs.append(contentsOf: newJobs)
        return newJobs
    }

    /// Remove a queued (not yet started) job
    func removeJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].isPending else { return }
        jobs.remove(at: index)
    }

    /// Move a job from one position to another (reorder pending jobs)
    func moveJob(from source: IndexSet, to destination: Int) {
        jobs.move(fromOffsets: source, toOffset: destination)
    }

    /// Cancel the currently active job(s)
    func cancelActiveJobs() {
        for index in jobs.indices where jobs[index].isActive {
            jobs[index].status = .cancelled
            jobs[index].progressMessage = "Cancelled"
        }
    }

    /// Clear all completed/failed/cancelled jobs
    func clearCompleted() {
        jobs.removeAll { $0.isFinished }
    }

    // MARK: - Processing Loop

    /// Start processing the queue with local, remote, and cloud streams.
    /// Local jobs: sequential, restart Python between each (MPS memory cleanup).
    /// Remote jobs: concurrent via RemoteGenerationService, no Python restart needed.
    /// Cloud jobs: concurrent via ACEMusicCloudService (acemusic.ai API).
    /// When `serverPool` is provided, jobs with `assignedServerId` use that specific server.
    func startProcessing(
        backend: BackendViewModel,
        sessionStore: SessionStore,
        remoteService: RemoteGenerationService? = nil,
        cloudService: ACEMusicCloudService? = nil,
        serverPool: ServerPoolManager? = nil,
        onJobCompleted: @escaping (GenerationJob, URL, JSONValue) -> Void
    ) {
        guard !isProcessing else { return }
        isProcessing = true
        activeBackend = backend

        // Start local processing stream
        let hasLocalJobs = jobs.contains { $0.isPending && $0.target == .local }
        if hasLocalJobs {
            localProcessingTask = Task { [weak self] in
                guard let self = self else { return }
                await self.processLocalJobs(backend: backend, sessionStore: sessionStore, onJobCompleted: onJobCompleted)
                self.localProcessingTask = nil
                self.checkDoneProcessing(backend: backend)
            }
        }

        // Start remote processing stream
        let hasRemoteJobs = jobs.contains { $0.isPending && $0.target == .remote }
        if hasRemoteJobs, remoteService != nil || serverPool?.hasEnabledServers == true {
            remoteProcessingTask = Task { [weak self] in
                guard let self = self else { return }
                await self.processRemoteJobs(remoteService: remoteService, serverPool: serverPool, sessionStore: sessionStore, onJobCompleted: onJobCompleted)
                self.remoteProcessingTask = nil
                self.checkDoneProcessing(backend: backend)
            }
        }

        // Start cloud processing stream
        let hasCloudJobs = jobs.contains { $0.isPending && $0.target == .cloud }
        if hasCloudJobs, let cloudService = cloudService {
            cloudProcessingTask = Task { [weak self] in
                guard let self = self else { return }
                await self.processCloudJobs(cloudService: cloudService, sessionStore: sessionStore, onJobCompleted: onJobCompleted)
                self.cloudProcessingTask = nil
                self.checkDoneProcessing(backend: backend)
            }
        }

        // If no jobs matched any stream, mark done
        if !hasLocalJobs && !hasRemoteJobs && !hasCloudJobs {
            isProcessing = false
        }
    }

    /// Process local jobs sequentially (one at a time, restart backend between each)
    private func processLocalJobs(
        backend: BackendViewModel,
        sessionStore: SessionStore,
        onJobCompleted: @escaping (GenerationJob, URL, JSONValue) -> Void
    ) async {
        while let job = jobs.first(where: { $0.isPending && $0.target == .local }) {
            let jobId = job.id
            _ = updateJob(id: jobId) {
                $0.status = .generating(progress: 0.0)
                $0.progressMessage = "Preparing for local generation..."
            }

            do {
                // 1. Restart backend for clean memory
                _ = updateJob(id: jobId) {
                    $0.progressMessage = "Restarting backend for clean memory..."
                }
                await backend.restartForGeneration()

                if Task.isCancelled {
                    markJobCancelled(id: jobId)
                    break
                }
                if isJobCancelled(id: jobId) { continue }

                // 2. Ensure session exists
                if sessionStore.currentSession == nil {
                    sessionStore.createNewSession(from: job.parameters)
                }

                guard sessionStore.currentSession != nil else {
                    _ = updateJob(id: jobId) {
                        $0.status = .failed(message: "No session available")
                        $0.progressMessage = "Error: No session available"
                    }
                    continue
                }

                let outputDirectory = try prepareOutputDirectory(for: job, sessionStore: sessionStore)
                let stagingDir = outputDirectory.path
                let caption = "\(job.parameters.style), \(job.parameters.bpm) BPM, \(job.parameters.key)"

                // 3. Generate music based on generation mode
                let audioURL: URL
                let metadata: JSONValue

                switch job.parameters.generationMode {
                case .cover:
                    _ = updateJob(id: jobId) {
                        $0.progressMessage = "Generating cover/style transfer locally..."
                    }
                    let (url, meta) = try await backend.generateCover(
                        referenceAudioPath: job.parameters.referenceAudioPath,
                        caption: caption,
                        coverStrength: job.parameters.coverStrength,
                        duration: Int(job.parameters.duration),
                        lyrics: job.parameters.lyrics.isEmpty ? nil : job.parameters.lyrics,
                        bpm: Int(job.parameters.bpm),
                        key: job.parameters.key,
                        model: job.parameters.model,
                        lmModel: job.parameters.lmModel,
                        guidanceScale: job.parameters.guidanceScale,
                        seed: job.parameters.seed,
                        numInferenceSteps: job.parameters.numInferenceSteps,
                        lmTemperature: job.parameters.lmTemperature,
                        lmCfgScale: job.parameters.lmCfgScale,
                        timeSignature: job.parameters.timeSignature,
                        vocalLanguage: job.parameters.vocalLanguage,
                        outputDir: stagingDir,
                        shift: job.parameters.shift,
                        inferMethod: job.parameters.inferMethod,
                        useAdg: job.parameters.useAdg,
                        cfgIntervalStart: job.parameters.cfgIntervalStart,
                        cfgIntervalEnd: job.parameters.cfgIntervalEnd,
                        thinking: job.parameters.thinking,
                        lmTopK: job.parameters.lmTopK,
                        lmTopP: job.parameters.lmTopP,
                        lmRepetitionPenalty: job.parameters.lmRepetitionPenalty,
                        lmNegativePrompt: job.parameters.lmNegativePrompt,
                        constrainedDecoding: job.parameters.constrainedDecoding
                    )
                    audioURL = url
                    metadata = meta

                case .continuation:
                    _ = updateJob(id: jobId) {
                        $0.progressMessage = "Generating audio continuation locally..."
                    }
                    let (url, meta) = try await backend.generateContinuation(
                        sourceAudioPath: job.parameters.sourceAudioPath,
                        caption: caption,
                        duration: Int(job.parameters.duration),
                        lyrics: job.parameters.lyrics.isEmpty ? nil : job.parameters.lyrics,
                        bpm: Int(job.parameters.bpm),
                        key: job.parameters.key,
                        model: job.parameters.model,
                        lmModel: job.parameters.lmModel,
                        guidanceScale: job.parameters.guidanceScale,
                        seed: job.parameters.seed,
                        numInferenceSteps: job.parameters.numInferenceSteps,
                        lmTemperature: job.parameters.lmTemperature,
                        lmCfgScale: job.parameters.lmCfgScale,
                        timeSignature: job.parameters.timeSignature,
                        vocalLanguage: job.parameters.vocalLanguage,
                        outputDir: stagingDir,
                        shift: job.parameters.shift,
                        inferMethod: job.parameters.inferMethod,
                        useAdg: job.parameters.useAdg,
                        cfgIntervalStart: job.parameters.cfgIntervalStart,
                        cfgIntervalEnd: job.parameters.cfgIntervalEnd,
                        thinking: job.parameters.thinking,
                        lmTopK: job.parameters.lmTopK,
                        lmTopP: job.parameters.lmTopP,
                        lmRepetitionPenalty: job.parameters.lmRepetitionPenalty,
                        lmNegativePrompt: job.parameters.lmNegativePrompt,
                        constrainedDecoding: job.parameters.constrainedDecoding
                    )
                    audioURL = url
                    metadata = meta

                case .repaint:
                    _ = updateJob(id: jobId) { $0.progressMessage = "Repainting audio section locally..." }
                    let (url, meta) = try await backend.generateRepaint(
                        sourceAudioPath: job.parameters.sourceAudioPath,
                        repaintStart: job.parameters.repaintStart,
                        repaintEnd: job.parameters.repaintEnd,
                        caption: caption,
                        duration: Int(job.parameters.duration),
                        lyrics: job.parameters.lyrics.isEmpty ? nil : job.parameters.lyrics,
                        bpm: Int(job.parameters.bpm),
                        key: job.parameters.key,
                        model: "acestep-v15-base",
                        seed: job.parameters.seed,
                        numInferenceSteps: max(job.parameters.numInferenceSteps, 50),
                        outputDir: stagingDir
                    )
                    audioURL = url
                    metadata = meta

                case .extract:
                    _ = updateJob(id: jobId) { $0.progressMessage = "Extracting stems locally..." }
                    let (url, meta) = try await backend.generateExtract(
                        sourceAudioPath: job.parameters.sourceAudioPath,
                        stems: job.parameters.extractStems,
                        duration: Int(job.parameters.duration),
                        model: "acestep-v15-base",
                        seed: job.parameters.seed,
                        numInferenceSteps: max(job.parameters.numInferenceSteps, 50),
                        outputDir: stagingDir
                    )
                    audioURL = url
                    metadata = meta

                case .lego:
                    _ = updateJob(id: jobId) { $0.progressMessage = "Generating stem with context locally..." }
                    let (url, meta) = try await backend.generateLego(
                        sourceAudioPath: job.parameters.sourceAudioPath.isEmpty ? "" : job.parameters.sourceAudioPath,
                        instruction: job.parameters.legoInstruction,
                        caption: caption,
                        duration: Int(job.parameters.duration),
                        lyrics: job.parameters.lyrics.isEmpty ? nil : job.parameters.lyrics,
                        bpm: Int(job.parameters.bpm),
                        key: job.parameters.key,
                        model: "acestep-v15-base",
                        seed: job.parameters.seed,
                        numInferenceSteps: max(job.parameters.numInferenceSteps, 50),
                        outputDir: stagingDir
                    )
                    audioURL = url
                    metadata = meta

                case .autoComplete:
                    _ = updateJob(id: jobId) { $0.progressMessage = "Auto-completing arrangement locally..." }
                    let (url, meta) = try await backend.generateAutoComplete(
                        sourceAudioPath: job.parameters.sourceAudioPath,
                        caption: caption,
                        duration: Int(job.parameters.duration),
                        model: "acestep-v15-base",
                        seed: job.parameters.seed,
                        numInferenceSteps: max(job.parameters.numInferenceSteps, 50),
                        outputDir: stagingDir
                    )
                    audioURL = url
                    metadata = meta

                case .textToMusic:
                    _ = updateJob(id: jobId) {
                        $0.progressMessage = "Generating music locally..."
                    }
                    let results = try await backend.generateMusic(
                        caption: caption,
                        duration: Int(job.parameters.duration),
                        count: 1,
                        model: job.parameters.model,
                        lmModel: job.parameters.lmModel,
                        guidanceScale: job.parameters.guidanceScale,
                        bpm: Int(job.parameters.bpm),
                        key: job.parameters.key,
                        lyrics: job.parameters.lyrics.isEmpty ? nil : job.parameters.lyrics,
                        outputDir: stagingDir,
                        artist: job.parameters.artist.isEmpty ? nil : job.parameters.artist,
                        album: job.parameters.album.isEmpty ? nil : job.parameters.album,
                        genre: job.parameters.genre.isEmpty ? nil : job.parameters.genre,
                        mood: job.parameters.mood.isEmpty ? nil : job.parameters.mood,
                        seed: job.parameters.seed,
                        numInferenceSteps: job.parameters.numInferenceSteps,
                        lmTemperature: job.parameters.lmTemperature,
                        lmCfgScale: job.parameters.lmCfgScale,
                        timeSignature: job.parameters.timeSignature,
                        vocalLanguage: job.parameters.vocalLanguage,
                        shift: job.parameters.shift,
                        inferMethod: job.parameters.inferMethod,
                        useAdg: job.parameters.useAdg,
                        cfgIntervalStart: job.parameters.cfgIntervalStart,
                        cfgIntervalEnd: job.parameters.cfgIntervalEnd,
                        thinking: job.parameters.thinking,
                        lmTopK: job.parameters.lmTopK,
                        lmTopP: job.parameters.lmTopP,
                        lmRepetitionPenalty: job.parameters.lmRepetitionPenalty,
                        lmNegativePrompt: job.parameters.lmNegativePrompt,
                        constrainedDecoding: job.parameters.constrainedDecoding
                    )

                    guard let first = results.first else {
                        _ = updateJob(id: jobId) {
                            $0.status = .failed(message: "No audio returned")
                            $0.progressMessage = "Error: No audio returned"
                        }
                        continue
                    }
                    audioURL = first.0
                    metadata = first.1
                }

                if Task.isCancelled {
                    markJobCancelled(id: jobId)
                    break
                }
                if isJobCancelled(id: jobId) { continue }

                guard let completedJob = updateJob(id: jobId, mutate: {
                    $0.status = .completed
                    $0.audioPath = audioURL.path
                    $0.progressMessage = "Complete"
                }) else {
                    continue
                }

                onJobCompleted(completedJob, audioURL, metadata)

            } catch {
                if Task.isCancelled || isJobCancelled(id: jobId) || error is CancellationError {
                    cleanupPartialOutput(for: job, sessionStore: sessionStore)
                    markJobCancelled(id: jobId)
                    if Task.isCancelled { break }
                    continue
                }
                cleanupPartialOutput(for: job, sessionStore: sessionStore)
                let errorMessage = error.localizedDescription
                _ = updateJob(id: jobId) {
                    $0.status = .failed(message: errorMessage)
                    $0.progressMessage = "Error: \(errorMessage)"
                }
                AppLog.error("Local generation job \(job.displayLabel) (\(job.variantId)) failed: \(error)")
            }
        }
    }

    /// Process remote jobs concurrently via RemoteGenerationService.
    /// When a job has `assignedServerId` and a `serverPool` is provided, that specific server
    /// is used (manual routing). Otherwise falls back to pool routing or the default `remoteService`.
    private func processRemoteJobs(
        remoteService: RemoteGenerationService?,
        serverPool: ServerPoolManager? = nil,
        sessionStore: SessionStore,
        onJobCompleted: @escaping (GenerationJob, URL, JSONValue) -> Void
    ) async {
        while let job = jobs.first(where: { $0.isPending && $0.target == .remote }) {
            let jobId = job.id
            var poolServerId: UUID?
            _ = updateJob(id: jobId) {
                $0.status = .generating(progress: 0.0)
                $0.progressMessage = "Submitting to remote server..."
            }

            do {
                // Resolve which remote service to use for this job
                let effectiveService: RemoteGenerationService

                if let assignedId = job.assignedServerId,
                   let pool = serverPool,
                   let server = pool.server(byId: assignedId) {
                    // Manual routing: use the specific server the user picked
                    effectiveService = RemoteGenerationService(serverURL: server.url, apiKey: server.apiKey)
                    poolServerId = assignedId
                } else if let pool = serverPool, let server = pool.nextServer() {
                    // Pool routing: pick the next server based on strategy
                    effectiveService = RemoteGenerationService(serverURL: server.url, apiKey: server.apiKey)
                    poolServerId = server.id
                } else if let fallback = remoteService {
                    // Fallback: use the legacy single-server config
                    effectiveService = fallback
                } else {
                    _ = updateJob(id: jobId) {
                        $0.status = .failed(message: "No remote server available")
                        $0.progressMessage = "Error: No remote server available"
                    }
                    continue
                }

                if let serverId = poolServerId {
                    serverPool?.markJobStarted(serverId: serverId)
                }

                // Ensure session exists
                if sessionStore.currentSession == nil {
                    sessionStore.createNewSession(from: job.parameters)
                }

                guard sessionStore.currentSession != nil else {
                    if let serverId = poolServerId {
                        serverPool?.recordJobFailure(serverId: serverId, error: "No session available")
                    }
                    _ = updateJob(id: jobId) {
                        $0.status = .failed(message: "No session available")
                        $0.progressMessage = "Error: No session available"
                    }
                    continue
                }

                let trackDir = try prepareOutputDirectory(for: job, sessionStore: sessionStore)

                let params = RemoteGenerationParams(
                    tags: "\(job.parameters.style), \(job.parameters.bpm) BPM, \(job.parameters.key)",
                    lyrics: job.parameters.lyrics,
                    instrumental: job.parameters.lyrics.isEmpty,
                    duration: Int(job.parameters.duration),
                    tempo: Int(job.parameters.bpm),
                    key: job.parameters.key,
                    seed: job.parameters.seed,
                    numInferenceSteps: job.parameters.numInferenceSteps,
                    guidanceScale: job.parameters.guidanceScale,
                    genre: job.parameters.genre.isEmpty ? nil : job.parameters.genre,
                    mood: job.parameters.mood.isEmpty ? nil : job.parameters.mood,
                    artist: job.parameters.artist.isEmpty ? nil : job.parameters.artist,
                    album: job.parameters.album.isEmpty ? nil : job.parameters.album,
                    modelId: job.parameters.model,
                    lmModel: job.parameters.lmModel,
                    lmTemperature: job.parameters.lmTemperature,
                    lmCfgScale: job.parameters.lmCfgScale,
                    timeSignature: job.parameters.timeSignature,
                    vocalLanguage: job.parameters.vocalLanguage,
                    shift: job.parameters.shift,
                    inferMethod: job.parameters.inferMethod,
                    useAdg: job.parameters.useAdg,
                    cfgIntervalStart: job.parameters.cfgIntervalStart,
                    cfgIntervalEnd: job.parameters.cfgIntervalEnd,
                    thinking: job.parameters.thinking,
                    lmTopK: job.parameters.lmTopK,
                    lmTopP: job.parameters.lmTopP,
                    lmRepetitionPenalty: job.parameters.lmRepetitionPenalty,
                    lmNegativePrompt: job.parameters.lmNegativePrompt,
                    constrainedDecoding: job.parameters.constrainedDecoding
                )

                let jobStartTime = Date()
                let (audioURL, serverMetadata) = try await effectiveService.generate(
                    parameters: params,
                    outputDir: trackDir,
                    saveToServer: true,
                    progressCallback: { [weak self] stage, percent, message in
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            guard let index = self.jobs.firstIndex(where: { $0.id == jobId }) else { return }
                            guard case .generating = self.jobs[index].status else { return }
                            let normalized = percent > 1.0 ? percent / 100.0 : percent
                            self.jobs[index].status = .generating(progress: min(max(normalized, 0.0), 1.0))
                            self.jobs[index].progressMessage = message
                        }
                    }
                )

                if let serverId = poolServerId {
                    serverPool?.recordJobCompletion(serverId: serverId, duration: Date().timeIntervalSince(jobStartTime))
                }

                if Task.isCancelled {
                    markJobCancelled(id: jobId)
                    break
                }
                if isJobCancelled(id: jobId) { continue }

                // Convert server metadata to JSONValue
                var jsonDict: [String: JSONValue] = [:]
                for (key, value) in serverMetadata {
                    jsonDict[key] = .string(value)
                }
                jsonDict["generated_by"] = .string(effectiveService.serverURL)
                let metadataValue = JSONValue.object(jsonDict)

                guard let completedJob = updateJob(id: jobId, mutate: {
                    $0.status = .completed
                    $0.audioPath = audioURL.path
                    $0.progressMessage = "Complete (remote)"
                }) else {
                    continue
                }

                onJobCompleted(completedJob, audioURL, metadataValue)

            } catch {
                if let serverId = poolServerId {
                    serverPool?.recordJobFailure(serverId: serverId, error: error.localizedDescription)
                }
                if Task.isCancelled || isJobCancelled(id: jobId) || error is CancellationError {
                    cleanupPartialOutput(for: job, sessionStore: sessionStore)
                    markJobCancelled(id: jobId)
                    if Task.isCancelled { break }
                    continue
                }
                cleanupPartialOutput(for: job, sessionStore: sessionStore)
                let errorMessage = error.localizedDescription
                _ = updateJob(id: jobId) {
                    $0.status = .failed(message: errorMessage)
                    $0.progressMessage = "Error: \(errorMessage)"
                }
                AppLog.error("Remote generation job \(job.displayLabel) (\(job.variantId)) failed: \(error)")
            }
        }
    }

    /// Process cloud jobs via ACEMusicCloudService (acemusic.ai API).
    /// Cloud jobs run sequentially (one at a time) since the cloud API handles concurrency.
    private func processCloudJobs(
        cloudService: ACEMusicCloudService,
        sessionStore: SessionStore,
        onJobCompleted: @escaping (GenerationJob, URL, JSONValue) -> Void
    ) async {
        while let job = jobs.first(where: { $0.isPending && $0.target == .cloud }) {
            let jobId = job.id
            _ = updateJob(id: jobId) {
                $0.status = .generating(progress: 0.0)
                $0.progressMessage = "Submitting to ACE Music Cloud..."
            }

            do {
                // Ensure session exists
                if sessionStore.currentSession == nil {
                    sessionStore.createNewSession(from: job.parameters)
                }

                guard sessionStore.currentSession != nil else {
                    _ = updateJob(id: jobId) {
                        $0.status = .failed(message: "No session available")
                        $0.progressMessage = "Error: No session available"
                    }
                    continue
                }

                let trackDir = try prepareOutputDirectory(for: job, sessionStore: sessionStore)

                // Convert MusicParameters to CloudGenerationParams
                let caption = "\(job.parameters.style), \(job.parameters.bpm) BPM, \(job.parameters.key)"
                let cloudParams = CloudGenerationParams(
                    caption: caption,
                    lyrics: job.parameters.lyrics,
                    instrumental: job.parameters.lyrics.isEmpty,
                    duration: Int(job.parameters.duration),
                    bpm: Int(job.parameters.bpm),
                    key: job.parameters.key,
                    seed: job.parameters.seed,
                    inferenceSteps: job.parameters.numInferenceSteps,
                    guidanceScale: job.parameters.guidanceScale,
                    shift: job.parameters.shift,
                    inferMethod: job.parameters.inferMethod.isEmpty ? nil : job.parameters.inferMethod,
                    thinking: job.parameters.thinking,
                    constrainedDecoding: job.parameters.constrainedDecoding,
                    lmTemperature: job.parameters.lmTemperature,
                    lmCfgScale: job.parameters.lmCfgScale,
                    lmTopP: job.parameters.lmTopP > 0 ? job.parameters.lmTopP : nil,
                    vocalLanguage: job.parameters.vocalLanguage,
                    timeSignature: job.parameters.timeSignature,
                    model: job.parameters.model,
                    lmModel: job.parameters.lmModel
                )

                let (audioURL, cloudMetadata) = try await cloudService.generate(
                    parameters: cloudParams,
                    outputDir: trackDir,
                    progressCallback: { [weak self] stage, percent, message in
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            guard let index = self.jobs.firstIndex(where: { $0.id == jobId }) else { return }
                            guard case .generating = self.jobs[index].status else { return }
                            let normalized = percent > 1.0 ? percent / 100.0 : percent
                            self.jobs[index].status = .generating(progress: min(max(normalized, 0.0), 1.0))
                            self.jobs[index].progressMessage = message
                        }
                    }
                )

                if Task.isCancelled {
                    markJobCancelled(id: jobId)
                    break
                }
                if isJobCancelled(id: jobId) { continue }

                // Convert cloud metadata to JSONValue
                var jsonDict: [String: JSONValue] = [:]
                for (key, value) in cloudMetadata {
                    jsonDict[key] = .string(value)
                }
                jsonDict["generated_by"] = .string("ace-music-cloud")
                let metadataValue = JSONValue.object(jsonDict)

                guard let completedJob = updateJob(id: jobId, mutate: {
                    $0.status = .completed
                    $0.audioPath = audioURL.path
                    $0.progressMessage = "Complete (cloud)"
                }) else {
                    continue
                }

                onJobCompleted(completedJob, audioURL, metadataValue)

            } catch {
                if Task.isCancelled || isJobCancelled(id: jobId) || error is CancellationError {
                    cleanupPartialOutput(for: job, sessionStore: sessionStore)
                    markJobCancelled(id: jobId)
                    if Task.isCancelled { break }
                    continue
                }
                cleanupPartialOutput(for: job, sessionStore: sessionStore)
                let errorMessage = error.localizedDescription
                _ = updateJob(id: jobId) {
                    $0.status = .failed(message: errorMessage)
                    $0.progressMessage = "Error: \(errorMessage)"
                }
                AppLog.error("Cloud generation job \(job.displayLabel) (\(job.variantId)) failed: \(error)")
            }
        }
    }

    /// Check if all streams are done, then mark queue as not processing
    private func checkDoneProcessing(backend: BackendViewModel) {
        let hasLocalPending = jobs.contains { $0.isPending && $0.target == .local }
        let hasRemotePending = jobs.contains { $0.isPending && $0.target == .remote }
        let hasCloudPending = jobs.contains { $0.isPending && $0.target == .cloud }
        let hasActive = jobs.contains { $0.isActive }

        if !hasLocalPending && !hasRemotePending && !hasCloudPending && !hasActive {
            isProcessing = false
            activeBackend = nil

            // Unload LLM to free RAM after all jobs complete
            Task {
                do {
                    _ = try await backend.unloadLLM()
                    AppLog.info("LLM unloaded after queue completed")
                } catch {
                    AppLog.error("Failed to unload LLM: \(error)")
                }
            }
        }
    }

    /// Stop processing — cancel both streams and mark active jobs as cancelled
    func stopProcessing() {
        localProcessingTask?.cancel()
        localProcessingTask = nil
        remoteProcessingTask?.cancel()
        remoteProcessingTask = nil
        cloudProcessingTask?.cancel()
        cloudProcessingTask = nil

        for index in jobs.indices where jobs[index].isPending || jobs[index].isActive {
            jobs[index].status = .cancelled
            jobs[index].progressMessage = "Cancelled"
        }

        isProcessing = false

        if jobs.contains(where: { $0.target == .local && $0.status == .cancelled }) {
            Task {
                await activeBackend?.cancelGeneration()
            }
        }

        activeBackend = nil
    }

    // MARK: - Progress Updates

    /// Route backend progress updates to the active local job
    func updateActiveJobProgress(progress: Double, stage: String, message: String) {
        guard let index = jobs.firstIndex(where: { $0.isActive && $0.target == .local }) else { return }
        let normalized = progress > 1.0 ? progress / 100.0 : progress
        jobs[index].status = .generating(progress: min(max(normalized, 0.0), 1.0))
        if !message.isEmpty && !stage.isEmpty {
            jobs[index].progressMessage = "\(stage): \(message)"
        } else if !message.isEmpty {
            jobs[index].progressMessage = message
        } else if !stage.isEmpty {
            jobs[index].progressMessage = stage
        }
    }

    // MARK: - Computed Properties

    var activeJob: GenerationJob? {
        jobs.first { $0.isActive }
    }

    var pendingJobs: [GenerationJob] {
        jobs.filter { $0.isPending }
    }

    var completedJobs: [GenerationJob] {
        jobs.filter { $0.isFinished }
    }

    var pendingCount: Int {
        pendingJobs.count
    }

    var completedCount: Int {
        jobs.filter { $0.status == .completed }.count
    }

    var totalCount: Int {
        jobs.count
    }

    var summaryText: String {
        if isProcessing {
            let remaining = pendingJobs.count
            let active = jobs.filter { $0.isActive }.count
            return "\(active) generating, \(remaining) queued"
        } else if !jobs.isEmpty {
            let completed = jobs.filter { $0.status == .completed }.count
            let failed = jobs.filter { if case .failed = $0.status { return true }; return false }.count
            var parts: [String] = []
            if completed > 0 { parts.append("\(completed) completed") }
            if failed > 0 { parts.append("\(failed) failed") }
            return parts.isEmpty ? "Queue empty" : parts.joined(separator: ", ")
        }
        return ""
    }

    @discardableResult
    private func updateJob(id jobId: UUID, mutate: (inout GenerationJob) -> Void) -> GenerationJob? {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return nil }
        mutate(&jobs[index])
        return jobs[index]
    }

    private func isJobCancelled(id jobId: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == jobId }) else { return true }
        return job.status == .cancelled
    }

    private func markJobCancelled(id jobId: UUID) {
        _ = updateJob(id: jobId) { job in
            guard !job.isFinished else { return }
            job.status = .cancelled
            job.progressMessage = "Cancelled"
        }
    }

    private func outputDirectory(for job: GenerationJob, sessionStore: SessionStore) -> URL {
        sessionStore
            .stagingDirectory(for: job.sessionId)
            .appendingPathComponent(job.variantId, isDirectory: true)
    }

    private func prepareOutputDirectory(for job: GenerationJob, sessionStore: SessionStore) throws -> URL {
        let directory = outputDirectory(for: job, sessionStore: sessionStore)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanupPartialOutput(for job: GenerationJob, sessionStore: SessionStore) {
        let directory = outputDirectory(for: job, sessionStore: sessionStore)
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
