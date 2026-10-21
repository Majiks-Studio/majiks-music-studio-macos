import Testing
import Foundation
import Combine
@testable import MajiksMusicStudio

// The two shipped-3.4.3 defects this lane closes, tested against the journal:
//
// 1. Tracks / instruments / clips could not be deleted from the GUI. The new
//    surfaces (track-header context menu, timeline clip context menu) drive
//    StudioViewModel.deleteTrack / removeInstrument / deleteSelection, and the
//    assertions here are the brief's own: one GESTURE emits one journaled undo
//    unit (a txn bracket when several commands are needed), undo truthfully
//    restores what was deleted, and a refusal surfaces the engine's message
//    instead of being swallowed.
//
// 2. The on-screen keyboard read as "removed" when it was merely hidden. The
//    auto-show rule lives in StudioKeyboardController where it is drivable
//    without SwiftUI: a fresh hardware noteOn while hidden shows the pane;
//    a manual hide disarms auto-show for the rest of the session; nothing
//    ever auto-hides.

// MARK: - Helpers

@MainActor
private func adoptedViewModel(_ engine: StudioMockEngine) async throws -> StudioViewModel {
    let vm = StudioViewModel(engine: engine)
    vm.startPolling()
    for _ in 0..<200 where vm.snapshot == nil {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    // Freeze the poll so assertions never race it; the delete tasks adopt
    // fresh snapshots themselves (adoptFresh) when they complete.
    vm.stopPolling()
    try #require(vm.snapshot != nil, "the view model never adopted a snapshot")
    return vm
}

/// Re-adopt after driving the engine directly. The suites freeze the poll so
/// assertions cannot race it, so state set up through the engine afterwards has
/// to be pulled in deliberately.
@MainActor
private func resync(_ vm: StudioViewModel, _ engine: StudioMockEngine) async throws {
    let target = await engine.snapshot(ifNewerThan: nil)?.revision ?? 0
    vm.startPolling()
    for _ in 0..<200 where (vm.snapshot?.revision ?? 0) < target {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    vm.stopPolling()
    try #require((vm.snapshot?.revision ?? 0) >= target,
                 "the view model never caught up with the engine")
}

/// The catalog names journaled AFTER a marker index (what the gesture emitted).
private func journaledNames(_ engine: StudioMockEngine, after mark: Int) async -> [String] {
    await engine.journal.dropFirst(mark).map(\.catalogName)
}

private func noteOn(seq: Int, pitch: Int = 60) -> StudioMidiLastEvent {
    StudioMidiLastEvent(seq: seq, port: "Test Keys", type: "noteOn", channel: 0, number: pitch, value: 100)
}

/// Collects EVERY toast posted while it lives. ToastManager is a shared
/// singleton and the suites run in parallel, so reading `currentToast` after
/// an await races other tests' toasts; collecting each @Published change
/// synchronously cannot lose the one this test caused.
@MainActor
private final class ToastCollector {
    private(set) var seen: [ToastMessage] = []
    private var cancellable: AnyCancellable?
    init() {
        cancellable = ToastManager.shared.$currentToast.sink { [weak self] toast in
            if let toast { self?.seen.append(toast) }
        }
    }
    func contains(_ fragment: String, style: ToastStyle) -> Bool {
        seen.contains { $0.message.contains(fragment) && $0.style == style }
    }
}

// MARK: - Delete Track

@Suite("Delete Track — one gesture, one undo unit")
struct StudioDeleteTrackTests {

    @Test("a populated track deletes as one txn bracket with exactly one track.remove")
    @MainActor
    func populatedTrackDeletesAsOneBracket() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let track = try #require(vm.snapshot?.tracks.first(where: { !$0.clips.isEmpty }))
        let clipCount = track.clips.count
        let mark = await engine.journal.count

        await vm.deleteTrack(track.id)?.value

        let names = await journaledNames(engine, after: mark)
        #expect(names.first == "txn.begin", "the gesture opens a bracket")
        #expect(names.last == "txn.commit", "the gesture closes the bracket")
        #expect(names.filter { $0 == "track.remove" }.count == 1,
                "Delete Track emitted exactly one track.remove")
        #expect(names.filter { $0 == "clip.remove" }.count == clipCount,
                "every clip on the track was removed through the bus, not poked")
        #expect(vm.snapshot?.tracks.contains(where: { $0.id == track.id }) == false,
                "the track is gone from the adopted snapshot")
    }

    @Test("one undo restores the track — name, kind, index, clips and instrument")
    @MainActor
    func oneUndoRestoresEverything() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        // Build a track that HAS an instrument (the mock's device registry),
        // plus a clip, so the restore has all three kinds of thing to bring back.
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Synth Lead", index: 0))
        _ = await engine.send(.catalog(name: "device.add", params: [
            "trackId": trackID.uuidString, "deviceId": "inst_test", "kind": "synth"]))
        _ = await engine.importAudio(path: "/tmp/lead.wav", trackID: trackID, startTicks: 0)
        vm.startPolling()
        for _ in 0..<100 where vm.snapshot?.tracks.first(where: { $0.id == trackID })?.clips.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        vm.stopPolling()
        let before = try #require(vm.snapshot?.tracks.first(where: { $0.id == trackID }))
        let beforeIndex = try #require(vm.snapshot?.tracks.firstIndex(where: { $0.id == trackID }))
        #expect(before.devices.map(\.id) == ["inst_test"])

        await vm.deleteTrack(trackID)?.value
        #expect(vm.snapshot?.tracks.contains(where: { $0.id == trackID }) == false)

        let undone = await engine.undo()
        #expect(undone, "there was exactly one unit to undo")
        let after = try #require(await engine.snapshot(ifNewerThan: nil))
        let restored = try #require(after.tracks.first(where: { $0.id == trackID }),
                                    "undo brought the track back")
        #expect(after.tracks.firstIndex(where: { $0.id == trackID }) == beforeIndex,
                "restored at its old position")
        #expect(restored.name == before.name)
        #expect(restored.kind == before.kind)
        #expect(restored.devices == before.devices, "the instrument came back with it")
        #expect(restored.clips.map(\.id) == before.clips.map(\.id), "the clips came back with it")

        // And a second undo does NOT peel off more of the same gesture.
        let stillTrack = await engine.undo()
        let again = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(again.tracks.contains(where: { $0.id == trackID }) || !stillTrack,
                "the delete was ONE unit — no partial re-deletion on further undo")
    }

    @Test("redo re-applies the whole gesture")
    @MainActor
    func redoReapplies() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let track = try #require(vm.snapshot?.tracks.first(where: { !$0.clips.isEmpty }))

        await vm.deleteTrack(track.id)?.value
        _ = await engine.undo()
        _ = await engine.redo()
        let after = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(!after.tracks.contains(where: { $0.id == track.id }),
                "redo removed the track (and its clips) again")
    }

    @Test("an empty track deletes as one bare track.remove — no bracket needed")
    @MainActor
    func emptyTrackNeedsNoBracket() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Empty", index: 99))
        vm.startPolling()
        for _ in 0..<100 where vm.snapshot?.tracks.contains(where: { $0.id == trackID }) != true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        vm.stopPolling()
        let mark = await engine.journal.count

        await vm.deleteTrack(trackID)?.value

        let names = await journaledNames(engine, after: mark)
        #expect(names == ["track.remove"], "one command, no txn markers")
    }

    @Test("selection and take-lane state stop pointing at the dead track")
    @MainActor
    func aftermathClearsSelection() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let track = try #require(vm.snapshot?.tracks.first(where: { !$0.clips.isEmpty }))
        vm.selection.clipIDs = Set(track.clips.map(\.id))
        vm.expandedTakeLanes.insert(track.id)
        vm.visibleAutomationLanes.insert(StudioAutoLaneKey(trackID: track.id, target: .volume))

        await vm.deleteTrack(track.id)?.value

        #expect(vm.selection.clipIDs.isDisjoint(with: track.clips.map(\.id)),
                "no deleted clip is still selected")
        #expect(!vm.expandedTakeLanes.contains(track.id))
        #expect(!vm.visibleAutomationLanes.contains(where: { $0.trackID == track.id }))
    }

    @Test("a refusal mid-gesture rolls back and surfaces the engine's message")
    @MainActor
    func refusalRollsBackAndSurfaces() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let track = try #require(vm.snapshot?.tracks.first(where: { $0.clips.count >= 2 }))
        // Yank the SECOND clip out from under the view model (its snapshot is
        // frozen, so it will still try to remove it): the first clip.remove
        // applies, the second refuses, and the gesture must roll the first
        // back rather than leave a half-deleted track.
        let firstClip = track.clips[0]
        let staleClip = track.clips[1]
        _ = await engine.send(.clipRemove(clipID: staleClip.id))
        let toasts = ToastCollector()

        await vm.deleteTrack(track.id)?.value

        let after = try #require(await engine.snapshot(ifNewerThan: nil))
        let survivor = try #require(after.tracks.first(where: { $0.id == track.id }),
                                    "the track was NOT deleted")
        #expect(survivor.clips.contains(where: { $0.id == firstClip.id }),
                "the clip removed before the refusal was rolled back")
        #expect(toasts.contains("clip.remove", style: .warning),
                "the refusal was surfaced with the engine's own message (it names the command)")
    }

    @Test("a refusal before anything applied does not undo the previous gesture")
    @MainActor
    func earlyRefusalLeavesHistoryAlone() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let track = try #require(vm.snapshot?.tracks.first(where: { $0.clips.count == 1 })
                                 ?? vm.snapshot?.tracks.first(where: { !$0.clips.isEmpty }))
        // The user's previous gesture: a mute, one undo unit.
        _ = await engine.send(.trackMute(trackID: track.id, muted: !track.muted))
        // Yank the FIRST clip so the gesture's first command refuses with
        // nothing applied yet.
        _ = await engine.send(.clipRemove(clipID: track.clips[0].id))

        await vm.deleteTrack(track.id)?.value

        let after = try #require(await engine.snapshot(ifNewerThan: nil))
        let survivor = try #require(after.tracks.first(where: { $0.id == track.id }))
        #expect(survivor.muted == !track.muted,
                "the earlier mute unit was NOT undone by the failed delete's cleanup")
    }
}

