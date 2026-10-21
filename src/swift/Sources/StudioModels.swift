import Foundation

// MARK: - Generation Mode

enum StudioGenerationMode: String, CaseIterable, Identifiable, Codable {
    case textToMusic = "text2music"
    case cover = "cover"
    case continuation = "complete"
    case repaint = "repaint"
    case extract = "extract"
    case lego = "lego"
    case autoComplete = "auto_complete"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .textToMusic: return "Text to Music"
        case .cover: return "Cover / Style Transfer"
        case .continuation: return "Continue Track"
        case .repaint: return "Repaint"
        case .extract: return "Extract Stems"
        case .lego: return "Lego (Stem Builder)"
        case .autoComplete: return "Auto-Complete"
        }
    }

    var description: String {
        switch self {
        case .textToMusic:
            return "Generate new music from a text description."
        case .cover:
            return "Create a new version using a reference track's style."
        case .continuation:
            return "Extend an existing track with new audio."
        case .repaint:
            return "Regenerate a specific time range within an existing track."
        case .extract:
            return "Isolate individual instruments or stems from a mix."
        case .lego:
            return "Generate a new stem that fits with existing tracks."
        case .autoComplete:
            return "Automatically fill in missing instruments for a partial mix."
        }
    }

    var systemImage: String {
        switch self {
        case .textToMusic: return "text.below.photo"
        case .cover: return "arrow.triangle.2.circlepath.doc.on.clipboard"
        case .continuation: return "arrow.right.to.line"
        case .repaint: return "paintbrush"
        case .extract: return "rectangle.3.group"
        case .lego: return "square.stack.3d.up"
        case .autoComplete: return "wand.and.stars.inverse"
        }
    }

    /// Whether this mode requires the base model (not turbo/sft).
    var requiresBaseModel: Bool {
        switch self {
        case .repaint, .extract, .lego, .autoComplete:
            return true
        case .textToMusic, .cover, .continuation:
            return false
        }
    }

    /// Whether this mode requires source audio input.
    var requiresSourceAudio: Bool {
        switch self {
        case .repaint, .extract, .continuation, .autoComplete, .lego:
            return true
        case .textToMusic:
            return false
        case .cover:
            return false  // cover uses referenceAudioPath instead
        }
    }
}

// MARK: - Studio Data Models

struct MusicParameters: Equatable, Codable {
    var bpm: Double = 88
    var key: String = "E♭ minor"
    var duration: Double = 60  // seconds (reduced default for faster generation)
    var style: String = "Aggressive battle rap"
    var variantCount: Int = 1  // 1-5 variants to generate (default to 1)
    var model: String = "acestep-v15-turbo"  // ACE-Step DiT model to use
    var lmModel: String = LMModel.defaultRawValueForCurrentMac  // Language model size (0.6B/1.7B/4B)
    var guidanceScale: Double = 4.5  // APG guidance scale (1.0-20.0) for prompt adherence
    var lyrics: String = ""  // Optional lyrics for vocal generation
    var artist: String = ""  // Artist name for library organization
    var album: String = ""  // Album name for library organization
    var genre: String = ""  // Genre for generation metadata
    var mood: String = ""  // Mood descriptor
    var contentType: String = ""  // "news_narrative" | "news_beats" | "personal"
    var topic: String = ""  // Topic for pipeline metadata
    var topicTags: [String] = []  // Topic tags for pipeline
    var seed: Int? = nil  // nil = random seed each time
    var numInferenceSteps: Int = 8  // Turbo: 8, SFT/Base: 32-100
    var lmTemperature: Double = 0.9  // LM creativity (0.1-2.0)
    var lmCfgScale: Double = 2.5  // LM guidance strength (0.5-10.0)
    var timeSignature: String = "4"  // "2" (2/4), "3" (3/4), "4" (4/4), "6" (6/8)
    var vocalLanguage: String = ""  // en, zh, ja, etc. Empty = auto-detect

