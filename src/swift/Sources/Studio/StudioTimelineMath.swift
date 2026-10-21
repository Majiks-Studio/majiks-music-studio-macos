import Foundation
import CoreGraphics

// MARK: - Snap
//
// Pure functions only. Everything here is unit-tested (StudioShellMathTests);
// no SwiftUI, no engine, no side effects.

enum StudioSnapMode: String, CaseIterable, Sendable {
    case off
    case bar
    case beat
    /// Division = quarter of a beat (a 16th in 4/4).
    case division

    var label: String {
        switch self {
        case .off: return "Off"
        case .bar: return "Bar"
        case .beat: return "Beat"
        case .division: return "1/16"
        }
    }
}

enum StudioTimelineMath {

    // MARK: Grid

    static func gridTicks(mode: StudioSnapMode, timeSignature: StudioTimeSignature) -> Int64? {
        switch mode {
        case .off: return nil
        case .bar: return timeSignature.ticksPerBar
        case .beat: return timeSignature.ticksPerBeat
        case .division: return max(1, timeSignature.ticksPerBeat / 4)
        }
    }

    /// Nearest grid line at or around `ticks`.
    ///
    /// Lines are measured FROM `phaseAnchorTicks` (where bar 1 begins), not
    /// from tick 0, so subdivisions inherit the project's bar phase. 0 is the
    /// v1 behaviour.
    static func nearestGridLine(
        _ ticks: Int64,
        gridTicks: Int64,
        phaseAnchorTicks: Int64 = 0
    ) -> Int64 {
        guard gridTicks > 0 else { return ticks }
        let rel = ticks - phaseAnchorTicks
        let down = (rel >= 0 ? rel : rel - gridTicks + 1) / gridTicks * gridTicks
        let up = down + gridTicks
        return phaseAnchorTicks + ((rel - down) <= (up - rel) ? down : up)
    }

    /// Magnetic snap: pull to the nearest grid line only when the cursor is
    /// within `magneticThresholdPx` of it; otherwise the raw position wins.
    /// `mode == .off` or a nil threshold distance passes through untouched.
    static func snap(
        _ ticks: Int64,
        mode: StudioSnapMode,
        timeSignature: StudioTimeSignature,
        pxPerTick: CGFloat,
        magneticThresholdPx: CGFloat = 8,
        phaseAnchorTicks: Int64 = 0
    ) -> Int64 {
        guard let grid = gridTicks(mode: mode, timeSignature: timeSignature) else { return ticks }
        let line = nearestGridLine(ticks, gridTicks: grid, phaseAnchorTicks: phaseAnchorTicks)
        let distancePx = CGFloat(abs(ticks - line)) * pxPerTick
        return distancePx <= magneticThresholdPx ? line : ticks
    }

    static func snap(
        _ ticks: Int64,
        mode: StudioSnapMode,
        grid: StudioBarGrid,
        pxPerTick: CGFloat,
        magneticThresholdPx: CGFloat = 8
    ) -> Int64 {
        guard mode != .off else { return ticks }
        let step = mode == .bar ? grid.ticksPerBar : mode == .beat ? grid.ticksPerBeat : max(1, grid.ticksPerBeat / 4)
        let line = StudioTimelineMath.nearestGridLine(ticks, gridTicks: step, phaseAnchorTicks: grid.phaseAnchorTicks)
        return CGFloat(abs(ticks - line)) * pxPerTick <= magneticThresholdPx ? line : ticks
    }

    /// Hard snap (always lands on the grid). Used for ruler region selection,
    /// which is bar-snapped by design (01-DESIGN 3.2).
    static func hardSnap(
        _ ticks: Int64,
        mode: StudioSnapMode,
        timeSignature: StudioTimeSignature,
        phaseAnchorTicks: Int64 = 0
    ) -> Int64 {
        guard let grid = gridTicks(mode: mode, timeSignature: timeSignature) else { return ticks }
        return nearestGridLine(ticks, gridTicks: grid, phaseAnchorTicks: phaseAnchorTicks)
    }

    static func hardSnap(_ ticks: Int64, mode: StudioSnapMode, grid: StudioBarGrid) -> Int64 {
        guard mode != .off else { return ticks }
        let step = mode == .bar ? grid.ticksPerBar : mode == .beat ? grid.ticksPerBeat : max(1, grid.ticksPerBeat / 4)
        return nearestGridLine(ticks, gridTicks: step, phaseAnchorTicks: grid.phaseAnchorTicks)
    }

    // MARK: Pixel <-> tick

