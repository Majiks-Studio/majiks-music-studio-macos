#if REAL_ENGINE
import XCTest
@testable import MajiksMusicStudio

// THE JOIN, for the sampler.
//
// StudioSamplerUITests proves the gesture grammar against the preview engine:
// the right commands, one bracket, refusals surfaced. It cannot prove the seam,
// because the preview engine invents its own source ids and reads no files.
// These tests drive the SAME view-model gestures a click drives, against the
// REAL FFI-backed engine, over a REAL `.mstudio` package, with a REAL wav on
// disk — and read the result back out of the REAL snapshot.
//
// Three seams only a real build exercises, each of which has silently swallowed
// a feature in this repo before:
//
//  1. the FFI call itself (`bind_samples`) — a Swift-side arg name that does
//     not match the host's parser fails at RUNTIME, not at compile time;
//  2. the snapshot DECODE of `devices[].zones` — serde emits `source_id`,
//     not `sourceId`, and a key mismatch would read every sampler as
//     zone-free, so the panel would show "no sounds" over a working instrument;
//  3. `loadedSources` — the only thing that can put a NAME on a bound sound.
//
// The AUDIO proof is not here and deliberately so: it lives in
// `engine/agent-surface/tests/sampler_ui_binding.rs`, which drives the same
// host method, renders the master through the same offline bounce the device
// callback runs, and measures the frequency (playing the root key of a 440 Hz
// recording must come out at 440 Hz; +12 semitones at 2.00x). A Swift test
// asserting "the picker appeared" would be worthless next to that.
//
// Silent: `RealStudioEngine(dataDir:audible:)` defaults `audible` to false and
// nothing here calls startLive, so this bundle never opens an output device.