    // Generation mode controls
    var generationMode: StudioGenerationMode = .textToMusic
    var referenceAudioPath: String = ""  // For cover/style transfer mode
    var coverStrength: Double = 0.5  // 0.0-1.0: lower = more style transfer, higher = closer to original
    var sourceAudioPath: String = ""  // For continuation/repaint/extract/lego/complete modes

    // Repaint mode parameters
    var repaintStart: Double = 0.0  // seconds - start of time range to repaint
    var repaintEnd: Double = -1.0   // seconds - end of time range (-1 = end of track)

    // Extract mode parameters
    var extractStems: [String] = []  // Which stems to extract (e.g. ["vocals", "drums"])

    // Lego mode parameters
    var legoInstruction: String = ""  // What stem to generate (e.g. "bass")

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

    var durationFormatted: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Stem names ACE-Step extract understands. Keep in mixer/canonical order.
    static let extractStemChoices = ["vocals", "drums", "bass", "guitar", "piano", "other"]

    /// User-facing reason Generate would fail this mode's RPC requirements, or nil if ready.
    func generationValidationError() -> String? {
        // Extract isolates existing audio; it does not need a style prompt.
        if generationMode != .extract,
           style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Please enter a style description before generating."
        }
        switch generationMode {
        case .textToMusic:
            return nil
        case .cover:
            if referenceAudioPath.isEmpty {
                return "Please select a reference audio file for cover/style transfer mode."
            }
            return nil
        case .continuation:
            if sourceAudioPath.isEmpty {
                return "Please select a source audio file for continuation mode."
            }
            return nil
        case .repaint:
            if sourceAudioPath.isEmpty {
                return "Please select a source audio file for repaint mode."
            }
            if repaintEnd >= 0 && repaintEnd <= repaintStart {
                return "Repaint end must be after the start time, or set to the end of the track."
            }
            return nil
        case .extract:
            if sourceAudioPath.isEmpty {
                return "Please select a source audio file for extract mode."
            }
            if extractStems.isEmpty {
                return "Please choose at least one stem to extract."
            }
            return nil
        case .lego:
            if sourceAudioPath.isEmpty {
                return "Please select a source audio file for Lego mode. Lego generates a new stem that fits this track."
            }
            if legoInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Please say what stem to generate (for example: bass, guitar, sax lead)."
            }
            return nil
        case .autoComplete:
            if sourceAudioPath.isEmpty {
                return "Please select a source audio file for auto-complete mode."
            }
            return nil
        }
    }

    // Custom decoding to handle old session files missing new fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try container.decodeIfPresent(Double.self, forKey: .bpm) ?? 88
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? "E♭ minor"
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 60
        style = try container.decodeIfPresent(String.self, forKey: .style) ?? "Aggressive battle rap"
        variantCount = try container.decodeIfPresent(Int.self, forKey: .variantCount) ?? 1
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "acestep-v15-turbo"
        lmModel = try container.decodeIfPresent(String.self, forKey: .lmModel) ?? LMModel.defaultRawValueForCurrentMac
        guidanceScale = try container.decodeIfPresent(Double.self, forKey: .guidanceScale) ?? 4.5
        lyrics = try container.decodeIfPresent(String.self, forKey: .lyrics) ?? ""
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? ""
        genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? ""
        mood = try container.decodeIfPresent(String.self, forKey: .mood) ?? ""
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType) ?? ""
        topic = try container.decodeIfPresent(String.self, forKey: .topic) ?? ""
        topicTags = try container.decodeIfPresent([String].self, forKey: .topicTags) ?? []
        seed = try container.decodeIfPresent(Int.self, forKey: .seed)
        numInferenceSteps = try container.decodeIfPresent(Int.self, forKey: .numInferenceSteps) ?? 8
        lmTemperature = try container.decodeIfPresent(Double.self, forKey: .lmTemperature) ?? 0.9
        lmCfgScale = try container.decodeIfPresent(Double.self, forKey: .lmCfgScale) ?? 2.5
        timeSignature = try container.decodeIfPresent(String.self, forKey: .timeSignature) ?? "4"
        vocalLanguage = try container.decodeIfPresent(String.self, forKey: .vocalLanguage) ?? ""
        generationMode = try container.decodeIfPresent(StudioGenerationMode.self, forKey: .generationMode) ?? .textToMusic
        referenceAudioPath = try container.decodeIfPresent(String.self, forKey: .referenceAudioPath) ?? ""
        coverStrength = try container.decodeIfPresent(Double.self, forKey: .coverStrength) ?? 0.5
        sourceAudioPath = try container.decodeIfPresent(String.self, forKey: .sourceAudioPath) ?? ""
        repaintStart = try container.decodeIfPresent(Double.self, forKey: .repaintStart) ?? 0.0
        repaintEnd = try container.decodeIfPresent(Double.self, forKey: .repaintEnd) ?? -1.0
        extractStems = try container.decodeIfPresent([String].self, forKey: .extractStems) ?? []
        legoInstruction = try container.decodeIfPresent(String.self, forKey: .legoInstruction) ?? ""
        shift = try container.decodeIfPresent(Double.self, forKey: .shift) ?? 3.0
        inferMethod = try container.decodeIfPresent(String.self, forKey: .inferMethod) ?? "ode"
        useAdg = try container.decodeIfPresent(Bool.self, forKey: .useAdg) ?? false
        cfgIntervalStart = try container.decodeIfPresent(Double.self, forKey: .cfgIntervalStart) ?? 0.0
        cfgIntervalEnd = try container.decodeIfPresent(Double.self, forKey: .cfgIntervalEnd) ?? 1.0
        thinking = try container.decodeIfPresent(Bool.self, forKey: .thinking) ?? true
        lmTopK = try container.decodeIfPresent(Int.self, forKey: .lmTopK) ?? 0
        lmTopP = try container.decodeIfPresent(Double.self, forKey: .lmTopP) ?? 0.9
        lmRepetitionPenalty = try container.decodeIfPresent(Double.self, forKey: .lmRepetitionPenalty) ?? 1.0
        lmNegativePrompt = try container.decodeIfPresent(String.self, forKey: .lmNegativePrompt) ?? "NO USER INPUT"
        constrainedDecoding = try container.decodeIfPresent(Bool.self, forKey: .constrainedDecoding) ?? true
    }

    // Default init for creating new instances
    init(bpm: Double = 88, key: String = "E♭ minor", duration: Double = 60, style: String = "Aggressive battle rap", variantCount: Int = 1, model: String = "acestep-v15-turbo", lmModel: String = LMModel.defaultRawValueForCurrentMac, guidanceScale: Double = 4.5, lyrics: String = "", artist: String = "", album: String = "", genre: String = "", mood: String = "", contentType: String = "", topic: String = "", topicTags: [String] = [], seed: Int? = nil, numInferenceSteps: Int = 8, lmTemperature: Double = 0.9, lmCfgScale: Double = 2.5, timeSignature: String = "4", vocalLanguage: String = "", generationMode: StudioGenerationMode = .textToMusic, referenceAudioPath: String = "", coverStrength: Double = 0.5, sourceAudioPath: String = "", repaintStart: Double = 0.0, repaintEnd: Double = -1.0, extractStems: [String] = [], legoInstruction: String = "", shift: Double = 3.0, inferMethod: String = "ode", useAdg: Bool = false, cfgIntervalStart: Double = 0.0, cfgIntervalEnd: Double = 1.0, thinking: Bool = true, lmTopK: Int = 0, lmTopP: Double = 0.9, lmRepetitionPenalty: Double = 1.0, lmNegativePrompt: String = "NO USER INPUT", constrainedDecoding: Bool = true) {
        self.bpm = bpm
        self.key = key
        self.duration = duration
        self.style = style
        self.variantCount = variantCount
        self.model = model
        self.lmModel = lmModel
        self.guidanceScale = guidanceScale
        self.lyrics = lyrics
        self.artist = artist
        self.album = album
        self.genre = genre
        self.mood = mood
        self.contentType = contentType
        self.topic = topic
        self.topicTags = topicTags
        self.seed = seed
        self.numInferenceSteps = numInferenceSteps
        self.lmTemperature = lmTemperature
        self.lmCfgScale = lmCfgScale
        self.timeSignature = timeSignature
        self.vocalLanguage = vocalLanguage
        self.generationMode = generationMode
        self.referenceAudioPath = referenceAudioPath
        self.coverStrength = coverStrength
        self.sourceAudioPath = sourceAudioPath
        self.repaintStart = repaintStart
        self.repaintEnd = repaintEnd
        self.extractStems = extractStems
        self.legoInstruction = legoInstruction
        self.shift = shift
        self.inferMethod = inferMethod
        self.useAdg = useAdg
        self.cfgIntervalStart = cfgIntervalStart
        self.cfgIntervalEnd = cfgIntervalEnd
        self.thinking = thinking
        self.lmTopK = lmTopK
        self.lmTopP = lmTopP
        self.lmRepetitionPenalty = lmRepetitionPenalty
        self.lmNegativePrompt = lmNegativePrompt
        self.constrainedDecoding = constrainedDecoding
    }
}

