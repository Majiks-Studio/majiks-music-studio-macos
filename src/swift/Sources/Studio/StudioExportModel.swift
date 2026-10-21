import Foundation

// MARK: - Export + provenance model (L13)
//
// The types the export dialog speaks, plus the default engine implementations
// (so the no-framework mock build compiles and the dialog renders without the
// FFI-only engine). RealStudioEngine overrides these to route export.* + the
// provenance manifest through the same journaled command bus everything uses;
// the manifest itself is BUILT by the engine (the command journal is the chain
// of custody), never reimplemented here. Swift only previews the split.

/// What to export.
enum StudioExportScope: String, CaseIterable, Sendable, Identifiable {
    case master, stems, region
    var id: String { rawValue }
    var label: String {
        switch self {
        case .master: return "Master mix"
        case .stems: return "Stems (per track)"
        case .region: return "Selected region"
        }
    }
}

/// The deliverable audio format.
enum StudioExportFormat: String, CaseIterable, Sendable, Identifiable {
    case wav, aac
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wav: return "WAV (24-bit)"
        case .aac: return "AAC (.m4a)"
        }
    }
    var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aac: return "m4a"
        }
    }
}

/// A loudness delivery target (EBU R128 integrated LUFS). Mirrors the engine's
/// render::encode::LoudnessTarget.
enum StudioLoudnessTarget: String, CaseIterable, Sendable, Identifiable {
    case none, streaming, club, broadcast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None (as mixed)"
        case .streaming: return "Streaming  -14 LUFS"
        case .club: return "Club  -7 LUFS"
        case .broadcast: return "Broadcast  -16 LUFS"
        }
    }
    /// Short label for a segmented control (the LUFS shows in the helper text).
    var shortLabel: String {
        switch self {
        case .none: return "None"
        case .streaming: return "Streaming"
        case .club: return "Club"
        case .broadcast: return "Broadcast"
        }
    }
    /// The wire value passed to export.master (`loudnessTarget`).
    var wire: String { rawValue }
    var targetLUFS: Double? {
        switch self {
        case .none: return nil
        case .streaming: return -14
        case .club: return -7
        case .broadcast: return -16
        }
    }
}

/// One export request from the dialog.
struct StudioExportRequest: Sendable, Equatable {
    var scope: StudioExportScope
    var format: StudioExportFormat
    var loudness: StudioLoudnessTarget
    var includeManifest: Bool
    /// The output file (master/region) or directory (stems). Absolute path.
    var outputPath: String
    /// Region bounds (scope == .region only), in ticks.
    var regionStartTicks: Int64 = 0
    var regionEndTicks: Int64 = 0
}

/// The measured loudness landing, echoed from the engine's export result.
struct StudioLoudnessResult: Sendable, Equatable {
    var target: String
    var integratedLufsAfter: Double?
    var appliedGainDB: Double
    var samplePeakDBFS: Double?
    var errorLU: Double
}

/// The result of an export (or a manifest write).
struct StudioExportOutcome: Sendable, Equatable {
    var ok: Bool
    var message: String?
    var outputPath: String?
    var format: String?
    var loudness: StudioLoudnessResult?
    var manifestPath: String?
    /// The engine's honest one-line provenance summary of what was exported.
    var provenanceSummary: String?

    static func failed(_ message: String) -> StudioExportOutcome {
        StudioExportOutcome(ok: false, message: message)
    }
    static let notOnThisEngine = StudioExportOutcome.failed("Export runs on the on-device engine.")
}

/// A publish-to-majiks.online request (reuses the existing publisher path).
struct StudioPublishRequest: Sendable, Equatable {
    var title: String
    var includeManifest: Bool = true
}

/// The provenance split for the export dialog, bucketed by the SAME four terms
/// the exported manifest uses and — on the real engine — from the engine's own
/// per-clip classification, carried on the snapshot.
///
/// It used to sort every non-generative clip into "imported", which was wrong
/// twice over: a note clip written in the piano roll has no file behind it, and
/// on the real engine `generative` was hardcoded false, so a fully AI-generated
/// project previewed as 100% imported. A preview that disagrees with the
/// artifact it previews is its own defect, so it no longer guesses.
struct StudioProvenancePreview: Sendable, Equatable {
    var clipCount: Int
    var generatedClips: Int
    var importedClips: Int
    var recordedClips: Int
    var authoredClips: Int
    var generatedPct: Int
    var importedPct: Int
    var recordedPct: Int
    var authoredPct: Int

    static let empty = StudioProvenancePreview(
        clipCount: 0, generatedClips: 0, importedClips: 0, recordedClips: 0, authoredClips: 0,
        generatedPct: 0, importedPct: 0, recordedPct: 0, authoredPct: 0)

    /// One origin's share of the project.
    struct Bucket: Identifiable, Sendable, Equatable {
        var origin: StudioClipOrigin
        var clips: Int
        var pct: Int
        var id: StudioClipOrigin { origin }
    }

    /// Every bucket, in the manifest's order.
    var buckets: [Bucket] {
        [Bucket(origin: .generated, clips: generatedClips, pct: generatedPct),
         Bucket(origin: .imported, clips: importedClips, pct: importedPct),
         Bucket(origin: .recorded, clips: recordedClips, pct: recordedPct),
         Bucket(origin: .authored, clips: authoredClips, pct: authoredPct)]
    }

    /// Mirrors the engine's `Composition::summary_line`: only non-empty buckets,
    /// in the same order, so the dialog and the export result agree word for word.
    var summaryLine: String {
        if clipCount == 0 { return "empty project" }
        let parts = buckets.filter { $0.pct > 0 }.map { "\($0.pct)% \($0.origin.rawValue)" }
        return parts.isEmpty ? "\(clipCount) clips" : parts.joined(separator: " / ")
    }

    /// True when any AI-generated clip is present (drives the disclosure note).
    var hasGeneratedContent: Bool { generatedClips > 0 }

    static func from(_ snapshot: StudioProjectSnapshot?) -> StudioProvenancePreview {
        guard let snapshot else { return .empty }
        var clips: [StudioClipOrigin: Int] = [:]
        var ticks: [StudioClipOrigin: Int64] = [:]
        var count = 0
        for track in snapshot.tracks {
            for clip in track.clips {
                let origin = clip.origin
                clips[origin, default: 0] += 1
                ticks[origin, default: 0] += clip.lengthTicks
                count += 1
            }
        }
        let total = max(1, ticks.values.reduce(0, +))
        let pct = { (o: StudioClipOrigin) in
            Int((Double(ticks[o] ?? 0) * 100.0 / Double(total)).rounded())
        }
        return StudioProvenancePreview(
            clipCount: count,
            generatedClips: clips[.generated] ?? 0,
            importedClips: clips[.imported] ?? 0,
            recordedClips: clips[.recorded] ?? 0,
            authoredClips: clips[.authored] ?? 0,
            generatedPct: pct(.generated),
            importedPct: pct(.imported),
            recordedPct: pct(.recorded),
            authoredPct: pct(.authored)
        )
    }
}

// MARK: - Default engine implementations
//
// Both concrete engines override these; the defaults keep the protocol
// satisfiable for the no-framework mock build (the dialog renders + previews
// provenance from the snapshot regardless).

extension StudioEngineProtocol {
    func exportAudio(_ request: StudioExportRequest) async -> StudioExportOutcome {
        .notOnThisEngine
    }
    func writeManifest(outputPath: String) async -> StudioExportOutcome {
        .notOnThisEngine
    }
    func publishToMajiks(_ request: StudioPublishRequest) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: "Publishing runs on the on-device engine.")
    }
}
