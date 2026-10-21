import XCTest
@testable import MajiksMusicStudio

// The arrangement bar/beat ruler for a GENERATED song.
//
// A landed song does not necessarily begin its first bar at tick 0: the project
// carries a phase anchor (engine `project.setPhaseAnchor`,
// `project.schema.json:phaseAnchorTicks`) saying where bar 1 actually starts.
// The piano roll has honoured that since E1 via `StudioBarGrid`; the
// ARRANGEMENT drew, labelled and snapped from tick 0, so every downbeat was off
// by the lead-in, clips read as off-grid, and snapping fought the user.
//
// Every test here uses a project whose bar 1 begins at tick 1920 (a half-bar
// lead-in at 4/4, 960 PPQ -> 3840 ticks per bar), i.e. exactly the case the
// naive `bar * ticksPerBar` math gets wrong.
final class StudioArrangementGridTests: XCTestCase {

    private let sig = StudioTimeSignature.fourFour
    /// Half a bar. Deliberately NOT a multiple of ticksPerBar, so any math that
    /// starts at tick 0 disagrees with any math that starts at the anchor.
    private let anchor: Int64 = 1920
    private var ticksPerBar: Int64 { sig.ticksPerBar }   // 3840

    private var grid: StudioBarGrid {
        StudioBarGrid(timeSignature: sig, phaseAnchorTicks: anchor)
    }

    // MARK: Bar lines come from the anchor, not from tick 0

    func testRulerBarLinesStartAtThePhaseAnchor() {
        let lines = StudioTimelineMath.barLines(
            grid: grid, fromTicks: 0, toTicks: 4 * ticksPerBar)

        // Bar 1 is at the anchor; every later bar is a bar-length past it.
        let ticks = lines.map(\.ticks)
        XCTAssertTrue(ticks.contains(anchor), "bar 1 must be drawn at the anchor")
        XCTAssertTrue(ticks.contains(anchor + ticksPerBar))
        XCTAssertTrue(ticks.contains(anchor + 2 * ticksPerBar))

        // The naive tick-0 grid is exactly what was shipped and is wrong here:
        // 3840 and 7680 are NOT bar lines for this project.
        XCTAssertFalse(ticks.contains(ticksPerBar), "tick-0 grid must not survive")
        XCTAssertFalse(ticks.contains(2 * ticksPerBar))
    }

    func testBarNumbersAreLabelledFromTheAnchor() {
        let lines = StudioTimelineMath.barLines(
            grid: grid, fromTicks: anchor, toTicks: anchor + 3 * ticksPerBar)

        XCTAssertEqual(lines.first?.ticks, anchor)
        XCTAssertEqual(lines.first?.barNumber, 1, "the anchor IS bar 1")
        XCTAssertEqual(
            lines.map(\.barNumber), [1, 2, 3, 4],
            "consecutive bars, 1-based, counted from the anchor")

        let region = try! XCTUnwrap(
            StudioRegionSelection(rawStart: anchor + ticksPerBar,
                                  rawEnd: anchor + 3 * ticksPerBar + 1))
        XCTAssertEqual(region.barRange(grid: grid), 2...4,
                         "arrangement copy must number bars from the same anchor")
    }

    /// `tickForBarIndex` must be the exact inverse of `barNumber(at:)`, or the
    /// ruler's label and its line can drift apart.
    func testBarIndexRoundTripsThroughBarNumber() {
        for index in Int64(-2)...Int64(16) {
            let tick = grid.tickForBarIndex(index)
            XCTAssertEqual(
                grid.barNumber(at: tick), Int(index) + 1,
                "index \(index) -> tick \(tick) must report bar \(index + 1)")
            XCTAssertEqual(grid.barStart(containing: tick), tick)
        }
    }

    // MARK: The emitted grid must not depend on the viewport

