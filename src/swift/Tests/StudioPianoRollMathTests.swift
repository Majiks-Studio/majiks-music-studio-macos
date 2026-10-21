import XCTest
@testable import MajiksMusicStudio

// Lane E1-ui: the piano roll.
//
// Two halves:
//   1. Pure geometry / interaction math — tick<->x, pitch<->y, the BEAT-TRACKED
//      bar grid, the tempo map, hit-test zones, marquee intersection, resize
//      clamping and multi-note offset preservation. This is where piano-roll
//      bugs actually live and all of it is testable without a GUI.
//   2. Interactions driven end-to-end through the controller and asserted
//      against the ENGINE JOURNAL: press -> drag -> release really emits one
//      command, and undo really restores pre-state. Behaviour, not comments.
//
// What these tests deliberately do NOT claim: that a drag feels good. No static
// check can prove that. See the lane report.

final class StudioPianoRollMathTests: XCTestCase {

    private let sig = StudioTimeSignature.fourFour      // 3840 ticks/bar
    private let bar: Int64 = 3840
    private let beat: Int64 = 960

    private func layout(
        pxPerTick: CGFloat = 0.1,
        rowHeight: CGFloat = 12,
        scrollTicks: Int64 = 0,
        scrollY: CGFloat = 0,
        size: CGSize = CGSize(width: 900, height: 500),
        velocityLane: CGFloat = 66
    ) -> StudioPianoRollLayout {
        StudioPianoRollLayout(
            pxPerTick: pxPerTick, rowHeight: rowHeight,
            scrollTicks: scrollTicks, scrollY: scrollY,
            gutterWidth: 54, rulerHeight: 20,
            velocityLaneHeight: velocityLane, size: size)
    }

    private func note(
        _ id: String, _ start: Int64, _ length: Int64, _ pitch: Int, _ velocity: Int = 100
    ) -> StudioNote {
        StudioNote(id: id, startTicks: start, lengthTicks: length,
                   pitch: StudioNote.clampPitch(pitch), velocity: velocity)
    }

    // MARK: - Note model

    func testNoteRejectsZeroLengthAndClampsRanges() {
        let n = StudioNote(id: "a", startTicks: 0, lengthTicks: 0, pitch: 200, velocity: 999)
        XCTAssertEqual(n.lengthTicks, 1)          // zero-length is rejected at construction
        XCTAssertEqual(n.pitch, 127)
        XCTAssertEqual(n.velocity, 127)
        XCTAssertEqual(StudioNote.clampPitch(-5), 0)
        XCTAssertEqual(StudioNote.clampVelocity(-5), 0)
    }

    func testNoteOrderingIsTotalAndMatchesTheEngine() {
        // Engine order is (start_ticks, pitch, id). Nondeterministic ordering
        // changes serialized bytes, so the UI must sort exactly this way.
        let notes = [
            note("z", 0, 480, 60), note("a", 0, 480, 60), note("b", 0, 480, 48),
            note("c", 240, 480, 12),
        ]
        XCTAssertEqual(StudioNote.sorted(notes).map(\.id), ["b", "a", "z", "c"])
    }

    // MARK: - Tick <-> x, pitch <-> y

    func testTickToPixelRoundTripsAcrossTheGutter() {
        let l = layout(pxPerTick: 0.1, scrollTicks: bar)
        // The left edge of the note area is the scroll position, not x = 0.
        XCTAssertEqual(l.x(forTicks: bar), l.noteRect.minX, accuracy: 0.001)
        XCTAssertEqual(l.x(forTicks: bar + 960), l.noteRect.minX + 96, accuracy: 0.001)
        XCTAssertEqual(l.ticks(forX: l.noteRect.minX), bar)
        XCTAssertEqual(l.ticks(forX: l.noteRect.minX + 96), bar + 960)
    }

    func testPitchToYPutsHighNotesAtTheTop() {
        let l = layout(rowHeight: 12)
        XCTAssertEqual(l.y(forPitch: 127), l.noteRect.minY, accuracy: 0.001)
        XCTAssertEqual(l.y(forPitch: 126), l.noteRect.minY + 12, accuracy: 0.001)
        XCTAssertEqual(l.pitch(forY: l.noteRect.minY), 127)
        XCTAssertEqual(l.pitch(forY: l.noteRect.minY + 12.5), 126)
        // Round trip for a middle pitch.
        XCTAssertEqual(l.pitch(forY: l.y(forPitch: 60) + 1), 60)
    }

    func testPitchForYIsNilOutsideRangeButClampedVariantStaysLive() {
        let l = layout(rowHeight: 12)
        // Far below the bottom of pitch 0.
        let belowZero = l.y(forPitch: 0) + 200
        XCTAssertNil(l.pitch(forY: belowZero))
        // The clamped form is what a live drag uses so the gesture survives the
        // cursor leaving the surface.
        XCTAssertEqual(l.clampedPitch(forY: belowZero), 0)
        XCTAssertEqual(l.clampedPitch(forY: l.noteRect.minY - 500), 127)
    }

    func testScrollYShiftsPitchRows() {
        let a = layout(rowHeight: 12, scrollY: 0)
        let b = layout(rowHeight: 12, scrollY: 120)   // 10 rows down
        XCTAssertEqual(b.y(forPitch: 117), a.y(forPitch: 127), accuracy: 0.001)
    }

    // MARK: - Culling

