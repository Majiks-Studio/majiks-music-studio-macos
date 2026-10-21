import Foundation
import CoreGraphics

// MARK: - Piano roll: note model + pure geometry / interaction math
//
// Pure value types and pure functions ONLY. No SwiftUI, no engine, no side
// effects — everything in this file is unit-tested (StudioPianoRollMathTests),
// which is where piano-roll bugs actually live (off-by-one snapping, a resize
// that eats a note, a multi-note drag that loses its relative offsets).
//
// The house discipline from StudioTimelineMath applies: ONE function produces a
// geometry, and both drawing and hit-testing call it, so they can never
// disagree.

// MARK: - Note (mirrors engine `Note`, DESIGN-E1-E2 §1)

/// One MIDI note on a note-backed clip.
///
/// Field-for-field the Swift mirror of the engine's `Note`. Deliberate choices,
/// per the seam spec:
///   * `id` is a `String` (ULID-shaped), NOT a UUID — stable identity across
///     edit + undo, minted UI-side the same way automation point ids are.
///   * `startTicks` / `lengthTicks` are CLIP-RELATIVE, in the 960-PPQ integer
///     tick domain. Pixels exist only at the view edge.
///   * `velocity` is an `Int` 0...127, never a Float. The engine's `Num`
///     preserves integer/float SHAPE and the journal hash chain depends on it,
///     so the UI must not turn 100 into 100.0 on the way out.
struct StudioNote: Identifiable, Sendable, Equatable, Hashable {
    var id: String
    var startTicks: Int64
    var lengthTicks: Int64
    var pitch: UInt8            // 0...127
    var velocity: Int           // 0...127, integer shape on the wire

    var endTicks: Int64 { startTicks + lengthTicks }

    init(id: String, startTicks: Int64, lengthTicks: Int64, pitch: UInt8, velocity: Int = 100) {
        self.id = id
        self.startTicks = startTicks
        self.lengthTicks = max(1, lengthTicks)          // zero-length is rejected at apply time
        // UInt8 reaches 255; MIDI stops at 127. Clamp here so an out-of-range
        // pitch can never reach the journal.
        self.pitch = StudioNote.clampPitch(Int(pitch))
        self.velocity = StudioNote.clampVelocity(velocity)
    }

    static func clampVelocity(_ v: Int) -> Int { min(127, max(0, v)) }
    static func clampPitch(_ p: Int) -> UInt8 { UInt8(min(127, max(0, p))) }

    /// The engine's total, deterministic order: `(start_ticks, pitch, id)`.
    /// Nondeterministic ordering changes serialized bytes, so the UI sorts the
    /// same way the engine does and never relies on incidental array order.
    static func isOrderedBefore(_ a: StudioNote, _ b: StudioNote) -> Bool {
        if a.startTicks != b.startTicks { return a.startTicks < b.startTicks }
        if a.pitch != b.pitch { return a.pitch < b.pitch }
        return a.id < b.id
    }

    static func sorted(_ notes: [StudioNote]) -> [StudioNote] {
        notes.sorted(by: isOrderedBefore)
    }
}

/// Pitch naming for the keyboard gutter and accessibility labels.
enum StudioPitchName {
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// True for the black keys (C#, D#, F#, G#, A#).
    static func isAccidental(_ pitch: UInt8) -> Bool {
        [1, 3, 6, 8, 10].contains(Int(pitch) % 12)
    }

    /// "C3" with MIDI 60 = C3 (Ableton / Yamaha convention, which Majik's DJ and
    /// the Studio transport readout already use).
    static func label(_ pitch: UInt8) -> String {
        let octave = Int(pitch) / 12 - 2
        return "\(names[Int(pitch) % 12])\(octave)"
    }

    /// True when this pitch is a C — the octave line the gutter labels.
    static func isOctaveRoot(_ pitch: UInt8) -> Bool { Int(pitch) % 12 == 0 }
}

// MARK: - Grid divisions

/// Piano-roll snap divisions. A DAW piano roll needs more than the arrangement's
/// bar/beat/16th: straight divisions down to a 32nd, plus triplets (Ableton
/// parity). Every value is an exact integer at 960 PPQ, so snapping never
/// accumulates float error.
enum StudioNoteGrid: String, CaseIterable, Sendable, Hashable {
    case off
    case bar
    case half
    case quarter
    case eighth
    case sixteenth
    case thirtySecond
    case eighthTriplet
    case sixteenthTriplet

    /// A whole note in ticks (4 quarters at PPQ).
    static var wholeTicks: Int64 { StudioTick.ppq * 4 }

    /// Grid step in ticks, or nil when snapping is off. `bar` depends on the
    /// time signature; everything else is an absolute note value.
    func ticks(_ sig: StudioTimeSignature) -> Int64? {
        switch self {
        case .off: return nil
        case .bar: return sig.ticksPerBar
        case .half: return Self.wholeTicks / 2                 // 1920
        case .quarter: return Self.wholeTicks / 4              // 960
        case .eighth: return Self.wholeTicks / 8               // 480
        case .sixteenth: return Self.wholeTicks / 16           // 240
        case .thirtySecond: return Self.wholeTicks / 32        // 120
        case .eighthTriplet: return Self.wholeTicks / 12        // 320
        case .sixteenthTriplet: return Self.wholeTicks / 24     // 160
        }
    }

