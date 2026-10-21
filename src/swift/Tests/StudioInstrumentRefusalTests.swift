import XCTest
import Combine
import Foundation
@testable import MajiksMusicStudio

// THE REFUSAL GATE 6 CAN SEE, ASSERTED INSTEAD OF ROUTED AROUND.
//
// `StudioEngineProtocol.addInstrumentTrack` has a default that refuses, and only
// `RealStudioEngine` overrides it — so under `MAJIKS_ENGINE=mock swift test`
// there is no such thing as a MIDI clip. A lane discovered this the expensive
// way: its first stems test called `addInstrumentTrack`, got `ok: false`, and
// SKIPPED. A skipped test is a green line asserting nothing, and the warning it
// left behind (`StudioBrowserPanesTests`) is a comment, which cannot fail.
//
// The engine half is covered by gate 7 (`StudioPianoRollRealEngineTests` builds
// its whole fixture through the real `addInstrumentTrack`). What NOTHING covered
// is the half that is entirely mock-visible and entirely in the app: what
// `StudioViewModel.addInstrumentTrack` does when the engine says no. That path
// decides whether a user who presses the toolbar's Instrument button on a build
// without the on-device engine gets an explanation or gets silence — and silence
// with a selected clip that does not exist would be worse than either.
//
// Same discipline as `StudioLandingRefusalTests`, which asserts the OTHER
// engine-says-no path (Open in Studio) for the same reason.

@MainActor
final class StudioInstrumentRefusalTests: XCTestCase {

    /// The preview engine's refusal, spelled out here rather than read back from
    /// the engine.
    ///
    /// Reading it back would compare the message against itself and pass for any
    /// wording at all, including an empty one. Written independently, a reworded
    /// default has to be reckoned with — which is the point: this sentence is
    /// what a person sees.
    private static let previewRefusal =
        "Instrument tracks need the on-device engine (this build is running on the mock)."

    private func bootedModel(_ engine: any StudioEngineProtocol) async throws -> StudioViewModel {
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        for _ in 0..<160 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        _ = try XCTUnwrap(model.snapshot?.tracks.first, "the project never arrived")
        return model
    }