    func testCullingDropsOffscreenNotesAndKeepsStraddlingOnes() {
        // scrollY frames pitch 72 at the top, so the rows under test are on
        // screen; culling is by BOTH axes, and a test that forgets the vertical
        // one is testing nothing.
        let l = layout(pxPerTick: 0.1, rowHeight: 12, scrollTicks: 1000,
                       scrollY: CGFloat(127 - 72) * 12)
        // Note area is ~846 px wide -> ~8460 ticks visible from 1000.
        let inside = note("in", 2000, 480, 60)
        let straddlingLeft = note("straddle", 500, 1000, 60)   // ends at 1500, visible
        let farRight = note("right", 60_000, 480, 60)
        let farLeft = note("left", 0, 100, 60)
        let outOfPitch = note("pitch", 2000, 480, 5)           // below the visible rows
        let visible = l.culled(
            [inside, straddlingLeft, farRight, farLeft, outOfPitch], clipOriginTicks: 0)
        XCTAssertEqual(Set(visible.map(\.id)), ["in", "straddle"])
    }

    func testCullingIsRelativeToTheClipOrigin() {
        let l = layout(pxPerTick: 0.1, scrollTicks: bar * 4, scrollY: CGFloat(127 - 72) * 12)
        // Clip-relative tick 0 sits at absolute bar 4 — it must be visible.
        XCTAssertTrue(l.isVisible(note("n", 0, 480, 60), clipOriginTicks: bar * 4))
        XCTAssertFalse(l.isVisible(note("n", 0, 480, 60), clipOriginTicks: 0))
    }

    // MARK: - Bar grid: BEAT-TRACKED, phase-anchored
    //
    // The regression these guard: generated audio drifts 1.2-2.9% off its
    // declared BPM, so a landed song's bar 1 starts at the tracked downbeat, not
    // at tick 0. `phaseAnchorTicks` carries that (engine project.setPhaseAnchor).
    // Any grid computed as `n * ticksPerBar` is wrong by the lead-in for every
    // note in the song.

    func testBarLinesFollowThePhaseAnchorNotTickZero() {
        let anchored = StudioBarGrid(timeSignature: sig, phaseAnchorTicks: 1920)   // half-bar lead-in
        XCTAssertEqual(anchored.barStart(containing: 0), 1920 - bar)     // the lead-in bar
        XCTAssertEqual(anchored.barStart(containing: 1920), 1920)
        XCTAssertEqual(anchored.barStart(containing: 1920 + 100), 1920)
        XCTAssertEqual(anchored.barStart(containing: 1920 + bar - 1), 1920)
        XCTAssertEqual(anchored.barStart(containing: 1920 + bar), 1920 + bar)
        XCTAssertEqual(anchored.barNumber(at: 1920), 1)
        XCTAssertEqual(anchored.barNumber(at: 1920 + bar * 3), 4)
        XCTAssertEqual(anchored.barNumber(at: 0), 0)                     // the lead-in
    }

    func testPhaseAnchoredSnapDiffersFromNaiveBarMath() {
        // The point of the whole exercise: the naive answer and the correct
        // answer are DIFFERENT numbers, so a passing test here means the piano
        // roll is not quietly using the naive path.
        let anchored = StudioBarGrid(timeSignature: sig, phaseAnchorTicks: 1920)
        let t: Int64 = 5900
        let naive = StudioTimelineMath.nearestGridLine(t, gridTicks: bar)
        let tracked = anchored.snap(t, division: .bar)
        XCTAssertEqual(naive, bar * 2)                   // 7680 — the wrong line
        XCTAssertEqual(tracked, 1920 + bar)              // 5760 — the tracked downbeat
        XCTAssertNotEqual(naive, tracked)
    }

    func testSubdivisionsInheritThePhaseAnchor() {
        let anchored = StudioBarGrid(timeSignature: sig, phaseAnchorTicks: 1920)
        // Every 1/16 line must be congruent to the anchor, not to 0.
        for line in anchored.gridLines(in: 1920...(1920 + bar), division: .sixteenth) {
            XCTAssertEqual((line - 1920) % 240, 0, "line \(line) is off the anchored grid")
        }
        XCTAssertEqual(anchored.snap(1920 + 130, division: .sixteenth), 1920 + 240)
        XCTAssertEqual(anchored.snap(1920 + 110, division: .sixteenth), 1920)
    }

    func testTripletDivisionsAreExactIntegersAt960PPQ() {
        XCTAssertEqual(StudioNoteGrid.eighthTriplet.ticks(sig), 320)
        XCTAssertEqual(StudioNoteGrid.sixteenthTriplet.ticks(sig), 160)
        XCTAssertEqual(StudioNoteGrid.thirtySecond.ticks(sig), 120)
        XCTAssertEqual(StudioNoteGrid.quarter.ticks(sig), 960)
        XCTAssertEqual(StudioNoteGrid.bar.ticks(sig), 3840)
        XCTAssertNil(StudioNoteGrid.off.ticks(sig))
        // Three triplet eighths fill a beat exactly — no rounding residue.
        XCTAssertEqual(StudioNoteGrid.eighthTriplet.ticks(sig)! * 3, beat)
    }

    func testGridLadderStepsFinerAndCoarserWithoutRunningOff() {
        XCTAssertEqual(StudioNoteGrid.quarter.finer(), .eighthTriplet)
        XCTAssertEqual(StudioNoteGrid.eighthTriplet.finer(), .eighth)
        XCTAssertEqual(StudioNoteGrid.thirtySecond.finer(), .thirtySecond)   // clamps
        XCTAssertEqual(StudioNoteGrid.bar.coarser(), .bar)                   // clamps
        XCTAssertEqual(StudioNoteGrid.eighth.coarser(), .eighthTriplet)
    }