    /// The stride-aligned start is what keeps the ruler and the lane grid drawn
    /// on top of each other. The shipped ruler walked `bar` from
    /// `scroll / ticksPerBar` in steps of `labelStride / 4` while only drawing
    /// when `bar % labelStride == 0`, so for a stride >= 8 and an unlucky
    /// scroll it emitted NOTHING at all.
    func testBarLinesAreViewportIndependent() {
        let stride: Int64 = 8
        let window = 64 * ticksPerBar

        // A line found from one scroll position must be found from any other
        // whose window also contains it.
        let wide = StudioTimelineMath.barLines(
            grid: grid, fromTicks: 0, toTicks: window, strideBars: stride)
        XCTAssertFalse(wide.isEmpty, "a 64-bar window must have stride-8 bar lines")

        for scrollBars in Int64(0)...Int64(9) {
            let from = anchor + scrollBars * ticksPerBar
            let to = from + 16 * ticksPerBar
            let seen = StudioTimelineMath.barLines(
                grid: grid, fromTicks: from, toTicks: to, strideBars: stride)

            XCTAssertFalse(
                seen.isEmpty,
                "scroll \(scrollBars) bars: a 16-bar window must still show stride-8 lines")

            // Same ticks as the wide sweep restricted to this window: the grid
            // is a property of the project, not of where we are looking.
            let expected = wide.filter { $0.ticks >= from && $0.ticks <= to }
            XCTAssertEqual(seen, expected, "scroll \(scrollBars) bars: grid shifted with the viewport")
        }
    }

