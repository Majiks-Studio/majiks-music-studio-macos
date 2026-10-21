#if REAL_ENGINE
import XCTest
@testable import MajiksMusicStudio

// THE JOIN, for "error on changing synth type" — and for everything else that
// rides the generic `.catalog` command.
//
// THE BUG, exactly. `StudioInstrumentPreset.commands` and
// `StudioViewModel.setInstrumentParam` build `device.param.set` with
// `"trackId": trackID.uuidString`. That UUID is the UI's OWN surrogate:
// `RealStudioEngine.uuid(forTrack:)` MINTS a fresh one the first time it sees an
// engine track id, so it has no relationship to `t_01J…` at all. Every typed
// command case resolves the two spaces through `uuidTrack` before submitting;
// the `.catalog` case forwarded params verbatim. So pressing "Electric Piano"
// on the shipped build sent the engine a track it had never heard of, got
// `unknown track: 3F2A9C1E-…` back, and put that string in front of a person
// who has never used a DAW inside the sentence "Could not change Electric
// Piano: …". Every preset. Every raw control. Every track. Every time.
//
// WHY EVERY GATE WAS GREEN. `StudioMockEngine` resolves `trackId` by parsing it
// as a UUID and matching its OWN track ids — because in the mock those ids ARE
// the UUIDs the UI minted. In the mock the two id spaces coincide, so the entire
// tone lane passes `swift test` while the product cannot change a sound. The
// conflation lived in the test double, which is the one place it can never be
// seen from. That is why these tests exist and why they are here rather than
// beside StudioInstrumentToneTests.
//
// THE BLAST RADIUS was never just the synth. Everything else that rides
// `.catalog` with a UI id was refused the same way and mostly in SILENCE,
// because those senders are fire-and-forget: `track.rename`, `track.reorder`,
// `track.setColor`, `track.setHeight`, `clip.rename`, `clip.setGain`,
// `clip.mute`. Renaming a track did nothing on the shipped build. The rename
// test below is deliberately not about instruments for exactly that reason.
//
// Silent: `RealStudioEngine(dataDir:audible:)` defaults `audible` to false and
// nothing here calls `startLive`, so this bundle never opens an output device.