    private func waitFor(_ timeout: TimeInterval = 3.0,
                         _ predicate: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - The refusal reaches the person

    func testARefusedInstrumentTrackSaysSoAndSelectsNothing() async throws {
        let log = InstrumentToastLog()
        let model = try await bootedModel(StudioMockEngine())
        defer { model.stopPolling() }

        let tracksBefore = try XCTUnwrap(model.snapshot?.tracks.count)
        model.selection.clipIDs = []
        model.newlyCreatedMidiClipID = nil

        model.addInstrumentTrack()

        // ⚠️ WAIT FOR THIS TOAST, not for "a toast". `ToastManager.shared` is
        // process-wide and the swift-testing suites run in parallel with this
        // one, so "the log is non-empty" wakes on whatever another test posted —
        // which is exactly the failure `e53c77e` fixed in the contract lane's
        // refusal test (`a refused rename said nothing: ["Deleted Drums..."]`, a
        // delete that test never performed). Matching the exact sentence cannot
        // wake on someone else's message, and if the app said nothing the wait
        // times out and the assertion below names everything that DID arrive.
        await waitFor { log.seen.contains { $0.message == Self.previewRefusal } }

        XCTAssertTrue(
            log.seen.contains { $0.message == Self.previewRefusal && $0.style == .warning },
            """
            the engine refused to build an instrument track and the app did not say so as a \
            warning. The toolbar button then reads as broken rather than as unavailable, which \
            is the silent-degradation shape this repo keeps paying for. What did arrive: \
            \(log.seen.map { "[\($0.style)] \($0.message)" })
            """)
        XCTAssertFalse(
            log.seen.contains { $0.style == .success && $0.message.contains("Instrument track") },
            "a refused creation was announced as a success: \(log.seen.map(\.message))")

        // AND NOTHING WAS FABRICATED. The failure mode worth guarding is not the
        // missing sentence, it is a UI that proceeds as if the clip existed: a
        // piano roll opened onto an id no engine has answers every gesture with
        // "unknown clip" and looks like the ROLL is broken.
        XCTAssertNil(model.newlyCreatedMidiClipID,
                     "a refused creation handed the piano roll a clip id to open onto")
        XCTAssertTrue(model.selection.clipIDs.isEmpty,
                      "a refused creation selected a clip that was never made")
        XCTAssertEqual(model.snapshot?.tracks.count, tracksBefore,
                       "a refused creation still changed the arrangement")
    }

    /// THE CALIBRATION, and without it the test above is decoration.
    ///
    /// "No clip was selected" and "nothing was announced as a success" are both
    /// true of a view model whose `addInstrumentTrack` is an empty function. So
    /// the SAME call is made against an engine that CAN build the track, and the
    /// same three properties must all move.
    ///
    /// The stand-in mints its ids and does not touch the project, which is
    /// deliberately less than the real engine does — it is here to prove the
    /// probe can see success, not to be a second engine. Anything it asserted
    /// about the arrangement would be asserting about itself.
    func testTheRefusalProbeCanActuallySeeASuccessfulCreation() async throws {
        let log = InstrumentToastLog()
        let engine = InstrumentCapableSpyEngine()
        let model = try await bootedModel(engine)
        defer { model.stopPolling() }

        model.selection.clipIDs = []
        model.newlyCreatedMidiClipID = nil

        model.addInstrumentTrack()
        await waitFor { model.newlyCreatedMidiClipID != nil }

        let clipID = try XCTUnwrap(
            model.newlyCreatedMidiClipID,
            "an engine that CAN build an instrument track produced no clip for the roll, so the assertions in the refusal test above are true of everything and prove nothing")
        XCTAssertEqual(model.selection.clipIDs, [clipID],
                       "the new clip must be selected, or the roll opens onto nothing")
        // The name is the position the track is ABOUT to take, so a project with
        // eight tracks asks for "Instrument 9". Asserted because a constant name
        // — every instrument track called "Instrument 1" — is the shape this
        // would silently degrade into, and it looks fine until the second one.
        // `[...]`, not `contains`: exactly one ask per press.
        let names = await engine.requestedNames
        let trackCount = try XCTUnwrap(model.snapshot?.tracks.count)
        XCTAssertEqual(names, ["Instrument \(trackCount + 1)"],
                       "the view model must name the track after its position, and must ask exactly once")

        // Same discipline: a specific toast, not any toast.
        await waitFor { log.seen.contains { $0.style == .success && $0.message.contains("Instrument track") } }
        XCTAssertTrue(
            log.seen.contains { $0.style == .success && $0.message.contains("Instrument track") },
            "a successful creation was not announced, so the refusal test's \"no success toast\" assertion is true of everything: \(log.seen.map(\.message))")
        XCTAssertFalse(
            log.seen.contains { $0.message == Self.previewRefusal },
            "the success path posted the refusal message")
    }

    /// The bars-to-ticks half, which is the only arithmetic in this path and the
    /// only thing a caller can get wrong without the engine noticing: a clip of
    /// the wrong length is a clip the roll draws the wrong number of bars for.
    func testTheRequestedLengthIsTheAskedForNumberOfBars() async throws {
        let engine = InstrumentCapableSpyEngine()
        let model = try await bootedModel(engine)
        defer { model.stopPolling() }

        model.addInstrumentTrack(bars: 8)
        await waitFor { model.newlyCreatedMidiClipID != nil }

        let lengths = await engine.requestedLengths
        let asked = try XCTUnwrap(lengths.first)
        XCTAssertEqual(
            asked, 8 * model.timeSignature.ticksPerBar,
            "8 bars asked for \(asked) ticks; the roll would draw a clip of the wrong length")
        XCTAssertGreaterThan(asked, 0, "a zero-length clip has nowhere to put a note")
    }
}

/// Collects every toast posted while it lives.
///
/// ⚠️ `dropFirst()` IS LOAD-BEARING and is not defensive tidiness.
/// `ToastManager.shared` is process-wide and `$currentToast` is `@Published`, so
/// `sink` REPLAYS the current value the instant it subscribes: whatever the
/// previously run test left behind is recorded before this test has done
/// anything, and a wait on "a toast has arrived" then returns immediately on
/// somebody else's message. That is not hypothetical — `e53c77e` fixed exactly
/// this in the contract lane's refusal test. Same shape as the process-wide
/// `guard::violations()` trap in GATES.md.
///
/// (`StudioCatalogContractTests` and `StudioDeleteAndDiscoverTests` each have
/// their own; this one is private to this file for the same reason theirs are.)
@MainActor
private final class InstrumentToastLog {
    private(set) var seen: [ToastMessage] = []
    private var cancellable: AnyCancellable?
    init() {
        cancellable = ToastManager.shared.$currentToast.dropFirst().sink { [weak self] toast in
            if let toast { self?.seen.append(toast) }
        }
    }
}

/// An engine that CAN build an instrument track, so the success half of the
/// refusal path is observable under gate 6.
///
/// It wraps a real `StudioMockEngine` for the READ half — the view model needs a
/// project before there is anything to add to — and overrides only
/// `addInstrumentTrack`, minting the two ids the way the real engine hands them
/// back. It deliberately does NOT place a track or a clip in the project: this
/// exists to show the app's success path moves, and a stand-in that also
/// simulated the engine would be a second, unverifiable engine (see
/// `StudioCatalogSchema.swift` on why the mock does not get to invent contracts).
private actor InstrumentCapableSpyEngine: StudioEngineProtocol {
    private let inner = StudioMockEngine()
    private(set) var requestedNames: [String] = []
    private(set) var requestedLengths: [Int64] = []

    func addInstrumentTrack(name: String, lengthTicks: Int64) async -> StudioInstrumentTrackOutcome {
        requestedNames.append(name)
        requestedLengths.append(lengthTicks)
        return StudioInstrumentTrackOutcome(
            ok: true, trackID: UUID(), clipID: UUID(), message: nil)
    }

    func snapshot(ifNewerThan revision: UInt64?) async -> StudioProjectSnapshot? {
        await inner.snapshot(ifNewerThan: revision)
    }

    @discardableResult
    func send(_ command: StudioEngineCommand) async -> StudioCommandResult {
        await inner.send(command)
    }

    func setMetronome(enabled: Bool?, levelDB: Double?, countInBeats: Int?) async {
        await inner.setMetronome(enabled: enabled, levelDB: levelDB, countInBeats: countInBeats)
    }

    func importAudio(path: String, trackID: UUID?, startTicks: Int64) async -> StudioCommandResult {
        await inner.importAudio(path: path, trackID: trackID, startTicks: startTicks)
    }

    @discardableResult func undo() async -> Bool { await inner.undo() }
    @discardableResult func redo() async -> Bool { await inner.redo() }

    func waveformTile(_ key: StudioTileKey) async -> StudioWaveformTile? {
        await inner.waveformTile(key)
    }

    @discardableResult
    func openInStudio(_ request: StudioLandingRequest) async -> StudioCommandResult {
        await inner.openInStudio(request)
    }
}
