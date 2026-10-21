import Foundation

struct Track: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var title: String
    var caption: String
    var audioFileName: String  // Relative path from Audio directory (e.g., "uuid/variant-1.wav")
    var createdAt: Date
    var duration: Double
    var rating: Int = 0  // 0-5 stars
    var bpm: Double?
    var key: String?
    var artist: String?
    var album: String?
    var genre: String?
    var lyrics: String?
    var sessionId: UUID?
    var conversationId: UUID?

    // Pipeline metadata
    var mood: String?
    var contentType: String?        // "news_narrative" | "news_beats" | "personal"
    var trackNumber: Int?
    var inspiredBy: String?
    var sourceURLs: [String]?
    var dateRelevance: String?
    var shelfLife: String?
    var topic: String?
    var topicTags: [String]?
    var extendedMetadata: [String: String]?  // Catch-all for pipeline metadata

    // Credits (persisted in library.json, carried over to publishing)
    var credits: [Credit]?

    // Opaque internal metadata (persisted but never rendered in UI)
    var internalMetadata: [String: String]?

    // Optional custom artwork (overrides album art for singles/special tracks)
    var customArtworkFileName: String?

    // Timestamped lyrics file (LRC format) stored alongside the audio file
    var lrcFileName: String?  // Relative path from Audio directory (e.g., "uuid/variant-1.lrc")

    // ISRC code for published tracks
    var isrc: String?

    // Metadata for generation tracking
    var originalPrompt: String?  // User's chat message/style
    var generationParams: GenerationParams?  // All generation settings

    var audioURL: URL {
        FileStore.shared.audioDirectory.appendingPathComponent(audioFileName)
    }

    /// Whether this track's audio is present on disk locally.
    ///
    /// ⚠️ NOT A FIELD READ. It builds a URL, renders it to a path and makes a
    /// `stat(2)` — about 12 µs a call, of which ~80% is the URL/String work
    /// rather than the syscall. Read it ONCE per SwiftUI body pass and hold the
    /// answer in a `let`; `StudioLibrarySongRow` read it six times per pass
    /// across sixty non-lazy rows before `StudioBrowserCostTests` pinned it.
    /// Routed through `FileExistenceProbe` so that test can count the calls.
    var audioFileExists: Bool {
        FileExistenceProbe.exists(audioURL)
    }

    var customArtworkURL: URL? {
        guard let fileName = customArtworkFileName else { return nil }
        return FileStore.shared.artworkDirectory.appendingPathComponent(fileName)
    }

    var lrcURL: URL? {
        guard let fileName = lrcFileName else { return nil }
        return FileStore.shared.audioDirectory.appendingPathComponent(fileName)
    }

    /// As `audioFileExists`: a syscall behind a property. Same rule applies.
    var lrcFileExists: Bool {
        guard let url = lrcURL else { return false }
        return FileExistenceProbe.exists(url)
    }
}

struct GenerationParams: Codable, Equatable, Hashable {
    var bpm: Double?
    var key: String?
    var duration: Double?
    var variantCount: Int?
    var model: String?
    var lmModel: String?
    var guidanceScale: Double?
    var lyrics: String?
    var style: String?
    var timestamp: Date?
    var genre: String?
    var mood: String?
    var artist: String?
    var album: String?
    var seed: Int?
    var numInferenceSteps: Int?
    var lmTemperature: Double?
    var lmCfgScale: Double?
    var timeSignature: String?
    var vocalLanguage: String?

    // ACE-Step v1.5 advanced diffusion parameters
    var shift: Double?
    var inferMethod: String?
    var useAdg: Bool?
    var cfgIntervalStart: Double?
    var cfgIntervalEnd: Double?

    // ACE-Step v1.5 advanced LM parameters
    var thinking: Bool?
    var lmTopK: Int?
    var lmTopP: Double?
    var lmRepetitionPenalty: Double?
    var lmNegativePrompt: String?
    var constrainedDecoding: Bool?

    init(from params: MusicParameters, timestamp: Date = Date()) {
        self.bpm = params.bpm
        self.key = params.key
        self.duration = params.duration
        self.variantCount = params.variantCount
        self.model = params.model
        self.lmModel = params.lmModel
        self.guidanceScale = params.guidanceScale
        self.lyrics = params.lyrics.isEmpty ? nil : params.lyrics
        self.style = params.style
        self.timestamp = timestamp
        self.genre = params.genre.isEmpty ? nil : params.genre
        self.mood = params.mood.isEmpty ? nil : params.mood
        self.artist = params.artist.isEmpty ? nil : params.artist
        self.album = params.album.isEmpty ? nil : params.album
        self.seed = params.seed
        self.numInferenceSteps = params.numInferenceSteps
        self.lmTemperature = params.lmTemperature
        self.lmCfgScale = params.lmCfgScale
        self.timeSignature = params.timeSignature.isEmpty ? nil : params.timeSignature
        self.vocalLanguage = params.vocalLanguage.isEmpty ? nil : params.vocalLanguage
        self.shift = params.shift
        self.inferMethod = params.inferMethod
        self.useAdg = params.useAdg
        self.cfgIntervalStart = params.cfgIntervalStart
        self.cfgIntervalEnd = params.cfgIntervalEnd
        self.thinking = params.thinking
        self.lmTopK = params.lmTopK
        self.lmTopP = params.lmTopP
        self.lmRepetitionPenalty = params.lmRepetitionPenalty
        self.lmNegativePrompt = params.lmNegativePrompt.isEmpty ? nil : params.lmNegativePrompt
        self.constrainedDecoding = params.constrainedDecoding
    }
}

/// Wraps a Decodable type so that individual element failures don't
/// kill an entire array decode. Use with `[FailableDecodable<T>].self`
/// and then `.compactMap { $0.value }` to silently skip bad entries.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(T.self)
    }
}

// MARK: - Credit

struct Credit: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var role: String
    var displayName: String

    static let standardRoles = [
        "producer", "lyricist", "co-creator", "inspiration",
        "engineer", "writer", "composer", "arranger",
        "vocalist", "mixing", "mastering", "instrumentalist", "featuring"
    ]

    init(id: UUID = UUID(), name: String, role: String, displayName: String = "") {
        self.id = id
        self.name = name
        self.role = role
        self.displayName = displayName
    }

    // Backward compat: displayName may not exist in old JSON
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decode(String.self, forKey: .role)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
    }
}

// MARK: - ISRC Helper

struct ISRCHelper {
    /// Format a 12-character ISRC code as XX-XXX-XX-XXXXX
    static func formatISRC(_ isrc: String) -> String {
        let clean = isrc.replacingOccurrences(of: "-", with: "")
        guard clean.count == 12 else { return isrc }
        let p1 = clean.prefix(2)
        let p2 = clean.dropFirst(2).prefix(3)
        let p3 = clean.dropFirst(5).prefix(2)
        let p4 = clean.dropFirst(7)
        return "\(p1)-\(p2)-\(p3)-\(p4)"
    }

    static func isValidISRC(_ isrc: String) -> Bool {
        let clean = isrc.replacingOccurrences(of: "-", with: "")
        guard clean.count == 12 else { return false }
        guard clean.prefix(2).allSatisfy({ $0.isLetter }) else { return false }
        return clean.allSatisfy({ $0.isLetter || $0.isNumber })
    }
}