// Available ACE-Step models
enum ACEStepModel: String, CaseIterable, Identifiable {
    case turbo = "acestep-v15-turbo"
    case turboRL = "acestep-v15-turbo-rl"
    case sft = "acestep-v15-sft"
    case base = "acestep-v15-base"
    case xlBase = "acestep-v15-xl-base"
    case xlSft = "acestep-v15-xl-sft"
    case xlTurbo = "acestep-v15-xl-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .turbo: return "ACE-Step v1.5 Turbo"
        case .turboRL: return "ACE-Step v1.5 Turbo RL"
        case .sft: return "ACE-Step v1.5 SFT"
        case .base: return "ACE-Step v1.5 Base"
        case .xlBase: return "XL Base (4B)"
        case .xlSft: return "XL SFT (4B)"
        case .xlTurbo: return "XL Turbo (4B)"
        }
    }

    var description: String {
        switch self {
        case .turbo:
            return "Fast generation with 8 inference steps. Best for rapid iteration."
        case .turboRL:
            return "Turbo model fine-tuned with reinforcement learning. Improved quality at turbo speed."
        case .sft:
            return "Supervised fine-tuned model with 32+ steps. Slower but more detailed results."
        case .base:
            return "Full-featured base model. Required for repaint, extract, lego, and auto-complete modes."
        case .xlBase:
            return "4B base model with CFG guidance. Required for repaint, extract, lego, and auto-complete at XL quality."
        case .xlSft:
            return "4B supervised fine-tuned model. Highest fidelity output with 50 inference steps."
        case .xlTurbo:
            return "4B turbo model. XL quality at turbo speed with only 8 inference steps."
        }
    }

    var qualityInfo: String {
        switch self {
        case .turbo:
            return "Professional audio quality with 5Hz language model for vocal generation."
        case .turboRL:
            return "RL-optimized turbo model balancing speed and output quality."
        case .sft:
            return "Maximum fidelity with extended diffusion steps for studio-grade output."
        case .base:
            return "Supports all generation task types including stem extraction and audio editing."
        case .xlBase:
            return "4B parameter base model supporting all generation modes with CFG guidance."
        case .xlSft:
            return "4B parameter SFT model for the highest possible audio fidelity."
        case .xlTurbo:
            return "4B parameter turbo model balancing XL quality with fast generation speed."
        }
    }

    var defaultInferenceSteps: Int {
        switch self {
        case .turbo: return 8
        case .turboRL: return 8
        case .sft: return 50
        case .base: return 50
        case .xlBase: return 50
        case .xlSft: return 50
        case .xlTurbo: return 8
        }
    }

    var minimumRAMGB: Int {
        switch self {
        case .turbo: return 8
        case .turboRL: return 8
        case .sft: return 8
        case .base: return 8
        case .xlBase: return 12
        case .xlSft: return 12
        case .xlTurbo: return 12
        }
    }

    /// Whether this is a turbo-speed model (fewer inference steps).
    var isTurbo: Bool {
        switch self {
        case .turbo, .turboRL, .xlTurbo: return true
        case .sft, .base, .xlBase, .xlSft: return false
        }
    }

    /// Whether this model is currently released and available for download.
    /// Hidden models stay in the enum for forward compatibility but don't show in UI pickers.
    var isReleased: Bool {
        switch self {
        case .turbo, .base, .sft, .xlBase, .xlSft, .xlTurbo: return true
        case .turboRL: return false  // Not yet released by ACE-Step team
        }
    }

    /// Only released models for UI display
    static var availableModels: [ACEStepModel] {
        allCases.filter(\.isReleased)
    }
}