    static func ticksToPx(_ ticks: Int64, pxPerTick: CGFloat, scrollTicks: Int64) -> CGFloat {
        CGFloat(ticks - scrollTicks) * pxPerTick
    }

    static func pxToTicks(_ px: CGFloat, pxPerTick: CGFloat, scrollTicks: Int64) -> Int64 {
        guard pxPerTick > 0 else { return scrollTicks }
        return scrollTicks + Int64((px / pxPerTick).rounded())
    }

    // MARK: Move / trim / split

    /// Clamp a proposed clip start so the clip stays within [0, projectEnd).
    static func clampedMoveStart(
        proposedStartTicks: Int64,
        lengthTicks: Int64,
        projectLengthTicks: Int64
    ) -> Int64 {
        let maxStart = max(0, projectLengthTicks - lengthTicks)
        return min(max(0, proposedStartTicks), maxStart)
    }

    enum TrimEdge: Sendable { case leading, trailing }

    /// Trim one edge of a clip. Result keeps at least `minLengthTicks` and
    /// never pushes the leading edge below 0.
    static func trimmed(
        start: Int64,
        length: Int64,
        edge: TrimEdge,
        toTicks: Int64,
        minLengthTicks: Int64
    ) -> (start: Int64, length: Int64) {
        switch edge {
        case .leading:
            let maxStart = start + length - minLengthTicks
            let newStart = min(max(0, toTicks), maxStart)
            return (newStart, start + length - newStart)
        case .trailing:
            let minEnd = start + minLengthTicks
            let newEnd = max(toTicks, minEnd)
            return (start, newEnd - start)
        }
    }

    /// Split a clip at an absolute tick. Returns nil when the split point is
    /// not strictly inside the clip.
    static func splitLengths(
        start: Int64,
        length: Int64,
        atTicks: Int64
    ) -> (left: Int64, right: Int64)? {
        guard atTicks > start, atTicks < start + length else { return nil }
        let left = atTicks - start
        return (left, length - left)
    }

    // MARK: Zoom

    static let minPxPerTick: CGFloat = 4.0 / CGFloat(StudioTick.ppq * 4)   // ~4 px per 4/4 bar
    static let maxPxPerTick: CGFloat = 200.0 / CGFloat(StudioTick.ppq)     // 200 px per quarter

    static func clampZoom(_ pxPerTick: CGFloat) -> CGFloat {
        min(max(pxPerTick, minPxPerTick), maxPxPerTick)
    }

    /// px-per-tick that fits `projectLengthTicks` into `viewportWidth`, clamped.
    static func zoomToFit(projectLengthTicks: Int64, viewportWidth: CGFloat) -> CGFloat {
        guard projectLengthTicks > 0, viewportWidth > 0 else { return clampZoom(0) }
        return clampZoom(viewportWidth / CGFloat(projectLengthTicks))
    }

    /// Zoom about an anchor: keep the tick under `anchorPx` stationary.
    /// Returns the new scroll (in ticks, >= 0).
    static func scrollPreservingAnchor(
        anchorPx: CGFloat,
        oldPxPerTick: CGFloat,
        newPxPerTick: CGFloat,
        oldScrollTicks: Int64
    ) -> Int64 {
        guard oldPxPerTick > 0, newPxPerTick > 0 else { return oldScrollTicks }
        let anchorTick = CGFloat(oldScrollTicks) + anchorPx / oldPxPerTick
        let newScroll = anchorTick - anchorPx / newPxPerTick
        return max(0, Int64(newScroll.rounded()))
    }

    // MARK: Position formatting

    /// "33.1.1" = bar.beat.division (all 1-based), divisions are quarters of
    /// a beat. Matches the transport readout in the mockup.
    static func positionString(
        ticks: Int64,
        timeSignature: StudioTimeSignature,
        phaseAnchorTicks: Int64 = 0
    ) -> String {
        let tpb = timeSignature.ticksPerBar
        let tpBeat = timeSignature.ticksPerBeat
        let tpDiv = max(1, tpBeat / 4)
        // Bars/beats/divisions are all counted from where bar 1 actually
        // begins. Floor division (not truncation) so a position inside the
        // lead-in still reports a sane beat/division rather than a negative one.
        let rel = max(0, ticks) - phaseAnchorTicks
        let bar = rel >= 0 ? rel / tpb : (rel - tpb + 1) / tpb
        let within = rel - bar * tpb
        let beat = within / tpBeat
        let div = (within % tpBeat) / tpDiv
        return "\(bar + 1).\(beat + 1).\(div + 1)"
    }