// MARK: - Remove Instrument

@Suite("Remove Instrument")
struct StudioRemoveInstrumentTests {

    @Test("one journaled device.remove; undo restores the device")
    @MainActor
    func removeAndUndoRestore() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Instrument 1", index: 0))
        _ = await engine.send(.catalog(name: "device.add", params: [
            "trackId": trackID.uuidString, "deviceId": "inst_a", "kind": "synth"]))
        let mark = await engine.journal.count

        await vm.removeInstrument(trackID: trackID, deviceID: "inst_a").value

        let names = await journaledNames(engine, after: mark)
        #expect(names == ["device.remove"], "exactly one journaled command")
        var snap = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(snap.tracks.first(where: { $0.id == trackID })?.devices.isEmpty == true)

        _ = await engine.undo()
        snap = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(snap.tracks.first(where: { $0.id == trackID })?.devices.map(\.id) == ["inst_a"],
                "undo restored the instrument")
    }

    @Test("a refused device.remove surfaces the engine's message")
    @MainActor
    func refusalSurfaces() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let track = try #require(vm.snapshot?.tracks.first)
        let toasts = ToastCollector()

        await vm.removeInstrument(trackID: track.id, deviceID: "no_such_device").value

        #expect(toasts.contains("device.remove", style: .warning),
                "the engine's message, not a euphemism")
    }
}

