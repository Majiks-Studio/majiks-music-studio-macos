import Testing
import Foundation
@testable import MajiksMusicStudio

private struct FlowPermission: StudioMicrophonePermission {
    let granted: Bool
    func requestIfNeeded() async -> Bool { granted }
}

private final class SuspendingPermission: StudioMicrophonePermission, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    var isPending: Bool { lock.withLock { continuation != nil } }
    func requestIfNeeded() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }
    func resume(_ granted: Bool) {
        let pending = lock.withLock { defer { continuation = nil }; return continuation }
        pending?.resume(returning: granted)
    }
}

private actor RecordFlowSpy: StudioEngineProtocol {
    let inner = StudioMockEngine()
    private(set) var sent: [StudioEngineCommand] = []

    func setMetronome(enabled: Bool?, levelDB: Double?, countInBeats: Int?) async {
        await inner.setMetronome(enabled: enabled, levelDB: levelDB, countInBeats: countInBeats)
    }
    func snapshot(ifNewerThan revision: UInt64?) async -> StudioProjectSnapshot? { await inner.snapshot(ifNewerThan: revision) }
    @discardableResult func send(_ command: StudioEngineCommand) async -> StudioCommandResult {
        sent.append(command)
        return await inner.send(command)
    }
    func importAudio(path: String, trackID: UUID?, startTicks: Int64) async -> StudioCommandResult { await inner.importAudio(path: path, trackID: trackID, startTicks: startTicks) }
    @discardableResult func undo() async -> Bool { await inner.undo() }
    @discardableResult func redo() async -> Bool { await inner.redo() }
    func waveformTile(_ key: StudioTileKey) async -> StudioWaveformTile? { await inner.waveformTile(key) }
    func addInstrumentTrack(name: String, lengthTicks: Int64) async -> StudioInstrumentTrackOutcome { await inner.addInstrumentTrack(name: name, lengthTicks: lengthTicks) }
    func openInStudio(_ request: StudioLandingRequest) async -> StudioCommandResult { await inner.openInStudio(request) }
}

@MainActor
@Suite("Studio record flow", .serialized)
struct StudioRecordFlowTests {
    private func wait(_ model: StudioViewModel, _ condition: @escaping (StudioViewModel) -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition(model) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("condition wait timed out")
    }

    private func waitSent(_ spy: RecordFlowSpy, _ condition: @escaping ([StudioEngineCommand]) -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition(await spy.sent) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("command wait timed out")
    }

    private func model(_ spy: RecordFlowSpy, permission: Bool = true) -> StudioViewModel {
        StudioViewModel(engine: spy, microphonePermission: FlowPermission(granted: permission))
    }

    private func arm(_ model: StudioViewModel) async -> UUID? {
        model.startPolling()
        await wait(model) { $0.snapshot != nil }
        guard let track = model.snapshot?.tracks.first else { return nil }
        model.setTrackArm(track.id, armed: true)
        await wait(model) { $0.firstArmedTrack != nil }
        return track.id
    }

    private func names(_ commands: [StudioEngineCommand]) -> [String] {
        commands.map {
            switch $0 {
            case .transportPlay: return "transport.play"
            case .transportStop: return "transport.stop"
            case .transportSeek: return "transport.seek"
            case .recordStart: return "record.start"
            case .recordInputListen: return "record.inputListen"
            case .recordStop: return "record.stop"
            case .recordCancel: return "record.cancel"
            default: return "other"
            }
        }
    }

    @Test("S1 stopped record orders seek, play, start")
    func s1StoppedOrder() async {
        let spy = RecordFlowSpy(); let model = model(spy); defer { model.stopPolling() }
        #expect(await arm(model) != nil)
        model.countInBeats = 0; model.toggleRecord()
        await waitSent(spy) { self.names($0).contains("record.start") }
        let sent = await spy.sent
        #expect(names(sent).suffix(2) == ["transport.play", "record.start"])
        #expect(sent.contains { if case .recordStart(_, _, nil, nil) = $0 { return true }; return false })
    }

    @Test("S1 stopped punch seeks and sends both region ticks")
    func s1StoppedPunchOrder() async {
        let spy = RecordFlowSpy(); let model = model(spy); defer { model.stopPolling() }
        #expect(await arm(model) != nil)
        model.selection.region = StudioRegionSelection(rawStart: 3840, rawEnd: 7680)
        model.countInBeats = 0; model.toggleRecord()
        await waitSent(spy) { self.names($0).contains("record.start") }
        let sent = await spy.sent
        #expect(names(sent).suffix(3) == ["transport.seek", "transport.play", "record.start"])
        #expect(sent.contains { if case .recordStart(_, _, 3840, 7680) = $0 { return true }; return false })
    }

    @Test("S2 count-in opens input before play")
    func s2CountInOpensInput() async {
        let spy = RecordFlowSpy(); let model = model(spy); defer { model.stopPolling() }
        #expect(await arm(model) != nil); model.countInBeats = 1; model.toggleRecord()
        await wait(model) { $0.isCountingIn }
        await waitSent(spy) { self.names($0).contains("record.start") }
        let sent = await spy.sent; let names = names(sent)
        #expect(names.contains("record.inputListen")); #expect(names.contains("record.start"))
        if let listen = names.firstIndex(of: "record.inputListen"), let start = names.firstIndex(of: "record.start") {
            #expect(listen < start)
        }
    }

