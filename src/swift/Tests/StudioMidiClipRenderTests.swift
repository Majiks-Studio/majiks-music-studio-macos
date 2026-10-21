import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// A MIDI clip in the arrangement must SHOW ITS NOTES.
//
// The bug these tests exist to keep dead: `drawClipBody` called `drawWaveform`
// for every clip, a note clip has no waveform tiles, and so every MIDI clip in
// the arrangement was a flat coloured rectangle with a name label and nothing
// inside it. A 56-note piano performance and a clip with no notes in it were
// pixel identical.
//
// That is a draw call that ran happily and produced nothing, which is why
// nothing here asserts on properties. Every claim below is made against actual
// rasterized pixels, through ImageRenderer — the deterministic, no-window path
// StudioMixerDockTests and StudioPaneSizingTests already use. A test that
// asserted "the clip has notes" would have passed against the broken build.
@MainActor
final class StudioMidiClipRenderTests: XCTestCase {

    // MARK: - Rasterizing probe
    //
    // The probe is framing ONLY. The pixels come from
    // `StudioMidiClipRender.draw`, which is the same function
    // `StudioTimelineCanvas.drawMidiNotes` calls — there is no second drawing
    // path for a test to be green against.

    private struct MidiClipProbe: View {
        /// nil draws the clip body with NO contents: the pixel baseline every
        /// "is there ink?" measurement below is taken against.
        let content: StudioMidiClipContent?
        var kind: StudioStemKind = .bass
        var pxPerTick: CGFloat = 96.0 / CGFloat(StudioTick.ppq)
        /// The cross-track-drag ghost state, straight through to the same call.
        var dim: Bool = false

