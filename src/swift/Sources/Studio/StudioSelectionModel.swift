import Foundation
import CoreGraphics

// MARK: - Selection model
//
// Pure value types + pure functions (unit-tested). A selection is either a
// set of clips, a time region across tracks (the Revise unit), or both
// cleared. The view model owns one StudioSelection.

struct StudioRegionSelection: Equatable, Sendable {
    /// Absolute ticks, normalized so start < end.
    var startTicks: Int64
    var endTicks: Int64
    /// Track ids covered; empty = all tracks (ruler drag selects all).
    var trackIDs: Set<UUID>

    var lengthTicks: Int64 { endTicks - startTicks }

    init?(rawStart: Int64, rawEnd: Int64, trackIDs: Set<UUID> = []) {
        let lo = min(rawStart, rawEnd)
        let hi = max(rawStart, rawEnd)
        guard hi > lo else { return nil }
        self.startTicks = max(0, lo)
        self.endTicks = hi
        self.trackIDs = trackIDs
    }

    /// 1-based inclusive bar numbers for UI copy: "Revise bars 33-48".
    func barRange(timeSignature: StudioTimeSignature) -> ClosedRange<Int> {
        let tpb = timeSignature.ticksPerBar
        let first = Int(startTicks / tpb) + 1
        let lastBarIndex = Int((endTicks - 1) / tpb) + 1
        return first...max(first, lastBarIndex)
    }

    func barRange(grid: StudioBarGrid) -> ClosedRange<Int> {
        let first = grid.barNumber(at: startTicks)
        let last = grid.barNumber(at: max(startTicks, endTicks - 1))
        return first...max(first, last)
    }
}

struct StudioSelection: Equatable, Sendable {
    var clipIDs: Set<UUID> = []
    var region: StudioRegionSelection?

    var isEmpty: Bool { clipIDs.isEmpty && region == nil }

    static let empty = StudioSelection()
}

enum StudioSelectionOps {

    /// Click semantics: plain click replaces, shift-click toggles.
    static func clicked(
        _ selection: StudioSelection,
        clipID: UUID,
        shift: Bool
    ) -> StudioSelection {
        var out = selection
        out.region = nil
        if shift {
            if out.clipIDs.contains(clipID) {
                out.clipIDs.remove(clipID)
            } else {
                out.clipIDs.insert(clipID)
            }
        } else {
            out.clipIDs = [clipID]
        }
        return out
    }

    /// Rubber-band result over precomputed clip frames. Plain drag replaces,
    /// shift drag adds to the existing set.
    static func rubberBand(
        _ selection: StudioSelection,
        rect: CGRect,
        clipFrames: [(id: UUID, frame: CGRect)],
        shift: Bool
    ) -> StudioSelection {
        var out = selection
        out.region = nil
        let hits = Set(clipFrames.filter { $0.frame.intersects(rect) }.map(\.id))
        out.clipIDs = shift ? out.clipIDs.union(hits) : hits
        return out
    }

    /// Normalized rubber-band rect from a drag's start/current points.
    static func bandRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// Region selection from a ruler drag, hard-snapped to bars.
    static func rulerRegion(
        fromTicks a: Int64,
        toTicks b: Int64,
        timeSignature: StudioTimeSignature,
        phaseAnchorTicks: Int64 = 0
    ) -> StudioRegionSelection? {
        let lo = StudioTimelineMath.hardSnap(
            min(a, b), mode: .bar, timeSignature: timeSignature,
            phaseAnchorTicks: phaseAnchorTicks)
        var hi = StudioTimelineMath.hardSnap(
            max(a, b), mode: .bar, timeSignature: timeSignature,
            phaseAnchorTicks: phaseAnchorTicks)
        if hi == lo { hi = lo + timeSignature.ticksPerBar }   // minimum one bar
        return StudioRegionSelection(rawStart: lo, rawEnd: hi)
    }

    static func rulerRegion(
        fromTicks a: Int64,
        toTicks b: Int64,
        grid: StudioBarGrid
    ) -> StudioRegionSelection? {
        let lo = StudioTimelineMath.hardSnap(min(a, b), mode: .bar, grid: grid)
        var hi = StudioTimelineMath.hardSnap(max(a, b), mode: .bar, grid: grid)
        if hi == lo { hi = lo + grid.ticksPerBar }
        return StudioRegionSelection(rawStart: lo, rawEnd: hi)
    }

    /// Clips that a split at `ticks` should affect: the selected clips that
    /// contain the tick, or (with no selection) every clip containing it.
    static func splitTargets(
        atTicks ticks: Int64,
        selection: StudioSelection,
        tracks: [StudioTrackSnapshot]
    ) -> [UUID] {
        let all = tracks.flatMap(\.clips)
        let containing = all.filter { $0.startTicks < ticks && ticks < $0.endTicks }
        if selection.clipIDs.isEmpty {
            return containing.map(\.id)
        }
        return containing.filter { selection.clipIDs.contains($0.id) }.map(\.id)
    }
}
