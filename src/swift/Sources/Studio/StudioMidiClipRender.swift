import SwiftUI

// MARK: - MIDI clips in the arrangement
//
// A MIDI clip used to draw as a flat coloured rectangle with a name on it and
// nothing inside. `drawClipBody` called `drawWaveform` for EVERY clip; a note
// clip has no audio, therefore no waveform tiles, therefore nothing was drawn.
// A 56-note piano performance and a clip with no notes in it were pixel
// identical — and that is the one distinction the arrangement most has to make.
// It is how you tell a bassline from a pad at a glance, and how you spot the
// empty clip before you go hunting for why you cannot hear it.
//
// This file is the note half of the clip body, split the way the rest of the
// Studio splits drawing: `StudioMidiClipGeometry` is pure math with no SwiftUI
// drawing in it (unit-tested, the way StudioTimelineMath and
// StudioPianoRollMath are), and `StudioMidiClipRender.draw` is the ONE function
// that puts note pixels on a context. The arrangement calls it and the pixel
// tests call it, so what a test rasterizes is exactly what the timeline
// rasterizes — there is no second drawing path to drift.

// MARK: - What the arrangement knows about one clip's notes

/// The notes of one MIDI clip, as the arrangement caches them.
///
/// Clip-RELATIVE ticks, exactly as `StudioMidiClipSnapshot` carries them and
/// exactly as the piano roll reads them; two surfaces drawing the same clip
/// must not disagree about where a note is.
///
/// `lowPitch` / `highPitch` are computed ONCE, here, rather than per frame. The
/// timeline canvas repaints continuously while `model.isPlaying`, so a min/max
/// over a few hundred notes for every clip on every frame is exactly the kind
/// of cost that never fails a test and shows up only as a stuttering
/// arrangement during playback.
struct StudioClipNotes: Sendable, Equatable {
    /// Engine order — `(startTicks, pitch, id)`. The draw loop relies on the
    /// start-tick ordering to stop early once it is past the right edge.
    var notes: [StudioNote]
    var lowPitch: UInt8
    var highPitch: UInt8
    /// The journal `seq` these notes were read at. The store's staleness gate.
    var revision: UInt64

    init(notes: [StudioNote], revision: UInt64) {
        self.notes = notes
        self.lowPitch = notes.map(\.pitch).min() ?? 60
        self.highPitch = notes.map(\.pitch).max() ?? 60
        self.revision = revision
    }
}

/// What the arrangement can currently say about a MIDI clip, as three states
/// that must not be drawn the same way.
///
/// `pending` and `empty` being distinct marks is the entire point of the fix:
/// "this clip has nothing in it" and "I have not read this clip yet" are
/// different facts, and the old behaviour — draw nothing for both, and for a
/// full clip too — is what made an empty clip and a 56-note clip identical.
enum StudioMidiClipContent: Sendable, Equatable {
    /// Not read yet: the engine call is in flight, has not been made, or the
    /// engine has no note seam at all (a mock build).
    case pending
    /// Read, and the clip genuinely holds no notes.
    case empty
    /// Read, with notes in it.
    case notes(StudioClipNotes)
}

// MARK: - Pure geometry

enum StudioMidiClipGeometry {

    /// The narrowest pitch window a clip row is ever scaled to, in semitones.
    ///
    /// Without a floor, a part that repeats ONE note would have a one-row
    /// window and that single note would fill the clip top to bottom — a solid
    /// block that says nothing. One octave is the smallest window in which a
    /// note still reads as "a note at a pitch" rather than as a bar.
    static let minimumPitchSpan = 12

    /// Padding inside the clip rect, so notes do not collide with the clip's
    /// own 1 pt stroke or sit under the name tag's baseline.
    static let verticalInset: CGFloat = 3

    /// Thinnest note ever drawn. A 1/32 note in a zoomed-out arrangement is
    /// well under a pixel wide; drawn honestly it would vanish, and a part
    /// would look emptier the further out you zoom — which is the bug being
    /// fixed, re-introduced by arithmetic.
    static let minimumNoteWidth: CGFloat = 1.5

    /// Shortest note ever drawn. Same argument in the other axis: a piano part
    /// spanning four octaves in a 90 pt row is under 2 pt per semitone.
    static let minimumNoteHeight: CGFloat = 1.5

    /// The pitch window this clip's row maps onto: the clip's OWN range, opened
    /// out to `minimumSpan` if it is narrower, and clamped to MIDI 0...127.
    ///
    /// Per-clip rather than a fixed 0...127, because 0...127 is what makes a
    /// bassline a hairline at the bottom of an otherwise blank row — you can
    /// see it is a clip, not what is in it. The cost of per-clip scaling is
    /// that a part and the same part an octave up draw identically; that is the
    /// same trade Ableton, Logic and Bitwig make, and it buys the thing that
    /// matters more, which is that every clip fills its row.
    static func pitchWindow(
        low: UInt8,
        high: UInt8,
        minimumSpan: Int = minimumPitchSpan
    ) -> ClosedRange<Int> {
        var lo = Int(min(low, high))
        var hi = Int(max(low, high))
        let span = hi - lo + 1
        if span < minimumSpan {
            let pad = minimumSpan - span
            lo -= pad / 2
            hi += pad - pad / 2
        }
        // Clamp, then slide (never shrink) so a part sitting against either end
        // of the keyboard still gets the full window rather than a squashed one.
        if lo < 0 { hi -= lo; lo = 0 }
        if hi > 127 { lo -= hi - 127; hi = 127 }
        return max(0, lo)...min(127, hi)
    }

