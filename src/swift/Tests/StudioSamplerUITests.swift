import Testing
import Foundation
import Combine
@testable import MajiksMusicStudio

// THE REACHABILITY LANE, tested from the gesture end.
//
// The sampler and the drum rack were finished, RT-safe and covered by ~35
// engine tests, and completely unusable: nothing in the app could put a sound
// into one. So the assertions that matter here are not "the picker appeared".
// They are:
//
//   • the gesture reaches the BUS — the exact journaled commands, in one txn
//     bracket, so one gesture is one Cmd-Z;
//   • the resulting device carries the ZONE the engine needs to compile;
//   • a refusal surfaces the ENGINE's sentence rather than being swallowed.
//
// The audio itself is proven where audio can be proven: `engine/agent-surface/
// tests/sampler_ui_binding.rs` renders the master and measures the frequency.
// The preview engine here reads no audio and never claims to.

// MARK: - Helpers

@MainActor
private func adoptedViewModel(_ engine: StudioMockEngine) async throws -> StudioViewModel {
    let vm = StudioViewModel(engine: engine)
    vm.startPolling()
    for _ in 0..<200 where vm.snapshot == nil {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    vm.stopPolling()
    try #require(vm.snapshot != nil, "the view model never adopted a snapshot")
    return vm
}

/// A track with no instrument on it, which is what every load gesture starts
/// from. The synthetic project's tracks carry clips, so this makes a fresh one.
@MainActor
private func emptyTrack(_ engine: StudioMockEngine, _ vm: StudioViewModel) async throws -> UUID {
    let trackID = UUID()
    _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Sampler", index: 0))
    vm.startPolling()
    for _ in 0..<200 where vm.snapshot?.tracks.contains(where: { $0.id == trackID }) != true {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    vm.stopPolling()
    try #require(vm.snapshot?.tracks.contains(where: { $0.id == trackID }) == true)
    return trackID
}

private func journaledNames(_ engine: StudioMockEngine, after mark: Int) async -> [String] {
    await engine.journal.dropFirst(mark).map(\.catalogName)
}

@MainActor
private final class ToastCollector {
    private(set) var seen: [ToastMessage] = []
    private var cancellable: AnyCancellable?
    init() {
        cancellable = ToastManager.shared.$currentToast.sink { [weak self] toast in
            if let toast { self?.seen.append(toast) }
        }
    }
    func contains(_ fragment: String) -> Bool {
        seen.contains { $0.message.contains(fragment) }
    }
}

private let kick = "/tmp/sampler-ui-tests/Kick 01.wav"
private let snare = "/tmp/sampler-ui-tests/Snare 02.wav"
private let pad = "/tmp/sampler-ui-tests/Pad C3.wav"

@Suite("Generated song — sampler front door")
struct StudioGeneratedSongSamplerTests {
    @Test("an all-audio generated song can gain a sampler track")
    @MainActor
    func generatedSongGainsSampler() async throws {
        let engine = StudioMockEngine(project: .standard)
        let vm = try await adoptedViewModel(engine)
        #expect(vm.snapshot?.tracks.allSatisfy { $0.role == .audio } == true,
                "the generated-song fixture must reproduce the all-audio starting state")

        await vm.addSamplerTrack(path: pad).value

        let sampler = try #require(
            vm.snapshot?.tracks.last(where: { $0.devices.contains(where: { $0.kind == "sampler" }) }),
            "the + Instrument sampler choice did not create a new track")
        #expect(sampler.role == .instrument)
        #expect(sampler.devices.first?.zones.count == 1)
        #expect(sampler.devices.first?.zones.first?.isFullRange == true)
    }

    @Test("one undo removes the new sampler track and its device together")
    @MainActor
    func undoRemovesTrackAndDeviceTogether() async throws {
        let engine = StudioMockEngine(project: .standard)
        let vm = try await adoptedViewModel(engine)
        let initialCount = try #require(vm.snapshot?.tracks.count)

        await vm.addSamplerTrack(path: pad).value
        let added = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(added.tracks.count == initialCount + 1)
        #expect(added.tracks.last?.devices.first?.kind == "sampler")

        #expect(await engine.undo(), "the complete add gesture must be one undo unit")
        let undone = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(undone.tracks.count == initialCount)
        #expect(undone.tracks.contains { $0.devices.contains { $0.kind == "sampler" } } == false)
    }

    @Test("a refused first bind leaves no orphan drum-rack track")
    @MainActor
    func failedBindRollsBackTrack() async throws {
        let engine = StudioMockEngine(project: .standard)
        let vm = try await adoptedViewModel(engine)
        let initialCount = try #require(vm.snapshot?.tracks.count)

        await vm.addDrumRackTrack(paths: []).value

        let after = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(after.tracks.count == initialCount,
                "a failed first bind must not strand the track.add")
        #expect(after.tracks.contains { $0.name == "Drum Rack" } == false)
    }
}