        var body: some View {
            Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .color(StudioTokens.clipFillColor(kind)))
                guard let content else { return }
                var body = context
                StudioMidiClipRender.draw(
                    &body, content: content, kind: kind, rect: rect,
                    pxPerTick: pxPerTick, visibleX: 0...size.width, dim: dim)
            }
        }
    }

    private let probeWidth: CGFloat = 320
    private let probeHeight: CGFloat = 80

    /// Raw BGRA bytes of a rendered probe. Fixed bitmap layout so two renders
    /// are byte-comparable.
    private func raster(
        _ content: StudioMidiClipContent?,
        kind: StudioStemKind = .bass,
        pxPerTick: CGFloat = 96.0 / CGFloat(StudioTick.ppq),
        dim: Bool = false,
        width: CGFloat? = nil,
        height: CGFloat? = nil
    ) throws -> Raster {
        let view = MidiClipProbe(content: content, kind: kind, pxPerTick: pxPerTick, dim: dim)
            .frame(width: width ?? probeWidth, height: height ?? probeHeight)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.cgImage, "the probe did not rasterize at all")
        let w = cg.width
        let h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Raster(width: w, height: h, bytes: bytes)
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        /// Pixels that differ from `other` by more than a rounding wobble.
        func differing(from other: Raster) -> Int {
            guard width == other.width, height == other.height else { return .max }
            var count = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                for c in 1..<4 where abs(Int(bytes[i + c]) - Int(other.bytes[i + c])) > 2 {
                    count += 1
                    break
                }
            }
            return count
        }

        /// Total per-channel departure from the empty clip body.
        ///
        /// Counting ink PIXELS is not enough at extreme zoom-out: a sub-pixel
        /// note is antialiased into a faint but present pixel, so the count
        /// barely moves while the part becomes too faint to read. The mass
        /// moves — it is coverage, which is what the eye is actually given.
        func inkMass(over baseline: Raster) -> Int {
            guard width == baseline.width, height == baseline.height else { return 0 }
            var mass = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                for c in 1..<4 {
                    mass += abs(Int(bytes[i + c]) - Int(baseline.bytes[i + c]))
                }
            }
            return mass
        }

        /// Pixels where this render put something the empty body did not: the
        /// "ink" a note layer laid down.
        func ink(over baseline: Raster) -> [(x: Int, y: Int)] {
            var out: [(x: Int, y: Int)] = []
            guard width == baseline.width, height == baseline.height else { return out }
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    var differs = false
                    for c in 1..<4 where abs(Int(bytes[i + c]) - Int(baseline.bytes[i + c])) > 2 {
                        differs = true
                        break
                    }
                    if differs { out.append((x, y)) }
                }
            }
            return out
        }
    }

    // MARK: - Note fixtures

    private func note(_ pitch: Int, _ startBeats: Double, _ lengthBeats: Double, velocity: Int = 100) -> StudioNote {
        let ppq = Double(StudioTick.ppq)
        return StudioNote(
            id: String(format: "N%03d%05d", pitch, Int(startBeats * 100)),
            startTicks: Int64(startBeats * ppq),
            lengthTicks: Int64(lengthBeats * ppq),
            pitch: StudioNote.clampPitch(pitch),
            velocity: velocity)
    }

    private func content(_ notes: [StudioNote]) -> StudioMidiClipContent {
        .notes(StudioClipNotes(notes: StudioNote.sorted(notes), revision: 1))
    }

    // MARK: - The bug itself

    func testAClipWithNotesRendersDifferentPixelsFromAnEmptyClip() throws {
        let full = try raster(content([
            note(48, 0, 1), note(52, 1, 1), note(55, 2, 1), note(60, 3, 1),
        ]))
        let empty = try raster(.empty)

        let differing = full.differing(from: empty)
        XCTAssertGreaterThan(
            differing, 500,
            "a clip with four notes in it rendered \(differing) pixels differently from an empty clip: the arrangement is drawing a flat rectangle for a part that has notes in it, which is the whole bug")
    }

    func testAnEmptyClipIsDistinguishableFromAClipThatHasNotBeenReadYet() throws {
        let empty = try raster(.empty)
        let pending = try raster(.pending)
        let bare = try raster(nil)

        XCTAssertGreaterThan(
            empty.differing(from: pending), 40,
            "'this clip has no notes' and 'I have not read this clip yet' rendered the same: a person cannot tell an empty part from a part whose notes failed to load")
        XCTAssertGreaterThan(
            empty.differing(from: bare), 40,
            "an empty clip drew nothing at all, so it is indistinguishable from a clip whose contents silently failed to draw — the exact failure mode being fixed")
    }

    func testNotesReadAsNotesAndNotAsAWaveformStyleMidline() throws {
        // A clip with notes must not be mistakable for either mark.
        let full = try raster(content([note(48, 0, 2), note(60, 2, 2)]))
        XCTAssertGreaterThan(full.differing(from: try raster(.empty)), 500)
        XCTAssertGreaterThan(full.differing(from: try raster(.pending)), 500)
    }

    // MARK: - Pitch reads as height

    func testAPartSittingHighInItsRangeDrawsAboveOneSittingLow() throws {
        // SAME pitch window in both (both span 48...72), so this isolates
        // exactly one thing: does pitch decide vertical position?
        let high = content([
            note(72, 0, 1), note(71, 1, 1), note(72, 2, 1), note(71, 3, 1), note(48, 3.5, 0.25),
        ])
        let low = content([
            note(48, 0, 1), note(49, 1, 1), note(48, 2, 1), note(49, 3, 1), note(72, 3.5, 0.25),
        ])
        let bare = try raster(nil)
        let highInk = try raster(high).ink(over: bare)
        let lowInk = try raster(low).ink(over: bare)

        XCTAssertFalse(highInk.isEmpty, "the high part drew no note pixels at all")
        XCTAssertFalse(lowInk.isEmpty, "the low part drew no note pixels at all")

        let highCentre = Double(highInk.map(\.y).reduce(0, +)) / Double(highInk.count)
        let lowCentre = Double(lowInk.map(\.y).reduce(0, +)) / Double(lowInk.count)
        XCTAssertLessThan(
            highCentre, lowCentre - 15,
            "the high part's ink sat at y=\(highCentre) and the low part's at y=\(lowCentre): pitch is not deciding where a note draws, so a bassline and a lead look the same")
    }

    func testAOneOctaveBasslineFillsItsRowRatherThanSittingAsAHairline() throws {
        // The reason the pitch window scales to the clip's own notes: on a fixed
        // 0...127 window a bass part occupies four rows out of a hundred and
        // twenty-eight and reads as a smudge on the floor of the clip.
        let bassline = content([
            note(36, 0, 0.5), note(43, 0.5, 0.5), note(48, 1, 0.5), note(41, 1.5, 0.5),
            note(36, 2, 0.5), note(43, 2.5, 0.5), note(48, 3, 0.5), note(38, 3.5, 0.5),
        ])
        let ink = try raster(bassline).ink(over: try raster(nil))
        let ys = ink.map(\.y)
        let spread = Double((ys.max() ?? 0) - (ys.min() ?? 0))
        XCTAssertGreaterThan(
            spread, Double(probeHeight) * 0.6,
            "a one-octave bassline covered only \(spread) pt of an \(probeHeight) pt row: the pitch window is not scaling to the notes present, so a bass part is a hairline instead of a part you can read")
    }

    // MARK: - Density

    func testADenseClipDrawsMoreInkThanASparseOne() throws {
        // Same three bars, same 48...72 pitch range in both, so the only
        // variable is how much is going on inside the clip. (Both fixtures fit
        // inside the probe: a fixture that runs off the right edge is culled,
        // and would make this test measure the cull rather than the density.)
        let sparse = [note(48, 0, 0.25), note(60, 1, 0.25), note(72, 2, 0.25)]
        var dense: [StudioNote] = []
        for slot in 0..<24 {
            let beat = Double(slot) * 0.125
            for voice in 0..<4 {
                dense.append(note(48 + voice * 8 + (slot % 2), beat, 0.125, velocity: 90))
            }
        }

        let bare = try raster(nil)
        let denseInk = try raster(content(dense)).ink(over: bare).count
        let sparseInk = try raster(content(sparse)).ink(over: bare).count

        XCTAssertGreaterThan(
            denseInk, sparseInk * 4,
            "a \(dense.count)-note passage laid down \(denseInk) note pixels against \(sparseInk) for a three-note one: density is not reading, so a busy part and an almost-empty one look alike")
    }

    func testEveryNoteSurvivesZoomOutRatherThanThinningToNothing() throws {
        // At the zoom that puts a whole 32-bar song on screen, a sixteenth note
        // is 0.6 pt wide. Drawn at its arithmetic width it fades to a smear and
        // a busy part reads as an empty clip the further out you zoom — the
        // same bug as the original one, re-introduced by geometry.
        //
        // The floor is on ink MASS, and it is calibrated against both sides
        // rather than guessed: with the minimum note width in place this
        // fixture measures 930,174; with the minimum removed it measures
        // 387,434. 650,000 sits between the two, so the assertion tells them
        // apart instead of merely being satisfiable. (An earlier version of
        // this test counted ink PIXELS with a floor of 100 and could not tell
        // them apart at all — removing the minimum width survived it.)
        let notes = (0..<512).map { note(48 + ($0 % 15), Double($0) * 0.25, 0.25) }
        // 512 sixteenths = 32 bars, laid across the whole probe.
        let wholeSong = probeWidth / (128.0 * CGFloat(StudioTick.ppq))
        let mass = try raster(content(notes), pxPerTick: wholeSong)
            .inkMass(over: try raster(nil, pxPerTick: wholeSong))
        print("MIDI zoom-out ink mass (512 sixteenths across the probe): \(mass)")
        XCTAssertGreaterThan(
            mass, 650_000,
            "a 512-note passage laid down only \(mass) of ink mass at whole-song zoom: notes are thinning below a pixel and the clip reads as empty when it is full")
    }

    // MARK: - Velocity

    func testVelocityChangesHowLoudANotePaints() throws {
        let shape: [(Int, Double)] = [(48, 0), (52, 1), (55, 2), (60, 3)]
        let quiet = content(shape.map { note($0.0, $0.1, 1, velocity: 20) })
        let loud = content(shape.map { note($0.0, $0.1, 1, velocity: 127) })

        let differing = try raster(quiet).differing(from: try raster(loud))
        XCTAssertGreaterThan(
            differing, 200,
            "the same notes played at velocity 20 and at 127 rendered identically (\(differing) pixels differ): the dynamics of a performance are invisible in the arrangement")
    }

    // MARK: - Ghosted (cross-track drag) clips

    func testAGhostedClipStillShowsItsNotesButRecedes() throws {
        let notes = content([note(48, 0, 1), note(55, 1, 1), note(60, 2, 1)])
        let bare = try raster(nil)
        let ghost = try raster(notes, dim: true)
        let solidRaster = try raster(notes, dim: false)

        XCTAssertGreaterThan(
            ghost.ink(over: bare).count, 200,
            "a clip being dragged across tracks drew no notes: the ghost is back to being a blank rectangle")
        XCTAssertGreaterThan(
            ghost.differing(from: solidRaster), 200,
            "a ghosted clip painted exactly as strongly as a settled one, so there is no visual difference between the clip you are dragging and the clip you already dropped")
    }

    // MARK: - Pure geometry
    //
    // Fast, exact, and the place an off-by-one in the pitch mapping shows up as
    // a number rather than as a smudge.

    func testThePitchWindowIsTheClipsOwnRangeWhenItIsWideEnough() {
        let window = StudioMidiClipGeometry.pitchWindow(low: 36, high: 72)
        XCTAssertEqual(window, 36...72)
    }

    func testANarrowPartIsOpenedOutToAtLeastAnOctave() {
        // One repeated note would otherwise own a one-row window and fill the
        // clip top to bottom as a solid bar.
        //
        // The bound is written out as 12 rather than as
        // `StudioMidiClipGeometry.minimumPitchSpan`: an assertion against the
        // constant it is testing passes for any value of that constant, which
        // is no assertion at all.
        let window = StudioMidiClipGeometry.pitchWindow(low: 60, high: 60)
        XCTAssertGreaterThanOrEqual(
            window.upperBound - window.lowerBound + 1, 12,
            "a single repeated note got a \(window) window and would draw as a full-height block")
        XCTAssertTrue(window.contains(60))
    }

    func testASingleRepeatedNoteIsNotAFullHeightBar() throws {
        // The same claim, in pixels: one note played four times must read as a
        // note at a pitch, not as a solid slab that says nothing about the part.
        let ink = try raster(content([
            note(60, 0, 0.5), note(60, 1, 0.5), note(60, 2, 0.5), note(60, 3, 0.5),
        ])).ink(over: try raster(nil))
        let ys = ink.map(\.y)
        let tallest = Double((ys.max() ?? 0) - (ys.min() ?? 0)) + 1
        XCTAssertFalse(ink.isEmpty, "the repeated note drew nothing")
        XCTAssertLessThan(
            tallest, Double(probeHeight) * 0.4,
            "one repeated note painted \(tallest) pt of an \(probeHeight) pt row: the pitch window has no floor, so a single-note part draws as a solid block")
    }

    func testTheWindowSlidesRatherThanShrinkingAtTheEndsOfTheKeyboard() {
        let low = StudioMidiClipGeometry.pitchWindow(low: 0, high: 1)
        XCTAssertEqual(low.lowerBound, 0)
        XCTAssertEqual(
            low.upperBound - low.lowerBound + 1, StudioMidiClipGeometry.minimumPitchSpan,
            "a part at the bottom of the keyboard got a squashed window")

        let high = StudioMidiClipGeometry.pitchWindow(low: 126, high: 127)
        XCTAssertEqual(high.upperBound, 127)
        XCTAssertEqual(
            high.upperBound - high.lowerBound + 1, StudioMidiClipGeometry.minimumPitchSpan,
            "a part at the top of the keyboard got a squashed window")
    }

    func testUpOnScreenIsUpInPitch() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 80)
        let window = 48...72
        let ppt: CGFloat = 96.0 / CGFloat(StudioTick.ppq)
        let top = StudioMidiClipGeometry.noteRect(
            for: note(72, 0, 1), in: rect, pxPerTick: ppt, window: window)
        let bottom = StudioMidiClipGeometry.noteRect(
            for: note(48, 0, 1), in: rect, pxPerTick: ppt, window: window)
        XCTAssertLessThan(top.minY, bottom.minY, "the higher pitch did not draw higher")
        XCTAssertGreaterThanOrEqual(top.minY, rect.minY)
        XCTAssertLessThanOrEqual(bottom.maxY, rect.maxY + 0.001)
    }

    // MARK: - The dense case, measured
    //
    // This canvas repaints continuously while `model.isPlaying`, so a slow note
    // layer does not fail a test — it drops frames in the arrangement while
    // audio is running, which nobody's assertion sees. Hence a number.
    //
    // The note layer is bucketed by velocity into a fixed six `context.fill`
    // calls whatever the note count (the same trick `StudioPianoRollView`
    // already uses for the same reason), and the per-note work left is a rect
    // append and a cull compare. What is measured here is the DELTA against an
    // identical render of an empty clip body, so SwiftUI's and ImageRenderer's
    // own overhead is subtracted out rather than being reported as the cost of
    // drawing notes.

    func testADenseClipsNoteLayerIsCheapEnoughToDrawDuringPlayback() throws {
        // A 22-bar part at 40 notes a bar — an order of magnitude denser than
        // the owner's 56-note piano take — drawn at the zoom that puts the
        // WHOLE clip on a 1400 pt arrangement. Every note is inside the
        // viewport, so nothing here is culled: this is the full cost.
        let bars: Double = 22
        let beats = bars * 4
        let width: CGFloat = 1400
        let rowHeight = StudioTokens.trackHeightDefault
        let pxPerTick = width / (CGFloat(beats) * CGFloat(StudioTick.ppq))
        var dense: [StudioNote] = []
        for i in 0..<880 {
            dense.append(note(
                36 + (i % 48), beats * Double(i) / 880.0, 0.1, velocity: 20 + (i % 100)))
        }
        let denseContent = content(dense)

        func elapsed(_ c: StudioMidiClipContent?, iterations: Int) throws -> Double {
            let start = CACurrentMediaTime()
            for _ in 0..<iterations {
                _ = try raster(c, pxPerTick: pxPerTick, width: width, height: rowHeight)
            }
            return (CACurrentMediaTime() - start) / Double(iterations)
        }

        _ = try elapsed(denseContent, iterations: 5)          // warm the renderer
        let iterations = 25
        let bare = try elapsed(nil, iterations: iterations)
        let dense880 = try elapsed(denseContent, iterations: iterations)
        let noteLayer = max(0, dense880 - bare)

        // Proof the measurement measured something: with nothing culled, all
        // 880 notes must actually have landed on the canvas.
        let ink = try raster(denseContent, pxPerTick: pxPerTick, width: width, height: rowHeight)
            .ink(over: try raster(nil, pxPerTick: pxPerTick, width: width, height: rowHeight))
        XCTAssertGreaterThan(
            ink.count, 3000,
            "the dense fixture only put \(ink.count) pixels on the canvas, so the timing below is timing an empty clip and means nothing")

        print(String(
            format: "MIDI note layer: 880 notes over 22 bars at %.0f x %.0f = %.3f ms per draw (empty clip body %.3f ms, dense render %.3f ms, %d note pixels)",
            width, rowHeight, noteLayer * 1000, bare * 1000, dense880 * 1000, ink.count))

        // One 60 Hz frame is 16.7 ms and holds an entire arrangement — ruler,
        // grid, every lane, every clip. A single 880-note clip taking a whole
        // millisecond of that would already be too much of the budget.
        XCTAssertLessThan(
            noteLayer, 0.001,
            "an 880-note clip cost \(noteLayer * 1000) ms of note layer per draw; a busy arrangement would drop frames during playback and the only symptom would be a stuttering timeline")
    }

    // The floors below are written as 1.0 — a whole pixel — and NOT as
    // `StudioMidiClipGeometry.minimumNoteWidth` / `.minimumNoteHeight`. An
    // assertion against the constant it is testing passes for every value of
    // that constant, including zero; the first version of this test did exactly
    // that and a mutation removing the minimum width survived it.

    func testATinyNoteKeepsAWholePixelOfWidth() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 80)
        // A 1/32 note at 1 px per beat: the zoom at which a whole song is on
        // screen at once.
        let r = StudioMidiClipGeometry.noteRect(
            for: note(60, 0, 0.125), in: rect,
            pxPerTick: 1.0 / CGFloat(StudioTick.ppq), window: 24...72)
        XCTAssertGreaterThanOrEqual(
            r.width, 1.0,
            "a short note came out \(r.width) pt wide, which is less than a pixel: zoom out far enough and a busy part reads as an empty clip")
    }

    func testANoteKeepsAWholePixelOfHeightOnACollapsedTrackRow() {
        // A five-octave piano part on a mini-height track row: 61 semitones in
        // 26 pt of usable height is well under a point per semitone.
        let rect = CGRect(x: 0, y: 0, width: 200, height: StudioTokens.trackHeightMini)
        let r = StudioMidiClipGeometry.noteRect(
            for: note(60, 0, 1), in: rect,
            pxPerTick: 96.0 / CGFloat(StudioTick.ppq), window: 36...96)
        XCTAssertGreaterThanOrEqual(
            r.height, 1.0,
            "a note came out \(r.height) pt tall on a collapsed track row, which is less than a pixel: collapse a track and its part disappears")
    }
}