    /// Where one note draws inside a clip's body rect.
    ///
    /// x comes from the note's CLIP-RELATIVE start, not from a source offset:
    /// `StudioMidiClipSnapshot` stores notes relative to the clip's own start
    /// and the piano roll draws them that way (`clip.startTicks +
    /// note.startTicks`), so the arrangement must too or the two surfaces
    /// disagree about where the downbeat is.
    static func noteRect(
        for note: StudioNote,
        in rect: CGRect,
        pxPerTick: CGFloat,
        window: ClosedRange<Int>
    ) -> CGRect {
        let rows = CGFloat(window.upperBound - window.lowerBound + 1)
        let usable = max(0, rect.height - verticalInset * 2)
        let rowHeight = usable / rows
        // Top row is the HIGHEST pitch: up on screen is up in pitch, the same
        // way round as the piano roll and every keyboard.
        let fromTop = CGFloat(window.upperBound - Int(note.pitch))
        let y = rect.minY + verticalInset + fromTop * rowHeight
        // A hair of separation between adjacent semitones once rows are tall
        // enough to afford it, so a held chord reads as three notes and not as
        // one block.
        let height = max(minimumNoteHeight, rowHeight - (rowHeight > 3 ? 1 : 0))
        return CGRect(
            x: rect.minX + CGFloat(note.startTicks) * pxPerTick,
            y: y,
            width: max(minimumNoteWidth, CGFloat(note.lengthTicks) * pxPerTick),
            height: height)
    }
}

// MARK: - The one draw function

enum StudioMidiClipRender {

    /// Velocity buckets, so the note layer costs a FIXED handful of fills
    /// whatever the note count. Straight off `StudioPianoRollView.drawNotes`,
    /// which learned it the same way: a `context.fill` per note is what turns a
    /// dense passage into a slideshow. Six reads as dynamics and stays flat
    /// under a few thousand notes.
    static let velocityBuckets = 6

    /// Alpha for the QUIETEST bucket, as a fraction of the loudest. Loud notes
    /// sing at full stem colour; a ghosted (cross-track drag) clip scales the
    /// whole ramp down to the waveform's ghost alpha, so a dragged MIDI clip
    /// recedes exactly as much as a dragged audio one.
    static let quietestAlphaFraction: Double = 0.45

    /// Draw a MIDI clip's contents into `rect`.
    ///
    /// `visibleX` is the canvas's own x range: a 22-bar clip scrolled half off
    /// screen must not build path geometry for the half nobody can see. Notes
    /// arrive in start-tick order, so the scan stops at the first note past the
    /// right edge rather than walking the rest of the part.
    static func draw(
        _ context: inout GraphicsContext,
        content: StudioMidiClipContent,
        kind: StudioStemKind,
        rect: CGRect,
        pxPerTick: CGFloat,
        visibleX: ClosedRange<CGFloat>,
        dim: Bool
    ) {
        let stem = StudioTokens.stemColor(kind)

        switch content {
        case .pending:
            // The waveform's placeholder idiom: a quiet, SOLID midline meaning
            // "still reading". Deliberately dimmer and unbroken so it cannot be
            // mistaken for the empty mark below.
            midline(&context, rect: rect, color: stem.opacity(dim ? 0.10 : 0.20), dash: [])

        case .empty:
            // A clip with no notes must LOOK empty on purpose. A dashed midline
            // is a mark you can read at sofa distance as "nothing recorded
            // here", and it is what separates an empty clip from a clip whose
            // notes failed to draw — which was the whole bug.
            midline(&context, rect: rect, color: stem.opacity(dim ? 0.18 : 0.38), dash: [3, 3])

        case .notes(let clipNotes):
            drawNotes(
                &context, clipNotes: clipNotes, stem: stem, rect: rect,
                pxPerTick: pxPerTick, visibleX: visibleX, dim: dim)
        }
    }

    private static func drawNotes(
        _ context: inout GraphicsContext,
        clipNotes: StudioClipNotes,
        stem: Color,
        rect: CGRect,
        pxPerTick: CGFloat,
        visibleX: ClosedRange<CGFloat>,
        dim: Bool
    ) {
        guard !clipNotes.notes.isEmpty else { return }
        let window = StudioMidiClipGeometry.pitchWindow(
            low: clipNotes.lowPitch, high: clipNotes.highPitch)

        var buckets = [Path](repeating: Path(), count: velocityBuckets)
        for note in clipNotes.notes {
            let r = StudioMidiClipGeometry.noteRect(
                for: note, in: rect, pxPerTick: pxPerTick, window: window)
            if r.maxX < visibleX.lowerBound { continue }
            // Engine order is by start tick, so once a note starts past the
            // right edge every note after it does too.
            if r.minX > visibleX.upperBound { break }
            let bucket = min(
                velocityBuckets - 1,
                max(0, note.velocity * velocityBuckets / 128))
            buckets[bucket].addRect(r)
        }

        let ceiling = dim ? StudioTokens.waveformDimAlpha : 1.0
        for (index, path) in buckets.enumerated() where !path.isEmpty {
            let t = Double(index) / Double(velocityBuckets - 1)
            let alpha = ceiling * (quietestAlphaFraction + (1 - quietestAlphaFraction) * t)
            context.fill(path, with: .color(stem.opacity(alpha)))
        }
    }

    private static func midline(
        _ context: inout GraphicsContext,
        rect: CGRect,
        color: Color,
        dash: [CGFloat]
    ) {
        var line = Path()
        line.move(to: CGPoint(x: rect.minX, y: rect.midY))
        line.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: dash))
    }
}
