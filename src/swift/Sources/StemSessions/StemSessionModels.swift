import Foundation

// MARK: - Stem Session Document (S1 — Stem Sessions)

/// A single stem inside a stem session.
///
/// `fileName` is a relative path inside `FileStore.stemSessionsDirectory`
/// (e.g. "SESSION-UUID/1a2b3c4d_vocals.wav"), mirroring how `Track.audioFileName`
/// is relative to the Audio directory. Stems are always COPIED into the session
/// directory when added — extract results live in `Audio/staging/` (pruned after
/// 30 days / on session cleanup) and Demucs exports land in ad-hoc `stems_<ts>`
/// folders, so referencing them in place would let sessions rot silently.
struct SessionStem: Identifiable, Codable, Equatable {
    let id: UUID
    var fileName: String
    var displayName: String
    var gainDB: Double
    var muted: Bool
    var solo: Bool
    /// Stereo pan position: −1 (hard left) … 0 (center) … +1 (hard right).
    /// Applied via AVAudioMixerNode.pan on the stem's mixer.
    var pan: Double

    /// Library track this stem was derived from, when known (provenance).
    var sourceTrackId: UUID?

    /// Generation parameters passthrough — the PROVENANCE SEED. Carried verbatim
    /// from the generation/extract flow so a stem always knows how it was made.
    var generationParams: GenerationParams?

    init(
        id: UUID = UUID(),
        fileName: String,
        displayName: String,
        gainDB: Double = 0,
        muted: Bool = false,
        solo: Bool = false,
        pan: Double = 0,
        sourceTrackId: UUID? = nil,
        generationParams: GenerationParams? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.displayName = displayName
        self.gainDB = gainDB
        self.muted = muted
        self.solo = solo
        self.pan = pan
        self.sourceTrackId = sourceTrackId
        self.generationParams = generationParams
    }

    // Backward/forward compat: tolerate older JSON missing newer fields
    // (pre-pan documents decode with pan = 0 → center, the old behavior).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? "Stem"
        gainDB = try container.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        solo = try container.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        sourceTrackId = try container.decodeIfPresent(UUID.self, forKey: .sourceTrackId)
        generationParams = try container.decodeIfPresent(GenerationParams.self, forKey: .generationParams)
    }
}

/// One entry in a session's append-only provenance log. Entries are only ever
/// appended — including for undo, which appends a compensating entry rather
/// than rewriting history.
struct StemOriginOp: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    /// Machine-readable action tag. String (not enum) so newer logs still decode
    /// in older builds — matches the `contentType: String?` idiom in `Track`.
    let action: String
    let detail: String

    init(id: UUID = UUID(), timestamp: Date = Date(), action: String, detail: String) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.detail = detail
    }

    // Well-known action tags
    static let actionCreated = "created"
    static let actionCreatedFromExtract = "created-from-extract"
    static let actionAddedFile = "added-file"
    static let actionAddedExtractedStem = "added-extracted-stem"
    static let actionRemovedStem = "removed-stem"
    static let actionRestoredStem = "restored-stem"
    static let actionRenamedSession = "renamed-session"
    static let actionRenamedStem = "renamed-stem"
    static let actionBounced = "bounced"
    static let actionAddedToLibrary = "added-to-library"
}

/// A stem session: N stems mixed against a master bus, persisted as flat JSON
/// (`stem_sessions.json`) following the `sessions.json` / `library.json`
/// conventions (ISO-8601 dates, atomic writes).
struct StemSessionDocument: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var stems: [SessionStem]
    var masterGainDB: Double
    /// Append-only origin log (created-from-extract / added-file / …).
    var originOps: [StemOriginOp]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        stems: [SessionStem] = [],
        masterGainDB: Double = 0,
        originOps: [StemOriginOp] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.stems = stems
        self.masterGainDB = masterGainDB
        self.originOps = originOps
    }

    // Backward/forward compat decoding with defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Stem Session"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        stems = try container.decodeIfPresent([SessionStem].self, forKey: .stems) ?? []
        masterGainDB = try container.decodeIfPresent(Double.self, forKey: .masterGainDB) ?? 0
        originOps = try container.decodeIfPresent([StemOriginOp].self, forKey: .originOps) ?? []
    }

    /// True when at least one stem is soloed (solo set derives effective mutes).
    var hasSolo: Bool {
        stems.contains { $0.solo }
    }
}

// MARK: - Mix Math (pure, testable)

/// Pure gain-resolution math shared by live playback, offline bounce, and tests.
/// Keeping this out of the engine means the solo/mute matrix is unit-testable
/// without touching AVFoundation.
enum StemMix {
    /// Gains at or below this dB value are treated as -inf (hard silence).
    static let silenceFloorDB: Double = -60
    static let minGainDB: Double = -60
    static let maxGainDB: Double = 12
    static let minPan: Double = -1
    static let maxPan: Double = 1

    /// dB -> linear amplitude. The slider floor (-60 dB) maps to true silence.
    static func linearGain(fromDB db: Double) -> Float {
        guard db > silenceFloorDB else { return 0 }
        return Float(pow(10.0, db / 20.0))
    }

    /// Solo/mute resolution: mute always wins; when any stem is soloed, every
    /// non-soloed stem is effectively muted (standard DAW semantics).
    static func isEffectivelyMuted(muted: Bool, solo: Bool, anySolo: Bool) -> Bool {
        muted || (anySolo && !solo)
    }

    /// Effective linear gain of one stem given the session's solo state.
    static func effectiveLinearGain(gainDB: Double, muted: Bool, solo: Bool, anySolo: Bool) -> Float {
        isEffectivelyMuted(muted: muted, solo: solo, anySolo: anySolo)
            ? 0
            : linearGain(fromDB: gainDB)
    }

    /// Effective linear gain for every stem in a document (master NOT included —
    /// master gain lives on the main mixer bus).
    static func effectiveLinearGains(for document: StemSessionDocument) -> [UUID: Float] {
        let anySolo = document.hasSolo
        var gains: [UUID: Float] = [:]
        for stem in document.stems {
            gains[stem.id] = effectiveLinearGain(
                gainDB: stem.gainDB,
                muted: stem.muted,
                solo: stem.solo,
                anySolo: anySolo
            )
        }
        return gains
    }

    /// Format a dB value for UI labels ("-inf dB", "-6.0 dB", "+3.5 dB", "0.0 dB").
    static func formatDB(_ db: Double) -> String {
        guard db > silenceFloorDB else { return "-∞ dB" }
        return String(format: "%@%.1f dB", db > 0 ? "+" : "", db)
    }

    /// Format a pan position for UI labels ("L64", "C", "R100").
    static func formatPan(_ pan: Double) -> String {
        let clamped = min(max(pan, minPan), maxPan)
        let magnitude = Int((abs(clamped) * 100).rounded())
        guard magnitude > 0 else { return "C" }
        return "\(clamped < 0 ? "L" : "R")\(magnitude)"
    }

    /// Meter scale: linear amplitude → 0…1 fraction on a −60…0 dBFS axis
    /// (the same −60 floor as the gain sliders). 0 dBFS and above pin to 1 —
    /// clipping is flagged separately off the raw peak.
    static func meterFraction(fromLinear linear: Float) -> Double {
        guard linear > 0 else { return 0 }
        let db = 20.0 * log10(Double(linear))
        return min(max((db - silenceFloorDB) / -silenceFloorDB, 0), 1)
    }
}