    /// The length a freshly drawn note gets at this grid (a quarter when off).
    func defaultNoteLengthTicks(_ sig: StudioTimeSignature) -> Int64 {
        ticks(sig) ?? (Self.wholeTicks / 4)
    }

    var label: String {
        switch self {
        case .off: return "Off"
        case .bar: return "Bar"
        case .half: return "1/2"
        case .quarter: return "1/4"
        case .eighth: return "1/8"
        case .sixteenth: return "1/16"
        case .thirtySecond: return "1/32"
        case .eighthTriplet: return "1/8T"
        case .sixteenthTriplet: return "1/16T"
        }
    }

    /// Coarse -> fine order used by the `[` / `]` shortcuts. Triplets sit next
    /// to the straight value they subdivide against.
    static let ladder: [StudioNoteGrid] = [
        .bar, .half, .quarter, .eighthTriplet, .eighth, .sixteenthTriplet, .sixteenth, .thirtySecond,
    ]

    func finer() -> StudioNoteGrid {
        guard let i = Self.ladder.firstIndex(of: self) else { return .sixteenth }
        return Self.ladder[min(i + 1, Self.ladder.count - 1)]
    }

    func coarser() -> StudioNoteGrid {
        guard let i = Self.ladder.firstIndex(of: self) else { return .quarter }
        return Self.ladder[max(i - 1, 0)]
    }
}

// MARK: - Bar grid (BEAT-TRACKED, not naive BPM math)
//
// Generated audio drifts 1.2-2.9% off its declared BPM, so the project's bar
// lines come from the beat tracker, not from arithmetic on a nominal tempo.
// Two things carry that truth:
//
//   1. `phaseAnchorTicks` — the project's bar-grid phase anchor (engine
//      `project.setPhaseAnchor`, `project.schema.json:phaseAnchorTicks`). Bar 1
//      begins at the FIRST TRACKED DOWNBEAT, not at tick 0. Any grid that draws
//      bars at `n * ticksPerBar` is off by the lead-in for every landed song.
//   2. `downbeatTicks` — an explicit tracked downbeat list, for material whose
//      bars are not uniformly spaced in the tick domain. When it is present it
//      WINS; when it is empty the uniform phase-anchored grid applies.
//
// Everything the piano roll snaps or draws goes through this type. There is no
// second path.
struct StudioBarGrid: Equatable, Sendable {
    var timeSignature: StudioTimeSignature
    /// Ticks the bar grid is shifted by so the first tracked downbeat lands on a
    /// bar line. 0 is the v1 behaviour (no lead-in).
    var phaseAnchorTicks: Int64
    /// Explicit tracked downbeats (absolute ticks, ascending). Empty = uniform.
    var downbeatTicks: [Int64]

    init(
        timeSignature: StudioTimeSignature = .fourFour,
        phaseAnchorTicks: Int64 = 0,
        downbeatTicks: [Int64] = []
    ) {
        self.timeSignature = timeSignature
        self.phaseAnchorTicks = max(0, phaseAnchorTicks)
        self.downbeatTicks = downbeatTicks.sorted()
    }

    var ticksPerBar: Int64 { timeSignature.ticksPerBar }
    var ticksPerBeat: Int64 { timeSignature.ticksPerBeat }

