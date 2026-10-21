import Testing
import Foundation
@testable import MajiksMusicStudio

// MIDI settings model round-trip (spec 6, 7.5). Exercises the preview engine's
// seeded fixture, the learn capture delay, and catalog dispatch.

@Suite("Studio MIDI model round-trip")
struct StudioMidiTests {

    private func snapshot(_ engine: StudioMockEngine) async -> StudioProjectSnapshot {
        await engine.snapshot(ifNewerThan: nil)!
    }

    // MARK: - Fixture

    @Test("seeded fixture has 4 maps, 9 bindings, 1 port")
    func seededFixture() async {
        let engine = StudioMockEngine()
        let midi = (await snapshot(engine)).midi
        #expect(midi != nil)
        #expect(midi?.ports.count == 1)
        #expect(midi?.ports[0].name == "SX-KC211 Keyboard (USB MIDI Interface)")
        #expect(midi?.ports[0].connected == true)
        #expect(midi?.maps.count == 4)
        #expect(midi?.maps[1].key == "sxkc211")
        #expect(midi?.activeBindings.count == 9)   // 8 command/builtin + 1 sterling
    }

    @Test("fixture binding play-stop is controlChange ch0 #20 → transport.togglePlay")
    func playStopBinding() async {
        let engine = StudioMockEngine()
        let midi = (await snapshot(engine)).midi
        let b = midi?.activeBindings[0]
        #expect(b?.label == "Play / Stop")
        #expect(b?.match.type == "controlChange")
        #expect(b?.match.channel == 0)
        #expect(b?.match.number == 20)
        #expect(b?.target.kind == .builtin)
        #expect(b?.target.name == "transport.togglePlay")
        #expect(b?.enabled == true)
    }

    @Test("fixture binding kick-mute is noteOn ch0 #36 → track.mute")
    func kickMuteBinding() async {
        let engine = StudioMockEngine()
        let midi = (await snapshot(engine)).midi
        let b = midi?.activeBindings[5]
        #expect(b?.label == "Kick Mute")
        #expect(b?.match.type == "noteOn")
        #expect(b?.match.number == 36)
        #expect(b?.target.name == "track.mute")
        #expect(b?.target.params?["trackName"] as? String == "Kick")
    }

    @Test("midi.enabled defaults to true")
    func midiEnabledDefault() async {
        let engine = StudioMockEngine()
        let midi = (await snapshot(engine)).midi
        #expect(midi?.enabled == true)
    }

    // MARK: - Learn flow

    @Test("learn.start → learn.active is true")
    func learnStart() async {
        let engine = StudioMockEngine()
        let params: [String: AnyHashable] = ["device": "SX-KC211 Keyboard (USB MIDI Interface)"]
        #expect(await engine.send(.catalog(name: "midi.learn.start", params: params)).ok)
        let midi = (await snapshot(engine)).midi
        #expect(midi?.learn.active == true)
    }

    @Test("learn.stop → learn.active is false")
    func learnStop() async {
        let engine = StudioMockEngine()
        let start: [String: AnyHashable] = ["device": "SX-KC211 Keyboard (USB MIDI Interface)"]
        #expect(await engine.send(.catalog(name: "midi.learn.start", params: start)).ok)
        #expect(await engine.send(.catalog(name: "midi.learn.stop", params: [:])).ok)
        let midi = (await snapshot(engine)).midi
        #expect(midi?.learn.active == false)
    }

    // MARK: - Catalog dispatch

    @Test("catalog midi.binding.set adds a new binding")
    func bindingSetAdd() async {
        let engine = StudioMockEngine()
        let before = (await snapshot(engine)).midi!.activeBindings.count
        var params: [String: AnyHashable] = [:]
        params["label"] = "Record"
        // "controlChange", not "cc": the catalog's control.type enum is
        // ["noteOn","noteOff","controlChange","pitchBend"], and the engine
        // refuses anything else. The mock used to take the shorthand, so this
        // fixture asserted a round trip the real engine never performs.
        params["control"] = ["type": "controlChange", "channel": 1, "number": 10] as [String: AnyHashable]
        params["target"] = ["kind": "builtin", "name": "transport.record"] as [String: AnyHashable]
        #expect(await engine.send(.catalog(name: "midi.binding.set", params: params)).ok)
        let after = (await snapshot(engine)).midi!.activeBindings.count
        #expect(after == before + 1)
    }

