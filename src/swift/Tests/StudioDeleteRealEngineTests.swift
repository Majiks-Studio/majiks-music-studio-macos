#if REAL_ENGINE
import XCTest
@testable import MajiksMusicStudio

// THE JOIN, for the delete surface.
//
// The mock-engine tests in StudioDeleteAndDiscoverTests prove the gesture
// grammar (one bracket, one undo unit, refusals surfaced). These prove the
// same gestures against the REAL FFI-backed engine and the REAL journal —
// including the two seams only a real build exercises:
//
//  - the snapshot DECODE of `devices` (serde emits it omitted-when-empty;
//    a key mismatch would silently read every track as instrument-free and
//    "Remove Instrument" would never appear);
//  - the route() mapping of .trackRemove / .deviceRemove onto catalog wire
//    params via the UUID<->engine-id map.
//
// Audio: RealStudioEngine(dataDir:audible:) with audible: false and nothing
// here calls startLive, so this bundle is silent at the device.

@MainActor
final class StudioDeleteRealEngineTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("majiks-delete-join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var packagePath: String {
        tempDir.appendingPathComponent("DeleteJoin.mstudio").path
    }

    /// A real engine with one instrument track (track + synth + MIDI clip),
    /// built through the SAME addInstrumentTrack the toolbar button calls,
    /// and a view model that has adopted it.
    private func makeSession() async throws -> (RealStudioEngine, StudioViewModel, StudioTrackSnapshot) {
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        let outcome = await engine.addInstrumentTrack(name: "Keys", lengthTicks: 3840 * 4)
        XCTAssertTrue(outcome.ok, "addInstrumentTrack: \(outcome.message ?? "no message")")

        let vm = StudioViewModel(engine: engine)
        vm.startPolling()
        for _ in 0..<200 where vm.snapshot == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        vm.stopPolling()
        let track = try XCTUnwrap(
            vm.snapshot?.tracks.first(where: { !$0.clips.isEmpty }),
            "the view model never adopted the instrument track")
        return (engine, vm, track)
    }

    func testDevicesDecodeOffTheRealSnapshot() async throws {
        let (_, _, track) = try await makeSession()
        // The contract seam: serde's Track omits `devices` when empty and
        // emits [{id, kind}] otherwise; kind is rename_all = "lowercase".
        XCTAssertEqual(track.devices.count, 1,
                       "the synth device.add put on this track must be visible to the UI")
        XCTAssertEqual(track.devices.first?.kind, "synth")
        XCTAssertFalse(track.devices.first?.id.isEmpty ?? true)
    }

    func testDeleteTrackIsOneUndoUnitOnTheRealJournal() async throws {
        let (engine, vm, track) = try await makeSession()

        await vm.deleteTrack(track.id)?.value
        XCTAssertEqual(vm.snapshot?.tracks.contains(where: { $0.id == track.id }), false,
                       "the track (clips and all) is gone from the real snapshot")

        // ONE undo brings the whole gesture back: track, clip, instrument.
        let undone = await engine.undo()
        XCTAssertTrue(undone, "the txn bracket landed as an undoable unit")
        let fresh = await engine.snapshot(ifNewerThan: nil)
        let after = try XCTUnwrap(fresh)
        let restored = try XCTUnwrap(
            after.tracks.first(where: { $0.name == track.name }),
            "undo restored the track")
        XCTAssertEqual(restored.devices.map(\.kind), ["synth"],
                       "the instrument came back with it (track_restore_sequence)")
        XCTAssertEqual(restored.clips.count, track.clips.count,
                       "the clips came back with it")
    }

    func testRemoveInstrumentRoundTripsOnTheRealEngine() async throws {
        let (engine, vm, track) = try await makeSession()
        let device = try XCTUnwrap(track.devices.first)

        await vm.removeInstrument(trackID: track.id, deviceID: device.id).value
        var fresh = await engine.snapshot(ifNewerThan: nil)
        var snap = try XCTUnwrap(fresh)
        XCTAssertEqual(snap.tracks.first(where: { $0.id == track.id })?.devices ?? [], [],
                       "device.remove reached the real registry")

        _ = await engine.undo()
        fresh = await engine.snapshot(ifNewerThan: nil)
        snap = try XCTUnwrap(fresh)
        XCTAssertEqual(snap.tracks.first(where: { $0.id == track.id })?.devices.map(\.id),
                       [device.id],
                       "undo restored the instrument by its own id")
    }

    func testTheRealRefusalMessageReachesTheResult() async throws {
        let (engine, _, track) = try await makeSession()
        // Bypass the view model's clip-clearing on purpose: track.remove on a
        // track that still has clips must refuse, and the ENGINE's own words
        // must come back on the result — this is the string the UI surfaces.
        let result = await engine.send(.trackRemove(trackID: track.id))
        XCTAssertFalse(result.ok, "a track with clips refuses track.remove")
        let message = try XCTUnwrap(result.message)
        XCTAssertTrue(message.contains("track.remove"),
                      "the surfaced message names the command: \(message)")
        XCTAssertTrue(message.lowercased().contains("not empty"),
                      "the surfaced message is the engine's track-not-empty text: \(message)")
    }
}
#endif
