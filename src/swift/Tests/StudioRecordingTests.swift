import Testing
import Foundation
@testable import MajiksMusicStudio

// The record surface drives the command bus (track.arm + record.start/rotate/
// stop/cancel). These exercise the preview engine (StudioMockEngine), which mirrors
// the real bus semantics: arming gates capture, record.stop lands a human-origin
// clip, record.cancel discards, and the input meter + device list surface while
// recording. Plus the pure meter-scale math the cockpit shares.

@Suite("Studio recording command round-trip")
struct StudioRecordingRoundTripTests {

    private func firstTrack(_ e: StudioMockEngine) async -> UUID {
        (await e.snapshot(ifNewerThan: nil)!).tracks[0].id
    }

    private func snap(_ e: StudioMockEngine) async -> StudioProjectSnapshot {
        await e.snapshot(ifNewerThan: nil)!
    }

    @Test("track.arm sets and clears the armed flag")
    func arm() async {
        let e = StudioMockEngine()
        let t = await firstTrack(e)
        await e.send(.trackArm(trackID: t, armed: true))
        #expect((await snap(e)).tracks.first(where: { $0.id == t })?.armed == true)
        await e.send(.trackArm(trackID: t, armed: false))
        #expect((await snap(e)).tracks.first(where: { $0.id == t })?.armed == false)
    }

    @Test("record.start requires an armed track")
    func startRequiresArm() async {
        let e = StudioMockEngine()
        let t = await firstTrack(e)
        let r = await e.send(.recordStart(trackID: t, deviceID: nil, startTicks: 0, punchOutTicks: nil))
        #expect(r.ok == false)                                   // not armed
        #expect((await snap(e)).transport.recording == false)
    }

    @Test("record.start on an armed track begins capture and surfaces input state")
    func start() async {
        let e = StudioMockEngine()
        let t = await firstTrack(e)
        await e.send(.trackArm(trackID: t, armed: true))
        // Arming alone must not open the mic.
        #expect((await snap(e)).transport.inputOpen == false)
        let r = await e.send(.recordStart(trackID: t, deviceID: nil, startTicks: 0, punchOutTicks: nil))
        #expect(r.ok == true)
        let s = await snap(e)
        #expect(s.transport.recording == true)
        #expect(s.transport.recordingTrackID == t)
        #expect(s.transport.inputOpen == true)                   // mic open indicator
        #expect(s.inputMeter != nil)                             // live input meter
        #expect(s.inputDevices.isEmpty == false)                 // device picker list
    }

    @Test("arming does not open the mic; inputListen does")
    func armDoesNotOpenMic() async {
        let e = StudioMockEngine()
        let t = await firstTrack(e)
        await e.send(.trackArm(trackID: t, armed: true))
        #expect((await snap(e)).transport.inputOpen == false)
        await e.send(.recordInputListen(enabled: true, deviceID: nil))
        #expect((await snap(e)).transport.inputOpen == true)
        #expect((await snap(e)).transport.inputListening == true)
        await e.send(.recordInputListen(enabled: false, deviceID: nil))
        #expect((await snap(e)).transport.inputOpen == false)
    }

    @Test("track.setInputChannel assigns a hardware channel")
    func setInputChannel() async {
        let e = StudioMockEngine()
        let t = await firstTrack(e)
        await e.send(.trackSetInputChannel(trackID: t, channel: 2))
        #expect((await snap(e)).tracks.first(where: { $0.id == t })?.inputChannel == 2)
    }

    @Test("record.stop lands a recorded (human-origin) clip and clears recording")
    func stopLands() async {
        let e = StudioMockEngine()
        let t = await firstTrack(e)
        let before = (await snap(e)).tracks.first(where: { $0.id == t })!.clips.count
        await e.send(.trackArm(trackID: t, armed: true))
        await e.send(.recordStart(trackID: t, deviceID: nil, startTicks: 0, punchOutTicks: nil))
        await e.send(.recordStop)
        let s = await snap(e)
        #expect(s.transport.recording == false)
        let track = s.tracks.first(where: { $0.id == t })!
        #expect(track.clips.count == before + 1)
        #expect(track.clips.last?.generative == false)           // recorded, not AI
    }