    // MARK: Adaptive grid density

    /// Bar-number label stride so labels stay >= ~44 px apart (mockup labels
    /// every 4 bars at 11 px/bar).
    static func barLabelStride(pxPerBar: CGFloat) -> Int {
        guard pxPerBar > 0 else { return 16 }
        var stride = 1
        while CGFloat(stride) * pxPerBar < 44 { stride *= 2 }
        return stride
    }

    /// Whether beat lines should draw at this zoom (>= ~10 px per beat).
    static func showsBeatLines(pxPerBeat: CGFloat) -> Bool {
        pxPerBeat >= 10
    }

    // MARK: Ruler / grid lines
    //
    // The arrangement ruler and the lane grid MUST agree, so both come from
    // this one function (the row-layout discipline, applied to the time axis).
    // Drawing code does geometry only; where a bar line lives is decided here
    // and unit-tested.

    /// One bar line: where it sits in ticks, and the 1-based number the ruler
    /// prints for it.
    struct BarLine: Equatable, Sendable {
        var ticks: Int64
        var barNumber: Int
    }

    /// Every `strideBars`-th bar line whose tick lands in `fromTicks...toTicks`.
    ///
    /// The emitted set is aligned to bar 1 of `grid` and to `strideBars`, so it
    /// does NOT depend on where the viewport happens to be scrolled: zooming or
    /// scrolling can change which lines are visible, never which ticks are bar
    /// lines. That independence is what keeps the ruler and the lane grid on
    /// top of each other.
    static func barLines(
        grid: StudioBarGrid,
        fromTicks: Int64,
        toTicks: Int64,
        strideBars: Int64 = 1
    ) -> [BarLine] {
        let step = max(1, strideBars)
        guard grid.ticksPerBar > 0, toTicks >= fromTicks else { return [] }

        // Walk from the bar containing the window start, backed up to the
        // previous multiple of `step` so the emitted phase is viewport
        // independent.
        let startBarNumber = grid.barNumber(at: fromTicks)
        // barNumber is 1-based; align the 0-based index down to `step`.
        var index = Int64(startBarNumber - 1)
        let rem = index % step
        index -= rem >= 0 ? rem : rem + step

        var out: [BarLine] = []
        var guardCount = 0
        while guardCount < 100_000 {
            guardCount += 1
            let ticks = grid.tickForBarIndex(index)
            if ticks > toTicks { break }
            if ticks >= fromTicks {
                out.append(BarLine(ticks: ticks, barNumber: Int(index) + 1))
            }
            index += step
        }
        return out
    }
}

// MARK: - Row layout
//
// One pure function produces the vertical layout used by BOTH the header
// column and the canvas, so hit-testing and drawing can never disagree.

enum StudioRowKind: Equatable, Sendable {
    case track(trackID: UUID)
    case takeLane(trackID: UUID)
    case automation(trackID: UUID, target: StudioAutoTarget)
}

struct StudioRowLayout: Equatable, Sendable {
    var kind: StudioRowKind
    var y: CGFloat
    var height: CGFloat

    var maxY: CGFloat { y + height }
}

enum StudioRowLayoutBuilder {
    static func rows(
        tracks: [StudioTrackSnapshot],
        expandedTakeLanes: Set<UUID>,
        visibleAutomationLanes: Set<StudioAutoLaneKey> = [],
        trackHeight: CGFloat = StudioTokens.trackHeightDefault,
        takeRowHeight: CGFloat = StudioTokens.takeRowHeight,
        automationHeight: CGFloat = StudioTokens.automationLaneHeight
    ) -> [StudioRowLayout] {
        var out: [StudioRowLayout] = []
        var y: CGFloat = 0
        for track in tracks {
            let h = track.height > 0 ? CGFloat(track.height) : trackHeight
            out.append(.init(kind: .track(trackID: track.id), y: y, height: h))
            y += h
            if let lane = track.takeLane, expandedTakeLanes.contains(track.id) {
                let h = CGFloat(lane.takes.count) * takeRowHeight + 6
                out.append(.init(kind: .takeLane(trackID: track.id), y: y, height: h))
                y += h
            }
            // A lane shows when the user toggled it on, or it already has points.
            for target in [StudioAutoTarget.volume, .pan] {
                let toggled = visibleAutomationLanes.contains(
                    StudioAutoLaneKey(trackID: track.id, target: target))
                if toggled || !track.automation(target).isEmpty {
                    out.append(.init(
                        kind: .automation(trackID: track.id, target: target),
                        y: y, height: automationHeight))
                    y += automationHeight
                }
            }
        }
        return out
    }