// Available Language Model sizes for semantic token generation
enum LMModel: String, CaseIterable, Identifiable {
    case tiny = "acestep-5Hz-lm-0.6B"
    case base = "acestep-5Hz-lm-1.7B"
    case large = "acestep-5Hz-lm-4B"

    var id: String { rawValue }

    /// Physical RAM required by the ACE-Step preflight for this language model.
    var minimumRAMGB: Int {
        switch self {
        case .tiny: return 16
        case .base: return 24
        case .large: return 32
        }
    }

    /// Short label shown beside a model wherever the user chooses a download.
    var minimumRAMLabel: String {
        "needs \(minimumRAMGB) GB"
    }

    /// The old name is kept for callers outside the picker; the requirement is
    /// physical system RAM, not GPU VRAM.
    var vramRequirement: String {
        minimumRAMLabel
    }

    /// The whole-number physical-memory value used by the setup wizard and
    /// generation defaults. Tests pass explicit values to the pure selector.
    static var physicalMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    /// Select the smallest LM that satisfies the app's hard RAM floor. At and
    /// above 24 GB, 1.7B remains the safe default; 4B stays available to pick.
    static func recommended(forPhysicalMemoryGB physicalMemoryGB: Int) -> LMModel {
        physicalMemoryGB < LMModel.base.minimumRAMGB ? .tiny : .base
    }