    @Test("record.rotate lands a comp pass and keeps capture live")
    func rotateKeepsCaptureLive() async {
        let e = StudioMockEngine()
        let t = await firstTrack(e)
        await e.send(.trackArm(trackID: t, armed: true))
        await e.send(.recordStart(trackID: t, deviceID: nil, startTicks: 0, punchOutTicks: 960))
        await e.send(.recordRotate)
        var s = await snap(e)
        #expect(s.transport.recording == true)
        #expect(s.tracks.first(where: { $0.id == t })?.takeLane?.takes.count == 1)

        await e.send(.recordStop)
        s = await snap(e)
        #expect(s.transport.recording == false)
        let track = s.tracks.first(where: { $0.id == t })!
        #expect(track.takeLane?.takes.count == 2)
        #expect(track.clips.filter { !$0.generative }.count == 1)
    }

    @Test("record.cancel discards the capture without landing")
    func cancelDiscards() async {
        let e = StudioMockEngine()
        let t = await firstTrack(e)
        let before = (await snap(e)).tracks.first(where: { $0.id == t })!.clips.count
        await e.send(.trackArm(trackID: t, armed: true))
        await e.send(.recordStart(trackID: t, deviceID: nil, startTicks: 0, punchOutTicks: nil))
        await e.send(.recordCancel)
        let s = await snap(e)
        #expect(s.transport.recording == false)
        #expect(s.tracks.first(where: { $0.id == t })!.clips.count == before)
    }

    @Test("catalog names for the record commands match the contract")
    func catalogNames() {
        #expect(StudioEngineCommand.trackArm(trackID: UUID(), armed: true).catalogName == "track.arm")
        #expect(StudioEngineCommand.trackSetInputChannel(trackID: UUID(), channel: 1).catalogName == "track.setInputChannel")
        #expect(StudioEngineCommand.recordStart(trackID: UUID(), deviceID: nil, startTicks: 0, punchOutTicks: nil).catalogName == "record.start")
        #expect(StudioEngineCommand.recordRotate.catalogName == "record.rotate")
        #expect(StudioEngineCommand.recordStop.catalogName == "record.stop")
        #expect(StudioEngineCommand.recordCancel.catalogName == "record.cancel")
        #expect(StudioEngineCommand.recordInputListen(enabled: true, deviceID: nil).catalogName == "record.inputListen")
    }
}

@Suite("Studio meter scale")
struct StudioMeterScaleTests {

    @Test("norm maps the -60..0 dBFS range to 0..1 and clamps")
    func norm() {
        #expect(abs(StudioMeterScale.norm(-60) - 0) < 1e-9)
        #expect(abs(StudioMeterScale.norm(0) - 1) < 1e-9)
        #expect(abs(StudioMeterScale.norm(-30) - 0.5) < 1e-9)
        #expect(StudioMeterScale.norm(12) == 1)                  // clamps high
        #expect(StudioMeterScale.norm(-120) == 0)                // clamps low
    }

    @Test("clock formats seconds as m:ss.d")
    func clock() {
        #expect(StudioMeterScale.clock(0) == "0:00.0")
        #expect(StudioMeterScale.clock(65) == "1:05.0")
        #expect(StudioMeterScale.clock(9.5) == "0:09.5")
    }

    @Test("dbLabel reads silent at the floor")
    func dbLabel() {
        #expect(StudioMeterScale.dbLabel(-120) == "silent")
        #expect(StudioMeterScale.dbLabel(-6).contains("dBFS"))
    }

    @Test("input meter reports captured seconds from frames and rate")
    func capturedSeconds() {
        let m = StudioInputMeter(peakDB: -6, rmsDB: -12, capturedFrames: 48_000, dropped: 0, sampleRate: 48_000)
        #expect(abs(m.capturedSeconds - 1.0) < 1e-9)
    }
}
