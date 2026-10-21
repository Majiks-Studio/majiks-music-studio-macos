import XCTest
@testable import MajiksMusicStudio

// A sound dragged out of the vault has to land ON THE BEAT.
//
// This is the last step of the journey the vault exists for — "browse the
// sounds, filter to something in key, drag it in, have it play in time" — and
// it was the step that did not work. `placeSound` took the raw pixel-derived
// pointer tick and handed it straight to `import.audio`, which made the browser
// drop the ONLY positioning gesture on that canvas that ignored the Snap
// control. Everything else there snaps: clip move, clip trim, automation points
// and the playhead all go through `model.snapMode`
// (`StudioTimelineView.updateDrag`), and the ruler's region and loop drags reach
// the same grid through `StudioSelectionOps.rulerRegion`. Meanwhile the
// transport bar displayed "Snap: Bar", which is the default.
//
// Size of the miss: at the default zoom (`24.0 / ppq` px per tick, ~96 px to the
// bar) three or four pixels of ordinary hand error is about an eighth of a beat,
// ~60 ms at 120 BPM. Audibly late, from the very first bar. On a TV at sofa
// distance the pointer error is larger, not smaller.
//
// ── WHY THE EXISTING SUITE COULD NOT SEE IT ─────────────────────────────────
//
// `StudioSoundsVaultTests` has 26 tests and one of them,
// `testDroppingASoundIsExactlyOneJournaledCommand`, does assert placement:
//
//     model.placeSound(path: ..., onTrack: track.id, atTicks: 3_840)
//     ...
//     XCTAssertEqual(clip.startTicks, 3_840, "the sound did not land where it was dropped")
//
// `3_840` is exactly one bar at ppq 960 in 4/4. The fixture already carries the
// expected value, so the assertion is satisfied whether or not anything snaps —
// a wait predicate that cannot fail. It is a good test of the COMMAND COUNT and
// no test at all of the grid. Every component was proven and the one line that
// decided the tick was asserted by nothing: this repo's commonest survivor
// shape, and the reason this file passes DELIBERATELY OFF-GRID ticks.
//
// Every assertion below is on the ARTIFACT — the `startTicks` of the clip that
// actually appears in the snapshot — never on a flag or on the source of a view.

final class StudioSoundsDropSnapTests: XCTestCase {

    /// One bar and one beat at the engine's resolution, in 4/4.
    /// Named rather than inlined so a reader can see that 137 is nowhere near
    /// either of them.
    private static let ticksPerBar: Int64 = 3_840      // 4 * 960
    private static let ticksPerBeat: Int64 = 960

    /// Deliberately not a multiple of a bar, a beat, or a 16th. This is the
    /// number the old code would have preserved and the whole point of the
    /// file: pass a tick no grid could produce by accident.
    private static let offGrid: Int64 = 137

    /// Bring up a model on the mock engine with a first track to drop onto.
    @MainActor
    private func makeModel() async throws -> (StudioViewModel, StudioTrackSnapshot) {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        try await Task.sleep(nanoseconds: 200_000_000)
        let track = try XCTUnwrap(model.snapshot?.tracks.first,
                                 "the mock project has no track to drop a sound onto")
        return (model, track)
    }

    /// Drop a sound and return the `startTicks` of the clip that appeared.
    @MainActor
    private func drop(
        _ model: StudioViewModel, onto track: StudioTrackSnapshot,
        at ticks: Int64, name: String
    ) async throws -> Int64 {
        let before = Set((model.snapshot?.tracks.first(where: { $0.id == track.id })?.clips ?? [])
            .map(\.id))
        model.placeSound(path: "/tmp/vault/Boom Bap/\(name).wav",
                         onTrack: track.id, atTicks: ticks)
        try await Task.sleep(nanoseconds: 400_000_000)
        let after = try XCTUnwrap(model.snapshot?.tracks.first(where: { $0.id == track.id }))
        let fresh = try XCTUnwrap(
            after.clips.first(where: { !before.contains($0.id) }),
            "the sound never landed, so there is nothing to check the grid against")
        return fresh.startTicks
    }

    // MARK: - The fix