// MARK: - Delete clips (selection)

@Suite("Delete clips — the selection path the context menu and Delete key share")
struct StudioDeleteSelectionTests {

    @Test("several selected clips delete as one bracket and one undo restores them all")
    @MainActor
    func multiClipDeleteIsOneUnit() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let track = try #require(vm.snapshot?.tracks.first(where: { $0.clips.count >= 2 }))
        let doomed = Array(track.clips.prefix(2))
        vm.selection.clipIDs = Set(doomed.map(\.id))
        let mark = await engine.journal.count

        await vm.deleteSelection()?.value

        let names = await journaledNames(engine, after: mark)
        #expect(names.first == "txn.begin" && names.last == "txn.commit",
                "several clips ride one bracket")
        #expect(names.filter { $0 == "clip.remove" }.count == 2)
        #expect(vm.selection.clipIDs.isEmpty, "selection cleared on success")

        _ = await engine.undo()
        let snap = try #require(await engine.snapshot(ifNewerThan: nil))
        let restored = try #require(snap.tracks.first(where: { $0.id == track.id }))
        for clip in doomed {
            #expect(restored.clips.contains(where: { $0.id == clip.id }),
                    "one undo brought back every clip of the gesture")
        }
    }

    @Test("a single clip deletes as one bare clip.remove")
    @MainActor
    func singleClipNeedsNoBracket() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let track = try #require(vm.snapshot?.tracks.first(where: { !$0.clips.isEmpty }))
        let clip = track.clips[0]
        vm.selection.clipIDs = [clip.id]
        let mark = await engine.journal.count

        await vm.deleteSelection()?.value

        let names = await journaledNames(engine, after: mark)
        #expect(names == ["clip.remove"], "one command, no txn markers")
        #expect(vm.selection.clipIDs.isEmpty)
    }
}