    @Test("catalog midi.binding.clear removes the matching binding")
    func bindingClear() async {
        let engine = StudioMockEngine()
        var params: [String: AnyHashable] = [:]
        params["device"] = "SX-KC211 Keyboard (USB MIDI Interface)"
        params["control"] = ["type": "controlChange", "channel": 0, "number": 20] as [String: AnyHashable]
        #expect(await engine.send(.catalog(name: "midi.binding.clear", params: params)).ok)
        let bindings = (await snapshot(engine)).midi!.activeBindings
        #expect(bindings.allSatisfy { $0.match.channel != 0 || $0.match.number != 20 })
    }

    @Test("catalog midi.map.import / midi.map.export succeed")
    func mapImportExport() async {
        let engine = StudioMockEngine()
        // The contract's own parameters: import takes `sourcePath`, export
        // takes `map` + `outputPath`. Both used to be sent as `key`, which the
        // mock accepted and the engine refuses.
        #expect(await engine.send(.catalog(name: "midi.map.import",
                                           params: ["sourcePath": "/tmp/sxkc211.json"])).ok)
        #expect(await engine.send(.catalog(name: "midi.map.export",
                                           params: ["map": "sxkc211",
                                                    "outputPath": "/tmp/sxkc211.json"])).ok)
    }

    @Test("catalog unknown midi verb returns false")
    func unknownVerb() async {
        let engine = StudioMockEngine()
        #expect(await engine.send(.catalog(name: "midi.unknown", params: [:])).ok == false)
    }

    // MARK: - Snapshot midi encoding

    @Test("snapshot round-trip sets midi field")
    func snapshotHasMidi() async {
        let engine = StudioMockEngine()
        let snap = await snapshot(engine)
        #expect(snap.midi != nil)
    }

    // MARK: - Replace preserves the full target (enabled-toggle corruption fix)

    @Test("binding.set replace keeps target params (toggle does not wipe them)")
    func bindingSetReplacePreservesParams() async {
        let engine = StudioMockEngine()
        // Kick Mute seed: noteOn ch0 #36 → track.mute {trackName: Kick}. The
        // Settings enabled-toggle re-sends binding.set with the SAME control and
        // the FULL target, flipping enabled. A replace must keep params — the
        // pre-fix toggle sent only {kind,name} and silently wiped them.
        var params: [String: AnyHashable] = [:]
        params["label"] = "Kick Mute"
        params["enabled"] = false
        params["control"] = ["type": "noteOn", "channel": 0, "number": 36] as [String: AnyHashable]
        params["target"] = [
            "kind": "command", "name": "track.mute",
            "params": ["trackName": "Kick"] as [String: AnyHashable],
        ] as [String: AnyHashable]
        #expect(await engine.send(.catalog(name: "midi.binding.set", params: params)).ok)
        let midi = (await snapshot(engine)).midi!
        #expect(midi.activeBindings.count == 9)   // replaced, not appended (8 + 1 sterling seed)
        let kick = midi.activeBindings.first { $0.match.type == "noteOn" && $0.match.number == 36 }
        #expect(kick?.target.params?["trackName"] as? String == "Kick")
        #expect(kick?.enabled == false)
    }

    @Test("catalog midi.device.select is accepted (eighth verb)")
    func deviceSelect() async {
        let engine = StudioMockEngine()
        let params: [String: AnyHashable] = [
            "device": "SX-KC211 Keyboard (USB MIDI Interface)", "map": "auto",
        ]
        #expect(await engine.send(.catalog(name: "midi.device.select", params: params)).ok)
    }

    // MARK: - Sterling triggers (M5)

    @Test("fixture carries a sterling trigger binding + an empty ring")
    func sterlingSeedBinding() async {
        let engine = StudioMockEngine()
        let midi = (await snapshot(engine)).midi
        let b = midi?.activeBindings.first { $0.target.kind == .sterling }
        #expect(b?.label == "Tighten Groove")
        #expect(b?.match.type == "noteOn")
        #expect(b?.match.number == 60)
        #expect(b?.target.instruction == "Tighten the groove on the drums in the selected region.")
        // The snapshot exposes the Sterling ring (empty on the mock) the copilot
        // drains — the real engine fills it from the pump.
        #expect(midi?.sterling != nil)
        #expect(midi?.sterling?.pending.isEmpty == true)
    }

    @Test("binding.set with a sterling target keeps the instruction")
    func bindingSetSterling() async {
        let engine = StudioMockEngine()
        var params: [String: AnyHashable] = [:]
        params["label"] = "Add Layer"
        params["control"] = ["type": "noteOn", "channel": 0, "number": 62] as [String: AnyHashable]
        params["target"] = [
            "kind": "sterling",
            "instruction": "Add a complementary layer under the chorus.",
        ] as [String: AnyHashable]
        #expect(await engine.send(.catalog(name: "midi.binding.set", params: params)).ok)
        let midi = (await snapshot(engine)).midi!
        let b = midi.activeBindings.first { $0.match.type == "noteOn" && $0.match.number == 62 }
        #expect(b?.target.kind == .sterling)
        #expect(b?.target.instruction == "Add a complementary layer under the chorus.")
    }
}

