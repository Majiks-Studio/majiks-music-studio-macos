import SwiftUI

// MARK: - Stem lane drawing
//
// ONE drawing path, called by both the view and its pixel tests.
//
// Three things this file deliberately does NOT do, because each already exists
// and a second copy would be the bug rather than the feature:
//
//   * it does not read audio. Peaks come from `WaveformData`, the app's single
//     sample extractor + cache (the same one the library rows and the player
//     bar use). `WaveformData.evictCache(under:)` on session delete keeps
//     working because there is still only one cache to evict.
//   * it does not build its own waveform path. The body is
//     `StudioWaveformTileStore.buildPath(peaks:)` — the Studio's tile path,
//     already unit space, already a closed min/max body around a midline — and
//     it is built ONCE per load and scaled per frame, which is the entire
//     reason that store exists.
//   * it does not poll meters. Levels ride `StemEngine.stemLevels`, published
//     by the one 20 Hz tick that owns the taps. `StemLevelAccumulator.read()`
//     is read-and-reset, so a second poller would drain the same hold and the
//     two would each see about half the peaks.
//
// It is a free function on a caseless enum, in the shape of
// `StudioMidiClipRender.draw`, for exactly that file's reason: a draw call that
// runs happily and produces nothing is invisible to any test that asserts on
// properties, so the test has to rasterize the real function.

enum StemLaneRender {

    /// The lane's whole data path in one call: decoded samples in, drawable
    /// body out.
    ///
    /// It exists as a named function rather than a line inside the view's
    /// `onChange` because that line was the ONE thing between a correct
    /// extractor and correct pixels, and a line inside a SwiftUI closure is a
    /// line no test can reach. Both mistakes the lanes actually had lived
    /// here — the samples never arrived at all (see
    /// `WaveformData.extractSamples`, which could not read a stereo file), and
    /// when they did they went through `buildPath(peaks:)`, which curves, on
    /// numbers the extractor had already curved.
    ///
    /// `WaveformData` returns HEIGHTS. That is why this is `heights:`.
    ///
    /// `@MainActor` because `StudioWaveformTileStore` is, and this calls into
    /// it. The isolation is not incidental: the one caller is the lane view's
    /// `onChange`, which is already on the main actor, and `WaveformData` is a
    /// `@MainActor` class whose `samples` this consumes. Making the tile store
    /// `nonisolated` instead would be defensible — `buildPath` is pure geometry
    /// over no instance state — but that widens a type three other files share,
    /// for no gain here.
    @MainActor
    static func body(forSamples samples: [Float]) -> Path {
        StudioWaveformTileStore.buildPath(heights: samples)
    }

    /// Draws one stem's waveform body into `rect`.
    ///
    /// - Parameters:
    ///   - body: the unit-space path from `StudioWaveformTileStore.buildPath`
    ///     (x = bin index, y in −1…1 around a midline). An EMPTY path draws
    ///     nothing — that is the "audio has not loaded yet / file is missing"
    ///     state, and it has to be visibly different from a stem that has
    ///     audio, which is what the pixel tests measure.
    ///   - binCount: how many bins `body` spans; the x scale factor's divisor.
    ///   - widthFraction: how much of `rect` this stem occupies. A stem session
    ///     is normally one song's parts and every stem is the full length
    ///     (fraction 1), but a hand-assembled session can hold a short stab
    ///     next to a full mix, and a stem shorter than the session must NOT be
    ///     stretched to fill — that would put its transients at the wrong time
    ///     under a playhead shared with every other lane.
    ///   - progress: 0…1 through THIS stem: the played/unplayed split.
    ///   - dimmed: effectively muted (muted, or outside a non-empty solo set).
    static func draw(
        _ context: inout GraphicsContext,
        body: Path,
        binCount: Int,
        rect: CGRect,
        color: Color,
        widthFraction: Double,
        progress: Double,
        dimmed: Bool
    ) {
        guard binCount > 0, !body.isEmpty, rect.width > 0, rect.height > 0 else { return }

        let span = rect.width * CGFloat(min(max(widthFraction, 0), 1))
        guard span > 0 else { return }

        let sx = span / CGFloat(binCount)
        // 0.92 leaves a hairline of lane above and below a full-scale peak, so
        // a hot stem reads as "loud" instead of as a block clipped flat by the
        // lane edge — which is what a normalised waveform at 1.0 looks like.
        let sy = (rect.height / 2) * 0.92

        // Played and unplayed are two CLIPPED fills of the same path, never two
        // paths, so the split can never disagree with the waveform under it.
        let playedWidth = span * CGFloat(min(max(progress, 0), 1))
        let playedAlpha = dimmed ? StudioTokens.waveformDimAlpha : StudioTokens.waveformBodyAlpha
        let tailAlpha = dimmed ? StudioTokens.waveformDimAlpha * 0.5 : StudioTokens.waveformDimAlpha

        if playedWidth > 0 {
            fill(context, body: body, rect: rect,
                 clipX: rect.minX, clipWidth: playedWidth,
                 sx: sx, sy: sy, color: color.opacity(playedAlpha))
        }
        if playedWidth < span {
            fill(context, body: body, rect: rect,
                 clipX: rect.minX + playedWidth, clipWidth: span - playedWidth,
                 sx: sx, sy: sy, color: color.opacity(tailAlpha))
        }
    }

    /// One clipped, scaled fill of the shared body path. Clip first, THEN
    /// transform: the clip rect is in lane coordinates and the path is in unit
    /// coordinates, and doing it the other way round would scale the clip too.
    private static func fill(
        _ context: GraphicsContext,
        body: Path,
        rect: CGRect,
        clipX: CGFloat,
        clipWidth: CGFloat,
        sx: CGFloat,
        sy: CGFloat,
        color: Color
    ) {
        var slice = context
        slice.clip(to: Path(CGRect(
            x: clipX, y: rect.minY, width: clipWidth, height: rect.height)))
        slice.translateBy(x: rect.minX, y: rect.midY)
        slice.scaleBy(x: sx, y: sy)
        slice.fill(body, with: .color(color))
    }
}

// MARK: - The lane view

/// One stem's waveform lane: a `Canvas` over `StemLaneRender.draw`, fed by the
/// shared `WaveformData` extractor.
///
/// The path is rebuilt only when the SAMPLES change (once per file load), not
/// per frame. During playback this view redraws ~20 times a second because the
/// playhead moves, and rebuilding a 400-segment path each time, per stem, is
/// the exact cost `StudioWaveformTileStore` was written to avoid.
///
/// 400 bins rather than the 200 the compact library rows use: a stem lane is
/// the full width of the window and twice the height of the old strip, so 200
/// bins across ~900 pt drew visible stair-steps.
struct StemLaneWaveform: View {
    let url: URL
    let color: Color
    let widthFraction: Double
    let progress: Double
    let dimmed: Bool

    @StateObject private var data = WaveformData()
    @State private var body_ = Path()
    @State private var binCount = 0

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            var context = context
            StemLaneRender.draw(
                &context,
                body: body_,
                binCount: binCount,
                rect: CGRect(origin: .zero, size: size),
                color: color,
                widthFraction: widthFraction,
                progress: progress,
                dimmed: dimmed
            )
        }
        .onAppear { data.load(from: url, targetSampleCount: 400) }
        .onChange(of: url) { _, newURL in data.load(from: newURL, targetSampleCount: 400) }
        .onChange(of: data.samples) { _, samples in
            body_ = StemLaneRender.body(forSamples: samples)
            binCount = samples.count
        }
        .accessibilityHidden(true)
    }
}