    @Test("S3 rolling record starts without a transport command")
    func s3Rolling() async {
        let spy = RecordFlowSpy(); let model = model(spy); defer { model.stopPolling() }
        #expect(await arm(model) != nil); model.countInBeats = 0
        model.play(); await wait(model) { $0.isPlaying }
        let before = (await spy.sent).count
        model.toggleRecord()
        await wait(model) { $0.isRecording }
        let names = names(Array((await spy.sent).dropFirst(before))); #expect(!names.contains("transport.seek")); #expect(!names.contains("transport.play")); #expect(names.last == "record.start")
    }

    @Test("S5 denied permission sends nothing and shows the refusal")
    func s5Denied() async {
        let spy = RecordFlowSpy(); let model = model(spy, permission: false); defer { model.stopPolling() }
        #expect(await arm(model) != nil); model.toggleRecord()
        await wait(model) { $0.microphoneAccessMessage != nil }
        let names = names(await spy.sent)
        #expect(!names.contains("record.start")); #expect(!names.contains("record.inputListen")); #expect(model.microphoneAccessMessage != nil)
    }

    @Test("S5 default permission stub allows recording")
    func s5DefaultPermissionAllowsRecording() async {
        let spy = RecordFlowSpy(); let model = StudioViewModel(engine: spy); defer { model.stopPolling() }
        #expect(await arm(model) != nil); model.countInBeats = 0; model.toggleRecord()
        await wait(model) { $0.isRecording }
        #expect(names(await spy.sent).contains("record.start"))
    }

    @Test("S6 mock rolling and stopped captures land at their distinct positions")
    func s6MockPlacement() async {
        let engine = StudioMockEngine()
        let initial = await engine.snapshot(ifNewerThan: nil)
        let track = initial!.tracks[0]
        _ = await engine.send(.trackArm(trackID: track.id, armed: true))
        _ = await engine.send(.transportSeek(ticks: 5000)); _ = await engine.send(.transportPlay)
        _ = await engine.send(.recordStart(trackID: track.id, deviceID: nil, startTicks: nil, punchOutTicks: nil))
        try? await Task.sleep(nanoseconds: 100_000_000); _ = await engine.send(.recordStop)
        var snapshot = await engine.snapshot(ifNewerThan: nil)!
        let rolling = snapshot.tracks[0].clips.last!
        #expect(rolling.startTicks >= 5000); #expect(rolling.startTicks % snapshot.timeSignature.ticksPerBar != 0)
        let stoppedEngine = StudioMockEngine()
        let stoppedTrack = (await stoppedEngine.snapshot(ifNewerThan: nil)!).tracks[0]
        _ = await stoppedEngine.send(.trackArm(trackID: stoppedTrack.id, armed: true))
        _ = await stoppedEngine.send(.transportStop)
        _ = await stoppedEngine.send(.transportSeek(ticks: 5000))
        _ = await stoppedEngine.send(.recordStart(trackID: stoppedTrack.id, deviceID: nil, startTicks: 5000, punchOutTicks: nil))
        _ = await stoppedEngine.send(.recordStop)
        snapshot = await stoppedEngine.snapshot(ifNewerThan: nil)!
        #expect(snapshot.tracks[0].clips.last?.startTicks == 3840)
        _ = await stoppedEngine.send(.transportPlay)
        _ = await stoppedEngine.send(.recordStart(trackID: stoppedTrack.id, deviceID: nil, startTicks: 3840, punchOutTicks: 7680))
        _ = await stoppedEngine.send(.recordStop)
        snapshot = await stoppedEngine.snapshot(ifNewerThan: nil)!
        let punch = snapshot.tracks[0].clips.last!
        #expect(punch.startTicks == 3840); #expect(punch.lengthTicks == 3840)
    }

    @Test("S8 loop record does not auto-roll")
    func s8LoopDoesNotRoll() async {
        let spy = RecordFlowSpy(); let model = model(spy); defer { model.stopPolling() }
        #expect(await arm(model) != nil); model.loopRecord = true; model.countInBeats = 0; model.toggleRecord()
        await waitSent(spy) { self.names($0).contains("record.start") }
        let names = names(await spy.sent); #expect(!names.contains("transport.play")); #expect(!names.contains("transport.seek")); #expect(names.contains("record.start"))
    }

    @Test("S4 stopping an auto-rolled take stops the transport")
    func s4StoppingAutoRolledTakeStopsTransport() async {
        let spy = RecordFlowSpy(); let model = model(spy); defer { model.stopPolling() }
        #expect(await arm(model) != nil); model.countInBeats = 0; model.toggleRecord()
        await wait(model) { $0.isRecording }; model.toggleRecord()
        await waitSent(spy) { names($0).contains("transport.stop") }
        #expect(names(await spy.sent).contains("transport.stop"))
    }