// MARK: - Mock txn semantics (the bracket the gestures rely on)

@Suite("Preview-engine txn bracket")
struct StudioMockTxnTests {

    @Test("brackets do not nest, and commit requires the matching id")
    func bracketRules() async {
        let engine = StudioMockEngine()
        let begin = await engine.send(.catalog(name: "txn.begin", params: ["txnId": "a"]))
        #expect(begin.ok)
        let nested = await engine.send(.catalog(name: "txn.begin", params: ["txnId": "b"]))
        #expect(!nested.ok, "v1 transactions do not nest")
        let wrong = await engine.send(.catalog(name: "txn.commit", params: ["txnId": "b"]))
        #expect(!wrong.ok, "commit must name the open bracket")
        let commit = await engine.send(.catalog(name: "txn.commit", params: ["txnId": "a"]))
        #expect(commit.ok)
    }

    @Test("an empty committed bracket pushes no undo unit")
    func emptyBracketPushesNothing() async {
        let engine = StudioMockEngine()
        let before = await engine.snapshot(ifNewerThan: nil)!.tracks[0]
        _ = await engine.send(.mixGain(trackID: before.id, gainDB: before.volumeDB - 9))   // the previous gesture
        _ = await engine.send(.catalog(name: "txn.begin", params: ["txnId": "e"]))
        _ = await engine.send(.catalog(name: "txn.commit", params: ["txnId": "e"]))
        _ = await engine.undo()
        let snap = await engine.snapshot(ifNewerThan: nil)!
        #expect(abs(snap.tracks[0].volumeDB - before.volumeDB) < 1e-9,
                "undo skipped the empty bracket and reversed the gain move")
    }
}

// MARK: - Keyboard discoverability (defect 2)

@Suite("On-screen keyboard auto-show")
@MainActor
struct StudioKeyboardAutoShowTests {

    @Test("a hardware noteOn while hidden shows the pane")
    func hardwareNoteShows() {
        let c = StudioKeyboardController()
        c.seedHardwareEvent(nil)             // fresh engine: no event yet
        #expect(!c.isShown)
        c.observeHardwareEvent(noteOn(seq: 1))
        #expect(c.isShown, "hardware plays -> keyboard appears")
    }

    @Test("a stale event observed again does not trigger")
    func staleEventDoesNotTrigger() {
        let c = StudioKeyboardController()
        c.seedHardwareEvent(noteOn(seq: 5))  // happened before the tab appeared
        c.observeHardwareEvent(noteOn(seq: 5))
        #expect(!c.isShown, "only a FRESH event counts")
        c.observeHardwareEvent(noteOn(seq: 6))
        #expect(c.isShown)
    }

    @Test("knob turns and CCs never show it")
    func controlChangesDoNotTrigger() {
        let c = StudioKeyboardController()
        c.seedHardwareEvent(nil)
        c.observeHardwareEvent(StudioMidiLastEvent(
            seq: 1, port: "Test Keys", type: "cc", channel: 0, number: 74, value: 90))
        #expect(!c.isShown, "a CC is not someone playing the keys")
    }

    @Test("after a manual hide, hardware notes stop auto-showing for the session")
    func manualHideWins() {
        let c = StudioKeyboardController()
        c.seedHardwareEvent(nil)
        c.observeHardwareEvent(noteOn(seq: 1))
        #expect(c.isShown)
        c.toggleShownByUser()                 // the user says: away with it
        #expect(!c.isShown)
        #expect(c.manuallyHiddenThisSession)
        c.observeHardwareEvent(noteOn(seq: 2))
        c.observeHardwareEvent(noteOn(seq: 3))
        #expect(!c.isShown, "the app does not fight a choice it just watched the user make")
        c.toggleShownByUser()                 // the toggle itself always works
        #expect(c.isShown)
    }