@MainActor
final class StudioSamplerRealEngineTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("majiks-sampler-join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var packagePath: String {
        tempDir.appendingPathComponent("SamplerJoin.mstudio").path
    }

    /// A real 16-bit mono WAV the engine can genuinely decode. Written by hand
    /// rather than pulled from a fixture directory so the test has no
    /// dependency on another lane's generated files — a missing fixture would
    /// otherwise read as "the sampler is broken".
    private func writeTone(named name: String, hz: Double = 440, seconds: Double = 1) throws -> String {
        let rate = 48_000
        let frames = Int(Double(rate) * seconds)
        var body = Data()
        for i in 0..<frames {
            let v = sin(2 * .pi * hz * Double(i) / Double(rate)) * 0.6
            var s = Int16(max(-1, min(1, v)) * 32_000)
            withUnsafeBytes(of: &s) { body.append(contentsOf: $0) }
        }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8)
        wav += le32(36 + body.count)
        wav += Data("WAVEfmt ".utf8)
        wav += le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        wav += Data("data".utf8) + le32(body.count) + body
        let url = tempDir.appendingPathComponent(name)
        try wav.write(to: url)
        return url.path
    }

    /// A real engine with one EMPTY track (no instrument), plus a view model
    /// that has adopted it — the state every load gesture starts from.
    private func makeSession() async throws -> (RealStudioEngine, StudioViewModel, UUID) {
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        let added = await engine.send(
            .trackAdd(trackID: UUID().uuidString, name: "Sampler", index: 0))
        XCTAssertTrue(added.ok, "track.add: \(added.message ?? "no message")")

        let vm = StudioViewModel(engine: engine)
        vm.startPolling()
        for _ in 0..<200 where vm.snapshot?.tracks.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        vm.stopPolling()
        let track = try XCTUnwrap(vm.snapshot?.tracks.first, "no track was adopted")
        XCTAssertTrue(track.devices.isEmpty, "the fixture track must start with no instrument")
        return (engine, vm, track.id)
    }

    // MARK: THE join

    func testLoadingASoundLandsARealSamplerWithARealZone() async throws {
        let (_, vm, trackID) = try await makeSession()
        let path = try writeTone(named: "Pad C3.wav")

        await vm.loadSamplerSound(trackID: trackID, path: path, rootPitch: 69).value

        let device = try XCTUnwrap(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first,
            "the gesture reached the engine but no instrument came back")
        XCTAssertEqual(device.kind, "sampler")

        let zone = try XCTUnwrap(device.zones.first, """
            the sampler has NO zones in the real snapshot. Either the zone never \
            landed, or `devices[].zones` failed to decode (serde emits source_id, \
            not sourceId) — and a sampler that reads as zone-free shows an empty \
            panel over a working instrument.
            """)
        XCTAssertEqual(zone.loPitch, 0)
        XCTAssertEqual(zone.hiPitch, 127)
        XCTAssertEqual(zone.rootPitch, 69, "the root key did not survive the FFI round trip")
        XCTAssertEqual(zone.sourceID.count, 64,
                       "a real source id is a 64-char blake3 hex digest; got \(zone.sourceID)")
    }

    /// The zone's `source_id` must be THE SAME content address a clip gets for
    /// the same file. If it ever stops being, a second asset pipeline has grown
    /// — which is the thing the whole design forbids.
    func testAZoneAndAClipNameTheSameAssetForTheSameFile() async throws {
        let (engine, vm, trackID) = try await makeSession()
        let path = try writeTone(named: "Shared.wav")

        await vm.loadSamplerSound(trackID: trackID, path: path).value
        let zone = try XCTUnwrap(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first?.zones.first)

        // Import the SAME file as a clip on a second track.
        let added = await engine.send(.trackAdd(trackID: UUID().uuidString, name: "Audio", index: 1))
        XCTAssertTrue(added.ok)
        var latest = await engine.snapshot(ifNewerThan: nil)
        var fresh = try XCTUnwrap(latest)
        let audioTrack = try XCTUnwrap(fresh.tracks.first(where: { $0.id != trackID })).id
        let imported = await engine.importAudio(path: path, trackID: audioTrack, startTicks: 0)
        XCTAssertTrue(imported.ok, "import.audio: \(imported.message ?? "no message")")
        latest = await engine.snapshot(ifNewerThan: nil)
        fresh = try XCTUnwrap(latest)

        // Both must resolve through the same registry, so the file appears once.
        XCTAssertNotNil(fresh.loadedSources[zone.sourceID],
                        "the zone's asset is not in loadedSources at all")
        let matching = fresh.loadedSources.filter { $0.value == path }
        XCTAssertEqual(matching.count, 1, """
            the same file produced \(matching.count) distinct asset ids, so the sampler \
            and the clip layer are ingesting through DIFFERENT pipelines
            """)
        XCTAssertEqual(matching.keys.first, zone.sourceID)
    }

    func testTheBoundSoundCanBeNamed() async throws {
        let (_, vm, trackID) = try await makeSession()
        let path = try writeTone(named: "Kick 01.wav")

        await vm.loadSamplerSound(trackID: trackID, path: path).value

        let zone = try XCTUnwrap(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first?.zones.first)
        XCTAssertEqual(vm.soundName(zone.sourceID), "Kick 01.wav",
                       "without a name the panel can only show a 64-character hash")
    }

    // MARK: The drum rack, over the real bus

    func testADrumRackLandsOnePadPerFileFromTheGeneralMidiKick() async throws {
        let (_, vm, trackID) = try await makeSession()
        let paths = try (0..<4).map { try writeTone(named: "pad\($0).wav", hz: 220 + Double($0) * 55) }

        await vm.loadDrumRack(trackID: trackID, paths: paths).value

        let device = try XCTUnwrap(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        XCTAssertEqual(device.kind, "drum")
        XCTAssertEqual(device.zones.count, 4)
        XCTAssertEqual(device.zones.map(\.loPitch), [36, 37, 38, 39])
        XCTAssertTrue(device.zones.allSatisfy { $0.isSingleKey },
                      "a drum pad covers exactly one key; the engine refuses any other shape")
        XCTAssertEqual(Set(device.zones.map(\.sourceID)).count, 4,
                       "four different files collapsed onto fewer assets")
    }

    /// A rack wider than sixteen keys is a hard compile error in the engine, so
    /// the gesture must never journal one. Driven through the ENGINE directly
    /// (the view model caps at sixteen files before it sends, which is the
    /// separate protection this deliberately steps around).
    func testARackWiderThanTheHardwareIsRefusedByTheEngine() async throws {
        let (engine, _, trackID) = try await makeSession()
        let a = try writeTone(named: "low.wav")
        let b = try writeTone(named: "high.wav")

        let outcome = await engine.bindSamples(StudioSampleBindRequest(
            trackID: trackID, deviceID: nil, kind: "drum",
            bindings: [.pad(a, key: 36), .pad(b, key: 60)],
            reason: "too wide"))

        XCTAssertFalse(outcome.ok, "a 25-key spread must not be accepted into a 16-pad rack")
        XCTAssertTrue(outcome.message?.contains("wider than") ?? false,
                      "the refusal has to say what is wrong: \(outcome.message ?? "no message")")
        let latest = await engine.snapshot(ifNewerThan: nil)
        let fresh = try XCTUnwrap(latest)
        XCTAssertTrue(fresh.tracks.first(where: { $0.id == trackID })?.devices.isEmpty ?? false,
                      "a refused gesture left an instrument behind")
    }

    func testASynthRefusesASoundWithAMessageAPersonCanAct() async throws {
        let (engine, vm, trackID) = try await makeSession()
        await vm.addInstrument(trackID: trackID)?.value
        let device = try XCTUnwrap(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        XCTAssertEqual(device.kind, "synth")
        let path = try writeTone(named: "nope.wav")

        let outcome = await engine.bindSamples(StudioSampleBindRequest(
            trackID: trackID, deviceID: device.id, kind: nil,
            bindings: [.acrossTheKeyboard(path)], reason: "into a synth"))

        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.message?.lowercased().contains("synth") ?? false,
                      "the refusal must name the reason: \(outcome.message ?? "no message")")
    }

    // MARK: Undo, on the real journal

    func testOneUndoTakesBackTheInstrumentAndItsSound() async throws {
        let (engine, vm, trackID) = try await makeSession()
        let path = try writeTone(named: "Undo me.wav")
        await vm.loadSamplerSound(trackID: trackID, path: path).value
        XCTAssertEqual(vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.count, 1)

        let undone = await engine.undo()
        XCTAssertTrue(undone)

        let latest = await engine.snapshot(ifNewerThan: nil)
        let fresh = try XCTUnwrap(latest)
        XCTAssertTrue(
            fresh.tracks.first(where: { $0.id == trackID })?.devices.isEmpty ?? false,
            """
            one undo left an instrument behind. If the device survived while its zone \
            did not, the project no longer compiles at all — the engine refuses a \
            sampler with no zones by design.
            """)

        let redone = await engine.redo()
        XCTAssertTrue(redone)
        let backLatest = await engine.snapshot(ifNewerThan: nil)
        let back = try XCTUnwrap(backLatest)
        let device = try XCTUnwrap(back.tracks.first(where: { $0.id == trackID })?.devices.first)
        XCTAssertEqual(device.zones.count, 1, "redo brought the instrument back without its sound")
    }

    /// Changing a pad's sound must be ONE step, and must never leave two
    /// sounds on one key even for an instant.
    func testReplacingAPadIsOneUndoStepAndOneSoundPerKey() async throws {
        let (engine, vm, trackID) = try await makeSession()
        let first = try writeTone(named: "First.wav", hz: 220)
        let second = try writeTone(named: "Second.wav", hz: 330)
        await vm.loadDrumRack(trackID: trackID, paths: [first]).value
        let device = try XCTUnwrap(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        let zone = try XCTUnwrap(device.zones.first)

        await vm.loadDrumPad(trackID: trackID, deviceID: device.id, key: 36,
                             path: second, replacing: zone.id).value

        var now = try XCTUnwrap(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        XCTAssertEqual(now.zones.count, 1, "key 36 ended up carrying \(now.zones.count) sounds")
        XCTAssertEqual(vm.soundName(now.zones[0].sourceID), "Second.wav")

        let undone = await engine.undo()
        XCTAssertTrue(undone)
        let backLatest = await engine.snapshot(ifNewerThan: nil)
        let back = try XCTUnwrap(backLatest)
        now = try XCTUnwrap(back.tracks.first(where: { $0.id == trackID })?.devices.first)
        XCTAssertEqual(now.zones.count, 1)
        XCTAssertEqual(now.zones[0].sourceID, zone.sourceID,
                       "one undo did not put the original sound back")
    }
}
#endif