@MainActor
final class StudioInstrumentRealEngineTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("majiks-instrument-join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var packagePath: String {
        tempDir.appendingPathComponent("InstrumentJoin.mstudio").path
    }

    /// Poll until the view model has adopted a snapshot satisfying `until`, or
    /// fail. Every gesture here goes through the SAME 30 Hz adoption the app
    /// uses; asserting on the command result alone would prove the call was
    /// made, not that the project changed.
    private func settle(
        _ vm: StudioViewModel,
        _ what: String,
        until: (StudioProjectSnapshot) -> Bool
    ) async throws {
        for _ in 0..<200 {
            if let s = vm.snapshot, until(s) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the engine never reported: \(what)")
    }

    /// A view model polling the given engine, torn down with the test.
    private func pollingModel(_ engine: RealStudioEngine) -> StudioViewModel {
        let vm = StudioViewModel(engine: engine)
        vm.startPolling()
        addTeardownBlock { @MainActor in vm.stopPolling() }
        return vm
    }

    /// A real engine over a real package, one track carrying a bare Synth, and
    /// a view model that has adopted it — the state a person is in the instant
    /// they open the instrument panel.
    private func makeSynthSession() async throws
        -> (RealStudioEngine, StudioViewModel, UUID, String) {
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        let added = await engine.send(
            .trackAdd(trackID: UUID().uuidString, name: "Keys", index: 0))
        XCTAssertTrue(added.ok, "track.add: \(added.message ?? "no message")")

        let vm = pollingModel(engine)
        try await settle(vm, "the track") { !$0.tracks.isEmpty }
        let trackID = try XCTUnwrap(vm.snapshot?.tracks.first?.id)

        await vm.addInstrument(trackID: trackID)?.value
        try await settle(vm, "the synth") { $0.tracks.first?.devices.isEmpty == false }
        let device = try XCTUnwrap(vm.snapshot?.tracks.first?.devices.first)
        XCTAssertEqual(device.kind, "synth")
        XCTAssertTrue(device.params.isEmpty,
                      "a fresh synth stores nothing; the preset assertions below rest on that")
        return (engine, vm, trackID, device.id)
    }

    /// The device's stored params as the ENGINE reports them, read back through
    /// a snapshot rather than from anything the UI remembers.
    private func storedParams(_ vm: StudioViewModel) -> [String: Double] {
        vm.snapshot?.tracks.first?.devices.first?.params ?? [:]
    }

    // MARK: - 1. THE REPORTED BUG

    /// "error on changing synth type."
    ///
    /// Fails before the `.catalog` id resolution exists — the eight
    /// `device.param.set` commands are all refused with `unknown track`, the
    /// transaction rolls back, and the device still stores nothing.
    func testANamedSoundActuallyChangesTheInstrument() async throws {
        let (_, vm, trackID, deviceID) = try await makeSynthSession()
        let preset = try XCTUnwrap(
            StudioInstrumentTone.presets.first { $0.id == "electricPiano" })

        await vm.applyInstrumentPreset(trackID: trackID, deviceID: deviceID, preset).value
        try await settle(vm, "Electric Piano") { _ in !self.storedParams(vm).isEmpty }

        let stored = storedParams(vm)
        for (key, expected) in preset.params {
            XCTAssertEqual(stored[key] ?? .nan, expected, accuracy: 1e-6,
                           "\(key) never reached the engine (stored: \(stored))")
        }
        XCTAssertTrue(preset.matches(stored),
                      "the panel would not light the preset it just applied")
    }

    /// Every preset, not just the first — a resolution that worked for one
    /// track and one device is not the property. And switching between two of
    /// them must leave nothing behind from the previous sound, which is the
    /// promise `StudioInstrumentPreset` makes in its own doc comment and which
    /// was untestable while none of them applied at all.
    func testSwitchingBetweenSoundsLeavesNothingOfThePreviousOne() async throws {
        let (_, vm, trackID, deviceID) = try await makeSynthSession()
        for preset in StudioInstrumentTone.presets {
            await vm.applyInstrumentPreset(trackID: trackID, deviceID: deviceID, preset).value
            try await settle(vm, preset.name) { _ in preset.matches(self.storedParams(vm)) }
            XCTAssertEqual(StudioInstrumentTone.current(for: storedParams(vm))?.id, preset.id,
                           "after applying \(preset.name) the panel names a different sound")
        }
    }

    /// The raw controls under the presets ride the same `.catalog` path with the
    /// same UI id, so they were broken by the same line and are fixed by it.
    func testARawSynthControlReachesTheEngine() async throws {
        let (_, vm, trackID, deviceID) = try await makeSynthSession()

        await vm.setInstrumentParam(trackID: trackID, deviceID: deviceID,
                                    key: "cutoff", value: 900).value
        try await settle(vm, "cutoff") { _ in self.storedParams(vm)["cutoff"] != nil }

        XCTAssertEqual(storedParams(vm)["cutoff"] ?? .nan, 900, accuracy: 1e-6)
        XCTAssertEqual(StudioInstrumentTone.value("cutoff", in: storedParams(vm)), 900,
                       accuracy: 1e-6, "the slider would still be drawing the DSP default")
    }

    /// NOT an instrument test. `track.rename` rides `.catalog` with the same UI
    /// id and was refused identically — and its sender is fire-and-forget, so
    /// on the shipped build renaming a track did nothing and said nothing.
    /// This is the half of the bug nobody reported because it produced no error
    /// at all.
    func testRenamingATrackActuallyRenamesIt() async throws {
        let (_, vm, trackID, _) = try await makeSynthSession()

        vm.renameTrack(trackID, name: "Wurlitzer")
        try await settle(vm, "the new name") { $0.tracks.first?.name == "Wurlitzer" }

        XCTAssertEqual(vm.snapshot?.tracks.first?.name, "Wurlitzer")
    }

    /// A UI id that names nothing live — the track went away under an open
    /// panel — is refused HERE, in a sentence, instead of becoming the engine's
    /// "unknown track: 3F2A9C1E-…" inside a toast. Correct behaviour, reported
    /// in words a person can act on.
    func testAStaleTrackIDIsRefusedInWordsRatherThanInIDs() async throws {
        let (engine, _, _, _) = try await makeSynthSession()

        let result = await engine.send(.catalog(name: "track.rename", params: [
            "trackId": UUID().uuidString, "name": "Ghost",
        ]))
        XCTAssertFalse(result.ok, "a track that does not exist must not be renamed")
        let message = try XCTUnwrap(result.message)
        XCTAssertTrue(message.contains("no longer in the project"),
                      "the refusal does not say what happened: \(message)")
        XCTAssertFalse(message.contains("unknown track:"),
                       "the raw engine id refusal leaked to the user: \(message)")
    }

    /// An engine-native id in a `.catalog` param is left ALONE — and this is
    /// the test that stopped the fix from being a SHAPE test.
    ///
    /// `track.add` mints its track id UI-side and the engine keeps it, so some
    /// engine-native track ids are themselves UUID-shaped. A resolver that read
    /// "looks like a UUID, therefore translate" rewrote one of those into a
    /// refusal. The first draft did exactly that and failed here; the shipped
    /// rule asks which SIDE the string is already on instead.
    func testAnEngineNativeIDInACatalogParamIsUntouched() async throws {
        let (engine, vm, _, _) = try await makeSynthSession()
        let uiID = try XCTUnwrap(vm.snapshot?.tracks.first?.id)
        let resolved = await engine.engineTrackID(uiID)
        let engineID = try XCTUnwrap(resolved)
        XCTAssertNotEqual(engineID, uiID.uuidString,
                          "the two id spaces coincide here, so this proves nothing")
        XCTAssertNotNil(UUID(uuidString: engineID),
                        "this fixture's engine id is meant to be UUID-shaped — that is the trap")

        let result = await engine.send(.catalog(name: "track.rename", params: [
            "trackId": engineID, "name": "Native",
        ]))
        XCTAssertTrue(result.ok, "an engine-native id was mangled: \(result.message ?? "")")
        try await settle(vm, "the rename") { $0.tracks.first?.name == "Native" }
    }

    /// The same, for an engine id that is NOT UUID-shaped — the ordinary case
    /// (`t_01J…`, minted by `addInstrumentTrack` and by the play-a-note path).
    func testANonUUIDEngineIDIsAlsoUntouched() async throws {
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        let vm = pollingModel(engine)
        let added = await engine.send(.trackAdd(trackID: "t_native", name: "Native", index: 0))
        XCTAssertTrue(added.ok, "track.add: \(added.message ?? "no message")")
        try await settle(vm, "the track") { !$0.tracks.isEmpty }

        let result = await engine.send(.catalog(name: "track.rename", params: [
            "trackId": "t_native", "name": "Renamed",
        ]))
        XCTAssertTrue(result.ok, "an engine-native id was mangled: \(result.message ?? "")")
        try await settle(vm, "the rename") { $0.tracks.first?.name == "Renamed" }
    }

    // MARK: - 2. THE TRACK THE APP MADE ITSELF

    /// The Swift half of "say so". `host.rs` derives `origin` from the
    /// journal's actor; this proves the app DECODES it — the seam a Rust test
    /// cannot see and a mock test cannot produce.
    ///
    /// Playing a key on an empty project creates a track
    /// (`ensure_instrument_target`). The one the user made by hand, in the same
    /// project, must stay unexplained.
    func testAPlayedTrackArrivesExplainedAndAHandMadeOneDoesNot() async throws {
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        let vm = pollingModel(engine)

        let added = await engine.send(
            .trackAdd(trackID: UUID().uuidString, name: "By hand", index: 0))
        XCTAssertTrue(added.ok, "track.add: \(added.message ?? "no message")")
        try await settle(vm, "the hand-made track") { !$0.tracks.isEmpty }
        XCTAssertNil(vm.snapshot?.tracks.first?.origin,
                     "a track the user made must arrive with nothing to explain")

        // A key press with no instrument anywhere: the engine makes one. This
        // host is silent (`audible: false`), so `audible` on the outcome is
        // false and says nothing about whether the track was created — the
        // project is the only honest place to look.
        _ = await engine.previewNote(trackID: nil, pitch: 60, velocity: 100)
        try await settle(vm, "the played track") { $0.tracks.count == 2 }

        let tracks = try XCTUnwrap(vm.snapshot?.tracks)
        let explained = tracks.filter { $0.origin == .played }
        XCTAssertEqual(explained.count, 1,
                       "exactly one track was made by playing: \(tracks.map { ($0.name, $0.origin) })")
        XCTAssertEqual(explained.first?.originNote, "Made when you played")
        XCTAssertNotEqual(explained.first?.name, "By hand",
                          "the hand-made track was marked as one the app made")
    }
}
#endif
