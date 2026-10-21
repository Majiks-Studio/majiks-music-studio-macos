import Testing
import Foundation
@testable import MajiksMusicStudio

// L12: the mixer + automation controls drive the command bus. These exercise
// the preview engine (StudioMockEngine), which mirrors the real bus semantics
// (self-inverse mixer/automation commands, journaled undo), plus the pure
// value/pixel math the lanes and hit-testing share.

@Suite("Studio mixer command round-trip")
struct StudioMixerRoundTripTests {

    private func firstTrack(_ engine: StudioMockEngine) async -> UUID {
        let snap = await engine.snapshot(ifNewerThan: nil)!
        return snap.tracks[0].id
    }

    private func snapshot(_ engine: StudioMockEngine) async -> StudioProjectSnapshot {
        await engine.snapshot(ifNewerThan: nil)!
    }

    @Test("mix.gain round-trips into the snapshot")
    func gain() async {
        let engine = StudioMockEngine()
        let t = await firstTrack(engine)
        await engine.send(.mixGain(trackID: t, gainDB: -6))
        let s = await snapshot(engine)
        #expect(abs(s.tracks[0].volumeDB - -6) < 1e-9)
    }

    @Test("mix.pan round-trips and clamps")
    func pan() async {
        let engine = StudioMockEngine()
        let t = await firstTrack(engine)
        await engine.send(.mixPan(trackID: t, pan: 0.5))
        #expect(abs((await snapshot(engine)).tracks[0].pan - 0.5) < 1e-9)
        await engine.send(.mixPan(trackID: t, pan: 3.0))   // clamps to 1
        #expect(abs((await snapshot(engine)).tracks[0].pan - 1.0) < 1e-9)
    }

    @Test("mix.eq sets the addressed band")
    func eq() async {
        let engine = StudioMockEngine()
        let t = await firstTrack(engine)
        await engine.send(.mixEq(trackID: t, band: 1, freqHz: 900, gainDB: 4, q: 1.2))
        let b = (await snapshot(engine)).tracks[0].eq[1]
        #expect(abs(b.freqHz - 900) < 1e-9)
        #expect(abs(b.gainDB - 4) < 1e-9)
        #expect(abs(b.q - 1.2) < 1e-9)
        #expect(b.kind == .bell)   // band 1 is a bell
    }

    @Test("mix.send sets bus A and B independently")
    func sends() async {
        let engine = StudioMockEngine()
        let t = await firstTrack(engine)
        await engine.send(.mixSend(trackID: t, bus: .a, amount: 0.3))
        await engine.send(.mixSend(trackID: t, bus: .b, amount: 0.6))
        let track = (await snapshot(engine)).tracks[0]
        #expect(abs(track.sendA - 0.3) < 1e-9)
        #expect(abs(track.sendB - 0.6) < 1e-9)
    }

    @Test("mix.master.gain and mix.limiter.set round-trip")
    func master() async {
        let engine = StudioMockEngine()
        await engine.send(.mixMasterGain(gainDB: -2))
        await engine.send(.mixLimiterSet(enabled: true, ceilingDB: -0.5, releaseMs: 80))
        let m = (await snapshot(engine)).master
        #expect(abs(m.volumeDB - -2) < 1e-9)
        #expect(m.limiterEnabled)
        #expect(abs(m.limiterCeilingDBTP - -0.5) < 1e-9)
        #expect(abs(m.limiterReleaseMs - 80) < 1e-9)
    }

    @Test("mute and solo round-trip")
    func muteSolo() async {
        let engine = StudioMockEngine()
        let t = await firstTrack(engine)
        await engine.send(.trackMute(trackID: t, muted: true))
        await engine.send(.trackSolo(trackID: t, soloed: true))
        let track = (await snapshot(engine)).tracks[0]
        #expect(track.muted)
        #expect(track.soloed)
    }
}

@Suite("Studio mixer + automation undo")
struct StudioMixerUndoTests {