    @Test("nothing here ever auto-hides")
    func neverAutoHides() {
        let c = StudioKeyboardController()
        c.isShown = true
        c.observeHardwareEvent(noteOn(seq: 1))
        c.observeHardwareEvent(nil)
        c.observeHardwareEvent(StudioMidiLastEvent(
            seq: 2, port: "Test Keys", type: "noteOff", channel: 0, number: 60, value: 0))
        #expect(c.isShown, "auto-show is one-directional")
    }

    @Test("showing via the toggle does not count as a manual hide")
    func manualShowDoesNotDisarm() {
        let c = StudioKeyboardController()
        c.toggleShownByUser()                 // show
        c.toggleShownByUser()                 // hide -> disarms
        let c2 = StudioKeyboardController()
        c2.toggleShownByUser()                // show only
        #expect(!c2.manuallyHiddenThisSession)
    }

    @Test("a manual hide releases every held key (no stranded note-ons)")
    func manualHideReleases() {
        let c = StudioKeyboardController()
        var events: [(UInt8, StudioNoteAuditionGate)] = []
        c.onNote = { pitch, _, gate in events.append((pitch, gate)) }
        c.isShown = true
        c.press(60, velocity: 100)
        c.toggleShownByUser()
        #expect(c.held.isEmpty)
        #expect(events.contains(where: { $0.0 == 60 && $0.1 == .off }),
                "the matching note-off went out")
    }
}

// MARK: - Piano roll aftermath

@Suite("Piano roll closes when its clip dies")
@MainActor
struct StudioPianoRollCloseTests {

    @Test("close() drops the dead session instead of rendering a ghost")
    func closeDropsSession() async {
        let clipID = UUID()
        let clip = StudioMidiClipSnapshot(
            id: clipID, trackID: UUID(), name: "Doomed",
            startTicks: 0, lengthTicks: 3840,
            notes: [], kind: .other)
        let engine = StudioMockNoteEngine(
            clip: clip, barGrid: StudioBarGrid(timeSignature: .fourFour), tempoMap: .constant(bpm: 120))
        let controller = StudioPianoRollController(engine: engine)
        await controller.attach(clipID: clipID)
        controller.isShown = true
        #expect(controller.clip != nil)

        controller.close()

        #expect(controller.clip == nil, "no ghost clip remains")
        #expect(!controller.isShown, "the pane closed")
        #expect(controller.selection.isEmpty)
    }
}

// MARK: - Instrument visibility (the "it didn't delete" finding)
//
// Observed on the shipped 3.4.4: Remove Instrument WORKED — it journaled, the
// menu afterwards offered only Delete Track — and the user reported that the
// instrument had not deleted, because nothing he could see had changed. The
// track header said nothing about instruments in either state, and the one
// signal that did exist (a toast) was drawn by a single whole-window overlay
// pinned to the top centre of the app window, over the tab strip, roughly a
// window-diagonal away from the track header the gesture happened on, for
// about 2.4 s at full opacity.
//
// The three things below are what a person can actually see, so they are what
// is asserted: the chip's presence tracks the DEVICE (not a constant), adding
// one goes through the journaled bus with a real inverse, and the toast is
// routed to the surface that is on screen and lives long enough to read.

@Suite("Track header instrument state")
@MainActor
struct StudioInstrumentChipTests {

    /// The chip's text as PRODUCTION computes it — `StudioTrackHeaderRow`
    /// renders exactly this property. Re-deriving it here would make every
    /// assertion below a test of the test.
    private func chipLabel(_ track: StudioTrackSnapshot) -> String? {
        track.instrumentChipLabel
    }

    @Test("the chip names the engine's own instrument kind")
    func chipNamesTheKind() {
        #expect(StudioDeviceSnapshot(id: "d", kind: "synth").instrumentLabel == "Synth")
        #expect(StudioDeviceSnapshot(id: "d", kind: "sampler").instrumentLabel == "Sampler")
        #expect(StudioDeviceSnapshot(id: "d", kind: "drum").instrumentLabel == "Drums")
        // An unknown kind is shown, not laundered into a generic word: a chip
        // that says "Instrument" for something the engine calls something else
        // cannot be matched against the menu item that removes it.
        #expect(StudioDeviceSnapshot(id: "d", kind: "wavetable").instrumentLabel == "Wavetable")
    }