// Sterling MIDI-trigger drain (spec 8). Serialized because these tests set the
// process-wide SterlingConfig (endpoint/model in UserDefaults) to control the
// `configured` gate, and Swift Testing runs @Tests in parallel by default.
@Suite("Sterling MIDI triggers", .serialized)
@MainActor
struct SterlingTriggerTests {

    /// Records what a Sterling turn was asked to run.
    final class SpyCopilotBackend: StudioCopilotBackend {
        var isAvailable = true
        private(set) var sent: [String] = []
        func send(_ request: StudioCopilotSendRequest) throws -> UInt64 {
            sent.append(request.text)
            return UInt64(sent.count)
        }
        func poll(_ turnId: UInt64) throws -> String { #"{"state":"done","events":[]}"# }
        func cancel(_ turnId: UInt64) throws {}
        func clearHistory() throws {}
        func undo() throws -> Bool { false }
    }

    private func midi(nextSeq: Int, pending: [StudioMidiSterlingItem]) -> StudioMidiSnapshot {
        StudioMidiSnapshot(
            enabled: true, ports: [], maps: [], activeBindings: [],
            learn: StudioMidiLearnState(active: false, device: nil, ageSeconds: nil, captured: nil, current: nil),
            lastEvent: nil,
            sterling: StudioSterlingState(nextSeq: nextSeq, pending: pending))
    }

    private func model(_ spy: SpyCopilotBackend) -> StudioCopilotModel {
        StudioCopilotModel(backend: spy, viewModel: StudioViewModel(engine: StudioMockEngine()))
    }