    @Test("undo restores the exact prior gain, not just a default")
    func undoGain() async {
        let engine = StudioMockEngine()
        let s0 = await engine.snapshot(ifNewerThan: nil)!
        let t = s0.tracks[0].id
        let initial = s0.tracks[0].volumeDB

        await engine.send(.mixGain(trackID: t, gainDB: -6))
        await engine.send(.mixGain(trackID: t, gainDB: -12))
        #expect(abs((await engine.snapshot(ifNewerThan: nil)!).tracks[0].volumeDB - -12) < 1e-9)

        #expect(await engine.undo())
        #expect(abs((await engine.snapshot(ifNewerThan: nil)!).tracks[0].volumeDB - -6) < 1e-9)
        #expect(await engine.undo())
        #expect(abs((await engine.snapshot(ifNewerThan: nil)!).tracks[0].volumeDB - initial) < 1e-9)

        // Redo re-applies forward.
        #expect(await engine.redo())
        #expect(abs((await engine.snapshot(ifNewerThan: nil)!).tracks[0].volumeDB - -6) < 1e-9)
    }

    @Test("undo restores eq, send, pan, master, and limiter")
    func undoEverything() async {
        let engine = StudioMockEngine()
        let s0 = await engine.snapshot(ifNewerThan: nil)!
        let t = s0.tracks[0].id

        await engine.send(.mixEq(trackID: t, band: 2, freqHz: 3000, gainDB: -5, q: 2))
        await engine.send(.mixSend(trackID: t, bus: .b, amount: 0.4))
        await engine.send(.mixPan(trackID: t, pan: -0.7))
        await engine.send(.mixMasterGain(gainDB: 3))
        await engine.send(.mixLimiterSet(enabled: true, ceilingDB: -2, releaseMs: 120))

        for _ in 0..<5 { #expect(await engine.undo()) }

        let s = await engine.snapshot(ifNewerThan: nil)!
        #expect(s.tracks[0].eq[2] == s0.tracks[0].eq[2])
        #expect(abs(s.tracks[0].sendB - s0.tracks[0].sendB) < 1e-9)
        #expect(abs(s.tracks[0].pan - s0.tracks[0].pan) < 1e-9)
        #expect(abs(s.master.volumeDB - s0.master.volumeDB) < 1e-9)
        #expect(s.master.limiterEnabled == s0.master.limiterEnabled)
        #expect(await engine.undo() == false)   // history exhausted
    }
}

@Suite("Studio automation edits + math")
struct StudioAutomationTests {

    @Test("add / move / remove / clear round-trip through the snapshot")
    func editLane() async {
        let engine = StudioMockEngine()
        let t = (await engine.snapshot(ifNewerThan: nil)!).tracks[0].id

        await engine.send(.autopointAdd(trackID: t, target: .volume, pointID: "p1", positionTicks: 1920, value: -6))
        await engine.send(.autopointAdd(trackID: t, target: .volume, pointID: "p2", positionTicks: 960, value: 0))
        var pts = (await engine.snapshot(ifNewerThan: nil)!).tracks[0].volumeAutomation
        #expect(pts.count == 2)
        #expect(pts.first?.id == "p2", "points are kept sorted by position")

        await engine.send(.autopointMove(trackID: t, target: .volume, pointID: "p2", positionTicks: 2880, value: 3))
        pts = (await engine.snapshot(ifNewerThan: nil)!).tracks[0].volumeAutomation
        #expect(pts.last?.id == "p2")
        #expect(abs((pts.last?.value ?? 0) - 3) < 1e-9)

        await engine.send(.autopointRemove(trackID: t, target: .volume, pointID: "p1"))
        #expect((await engine.snapshot(ifNewerThan: nil)!).tracks[0].volumeAutomation.count == 1)

        // Undo the remove brings p1 back.
        #expect(await engine.undo())
        #expect((await engine.snapshot(ifNewerThan: nil)!).tracks[0].volumeAutomation.count == 2)

        await engine.send(.autolaneClear(trackID: t, target: .volume))
        #expect((await engine.snapshot(ifNewerThan: nil)!).tracks[0].volumeAutomation.isEmpty)
        #expect(!(await engine.snapshot(ifNewerThan: nil)!).tracks[0].hasVolumeAutomation)

        // Undo the clear restores every point.
        #expect(await engine.undo())
        #expect((await engine.snapshot(ifNewerThan: nil)!).tracks[0].volumeAutomation.count == 2)
    }

