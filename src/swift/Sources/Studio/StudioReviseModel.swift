import Foundation

// MARK: - Revise / Extend / Add-a-Layer (L9): the killer feature, UI side.
//
// Value types the Revise panel + audition + commit flow speak. The engine does
// the generation + splice + commit txn (over the same command bus MCP and the
// CLI use); the UI supplies the region, the instruction, the scope, and the
// choice of variant. Pure types + a couple of pure helpers (unit-tested).

/// One scoped-stem promotion: the engine take handle + the clip it lands in.
/// `takeID` is an OPAQUE engine handle (the UI never parses it), so this works
/// whether the engine speaks the mock's ids or the FFI's ULIDs.
struct StudioPromotion: Sendable, Equatable {
    var takeID: String
    var clipID: UUID
    var stem: StudioStemKind
}

/// One generated variant of a revise: the takes to promote if the user picks it.
struct StudioReviseVariant: Sendable, Equatable, Identifiable {
    var index: Int          // 0-based; audition key = index + 1
    var seed: UInt64
    var promotions: [StudioPromotion]
    var id: Int { index }
}

/// The request the Revise panel builds from the selection + panel controls.
struct StudioReviseRequest: Sendable, Equatable {
    /// The scoped stem clips (one per scoped stem), or a single full-mix clip.
    var clipIDs: [UUID]
    var regionStartTicks: Int64
    var regionEndTicks: Int64
    /// The stems to regenerate; empty means the single full-mix clip (all-stems).
    var scope: [StudioStemKind]
    var allStems: Bool
    var instruction: String
    var variants: Int
    /// Honest toggle: resend the lyrics when vocals are in scope.
    var keepLyrics: Bool
    var crossfadeMs: Double
    var seed: UInt64?
}

/// The result of a revise: the variants (each auditionable, one committable) and
/// the audition loop (region + pre-roll) to set on the transport.
struct StudioReviseOutcome: Sendable, Equatable {
    var ok: Bool
    var message: String?
    var variants: [StudioReviseVariant]
    var auditionLoopStart: Int64
    var auditionLoopEnd: Int64
    /// The draft take ids for the finalize (draft/commit two-phase) re-render.
    var draftTakeIDsByVariant: [Int: [String]]

    static func failed(_ message: String) -> StudioReviseOutcome {
        StudioReviseOutcome(ok: false, message: message, variants: [], auditionLoopStart: 0, auditionLoopEnd: 0, draftTakeIDsByVariant: [:])
    }
}

/// A candidate take from extend / add-a-layer (a simpler, non-scoped flow).
struct StudioGenTake: Sendable, Equatable, Identifiable {
    var takeID: String
    var seed: UInt64
    var label: String
    var id: String { takeID }
}

struct StudioGenOutcome: Sendable, Equatable {
    var ok: Bool
    var message: String?
    var takes: [StudioGenTake]
    /// Add-a-layer: the NEW track the engine prepared (take lanes live here).
    var targetTrackID: String?
    static func failed(_ message: String) -> StudioGenOutcome {
        StudioGenOutcome(ok: false, message: message, takes: [], targetTrackID: nil)
    }
}

// MARK: - Audition state (view model owns one)

/// The live audition of a revise: the variants, which is auditioning (nil = the
/// original), and the loop bounds. Keys 1-9 pick a variant, A returns to the
/// original, Return commits the auditioned variant.
struct StudioAuditionState: Equatable {
    var variants: [StudioReviseVariant]
    var draftTakeIDsByVariant: [Int: [String]]
    var loop: ClosedRange<Int64>
    var region: StudioRegionSelection
    /// nil = auditioning the ORIGINAL (A); else the auditioned variant index.
    var auditioningVariant: Int?
    /// Set true after a commit lands, until the background finalize swaps in.
    var finalizing: Bool = false

    /// The variant a number key selects (1-based key -> 0-based index), or nil
    /// when the key is out of range for the generated variant count.
    func variantForKey(_ number: Int) -> Int? {
        let idx = number - 1
        return variants.indices.contains(idx) ? idx : nil
    }