    /// The start tick of the bar containing `ticks` (the bar that begins at or
    /// before it). Before the phase anchor the grid extends backwards at the
    /// same spacing, so a lead-in still shows bar lines rather than a void.
    func barStart(containing ticks: Int64) -> Int64 {
        if !downbeatTicks.isEmpty {
            // Last downbeat <= ticks; before the first, extrapolate backwards at
            // the first measured bar length so the lead-in is still gridded.
            var lo = 0, hi = downbeatTicks.count - 1, found = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if downbeatTicks[mid] <= ticks { found = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            if found >= 0 {
                // Past the last tracked downbeat: continue at the last spacing.
                if found == downbeatTicks.count - 1, downbeatTicks.count >= 2 {
                    let span = max(1, downbeatTicks[found] - downbeatTicks[found - 1])
                    let over = ticks - downbeatTicks[found]
                    return downbeatTicks[found] + (over / span) * span
                }
                return downbeatTicks[found]
            }
            let first = downbeatTicks[0]
            let span = downbeatTicks.count >= 2 ? max(1, downbeatTicks[1] - first) : ticksPerBar
            let behind = first - ticks
            return first - ((behind + span - 1) / span) * span
        }
        let rel = ticks - phaseAnchorTicks
        let floored = rel >= 0 ? (rel / ticksPerBar) : ((rel - ticksPerBar + 1) / ticksPerBar)
        return phaseAnchorTicks + floored * ticksPerBar
    }

    /// Length in ticks of the bar containing `ticks` (constant for a uniform
    /// grid; measured for a tracked one).
    func barLength(containing ticks: Int64) -> Int64 {
        guard !downbeatTicks.isEmpty else { return ticksPerBar }
        let start = barStart(containing: ticks)
        if let next = downbeatTicks.first(where: { $0 > start }) { return max(1, next - start) }
        if downbeatTicks.count >= 2 {
            let n = downbeatTicks.count
            return max(1, downbeatTicks[n - 1] - downbeatTicks[n - 2])
        }
        return ticksPerBar
    }

    /// 1-based bar number for the ruler (bar 1 begins at the phase anchor).
    func barNumber(at ticks: Int64) -> Int {
        if !downbeatTicks.isEmpty {
            let start = barStart(containing: ticks)
            if let idx = downbeatTicks.firstIndex(of: start) { return idx + 1 }
            // Extrapolated bar outside the tracked list.
            if let first = downbeatTicks.first, start < first {
                let span = downbeatTicks.count >= 2 ? max(1, downbeatTicks[1] - first) : ticksPerBar
                return 1 - Int((first - start) / span)
            }
            let last = downbeatTicks[downbeatTicks.count - 1]
            let span = barLength(containing: ticks)
            return downbeatTicks.count + Int((start - last) / span)
        }
        let rel = ticks - phaseAnchorTicks
        let floored = rel >= 0 ? (rel / ticksPerBar) : ((rel - ticksPerBar + 1) / ticksPerBar)
        return Int(floored) + 1
    }

    /// Start tick of the bar with 0-based `index` (so index 0 is bar 1, which
    /// begins at the phase anchor). The exact inverse of `barNumber(at:)`:
    /// `barNumber(at: tickForBarIndex(i)) == i + 1`. Negative indices address
    /// the lead-in before bar 1.
    func tickForBarIndex(_ index: Int64) -> Int64 {
        guard !downbeatTicks.isEmpty else {
            return phaseAnchorTicks + index * ticksPerBar
        }
        if index >= 0, index < Int64(downbeatTicks.count) {
            return downbeatTicks[Int(index)]
        }
        if index < 0 {
            let first = downbeatTicks[0]
            let span = downbeatTicks.count >= 2
                ? max(1, downbeatTicks[1] - first) : ticksPerBar
            return first + index * span
        }
        // Past the tracked list: continue at the last measured spacing.
        let n = downbeatTicks.count
        let last = downbeatTicks[n - 1]
        let span = n >= 2 ? max(1, last - downbeatTicks[n - 2]) : ticksPerBar
        return last + (index - Int64(n - 1)) * span
    }

    /// Every bar line in `range`, inclusive. Ascending; safe on an empty range.
    func barLines(in range: ClosedRange<Int64>) -> [Int64] {
        var out: [Int64] = []
        var t = barStart(containing: range.lowerBound)
        var guardCount = 0
        while t <= range.upperBound, guardCount < 100_000 {
            if t >= range.lowerBound { out.append(t) }
            t += barLength(containing: t)
            guardCount += 1
        }
        return out
    }

    /// Every grid line at `division` in `range`, phase-aligned to the bar grid.
    /// Subdivisions are measured FROM THE BAR LINE, so the phase anchor
    /// propagates all the way down to a 32nd.
    func gridLines(in range: ClosedRange<Int64>, division: StudioNoteGrid) -> [Int64] {
        guard let step = division.ticks(timeSignature), step > 0 else { return [] }
        if division == .bar { return barLines(in: range) }
        var out: [Int64] = []
        var bar = barStart(containing: range.lowerBound)
        var guardCount = 0
        while bar <= range.upperBound, guardCount < 100_000 {
            let length = barLength(containing: bar)
            var t = bar
            while t < bar + length {
                if t >= range.lowerBound, t <= range.upperBound { out.append(t) }
                t += step
            }
            bar += length
            guardCount += 1
        }
        return out
    }

    /// Snap `ticks` to the nearest line of `division`, measured from the bar it
    /// falls in. `division == .off` passes through untouched.
    ///
    /// This is a HARD snap (Ableton parity: the grid is authoritative, and the
    /// bypass modifier — not a distance threshold — is how you land off-grid).
    func snap(_ ticks: Int64, division: StudioNoteGrid) -> Int64 {
        guard let step = division.ticks(timeSignature), step > 0 else { return ticks }
        if division == .bar {
            let start = barStart(containing: ticks)
            let length = barLength(containing: ticks)
            let next = start + length
            return (ticks - start) * 2 <= (next - ticks) * 2 ? start : next
        }
        let start = barStart(containing: ticks)
        let rel = ticks - start
        let down = rel >= 0 ? (rel / step) * step : ((rel - step + 1) / step) * step
        let up = down + step
        return start + ((rel - down) <= (up - rel) ? down : up)
    }

    /// Snap honoring a live bypass modifier (Command, Ableton parity).
    func snap(_ ticks: Int64, division: StudioNoteGrid, bypass: Bool) -> Int64 {
        bypass ? ticks : snap(ticks, division: division)
    }
}

// MARK: - Tempo map (tick <-> seconds; NEVER `ticks / ppq * 60 / bpm`)
//
// The bar grid above fixes WHERE bars are in the tick domain. This fixes how
// ticks map to wall-clock seconds — which is what the play head needs. A single
// nominal BPM is a lie for landed generative audio (1.2-2.9% drift, and a song
// that speeds up mid-take drifts further every bar). A piecewise map is exact,
// and it degrades to the naive answer when there is only one segment, so the
// call site never needs to branch.
struct StudioTempoSegment: Equatable, Sendable {
    /// First tick of the segment.
    var startTicks: Int64
    /// Wall-clock seconds at `startTicks`.
    var startSeconds: Double
    /// Tempo held across the segment.
    var bpm: Double
}

struct StudioTempoMap: Equatable, Sendable {
    /// Ascending by `startTicks`; the first segment must start at 0.
    private(set) var segments: [StudioTempoSegment]