    func testSnapBypassPassesThroughUntouched() {
        let grid = StudioBarGrid(timeSignature: sig, phaseAnchorTicks: 1920)
        XCTAssertEqual(grid.snap(1937, division: .sixteenth, bypass: true), 1937)
        XCTAssertEqual(grid.snap(1937, division: .sixteenth, bypass: false), 1920)
        XCTAssertEqual(grid.snap(1937, division: .off), 1937)
    }

    func testIrregularTrackedDownbeatsWinOverTheUniformGrid() {
        // Bars measured by the beat tracker at slightly different lengths, the
        // shape a drifting generative take actually produces.
        let downbeats: [Int64] = [500, 4300, 8180, 12_000]
        let grid = StudioBarGrid(timeSignature: sig, phaseAnchorTicks: 0, downbeatTicks: downbeats)
        XCTAssertEqual(grid.barStart(containing: 4300), 4300)
        XCTAssertEqual(grid.barStart(containing: 8179), 4300)
        XCTAssertEqual(grid.barLength(containing: 4300), 3880)
        XCTAssertEqual(grid.barNumber(at: 8180), 3)
        // Snapping to a bar uses the measured neighbours, not ticksPerBar.
        XCTAssertEqual(grid.snap(8100, division: .bar), 8180)
        XCTAssertEqual(grid.snap(4400, division: .bar), 4300)
        // Before the first tracked downbeat the grid still exists.
        XCTAssertEqual(grid.barStart(containing: 100), 500 - 3800)
    }

    func testBarLinesInRangeAreAscendingAndBounded() {
        let grid = StudioBarGrid(timeSignature: sig, phaseAnchorTicks: 1920)
        let lines = grid.barLines(in: 1920...(1920 + bar * 3))
        XCTAssertEqual(lines, [1920, 1920 + bar, 1920 + bar * 2, 1920 + bar * 3])
        // A range that spans no line yields nothing rather than looping.
        XCTAssertTrue(grid.barLines(in: 2000...2100).isEmpty)
    }

    // MARK: - Tempo map

    func testConstantTempoMapMatchesNaiveBpmMath() {
        let map = StudioTempoMap.constant(bpm: 120)
        // One bar at 120 bpm in 4/4 = 2 seconds.
        XCTAssertEqual(map.seconds(atTicks: bar), 2.0, accuracy: 1e-9)
        XCTAssertEqual(map.ticks(atSeconds: 2.0), bar)
        XCTAssertEqual(map.advanced(fromTicks: 0, bySeconds: 2.0), bar)
    }