    @Test("a fresh ring item reaches backend.send with the exact instruction")
    func triggerReachesBackend() async {
        SterlingConfig.endpoint = "http://localhost:4000/v1"
        SterlingConfig.model = "test-model"
        let spy = SpyCopilotBackend()
        let copilot = model(spy)
        // First sight of the ring initializes the cursor; nothing runs.
        copilot.applyMidiTriggerDrain(midi(nextSeq: 0, pending: []))
        #expect(spy.sent.isEmpty)
        // A trigger fires (seq 0, nextSeq advances to 1).
        let item = StudioMidiSterlingItem(seq: 0, instruction: "tighten the groove", bindingId: "b9", port: "KC")
        copilot.applyMidiTriggerDrain(midi(nextSeq: 1, pending: [item]))
        #expect(spy.sent == ["tighten the groove"])
        // The transcript shows the trigger, not the raw instruction alone.
        #expect(copilot.entries.contains {
            if case .message(let m) = $0 { return m.role == .user && m.text.hasPrefix("MIDI trigger:") }
            return false
        })
        // Simulate the turn completing so the `running` guard is NOT what blocks a
        // re-send. Re-draining the same ring must still not replay the drained
        // item, which proves the cursor advanced past it (delete the cursor
        // advance and this sends "tighten the groove" a second time).
        copilot.running = false
        copilot.applyMidiTriggerDrain(midi(nextSeq: 1, pending: [item]))
        #expect(spy.sent == ["tighten the groove"])
    }

    @Test("items already in the ring at session start never replay")
    func preSessionNoReplay() async {
        SterlingConfig.endpoint = "http://localhost:4000/v1"
        SterlingConfig.model = "test-model"
        let spy = SpyCopilotBackend()
        let copilot = model(spy)
        let stale = StudioMidiSterlingItem(seq: 4, instruction: "OLD", bindingId: "b9", port: "KC")
        // Cursor initializes to nextSeq (5) on first sight; seq 4 is pre-session.
        copilot.applyMidiTriggerDrain(midi(nextSeq: 5, pending: [stale]))
        copilot.applyMidiTriggerDrain(midi(nextSeq: 5, pending: [stale]))
        #expect(spy.sent.isEmpty)
    }

    @Test("an UNAVAILABLE Sterling shows a notice and sends nothing")
    func unavailableNoSend() async {
        let spy = SpyCopilotBackend()
        spy.isAvailable = false          // the real gate: no backend to run a turn
        let copilot = model(spy)
        copilot.applyMidiTriggerDrain(midi(nextSeq: 0, pending: []))
        let item = StudioMidiSterlingItem(seq: 0, instruction: "do a thing", bindingId: "b9", port: "KC")
        copilot.applyMidiTriggerDrain(midi(nextSeq: 1, pending: [item]))
        #expect(spy.sent.isEmpty)
        #expect(copilot.statusText != nil)
    }

    @Test("an empty BYO endpoint does NOT block a local turn — local is the default route")
    func emptyByoConfigStillRunsLocally() async {
        // Contract change: Sterling used to be BYO-endpoint-only, so a blank
        // endpoint/model meant "unconfigured, refuse to send". Sterling now
        // defaults to the LOCAL command-bus copilot running an on-device model,
        // which needs no endpoint at all — SterlingConfig only configures the
        // optional remote/BYO route. Blank BYO config must therefore still run.
        SterlingConfig.endpoint = ""
        SterlingConfig.model = ""
        let spy = SpyCopilotBackend()    // available; route defaults to .local
        let copilot = model(spy)
        copilot.applyMidiTriggerDrain(midi(nextSeq: 0, pending: []))
        let item = StudioMidiSterlingItem(seq: 0, instruction: "do a thing", bindingId: "b9", port: "KC")
        copilot.applyMidiTriggerDrain(midi(nextSeq: 1, pending: [item]))
        #expect(spy.sent == ["do a thing"])
        #expect(copilot.statusText == nil)   // no false "not configured" notice
    }

    @Test("drain reads the ring ungated: a revision-silent push while idle is seen")
    func drainReadsRingUngated() async {
        // Guards the revision-gate bug (spec 8.2): a Sterling press is journal- and
        // revision-silent, so the view model's revision-gated 30 Hz snapshot would
        // NOT refresh on it while idle. drainMidiTriggerTick reads the engine
        // UNGATED (ifNewerThan: nil), so it observes the ring with no revision bump
        // and no active snapshot poll (the view model is never polled here). This
        // fails if the drain regresses either way: to viewModel.snapshot (nil here),
        // OR to a revision-gated engine read, because mockFireSterling does NOT bump
        // revision, so a gated read would return nil on the second tick and send
        // nothing. Going through send() would bump revision and mask the latter.
        SterlingConfig.endpoint = "http://localhost:4000/v1"
        SterlingConfig.model = "test-model"
        let spy = SpyCopilotBackend()
        let engine = StudioMockEngine()
        // StudioCopilotModel holds viewModel weakly; keep vm alive across the awaits.
        let vm = StudioViewModel(engine: engine)
        let copilot = StudioCopilotModel(backend: spy, viewModel: vm)
        // First tick initializes the cursor from the engine's empty ring.
        await copilot.drainMidiTriggerTick()
        #expect(spy.sent.isEmpty)
        // A pad fires: the ring gains an item WITHOUT a revision bump.
        await engine.mockFireSterling(instruction: "tighten the groove")
        await copilot.drainMidiTriggerTick()
        #expect(spy.sent == ["tighten the groove"])
        withExtendedLifetime(vm) {}
    }
}