    @Test("removing the instrument makes the chip disappear — the gesture has a visible effect")
    func chipDisappearsOnRemoval() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Keys", index: 0))
        _ = await engine.send(.deviceAdd(trackID: trackID, deviceID: "inst_a", kind: "synth"))
        try await resync(vm, engine)
        let before = try #require(vm.snapshot?.tracks.first(where: { $0.id == trackID }))
        #expect(chipLabel(before) == "Synth", "a track with a synth shows a Synth chip")

        await vm.removeInstrument(trackID: trackID, deviceID: "inst_a").value

        let after = try #require(vm.snapshot?.tracks.first(where: { $0.id == trackID }))
        #expect(chipLabel(after) == nil, "the chip is GONE — the removal is visible")
    }

    @Test("the chip is bound to the devices, not to a constant")
    func chipTracksTheDevice() async throws {
        // The mutation this pins: a chip wired to `true` (or to "always show
        // Synth") passes the removal test only if the removal test reads the
        // chip and not the raw array. Two tracks, one with and one without,
        // in ONE snapshot: a constant cannot satisfy both.
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let withInstrument = UUID(), without = UUID()
        _ = await engine.send(.trackAdd(trackID: withInstrument.uuidString, name: "Has", index: 0))
        _ = await engine.send(.trackAdd(trackID: without.uuidString, name: "Hasn't", index: 1))
        _ = await engine.send(.deviceAdd(trackID: withInstrument, deviceID: "inst_a", kind: "synth"))
        try await resync(vm, engine)

        let a = try #require(vm.snapshot?.tracks.first(where: { $0.id == withInstrument }))
        let b = try #require(vm.snapshot?.tracks.first(where: { $0.id == without }))
        #expect(chipLabel(a) == "Synth")
        #expect(chipLabel(b) == nil)
    }

    @Test("a second instrument is counted, not hidden")
    func chipCountsExtras() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Stack", index: 0))
        _ = await engine.send(.deviceAdd(trackID: trackID, deviceID: "inst_a", kind: "synth"))
        _ = await engine.send(.deviceAdd(trackID: trackID, deviceID: "inst_b", kind: "sampler"))
        try await resync(vm, engine)
        let track = try #require(vm.snapshot?.tracks.first(where: { $0.id == trackID }))
        #expect(chipLabel(track) == "Synth +1",
                "a header that showed only the first would hide the one you cannot remove from it")
    }
}

@Suite("Add Instrument — the way back")
@MainActor
struct StudioAddInstrumentTests {