    @Test("value <-> y mapping is an inverse within a lane")
    func valuePixelInverse() {
        let rowY: CGFloat = 100, height: CGFloat = 40
        for target in StudioAutoTarget.allCases {
            for v in stride(from: target == .volume ? -24.0 : -1.0,
                            through: target == .volume ? 6.0 : 1.0, by: 0.5) {
                let y = StudioAutomationMath.valueToY(v, target: target, rowY: rowY, height: height)
                let back = StudioAutomationMath.yToValue(y, target: target, rowY: rowY, height: height)
                #expect(abs(back - v) < 1e-6, "target \(target) value \(v) -> \(back)")
            }
        }
    }

    @Test("value maps top-of-lane to the max and bottom to the min")
    func axisOrientation() {
        let rowY: CGFloat = 0, height: CGFloat = 40
        // Top of the lane is the higher value.
        let topVol = StudioAutomationMath.yToValue(rowY, target: .volume, rowY: rowY, height: height)
        let botVol = StudioAutomationMath.yToValue(rowY + height, target: .volume, rowY: rowY, height: height)
        #expect(topVol > botVol)
        #expect(abs(topVol - 6) < 1e-6)
        #expect(abs(botVol - -24) < 1e-6)
    }

    @Test("nearestPoint finds a point within radius and rejects far ones")
    func nearest() {
        let points = [
            StudioAutoPoint(id: "a", positionTicks: 0, value: 0),
            StudioAutoPoint(id: "b", positionTicks: 960, value: -12),
        ]
        let pxPerTick: CGFloat = 24.0 / 960.0
        let rowY: CGFloat = 0, height: CGFloat = 40
        // Point "a" is at x=0, value 0 (near the top of the lane).
        let aY = StudioAutomationMath.valueToY(0, target: .volume, rowY: rowY, height: height)
        let hit = StudioAutomationMath.nearestPoint(
            points, target: .volume, pxPerTick: pxPerTick, scrollTicks: 0,
            rowY: rowY, height: height, at: CGPoint(x: 2, y: aY + 2), radiusPx: 8)
        #expect(hit?.id == "a")
        let miss = StudioAutomationMath.nearestPoint(
            points, target: .volume, pxPerTick: pxPerTick, scrollTicks: 0,
            rowY: rowY, height: height, at: CGPoint(x: 200, y: 200), radiusPx: 8)
        #expect(miss == nil)
    }
}

@Suite("Studio automation lane layout")
struct StudioAutomationLayoutTests {

    @Test("a lane shows when it has points or when toggled visible")
    func laneVisibility() {
        let withPoints = StudioTrackSnapshot(
            id: UUID(), name: "VO", kind: .imported, clips: [], takeLane: nil,
            hasVolumeAutomation: true,
            volumeAutomation: [StudioAutoPoint(id: "p", positionTicks: 0, value: 0)])
        let empty = StudioTrackSnapshot(id: UUID(), name: "Drums", kind: .drums, clips: [], takeLane: nil)

        // With points: a volume automation row appears, no pan row.
        let rows1 = StudioRowLayoutBuilder.rows(tracks: [withPoints], expandedTakeLanes: [])
        #expect(rows1.contains { $0.kind == .automation(trackID: withPoints.id, target: .volume) })
        #expect(!rows1.contains { $0.kind == .automation(trackID: withPoints.id, target: .pan) })

        // Empty + no toggle: no automation rows.
        let rows2 = StudioRowLayoutBuilder.rows(tracks: [empty], expandedTakeLanes: [])
        #expect(!rows2.contains { if case .automation = $0.kind { return true }; return false })

        // Empty + pan toggled visible: a pan row appears.
        let key = StudioAutoLaneKey(trackID: empty.id, target: .pan)
        let rows3 = StudioRowLayoutBuilder.rows(
            tracks: [empty], expandedTakeLanes: [], visibleAutomationLanes: [key])
        #expect(rows3.contains { $0.kind == .automation(trackID: empty.id, target: .pan) })
    }
}
