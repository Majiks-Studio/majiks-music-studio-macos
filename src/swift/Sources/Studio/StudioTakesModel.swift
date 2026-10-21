import Foundation

// MARK: - Takes system (L10): the browser's value types + the engine seam.
//
// The Takes browser lists EVERY generative result in the project (revise /
// extend / layer / landing / ...), each carrying the lineage that produced it.
// It reads `takes.list` and drives `take.promote` / `take.discard` /
// `take.auditionMix` / purge, the SAME commands an agent uses, so the UI and an
// agent share one path (agent parity). These are pure value types + a pure
// filter, unit-tested without any engine.

/// What produced a take (mirrors the engine `kind` classification). `landing`
/// is a whole-song provenance anchor (the L8 follow-up), not an alternative.
enum StudioTakeKind: String, Sendable, Codable, CaseIterable {
    case revise, extend, layer, retake, landing, finalize, cover, autocomplete, other

    /// The kinds a user auditions as ALTERNATIVES (drives the browser's default
    /// filter). Landing + finalize are provenance / plumbing.
    var isAlternativeKind: Bool {
        switch self {
        case .revise, .extend, .layer, .retake: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .revise: return "Revise"
        case .extend: return "Extend"
        case .layer: return "Layer"
        case .retake: return "Retake"
        case .landing: return "Landed song"
        case .finalize: return "Finalize"
        case .cover: return "Cover"
        case .autocomplete: return "Autocomplete"
        case .other: return "Other"
        }
    }
}

enum StudioTakeStatusKind: String, Sendable, Codable {
    case candidate, promoted, discarded
}

/// The joined lineage of a take: what it was told to make, and how.
struct StudioTakeLineage: Sendable, Equatable {
    var prompt: String?
    var seed: UInt64?
    var model: String?
    var steps: Int?
    var device: String?
    var regionStartTicks: Int64?
    var regionEndTicks: Int64?
}

/// One take as the browser shows it (mirror of the enriched `takes.list`
/// record). `stemName` may be "mix" (a full-mix take), so it is a string; the
/// coloring stem is derived.
struct StudioTakeBrowserItem: Sendable, Equatable, Identifiable {
    var takeID: String
    var requestID: String
    var kind: StudioTakeKind
    var stemName: String
    var status: StudioTakeStatusKind
    var promotedInto: String?
    /// The stem asset hash (for drag-to-timeline placement), if single-asset.
    var assetHash: String?
    var auditionable: Bool
    var provenance: Bool
    var offline: Bool
    var createdTs: String?
    var createdSeq: Int?
    var lineage: StudioTakeLineage

    var id: String { takeID }

    /// The stem used to color the row (mix / unknown -> other).
    var stemKind: StudioStemKind {
        StudioStemKind(rawValue: stemName) ?? .other
    }

    /// A short, human line for the row: the prompt, else the kind.
    var title: String {
        if let p = lineage.prompt, !p.trimmingCharacters(in: .whitespaces).isEmpty {
            return p
        }
        return kind.label
    }
}

/// The engine-side filter for a `takes.list` read (all optional / additive).
struct StudioTakesQuery: Sendable, Equatable {
    var clipID: String?
    var requestID: String?
    var kind: StudioTakeKind?
    var auditionableOnly: Bool = false
    var includePurged: Bool = true

    static let all = StudioTakesQuery()
}

/// Scope for a purge (reclaim take audio to free space).
enum StudioPurgeScope: Sendable, Equatable {
    case all
    case take(String)
    case request(String)
}

struct StudioPurgeResult: Sendable, Equatable {
    var ok: Bool
    var purgedCount: Int
    var assetsDeleted: Int
    var bytesReclaimed: Int64
    var message: String?

    static func failed(_ message: String) -> StudioPurgeResult {
        StudioPurgeResult(ok: false, purgedCount: 0, assetsDeleted: 0, bytesReclaimed: 0, message: message)
    }
}

// MARK: - The browser's client-side view filter (by prompt / region / date)
//
// The engine read already narrows by clip/request/kind/auditionable; this is
// the interactive filter the browser drives on the loaded list (design 4:
// "filterable by region/prompt", plus date). Pure + unit-tested.

struct StudioTakesFilter: Equatable {
    /// Free-text match over the prompt + kind + stem.
    var search: String = ""
    /// Only takes whose region overlaps this selection (the "this region" view).
    var region: StudioRegionSelection?
    /// Only takes you can audition (hides landing provenance + purged).
    var auditionableOnly: Bool = true
    /// Kind filter (nil = any).
    var kind: StudioTakeKind?

    var isActive: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
            || region != nil || kind != nil || auditionableOnly
    }

    func matches(_ item: StudioTakeBrowserItem) -> Bool {
        if auditionableOnly && !item.auditionable { return false }
        if let k = kind, item.kind != k { return false }
        if let region {
            guard let s = item.lineage.regionStartTicks, let e = item.lineage.regionEndTicks else {
                return false // no region on this take (e.g. a landing) -> not "in this region"
            }
            if s >= region.endTicks || region.startTicks >= e { return false }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            let hay = "\(item.lineage.prompt ?? "") \(item.kind.label) \(item.stemName)".lowercased()
            if !hay.contains(q) { return false }
        }
        return true
    }

    /// Apply to a loaded list (newest first by creation order).
    func apply(_ items: [StudioTakeBrowserItem]) -> [StudioTakeBrowserItem] {
        items.filter(matches).sorted { ($0.createdSeq ?? 0) > ($1.createdSeq ?? 0) }
    }
}

// MARK: - Engine protocol default impls
//
// Same discipline as L9 (StudioReviseModel): the protocol DECLARES these (see
// StudioEngineProtocol), and both concrete engines override them. These
// defaults keep the protocol satisfiable + honest for any future engine.

extension StudioEngineProtocol {
    func takes(query: StudioTakesQuery) async -> [StudioTakeBrowserItem] { [] }

    func auditionMix(takeID: String, stems: [String]) async -> StudioCommandResult {
        StudioCommandResult(ok: true, message: nil) // preview signal; safe no-op
    }

    func purgeTakes(scope: StudioPurgeScope) async -> StudioPurgeResult {
        .failed("Purge runs on the on-device engine.")
    }

    func placeTake(takeID: String, ontoClipID: UUID) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: "Placing a take runs on the on-device engine.")
    }
}