    func testTempoMapRoundTripsAcrossASegmentBoundary() {
        let map = StudioTempoMap.from(changes: [(0, 120), (bar * 4, 90)])
        let atChange = map.seconds(atTicks: bar * 4)
        XCTAssertEqual(atChange, 8.0, accuracy: 1e-9)             // 4 bars at 120
        XCTAssertEqual(map.ticks(atSeconds: atChange), bar * 4)
        // One more bar, now at 90 bpm: 4 beats * (60/90) = 2.666..s
        XCTAssertEqual(map.seconds(atTicks: bar * 5), 8.0 + 8.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(map.ticks(atSeconds: 8.0 + 8.0 / 3.0), bar * 5)
        XCTAssertEqual(map.bpm(atTicks: bar * 4 + 1), 90)
    }

    func testPlayheadAdvanceHonorsATempoChangeInsideTheWindow() {
        let map = StudioTempoMap.from(changes: [(0, 120), (bar * 2, 60)])
        // Start one bar in (2 s of audio elapsed), then run 5 more seconds. The
        // tempo change lands at 4 s, so 2 s of the window are at 120 and 3 at 60.
        let landed = map.advanced(fromTicks: bar, bySeconds: 5.0)
        // 2 s at 120 -> the bar-2 boundary; 3 s at 60 -> 3 beats = 2880 ticks.
        XCTAssertEqual(landed, bar * 2 + 2880)
        // The naive form would give: 5 s * 120bpm = 10 beats = 9600 ticks on.
        let naive = bar + Int64(5.0 * 120.0 / 60.0 * Double(StudioTick.ppq))
        XCTAssertNotEqual(landed, naive)
    }

    func testDeclaredVsMeasuredTempoDriftAccumulatesToWholeBeats() {
        // The documented failure: audio tagged 100 bpm actually runs 2.4% slow.
        // A play head driven by the tag walks off the audio; the map does not.
        let declared = StudioTempoMap.constant(bpm: 100.0)
        let measured = StudioTempoMap.constant(bpm: 97.6)
        let after = 120.0   // two minutes in
        let declaredTicks = declared.advanced(fromTicks: 0, bySeconds: after)
        let measuredTicks = measured.advanced(fromTicks: 0, bySeconds: after)
        let driftBeats = Double(declaredTicks - measuredTicks) / Double(StudioTick.ppq)
        XCTAssertGreaterThan(driftBeats, 4.0, "2.4% drift over 2 min is more than a bar")
    }

    // MARK: - Hit testing

    func testWideNoteExposesBodyAndBothEdges() {
        let rect = CGRect(x: 100, y: 50, width: 60, height: 12)
        XCTAssertEqual(StudioPianoRollGeometry.zone(in: rect, at: CGPoint(x: 130, y: 56)), .body)
        XCTAssertEqual(StudioPianoRollGeometry.zone(in: rect, at: CGPoint(x: 102, y: 56)), .leadingEdge)
        XCTAssertEqual(StudioPianoRollGeometry.zone(in: rect, at: CGPoint(x: 158, y: 56)), .trailingEdge)
        XCTAssertNil(StudioPianoRollGeometry.zone(in: rect, at: CGPoint(x: 200, y: 56)))
    }

    func testEdgeGrabNeverFallsBelowTheUsableMinimum() {
        // The bug class this guards: an edge a few points wide is a resize handle
        // you aim at and miss, and the fix is never "make the note bigger".
        for width in stride(from: CGFloat(2), through: 400, by: 1) {
            let grab = StudioPianoRollGeometry.edgeGrabWidth(noteWidthPx: width)
            XCTAssertGreaterThanOrEqual(grab, StudioPianoRollGeometry.minEdgeGrabPx)
            XCTAssertLessThanOrEqual(grab, StudioPianoRollGeometry.maxEdgeGrabPx)
        }
    }

    func testTinyNoteKeepsBothAMoveTargetAndAResizeTarget() {
        // A 6 px note. Two edges would leave no body, so it gets one: the left
        // half moves, the right half (plus the outward margin) resizes.
        let rect = CGRect(x: 100, y: 50, width: 6, height: 12)
        XCTAssertEqual(StudioPianoRollGeometry.zone(in: rect, at: CGPoint(x: 100.5, y: 56)), .body)
        XCTAssertEqual(StudioPianoRollGeometry.zone(in: rect, at: CGPoint(x: 105, y: 56)), .trailingEdge)
        // The outward margin is what makes the sliver hittable at all.
        XCTAssertEqual(StudioPianoRollGeometry.zone(in: rect, at: CGPoint(x: 108, y: 56)), .trailingEdge)
        XCTAssertEqual(StudioPianoRollGeometry.zone(in: rect, at: CGPoint(x: 98, y: 56)), .body)
        XCTAssertNil(StudioPianoRollGeometry.zone(in: rect, at: CGPoint(x: 112, y: 56)))
    }

    func testEveryNoteWidthHasBothAMoveAndAResizeZone() {
        // Property check: at no width does a note become un-moveable or
        // un-resizable. This is the invariant, not the specific pixel numbers.
        for width in stride(from: CGFloat(3), through: 200, by: 0.5) {
            let rect = CGRect(x: 0, y: 0, width: width, height: 12)
            var zones: Set<String> = []
            var x = -StudioPianoRollGeometry.outwardGrabPx
            while x <= width + StudioPianoRollGeometry.outwardGrabPx {
                if let z = StudioPianoRollGeometry.zone(in: rect, at: CGPoint(x: x, y: 6)) {
                    zones.insert("\(z)")
                }
                x += 0.25
            }
            XCTAssertTrue(zones.contains("body"), "width \(width) has no move target")
            XCTAssertTrue(zones.contains("trailingEdge"), "width \(width) has no resize target")
        }
    }

    func testHitTestPrefersTheSelectedNoteOnAnOverlap() {
        let l = layout(pxPerTick: 0.1, rowHeight: 12)
        let a = note("a", 0, 960, 60)
        let b = note("b", 240, 960, 60)         // overlaps a, drawn later
        let point = CGPoint(x: l.x(forTicks: 500), y: l.y(forPitch: 60) + 6)
        // Nothing selected: the topmost (last in engine order) wins.
        XCTAssertEqual(
            StudioPianoRollGeometry.hitTest(
                [a, b], selected: [], layout: l, clipOriginTicks: 0, at: point)?.noteID, "b")
        // "a" selected: the drag keeps hold of what you already picked.
        XCTAssertEqual(
            StudioPianoRollGeometry.hitTest(
                [a, b], selected: ["a"], layout: l, clipOriginTicks: 0, at: point)?.noteID, "a")
    }

    func testMarqueeSelectsIntersectingNotesOnly() {
        let l = layout(pxPerTick: 0.1, rowHeight: 12)
        let inside = note("in", 480, 480, 60)
        let above = note("above", 480, 480, 72)
        let right = note("right", 4800, 480, 60)
        let rect = CGRect(
            x: l.x(forTicks: 400), y: l.y(forPitch: 62),
            width: 80, height: 4 * 12)
        let hits = StudioPianoRollGeometry.marqueeHits(
            [inside, above, right], layout: l, clipOriginTicks: 0, rect: rect)
        XCTAssertEqual(hits, ["in"])
    }

    func testMarqueeRectNormalizesEitherDragDirection() {
        let a = StudioPianoRollGeometry.marqueeRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 4, y: 2))
        XCTAssertEqual(a, CGRect(x: 4, y: 2, width: 6, height: 8))
    }

    func testVelocityLaneHitFindsTheNearestStem() {
        let l = layout(pxPerTick: 0.1, rowHeight: 12)
        let a = note("a", 0, 480, 60, 100)
        let b = note("b", 960, 480, 62, 40)
        let point = CGPoint(x: l.x(forTicks: 960) + 2, y: l.velocityRect.midY)
        XCTAssertEqual(
            StudioPianoRollGeometry.velocityHit(
                [a, b], selected: [], layout: l, clipOriginTicks: 0, at: point), "b")
        // Outside the lane, nothing.
        XCTAssertNil(StudioPianoRollGeometry.velocityHit(
            [a, b], selected: [], layout: l, clipOriginTicks: 0,
            at: CGPoint(x: point.x, y: l.noteRect.midY)))
    }

    func testVelocityValueMapsToAndFromTheLane() {
        let l = layout()
        XCTAssertEqual(l.velocity(forY: l.velocityY(0)), 0)
        XCTAssertEqual(l.velocity(forY: l.velocityY(127)), 127)
        XCTAssertEqual(l.velocity(forY: l.velocityY(64)), 64)
        // Beyond the lane, clamped rather than wrapped.
        XCTAssertEqual(l.velocity(forY: l.velocityRect.minY - 50), 127)
        XCTAssertEqual(l.velocity(forY: l.velocityRect.maxY + 50), 0)
    }

    func testGutterKeyResolvesAPitchAndOnlyInsideTheGutter() {
        let l = layout(rowHeight: 12, scrollY: CGFloat(127 - 72) * 12)
        let inGutter = CGPoint(x: 20, y: l.y(forPitch: 60) + 4)
        XCTAssertEqual(StudioPianoRollGeometry.gutterKey(layout: l, at: inGutter), 60)
        XCTAssertNil(StudioPianoRollGeometry.gutterKey(
            layout: l, at: CGPoint(x: 300, y: inGutter.y)))
    }

    func testPitchNamesAndAccidentals() {
        XCTAssertEqual(StudioPitchName.label(60), "C3")
        XCTAssertEqual(StudioPitchName.label(61), "C#3")
        XCTAssertEqual(StudioPitchName.label(72), "C4")
        XCTAssertTrue(StudioPitchName.isAccidental(61))
        XCTAssertFalse(StudioPitchName.isAccidental(60))
        XCTAssertTrue(StudioPitchName.isOctaveRoot(48))
    }

    // MARK: - Move: relative offsets and GROUP clamping

    func testMultiNoteMovePreservesRelativeOffsetsExactly() {
        let chord = [note("a", 0, 480, 60), note("b", 240, 480, 64), note("c", 480, 960, 67)]
        let delta = StudioNoteEdit.moveDelta(
            notes: chord, anchorID: "a",
            proposedAnchorStart: 960, proposedAnchorPitch: 62,
            clipLengthTicks: bar * 4)
        let moved = StudioNoteEdit.applyMove(chord, delta: delta)
        XCTAssertEqual(moved.map(\.startTicks), [960, 1200, 1440])
        XCTAssertEqual(moved.map { Int($0.pitch) }, [62, 66, 69])
        // Intervals and rhythmic offsets are byte-identical to the originals.
        XCTAssertEqual(
            zip(moved, chord).map { Int($0.pitch) - Int($1.pitch) }, [2, 2, 2])
        XCTAssertEqual(
            zip(moved, chord).map { $0.startTicks - $1.startTicks }, [960, 960, 960])
    }

    func testGroupClampStopsTheWholeSelectionRatherThanCollapsingIt() {
        // The classic bug: clamping each note independently piles a chord onto
        // pitch 0 / tick 0 and destroys the voicing. The group must stop as one.
        let chord = [note("a", 0, 480, 60), note("b", 240, 480, 64), note("c", 480, 480, 67)]
        let delta = StudioNoteEdit.moveDelta(
            notes: chord, anchorID: "a",
            proposedAnchorStart: -5000, proposedAnchorPitch: 0,
            clipLengthTicks: bar * 4)
        let moved = StudioNoteEdit.applyMove(chord, delta: delta)
        XCTAssertEqual(moved.map(\.startTicks), [0, 240, 480])     // shape intact
        XCTAssertEqual(moved.map { Int($0.pitch) }, [0, 4, 7])     // voicing intact
        XCTAssertEqual(moved.map(\.startTicks).min(), 0)
    }

    func testGroupClampAtTheTopOfTheKeyboardKeepsTheVoicing() {
        let chord = [note("a", 0, 480, 120), note("b", 0, 480, 124)]
        let delta = StudioNoteEdit.moveDelta(
            notes: chord, anchorID: "a",
            proposedAnchorStart: 0, proposedAnchorPitch: 127, clipLengthTicks: 0)
        let moved = StudioNoteEdit.applyMove(chord, delta: delta)
        XCTAssertEqual(moved.map { Int($0.pitch) }, [123, 127])
    }

    func testMoveIsBoundedByTheClipEnd() {
        let notes = [note("a", 0, 480, 60), note("b", bar - 480, 480, 60)]
        let delta = StudioNoteEdit.moveDelta(
            notes: notes, anchorID: "a",
            proposedAnchorStart: bar * 8, proposedAnchorPitch: 60, clipLengthTicks: bar)
        let moved = StudioNoteEdit.applyMove(notes, delta: delta)
        // The group's last note already ends exactly on the clip end, so the
        // whole selection is pinned — moving only the first note would break the
        // relative offsets, which is the one thing a group move must not do.
        XCTAssertEqual(moved.map(\.endTicks).max(), bar)
        XCTAssertEqual(moved.map(\.startTicks), [0, bar - 480])
    }

    func testUnboundedClipLengthLetsAMoveRunPastTheEnd() {
        let notes = [note("a", 0, 480, 60)]
        let delta = StudioNoteEdit.moveDelta(
            notes: notes, anchorID: "a",
            proposedAnchorStart: bar * 99, proposedAnchorPitch: 60, clipLengthTicks: 0)
        XCTAssertEqual(delta.ticks, bar * 99)
    }

    // MARK: - Resize from either edge

    func testResizeTrailingGrowsAndIsClampedByTheClip() {
        let notes = [note("a", 0, 480, 60)]
        let grow = StudioNoteEdit.resizeDelta(
            notes: notes, anchorID: "a", edge: .trailing,
            proposedAnchorEdge: 960, clipLengthTicks: bar)
        XCTAssertEqual(StudioNoteEdit.applyResize(notes, edge: .trailing, delta: grow)[0].lengthTicks, 960)

        let overrun = StudioNoteEdit.resizeDelta(
            notes: notes, anchorID: "a", edge: .trailing,
            proposedAnchorEdge: bar * 4, clipLengthTicks: bar)
        XCTAssertEqual(
            StudioNoteEdit.applyResize(notes, edge: .trailing, delta: overrun)[0].endTicks, bar)
    }

    func testResizeTrailingNeverSquashesAnyNoteBelowTheMinimum() {
        let notes = [note("a", 0, 960, 60), note("b", 0, 240, 62)]   // b is the shortest
        let delta = StudioNoteEdit.resizeDelta(
            notes: notes, anchorID: "a", edge: .trailing,
            proposedAnchorEdge: 0, clipLengthTicks: bar)
        let resized = StudioNoteEdit.applyResize(notes, edge: .trailing, delta: delta)
        XCTAssertEqual(resized.map(\.lengthTicks).min(), StudioNoteEdit.minLengthTicks)
        // And the longer note kept its extra length relative to the short one.
        XCTAssertEqual(resized[0].lengthTicks - resized[1].lengthTicks, 720)
    }

    func testResizeLeadingMovesTheStartWithoutMovingTheEnd() {
        let notes = [note("a", 960, 960, 60)]
        let delta = StudioNoteEdit.resizeDelta(
            notes: notes, anchorID: "a", edge: .leading,
            proposedAnchorEdge: 480, clipLengthTicks: bar)
        let resized = StudioNoteEdit.applyResize(notes, edge: .leading, delta: delta)
        XCTAssertEqual(resized[0].startTicks, 480)
        XCTAssertEqual(resized[0].endTicks, 1920)   // the far edge did not move
    }

    func testResizeLeadingIsClampedAtZeroAndAtTheMinimumLength() {
        let notes = [note("a", 240, 960, 60)]
        let past = StudioNoteEdit.resizeDelta(
            notes: notes, anchorID: "a", edge: .leading,
            proposedAnchorEdge: -5000, clipLengthTicks: bar)
        XCTAssertEqual(StudioNoteEdit.applyResize(notes, edge: .leading, delta: past)[0].startTicks, 0)

        let inverted = StudioNoteEdit.resizeDelta(
            notes: notes, anchorID: "a", edge: .leading,
            proposedAnchorEdge: 5000, clipLengthTicks: bar)
        let squashed = StudioNoteEdit.applyResize(notes, edge: .leading, delta: inverted)[0]
        XCTAssertEqual(squashed.lengthTicks, StudioNoteEdit.minLengthTicks)
        XCTAssertGreaterThan(squashed.lengthTicks, 0, "a resize must never invert a note")
    }

    func testMultiNoteResizeAppliesTheSameDeltaToEveryNote() {
        let notes = [note("a", 0, 480, 60), note("b", 960, 720, 64)]
        let delta = StudioNoteEdit.resizeDelta(
            notes: notes, anchorID: "a", edge: .trailing,
            proposedAnchorEdge: 720, clipLengthTicks: bar * 4)
        let resized = StudioNoteEdit.applyResize(notes, edge: .trailing, delta: delta)
        XCTAssertEqual(resized.map(\.lengthTicks), [720, 960])   // both grew by 240
    }

    // MARK: - Velocity

    func testVelocityGroupDeltaPreservesRelativeDynamics() {
        let notes = [note("a", 0, 480, 60, 100), note("b", 240, 480, 62, 60)]
        let delta = StudioNoteEdit.velocityDelta(
            notes: notes, proposedAnchorVelocity: 120, anchorID: "a")
        let edited = StudioNoteEdit.applyVelocity(notes, delta: delta)
        XCTAssertEqual(edited.map(\.velocity), [120, 80])
        XCTAssertEqual(edited[0].velocity - edited[1].velocity, 40)
    }

    func testVelocityGroupStopsAtTheCeilingAsOne() {
        let notes = [note("a", 0, 480, 60, 100), note("b", 0, 480, 62, 125)]
        let delta = StudioNoteEdit.velocityDelta(
            notes: notes, proposedAnchorVelocity: 127, anchorID: "a")
        let edited = StudioNoteEdit.applyVelocity(notes, delta: delta)
        XCTAssertEqual(edited.map(\.velocity), [102, 127])
    }

    // MARK: - Duplicate / draw / nudge

    func testDuplicateOffsetIsTheSelectionSpanRoundedUpToTheGrid() {
        let notes = [note("a", 0, 480, 60), note("b", 700, 300, 62)]   // span 1000
        XCTAssertEqual(
            StudioNoteEdit.duplicateOffsetTicks(notes, grid: .quarter, timeSignature: sig), 960 * 2)
        XCTAssertEqual(
            StudioNoteEdit.duplicateOffsetTicks(notes, grid: .sixteenth, timeSignature: sig), 1200)
        XCTAssertEqual(
            StudioNoteEdit.duplicateOffsetTicks(notes, grid: .off, timeSignature: sig), 1000)
        XCTAssertEqual(StudioNoteEdit.duplicateOffsetTicks([], grid: .bar, timeSignature: sig), 0)
    }

    func testDrawnNoteTakesTheGridLengthOnAClickAndTheDragLengthOnADrag() {
        let click = StudioNoteEdit.drawnNote(
            id: "n", pitch: 60, fromTicks: 480, toTicks: 480,
            defaultLengthTicks: 240, clipLengthTicks: bar, velocity: 100)
        XCTAssertEqual(click.startTicks, 480)
        XCTAssertEqual(click.lengthTicks, 240)

        let dragged = StudioNoteEdit.drawnNote(
            id: "n", pitch: 60, fromTicks: 480, toTicks: 1440,
            defaultLengthTicks: 240, clipLengthTicks: bar, velocity: 100)
        XCTAssertEqual(dragged.lengthTicks, 960)

        // Backwards drag still produces a forward note.
        let backwards = StudioNoteEdit.drawnNote(
            id: "n", pitch: 60, fromTicks: 1440, toTicks: 480,
            defaultLengthTicks: 240, clipLengthTicks: bar, velocity: 100)
        XCTAssertEqual(backwards.startTicks, 480)
        XCTAssertEqual(backwards.lengthTicks, 960)

        // Never past the clip end.
        let clipped = StudioNoteEdit.drawnNote(
            id: "n", pitch: 60, fromTicks: bar - 120, toTicks: bar * 4,
            defaultLengthTicks: 240, clipLengthTicks: bar, velocity: 100)
        XCTAssertEqual(clipped.endTicks, bar)
    }

    func testNudgeMovesByWholeGridStepsWithTheSameGroupClamp() {
        let chord = [note("a", 960, 480, 60), note("b", 1200, 480, 64)]
        let right = StudioNoteEdit.nudge(
            chord, byGridSteps: 1, semitones: 0, grid: .sixteenth,
            timeSignature: sig, clipLengthTicks: bar * 4)
        XCTAssertEqual(right, StudioNoteEdit.MoveDelta(ticks: 240, pitch: 0))

        let octave = StudioNoteEdit.nudge(
            chord, byGridSteps: 0, semitones: 12, grid: .sixteenth,
            timeSignature: sig, clipLengthTicks: bar * 4)
        XCTAssertEqual(octave.pitch, 12)

        // Nudging left past zero stops the group at zero, intact.
        let left = StudioNoteEdit.nudge(
            chord, byGridSteps: -10, semitones: 0, grid: .quarter,
            timeSignature: sig, clipLengthTicks: bar * 4)
        let moved = StudioNoteEdit.applyMove(chord, delta: left)
        XCTAssertEqual(moved.map(\.startTicks), [0, 240])
    }

    // MARK: - Zoom limits

    func testZoomClampsStayWithinUsableBounds() {
        XCTAssertEqual(
            StudioPianoRollLayout.clampRowHeight(0.1), StudioPianoRollLayout.minRowHeight)
        XCTAssertEqual(
            StudioPianoRollLayout.clampRowHeight(9999), StudioPianoRollLayout.maxRowHeight)
        XCTAssertEqual(
            StudioPianoRollLayout.clampPxPerTick(0), StudioPianoRollLayout.minPxPerTick)
        XCTAssertEqual(
            StudioPianoRollLayout.clampPxPerTick(9999), StudioPianoRollLayout.maxPxPerTick)
        // A row can never be squeezed below the mouse-able floor.
        XCTAssertGreaterThanOrEqual(StudioPianoRollLayout.minRowHeight, 6)
    }

    // MARK: - Command shapes

    func testNoOpCommandsAreRecognizedSoTheyNeverEnterTheJournal() {
        let clip = UUID()
        XCTAssertTrue(StudioNoteCommand.move(
            clipID: clip, noteIDs: ["a"], deltaTicks: 0, deltaPitch: 0).isNoOp)
        XCTAssertFalse(StudioNoteCommand.move(
            clipID: clip, noteIDs: ["a"], deltaTicks: 1, deltaPitch: 0).isNoOp)
        XCTAssertTrue(StudioNoteCommand.resize(
            clipID: clip, noteIDs: ["a"], edge: .trailing, deltaTicks: 0).isNoOp)
        XCTAssertTrue(StudioNoteCommand.remove(clipID: clip, noteIDs: []).isNoOp)
        XCTAssertTrue(StudioNoteCommand.duplicate(
            clipID: clip, noteIDs: ["a", "b"], newIDs: ["c"],
            deltaTicks: 10, deltaPitch: 0).isNoOp, "mismatched id counts must not journal")
        // Quantize: a 0% strength moves nothing and a grid of 0 has no lines.
        // Both would put an undo step that does nothing on the stack.
        XCTAssertTrue(StudioNoteCommand.quantize(
            clipID: clip, noteIDs: ["a"], gridTicks: 240,
            strengthPercent: 0, quantizeEnds: false).isNoOp)
        XCTAssertTrue(StudioNoteCommand.quantize(
            clipID: clip, noteIDs: ["a"], gridTicks: 0,
            strengthPercent: 100, quantizeEnds: false).isNoOp)
        XCTAssertTrue(StudioNoteCommand.quantize(
            clipID: clip, noteIDs: [], gridTicks: 240,
            strengthPercent: 100, quantizeEnds: false).isNoOp)
        XCTAssertFalse(StudioNoteCommand.quantize(
            clipID: clip, noteIDs: ["a"], gridTicks: 240,
            strengthPercent: 1, quantizeEnds: false).isNoOp)
        XCTAssertTrue(StudioNoteCommand.setTiming(clipID: clip, timings: []).isNoOp)
    }

    func testCatalogNamesAreNewNamesNotOverloadedOnes() {
        let clip = UUID()
        let names = [
            StudioNoteCommand.add(clipID: clip, notes: []).catalogName,
            StudioNoteCommand.remove(clipID: clip, noteIDs: []).catalogName,
            StudioNoteCommand.move(clipID: clip, noteIDs: [], deltaTicks: 0, deltaPitch: 0).catalogName,
            StudioNoteCommand.resize(clipID: clip, noteIDs: [], edge: .leading, deltaTicks: 0).catalogName,
            StudioNoteCommand.setVelocity(clipID: clip, noteIDs: [], deltaVelocity: 0).catalogName,
            StudioNoteCommand.duplicate(
                clipID: clip, noteIDs: [], newIDs: [], deltaTicks: 0, deltaPitch: 0).catalogName,
            StudioNoteCommand.setTiming(clipID: clip, timings: []).catalogName,
            StudioNoteCommand.quantize(
                clipID: clip, noteIDs: [], gridTicks: 240,
                strengthPercent: 100, quantizeEnds: false).catalogName,
        ]
        XCTAssertEqual(Set(names).count, names.count, "every note command needs a distinct name")
        for name in names { XCTAssertTrue(name.hasPrefix("note."), name) }
    }

    func testMintedNoteIDsAreULIDShapedAndSortable() {
        let a = StudioNoteIDMinter.mint(now: Date(timeIntervalSince1970: 1_000_000))
        let b = StudioNoteIDMinter.mint(now: Date(timeIntervalSince1970: 1_000_001))
        XCTAssertEqual(a.count, 26)
        XCTAssertLessThan(a.prefix(10), b.prefix(10))   // time-ordered prefix
    }

    // MARK: - Performance
    //
    // The gate: the arrangement canvas holds 60 fps (~2-3 ms p95 draw cost) and
    // the piano roll must not regress that. The per-frame CPU work that scales
    // with note count is cull + rect construction; that is what this measures.
    // It is not a claim about GPU compositing, which needs the GUI.

    func testCullAndRectMathStaysFarInsideAFrameBudgetAt5000Notes() {
        let l = layout(pxPerTick: 0.1, rowHeight: 12, size: CGSize(width: 1400, height: 700))
        var notes: [StudioNote] = []
        notes.reserveCapacity(5000)
        for i in 0..<5000 {
            notes.append(note(
                String(format: "N%05d", i),
                Int64(i) * 37 % (bar * 64), 240, 36 + i % 60))
        }
        var checksum: CGFloat = 0
        let start = Date()
        let passes = 20
        for _ in 0..<passes {
            let visible = l.culled(notes, clipOriginTicks: 0)
            for n in visible { checksum += l.rect(for: n, clipOriginTicks: 0).midX }
        }
        let msPerFrame = Date().timeIntervalSince(start) / Double(passes) * 1000
        XCTAssertGreaterThan(checksum, 0)
        print("[E1-ui perf] 5000-note clip: \(String(format: "%.3f", msPerFrame)) ms/frame of "
              + "cull+geometry, \(l.culled(notes, clipOriginTicks: 0).count) notes visible")
        // A 60 fps budget is 16.7 ms for EVERYTHING. The note math gets a small
        // slice of it; 4 ms is a generous ceiling that still fails loudly if
        // culling is ever removed.
        XCTAssertLessThan(msPerFrame, 4.0, "note geometry cost \(msPerFrame) ms/frame")
        // And culling must actually be culling.
        XCTAssertLessThan(l.culled(notes, clipOriginTicks: 0).count, notes.count / 2)

        // Worst case, honestly measured: zoomed all the way out so culling saves
        // nothing and every one of the 5000 notes is on screen.
        let wide = layout(
            pxPerTick: StudioPianoRollLayout.minPxPerTick, rowHeight: 6,
            size: CGSize(width: 1400, height: 900))
        var worstChecksum: CGFloat = 0
        let worstStart = Date()
        for _ in 0..<passes {
            for n in wide.culled(notes, clipOriginTicks: 0) {
                worstChecksum += wide.rect(for: n, clipOriginTicks: 0).midX
            }
        }
        let worstMs = Date().timeIntervalSince(worstStart) / Double(passes) * 1000
        XCTAssertGreaterThan(worstChecksum, 0)
        print("[E1-ui perf] worst case (no culling possible, "
              + "\(wide.culled(notes, clipOriginTicks: 0).count) notes visible): "
              + "\(String(format: "%.3f", worstMs)) ms/frame")
        XCTAssertLessThan(worstMs, 8.0, "even fully un-culled, note geometry must fit a frame")
    }

    func testCullingIsWhatKeepsTheCostFlat() {
        // Mutation check: with the viewport zoomed out to hold everything, the
        // visible count rises — proving the cheap case above came from culling
        // and not from the notes happening to be empty.
        let wide = layout(
            pxPerTick: StudioPianoRollLayout.minPxPerTick, rowHeight: 6,
            size: CGSize(width: 1400, height: 900))
        var notes: [StudioNote] = []
        for i in 0..<400 {
            notes.append(note(String(format: "N%03d", i), Int64(i) * 240, 240, 40 + i % 40))
        }
        XCTAssertEqual(wide.culled(notes, clipOriginTicks: 0).count, 400)
        let tight = layout(pxPerTick: 0.4, rowHeight: 24, size: CGSize(width: 400, height: 200))
        XCTAssertLessThan(tight.culled(notes, clipOriginTicks: 0).count, 400)
    }
}