    @Test("S4 stopping a take started while playing leaves transport rolling")
    func s4StoppingRollingTakeLeavesTransportPlaying() async {
        let spy = RecordFlowSpy(); let model = model(spy); defer { model.stopPolling() }
        #expect(await arm(model) != nil); model.countInBeats = 0; model.play()
        await wait(model) { $0.isPlaying }; model.toggleRecord(); await wait(model) { $0.isRecording }
        let before = await spy.sent.count; model.toggleRecord(); await waitSent(spy) { commands in
            names(Array(commands.dropFirst(before))).contains("record.stop")
        }
        let sent = Array((await spy.sent).dropFirst(before)); #expect(names(sent).first == "record.stop")
        #expect(!names(sent).contains("transport.stop"))
    }

    @Test("S7 cancelling a count-in closes the listen stream")
    func s7CancellingCountInClosesListen() async {
        let spy = RecordFlowSpy(); let model = model(spy); defer { model.stopPolling() }
        #expect(await arm(model) != nil); model.countInBeats = 4; model.toggleRecord()
        await wait(model) { $0.isCountingIn }; model.toggleRecord()
        await waitSent(spy) { $0.contains { if case .recordInputListen(false, _) = $0 { return true }; return false } }
        let sent = await spy.sent
        #expect(sent.contains { if case .recordInputListen(false, _) = $0 { return true }; return false })
    }

    @Test("S7 stop closes a listen opened by Record and restores user Listen")
    func s7StopRestoresListenOwnership() async {
        let spy = RecordFlowSpy(); let model = model(spy); defer { model.stopPolling() }
        #expect(await arm(model) != nil); model.countInBeats = 0; model.toggleRecord()
        await wait(model) { $0.isRecording }; let before = await spy.sent.count; model.toggleRecord()
        await waitSent(spy) { commands in
            names(Array(commands.dropFirst(before))).contains("record.inputListen")
        }
        let sent = Array((await spy.sent).dropFirst(before));
        #expect(names(sent).first == "record.stop")
        #expect(sent.contains { if case .recordInputListen(false, _) = $0 { return true }; return false })

        let userSpy = RecordFlowSpy(); let userModel = self.model(userSpy); defer { userModel.stopPolling() }
        #expect(await arm(userModel) != nil); userModel.toggleInputListen()
        await wait(userModel) { $0.inputListening }; userModel.countInBeats = 0; userModel.toggleRecord()
        await wait(userModel) { $0.isRecording }; let userBefore = await userSpy.sent.count; userModel.toggleRecord()
        await waitSent(userSpy) { commands in
            names(Array(commands.dropFirst(userBefore))).contains("record.inputListen")
        }
        let userSent = Array((await userSpy.sent).dropFirst(userBefore));
        #expect(names(userSent).first == "record.stop")
        #expect(userSent.contains { if case .recordInputListen(true, _) = $0 { return true }; return false })
    }

    @Test("S9 a pending permission check suppresses a second press")
    func s9PermissionPendingIsSingleShot() async {
        let spy = RecordFlowSpy(); let permission = SuspendingPermission()
        let model = StudioViewModel(engine: spy, microphonePermission: permission); defer { model.stopPolling() }
        #expect(await arm(model) != nil); model.countInBeats = 0; model.toggleRecord()
        let pendingDeadline = Date().addingTimeInterval(2)
        while !permission.isPending && Date() < pendingDeadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        if !permission.isPending { Issue.record("permission check did not become pending") }
        model.toggleRecord(); permission.resume(true)
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(names(await spy.sent).filter { $0 == "record.start" }.isEmpty)
        let secondSpy = RecordFlowSpy(); let secondPermission = SuspendingPermission()
        let second = StudioViewModel(engine: secondSpy, microphonePermission: secondPermission); defer { second.stopPolling() }
        #expect(await arm(second) != nil); second.countInBeats = 0; second.toggleRecord()
        let secondPendingDeadline = Date().addingTimeInterval(2)
        while !secondPermission.isPending && Date() < secondPendingDeadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        if !secondPermission.isPending { Issue.record("second permission check did not become pending") }
        secondPermission.resume(true)
        await wait(second) { $0.isRecording }
        #expect(names(await secondSpy.sent).filter { $0 == "record.start" }.count == 1)
    }

    @Test("S10 a free rolling take has no punch parameters")
    func s10RollingFreeTakeHasNoPunch() async {
        let spy = RecordFlowSpy(); let model = model(spy); defer { model.stopPolling() }
        #expect(await arm(model) != nil); model.selection.region = StudioRegionSelection(rawStart: 3840, rawEnd: 7680)
        model.countInBeats = 0; model.seek(toTicks: 10_000); model.play()
        await wait(model) { $0.isPlaying }; try? await Task.sleep(nanoseconds: 100_000_000)
        model.toggleRecord(); await wait(model) { $0.isRecording }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let starts = (await spy.sent).compactMap { command -> (Int64?, Int64?)? in
            guard case let .recordStart(_, _, start, punch) = command else { return nil }; return (start, punch)
        }
        #expect(starts.last?.0 == nil); #expect(starts.last?.1 == nil)
        #expect(!names(await spy.sent).contains("record.stop"))
    }
}
