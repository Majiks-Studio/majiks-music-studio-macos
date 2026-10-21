import SwiftUI

// MARK: - Waveform tile store
//
// DJ WaveformView pattern: peaks arrive as arrays from the engine, async,
// never raw audio on the UI thread. This store caches, per tile, a Path
// built ONCE in unit space (x 0...1 per bin span, y 0...1 amplitude); the
// canvas scales the graphics context instead of rebuilding paths per frame.

struct StudioTilePath {
    let path: Path            // unit space: x in 0...binCount, y in -1...1 around 0
    let binCount: Int
    let ticksPerBin: Int64
}

// MARK: - Peak -> drawn height
//
// WHY THIS IS NOT THE IDENTITY, which is what shipped.
//
// A bin's peak is an AMPLITUDE, and amplitude drawn linearly is not what a
// person sees when they listen. -20 dBFS is 0.1 of full scale: on the default
// 90 pt track row, where `drawWaveform` has 42 pt of half-height to work with,
// linear puts that at 4.2 pt. Four points of a stem colour at 75% alpha on a
// near-black canvas is not visible on a television across a room, and the
// material is plainly audible. Measured on the owner's own session, the mean
// drawn half-height of all four stems was 3.3-4.5 pt of the 42 available: the
// arrangement was a thin smear along the midline, which is exactly what he
// reported.
//
// THE CURVE. Stevens' power law puts perceived loudness near intensity^0.3,
// i.e. amplitude^0.6. A square root (0.5) is the same neighbourhood, is exact
// in binary floating point, is monotone, is cheap in the canvas hot loop, and
// is anchored at both ends: 0 draws nothing and 1.0 draws full. It halves the
// dB slope rather than removing it, so loud and quiet stay clearly ORDERED:
//
//     -3 dBFS  0.7071 -> 0.8409   (35.3 pt of 42)
//    -20 dBFS  0.1000 -> 0.3162   (13.3 pt of 42, was 4.2)
//    -40 dBFS  0.0100 -> 0.1000   ( 4.2 pt of 42, was 0.4)
//
// The alternative considered and rejected was a dB-domain ramp with a floor
// (`(dB + 60) / 60`), which maps -20 dBFS to 0.67 and -3 dBFS to 0.955 — both
// visible, but only 1.4x apart, so a quiet passage and a loud one draw nearly
// the same height and the picture stops carrying dynamics at all. That trades
// one unreadable waveform for a different one.
//
// This changes PIXELS ONLY. No rendered sample moves; the legacy bit-identity
// pin is untouched.
enum StudioWaveformScale {
    /// Amplitude exponent. Stevens' loudness exponent against amplitude is
    /// ~0.6; 0.5 is the same neighbourhood and is exact.
    static let exponent: Double = 0.5

    /// A bin peak (0...1) as a fraction of the available half-height.
    static func height(forPeak peak: Float) -> Float {
        let clamped = Double(min(1, max(0, peak)))
        return Float(pow(clamped, exponent))
    }
}

@MainActor
final class StudioWaveformTileStore: ObservableObject {

    /// Bumped when a tile lands so the canvas redraws. Not per-tile state:
    /// the canvas pulls from `cache` directly during draw.
    @Published private(set) var tileEpoch: UInt64 = 0

    private(set) var cache: [StudioTileKey: StudioTilePath] = [:]
    // Access stamps avoid removeFirst/firstIndex churn while zooming across a
    // large arrangement. The cache remains bounded, but each hit is O(1).
    private var accessStamp: [StudioTileKey: UInt64] = [:]
    private var nextAccessStamp: UInt64 = 0
    private var inFlight: Set<StudioTileKey> = []
    private let capacity = 768

    /// Cached tile, if present (marks it recently used).
    func tile(for key: StudioTileKey) -> StudioTilePath? {
        guard let hit = cache[key] else { return nil }
        touch(key)
        return hit
    }

    /// Ask the engine for a tile if it is neither cached nor being fetched.
    func request(_ key: StudioTileKey, from engine: any StudioEngineProtocol) {
        guard cache[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task { [weak self] in
            let tile = await engine.waveformTile(key)
            guard let self else { return }
            self.inFlight.remove(key)
            guard let tile else { return }
            self.store(tile)
        }
    }

    private func store(_ tile: StudioWaveformTile) {
        cache[tile.key] = StudioTilePath(
            path: Self.buildPath(peaks: tile.peaks),
            binCount: tile.peaks.count,
            ticksPerBin: tile.ticksPerBin
        )
        touch(tile.key)
        while cache.count > capacity {
            guard let evicted = accessStamp.min(by: { $0.value < $1.value })?.key else { break }
            cache.removeValue(forKey: evicted)
            accessStamp.removeValue(forKey: evicted)
        }
        tileEpoch &+= 1
    }

    private func touch(_ key: StudioTileKey) {
        nextAccessStamp &+= 1
        accessStamp[key] = nextAccessStamp
    }

    /// Filled min/max body around a midline: for each bin a symmetric
    /// amplitude, drawn as one closed path (top run, then bottom run back).
    /// Unit space: x = bin index, y in -1...1 (0 = midline).
    ///
    /// The peak is put through `StudioWaveformScale` on the way in — once,
    /// here, because this is the one place an ENGINE TILE's peak becomes a
    /// coordinate.
    ///
    /// ⚠️ Takes raw bin PEAKS. A caller whose numbers have already been through
    /// the curve wants `buildPath(heights:)`. `WaveformData.extractSamples` is
    /// one: it curves on the way out (its own header says so), so
    /// `StemLaneWaveform` calling this overload applied the square root TWICE.
    /// sqrt(sqrt(x)) puts -20 dBFS at 0.562 instead of 0.316 and collapses the
    /// loud:quiet ratio from 3.16 to 1.78 — under the `> 2.0` bound
    /// `LibraryWaveformScaleTests.dynamicsSurvive` states as the point of
    /// having a curve at all. Every stem lane read as uniformly loud.
    static func buildPath(peaks: [Float]) -> Path {
        buildPath(heights: peaks.map(StudioWaveformScale.height(forPeak:)))
    }

    /// The geometry alone, from numbers that are ALREADY drawn heights in
    /// 0...1. Split out from `buildPath(peaks:)` so a caller that has already
    /// applied `StudioWaveformScale` has a way to say so, instead of the curve
    /// being applied a second time because both ends assumed the other end had
    /// not done it.
    static func buildPath(heights: [Float]) -> Path {
        var path = Path()
        guard !heights.isEmpty else { return path }
        path.move(to: CGPoint(x: 0, y: CGFloat(-heights[0])))
        for (i, h) in heights.enumerated().dropFirst() {
            path.addLine(to: CGPoint(x: CGFloat(i), y: CGFloat(-h)))
        }
        for (i, h) in heights.enumerated().reversed() {
            path.addLine(to: CGPoint(x: CGFloat(i), y: CGFloat(h)))
        }
        path.closeSubpath()
        return path
    }
}
