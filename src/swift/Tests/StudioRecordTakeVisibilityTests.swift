import XCTest
@testable import MajiksMusicStudio

// RECORD A PASS, THEN GO AND LOOK FOR IT.
//
// THE DEFECT. `takesBrowserItems` — everything Browser ▸ Takes draws — is NOT
// part of the snapshot. It comes from a separate `studio_takes` read, and
// `refreshTakes()` had exactly two callers in the whole app: `pollOnce`, guarded
// by `snapshot == nil` (the FIRST adoption of a session, once), and
// `adoptFresh()`. The 30 Hz poll therefore cannot bring a new take into that
// list, whatever the engine did.
//
// Nineteen call sites know this and call `adoptFresh()` after a take-making
// workflow: revise, extend, add-a-layer, keep, place, purge. `stopRecording()`
// did not. It sent `record.stop` fire-and-forget and returned. So: record a
// pass, watch the clip appear on the timeline (the clip IS in the snapshot),
// open Takes — and the take is not there. It shows up later, out of nowhere,
// the next time anything else forces a fresh adoption.
//
// ⚠️ HOW THIS IS PROVEN, AND WHAT THE MOCK CANNOT DO.
//
// `StudioMockEngine.landRecording` places a clip and a take LANE; it does not
// append to `takeRecords`. The real engine does — `record.commit` is written
// into `studio_takes` with `kind: "record"` — so the mock does not share the
// engine's behaviour here and cannot produce the take whose absence is the
// symptom. That is the GATES.md hazard exactly: a defect the test double cannot
// express.
//
// So the test does not wait for the mock to invent a take. It makes the
// engine's take list CHANGE behind the view model's back — by purging on the
// engine directly, which flips `offline` on every candidate without any
// view-model call — and then asks whether stopping a recording re-read it. That
// is the property under test: does the record path go back to the engine for
// the take list, or does it leave a stale copy on screen? The purge stands in
// for the landed take the real engine would have added, and it is a strictly
// harder case, because it changes records that are already in the list.

@MainActor
final class StudioRecordTakeVisibilityTests: XCTestCase {

    private func settle(_ timeout: TimeInterval = 3.0,
                        until condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func liveModel() async -> (StudioMockEngine, StudioViewModel) {
        let engine = StudioMockEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        await settle { model.snapshot != nil }
        // Recording is what is under test; a count-in would only add a timer.
        model.countInBeats = 0
        return (engine, model)
    }

    /// The first adoption really does load the list, so the assertion below is
    /// about the RECORD path and not about the list never being loaded at all.
    func testTheFirstAdoptionLoadsTheTakeList() async {
        let (_, model) = await liveModel()
        defer { model.stopPolling() }
        await settle { !model.takesBrowserItems.isEmpty }
        XCTAssertFalse(
            model.takesBrowserItems.isEmpty,
            "the fixture seeds takes and the first adoption reads them; without this the "
            + "test below could pass on a list that is empty for the wrong reason")
        XCTAssertFalse(
            model.takesBrowserItems.contains(where: \.offline),
            "nothing is purged yet")
    }

    /// THE REGRESSION TEST. Stop a recording and the take list on screen must be
    /// the engine's, not the one from session start.
    func testStoppingARecordingRereadsTheTakeList() async throws {
        let (engine, model) = await liveModel()
        defer { model.stopPolling() }
        await settle { !model.takesBrowserItems.isEmpty }
        let track = try XCTUnwrap(model.snapshot?.tracks.first, "the fixture has tracks")

        // The engine's take list changes, with no view-model call anywhere near
        // it. Nothing the app does on its own can notice this.
        let purge = await engine.purgeTakes(scope: .all)
        XCTAssertGreaterThan(purge.purgedCount, 0, "the purge has to actually change something")
        XCTAssertFalse(
            model.takesBrowserItems.contains(where: \.offline),
            "the view model's cached list must still be the stale one at this point, or the "
            + "test is measuring the poll rather than the record path")

        model.setTrackArm(track.id, armed: true)
        await settle { model.firstArmedTrack != nil }
        model.toggleRecord()                       // start
        await settle { model.isRecording }
        try await Task.sleep(nanoseconds: 120_000_000)
        model.toggleRecord()                       // stop and land

        await settle { model.takesBrowserItems.contains(where: \.offline) }
        XCTAssertTrue(
            model.takesBrowserItems.contains(where: \.offline),
            """
            Browser ▸ Takes is still showing the list this session started with. \
            record.stop never re-read it, so a take the engine has just landed is \
            not on screen and there is nothing the user can do to make it appear.
            """)
    }

    /// Cancelling has the same obligation: after one or more loop passes it
    /// leaves the earlier passes standing, so the list it leaves behind is a
    /// different list from the one before it.
    func testCancellingARecordingAlsoRereadsTheTakeList() async throws {
        let (engine, model) = await liveModel()
        defer { model.stopPolling() }
        await settle { !model.takesBrowserItems.isEmpty }
        let track = try XCTUnwrap(model.snapshot?.tracks.first)

        _ = await engine.purgeTakes(scope: .all)
        XCTAssertFalse(model.takesBrowserItems.contains(where: \.offline))

        model.setTrackArm(track.id, armed: true)
        await settle { model.firstArmedTrack != nil }
        model.toggleRecord()
        await settle { model.isRecording }
        model.cancelRecording()

        await settle { model.takesBrowserItems.contains(where: \.offline) }
        XCTAssertTrue(
            model.takesBrowserItems.contains(where: \.offline),
            "cancelling a recording left a stale take list on screen")
    }
}