    init(segments: [StudioTempoSegment]) {
        let sorted = segments.filter { $0.bpm > 0 }.sorted { $0.startTicks < $1.startTicks }
        self.segments = sorted.isEmpty ? [StudioTempoSegment(startTicks: 0, startSeconds: 0, bpm: 120)] : sorted
    }

    /// The degenerate one-segment map: identical to naive BPM math, by design.
    static func constant(bpm: Double) -> StudioTempoMap {
        StudioTempoMap(segments: [
            StudioTempoSegment(startTicks: 0, startSeconds: 0, bpm: bpm > 0 ? bpm : 120)
        ])
    }

    /// Build a continuous map from tempo changes given as (tick, bpm), filling
    /// in each segment's start time by integrating the ones before it.
    static func from(changes: [(ticks: Int64, bpm: Double)]) -> StudioTempoMap {
        let sorted = changes.filter { $0.bpm > 0 }.sorted { $0.ticks < $1.ticks }
        guard let first = sorted.first else { return .constant(bpm: 120) }
        var segments: [StudioTempoSegment] = []
        var seconds = 0.0
        var previous: (ticks: Int64, bpm: Double) = (0, first.bpm)
        for change in sorted {
            if change.ticks > previous.ticks {
                seconds += Self.duration(ticks: change.ticks - previous.ticks, bpm: previous.bpm)
            }
            segments.append(StudioTempoSegment(
                startTicks: max(0, change.ticks), startSeconds: seconds, bpm: change.bpm))
            previous = (change.ticks, change.bpm)
        }
        if segments.first?.startTicks != 0 {
            segments.insert(
                StudioTempoSegment(startTicks: 0, startSeconds: 0, bpm: first.bpm), at: 0)
        }
        return StudioTempoMap(segments: segments)
    }

    private static func duration(ticks: Int64, bpm: Double) -> Double {
        Double(ticks) / Double(StudioTick.ppq) * 60.0 / bpm
    }

    private func segment(atTicks ticks: Int64) -> StudioTempoSegment {
        var chosen = segments[0]
        for s in segments where s.startTicks <= ticks { chosen = s }
        return chosen
    }

    private func segment(atSeconds seconds: Double) -> StudioTempoSegment {
        var chosen = segments[0]
        for s in segments where s.startSeconds <= seconds { chosen = s }
        return chosen
    }

    func seconds(atTicks ticks: Int64) -> Double {
        let s = segment(atTicks: ticks)
        return s.startSeconds + Self.duration(ticks: ticks - s.startTicks, bpm: s.bpm)
    }

    func ticks(atSeconds seconds: Double) -> Int64 {
        let s = segment(atSeconds: seconds)
        let delta = (seconds - s.startSeconds) * s.bpm / 60.0 * Double(StudioTick.ppq)
        return s.startTicks + Int64(delta.rounded())
    }

    /// Play-head advance: where the transport is `elapsed` seconds after it
    /// reported `positionTicks`. Goes out and back through the map, so a tempo
    /// change inside the elapsed window is honored instead of smeared.
    func advanced(fromTicks positionTicks: Int64, bySeconds elapsed: Double) -> Int64 {
        guard elapsed > 0 else { return positionTicks }
        return ticks(atSeconds: seconds(atTicks: positionTicks) + elapsed)
    }

    /// Tempo in force at a tick (for readouts).
    func bpm(atTicks ticks: Int64) -> Double { segment(atTicks: ticks).bpm }
}

// MARK: - Layout / geometry
//
// One layout value describes the whole surface. Drawing, hit-testing, culling
// and the marquee all read it, so they cannot disagree — the same rule the
// arrangement's StudioRowLayoutBuilder enforces on the vertical axis.

struct StudioPianoRollLayout: Equatable, Sendable {
    /// Horizontal zoom.
    var pxPerTick: CGFloat
    /// Vertical zoom: height of one semitone row.
    var rowHeight: CGFloat
    /// Absolute tick at the left edge of the note area.
    var scrollTicks: Int64
    /// Pixels scrolled down from the top of pitch 127.
    var scrollY: CGFloat
    /// Width of the keyboard gutter on the left.
    var gutterWidth: CGFloat
    /// Height of the bar ruler on top.
    var rulerHeight: CGFloat
    /// Height of the velocity lane at the bottom (0 when hidden).
    var velocityLaneHeight: CGFloat
    /// Full view size.
    var size: CGSize

    static let minRowHeight: CGFloat = 6        // a row must stay mouse-able
    static let maxRowHeight: CGFloat = 40
    static let defaultRowHeight: CGFloat = 13
    static let pitchCount = 128

    static func clampRowHeight(_ h: CGFloat) -> CGFloat {
        min(max(h, minRowHeight), maxRowHeight)
    }

    /// Horizontal zoom limits: the arrangement's, shifted up — a piano roll is
    /// used far closer in than an arrangement.
    static let minPxPerTick: CGFloat = 12.0 / CGFloat(StudioTick.ppq * 4)   // ~12 px per 4/4 bar
    static let maxPxPerTick: CGFloat = 600.0 / CGFloat(StudioTick.ppq)      // 600 px per quarter