    var auditionedPromotions: [StudioPromotion]? {
        guard let v = auditioningVariant, variants.indices.contains(v) else { return nil }
        return variants[v].promotions
    }

    var auditionedDraftTakeIDs: [String] {
        guard let v = auditioningVariant else { return [] }
        return draftTakeIDsByVariant[v] ?? []
    }
}

// MARK: - Default engine implementations
//
// Both concrete engines (StudioMockEngine, RealStudioEngine) override these.
// The defaults keep the protocol satisfiable and honest for any future engine,
// and mean the no-framework mock build never depends on the FFI-only engine.

extension StudioEngineProtocol {
    /// Honest default: an engine that cannot build an instrument track says so.
    /// A default that returned "ok" with no ids would put the app right back in
    /// the failure this lane exists to fix — a UI that looks like it worked
    /// while the project stayed empty.
    func addInstrumentTrack(name: String, lengthTicks: Int64) async -> StudioInstrumentTrackOutcome {
        StudioInstrumentTrackOutcome(
            ok: false, trackID: nil, clipID: nil,
            message: "Instrument tracks need the on-device engine (this build is running on the mock).")
    }

    /// Honest default, same rule as `addInstrumentTrack` above: an engine that
    /// cannot load a sound SAYS so. A default that returned `ok` would leave a
    /// track showing a Sampler chip over an instrument the engine never made —
    /// and a sampler with no zone does not compile, so the failure would arrive
    /// later, as silence, somewhere else.
    func bindSamples(_ request: StudioSampleBindRequest) async -> StudioSampleBindOutcome {
        .failed("Loading a sound into a sampler needs the on-device engine.")
    }

    func revise(_ request: StudioReviseRequest) async -> StudioReviseOutcome {
        StudioReviseOutcome.failed("Revise runs on the on-device engine.")
    }
    func commitRevise(_ promotions: [StudioPromotion], reason: String) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: "Commit runs on the on-device engine.")
    }
    /// Honest default, same rule as `addInstrumentTrack` and `bindSamples`
    /// above — and this is the one that was breaking it. It used to answer
    /// `ok: true, message: nil` for a re-render it never ran, described as a
    /// "best-effort background step". `StudioViewModel.commitAudition` reads
    /// `swap.ok` and re-adopts on true, so on any engine without an override
    /// the background swap reported success having done nothing, and a test
    /// asserting on this call's `ok` would have been equally true of an engine
    /// that had deleted the feature outright. That is the exact shape
    /// `StudioMockCapabilityCensusTests` exists to make visible; its row for
    /// this capability recorded the danger in prose, and prose does not fail.
    ///
    /// Refusing costs the caller nothing it needs: it has already adopted the
    /// committed take, and the full-quality swap this reports on is the thing
    /// that did not happen. Skipping the second `adoptFresh()` is the whole
    /// behavioural difference.
    func finalizeRevise(draftTakeIDs: [String]) async -> StudioCommandResult {
        StudioCommandResult(
            ok: false,
            message: "Re-rendering a committed take at full quality runs on the on-device engine.")
    }
    func discardRevise(takeIDs: [String]) async -> StudioCommandResult {
        StudioCommandResult(ok: true, message: nil)
    }
    func extendClip(clipID: UUID, addedSeconds: Double, instruction: String, variants: Int) async -> StudioGenOutcome {
        StudioGenOutcome.failed("Extend runs on the on-device engine.")
    }
    func commitExtend(takeID: String, clipID: UUID) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: "Commit runs on the on-device engine.")
    }
    func addLayer(instruction: String, regionStartTicks: Int64, regionEndTicks: Int64, contextClipID: UUID?, stem: StudioStemKind, variants: Int) async -> StudioGenOutcome {
        StudioGenOutcome.failed("Add a Layer runs on the on-device engine.")
    }
    func commitLayer(takeID: String, targetTrackID: String, regionStartTicks: Int64) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: "Commit runs on the on-device engine.")
    }
}