    @Test("adding emits exactly one journaled device.add and the device appears")
    func addIsOneJournaledCommand() async throws {
        // The mutation this pins: an affordance wired to nothing at all. It is
        // asserted on the JOURNAL, so a button that mutated a local @State
        // (or did nothing) fails here even though the view would "look right".
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Empty", index: 0))
        try await resync(vm, engine)
        #expect(vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.isEmpty == true)
        let mark = await engine.journal.count

        await vm.addInstrument(trackID: trackID)?.value

        let names = await journaledNames(engine, after: mark)
        #expect(names == ["device.add"], "one command, no txn markers: got \(names)")
        let track = try #require(vm.snapshot?.tracks.first(where: { $0.id == trackID }))
        #expect(track.devices.count == 1)
        #expect(track.devices.first?.kind == "synth",
                "Synth only — a sampler with no sample source is a hard engine refusal by design")
    }

    @Test("one undo takes the added instrument back")
    func addUndoes() async throws {
        // Asserted through the mock's REAL inverse (deviceAdd -> deviceRemove),
        // so an inverse that returned [] would leave the device in place here.
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Empty", index: 0))
        try await resync(vm, engine)

        await vm.addInstrument(trackID: trackID)?.value
        #expect(vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.count == 1)

        let undone = await engine.undo()
        #expect(undone, "there was exactly one unit to undo")
        let snap = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(snap.tracks.first(where: { $0.id == trackID })?.devices.isEmpty == true,
                "one undo removed the instrument that one gesture added")
    }

    @Test("remove then add is a round trip the user can drive from the header alone")
    func removeThenAddRoundTrips() async throws {
        // AARON'S FLOW, on the GUI side of the seam: the instrument goes away
        // and he can put one back WITHOUT knowing about the piano roll, the
        // Instrument button in the toolbar (which makes a whole new track), or
        // Cmd-Z.
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Keys", index: 0))
        _ = await engine.send(.deviceAdd(trackID: trackID, deviceID: "inst_a", kind: "synth"))
        try await resync(vm, engine)
        let trackCountBefore = vm.snapshot?.tracks.count ?? 0

        await vm.removeInstrument(trackID: trackID, deviceID: "inst_a").value
        #expect(vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.isEmpty == true)

        await vm.addInstrument(trackID: trackID)?.value

        let track = try #require(vm.snapshot?.tracks.first(where: { $0.id == trackID }))
        #expect(track.devices.count == 1, "the track plays again")
        #expect(vm.snapshot?.tracks.count == trackCountBefore,
                "and it went back on THIS track — no stray second track was created")
    }

    @Test("adding to a track that already has one does nothing")
    func addIsRefusedWhenOccupied() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Keys", index: 0))
        _ = await engine.send(.deviceAdd(trackID: trackID, deviceID: "inst_a", kind: "synth"))
        try await resync(vm, engine)
        let mark = await engine.journal.count

        let task = vm.addInstrument(trackID: trackID)

        #expect(task == nil, "the affordance is not offered there, so a stale click is a no-op")
        let names = await journaledNames(engine, after: mark)
        #expect(names.isEmpty, "nothing was journaled: got \(names)")
    }
}

@Suite("Toast reliability")
@MainActor
struct StudioToastRoutingTests {

    @Test("exactly one surface draws a toast")
    func oneSurfaceDraws() {
        // Two live presenters would draw the same toast twice, in two places.
        for active in [ToastSurface.app, .studio] {
            let drawn = [ToastSurface.app, .studio]
                .filter { ToastManager.shouldRender(surface: $0, active: active) }
            #expect(drawn == [active], "active \(active) is drawn by itself alone")
        }
    }

    @Test("the Studio claims presentation and hands it straight back")
    func claimAndRelease() {
        let manager = ToastManager.shared
        manager.releaseSurface(.studio)          // known state
        #expect(manager.activeSurface == .app)
        manager.claimSurface(.studio)
        #expect(manager.activeSurface == .studio,
                "a Studio gesture's result is drawn in the Studio's own frame")
        manager.releaseSurface(.studio)
        #expect(manager.activeSurface == .app, "leaving hands presentation back")
    }

    @Test("a surface that no longer holds the claim cannot yank it back")
    func staleReleaseIsIgnored() {
        let manager = ToastManager.shared
        manager.claimSurface(.app)
        manager.releaseSurface(.studio)   // the Studio never held it
        #expect(manager.activeSurface == .app)
        manager.claimSurface(.studio)
        manager.claimSurface(.studio)     // idempotent
        #expect(manager.activeSurface == .studio)
        manager.releaseSurface(.studio)
    }

    @Test("a result the user has to act on stays up long enough to read")
    func actionableToastsAreLonger() {
        #expect(ToastDuration.actionable >= 4,
                "under ~4 s a person has to notice, cross the screen with their eyes, and read")
        #expect(ToastDuration.actionable > ToastDuration.standard)
    }

    @Test("removing an instrument posts an actionable toast naming the way back")
    func removalToastIsActionable() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Keys", index: 0))
        _ = await engine.send(.deviceAdd(trackID: trackID, deviceID: "inst_a", kind: "synth"))
        try await resync(vm, engine)
        let toasts = ToastCollector()

        await vm.removeInstrument(trackID: trackID, deviceID: "inst_a").value

        let toast = try #require(toasts.seen.last(where: { $0.message.contains("Removed the") }),
                                 "the removal said something")
        #expect(toast.seconds >= ToastDuration.actionable,
                "a destructive result gets the longer read time, not the 3 s default")
        #expect(toast.message.contains("+ Instrument"),
                "and it names the affordance that puts one back, not just Cmd-Z")
    }
}