    func testEveryEmittedLineIsOnTheStride() {
        let lines = StudioTimelineMath.barLines(
            grid: grid, fromTicks: anchor + 5 * ticksPerBar,
            toTicks: anchor + 40 * ticksPerBar, strideBars: 4)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertEqual(
                (line.barNumber - 1) % 4, 0,
                "bar \(line.barNumber) is not on a 4-bar stride")
        }
    }

    // MARK: Snapping must land on the anchored grid

    func testBarSnapLandsOnAnchoredBarLines() {
        // A tick just past bar 2 (anchor + 3840 = 5760) must snap to it, not to
        // the tick-0 grid line at 7680.
        let snapped = StudioTimelineMath.hardSnap(
            5760 + 200, mode: .bar, timeSignature: sig, phaseAnchorTicks: anchor)
        XCTAssertEqual(snapped, anchor + ticksPerBar, "must snap to the anchored bar 2")
    }

    func testMagneticSnapUsesTheAnchoredGrid() {
        // A tick just off an anchored bar line, well inside the magnetic
        // threshold, must be pulled ONTO the anchored line. pxPerTick is large
        // enough that the pull is what decides this, not the threshold.
        let onGrid = anchor + 3 * ticksPerBar
        XCTAssertEqual(
            StudioTimelineMath.snap(
                onGrid + 40, mode: .bar, timeSignature: sig,
                pxPerTick: 0.1, phaseAnchorTicks: anchor),
            onGrid,
            "must be pulled onto the anchored bar line")
        // And sitting exactly on it is a no-op.
        XCTAssertEqual(
            StudioTimelineMath.snap(
                onGrid, mode: .bar, timeSignature: sig,
                pxPerTick: 0.1, phaseAnchorTicks: anchor),
            onGrid)
    }

    /// A beat-aligned anchor would let the tick-0 grid agree by luck, so this
    /// uses an anchor that is NOT a multiple of a beat.
    func testBeatSnapIsMeasuredFromTheBarLine() {
        let oddAnchor: Int64 = 1450          // not a multiple of 960
        let snapped = StudioTimelineMath.hardSnap(
            oddAnchor + 960 + 50, mode: .beat, timeSignature: sig,
            phaseAnchorTicks: oddAnchor)
        XCTAssertEqual(snapped, oddAnchor + 960, "beats subdivide the anchored bar")

        let division = StudioTimelineMath.hardSnap(
            oddAnchor + 240 + 30, mode: .division, timeSignature: sig,
            phaseAnchorTicks: oddAnchor)
        XCTAssertEqual(division, oddAnchor + 240, "divisions inherit the bar phase too")
    }

    // MARK: The transport readout must agree with the ruler

    func testPositionStringCountsBarsFromTheAnchor() {
        XCTAssertEqual(
            StudioTimelineMath.positionString(
                ticks: anchor, timeSignature: sig, phaseAnchorTicks: anchor),
            "1.1.1",
            "the anchor is bar 1 beat 1")
        XCTAssertEqual(
            StudioTimelineMath.positionString(
                ticks: anchor + ticksPerBar, timeSignature: sig, phaseAnchorTicks: anchor),
            "2.1.1")
        XCTAssertEqual(
            StudioTimelineMath.positionString(
                ticks: anchor + ticksPerBar + 960, timeSignature: sig, phaseAnchorTicks: anchor),
            "2.2.1")
    }

    // MARK: The anchor has to survive the trip to the snapshot the UI reads

    func testSnapshotCarriesTheAnchorIntoItsBarGrid() {
        let snap = StudioProjectSnapshot(
            revision: 1, name: "Landed", tempoBPM: 126, timeSignature: sig,
            key: "E minor", lengthBars: 32, sections: [], tracks: [],
            transport: StudioTransportSnapshot(
                isPlaying: false, positionTicks: 0, capturedAtHostTime: 0,
                loopRegion: nil, recording: false, recordingTrackID: nil),
            stats: StudioEngineStats(
                callbackP95Millis: 0, underruns: 0, engineLabel: "test"),
            master: StudioMasterSnapshot(),
            provenanceSummary: "",
            phaseAnchorTicks: anchor)

        XCTAssertEqual(snap.phaseAnchorTicks, anchor)
        XCTAssertEqual(
            snap.barGrid.phaseAnchorTicks, anchor,
            "the snapshot's bar grid must carry the anchor to the arrangement")
        XCTAssertEqual(snap.barGrid.barStart(containing: anchor + 100), anchor)
        XCTAssertEqual(snap.barGrid.barNumber(at: anchor), 1)
    }

    // MARK: v1 projects (no anchor) must be untouched

    func testUnanchoredProjectsKeepTheTickZeroGrid() {
        let v1 = StudioBarGrid(timeSignature: sig, phaseAnchorTicks: 0)
        let lines = StudioTimelineMath.barLines(
            grid: v1, fromTicks: 0, toTicks: 4 * ticksPerBar)
        XCTAssertEqual(
            lines.map(\.ticks),
            [0, ticksPerBar, 2 * ticksPerBar, 3 * ticksPerBar, 4 * ticksPerBar])
        XCTAssertEqual(lines.first?.barNumber, 1)

        XCTAssertEqual(
            StudioTimelineMath.positionString(ticks: 0, timeSignature: sig), "1.1.1")
        XCTAssertEqual(
            StudioTimelineMath.hardSnap(200, mode: .bar, timeSignature: sig), 0)
    }

    func testMeasuredTempoMapChangesPlayheadPosition() {
        let map = StudioTempoMap.from(changes: [(ticks: 0, bpm: 120), (ticks: 3840, bpm: 60)])
        XCTAssertEqual(map.advanced(fromTicks: 0, bySeconds: 2), 3840)
        XCTAssertNotEqual(map.advanced(fromTicks: 0, bySeconds: 3.5), 6720,
                          "naive 120 BPM extrapolation must not survive the change")
    }

    // These three strings are the user-visible consumers that Round 3 moved
    // from `barRange(timeSignature:)` to the anchored snapshot grid. The
    // selected interval deliberately crosses the naive tick-0 answer.
    func testLoopDescriptionUsesAnchoredBarNumber() {
        let region = try! XCTUnwrap(StudioRegionSelection(rawStart: 3840, rawEnd: 5000))
        let anchored = region.barRange(grid: grid)
        let naive = region.barRange(timeSignature: sig)
        XCTAssertEqual("bar \(anchored.lowerBound)", "bar 1")
        XCTAssertNotEqual("bar \(anchored.lowerBound)", "bar \(naive.lowerBound)")
    }

    func testAuditionToastUsesAnchoredBarNumber() {
        let region = try! XCTUnwrap(StudioRegionSelection(rawStart: 3840, rawEnd: 5000))
        let anchored = region.barRange(grid: grid)
        let naive = region.barRange(timeSignature: sig)
        let toast = "Revised bars \(anchored.lowerBound)-\(anchored.upperBound)."
        XCTAssertEqual(toast, "Revised bars 1-1.")
        XCTAssertNotEqual(toast, "Revised bars \(naive.lowerBound)-\(naive.upperBound).")
    }

    func testTakesLineageUsesAnchoredBarNumber() {
        let region = try! XCTUnwrap(StudioRegionSelection(rawStart: 3840, rawEnd: 5000))
        let anchored = region.barRange(grid: grid)
        let naive = region.barRange(timeSignature: sig)
        let lineage = "bars \(anchored.lowerBound)-\(anchored.upperBound)"
        XCTAssertEqual(lineage, "bars 1-1")
        XCTAssertNotEqual(lineage, "bars \(naive.lowerBound)-\(naive.upperBound)")
    }

    func testZeroConfidenceProducesVisibleBadgeCopy() {
        XCTAssertEqual(
            StudioTempoTruth.messages(confidence: 0, timeSignature: .fourFour),
            ["Tempo not detected — grid at 120 BPM"])
    }

    func testUnknownConfidenceDoesNotShowDetectionBadge() {
        XCTAssertTrue(
            StudioTempoTruth.messages(confidence: 1, timeSignature: .fourFour).isEmpty,
            "a project without tempo metadata must not claim detection failed")
    }
}