    static func clampPxPerTick(_ v: CGFloat) -> CGFloat {
        min(max(v, minPxPerTick), maxPxPerTick)
    }

    /// The note area: everything right of the gutter, below the ruler, above the
    /// velocity lane.
    var noteRect: CGRect {
        CGRect(
            x: gutterWidth,
            y: rulerHeight,
            width: max(0, size.width - gutterWidth),
            height: max(0, size.height - rulerHeight - velocityLaneHeight))
    }

    var rulerRect: CGRect {
        CGRect(x: gutterWidth, y: 0, width: max(0, size.width - gutterWidth), height: rulerHeight)
    }

    var gutterRect: CGRect {
        CGRect(x: 0, y: rulerHeight, width: gutterWidth, height: noteRect.height)
    }

    var velocityRect: CGRect {
        CGRect(
            x: gutterWidth, y: size.height - velocityLaneHeight,
            width: max(0, size.width - gutterWidth), height: velocityLaneHeight)
    }

    /// Total scrollable pitch content height.
    var contentHeight: CGFloat { CGFloat(Self.pitchCount) * rowHeight }

    var maxScrollY: CGFloat { max(0, contentHeight - noteRect.height) }

    // MARK: Tick <-> x

    func x(forTicks ticks: Int64) -> CGFloat {
        noteRect.minX + CGFloat(ticks - scrollTicks) * pxPerTick
    }

    func ticks(forX x: CGFloat) -> Int64 {
        guard pxPerTick > 0 else { return scrollTicks }
        return scrollTicks + Int64(((x - noteRect.minX) / pxPerTick).rounded(.down))
    }

    /// Tick span visible in the note area, padded a tick either side so a note
    /// straddling the edge still draws.
    var visibleTickRange: ClosedRange<Int64> {
        guard pxPerTick > 0 else { return scrollTicks...scrollTicks }
        let span = Int64((noteRect.width / pxPerTick).rounded(.up)) + 1
        return scrollTicks...(scrollTicks + max(1, span))
    }

    // MARK: Pitch <-> y
    //
    // Pitch 127 sits at the top; y grows downwards as pitch falls, which is what
    // a keyboard on its side looks like.

    func y(forPitch pitch: UInt8) -> CGFloat {
        noteRect.minY + CGFloat(127 - Int(pitch)) * rowHeight - scrollY
    }

    /// The pitch whose row contains `y`, or nil when `y` is outside 0...127.
    func pitch(forY y: CGFloat) -> UInt8? {
        guard rowHeight > 0 else { return nil }
        let row = Int(((y - noteRect.minY + scrollY) / rowHeight).rounded(.down))
        let pitch = 127 - row
        guard pitch >= 0, pitch <= 127 else { return nil }
        return UInt8(pitch)
    }

    /// Like `pitch(forY:)` but clamped into range — used mid-drag, where the
    /// cursor may leave the surface and the gesture must stay live.
    func clampedPitch(forY y: CGFloat) -> UInt8 {
        guard rowHeight > 0 else { return 60 }
        let row = Int(((y - noteRect.minY + scrollY) / rowHeight).rounded(.down))
        return StudioNote.clampPitch(127 - row)
    }

    /// Pitches whose rows intersect the note area (top-down, high to low).
    var visiblePitchRange: ClosedRange<UInt8> {
        guard rowHeight > 0 else { return 0...127 }
        let topRow = Int((scrollY / rowHeight).rounded(.down))
        let rows = Int((noteRect.height / rowHeight).rounded(.up)) + 1
        let high = StudioNote.clampPitch(127 - topRow)
        let low = StudioNote.clampPitch(127 - (topRow + rows))
        return low...high
    }

    // MARK: Note rectangles

    /// The on-screen rect of a note. `clipOriginTicks` is the clip's absolute
    /// start, because note ticks are clip-relative but the ruler, grid and play
    /// head are absolute.
    func rect(for note: StudioNote, clipOriginTicks: Int64) -> CGRect {
        let x0 = x(forTicks: clipOriginTicks + note.startTicks)
        let width = max(StudioPianoRollGeometry.minDrawnNoteWidth, CGFloat(note.lengthTicks) * pxPerTick)
        return CGRect(x: x0, y: y(forPitch: note.pitch), width: width, height: rowHeight)
    }

    /// Whether a note's rect intersects the visible note area (the cull test).
    func isVisible(_ note: StudioNote, clipOriginTicks: Int64) -> Bool {
        let range = visibleTickRange
        let start = clipOriginTicks + note.startTicks
        let end = clipOriginTicks + note.endTicks
        guard end >= range.lowerBound, start <= range.upperBound else { return false }
        let pitches = visiblePitchRange
        return note.pitch >= pitches.lowerBound && note.pitch <= pitches.upperBound
    }

    /// Notes to draw this frame, in engine order, culled to the viewport.
    /// Culling is what keeps a 5,000-note clip at the same frame cost as a
    /// 50-note one.
    func culled(_ notes: [StudioNote], clipOriginTicks: Int64) -> [StudioNote] {
        notes.filter { isVisible($0, clipOriginTicks: clipOriginTicks) }
    }

    // MARK: Velocity lane