    static var recommendedForCurrentMac: LMModel {
        recommended(forPhysicalMemoryGB: physicalMemoryGB)
    }

    static var defaultRawValueForCurrentMac: String {
        recommendedForCurrentMac.rawValue
    }

    var displayName: String {
        switch self {
        case .tiny: return "0.6B (Fast)"
        case .base: return "1.7B (Balanced)"
        case .large: return "4B (Best Quality)"
        }
    }

    var description: String {
        switch self {
        case .tiny:
            return "Lightweight model for Macs with 16 GB RAM. Faster generation but lower prompt adherence."
        case .base:
            return "Balanced model for Macs with 24 GB RAM. Recommended default when available."
        case .large:
            return "High-quality model for Macs with 32 GB RAM. Best prompt understanding and musical coherence."
        }
    }
}

enum VariantStatus: Equatable {
    case ready
    case queued
    case generating(progress: Double)
    case failed(message: String)

    var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }

    var isQueued: Bool {
        if case .queued = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct Variant: Identifiable, Equatable {
    let id: String  // Unique ID (short UUID) — stable across deletions and sessions
    var displayLabel: String  // Human-readable label ("A", "B", "C") for UI display
    var title: String
    var note: String
    var rating: Int  // 1-5
    var bpm: Double
    var key: String
    var duration: Double
    var status: VariantStatus
    var audioPath: String?
    var generatedBy: String?  // "local" or remote server URL
}

struct Section: Identifiable, Equatable {
    let id: String
    let label: String
    let start: Double  // seconds
    let end: Double    // seconds
    let mood: String
}

struct GPUQueueStatus: Equatable {
    var gpu1Progress: Double = 0.0
    var gpu2Progress: Double = 0.0
    var isActive: Bool = false
    var currentStage: String = "Idle"
}

// MARK: - Generation Progress

struct GenerationProgress: Codable {
    let id: String
    let stage: String
    let percent: Double
    let message: String
}

// MARK: - Session Management

struct StudioSession: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var stagingTracks: [StagingTrack]
    var parameters: MusicParameters
    var conversationId: UUID?
    var createdAt: Date
    var updatedAt: Date
}

