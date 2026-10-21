import Foundation
import AVFoundation

/// Errors thrown when adding a bounced mix to the Library.
enum StemSessionLibraryExportError: LocalizedError {
    case bounceFileMissing

    var errorDescription: String? {
        switch self {
        case .bounceFileMissing:
            return "The bounced audio file could not be found."
        }
    }
}

/// Per-stem provenance snapshot carried into a bounced track's
/// extendedMetadata — the mix position of every stem plus its PROVENANCE
/// SEED (source track + generation parameters), so the chain
/// generation → stem → session → bounced track never breaks.
struct StemProvenance: Codable, Equatable {
    let displayName: String
    let gainDB: Double
    let muted: Bool
    let solo: Bool
    let pan: Double
    let sourceTrackId: UUID?
    let generationParams: GenerationParams?

    init(stem: SessionStem) {
        displayName = stem.displayName
        gainDB = stem.gainDB
        muted = stem.muted
        solo = stem.solo
        pan = stem.pan
        sourceTrackId = stem.sourceTrackId
        generationParams = stem.generationParams
    }
}

/// Builds Library tracks from bounced stem sessions, following the app's
/// file conventions: the bounce is COPIED into the Audio tree (so the track
/// is independent of wherever the user saved the export) and registered via
/// LibraryStore.addTrack by the caller.
enum StemSessionLibraryExport {
    /// Subdirectory of the Audio directory holding bounced session mixes.
    static let bouncesSubdirectory = "StemBounces"

    /// Extended-metadata keys (machine-readable provenance).
    static let metadataSessionIdKey = "stemSessionId"
    static let metadataSessionNameKey = "stemSessionName"
    static let metadataStemCountKey = "stemSessionStemCount"
    /// JSON array of StemOriginOp — the session's append-only history.
    static let metadataOriginOpsKey = "stemSessionOriginOps"
    /// JSON array of StemProvenance — per-stem mix + generation params.
    static let metadataStemsKey = "stemSessionStems"

    /// Copies `bounceURL` into `audioDirectory`/StemBounces/ under a unique
    /// name and returns a Track pointing at the copy, with the session's
    /// provenance chain carried in extendedMetadata.
    static func makeTrack(
        from document: StemSessionDocument,
        bounceURL: URL,
        audioDirectory: URL,
        now: Date = Date()
    ) throws -> Track {
        guard FileManager.default.fileExists(atPath: bounceURL.path) else {
            throw StemSessionLibraryExportError.bounceFileMissing
        }

        let bouncesDir = audioDirectory.appendingPathComponent(bouncesSubdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: bouncesDir, withIntermediateDirectories: true)

        // "<track-uuid8>_<safe session name>.<ext>" — same naming shape as
        // stem copies; the UUID prefix keeps repeated bounces collision-free.
        let ext = bounceURL.pathExtension.isEmpty ? "wav" : bounceURL.pathExtension
        let trackID = UUID()
        let safeBase = StemSessionStore.sanitizedBaseName(document.name)
        let fileName = "\(trackID.uuidString.prefix(8).lowercased())_\(safeBase).\(ext)"
        let destination = bouncesDir.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: bounceURL, to: destination)

        // Duration from the audio header (no full decode).
        var duration: Double = 0
        if let file = try? AVAudioFile(forReading: destination) {
            let rate = file.processingFormat.sampleRate
            if rate > 0 {
                duration = Double(file.length) / rate
            }
        }

        let stemCount = document.stems.count
        return Track(
            id: trackID,
            title: document.name,
            caption: "Bounced from stem session \"\(document.name)\" (\(stemCount) stem\(stemCount == 1 ? "" : "s"))",
            audioFileName: "\(bouncesSubdirectory)/\(fileName)",
            createdAt: now,
            duration: duration,
            extendedMetadata: provenanceMetadata(for: document)
        )
    }

    /// The provenance payload: session identity, the append-only origin log,
    /// and every stem's mix position + generation parameters as JSON strings
    /// (extendedMetadata is [String: String] by convention).
    static func provenanceMetadata(for document: StemSessionDocument) -> [String: String] {
        var metadata: [String: String] = [
            metadataSessionIdKey: document.id.uuidString,
            metadataSessionNameKey: document.name,
            metadataStemCountKey: String(document.stems.count)
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        if let opsData = try? encoder.encode(document.originOps) {
            metadata[metadataOriginOpsKey] = String(data: opsData, encoding: .utf8)
        }
        let stems = document.stems.map { StemProvenance(stem: $0) }
        if let stemsData = try? encoder.encode(stems) {
            metadata[metadataStemsKey] = String(data: stemsData, encoding: .utf8)
        }
        return metadata
    }
}