    /// y of a velocity stem's top within the velocity lane.
    func velocityY(_ velocity: Int) -> CGFloat {
        let lane = velocityRect
        let norm = CGFloat(StudioNote.clampVelocity(velocity)) / 127.0
        return lane.maxY - norm * (lane.height - 4) - 2
    }

    /// The velocity a y within the lane represents (clamped 0...127).
    func velocity(forY y: CGFloat) -> Int {
        let lane = velocityRect
        guard lane.height > 4 else { return 0 }
        let norm = (lane.maxY - 2 - y) / (lane.height - 4)
        return StudioNote.clampVelocity(Int((norm * 127).rounded()))
    }
}

// MARK: - Hit testing
//
// THE HIT-TESTING RULE for this surface: there are NO child views to hit. The
// grid, the notes, the gutter keys and the velocity stems are all drawn into one
// Canvas, and every "click on a thing" is answered by the functions below from
// the same layout the drawing used. Nothing here can be eaten by a scroll view,
// collapsed to a glyph outline, or swallowed by a decorative overlay, because
// none of those participate.

enum StudioNoteHitZone: Equatable, Sendable {
    case body
    case leadingEdge
    case trailingEdge
}

struct StudioNoteHit: Equatable, Sendable {
    var noteID: String
    var zone: StudioNoteHitZone
}

enum StudioPianoRollGeometry {
    /// A note narrower than this still draws (and stays grabbable) at this width.
    static let minDrawnNoteWidth: CGFloat = 3

    /// How far outside its drawn rect a note still answers the mouse. Small
    /// notes live or die on this: a 4 px note with no outward margin is
    /// unhittable in practice.
    static let outwardGrabPx: CGFloat = 3

    /// Minimum width of a resize grab zone. Below ~5 pt a resize edge reads as
    /// broken — you aim at it and get a move instead. This is the constant that
    /// three previous hit-testing bugs in this app came down to.
    static let minEdgeGrabPx: CGFloat = 5
    static let maxEdgeGrabPx: CGFloat = 9

    /// Under this drawn width a note gets ONE edge (trailing) instead of two, so
    /// there is always somewhere left to grab for a move. Resize-right is the
    /// common gesture; resize-left on a sliver is what zooming is for.
    static let twoEdgeMinWidth: CGFloat = 15

    /// Width of each resize grab zone for a note drawn `w` px wide.
    static func edgeGrabWidth(noteWidthPx w: CGFloat) -> CGFloat {
        max(minEdgeGrabPx, min(maxEdgeGrabPx, w / 3))
    }

    /// The zone of a single note under `point`, or nil when the point misses it.
    /// The rect is expanded outward first, so the boundary is forgiving in both
    /// axes.
    static func zone(in rect: CGRect, at point: CGPoint) -> StudioNoteHitZone? {
        let hit = rect.insetBy(dx: -outwardGrabPx, dy: -1)
        guard hit.contains(point) else { return nil }
        let grab = edgeGrabWidth(noteWidthPx: rect.width)
        if point.x >= rect.maxX - grab { return .trailingEdge }
        if rect.width >= twoEdgeMinWidth, point.x <= rect.minX + grab { return .leadingEdge }
        if rect.width < twoEdgeMinWidth, point.x >= rect.midX { return .trailingEdge }
        return .body
    }

    /// The note under `point`, preferring the selected notes (so a drag that
    /// starts on an overlapping stack keeps hold of what you already picked),
    /// then the topmost drawn note.
    static func hitTest(
        _ notes: [StudioNote],
        selected: Set<String>,
        layout: StudioPianoRollLayout,
        clipOriginTicks: Int64,
        at point: CGPoint
    ) -> StudioNoteHit? {
        var fallback: StudioNoteHit?
        // Reverse engine order = topmost drawn first.
        for note in notes.reversed() {
            let rect = layout.rect(for: note, clipOriginTicks: clipOriginTicks)
            guard let zone = zone(in: rect, at: point) else { continue }
            let hit = StudioNoteHit(noteID: note.id, zone: zone)
            if selected.contains(note.id) { return hit }
            if fallback == nil { fallback = hit }
        }
        return fallback
    }

    /// Notes whose rects intersect a marquee rect.
    static func marqueeHits(
        _ notes: [StudioNote],
        layout: StudioPianoRollLayout,
        clipOriginTicks: Int64,
        rect: CGRect
    ) -> Set<String> {
        var out: Set<String> = []
        for note in notes {
            if layout.rect(for: note, clipOriginTicks: clipOriginTicks).intersects(rect) {
                out.insert(note.id)
            }
        }
        return out
    }