// MARK: - Loading one sound across the keyboard

@Suite("Sampler — load one sound across the keys")
struct StudioLoadSamplerTests {

    @Test("the gesture journals device.add + device.zone.add inside one bracket")
    @MainActor
    func oneGestureOneBracket() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)
        let mark = await engine.journal.count

        await vm.loadSamplerSound(trackID: trackID, path: pad).value

        let names = await journaledNames(engine, after: mark)
        #expect(names == ["txn.begin", "device.add", "device.zone.add", "txn.commit"],
                "the load gesture must be exactly these commands, in one bracket: \(names)")
    }

    @Test("the device that lands is a sampler with a zone covering the whole keyboard")
    @MainActor
    func theZoneCoversEveryKey() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)

        await vm.loadSamplerSound(trackID: trackID, path: pad, rootPitch: 60).value

        let device = try #require(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first,
            "no instrument landed at all")
        #expect(device.kind == "sampler")
        #expect(device.playsSamples)
        let zone = try #require(device.zones.first, """
            the sampler landed with NO zone. The engine refuses to compile a zoneless \
            sampler by design, so this is not a cosmetic gap — the track would be dead.
            """)
        #expect(zone.isFullRange, "a load-one-sound gesture must answer every key")
        #expect(zone.rootPitch == 60)
        #expect(!zone.sourceID.isEmpty, "the zone names no asset, so it can resolve nothing")
    }

    @Test("the panel can name the file that was loaded")
    @MainActor
    func theBoundSoundHasAName() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)

        await vm.loadSamplerSound(trackID: trackID, path: pad).value

        let zone = try #require(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first?.zones.first)
        #expect(vm.soundName(zone.sourceID) == "Pad C3.wav",
                "a bound sound with no name shows a 64-character hash, which is unreadable")
    }

    @Test("one undo takes back the instrument AND its sound together")
    @MainActor
    func oneUndoTakesBackTheWholeThing() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)
        await vm.loadSamplerSound(trackID: trackID, path: pad).value
        #expect(vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.count == 1)

        _ = await engine.undo()
        let after = await engine.snapshot(ifNewerThan: nil)
        #expect(after?.tracks.first(where: { $0.id == trackID })?.devices.isEmpty == true, """
            one undo left something behind. A sampler whose zone was undone but whose \
            device was not cannot compile at all, so a two-step undo is a broken project \
            between the presses.
            """)
    }

    @Test("the toast says how to play it and how to take it back")
    @MainActor
    func theToastTeaches() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)
        let toasts = ToastCollector()

        await vm.loadSamplerSound(trackID: trackID, path: pad).value

        #expect(toasts.contains("Pad C3.wav"), "the toast never names the sound that loaded")
        #expect(toasts.contains("Play any key"), "the toast never says what to do next")
        #expect(toasts.contains("Cmd-Z"), "the toast never says how to take it back")
    }
}

// MARK: - The drum rack

@Suite("Drum rack — a sound per pad")
struct StudioDrumRackTests {

    @Test("building a rack journals one device.add and one zone.add per pad, in one bracket")
    @MainActor
    func oneBracketForTheWholeKit() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)
        let mark = await engine.journal.count

        await vm.loadDrumRack(trackID: trackID, paths: [kick, snare]).value

        let names = await journaledNames(engine, after: mark)
        #expect(names == ["txn.begin", "device.add", "device.zone.add", "device.zone.add",
                          "txn.commit"], "got \(names)")
    }

    @Test("pads land one key each, starting at the General MIDI kick")
    @MainActor
    func padsAreOneKeyEachFromGM() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)

        await vm.loadDrumRack(trackID: trackID, paths: [kick, snare]).value

        let device = try #require(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        #expect(device.kind == "drum")
        #expect(device.zones.count == 2)
        #expect(device.zones.allSatisfy({ $0.isSingleKey }),
                "a drum pad covers exactly one key; the engine refuses any other shape")
        #expect(device.zones.map(\.loPitch) == [36, 37],
                "a new rack starts at the GM kick so a standard kit lands where a drummer expects")
    }

    @Test("more files than the rack holds is a partial success with the count said out loud")
    @MainActor
    func extraFilesAreDroppedNotRefused() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)
        let toasts = ToastCollector()
        let many = (0..<20).map { "/tmp/sampler-ui-tests/hat\($0).wav" }

        await vm.loadDrumRack(trackID: trackID, paths: many).value

        let device = try #require(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        #expect(device.zones.count == StudioDrumRack.padCount,
                "the rack holds sixteen; sending twenty would be refused outright, and a refusal for 'you picked a folder' is not something a person can act on")
        #expect(toasts.contains("4 files did not fit"),
                "dropping four files silently is the silent-degradation class this program keeps catching")
    }

    @Test("changing a pad's sound removes then adds, in one undo step, never two on one key")
    @MainActor
    func replacingAPadIsOneStep() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)
        await vm.loadDrumRack(trackID: trackID, paths: [kick]).value
        let device = try #require(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        let zone = try #require(device.zones.first)
        let mark = await engine.journal.count

        await vm.loadDrumPad(trackID: trackID, deviceID: device.id, key: 36,
                             path: snare, replacing: zone.id).value

        let names = await journaledNames(engine, after: mark)
        #expect(names == ["txn.begin", "device.zone.remove", "device.zone.add", "txn.commit"],
                "the remove must come first, or the key briefly holds two sounds: \(names)")
        let after = try #require(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        #expect(after.zones.count == 1, "key 36 ended up with \(after.zones.count) sounds on it")
        #expect(vm.soundName(after.zones[0].sourceID) == "Snare 02.wav")
    }

    @Test("clearing the last pad is refused with the remedy, and the pad survives")
    @MainActor
    func clearingTheLastPadIsRefused() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)
        await vm.loadDrumRack(trackID: trackID, paths: [kick]).value
        let device = try #require(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        let zone = try #require(device.zones.first)
        let toasts = ToastCollector()

        await vm.clearDrumPad(trackID: trackID, deviceID: device.id, zone: zone).value

        #expect(toasts.contains("remove the instrument instead"),
                "the refusal has to name the way out, or it is a dead end")
        let after = try #require(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        #expect(after.zones.count == 1, "a refused clear must not have emptied the rack")
    }

    @Test("a rack cannot be started on a track that already plays something")
    @MainActor
    func oneInstrumentPerTrack() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)
        await vm.loadSamplerSound(trackID: trackID, path: pad).value
        let toasts = ToastCollector()
        let mark = await engine.journal.count

        await vm.loadDrumRack(trackID: trackID, paths: [kick]).value

        #expect(toasts.contains("already plays"),
                "a second instrument on one track fails to COMPILE in the engine, so it has to be refused here rather than journaled")
        #expect(await journaledNames(engine, after: mark).isEmpty,
                "a refused gesture wrote to the journal")
    }
}

// MARK: - Retuning

@Suite("Sampler — the key the recording sounds at")
struct StudioSamplerRootKeyTests {

    @Test("changing the root key rebinds the same sound at the new root, in one step")
    @MainActor
    func rootKeyChangeIsOneStep() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)
        await vm.loadSamplerSound(trackID: trackID, path: pad, rootPitch: 60).value
        let device = try #require(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        let zone = try #require(device.zones.first)
        let mark = await engine.journal.count

        await vm.setZoneRootPitch(trackID: trackID, deviceID: device.id,
                                  zone: zone, rootPitch: 48)?.value

        let names = await journaledNames(engine, after: mark)
        #expect(names == ["txn.begin", "device.zone.remove", "device.zone.add", "txn.commit"],
                "there is no device.zone.set in the catalog on purpose: an edit is remove+add, which keeps the inverse exact. Got \(names)")
        let after = try #require(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first?.zones.first)
        #expect(after.rootPitch == 48)
        #expect(after.sourceID == zone.sourceID, "retuning must not change the sound")
        #expect(after.isFullRange, "retuning must not change the key range")
    }

    @Test("setting the root key it already has does nothing at all")
    @MainActor
    func aNoOpRetuneEmitsNothing() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = try await emptyTrack(engine, vm)
        await vm.loadSamplerSound(trackID: trackID, path: pad, rootPitch: 60).value
        let device = try #require(
            vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        let zone = try #require(device.zones.first)
        let mark = await engine.journal.count

        await vm.setZoneRootPitch(trackID: trackID, deviceID: device.id,
                                  zone: zone, rootPitch: 60)?.value

        #expect(await journaledNames(engine, after: mark).isEmpty,
                "a stepper that lands back where it started must not cost an undo step")
    }
}

// MARK: - The controls are actually wired to the gestures
//
// Every suite above drives the VIEW MODEL, which is the layer the tests can
// reach — SwiftUI views are not hosted here. That leaves one mutation
// unguarded and it is the most likely one of all: a control that looks right
// and calls nothing. This is exactly the defect the help layer was built for
// ("the feature shipped, was on screen, and was reported missing").
//
// So: a source scan, the same net `StudioHelpTests` uses for help ids. Delete
// the call behind the Sampler menu item and this fails BY NAME instead of
// every other test staying green.

@Suite("Sampler controls reach the bus")
struct StudioSamplerWiringTests {

    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // swift/
            .appendingPathComponent("Sources/Studio")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    @Test("the track header offers all three instruments, and the two sample ones pick a file")
    func headerOffersEveryInstrument() throws {
        let header = try Self.source("StudioTrackHeaderColumn.swift")
        // TWICE each, because there are deliberately TWO affordances: the
        // instrument-slot Menu, and the right-click menu — the chip is 9pt
        // tall, so on a 4K TV at couch distance the right-click is the one that
        // lands. Counting rather than merely `contains` is not pedantry: a
        // mutation that gutted the Menu item passed a `contains` check, because
        // the context-menu copy of the call was still in the file.
        for call in ["model.addInstrument(", "model.loadSamplerSound(", "model.loadDrumRack("] {
            let uses = header.components(separatedBy: call).count - 1
            #expect(uses >= 2, """
                \(call) appears \(uses) time(s) in the track header. Both affordances have \
                to send it — the instrument-slot menu AND the right-click menu — or one of \
                them is a control that does nothing.
                """)
        }
        #expect(header.contains("StudioSoundPicker.pickOne"),
                "the Sampler item must ask for a file: creating an instrument without a sound is a hard compile error in the engine")
        #expect(header.contains("StudioSoundPicker.pickMany"),
                "the Drum Rack item must ask for files")
        #expect(header.contains("model.openInstrumentPanel("),
                "nothing opens the instrument panel any more, so a loaded sound cannot be changed")
    }

    @Test("every pad and sampler control in the panel calls a gesture")
    func panelControlsAreWired() throws {
        let panel = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Studio/StudioInstrumentView.swift"),
            encoding: .utf8)
        for call in ["model.clearDrumPad(", "model.replaceSamplerSound(",
                     "model.setZoneRootPitch("] {
            #expect(panel.contains(call),
                    "the instrument panel no longer calls \(call) — that control sends nothing")
        }
        // Twice: clicking a pad, and dropping a file on one. Same reasoning as
        // the header — a `contains` check passes while one of the two is dead.
        let padLoads = panel.components(separatedBy: "model.loadDrumPad(").count - 1
        #expect(padLoads >= 2, """
            model.loadDrumPad( appears \(padLoads) time(s). Both ways onto a pad have to \
            send it — clicking the pad AND dropping a file on it.
            """)
        #expect(panel.contains(".onDrop(of: [.fileURL]"),
                "dropping a file on a pad was the fastest way to fill a kit and is gone")
    }

    @Test("the pad grid is a LazyVGrid and is nowhere near a horizontal ScrollView")
    func theGridDoesNotEatItsOwnClicks() throws {
        let panel = try Self.source("StudioInstrumentView.swift")
        #expect(panel.contains("LazyVGrid"))
        #expect(!panel.contains("ScrollView(.horizontal"), """
            a horizontal ScrollView on macOS silently swallows Button clicks — it cost this \
            product days on the settings tab strip, and a pad grid is exactly the shape that \
            tempts one.
            """)
    }
}

// MARK: - The rules the pad grid draws from

@Suite("Drum rack geometry")
struct StudioDrumRackMathTests {

    @Test("a rack is sixteen keys in a row")
    func sixteenInARow() {
        #expect(StudioDrumRack.padCount == 16)
        let keys = StudioDrumRack.keys(baseKey: 36)
        #expect(keys.count == 16)
        #expect(keys.first == 36)
        #expect(keys.last == 51, "the rack must be contiguous — the engine's slot is pitch - base")
    }

    @Test("a General MIDI kit fits and a two-octave spread does not")
    func fitsMirrorsTheEngineRule() {
        // 36..=49 is the bottom of a GM kit and is what the brief calls out.
        #expect(StudioDrumRack.fits(newKey: 49, existingKeys: [36]))
        #expect(!StudioDrumRack.fits(newKey: 52, existingKeys: [36]),
                "36 to 52 is seventeen keys, which build_drum_kit refuses rather than truncating")
        #expect(!StudioDrumRack.fits(newKey: 36, existingKeys: [36]),
                "two pads on one key is refused: the engine binds one pad per slot")
        #expect(!StudioDrumRack.fits(newKey: 128, existingKeys: []))
    }

    @Test("the base key is the lowest bound pad, matching build_drum_kit")
    func baseKeyIsTheLowestPad() {
        #expect(StudioDrumRack.baseKey(forBoundKeys: [40, 36, 38]) == 36)
        #expect(StudioDrumRack.baseKey(forBoundKeys: []) == StudioDrumRack.defaultBaseKey)
    }

    @Test("keys are named the way the piano roll names them")
    func pitchNamesAgreeWithTheRoll() {
        #expect(StudioPitchName.name(60) == StudioPitchName.label(60))
        #expect(StudioPitchName.name(36) == "C1")
        #expect(StudioPitchName.name(60) == "C3")
        #expect(StudioPitchName.name(-1) == "—")
    }
}