struct StagingTrack: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var variantId: String  // Short unique ID (first 8 chars of UUID)
    var audioFileName: String  // Relative path in Audio/staging/
    var note: String
    var rating: Int
    var bpm: Double?
    var key: String?
    var duration: Double
    var isMarkedForKeep: Bool  // User's selection for Library
    var createdAt: Date

    // Pipeline metadata (carried through to Track on keep)
    var genre: String?
    var mood: String?
    var contentType: String?
    var artist: String?
    var album: String?
    var topic: String?
    var topicTags: [String]?
    var extendedMetadata: [String: String]?
    var generatedBy: String?  // "local" or remote server URL

    // Computed property for full URL using FileStore staging directory
    var audioURL: URL {
        FileStore.shared.stagingDirectory.appendingPathComponent(audioFileName)
    }
}

// MARK: - MusicParameters Extensions

extension MusicParameters {
    func toGenerationParams() -> GenerationParams {
        return GenerationParams(from: self)
    }
}

// MARK: - Model Availability

/// Describes whether a model is available on a given generation target.
enum ModelAvailability: Equatable {
    case available        // Downloaded locally or present on server/cloud
    case notAvailable     // Not downloaded or not on server
    case unknown          // Not yet queried (show as available, don't block)
}

/// Caches model availability per generation target to avoid redundant API queries.
/// Queries are triggered on generation mode changes, API key entry, and app launch.
@MainActor
final class ModelAvailabilityManager: ObservableObject {
    /// Model IDs reported by the ACE Music Cloud API (nil = not queried yet).
    @Published var cloudModelIds: [String]? = nil
    /// Model IDs reported by remote server pool (keyed by server URL, nil = not queried).
    @Published var remoteModelIds: [String: [String]] = [:]
    /// Timestamp of last successful cloud query, for cache expiry.
    private var lastCloudQuery: Date? = nil
    /// Timestamp of last remote query per server URL.
    private var lastRemoteQueries: [String: Date] = [:]
    /// Cache TTL: re-query if older than this interval.
    private let cacheTTL: TimeInterval = 300  // 5 minutes

