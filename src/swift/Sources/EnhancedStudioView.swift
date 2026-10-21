import SwiftUI
import UniformTypeIdentifiers

struct EnhancedStudioView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var backend: BackendViewModel
    @EnvironmentObject var studioCoordinator: StudioCoordinator
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var stemSessionStore: StemSessionStore
    @EnvironmentObject var licenseManager: LicenseManager
    @EnvironmentObject var generationQueue: GenerationQueue
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @EnvironmentObject var serverPool: ServerPoolManager
    @EnvironmentObject var modelAvailability: ModelAvailabilityManager

    @State private var parameters = MusicParameters()
    @State private var selectedTrack: Track?
    @State private var variants: [Variant] = []
    @State private var gpuStatus = GPUQueueStatus()
    @State private var currentPlaybackTime: Double = 0.0
    @State private var sections: [Section] = Self.defaultSections

    private static let defaultSections: [Section] = [
        Section(id: "intro", label: "Intro", start: 0, end: 20, mood: "intro"),
        Section(id: "verse1", label: "Verse 1", start: 20, end: 60, mood: "verse"),
        Section(id: "hook1", label: "Hook", start: 60, end: 90, mood: "hook"),
        Section(id: "verse2", label: "Verse 2", start: 90, end: 130, mood: "verse"),
        Section(id: "hook2", label: "Hook", start: 130, end: 160, mood: "hook"),
        Section(id: "outro", label: "Outro", start: 160, end: 170, mood: "outro")
    ]
    @State private var isEnhancingCaption = false
    @State private var showGenerationError = false
    @State private var generationErrorMessage = ""
    @State private var showEnhanceError = false
    @State private var enhanceErrorMessage = ""

    private var isGenerating: Bool {
        generationQueue.isProcessing
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(geometry.size.width - 48, 320)

            ZStack(alignment: .topTrailing) {
                ScrollView {
                    VStack(spacing: 20) {
                        // Project Header
                        ProjectHeaderView(
                            parameters: $parameters,
                            variants: $variants,
                            isGenerating: isGenerating,
                            onGenerate: generateVariants,
                            onStop: stopGeneration,
                            onClear: clearWorkspace,
                            onNewSong: resetParametersForNewSong
                        )

                        // Parameter Controls
                        ParameterControlsView(
                            parameters: $parameters,
                            isEnhancingCaption: $isEnhancingCaption,
                            onEnhanceCaption: enhanceCaption,
                            availableWidth: contentWidth
                        )

                        // Generation Queue (replaces old progress view)
                        if !generationQueue.jobs.isEmpty {
                            GenerationQueueView(availableWidth: contentWidth)
                        }

                        // Interactive waveform visualization
                        InteractiveWaveformView(
                            sections: $sections,
                            currentTime: $currentPlaybackTime,
                            duration: parameters.duration,
                            isPlaying: player.isPlaying
                        )

                        // Variants Grid (Phase 3)
                        if !variants.isEmpty {
                            VariantsGridView(
                                variants: $variants,
                                player: player,
                                onDelete: deleteVariant,
                                availableWidth: contentWidth
                            )
                        }

                        // S1: extract-mode results → open in the Stems mixer
                        if parameters.generationMode == .extract,
                           variants.contains(where: { $0.status == .ready && $0.audioPath != nil }) {
                            HStack {
                                Spacer()
                                Button(action: openExtractResultsAsStemSession) {
                                    Label("Open as Stem Session", systemImage: "slider.horizontal.3")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.purple)
                                .help("Mix the extracted stems with per-stem gain, mute, and solo in the Stems tab")
                                Spacer()
                            }
                        }

                        Spacer()
                    }
                    .padding(24)
                }

                // Floating Volume Control (always visible)
                VolumeControlView(volume: $player.volume)
                    .padding(.top, 16)
                    .padding(.trailing, 24)
            }
        }
        .onChange(of: studioCoordinator.pendingParameters) { _, newParams in
            if let params = newParams {
                // Convert BackendViewModel.MusicParameters to StudioModels.MusicParameters
                parameters.style = params.caption
                parameters.duration = Double(params.duration)
                parameters.variantCount = params.variantCount
                if let bpm = params.bpm {
                    parameters.bpm = Double(bpm)
                }
                if let key = params.key {
                    parameters.key = key
                }
                if let lyrics = params.lyrics {
                    parameters.lyrics = lyrics
                }

                // Clear pending parameters after loading
                studioCoordinator.pendingParameters = nil
            }
        }
        .onReceive(backend.$generationProgress) { progress in
            guard generationQueue.isProcessing else { return }
            generationQueue.updateActiveJobProgress(
                progress: progress,
                stage: backend.generationStage,
                message: backend.generationMessage
            )
            syncVariantStatusFromQueue()
        }
        .onReceive(backend.$generationMessage) { _ in
            guard generationQueue.isProcessing else { return }
            generationQueue.updateActiveJobProgress(
                progress: backend.generationProgress,
                stage: backend.generationStage,
                message: backend.generationMessage
            )
            syncVariantStatusFromQueue()
        }
        .alert("Generation Failed", isPresented: $showGenerationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(generationErrorMessage)
        }
        .alert("AI Enhancement Failed", isPresented: $showEnhanceError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(enhanceErrorMessage)
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            if player.isPlaying {
                currentPlaybackTime = player.currentTime
            }
        }
        .task {
            // Query model availability on view appear based on current generation mode
            await refreshModelAvailability()
        }
        .onChange(of: llmSettings.generationMode) { _, _ in
            Task { await refreshModelAvailability() }
        }
        .onChange(of: llmSettings.aceCloudAPIKey) { _, _ in
            modelAvailability.invalidateCloudCache()
            Task { await refreshModelAvailability() }
        }
        .onChange(of: llmSettings.aceStepServerURL) { _, _ in
            modelAvailability.invalidateRemoteCache()
            Task { await refreshModelAvailability() }
        }
    }

    /// Query model availability for the current generation mode.
    private func refreshModelAvailability() async {
        let mode = llmSettings.generationMode
        if mode.usesCloud || mode == .auto {
            await modelAvailability.queryCloudModels(apiKey: llmSettings.aceCloudAPIKey)
        }
        if mode == .remoteOnly || mode == .both || mode == .auto {
            if !llmSettings.aceStepServerURL.isEmpty {
                await modelAvailability.queryRemoteModels(
                    serverURL: llmSettings.aceStepServerURL,
                    apiKey: llmSettings.aceStepServerAPIKey
                )
            }
            if serverPool.hasEnabledServers {
                await modelAvailability.queryPoolModels(serverPool: serverPool)
            }
        }
    }

    private func enhanceCaption() {
        guard !parameters.style.isEmpty else { return }
        guard backend.isConnected else {
            enhanceErrorMessage = "Backend is not connected. Please wait for it to start or restart it in Settings."
            showEnhanceError = true
            return
        }
        isEnhancingCaption = true

        Task {
            do {
                let enhanced = try await backend.enhanceCaption(parameters.style)
                await MainActor.run {
                    parameters.style = enhanced
                    isEnhancingCaption = false
                }
            } catch {
                await MainActor.run {
                    AppLog.error("Caption enhancement failed: \(error)")
                    enhanceErrorMessage = "Could not enhance the style description. Check that an LLM provider is configured in Settings > LLM.\n\n\(error.localizedDescription)"
                    showEnhanceError = true
                    isEnhancingCaption = false
                }
            }
        }
    }

    private func generateVariants() {
        if let message = parameters.generationValidationError() {
            generationErrorMessage = message
            showGenerationError = true
            return
        }

        // Pre-generation ACE-Step readiness check (skip for remote-only and cloud-only modes)
        if llmSettings.generationMode != .remoteOnly && llmSettings.generationMode != .cloudOnly {
            Task {
                do {
                    // If backend isn't connected, try to restart it before giving up
                    if !backend.isConnected {
                        await backend.restartForGeneration()
                    }
                    let result = try await backend.testAceStepInstallation()
                    if !result.isWorking {
                        await MainActor.run {
                            generationErrorMessage = result.message ?? "ACE-Step models are not installed or configured correctly. Please run the Setup Wizard from Settings to download the required models."
                            showGenerationError = true
                        }
                        return
                    }
                    await MainActor.run {
                        self.proceedWithGeneration()
                    }
                } catch {
                    await MainActor.run {
                        generationErrorMessage = "Could not verify ACE-Step installation: \(error.localizedDescription)\n\nPlease check that the backend is running and models are installed. Try restarting the app, or go to Settings > LLM and click 'Restart Backend'."
                        showGenerationError = true
                    }
                }
            }
            return
        }

        proceedWithGeneration()
    }

    private func proceedWithGeneration() {
        // Create session first if none exists
        if sessionStore.currentSession == nil {
            sessionStore.createNewSession(from: parameters)
        }

        guard let session = sessionStore.currentSession else {
            generationErrorMessage = "No session available"
            showGenerationError = true
            return
        }

        let hasRemoteServer = !llmSettings.aceStepServerURL.isEmpty
        let hasCloudKey = !llmSettings.aceCloudAPIKey.isEmpty

        // Enqueue N jobs with parameter snapshot and generation mode
        let existingCount = variants.count
        let newJobs = generationQueue.enqueue(
            count: parameters.variantCount,
            parameters: parameters,
            sessionId: session.id,
            existingVariantCount: existingCount,
            generationMode: llmSettings.generationMode,
            hasRemoteServer: hasRemoteServer,
            hasCloudKey: hasCloudKey
        )

        // Create placeholder Variant cards with .queued status
        for job in newJobs {
            let note: String
            let generatedBy: String
            switch job.target {
            case .remote:
                note = "Queued (remote)"
                generatedBy = llmSettings.aceStepServerURL
            case .cloud:
                note = "Queued (cloud)"
                generatedBy = "ace-music-cloud"
            case .local:
                note = "Queued"
                generatedBy = "local"
            }
            let variant = Variant(
                id: job.variantId,
                displayLabel: job.displayLabel,
                title: "Version \(job.displayLabel)",
                note: note,
                rating: 3,
                bpm: parameters.bpm,
                key: parameters.key,
                duration: parameters.duration,
                status: .queued,
                generatedBy: generatedBy
            )
            variants.append(variant)
        }

        // Create remote service if needed
        var remoteService: RemoteGenerationService? = nil
        let hasRemoteJobs = newJobs.contains { $0.target == .remote }
        if hasRemoteJobs && hasRemoteServer {
            remoteService = RemoteGenerationService(
                serverURL: llmSettings.aceStepServerURL,
                apiKey: llmSettings.aceStepServerAPIKey
            )
        }

        // Create cloud service if needed
        var cloudService: ACEMusicCloudService? = nil
        let hasCloudJobs = newJobs.contains { $0.target == .cloud }
        if hasCloudJobs && hasCloudKey {
            cloudService = ACEMusicCloudService(apiKey: llmSettings.aceCloudAPIKey)
        }

        // Start processing if not already running
        if !generationQueue.isProcessing {
            generationQueue.startProcessing(
                backend: backend,
                sessionStore: sessionStore,
                remoteService: remoteService,
                cloudService: cloudService,
                serverPool: serverPool.hasEnabledServers ? serverPool : nil,
                onJobCompleted: { [self] job, audioURL, metadata in
                    self.handleJobCompleted(job: job, audioURL: audioURL, metadata: metadata)
                }
            )
        }
    }

    private func handleJobCompleted(job: GenerationJob, audioURL: URL, metadata: JSONValue) {
        // Find the matching variant card and update it
        guard let variantIndex = variants.firstIndex(where: { $0.id == job.variantId }) else { return }

        var variant = variants[variantIndex]
        variant.status = .ready
        variant.audioPath = audioURL.path

        // Extract metadata if available
        var extractedBPM: Double? = nil
        var extractedKey: String? = nil
        var extractedDuration: Double = job.parameters.duration

        if case .object(let metadataObj) = metadata {
            if case .number(let bpm)? = metadataObj["bpm"] {
                extractedBPM = bpm
                variant.bpm = bpm
            }
            if case .string(let key)? = metadataObj["key"] {
                extractedKey = key
                variant.key = key
            }
            if case .number(let duration)? = metadataObj["duration"] {
                extractedDuration = duration
            }
        }

        variant.note = generateVariantNote(index: variantIndex)
        variants[variantIndex] = variant

        // Create staging track
        guard let session = sessionStore.currentSession else { return }
        let variantLabel = variant.displayLabel
        let stagingBase = FileStore.shared.stagingDirectory.path
        let relativeFileName: String
        if audioURL.path.hasPrefix(stagingBase) {
            let startIdx = audioURL.path.index(audioURL.path.startIndex, offsetBy: stagingBase.count + 1)
            relativeFileName = String(audioURL.path[startIdx...])
        } else {
            relativeFileName = "\(session.id.uuidString)/\(audioURL.lastPathComponent)"
        }

        let trackTitle: String = {
            if !job.parameters.style.isEmpty {
                let style = job.parameters.style
                if style.count <= 50 {
                    return "\(style) (\(variantLabel))"
                }
                // Truncate at word boundary around 40 chars
                let prefix = String(style.prefix(40))
                if let lastSpace = prefix.lastIndex(of: " ") {
                    return "\(prefix[...lastSpace])(\(variantLabel))"
                }
                return "\(prefix)... (\(variantLabel))"
            } else {
                return "Untitled Track \(variantLabel)"
            }
        }()

        let stagingTrack = StagingTrack(
            id: UUID(),
            title: trackTitle,
            variantId: variant.id,
            audioFileName: relativeFileName,
            note: variant.note,
            rating: 0,
            bpm: extractedBPM,
            key: extractedKey,
            duration: extractedDuration,
            isMarkedForKeep: true,
            createdAt: Date()
        )

        sessionStore.addStagingTrack(stagingTrack)
    }

    /// Sync variant card statuses from the generation queue
    private func syncVariantStatusFromQueue() {
        for job in generationQueue.jobs {
            guard let index = variants.firstIndex(where: { $0.id == job.variantId }) else { continue }
            switch job.status {
            case .queued:
                variants[index].status = .queued
            case .generating(let progress):
                variants[index].status = .generating(progress: progress)
            case .completed:
                // Don't overwrite .ready status that was set in handleJobCompleted
                break
            case .failed(let message):
                variants[index].status = .failed(message: message)
                variants[index].note = "Generation failed"
            case .cancelled:
                variants[index].status = .failed(message: "Cancelled")
                variants[index].note = "Cancelled"
            }
        }
    }

    private func generateVariantNote(index: Int) -> String {
        let notes = [
            "Original parameters",
            "Slightly faster tempo",
            "Alternative arrangement",
            "Different mood",
            "Experimental variation"
        ]
        return notes[min(index, notes.count - 1)]
    }

    private func stopGeneration() {
        generationQueue.stopProcessing()
        // Tell the Python backend to cancel any active generation
        Task {
            await backend.cancelGeneration()
        }
        // Mark any generating variants as failed
        for index in variants.indices {
            if variants[index].status.isGenerating || variants[index].status.isQueued {
                variants[index].status = .failed(message: "Cancelled")
            }
        }
    }

    private func deleteVariant(_ variant: Variant) {
        // Remove from variants array
        variants.removeAll { $0.id == variant.id }

        // Remove from queue if pending
        for job in generationQueue.jobs where job.variantId == variant.id && job.isPending {
            generationQueue.removeJob(job.id)
        }

        // If this variant has a staging track, delete that too
        if let stagingTrack = sessionStore.currentSession?.stagingTracks.first(where: { $0.variantId == variant.id }) {
            sessionStore.deleteTrack(stagingTrack.id)
        }

        // Delete audio file if it exists
        if let audioPath = variant.audioPath {
            let fileURL = URL(fileURLWithPath: audioPath)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func clearWorkspace() {
        // Stop any active generation
        generationQueue.stopProcessing()
        generationQueue.clearCompleted()

        // Clear session storage (staging files)
        sessionStore.clearCurrentSession()

        // Reset all UI state to defaults
        parameters = MusicParameters()
        variants = []

        // Reset waveform sections to defaults
        sections = Self.defaultSections

        // Only stop playback if currently playing a studio track
        if player.isPlaying,
           let currentURL = player.currentURL,
           variants.contains(where: { variant in
               guard let audioPath = variant.audioPath else { return false }
               return URL(fileURLWithPath: audioPath).path == currentURL.path
           }) {
            player.pause()
        }

        AppLog.debug("Cleared workspace - all state reset")
    }

    /// Resets parameter fields to defaults for a new song without
    /// clearing the generation queue, variants, or staged tracks.
    private func resetParametersForNewSong() {
        parameters = MusicParameters()
        AppLog.debug("Parameters reset for new song -- queue and tracks preserved")
    }

    /// Creates a Stem Session from ready extract-mode variants and opens the
    /// Stems tab (S1). Each extract job yields one isolated-stem file;
    /// provenance (source path + requested stems) rides along in generationParams.
    private func openExtractResultsAsStemSession() {
        let ready = variants.filter { $0.status == .ready && $0.audioPath != nil }
        guard !ready.isEmpty else { return }

        // Provenance: match the extract source back to a library track if possible.
        let sourcePath = parameters.sourceAudioPath
        let sourceTrack = library.tracks.first { $0.audioURL.path == sourcePath }

        let instruction = parameters.extractStems.joined(separator: ", ")
        let inputs: [(displayName: String, url: URL)] = ready.map { variant in
            let base = instruction.isEmpty ? variant.title : instruction.capitalized
            let name = ready.count > 1 ? "\(base) (\(variant.displayLabel))" : base
            return (displayName: name, url: URL(fileURLWithPath: variant.audioPath ?? ""))
        }

        let sourceName = sourceTrack?.title
            ?? URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        let sessionName = sourceName.isEmpty ? "Extracted Stems" : "\(sourceName) — Stems"

        do {
            let doc = try stemSessionStore.createSession(
                name: sessionName,
                stems: inputs,
                sourceTrackId: sourceTrack?.id,
                generationParams: parameters.toGenerationParams(),
                originAction: StemOriginOp.actionCreatedFromExtract,
                originDetail: "Extracted \(instruction.isEmpty ? "stems" : instruction) from \"\(sourceName)\""
            )
            ToastManager.shared.show("Stem session created — opening Stems tab", style: .success)
            studioCoordinator.openStemSessions(sessionID: doc.id)
        } catch {
            ToastManager.shared.show("Could not create stem session: \(error.localizedDescription)", style: .error)
            AppLog.error("Stem session from extract failed: \(error)")
        }
    }
}

// MARK: - Project Header

struct ProjectHeaderView: View {
    @Binding var parameters: MusicParameters
    @Binding var variants: [Variant]
    let isGenerating: Bool
    let onGenerate: () -> Void
    let onStop: () -> Void
    let onClear: () -> Void
    let onNewSong: () -> Void
    @State private var showingImportPicker = false
    @State private var showingExportMenu = false
    @State private var importStatus: String = ""
    @State private var exportStatus: String = ""
    @State private var showClearConfirmation = false
    @State private var generateCooldown = false
    @EnvironmentObject var backend: BackendViewModel
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var stemSessionStore: StemSessionStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var licenseManager: LicenseManager
    @EnvironmentObject var studioCoordinator: StudioCoordinator
    @EnvironmentObject var generationQueue: GenerationQueue
    @EnvironmentObject var serverPool: ServerPoolManager
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @EnvironmentObject var modelAvailability: ModelAvailabilityManager

    private var selectedTracksCount: Int {
        sessionStore.currentSession?.stagingTracks.filter { $0.isMarkedForKeep }.count ?? 0
    }

    private var generationModeIcon: String {
        switch llmSettings.generationMode {
        case .cloudOnly, .localAndCloud: return "cloud"
        case .remoteOnly, .both: return "server.rack"
        case .localOnly: return "desktopcomputer"
        case .auto: return "server.rack"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                // Always show Sterling's logo on Studio tab
                EngineerLogo(size: 40)
                    .accessibilityHidden(true)

                // spacer removed — temporary badge no longer needed

                VStack(alignment: .leading, spacing: 2) {
                    Text(SterlingPersona.role)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Studio Session")
                        .font(.title2)
                        .fontWeight(.semibold)
                }

                Spacer()

                HStack(spacing: 12) {
                    // New Song button — resets form fields for a new song
                    Button(action: onNewSong) {
                        Label("New Song", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .help("Clear all parameter fields to set up a new song. The queue and generated tracks are kept.")

                    // Import button
                    Button(action: { showingImportPicker = true }) {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isGenerating)
                    .help("Import an audio file for analysis")

                    // Clear Studio button
                    Button("Clear Studio") {
                        showClearConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(isGenerating || sessionStore.currentSession == nil)
                    .help("Discard all tracks and reset the workspace")

                    // Save Selected to Library button
                    Button("Save Selected to Library") {
                        saveSelectedToLibrary()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating || selectedTracksCount == 0)
                    .help("Save tracks marked as Keep to your library")

                    if isGenerating {
                        Button(action: onStop) {
                            Label("Stop All", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .accessibilityLabel("Stop all generation")
                    }

                    // Generate / Add to Queue button
                    Button(action: {
                        generateCooldown = true
                        onGenerate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            generateCooldown = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            if generationQueue.isProcessing {
                                Text("Add")
                                    .font(.body)
                            } else {
                                Text("Generate")
                                    .font(.body)
                            }
                            Picker("", selection: $parameters.variantCount) {
                                ForEach(1...5, id: \.self) { count in
                                    Text("\(count)").tag(count)
                                }
                            }
                            .frame(width: 50)
                            .labelsHidden()
                            .accessibilityLabel("Number of versions")
                            .accessibilityValue("\(parameters.variantCount)")
                            .help("Generate multiple versions in parallel with different random seeds. Compare and keep the best one.")
                            if generationQueue.isProcessing {
                                Text("to Queue")
                                    .font(.body)
                            } else {
                                Text(parameters.variantCount == 1 ? "Version" : "Versions")
                                    .font(.body)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(generationQueue.isProcessing ? Color.orange : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(generateCooldown || parameters.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            // Generation Config Summary — quick-access shortcuts
            HStack(spacing: 12) {
                // Server target
                Menu {
                    Button("Local (this Mac)") {
                        llmSettings.generationMode = .localOnly
                    }
                    Button("Auto") {
                        llmSettings.generationMode = .auto
                    }
                    if serverPool.hasEnabledServers {
                        Divider()
                        Button("Remote Only") {
                            llmSettings.generationMode = .remoteOnly
                        }
                        Button("Both (Parallel)") {
                            llmSettings.generationMode = .both
                        }
                    }
                    if !llmSettings.aceCloudAPIKey.isEmpty {
                        Divider()
                        Button("Cloud Only") {
                            llmSettings.generationMode = .cloudOnly
                        }
                        Button("Local + Cloud") {
                            llmSettings.generationMode = .localAndCloud
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: generationModeIcon)
                            .font(.caption)
                        Text(llmSettings.generationMode.displayName)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(6)
                }

                // ACE Music Cloud status indicator
                if llmSettings.generationMode.usesCloud {
                    if llmSettings.aceCloudAPIKey.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                            Text("No cloud API key")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "cloud.fill")
                                .font(.caption2)
                                .foregroundColor(.green)
                            Text("ACE Music Cloud (Free)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // DiT model quick-select
                Menu {
                    ForEach(ACEStepModel.availableModels) { model in
                        let avail = modelAvailability.availability(of: model, mode: llmSettings.generationMode)
                        Button {
                            parameters.model = model.rawValue
                            parameters.numInferenceSteps = model.defaultInferenceSteps
                        } label: {
                            HStack {
                                Circle()
                                    .fill(avail == .available ? Color.green :
                                          avail == .unknown ? Color.yellow.opacity(0.7) : Color.gray)
                                    .frame(width: 6, height: 6)
                                Text(model.displayName)
                                if avail == .notAvailable {
                                    Text("(Unavailable)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if parameters.model == model.rawValue {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(avail == .notAvailable)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.caption)
                        Text(ACEStepModel(rawValue: parameters.model)?.displayName ?? parameters.model)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(6)
                }

                // LM model quick-select
                Menu {
                    ForEach(LMModel.allCases) { lm in
                        Button {
                            parameters.lmModel = lm.rawValue
                        } label: {
                            HStack {
                                Text(lm.displayName)
                                if parameters.lmModel == lm.rawValue {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                            .font(.caption)
                        Text(LMModel(rawValue: parameters.lmModel)?.displayName ?? "1.7B")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(6)
                }

                Spacer()
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [.audio, .wav, .mp3],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result: result)
        }
        .confirmationDialog("Clear Studio Workspace?", isPresented: $showClearConfirmation) {
            Button("Discard All Tracks", role: .destructive) {
                clearWorkspace()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all tracks from the workspace. This action cannot be undone.")
        }
    }

    /// Human-readable label for why a model is unavailable on the current target.
    private func availabilityLabel(for model: ACEStepModel) -> String {
        switch llmSettings.generationMode {
        case .localOnly:
            return "(Not Downloaded)"
        case .cloudOnly:
            return "(Not on Cloud)"
        case .remoteOnly:
            return "(Not on Server)"
        default:
            if !modelAvailability.isLocallyDownloaded(model) {
                return "(Not Downloaded)"
            }
            return "(Unavailable)"
        }
    }

    private func exportAs(format: String) {
        Task {
            do {
                // Export the first ready variant, or show error
                guard let firstVariant = variants.first(where: { variant in
                    variant.status == .ready && variant.audioPath != nil
                }) else {
                    exportStatus = "No generated audio to export"
                    return
                }

                guard let sourceFile = firstVariant.audioPath else {
                    exportStatus = "No audio path available"
                    return
                }

                let fileExtension = format.lowercased()
                let exportName = firstVariant.title.isEmpty ? "export_\(Date().timeIntervalSince1970)" : firstVariant.title
                let outputPath = FileStore.shared.baseDirectory
                    .appendingPathComponent("\(exportName).\(fileExtension)")
                    .path

                exportStatus = "Exporting as \(format)..."
                let exportedPath = try await backend.exportTrack(
                    filePath: sourceFile,
                    outputPath: outputPath,
                    format: fileExtension
                )
                exportStatus = "Exported to: \(exportedPath)"
                AppLog.info("Export complete: \(exportedPath)")
            } catch {
                exportStatus = "Export failed: \(error.localizedDescription)"
                AppLog.error("Export error: \(error)")
            }
        }
    }

    private func exportStems() {
        Task {
            do {
                guard let firstVariant = variants.first(where: { variant in
                    variant.status == .ready && variant.audioPath != nil
                }) else {
                    exportStatus = "No generated audio to export"
                    return
                }

                guard let sourceFile = firstVariant.audioPath else {
                    exportStatus = "No audio path available"
                    return
                }

                let outputDir = FileStore.shared.baseDirectory
                    .appendingPathComponent("stems_\(Date().timeIntervalSince1970)")
                    .path

                exportStatus = "Separating stems with Demucs (this may take a few minutes)..."
                // Through the `StemSeparating` protocol, which is what every
                // other entry point in the app now calls. Same method, same
                // subprocess — the point is that there is ONE name for "split
                // this song" and every surface uses it, so a source scan can
                // tell which surfaces still reach it.
                let stems = try await backend.separateIntoStems(
                    sourceAudioPath: sourceFile,
                    outputDir: outputDir
                )

                // Success! Show which stems were exported
                let stemNames = stems.keys.sorted().joined(separator: ", ")
                exportStatus = "Exported \(stems.count) stems: \(stemNames)"
                AppLog.info("Stems exported: \(stemNames)")

                // S1: open the separated stems as a Stem Session (files are
                // copied into the session, so the ad-hoc stems_<ts> dir can go).
                openDemucsStemsAsStemSession(stems, sourceTitle: firstVariant.title)
            } catch {
                // ⚠️ THIS USED TO THROW THE REASON AWAY. It matched RPC -32001
                // and replaced the whole payload with "Install Demucs: pip
                // install demucs" — advice that is WRONG whenever the missing
                // package is numpy or torch (demucs does not depend on numpy
                // and imports it at load), and which discarded the interpreter
                // path, the other half of every real diagnosis. The refusal now
                // carries the backend's own words and APPENDS the fix.
                exportStatus = StemSeparationRefusal.message(for: error)
                AppLog.error("Stem export error: \(error)")
            }
        }
    }

    // MARK: - Stem Session Integration (S1)

    /// Creates a Stem Session from Demucs separation output and opens the Stems
    /// tab.
    ///
    /// The ordering and the session-building live in `StemSeparation` now, not
    /// here: this file used to hold its own private `stemOrder` and its own
    /// copy of the `createSession` call, which is a second list of the same
    /// decision one tab away from the first. Every surface that turns four
    /// files into a stem session goes through `StemSeparation.makeSession`.
    private func openDemucsStemsAsStemSession(_ stems: [String: String], sourceTitle: String) {
        guard !stems.isEmpty else { return }
        let title = sourceTitle.isEmpty ? "Separated Stems" : sourceTitle
        do {
            let doc = try StemSeparation.makeSession(
                from: stems,
                title: title,
                sourceTrackID: nil,
                generationParams: parameters.toGenerationParams(),
                detail: "Demucs separation of \"\(title)\" "
                    + "(\(StemSeparation.orderedInputs(stems).map(\.displayName).joined(separator: ", ")))",
                store: stemSessionStore
            )
            ToastManager.shared.show("Stem session created — opening Stems tab", style: .success)
            studioCoordinator.openStemSessions(sessionID: doc.id)
        } catch {
            ToastManager.shared.show("Could not create stem session: \(error.localizedDescription)", style: .error)
            AppLog.error("Stem session from Demucs export failed: \(error)")
        }
    }

    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                Task {
                    do {
                        importStatus = "Importing \(url.lastPathComponent)..."
                        let (importedURL, metadata) = try await backend.importAudio(filePath: url.path)
                        importStatus = "Imported successfully!"

                        // Extract metadata
                        var bpm: Double = 120
                        var key: String = "Unknown"
                        if case .object(let metadataObj) = metadata {
                            if case .number(let extractedBPM)? = metadataObj["bpm"] {
                                bpm = extractedBPM
                            }
                            if case .string(let extractedKey)? = metadataObj["key"] {
                                key = extractedKey
                            }
                        }

                        // Update parameters with extracted metadata
                        parameters.bpm = bpm
                        parameters.key = key

                        AppLog.info("Imported: \(importedURL.path), BPM: \(bpm), Key: \(key)")
                    } catch {
                        importStatus = "Import failed: \(error.localizedDescription)"
                        AppLog.error("Import error: \(error)")
                    }
                }
            }
        case .failure(let error):
            importStatus = "Import failed: \(error.localizedDescription)"
            AppLog.error("File picker error: \(error)")
        }
    }

    private func clearWorkspace() {
        onClear()
    }

    private func saveSelectedToLibrary() {
        // Sync current UI parameters to session (artist, album, etc. may have changed)
        sessionStore.updateParameters(parameters)

        // Convert marked staging tracks to library tracks
        let libraryTracks = sessionStore.keepSelectedTracks()

        // Add tracks to library
        for track in libraryTracks {
            library.addTrack(track)
            library.organizeTrack(track)
        }

        // Generate LRC (timestamped lyrics) files in the background for tracks with lyrics
        sessionStore.generateLRCForTracks(libraryTracks, backend: backend, library: library)

        AppLog.info("Saved \(libraryTracks.count) track(s) to library")
    }
}

// MARK: - Parameter Controls

struct ParameterControlsView: View {
    @Binding var parameters: MusicParameters
    @Binding var isEnhancingCaption: Bool
    let onEnhanceCaption: () -> Void
    let availableWidth: CGFloat
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @EnvironmentObject var modelAvailability: ModelAvailabilityManager
    @State private var showAdvanced = false
    @State private var showDiffusionControls = true
    @State private var showLanguageModelControls = true
    @State private var showReferenceFilePicker = false
    @State private var showSourceFilePicker = false

    /// Maximum duration depends on whether a remote server is configured.
    /// Remote ACE-Step 1.5 servers support up to 480s (~8 minutes).
    /// Local generation on MacBook is limited to 180s by VRAM constraints.
    private var maxDuration: Double {
        !llmSettings.aceStepServerURL.isEmpty ? 480 : 180
    }

    private var maxDurationFormatted: String {
        let minutes = Int(maxDuration) / 60
        let seconds = Int(maxDuration) % 60
        return seconds > 0 ? String(format: "%d:%02d", minutes, seconds) : "\(minutes):00"
    }

    private let keyOptions = [
        "C major", "G major", "D major", "A major", "E major", "B major",
        "F# major", "C# major", "F major", "B♭ major", "E♭ major", "A♭ major",
        "A minor", "E minor", "B minor", "F# minor", "C# minor", "G# minor",
        "D minor", "G minor", "C minor", "F minor", "B♭ minor", "E♭ minor"
    ]

    private var parameterGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 200, maximum: 400), spacing: 12, alignment: .top)]
    }

    private var usesCompactModePicker: Bool {
        availableWidth < 1000
    }

    var body: some View {
        VStack(spacing: 12) {
            generationModeCard

            // Mode-specific controls
            if parameters.generationMode == .cover {
                coverModeControls
            } else if parameters.generationMode == .continuation {
                continuationModeControls
            } else if parameters.generationMode == .lego {
                legoModeControls
            } else if parameters.generationMode == .extract {
                extractModeControls
            } else if parameters.generationMode == .repaint {
                repaintModeControls
            } else if parameters.generationMode == .autoComplete {
                autoCompleteModeControls
            }

            primaryParameterGrid
            modelSelectionGrid
            lyricsCard
            cfgGuidanceCard
            advancedParametersSection
            libraryOrganizationGrid
        }
        .fileImporter(
            isPresented: $showReferenceFilePicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = url.startAccessingSecurityScopedResource()
                parameters.referenceAudioPath = url.path
                url.stopAccessingSecurityScopedResource()
            }
        }
        .fileImporter(
            isPresented: $showSourceFilePicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = url.startAccessingSecurityScopedResource()
                parameters.sourceAudioPath = url.path
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    private var generationModeCard: some View {
        ParameterCard(title: "Generation Mode", systemImage: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 8) {
                if usesCompactModePicker {
                    Picker("Mode", selection: $parameters.generationMode) {
                        ForEach(StudioGenerationMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("Mode", selection: $parameters.generationMode) {
                        ForEach(StudioGenerationMode.allCases) { mode in
                            Text(modeSegmentTitle(for: mode))
                                .tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                Text(parameters.generationMode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityLabel("Generation mode")
        }
    }

    private var primaryParameterGrid: some View {
        LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
            ParameterCard(title: "BPM", systemImage: "metronome") {
                VStack(spacing: 8) {
                    Text("\(Int(parameters.bpm))")
                        .font(.title)
                        .fontWeight(.bold)
                    Slider(value: $parameters.bpm, in: 60...160, step: 1)
                        .accessibilityLabel("BPM")
                        .accessibilityValue("\(Int(parameters.bpm)) beats per minute")
                        .help("Beats per minute. 60-80 = slow ballad, 90-120 = pop/rock, 120-140 = dance, 140+ = fast electronic")
                    HStack {
                        Text("60")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("160")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("60-80 ballad, 90-120 pop/rock, 120-140 dance, 140+ electronic")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            ParameterCard(title: "Key", systemImage: "music.note") {
                VStack(spacing: 8) {
                    Text(parameters.key)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Picker("Key", selection: $parameters.key) {
                        ForEach(keyOptions, id: \.self) { key in
                            Text(key).tag(key)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Musical key")
                    .accessibilityValue(parameters.key)
                    .help("Musical key and scale. Major keys sound bright and happy; minor keys sound darker and moody.")
                    Text("Major = bright/happy, Minor = dark/moody")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ParameterCard(title: "Seed", systemImage: "dice") {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        TextField("Random", value: Binding(
                            get: { parameters.seed },
                            set: { parameters.seed = $0 }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .accessibilityLabel("Seed value")
                        .accessibilityValue(parameters.seed.map { "\($0)" } ?? "Random")
                        .help("A fixed seed produces the same output every time. Leave empty for a random seed each generation.")

                        if parameters.seed != nil {
                            Button {
                                parameters.seed = nil
                            } label: {
                                Image(systemName: "dice")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear the seed to randomize each generation")
                            .accessibilityLabel("Use random seed")
                        }
                    }
                    Text("Fixed seed = reproducible results. Empty = random each time.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ParameterCard(title: "Duration", systemImage: "clock") {
                VStack(spacing: 8) {
                    Text(parameters.durationFormatted)
                        .font(.title)
                        .fontWeight(.bold)
                    Slider(value: $parameters.duration, in: 10...maxDuration, step: 10)
                        .accessibilityLabel("Duration")
                        .accessibilityValue(parameters.durationFormatted)
                        .help("Track length. Longer durations use more memory and take longer to generate. Over 2 minutes requires a capable GPU.")
                    HStack {
                        Text("0:10")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(maxDurationFormatted)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("Longer tracks use more memory and time")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if maxDuration > 180 {
                        Text("Remote server: up to 8 minutes")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }
                .onChange(of: maxDuration) { _, newMax in
                    if parameters.duration > newMax {
                        parameters.duration = newMax
                    }
                }
            }

            ParameterCard(title: "Style / Caption", systemImage: "waveform") {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("e.g., Aggressive battle rap with heavy 808s and dark synths", text: $parameters.style)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                            .help("The main prompt for generation. Be descriptive: include genre, mood, instruments, vocal style, and energy level.")

                        Button(action: onEnhanceCaption) {
                            HStack(spacing: 4) {
                                if isEnhancingCaption {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                            }
                            .frame(width: 32, height: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(parameters.style.isEmpty || isEnhancingCaption)
                        .accessibilityLabel(isEnhancingCaption ? "Enhancing style description" : "Enhance style with AI")
                        .help("Use AI to expand your short description into a detailed prompt")
                    }
                    Text(isEnhancingCaption ? "Enhancing with AI..." : "Describe genre, mood, instruments, vocals. More detail = better results.")
                        .font(.caption)
                        .foregroundColor(isEnhancingCaption ? .purple : .secondary)
                }
            }
        }
    }

    /// Color for a model availability status dot.
    private func availabilityDotColor(_ avail: ModelAvailability) -> Color {
        switch avail {
        case .available: return .green
        case .unknown: return Color.yellow.opacity(0.7)
        case .notAvailable: return .gray
        }
    }

    /// Human-readable label for why a model is unavailable on the current target.
    private func availabilityLabel(for model: ACEStepModel) -> String {
        switch llmSettings.generationMode {
        case .localOnly:
            return "(Not Downloaded)"
        case .cloudOnly:
            return "(Not on Cloud)"
        case .remoteOnly:
            return "(Not on Server)"
        default:
            if !modelAvailability.isLocallyDownloaded(model) {
                return "(Not Downloaded)"
            }
            return "(Unavailable)"
        }
    }

    private var modelSelectionGrid: some View {
        LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
            ditModelCard
            lmModelCard
            inferenceStepsCard
        }
    }

    private var ditModelCard: some View {
        ParameterCard(title: "DiT Model", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Model", selection: $parameters.model) {
                    ForEach(ACEStepModel.availableModels) { model in
                        ditModelRow(model)
                            .tag(model.rawValue)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Generation model")
                .help("Turbo is fast (4-16 steps) for quick drafts and iteration. SFT/Base uses more steps (16-100) for detailed, polished output.")

                Text(ACEStepModel(rawValue: parameters.model)?.description ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Turbo = fast drafts, SFT/Base = polished output")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func ditModelRow(_ model: ACEStepModel) -> some View {
        let avail = modelAvailability.availability(of: model, mode: llmSettings.generationMode)
        HStack {
            Circle()
                .fill(availabilityDotColor(avail))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(model.displayName)
                    .font(.body)
                    .foregroundColor(avail == .notAvailable ? .secondary : .primary)
                if avail == .notAvailable {
                    Text(availabilityLabel(for: model))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func lmModelRow(_ model: LMModel) -> some View {
        let downloaded = modelAvailability.isLMLocallyDownloaded(model)
        HStack {
            Circle()
                .fill(downloaded ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(model.displayName)
                    .font(.body)
                Text(downloaded ? model.minimumRAMLabel : "\(model.minimumRAMLabel) • Not Downloaded")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var lmModelCard: some View {
        ParameterCard(title: "ACE-Step LM", systemImage: "brain") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("LM Model", selection: $parameters.lmModel) {
                    ForEach(LMModel.allCases) { model in
                        lmModelRow(model)
                            .tag(model.rawValue)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Language model")
                .help("The language model interprets your prompt. 0.6B is fast but less accurate. 1.7B is a good balance. 4B gives the best prompt understanding but uses more memory.")

                Text(LMModel(rawValue: parameters.lmModel)?.description ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Larger models understand prompts better but need more memory")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var inferenceStepsCard: some View {
        ParameterCard(title: "Inference Steps", systemImage: "arrow.triangle.2.circlepath") {
            VStack(spacing: 8) {
                Text("\(parameters.numInferenceSteps)")
                    .font(.title)
                    .fontWeight(.bold)
                let isTurboModel = ACEStepModel(rawValue: parameters.model)?.isTurbo ?? false
                let stepsRange: ClosedRange<Double> = isTurboModel ? 4...16 : 16...100
                Slider(value: Binding(
                    get: { Double(parameters.numInferenceSteps) },
                    set: { parameters.numInferenceSteps = Int($0) }
                ), in: stepsRange, step: 1)
                .accessibilityLabel("Inference steps")
                .accessibilityValue("\(parameters.numInferenceSteps) steps")
                .help("Number of denoising passes. More steps refine the audio quality but take longer. Turbo: 4-16, SFT/Base: 16-100.")
                HStack {
                    Text("\(Int(stepsRange.lowerBound))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(stepsRange.upperBound))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("Each step refines the audio. More = better quality, slower.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .onChange(of: parameters.model) { _, newModel in
                if let model = ACEStepModel(rawValue: newModel) {
                    parameters.numInferenceSteps = model.defaultInferenceSteps
                }
            }
        }
    }

    private var lyricsCard: some View {
        ParameterCard(title: "Lyrics (Optional)", systemImage: "text.quote") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $parameters.lyrics)
                    .font(.body)
                    .frame(minHeight: 150, idealHeight: 200, maxHeight: .infinity)
                    .border(Color.gray.opacity(0.3))
                    .cornerRadius(4)
                    .help("Add lyrics for vocal generation. Use [Verse], [Chorus], [Bridge] tags to structure sections. Leave empty for an instrumental track.")
                Text("Leave empty for instrumental. Use [Verse], [Chorus], [Bridge] tags for structure.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var cfgGuidanceCard: some View {
        LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
            ParameterCard(title: "CFG Guidance", systemImage: "slider.horizontal.3") {
                VStack(spacing: 8) {
                    Text(String(format: "%.1f", parameters.guidanceScale))
                        .font(.title3)
                        .fontWeight(.semibold)
                    Slider(value: $parameters.guidanceScale, in: 1.0...20.0, step: 0.5)
                        .accessibilityLabel("CFG guidance scale")
                        .accessibilityValue(String(format: "%.1f", parameters.guidanceScale))
                        .help("Classifier-free guidance scale. Higher values make the model follow your prompt more literally. Lower values give more creative freedom. 3-7 is typical.")
                    HStack {
                        Text("1.0")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("20.0")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("Higher = follows prompt closely. Lower = more creative. 3-7 typical.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var advancedParametersSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                musicalSettingsGrid
                diffusionControlsSection
                languageModelControlsSection
            }
            .padding(.top, 8)
        } label: {
            Label("Advanced Parameters", systemImage: "gearshape.2")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }

    private var musicalSettingsGrid: some View {
        LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
            ParameterCard(title: "Time Signature", systemImage: "music.note.list") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Time Signature", selection: $parameters.timeSignature) {
                        Text("4/4 (Standard)").tag("4")
                        Text("3/4 (Waltz)").tag("3")
                        Text("2/4 (March)").tag("2")
                        Text("6/8 (Compound)").tag("6")
                    }
                    .labelsHidden()
                    .accessibilityLabel("Time signature")
                    .accessibilityValue({
                        switch parameters.timeSignature {
                        case "4": return "4/4 Standard"
                        case "3": return "3/4 Waltz"
                        case "2": return "2/4 March"
                        case "6": return "6/8 Compound"
                        default: return parameters.timeSignature
                        }
                    }())
                    .help("The rhythmic pulse. 4/4 is standard for pop, rock, electronic. 3/4 for waltz, folk. 6/8 for ballads and jigs.")

                    Text("4/4 for most genres. 3/4 for waltz/folk. 6/8 for ballads/jigs.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ParameterCard(title: "Vocal Language", systemImage: "globe") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Language", selection: $parameters.vocalLanguage) {
                        Text("Auto-detect").tag("")
                        Text("English").tag("en")
                        Text("Chinese").tag("zh")
                        Text("Japanese").tag("ja")
                        Text("Korean").tag("ko")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Spanish").tag("es")
                    }
                    .labelsHidden()
                    .accessibilityLabel("Vocal language")
                    .accessibilityValue(parameters.vocalLanguage.isEmpty ? "Auto-detect" : parameters.vocalLanguage)
                    .help("Set the language for vocals. Auto-detect works well when lyrics are provided. Set manually if the model guesses wrong.")

                    Text("Auto-detect works when lyrics are provided. Set manually if needed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var diffusionControlsSection: some View {
        DisclosureGroup(isExpanded: $showDiffusionControls) {
            LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
                ParameterCard(title: "Shift", systemImage: "dial.medium") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Shift", value: nonNegativeDoubleBinding(\.shift), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Timestep shift factor for diffusion scheduling.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ParameterCard(title: "Infer Method", systemImage: "arrow.triangle.branch") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Infer Method", selection: $parameters.inferMethod) {
                            Text("ODE").tag("ode")
                            Text("SDE").tag("sde")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        Text("ODE is deterministic. SDE adds stochastic sampling.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ParameterCard(title: "ADG", systemImage: "slider.horizontal.below.square.filled.and.square") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable Adaptive Dual Guidance", isOn: $parameters.useAdg)
                            .toggleStyle(.checkbox)
                        Text("Best suited to supported base-model workflows.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ParameterCard(title: "CFG Interval", systemImage: "timeline.selection") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Start")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                TextField("0.0", value: cfgIntervalStartBinding, format: .number)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("End")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                TextField("1.0", value: cfgIntervalEndBinding, format: .number)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        Text("Normalized start and end points for applying CFG.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Diffusion Controls", systemImage: "aqi.medium")
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding()
        .background(Color.gray.opacity(0.04))
        .cornerRadius(10)
    }

    private var languageModelControlsSection: some View {
        DisclosureGroup(isExpanded: $showLanguageModelControls) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
                    ParameterCard(title: "LM Temperature", systemImage: "thermometer.medium") {
                        VStack(spacing: 8) {
                            Text(String(format: "%.1f", parameters.lmTemperature))
                                .font(.title3)
                                .fontWeight(.semibold)
                            Slider(value: $parameters.lmTemperature, in: 0.1...2.0, step: 0.1)
                                .accessibilityLabel("LM temperature")
                                .accessibilityValue(String(format: "%.1f", parameters.lmTemperature))
                                .help("Controls randomness in the language model. Low (0.1-0.5) = safe and repetitive. Medium (0.7-1.0) = balanced. High (1.2+) = wild and experimental.")
                            HStack {
                                Text("0.1")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("2.0")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text("Low = safe/repetitive, Medium = balanced, High = experimental")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    ParameterCard(title: "LM Guidance", systemImage: "tuningfork") {
                        VStack(spacing: 8) {
                            Text(String(format: "%.1f", parameters.lmCfgScale))
                                .font(.title3)
                                .fontWeight(.semibold)
                            Slider(value: $parameters.lmCfgScale, in: 0.5...10.0, step: 0.5)
                                .accessibilityLabel("LM guidance scale")
                                .accessibilityValue(String(format: "%.1f", parameters.lmCfgScale))
                                .help("Language model guidance strength. Higher values make the LM stick closely to your text description. Lower values allow more musical freedom.")
                            HStack {
                                Text("0.5")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("10.0")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text("Higher = strict prompt adherence. Lower = musical freedom.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    ParameterCard(title: "Thinking", systemImage: "brain.filled.head.profile") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Enable LM thinking", isOn: $parameters.thinking)
                                .toggleStyle(.checkbox)
                            Text("Uses deeper LM reasoning for semantic and music metadata generation.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    ParameterCard(title: "Top-K", systemImage: "number") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("0", value: nonNegativeIntBinding(\.lmTopK), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.title3)
                                .fontWeight(.semibold)
                            Text("0 disables top-k sampling.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    ParameterCard(title: "Top-P", systemImage: "chart.line.uptrend.xyaxis") {
                        VStack(spacing: 8) {
                            Text(String(format: "%.2f", parameters.lmTopP))
                                .font(.title3)
                                .fontWeight(.semibold)
                            Slider(value: clampedDoubleBinding(\.lmTopP, range: 0.0...1.0), in: 0.0...1.0, step: 0.05)
                                .accessibilityLabel("LM top-p")
                                .accessibilityValue(String(format: "%.2f", parameters.lmTopP))
                            HStack {
                                Text("0.0")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("1.0")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text("1.0 disables nucleus sampling.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    // Repetition Penalty slider removed — ACE-Step GenerationParams
                    // does not support lm_repetition_penalty; the control was misleading.

                    ParameterCard(title: "Constrained Decoding", systemImage: "checkmark.shield") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Enable constrained decoding", isOn: $parameters.constrainedDecoding)
                                .toggleStyle(.checkbox)
                            Text("Applies FSM constraints during LM generation when supported.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                ParameterCard(title: "Negative Prompt", systemImage: "text.badge.minus") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $parameters.lmNegativePrompt)
                            .font(.body)
                            .frame(minHeight: 90)
                            .border(Color.gray.opacity(0.3))
                            .cornerRadius(4)
                        Text("Used for LM-side CFG. Keep `NO USER INPUT` to preserve the default unconditional prompt.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Language Model Controls", systemImage: "brain")
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding()
        .background(Color.gray.opacity(0.04))
        .cornerRadius(10)
    }

    private var libraryOrganizationGrid: some View {
        LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
            ParameterCard(title: "Artist", systemImage: "person.fill") {
                VStack(alignment: .leading, spacing: 8) {
                    AutocompleteTextField(
                        placeholder: "Artist name",
                        text: $parameters.artist,
                        suggestions: library.getAllArtists().filter {
                            $0 != "Working Files"
                        }
                    )
                    .font(.body)
                    Text("Organize in library by artist")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .zIndex(2)

            ParameterCard(title: "Album", systemImage: "square.stack.fill") {
                VStack(alignment: .leading, spacing: 8) {
                    AutocompleteTextField(
                        placeholder: "Album name",
                        text: $parameters.album,
                        suggestions: library.getAllAlbums(for: parameters.artist.isEmpty ? nil : parameters.artist).filter {
                            $0 != "Unsorted"
                        }
                    )
                    .font(.body)
                    Text("Group tracks into albums")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .zIndex(1)
        }
    }

    // MARK: - Cover Mode Controls

    private var coverModeControls: some View {
        LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
            ParameterCard(title: "Reference Audio", systemImage: "music.note") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if parameters.referenceAudioPath.isEmpty {
                            Text("No file selected")
                                .foregroundColor(.secondary)
                                .font(.body)
                        } else {
                            Text(URL(fileURLWithPath: parameters.referenceAudioPath).lastPathComponent)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Browse...") {
                            showReferenceFilePicker = true
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Choose reference audio file")

                        if !parameters.referenceAudioPath.isEmpty {
                            Button {
                                parameters.referenceAudioPath = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear reference audio")
                        }
                    }
                    Text("Audio file whose style will be transferred to the new track")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ParameterCard(title: "Cover Strength", systemImage: "dial.medium") {
                VStack(spacing: 8) {
                    Text(String(format: "%.0f%%", parameters.coverStrength * 100))
                        .font(.title3)
                        .fontWeight(.semibold)
                    Slider(value: $parameters.coverStrength, in: 0.0...1.0, step: 0.05)
                        .accessibilityLabel("Cover strength")
                        .accessibilityValue(String(format: "%.0f percent", parameters.coverStrength * 100))
                        .help("How closely the output matches the reference audio")
                    HStack {
                        Text("Style Transfer")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Close Cover")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("Low = creative reinterpretation, High = faithful cover")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    // MARK: - Continuation Mode Controls

    private var continuationModeControls: some View {
        LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
            sourceAudioCard(
                caption: "Audio track to continue/extend. Duration 0 = double the source length.",
                browseLabel: "Choose source audio file to continue"
            )
        }
    }

    // MARK: - Lego / Extract / Repaint / Auto

    private var legoModeControls: some View {
        LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
            sourceAudioCard(
                caption: "Existing track the new stem should fit. Duration 0 matches the source length.",
                browseLabel: "Choose source audio file for Lego"
            )
            ParameterCard(title: "Stem to Generate", systemImage: "square.stack.3d.up") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("bass, guitar, sax lead…", text: $parameters.legoInstruction)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("What stem to generate")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(["bass", "drums", "guitar", "keys", "vocals", "sax"], id: \.self) { chip in
                            Button(chip) {
                                parameters.legoInstruction = chip
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Set stem to \(chip)")
                        }
                    }
                    Text("Required. Style describes the sound; this names the part (bass, sax lead, …).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var extractModeControls: some View {
        LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
            sourceAudioCard(
                caption: "Mix to isolate stems from.",
                browseLabel: "Choose source audio file to extract stems from"
            )
            ParameterCard(title: "Stems to Extract", systemImage: "rectangle.3.group") {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(MusicParameters.extractStemChoices, id: \.self) { stem in
                            Toggle(stem.capitalized, isOn: extractStemBinding(stem))
                                .toggleStyle(.checkbox)
                                .accessibilityLabel("Extract \(stem)")
                        }
                    }
                    Text("Choose at least one part to isolate.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var repaintModeControls: some View {
        LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
            sourceAudioCard(
                caption: "Track whose selected time range will be regenerated.",
                browseLabel: "Choose source audio file to repaint"
            )
            ParameterCard(title: "Repaint Range", systemImage: "paintbrush") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Start")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatSeconds(parameters.repaintStart))
                            .font(.body.monospacedDigit())
                    }
                    Slider(value: $parameters.repaintStart, in: 0...repaintSliderMax, step: 0.1)
                        .accessibilityLabel("Repaint start time")
                        .accessibilityValue(formatSeconds(parameters.repaintStart))
                    Toggle("To end of track", isOn: repaintToEndBinding)
                        .accessibilityLabel("Repaint through the end of the track")
                    if !repaintToEnd {
                        HStack {
                            Text("End")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatSeconds(parameters.repaintEnd))
                                .font(.body.monospacedDigit())
                        }
                        Slider(value: $parameters.repaintEnd, in: 0...repaintSliderMax, step: 0.1)
                            .accessibilityLabel("Repaint end time")
                            .accessibilityValue(formatSeconds(parameters.repaintEnd))
                    }
                    Text("Only this slice is regenerated. The rest of the track stays.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var autoCompleteModeControls: some View {
        LazyVGrid(columns: parameterGridColumns, alignment: .leading, spacing: 12) {
            sourceAudioCard(
                caption: "Partial mix to fill missing instruments around.",
                browseLabel: "Choose source audio file to auto-complete"
            )
        }
    }

    private func sourceAudioCard(caption: String, browseLabel: String) -> some View {
        ParameterCard(title: "Source Audio", systemImage: "waveform.badge.plus") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if parameters.sourceAudioPath.isEmpty {
                        Text("No file selected")
                            .foregroundColor(.secondary)
                            .font(.body)
                    } else {
                        Text(URL(fileURLWithPath: parameters.sourceAudioPath).lastPathComponent)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Browse...") {
                        showSourceFilePicker = true
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(browseLabel)

                    if !parameters.sourceAudioPath.isEmpty {
                        Button {
                            parameters.sourceAudioPath = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear source audio")
                    }
                }
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func extractStemBinding(_ stem: String) -> Binding<Bool> {
        Binding(
            get: { parameters.extractStems.contains(stem) },
            set: { isOn in
                parameters.extractStems = MusicParameters.extractStemChoices.filter { choice in
                    if choice == stem { return isOn }
                    return parameters.extractStems.contains(choice)
                }
            }
        )
    }

    private var repaintSliderMax: Double {
        max(parameters.duration, 1)
    }

    private var repaintToEnd: Bool {
        parameters.repaintEnd < 0
    }

    private var repaintToEndBinding: Binding<Bool> {
        Binding(
            get: { parameters.repaintEnd < 0 },
            set: { toEnd in
                if toEnd {
                    parameters.repaintEnd = -1
                } else if parameters.repaintEnd < 0 {
                    parameters.repaintEnd = max(parameters.repaintStart + 1, min(repaintSliderMax, parameters.duration))
                }
            }
        )
    }

    private func formatSeconds(_ value: Double) -> String {
        let minutes = Int(value) / 60
        let seconds = value.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%04.1f", minutes, seconds)
    }

    private func modeSegmentTitle(for mode: StudioGenerationMode) -> String {
        switch mode {
        case .textToMusic:
            return "Text"
        case .cover:
            return "Cover"
        case .continuation:
            return "Continue"
        case .repaint:
            return "Repaint"
        case .extract:
            return "Extract"
        case .lego:
            return "Lego"
        case .autoComplete:
            return "Auto"
        }
    }

    private func clampedDoubleBinding(_ keyPath: WritableKeyPath<MusicParameters, Double>, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { parameters[keyPath: keyPath] },
            set: { parameters[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, $0)) }
        )
    }

    private func nonNegativeDoubleBinding(_ keyPath: WritableKeyPath<MusicParameters, Double>) -> Binding<Double> {
        Binding(
            get: { parameters[keyPath: keyPath] },
            set: { parameters[keyPath: keyPath] = max(0, $0) }
        )
    }

    private func nonNegativeIntBinding(_ keyPath: WritableKeyPath<MusicParameters, Int>) -> Binding<Int> {
        Binding(
            get: { parameters[keyPath: keyPath] },
            set: { parameters[keyPath: keyPath] = max(0, $0) }
        )
    }

    private var cfgIntervalStartBinding: Binding<Double> {
        Binding(
            get: { parameters.cfgIntervalStart },
            set: { parameters.cfgIntervalStart = min(parameters.cfgIntervalEnd, max(0.0, $0)) }
        )
    }

    private var cfgIntervalEndBinding: Binding<Double> {
        Binding(
            get: { parameters.cfgIntervalEnd },
            set: { parameters.cfgIntervalEnd = max(parameters.cfgIntervalStart, min(1.0, $0)) }
        )
    }
}

struct ParameterCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundColor(.secondary)

            content
        }
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Generation Progress

struct GenerationProgressView: View {
    let progress: Double
    let message: String
    let gpuStatus: GPUQueueStatus

    var body: some View {
        VStack(spacing: 16) {
            // Main progress section
            VStack(spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundColor(.blue)
                            .font(.title3)
                        Text("Generating Music")
                            .font(.headline)
                    }
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .accessibilityLabel("Generation progress")
                    .accessibilityValue("\(Int(progress * 100)) percent")

                if !message.isEmpty {
                    HStack {
                        Image(systemName: "info.circle")
                            .font(.caption)
                        Text(message)
                            .font(.caption)
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.08))
            )

            // GPU monitoring panel
            if gpuStatus.isActive {
                GPUMonitoringPanel(gpuStatus: gpuStatus)
            }
        }
    }
}

struct GPUMonitoringPanel: View {
    let gpuStatus: GPUQueueStatus

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .foregroundColor(.orange)
                    Text("GPU Activity")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                Spacer()
                Text(gpuStatus.currentStage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                GPUCard(
                    gpuName: "Metal GPU 1",
                    progress: gpuStatus.gpu1Progress,
                    color: .orange
                )
                GPUCard(
                    gpuName: "Metal GPU 2",
                    progress: gpuStatus.gpu2Progress,
                    color: .purple
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct GPUCard: View {
    let gpuName: String
    let progress: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "memorychip")
                    .font(.caption)
                    .foregroundColor(color)
                Text(gpuName)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            VStack(spacing: 4) {
                HStack {
                    Text("\(Int(progress * 100))%")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(color)
                    Spacer()
                    Image(systemName: progress > 0 ? "bolt.fill" : "bolt.slash")
                        .font(.caption)
                        .foregroundColor(progress > 0 ? color : .gray)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))

                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [color, color.opacity(0.6)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.08))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(gpuName)")
        .accessibilityValue("\(Int(progress * 100)) percent utilization")
    }
}

// MARK: - Interactive Waveform

struct InteractiveWaveformView: View {
    @Binding var sections: [Section]
    @Binding var currentTime: Double
    let duration: Double
    let isPlaying: Bool
    @State private var selectedSection: Section?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(.secondary)
                Text("Arrangement")
                    .font(.headline)
                Spacer()
                Text("Click sections to edit")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background waveform bars
                    WaveformBarsView(width: geometry.size.width, height: geometry.size.height)

                    // Section boxes
                    ForEach(sections) { section in
                        SectionBoxView(
                            section: section,
                            totalDuration: duration,
                            width: geometry.size.width,
                            height: geometry.size.height,
                            isSelected: selectedSection?.id == section.id
                        )
                        .onTapGesture {
                            selectedSection = section
                        }
                        .accessibilityLabel("\(section.label) section")
                        .accessibilityHint("Double-tap to select this section")
                        .accessibilityAddTraits(.isButton)
                    }

                    // Playhead cursor (always visible when time > 0)
                    if currentTime > 0 || isPlaying {
                        PlayheadView(currentTime: currentTime, duration: duration, width: geometry.size.width)
                    }
                }
            }
            .frame(height: 120)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(12)

            // Section legend
            HStack(spacing: 8) {
                ForEach(sections) { section in
                    SectionLegendButton(
                        section: section,
                        isSelected: selectedSection?.id == section.id,
                        onTap: { selectedSection = section }
                    )
                }
                Spacer()
            }
        }
    }
}

struct WaveformBarsView: View {
    let width: CGFloat
    let height: CGFloat

    // Pre-computed random fractions (0...1) so bars don't re-randomize on every render
    private static let barFractions: [CGFloat] = (0..<500).map { _ in CGFloat.random(in: 0.25...1.0) }

    var body: some View {
        let barCount = max(0, Int(width / 3))
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.blue.opacity(0.3))
                    .frame(width: 2, height: Self.barFractions[i % Self.barFractions.count] * height * 0.8)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

struct SectionBoxView: View {
    let section: Section
    let totalDuration: Double
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool

    var sectionColor: Color {
        switch section.mood {
        case "intro": return .purple
        case "verse": return .blue
        case "hook": return .orange
        case "bridge": return .green
        case "outro": return .purple
        default: return .gray
        }
    }

    var body: some View {
        let startX = (section.start / totalDuration) * width
        let sectionWidth = ((section.end - section.start) / totalDuration) * width

        VStack(alignment: .leading, spacing: 2) {
            Text(section.label)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            Spacer()
        }
        .padding(6)
        .frame(width: sectionWidth, height: height)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(sectionColor.opacity(isSelected ? 0.7 : 0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? .white : .clear, lineWidth: 2)
                )
        )
        .offset(x: startX)
    }
}

struct PlayheadView: View {
    let currentTime: Double
    let duration: Double
    let width: CGFloat

    var body: some View {
        let position = (currentTime / duration) * width

        Rectangle()
            .fill(Color.red)
            .frame(width: 2)
            .offset(x: position)
    }
}

struct SectionLegendButton: View {
    let section: Section
    let isSelected: Bool
    let onTap: () -> Void

    var sectionColor: Color {
        switch section.mood {
        case "intro": return .purple
        case "verse": return .blue
        case "hook": return .orange
        case "bridge": return .green
        case "outro": return .purple
        default: return .gray
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Circle()
                    .fill(sectionColor)
                    .frame(width: 8, height: 8)
                Text(section.label)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? sectionColor.opacity(0.2) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(section.label) section")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

// MARK: - Variants Grid

struct VariantsGridView: View {
    @Binding var variants: [Variant]
    let player: AudioPlayer
    let onDelete: (Variant) -> Void
    let availableWidth: CGFloat

    private var columns: [GridItem] {
        if availableWidth < 980 {
            return [GridItem(.flexible(), spacing: 12, alignment: .top)]
        }

        return [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.grid.2x2")
                    .foregroundColor(.secondary)
                Text("Results")
                    .font(.headline)
                Spacer()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach($variants) { $variant in
                    VariantCard(variant: $variant, player: player, onDelete: onDelete)
                }
            }
        }
    }
}

struct VariantCard: View {
    @Binding var variant: Variant
    let player: AudioPlayer
    let onDelete: (Variant) -> Void
    @State private var isPicked = false
    @State private var isHovered = false
    @State private var exportStatus: String = ""
    @State private var showExportAlert = false
    @State private var exportAlertMessage = ""
    @State private var exportedFilePath: String?
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var backend: BackendViewModel
    @EnvironmentObject var licenseManager: LicenseManager

    @State private var isEditingTitle = false
    @FocusState private var isTitleFieldFocused: Bool

    private var stagingTrack: StagingTrack? {
        sessionStore.currentSession?.stagingTracks.first { $0.variantId == variant.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            variantHeader
            MiniWaveformView()
            ratingSection
            metadataSection
            Divider()
            actionSection
        }
        .padding(14)
        .background(cardBackground)
        .shadow(color: Color.black.opacity(isHovered ? 0.15 : 0.05), radius: isHovered ? 8 : 4, x: 0, y: 2)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .alert("Export", isPresented: $showExportAlert) {
            if let path = exportedFilePath {
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage)
        }
    }

    private var variantHeader: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 32, height: 32)
                Text(variant.displayLabel)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                if isEditingTitle {
                    TextField("Title", text: $variant.title, onCommit: {
                        finishEditingTitle()
                    })
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .focused($isTitleFieldFocused)
                } else {
                    HStack(spacing: 4) {
                        Text(variant.title)
                            .font(.headline)
                            .onTapGesture(count: 2) {
                                startEditingTitle()
                            }

                        if isHovered {
                            Button(action: {
                                startEditingTitle()
                            }) {
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit title")
                        }
                    }
                }

                Text(formatDuration(variant.duration))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isPicked {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.green)
                    .accessibilityLabel("Picked")
            }
        }
    }

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<5) { i in
                    Image(systemName: i < variant.rating ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundColor(i < variant.rating ? .yellow : .gray.opacity(0.3))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rating")
            .accessibilityValue("\(variant.rating) out of 5 stars")
            Text(variant.note)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
    }

    private var metadataSection: some View {
        HStack(spacing: 6) {
            MetadataPill(icon: "metronome", text: "\(Int(variant.bpm)) BPM")
            MetadataPill(icon: "music.note", text: variant.key)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if case .queued = variant.status {
            // Queued state — waiting in queue
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Waiting in queue...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                Button(action: { onDelete(variant) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                        Text("Remove")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .accessibilityLabel("Remove \(variant.title) from queue")
            }
        } else if case .generating(let progress) = variant.status {
            VStack(spacing: 6) {
                HStack {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 35)
                }
                Text("Generating variant...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } else if case .failed(let message) = variant.status {
            // Failed state
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(message)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(5)
                        .textSelection(.enabled)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Generation failed: \(message)")
                .contextMenu {
                    Button("Copy Error") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    }
                }
                Button(action: { onDelete(variant) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Remove")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityLabel("Remove failed variant \(variant.title)")
            }
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Button(action: { togglePlay() }) {
                        HStack(spacing: 4) {
                            Image(systemName: player.isPlaying && isCurrentlyPlaying() ? "pause.fill" : "play.fill")
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(player.isPlaying && isCurrentlyPlaying() ? "Pause \(variant.title)" : "Play \(variant.title)")

                    Button(action: { stopPlay() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .accessibilityLabel("Stop playback")

                    // Export menu
                    Menu {
                        Button(action: { exportVariant(format: "WAV") }) {
                            Label("Export WAV", systemImage: "doc")
                        }
                        Button(action: { exportVariant(format: "FLAC") }) {
                            Label("Export FLAC", systemImage: "doc")
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Export \(variant.title)")

                    // ACE Music sharing (coming soon)
                    Button { } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "music.note.house")
                            Text("ACE Music")
                                .font(.caption2)
                            Text("Soon")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.2))
                                .cornerRadius(3)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .help("Share to acemusic.ai — coming soon!")
                }

                // Keep checkbox and Delete button for staging workflow
                HStack(spacing: 6) {
                    Toggle("Keep", isOn: Binding(
                        get: {
                            // Default to true when no staging track exists yet
                            stagingTrack?.isMarkedForKeep ?? true
                        },
                        set: { newValue in
                            // Only update if staging track exists
                            if var track = stagingTrack {
                                track.isMarkedForKeep = newValue
                                sessionStore.updateStagingTrack(track)
                            }
                        }
                    ))
                    .font(.body)
                    .toggleStyle(.switch)
                    .disabled(stagingTrack == nil)
                    .accessibilityLabel("Keep \(variant.title)")
                    .accessibilityValue(stagingTrack?.isMarkedForKeep ?? true ? "On" : "Off")
                    .help(stagingTrack == nil
                        ? "Generate track first to enable Keep toggle"
                        : "Toggle to mark this track for saving to your library")

                    Spacer()

                    Button(action: { onDelete(variant) }) {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .accessibilityLabel("Delete \(variant.title)")
                }
                .padding(.top, 2)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isPicked ? Color.green.opacity(0.05) : Color.gray.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isPicked ? Color.green.opacity(0.5) : (isHovered ? Color.blue.opacity(0.3) : Color.clear),
                        lineWidth: isPicked ? 2 : 1
                    )
            )
    }

    private func togglePlay() {
        if let audioPath = variant.audioPath {
            let url = URL(fileURLWithPath: audioPath)
            if isCurrentlyPlaying() {
                player.pause()
            } else {
                player.load(url: url)
                player.nowPlaying = NowPlayingInfo(
                    title: variant.title,
                    artist: "",
                    album: "",
                    duration: variant.duration,
                    artworkURL: nil
                )
                player.play()
            }
        }
    }

    private func stopPlay() {
        player.stop()
    }

    private func isCurrentlyPlaying() -> Bool {
        guard let audioPath = variant.audioPath else { return false }
        return player.isPlaying && player.currentURL?.path == audioPath
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func exportVariant(format: String) {
        guard let audioPath = variant.audioPath else {
            exportAlertMessage = "No audio available to export"
            showExportAlert = true
            return
        }

        Task {
            do {
                let fileExtension = format.lowercased()
                let exportName = variant.title.isEmpty ? "export_\(variant.id)_\(Date().timeIntervalSince1970)" : variant.title
                let outputPath = FileStore.shared.baseDirectory
                    .appendingPathComponent("\(exportName).\(fileExtension)")
                    .path

                let exportedPath = try await backend.exportTrack(
                    filePath: audioPath,
                    outputPath: outputPath,
                    format: fileExtension
                )

                await MainActor.run {
                    exportAlertMessage = "Exported Version \(variant.displayLabel) as \(format.uppercased())"
                    exportedFilePath = exportedPath
                    showExportAlert = true
                }

                AppLog.info("Export complete: \(exportedPath)")
            } catch {
                await MainActor.run {
                    exportAlertMessage = "Export failed: \(error.localizedDescription)"
                    exportedFilePath = nil
                    showExportAlert = true
                }
                AppLog.error("Export error: \(error)")
            }
        }
    }

    private func startEditingTitle() {
        isEditingTitle = true
        isTitleFieldFocused = true
    }

    private func finishEditingTitle() {
        isEditingTitle = false

        if let track = stagingTrack {
            var updatedTrack = track
            updatedTrack.title = variant.title
            sessionStore.updateStagingTrack(updatedTrack)
        }
    }
}

struct MiniWaveformView: View {
    // Pre-computed random heights so the waveform stays stable across re-renders
    private static let barHeights: [CGFloat] = (0..<40).map { _ in CGFloat.random(in: 8...32) }

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<40, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.6), .purple.opacity(0.4)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 2, height: Self.barHeights[i])
            }
        }
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.05))
        .cornerRadius(6)
        .accessibilityHidden(true)
    }
}

struct MetadataPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Volume Control Component

struct VolumeControlView: View {
    @Binding var volume: Double
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 8) {
            if isExpanded {
                Slider(value: $volume, in: 0...1)
                    .frame(width: 100)
                    .controlSize(.small)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int(volume * 100)) percent")
            }

            Button(action: { isExpanded.toggle() }) {
                Image(systemName: volumeIcon)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isExpanded ? "Hide volume slider" : "Show volume slider")
            .accessibilityValue("\(Int(volume * 100)) percent")
            .help("Volume: \(Int(volume * 100))%")
        }
        .padding(8)
        .background(.regularMaterial)
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private var volumeIcon: String {
        if volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}