    /// THE test. An off-grid drop with the default Snap lands on the bar line.
    ///
    /// Mutation check: remove the `hardSnap` from `placeSound` and this fails
    /// with 137 != 0.
    @MainActor
    func testASoundDroppedOffTheGridLandsOnTheBar() async throws {
        let (model, track) = try await makeModel()
        defer { model.stopPolling() }
        XCTAssertEqual(model.snapMode, .bar,
                       "this test assumes the shipping default; if Snap's default changed, so did the journey")

        let landed = try await drop(model, onto: track,
                                    at: Self.ticksPerBar * 5 + Self.offGrid, name: "Kick 03")
        XCTAssertEqual(
            landed, Self.ticksPerBar * 5,
            "a sound dropped 137 ticks past bar 6 stayed 137 ticks late. With Snap: Bar showing in "
            + "the transport, a dropped loop must land ON the bar — otherwise it is audibly out of "
            + "time from the first beat, which is the whole thing the vault is for.")
    }

    /// It rounds to the NEAREST line, not always downwards — a drop just before
    /// a bar belongs to that bar, not to the one before it.
    @MainActor
    func testADropJustBeforeABarLineLandsOnThatBarNotThePreviousOne() async throws {
        let (model, track) = try await makeModel()
        defer { model.stopPolling() }

        let landed = try await drop(model, onto: track,
                                    at: Self.ticksPerBar * 3 - 40, name: "Snare 01")
        XCTAssertEqual(
            landed, Self.ticksPerBar * 3,
            "a drop 40 ticks SHORT of bar 4 was floored back to bar 3 — a whole bar early. The grid "
            + "must round to the nearest line, the way every other gesture on this canvas does.")
    }

    // MARK: - The Snap control still governs it

    /// Snap: Off means off. The fix must not become a second, hidden rule that
    /// overrides the control the user can see.
    ///
    /// Mutation check: hard-code the snap instead of reading `snapMode` and this
    /// fails with 137 != 5*bar+137.
    @MainActor
    func testWithSnapOffTheSoundLandsExactlyWhereItWasDropped() async throws {
        let (model, track) = try await makeModel()
        defer { model.stopPolling() }
        model.snapMode = .off

        let raw = Self.ticksPerBar * 5 + Self.offGrid
        let landed = try await drop(model, onto: track, at: raw, name: "Hat 02")
        XCTAssertEqual(
            landed, raw,
            "Snap was Off and the drop was still pulled to the grid. The fix must honour the control "
            + "in the transport bar, not replace it with a rule nobody can turn off.")
    }

    /// Beat mode snaps to the beat, not to the bar — the fix reads the mode
    /// rather than assuming one.
    @MainActor
    func testSnapBeatLandsOnTheBeatAndNotOnTheBar() async throws {
        let (model, track) = try await makeModel()
        defer { model.stopPolling() }
        model.snapMode = .beat

        // Bar 3 + 2 beats + a bit. Under .bar this would collapse to bar 3;
        // under .beat it must keep the two beats.
        let landed = try await drop(
            model, onto: track,
            at: Self.ticksPerBar * 2 + Self.ticksPerBeat * 2 + 30, name: "Rim 01")
        XCTAssertEqual(
            landed, Self.ticksPerBar * 2 + Self.ticksPerBeat * 2,
            "Snap: Beat did not land on the beat. If this equals the bar line instead, the snap is "
            + "hard-coded to bars and ignores the mode.")
    }

    // MARK: - The guard on the old assertion

    /// Nails down WHY the existing vault test cannot see this, so nobody
    /// "simplifies" this file away by pointing at it.
    ///
    /// This is not a test of the product; it is a test of the other test's
    /// blind spot. It asserts that the value that suite uses is a bar multiple,
    /// i.e. that its placement assertion passes with the snap removed.
    func testTheOldPlacementAssertionUsesABarAlignedFixtureAndSoCannotSeeAMissingSnap() {
        let fixture: Int64 = 3_840   // the literal in testDroppingASoundIsExactlyOneJournaledCommand
        XCTAssertEqual(
            fixture % Self.ticksPerBar, 0,
            "the premise of this file is that 3_840 is bar-aligned; if that changed, re-check whether "
            + "the older test now covers the grid and this file is redundant")
        XCTAssertEqual(
            StudioTimelineMath.hardSnap(
                fixture, mode: .bar,
                timeSignature: .fourFour,
                phaseAnchorTicks: 0),
            fixture,
            "snapping a bar-aligned tick is the identity, which is exactly why an assertion built on "
            + "one is satisfied whether or not the snap is there at all")
    }
}