    static func totalHeight(_ rows: [StudioRowLayout]) -> CGFloat {
        rows.last?.maxY ?? 0
    }

    static func row(at y: CGFloat, rows: [StudioRowLayout]) -> StudioRowLayout? {
        rows.first { y >= $0.y && y < $0.maxY }
    }
}

// MARK: - Automation lane math
//
// Pure value<->pixel mapping for the breakpoint lanes, shared by drawing and
// hit-testing so they never disagree (the row-layout discipline, applied to
// the vertical axis). Volume is dB in a fixed window; pan is -1...1.

enum StudioAutomationMath {
    /// The displayed value window for a lane (top of lane = upperBound).
    static func range(_ target: StudioAutoTarget) -> ClosedRange<Double> {
        switch target {
        case .volume: return -24.0...6.0   // dB; unity (0) sits near the top
        case .pan: return -1.0...1.0       // full left...right
        }
    }

    /// The value a freshly drawn point defaults to (unity / center).
    static func defaultValue(_ target: StudioAutoTarget) -> Double { 0 }

    static func valueToNorm(_ value: Double, target: StudioAutoTarget) -> Double {
        let r = range(target)
        return min(1, max(0, (value - r.lowerBound) / (r.upperBound - r.lowerBound)))
    }

    static func normToValue(_ norm: Double, target: StudioAutoTarget) -> Double {
        let r = range(target)
        return r.lowerBound + min(1, max(0, norm)) * (r.upperBound - r.lowerBound)
    }

    /// y for a value within a lane spanning [rowY, rowY + height] (top = high).
    static func valueToY(_ value: Double, target: StudioAutoTarget, rowY: CGFloat, height: CGFloat) -> CGFloat {
        rowY + (1 - CGFloat(valueToNorm(value, target: target))) * height
    }

    /// The value for a y within the lane (inverse of `valueToY`), clamped.
    static func yToValue(_ y: CGFloat, target: StudioAutoTarget, rowY: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return normToValue(0, target: target) }
        return normToValue(Double(1 - (y - rowY) / height), target: target)
    }

    /// The nearest breakpoint to a lane-space point within `radiusPx`, if any.
    static func nearestPoint(
        _ points: [StudioAutoPoint],
        target: StudioAutoTarget,
        pxPerTick: CGFloat,
        scrollTicks: Int64,
        rowY: CGFloat,
        height: CGFloat,
        at point: CGPoint,
        radiusPx: CGFloat = 8
    ) -> StudioAutoPoint? {
        var best: (StudioAutoPoint, CGFloat)?
        for p in points {
            let x = StudioTimelineMath.ticksToPx(p.positionTicks, pxPerTick: pxPerTick, scrollTicks: scrollTicks)
            let y = valueToY(p.value, target: target, rowY: rowY, height: height)
            let d = hypot(point.x - x, point.y - y)
            if d <= radiusPx, best == nil || d < best!.1 {
                best = (p, d)
            }
        }
        return best?.0
    }
}

// MARK: - Ruler bands
//
// The arrangement ruler is three stacked bands and the lanes below them. WHICH
// band a press lands in is the entire gesture-coexistence rule for the ruler:
// each band owns exactly one drag, decided by y and nothing else — no modifier
// keys, no press-and-hold, no drag that changes meaning once it travels far
// enough. That rule is a pure function of a y coordinate, so it lives here with
// the rest of the geometry and is unit-tested rather than trapped inside a
// gesture closure.

enum StudioRulerBand: Equatable, Sendable {
    /// Coloured section headers. Drag selects bars (a SELECTION, not a loop).
    case sections
    /// Bar numbers. Drag scrubs the play head.
    case bars
    /// The loop strip. Drag sets the loop brace; a click clears it.
    case loop
    /// Below the ruler: clips, takes, automation.
    case lanes

    /// Total ruler height — the offset every lane calculation subtracts.
    static var rulerHeight: CGFloat {
        StudioTokens.sectionRulerHeight + StudioTokens.barRulerHeight
            + StudioTokens.loopRulerHeight
    }

    /// Top edge of the loop strip.
    static var loopStripY: CGFloat {
        StudioTokens.sectionRulerHeight + StudioTokens.barRulerHeight
    }

    static func at(y: CGFloat) -> StudioRulerBand {
        if y < StudioTokens.sectionRulerHeight { return .sections }
        if y < loopStripY { return .bars }
        if y < rulerHeight { return .loop }
        return .lanes
    }
}