    /// Normalized marquee rect from a drag's two points.
    static func marqueeRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The velocity stem under `point` in the velocity lane (stems are thin, so
    /// the grab zone is by x-proximity to the note's start, not by the drawn
    /// 2 px stem).
    static func velocityHit(
        _ notes: [StudioNote],
        selected: Set<String>,
        layout: StudioPianoRollLayout,
        clipOriginTicks: Int64,
        at point: CGPoint,
        grabPx: CGFloat = 6
    ) -> String? {
        guard layout.velocityRect.insetBy(dx: 0, dy: -2).contains(point) else { return nil }
        var best: (String, CGFloat)?
        for note in notes {
            let x = layout.x(forTicks: clipOriginTicks + note.startTicks)
            let d = abs(point.x - x)
            guard d <= grabPx else { continue }
            // A selected stem wins ties so a group velocity drag stays on target.
            let score = selected.contains(note.id) ? d - grabPx : d
            if best == nil || score < best!.1 { best = (note.id, score) }
        }
        return best?.0
    }

    /// The pitch of the gutter key under `point`, or nil when the point is not
    /// in the gutter. (Keys are DRAWN, not Buttons — see the file header.)
    static func gutterKey(layout: StudioPianoRollLayout, at point: CGPoint) -> UInt8? {
        guard layout.gutterRect.contains(point) else { return nil }
        return layout.pitch(forY: point.y)
    }
}

// MARK: - Edit math
//
// Every edit is expressed as a DELTA computed once from the drag anchor, then
// applied to the whole selection. That is what preserves relative offsets: a
// chord dragged up a third stays a chord. Clamping is likewise computed over the
// whole group — clamping each note independently is the classic bug that
// collapses a chord onto the bottom of the roll when one voice hits pitch 0.

enum StudioNoteEdit {
    /// Shortest note the UI will produce or leave behind (a 32nd at 960 PPQ).
    static let minLengthTicks: Int64 = StudioNoteGrid.wholeTicks / 32

    // MARK: Move

    struct MoveDelta: Equatable, Sendable {
        var ticks: Int64
        var pitch: Int
    }

    /// The move delta for a drag, clamped over the WHOLE selection.
    ///
    /// - `proposedAnchorStart` is where the anchor note's start wants to be
    ///   (already snapped by the caller, so the anchor lands exactly on the grid
    ///   and every other note keeps its offset from it).
    /// - `clipLengthTicks == 0` means "no right-hand bound" (an unbounded clip).
    static func moveDelta(
        notes: [StudioNote],
        anchorID: String,
        proposedAnchorStart: Int64,
        proposedAnchorPitch: UInt8,
        clipLengthTicks: Int64
    ) -> MoveDelta {
        guard let anchor = notes.first(where: { $0.id == anchorID }), !notes.isEmpty else {
            return MoveDelta(ticks: 0, pitch: 0)
        }
        var dTicks = proposedAnchorStart - anchor.startTicks
        var dPitch = Int(proposedAnchorPitch) - Int(anchor.pitch)

        let minStart = notes.map(\.startTicks).min() ?? 0
        let maxEnd = notes.map(\.endTicks).max() ?? 0
        dTicks = max(dTicks, -minStart)
        if clipLengthTicks > 0 { dTicks = min(dTicks, clipLengthTicks - maxEnd) }

        let minPitch = Int(notes.map(\.pitch).min() ?? 0)
        let maxPitch = Int(notes.map(\.pitch).max() ?? 127)
        dPitch = max(dPitch, -minPitch)
        dPitch = min(dPitch, 127 - maxPitch)

        return MoveDelta(ticks: dTicks, pitch: dPitch)
    }

    static func applyMove(_ notes: [StudioNote], delta: MoveDelta) -> [StudioNote] {
        notes.map { note in
            var out = note
            out.startTicks = note.startTicks + delta.ticks
            out.pitch = StudioNote.clampPitch(Int(note.pitch) + delta.pitch)
            return out
        }
    }

    // MARK: Resize

    enum Edge: Equatable, Sendable { case leading, trailing }

    /// The resize delta for a drag, clamped over the whole selection so no note
    /// in the group can be squeezed below `minLengthTicks` or pushed out of the
    /// clip. Applying it to a single note is the same code path.
    ///
    /// `proposedAnchorEdge` is where the dragged EDGE of the anchor note wants
    /// to be (already snapped).
    static func resizeDelta(
        notes: [StudioNote],
        anchorID: String,
        edge: Edge,
        proposedAnchorEdge: Int64,
        clipLengthTicks: Int64,
        minLengthTicks: Int64 = minLengthTicks
    ) -> Int64 {
        guard let anchor = notes.first(where: { $0.id == anchorID }), !notes.isEmpty else { return 0 }
        let shortest = notes.map(\.lengthTicks).min() ?? minLengthTicks
        switch edge {
        case .trailing:
            var delta = proposedAnchorEdge - anchor.endTicks
            // No note may fall below the minimum length.
            delta = max(delta, minLengthTicks - shortest)
            if clipLengthTicks > 0 {
                let maxEnd = notes.map(\.endTicks).max() ?? 0
                delta = min(delta, clipLengthTicks - maxEnd)
            }
            return delta
        case .leading:
            var delta = proposedAnchorEdge - anchor.startTicks
            let minStart = notes.map(\.startTicks).min() ?? 0
            delta = max(delta, -minStart)                    // never before the clip start
            delta = min(delta, shortest - minLengthTicks)    // never shorter than the minimum
            return delta
        }
    }

    static func applyResize(_ notes: [StudioNote], edge: Edge, delta: Int64) -> [StudioNote] {
        notes.map { note in
            var out = note
            switch edge {
            case .trailing:
                out.lengthTicks = max(1, note.lengthTicks + delta)
            case .leading:
                out.startTicks = note.startTicks + delta
                out.lengthTicks = max(1, note.lengthTicks - delta)
            }
            return out
        }
    }

    // MARK: Velocity