    /// Whether a DiT model is downloaded locally (checkpoint directory exists).
    func isLocallyDownloaded(_ model: ACEStepModel) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let checkpointDir = home.appendingPathComponent("ACE-Step-1.5/checkpoints/\(model.rawValue)")
        return FileManager.default.fileExists(atPath: checkpointDir.path)
    }

    /// Whether an LM model is downloaded locally.
    func isLMLocallyDownloaded(_ model: LMModel) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let checkpointDir = home.appendingPathComponent("ACE-Step-1.5/checkpoints/\(model.rawValue)")
        return FileManager.default.fileExists(atPath: checkpointDir.path)
    }

    /// Check availability of a DiT model for the current generation mode.
    func availability(of model: ACEStepModel, mode: GenerationMode) -> ModelAvailability {
        switch mode {
        case .localOnly:
            return isLocallyDownloaded(model) ? .available : .notAvailable
        case .cloudOnly:
            return cloudAvailability(of: model)
        case .remoteOnly:
            return remoteAvailability(of: model)
        case .auto:
            // Available if downloaded locally, or on cloud (if configured), or on remote
            if isLocallyDownloaded(model) { return .available }
            let cloud = cloudAvailability(of: model)
            if cloud == .available { return .available }
            let remote = remoteAvailability(of: model)
            if remote == .available { return .available }
            // If nothing queried yet, show as unknown
            if cloud == .unknown && remote == .unknown { return .unknown }
            return .notAvailable
        case .both, .localAndCloud:
            // Available if at least one target has it
            if isLocallyDownloaded(model) { return .available }
            let cloud = cloudAvailability(of: model)
            if cloud == .available { return .available }
            let remote = remoteAvailability(of: model)
            if remote == .available { return .available }
            if cloud == .unknown || remote == .unknown { return .unknown }
            return .notAvailable
        }
    }

    /// Cloud-specific availability check.
    private func cloudAvailability(of model: ACEStepModel) -> ModelAvailability {
        guard let ids = cloudModelIds else { return .unknown }
        return cloudModelIdsContain(model, ids: ids) ? .available : .notAvailable
    }

    /// Remote-specific availability check (any pool server).
    private func remoteAvailability(of model: ACEStepModel) -> ModelAvailability {
        if remoteModelIds.isEmpty { return .unknown }
        for (_, ids) in remoteModelIds {
            if ids.contains(model.rawValue) { return .available }
            // Also check with the acemusic/ prefix format
            if cloudModelIdsContain(model, ids: ids) { return .available }
        }
        return .notAvailable
    }

    /// Match cloud model ID format ("acemusic/acestep-v1.5-turbo") to our enum ("acestep-v15-turbo").
    private func cloudModelIdsContain(_ model: ACEStepModel, ids: [String]) -> Bool {
        // Our enum raw values: "acestep-v15-turbo", "acestep-v15-base", etc.
        // Cloud IDs might be: "acemusic/acestep-v1.5-turbo", "acestep-v15-turbo", etc.
        let rawValue = model.rawValue  // e.g. "acestep-v15-turbo"
        // Direct match
        if ids.contains(rawValue) { return true }
        // Convert our format to cloud format: "acestep-v15-" -> "acestep-v1.5-"
        let cloudVariant = rawValue.replacingOccurrences(of: "acestep-v15-", with: "acestep-v1.5-")
        if ids.contains(cloudVariant) { return true }
        // Check with "acemusic/" prefix
        if ids.contains("acemusic/\(cloudVariant)") { return true }
        // Fuzzy match: check if any ID contains the model's suffix (turbo, base, sft, etc.)
        let suffix = rawValue.replacingOccurrences(of: "acestep-v15-", with: "")
        if ids.contains(where: { $0.lowercased().contains("acestep") && $0.lowercased().hasSuffix(suffix) }) {
            return true
        }
        return false
    }

    // MARK: - Query Methods

    /// Query available models from ACE Music Cloud. Respects cache TTL.
    func queryCloudModels(apiKey: String, baseURL: String = "https://api.acemusic.ai") async {
        guard !apiKey.isEmpty else {
            cloudModelIds = nil
            return
        }
        // Check cache
        if let lastQuery = lastCloudQuery,
           Date().timeIntervalSince(lastQuery) < cacheTTL,
           cloudModelIds != nil {
            return
        }
        let service = ACEMusicCloudService(apiKey: apiKey, baseURL: baseURL)
        let ids = await service.listModelIds()
        cloudModelIds = ids.isEmpty ? nil : ids
        if !ids.isEmpty {
            lastCloudQuery = Date()
        }
    }

    /// Query available models from a single remote server. Respects cache TTL.
    func queryRemoteModels(serverURL: String, apiKey: String) async {
        guard !serverURL.isEmpty else { return }
        // Check cache
        if let lastQuery = lastRemoteQueries[serverURL],
           Date().timeIntervalSince(lastQuery) < cacheTTL,
           remoteModelIds[serverURL] != nil {
            return
        }
        let service = RemoteGenerationService(serverURL: serverURL, apiKey: apiKey)
        let ids = await service.listModels()
        if !ids.isEmpty {
            remoteModelIds[serverURL] = ids
            lastRemoteQueries[serverURL] = Date()
        }
    }

    /// Query models from all enabled servers in a pool.
    func queryPoolModels(serverPool: ServerPoolManager) async {
        let servers = serverPool.enabledServers
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { [weak self] in
                    await self?.queryRemoteModels(serverURL: server.url, apiKey: server.apiKey)
                }
            }
        }
    }

    /// Invalidate cached cloud model list (e.g. when API key changes).
    func invalidateCloudCache() {
        cloudModelIds = nil
        lastCloudQuery = nil
    }

    /// Invalidate all remote caches.
    func invalidateRemoteCache() {
        remoteModelIds.removeAll()
        lastRemoteQueries.removeAll()
    }
}