    /// Clamped group velocity delta: the whole selection shifts together and
    /// stops as one when any member reaches 0 or 127, so relative dynamics
    /// survive the drag.
    static func velocityDelta(notes: [StudioNote], proposedAnchorVelocity: Int, anchorID: String) -> Int {
        guard let anchor = notes.first(where: { $0.id == anchorID }), !notes.isEmpty else { return 0 }
        var delta = StudioNote.clampVelocity(proposedAnchorVelocity) - anchor.velocity
        let lowest = notes.map(\.velocity).min() ?? 0
        let highest = notes.map(\.velocity).max() ?? 127
        delta = max(delta, -lowest)
        delta = min(delta, 127 - highest)
        return delta
    }

    static func applyVelocity(_ notes: [StudioNote], delta: Int) -> [StudioNote] {
        notes.map { note in
            var out = note
            out.velocity = StudioNote.clampVelocity(note.velocity + delta)
            return out
        }
    }

    // MARK: Quantize

    /// How far one ABSOLUTE tick position travels toward its grid line.
    ///
    /// This is a mirror of `timeline-core/src/apply.rs::quantize_shift`, and it
    /// has to stay one: `StudioMockNoteEngine` uses it to apply the command the
    /// UI sends, so if the two drifted apart every test would still pass while
    /// the shipping app moved notes somewhere else. Three properties, same as
    /// the Rust:
    ///
    ///   1. Anchored on the project's bar-grid PHASE, not on tick 0. A landed
    ///      generative song's bar 1 starts partway into the timeline; lines
    ///      measured from zero are not where its beats are.
    ///   2. Integer-only. The engine's copy is replayed from the journal, and a
    ///      float multiply is not guaranteed to round identically across
    ///      builds. Ties go to the LATER line; the strength scaling rounds half
    ///      away from zero.
    ///   3. Strength-proportional, so 0% is an exact no-op rather than a nudge.
    static func quantizeShift(
        position: Int64,
        anchor: Int64,
        gridTicks: Int64,
        strengthPercent: Int
    ) -> Int64 {
        guard gridTicks > 0 else { return 0 }
        let strength = Int64(min(100, max(0, strengthPercent)))
        let rel = position - anchor
        // Swift's `/` truncates toward zero, so a negative `rel` needs the
        // floor form or the note above the anchor and the note below it would
        // round in opposite directions.
        var below = (rel / gridTicks) * gridTicks
        if rel < 0, below != rel { below -= gridTicks }
        let remainder = rel - below
        let target = remainder * 2 >= gridTicks ? below + gridTicks : below
        let full = target - rel
        let scaled = full * strength
        return scaled >= 0 ? (scaled + 50) / 100 : -((-scaled + 50) / 100)
    }

    // MARK: Duplicate

    /// Where a Cmd-D duplicate lands: one selection-length to the right, rounded
    /// up to the grid so the copy stays in time. Ableton's behaviour.
    static func duplicateOffsetTicks(
        _ notes: [StudioNote],
        grid: StudioNoteGrid,
        timeSignature: StudioTimeSignature
    ) -> Int64 {
        guard let minStart = notes.map(\.startTicks).min(),
              let maxEnd = notes.map(\.endTicks).max(), maxEnd > minStart else { return 0 }
        let span = maxEnd - minStart
        guard let step = grid.ticks(timeSignature), step > 0 else { return span }
        return ((span + step - 1) / step) * step
    }

    // MARK: Draw

    /// The note a click-and-drag on empty grid produces. `fromTicks` is the
    /// snapped press position; `toTicks` follows the cursor, so a quick click
    /// gives the default grid length and a drag gives exactly what you drew.
    static func drawnNote(
        id: String,
        pitch: UInt8,
        fromTicks: Int64,
        toTicks: Int64,
        defaultLengthTicks: Int64,
        clipLengthTicks: Int64,
        velocity: Int
    ) -> StudioNote {
        let start = max(0, min(fromTicks, toTicks))
        var length = max(minLengthTicks, abs(toTicks - fromTicks))
        if abs(toTicks - fromTicks) < minLengthTicks { length = max(minLengthTicks, defaultLengthTicks) }
        if clipLengthTicks > 0 { length = min(length, max(minLengthTicks, clipLengthTicks - start)) }
        return StudioNote(
            id: id, startTicks: start, lengthTicks: length, pitch: pitch, velocity: velocity)
    }

    // MARK: Keyboard nudge

    /// Nudge the selection by whole grid steps and/or semitones (arrow keys),
    /// with the same group clamp a mouse drag gets.
    static func nudge(
        _ notes: [StudioNote],
        byGridSteps steps: Int,
        semitones: Int,
        grid: StudioNoteGrid,
        timeSignature: StudioTimeSignature,
        clipLengthTicks: Int64
    ) -> MoveDelta {
        guard let anchor = notes.first else { return MoveDelta(ticks: 0, pitch: 0) }
        let step = grid.ticks(timeSignature) ?? (StudioNoteGrid.wholeTicks / 16)
        return moveDelta(
            notes: notes,
            anchorID: anchor.id,
            proposedAnchorStart: anchor.startTicks + Int64(steps) * step,
            proposedAnchorPitch: StudioNote.clampPitch(Int(anchor.pitch) + semitones),
            clipLengthTicks: clipLengthTicks)
    }
}
