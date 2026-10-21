import XCTest
import SwiftUI
import AVFoundation
@testable import MajiksMusicStudio

// A stem lane must SHOW THE PART.
//
// The failure this guards against is the one `StudioMidiClipRenderTests` was
// written for: a draw call that runs happily and produces nothing. A test that
// asserted "the row has a waveform" would pass against a lane that drew an
// empty rectangle, so nothing here asserts on properties. Every claim is made
// against rasterized pixels through ImageRenderer — the deterministic,
// no-window path StudioMixerDockTests and StudioPaneSizingTests already use.
//
// Ink MASS, not ink pixel COUNT. Another lane's first pixel test counted ink
// pixels with a low floor and Core Graphics antialiasing kept the count nearly
// unchanged while the content became unreadable. Mass is coverage, which is
// what the eye is actually given.
@MainActor
final class StemLaneRenderTests: XCTestCase {

    // MARK: - Rasterizing probe
    //
    // Framing ONLY. The pixels come from `StemLaneRender.draw`, the same
    // function `StemLaneWaveform`'s Canvas calls — there is no second drawing
    // path for a test to be green against. The path itself comes from
    // `StudioWaveformTileStore.buildPath`, the Studio's tile builder, for the
    // same reason.

    private struct LaneProbe: View {
        /// Empty peaks draw NOTHING: the baseline every measurement is against.
        let peaks: [Float]
        var color: Color = StudioTokens.stemVocals
        var widthFraction: Double = 1
        var progress: Double = 0
        var dimmed: Bool = false

        var body: some View {
            Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                let rect = CGRect(origin: .zero, size: size)
                // The lane's own background, so the baseline is the real empty
                // lane rather than a black frame.
                context.fill(Path(rect), with: .color(StudioTokens.panel))
                var body = context
                StemLaneRender.draw(
                    &body,
                    body: StudioWaveformTileStore.buildPath(peaks: peaks),
                    binCount: peaks.count,
                    rect: rect,
                    color: color,
                    widthFraction: widthFraction,
                    progress: progress,
                    dimmed: dimmed)
            }
        }
    }

    private let probeWidth: CGFloat = 400
    private let probeHeight: CGFloat = StemBreakoutLayout.laneHeight

    private func raster(
        peaks: [Float],
        color: Color = StudioTokens.stemVocals,
        widthFraction: Double = 1,
        progress: Double = 0,
        dimmed: Bool = false
    ) throws -> Raster {
        let view = LaneProbe(peaks: peaks, color: color, widthFraction: widthFraction,
                             progress: progress, dimmed: dimmed)
            .frame(width: probeWidth, height: probeHeight)
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

        /// Total per-channel departure from a baseline: the ink laid down.
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

        /// Ink mass restricted to a horizontal band, so a claim about WHERE
        /// something drew is measurable, not just that it drew.
        func inkMass(over baseline: Raster, xRange: Range<Int>) -> Int {
            guard width == baseline.width, height == baseline.height else { return 0 }
            var mass = 0
            for y in 0..<height {
                for x in xRange where x >= 0 && x < width {
                    let i = (y * width + x) * 4
                    for c in 1..<4 {
                        mass += abs(Int(bytes[i + c]) - Int(baseline.bytes[i + c]))
                    }
                }
            }
            return mass
        }

        /// Per-channel means, for asking "is this lane pink or amber".
        func meanRGB() -> (r: Double, g: Double, b: Double) {
            var r = 0, g = 0, b = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                r += Int(bytes[i + 1]); g += Int(bytes[i + 2]); b += Int(bytes[i + 3])
            }
            let n = Double(bytes.count / 4)
            return (Double(r) / n, Double(g) / n, Double(b) / n)
        }

        func differs(from other: Raster) -> Bool {
            guard width == other.width, height == other.height else { return true }
            for i in stride(from: 0, to: bytes.count, by: 4) {
                for c in 1..<4 where abs(Int(bytes[i + c]) - Int(other.bytes[i + c])) > 2 {
                    return true
                }
            }
            return false
        }
    }

    // MARK: - Fixtures
    //
    // Deliberately DIFFERENT shapes per part, because "four lanes drew
    // something" is a weaker claim than "four lanes drew four distinguishable
    // things", and stems really are different shapes: a vocal breathes, drums
    // are transients, a bass is near-continuous.

    private static let bins = 200

    /// A near-continuous part (bass).
    private static func sustained(_ level: Float) -> [Float] {
        (0..<bins).map { _ in level }
    }

    /// Sharp transients with silence between (drums).
    private static func transients() -> [Float] {
        (0..<bins).map { $0 % 16 == 0 ? 1.0 : 0.02 }
    }

    /// A slow swell (a vocal phrase).
    private static func swell() -> [Float] {
        (0..<bins).map { Float(sin(Double($0) / Double(bins) * .pi)) }
    }

    // MARK: - 1. A lane with audio is not a lane without

    func testALaneWithAudioDrawsAndAnEmptyOneDoesNot() throws {
        let empty = try raster(peaks: [])
        let loud = try raster(peaks: Self.sustained(0.9))

        XCTAssertTrue(loud.differs(from: empty),
                      "a stem with audio rasterized identically to a stem with none")

        // An empty lane must lay down NO ink at all — not merely less.
        XCTAssertEqual(empty.inkMass(over: empty), 0)

        // And the waveform's ink is a large fraction of the lane, not a hairline.
        // Full-scale sustained peaks at 0.75 body alpha over the panel colour:
        // measured floor with generous headroom under it.
        let mass = loud.inkMass(over: empty)
        XCTAssertGreaterThan(mass, 400_000,
                             "the lane drew something, but far too little of it to read as a waveform")
    }

    func testAnAllSilentPartDrawsFarLessInkThanALoudOne() throws {
        let empty = try raster(peaks: [])
        let silent = try raster(peaks: Self.sustained(0.0))
        let loud = try raster(peaks: Self.sustained(0.9))

        let silentMass = silent.inkMass(over: empty)
        let loudMass = loud.inkMass(over: empty)
        // A silent part is a flat midline: some ink (the line itself) but a
        // tiny fraction of a loud part's. If these were within an order of
        // magnitude the lane would not be showing amplitude at all.
        XCTAssertLessThan(silentMass * 10, loudMass,
                          "silence and full scale draw nearly the same amount of ink, so the lane is not showing level")
    }

    // MARK: - 2. Four parts read as four different lanes

    func testFourStemsDrawFourDistinguishableLanes() throws {
        let empty = try raster(peaks: [])
        let vocals = try raster(peaks: Self.swell(), color: StudioTokens.stemVocals)
        let drums = try raster(peaks: Self.transients(), color: StudioTokens.stemDrums)
        let bass = try raster(peaks: Self.sustained(0.7), color: StudioTokens.stemBass)
        let other = try raster(peaks: Self.sustained(0.3), color: StudioTokens.stemOther)

        let lanes = [("vocals", vocals), ("drums", drums), ("bass", bass), ("other", other)]

        // Every one drew.
        for (name, lane) in lanes {
            XCTAssertGreaterThan(lane.inkMass(over: empty), 50_000,
                                 "the \(name) lane is effectively blank")
        }

        // And no two are the same picture.
        for i in 0..<lanes.count {
            for j in (i + 1)..<lanes.count {
                XCTAssertTrue(lanes[i].1.differs(from: lanes[j].1),
                              "\(lanes[i].0) and \(lanes[j].0) rasterized identically")
            }
        }
    }

    func testEachStemLaneCarriesItsOwnStemColour() throws {
        // The defect this closes: rows were coloured by ROW INDEX from a
        // rotating palette, so the vocal's colour depended on how many stems
        // the session happened to have. Now vocals are pink (#FF5FA2, red-
        // dominant), drums amber (#FFB020, red>green>blue), bass violet
        // (#8B5CF6, blue-dominant), other teal (#2BD9C7, green/blue-dominant) —
        // the same constants the Studio and Majik's DJ draw.
        let peaks = Self.sustained(0.95)
        let vocals = try raster(peaks: peaks, color: StudioTokens.stemVocals).meanRGB()
        let drums = try raster(peaks: peaks, color: StudioTokens.stemDrums).meanRGB()
        let bass = try raster(peaks: peaks, color: StudioTokens.stemBass).meanRGB()
        let other = try raster(peaks: peaks, color: StudioTokens.stemOther).meanRGB()

        XCTAssertGreaterThan(vocals.r, vocals.g, "the vocal lane is not drawing pink")
        XCTAssertGreaterThan(vocals.r, vocals.b, "the vocal lane is not drawing pink")

        XCTAssertGreaterThan(drums.r, drums.g, "the drum lane is not drawing amber")
        XCTAssertGreaterThan(drums.g, drums.b, "the drum lane is not drawing amber")

        XCTAssertGreaterThan(bass.b, bass.r, "the bass lane is not drawing violet")
        XCTAssertGreaterThan(bass.b, bass.g, "the bass lane is not drawing violet")

        XCTAssertGreaterThan(other.g, other.r, "the other lane is not drawing teal")
        XCTAssertGreaterThan(other.b, other.r, "the other lane is not drawing teal")
    }

    // MARK: - 3. The states a lane has to distinguish

    func testAMutedLaneIsVisiblyDimmedButStillLegible() throws {
        let empty = try raster(peaks: [])
        let live = try raster(peaks: Self.sustained(0.8), progress: 1, dimmed: false)
        let muted = try raster(peaks: Self.sustained(0.8), progress: 1, dimmed: true)

        let liveMass = live.inkMass(over: empty)
        let mutedMass = muted.inkMass(over: empty)

        // Dim, not gone: a muted part still has to be readable, because
        // deciding what to un-mute means looking at it.
        XCTAssertLessThan(mutedMass, liveMass,
                          "muting a stem changed nothing about how the lane draws")
        XCTAssertGreaterThan(mutedMass * 2, liveMass / 2,
                             "the muted lane faded to effectively invisible")
        // waveformDimAlpha (0.28) against waveformBodyAlpha (0.75): the dimmed
        // lane should carry roughly a third of the ink, so pin a band rather
        // than a bare inequality that any dimming would satisfy.
        XCTAssertLessThan(mutedMass * 2, liveMass,
                          "the 'dimmed' lane is barely dimmer than the live one")
    }

    func testThePlayedPartOfALaneIsBrighterThanTheUnplayedPart() throws {
        let empty = try raster(peaks: [])
        let halfway = try raster(peaks: Self.sustained(0.8), progress: 0.5)

        let width = Int(probeWidth)
        let played = halfway.inkMass(over: empty, xRange: 0..<(width / 2))
        let unplayed = halfway.inkMass(over: empty, xRange: (width / 2)..<width)

        // Body alpha 0.75 vs dim 0.28: the played half carries clearly more.
        XCTAssertGreaterThan(played, unplayed * 2,
                             "played and unplayed halves of the lane look the same, so the playhead teaches nothing")
        XCTAssertGreaterThan(unplayed, 0,
                             "the unplayed half drew nothing, so the rest of the song is invisible")
    }

    func testAShortStemOccupiesOnlyItsOwnSpanOfTheSharedTimeline() throws {
        // A stem half the session's length must draw across half the lane, NOT
        // be stretched to fill — stretching would put its transients under the
        // wrong moment of a playhead shared with every other lane.
        let empty = try raster(peaks: [])
        let half = try raster(peaks: Self.sustained(0.8), widthFraction: 0.5)

        let width = Int(probeWidth)
        let firstHalf = half.inkMass(over: empty, xRange: 0..<(width / 2))
        let secondHalf = half.inkMass(over: empty, xRange: (width / 2)..<width)

        XCTAssertGreaterThan(firstHalf, 100_000, "the short stem drew nothing in its own span")
        XCTAssertEqual(secondHalf, 0,
                       "the short stem drew past its own length, so it is stretched and its timing is a lie")
    }

    // MARK: - 4. Geometry the drawing must respect

    func testDegenerateInputsDrawNothingRatherThanFaulting() throws {
        let empty = try raster(peaks: [])
        XCTAssertEqual(try raster(peaks: [], widthFraction: 1).inkMass(over: empty), 0)
        XCTAssertEqual(try raster(peaks: Self.sustained(0.8), widthFraction: 0).inkMass(over: empty), 0)
        XCTAssertEqual(try raster(peaks: Self.sustained(0.8), widthFraction: -5).inkMass(over: empty), 0)
    }

    func testTheLaneNeverDrawsOutsideItsOwnRect() throws {
        // Full-scale peaks at the 0.92 height factor: the top and bottom rows
        // of the lane must stay the background, or a hot stem would appear
        // clipped flat by the lane edge and bleed into its neighbours.
        let loud = try raster(peaks: Self.sustained(1.0))
        let empty = try raster(peaks: [])
        var edgeMass = 0
        for x in 0..<loud.width {
            for y in [0, loud.height - 1] {
                let i = (y * loud.width + x) * 4
                for c in 1..<4 {
                    edgeMass += abs(Int(loud.bytes[i + c]) - Int(empty.bytes[i + c]))
                }
            }
        }
        XCTAssertEqual(edgeMass, 0,
                       "a full-scale stem drew into the lane's top/bottom edge rows")
    }
}

// MARK: - 5. From a real audio FILE, not from a peaks array
//
// WHY A SECOND CLASS, AND WHY IT DOES NOT USE `LaneProbe`.
//
// Everything above is green against the shipped build, and the shipped build
// drew four blank lanes on the owner's own session. It could be, because every
// test above hands `StemLaneRender.draw` a peaks array a Swift literal made.
// The drawing was never the defect. The defect was that no peaks ever reached
// it: `WaveformData.extractSamples` built a MONO `AVAudioPCMBuffer` and asked
// `AVAudioFile.read(into:)` to fill it from a STEREO file, which is
// kAudio_ParamError (-50), which the `catch` turned into `[]`. htdemucs writes
// stereo, so this was every stem of every separation, every time.
//
// So these tests start at a FILE ON DISK and end at pixels, through
// `WaveformData.extractSamples` -> `StemLaneRender.body(forSamples:)` ->
// `StemLaneRender.draw` — the three calls the view makes, in order, with
// nothing substituted. The one thing they cannot see is the view's `onChange`
// closure that strings them together; that is stated as a survivor in the
// commit rather than asserted by a `contains` over the source, which is the
// shape of guard this repo has already been burned by twice.
@MainActor
final class StemLaneRealAudioTests: XCTestCase {

    private let probeWidth: CGFloat = 400
    private let probeHeight: CGFloat = StemBreakoutLayout.laneHeight

    /// Draws a body path exactly as the lane view does. `body` rather than
    /// `peaks` on purpose: the input is what the extractor really returned.
    private struct FileLaneProbe: View {
        let body_: Path
        let binCount: Int
        var color: Color = StudioTokens.stemBass

        var body: some View {
            Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .color(StudioTokens.panel))
                var slice = context
                StemLaneRender.draw(
                    &slice,
                    body: body_,
                    binCount: binCount,
                    rect: rect,
                    color: color,
                    widthFraction: 1,
                    progress: 0,
                    dimmed: false)
            }
        }
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]

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

        /// How many rows of column `x` carry ink. The lane's body is symmetric
        /// about the midline, so this is a direct read of DRAWN HEIGHT — which
        /// is what a doubled loudness curve changes and an ink-mass total
        /// blurs.
        func inkedRows(atX x: Int, over baseline: Raster) -> Int {
            guard width == baseline.width, height == baseline.height,
                  x >= 0, x < width else { return 0 }
            var rows = 0
            for y in 0..<height {
                let i = (y * width + x) * 4
                var d = 0
                for c in 1..<4 { d += abs(Int(bytes[i + c]) - Int(baseline.bytes[i + c])) }
                if d > 6 { rows += 1 }
            }
            return rows
        }
    }

    private func raster(body: Path, binCount: Int) throws -> Raster {
        let view = FileLaneProbe(body_: body, binCount: binCount)
            .frame(width: probeWidth, height: probeHeight)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.cgImage, "the probe did not rasterize at all")
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Raster(width: w, height: h, bytes: bytes)
    }

    // MARK: The ImageRenderer noise floor
    //
    // ⚠️ `ImageRenderer` is NOT bit-deterministic. The FIRST pair of renders in
    // a process differs by tens of channel-units (glyph-cache warm-up) and
    // every subsequent pair by 0. Two assertions in this repo were written as
    // `XCTAssertEqual(mass, 0)` and passed only because an alphabetically
    // earlier test happened to pay the warm-up. `RUST_TEST_THREADS` and
    // `--filter` both change that ordering, so no assertion here may depend on
    // it: each test MEASURES the floor for itself and bounds against what it
    // measured.
    private func measuredFloor(binCount: Int, body: Path) throws -> Int {
        let a = try raster(body: body, binCount: binCount)
        let b = try raster(body: body, binCount: binCount)
        return a.inkMass(over: b)
    }

    // MARK: Fixtures

    /// Writes a real WAV with `channels` channels, Int16 — the format htdemucs
    /// writes and the format the owner's four stems are on disk (verified with
    /// `afinfo`: "2 ch, 44100 Hz, Int16, interleaved").
    ///
    /// The content is a full-scale transient in the first bucket over a
    /// -20 dBFS body, the shape `LibraryWaveformScaleTests` uses, so the
    /// expected drawn height is a number and not a hand-wave.
    private func writeSong(channels: AVAudioChannelCount, frames: Int, to url: URL) throws {
        let rate = 44_100.0
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        var writer: AVAudioFile? = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: Int(channels),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let transient = max(1, frames / 20)
        for c in 0..<Int(channels) {
            for i in 0..<frames {
                data[c][i] = i < transient ? 1.0 : 0.1
            }
        }
        try writer!.write(from: buffer)
        // AVAudioFile finalises the header on deinit; reading it back while the
        // writer is alive returns an empty file. (It did, in the sibling test
        // in LibraryAndPublisherEvidenceTests, and that test read zero buckets
        // rather than wrong ones.)
        writer = nil
    }

    private func tempDir() throws -> URL {
        // PID as well as UUID: five lanes share this machine and its temp dir,
        // and a stray directory should say which process to blame.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "majiks-stemlane-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - The defect, asserted end to end

    func testAStereoStemDecodesAndTheLaneDrawsRealInk() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("bass.wav")
        try writeSong(channels: 2, frames: 44_100, to: url)

        // VACUITY GUARD 1 — the fixture must really be the shape that broke.
        // A mono fixture here would make every assertion below pass against
        // the shipped bug, which is exactly how this defect survived: the one
        // existing test that reads a real file through `extractSamples` writes
        // a MONO probe.
        let opened = try AVAudioFile(forReading: url)
        XCTAssertEqual(opened.processingFormat.channelCount, 2,
                       "the fixture decoded as mono, so this test cannot see the defect at all")
        XCTAssertGreaterThan(opened.length, 0, "the fixture wrote no audio")

        // The real extractor, on a real file.
        let samples = WaveformData.extractSamples(from: url, count: 400)

        // VACUITY GUARD 2 — no peaks means no path means no ink, and the ink
        // assertion below would be measuring the wrong thing's absence.
        XCTAssertEqual(samples.count, 400,
                       "extractSamples returned \(samples.count) bins for a stereo file; "
                       + "0 is the shipped defect (AVAudioFile.read threw -50 into a mono buffer)")
        let decodedPeak = try XCTUnwrap(samples.max())
        XCTAssertGreaterThan(decodedPeak, 0.9,
                             "the decoded peak is \(decodedPeak), not the full-scale transient written")

        // The real path builder the view uses.
        let body = StemLaneRender.body(forSamples: samples)
        XCTAssertFalse(body.isEmpty, "the lane body path is empty, so draw() returns immediately")

        // Pixels, bounded against a floor measured in THIS process, in THIS
        // test — never against a constant, and never against a zero that only
        // holds when some other test warmed the glyph cache first.
        let blank = try raster(body: Path(), binCount: 0)
        let floor = try measuredFloor(binCount: 0, body: Path())
        let drawn = try raster(body: body, binCount: samples.count)
        let mass = drawn.inkMass(over: blank)

        XCTAssertGreaterThan(mass, floor * 1_000,
                             "a stereo stem's lane drew \(mass) channel-units of ink over an "
                             + "empty lane, against a measured renderer floor of \(floor). "
                             + "That is a blank lane.")

        // THE LOAD-BEARING CLAIM, and the reason the number above is not it.
        //
        // "Drew a lot of ink" is satisfied by ink of any shape, including ink
        // that has nothing to do with the file. So assert the drawn HEIGHT at a
        // known bin against the height the DECODER produced for that same bin —
        // expectation computed from real decoded audio, not from a constant I
        // chose. If the decode and the drawing ever stop agreeing, this moves
        // and the mass total does not.
        //
        // A first attempt used an all-zero "silent lane" as the derived floor.
        // That is worthless: `buildPath(heights:)` on zeros is a ZERO-AREA
        // closed path, so its mass is ~0 and any `> silent * 10` passes
        // trivially. A bound that cannot fail is not a bound.
        let bodyBin = 300
        let x = Int(probeWidth) * bodyBin / samples.count
        let expectedRows = Double(samples[bodyBin]) * Double(probeHeight) * 0.92
        XCTAssertEqual(Double(drawn.inkedRows(atX: x, over: blank)), expectedRows, accuracy: 4,
                       "at bin \(bodyBin) the decoder produced \(samples[bodyBin]) but the lane "
                       + "drew \(drawn.inkedRows(atX: x, over: blank)) rows, not the "
                       + "\(Int(expectedRows)) that height implies")
    }

    func testChannelCountDoesNotDecideWhetherAStemHasAWaveform() throws {
        // The mono and stereo files carry the SAME signal. If the two lanes do
        // not draw the same picture, the decode is channel-dependent — which is
        // the whole defect, stated as a difference rather than as an absolute.
        let dir = try tempDir()
        let mono = dir.appendingPathComponent("mono.wav")
        let stereo = dir.appendingPathComponent("stereo.wav")
        try writeSong(channels: 1, frames: 44_100, to: mono)
        try writeSong(channels: 2, frames: 44_100, to: stereo)

        let monoSamples = WaveformData.extractSamples(from: mono, count: 400)
        let stereoSamples = WaveformData.extractSamples(from: stereo, count: 400)

        XCTAssertEqual(monoSamples.count, 400, "the mono control itself failed to decode")
        XCTAssertEqual(stereoSamples.count, monoSamples.count,
                       "the stereo copy of the same audio produced \(stereoSamples.count) bins "
                       + "against the mono copy's \(monoSamples.count)")

        let blank = try raster(body: Path(), binCount: 0)
        let monoMass = try raster(body: StemLaneRender.body(forSamples: monoSamples),
                                  binCount: monoSamples.count).inkMass(over: blank)
        let stereoMass = try raster(body: StemLaneRender.body(forSamples: stereoSamples),
                                    binCount: stereoSamples.count).inkMass(over: blank)

        XCTAssertGreaterThan(monoMass, 200_000, "the mono control drew nothing either")
        // Int16 quantisation is the only thing that may differ between them.
        XCTAssertEqual(Double(stereoMass), Double(monoMass), accuracy: Double(monoMass) * 0.02,
                       "mono drew \(monoMass) and stereo drew \(stereoMass) for identical audio")
    }

    func testAHardPannedPartIsNotLostByReadingOnlyTheFirstChannel() throws {
        // Reading `floatChannelData[0]` and calling it the file is the OTHER
        // way to be wrong about channels, and it is the shape the old code was
        // already in — it asked for a mono buffer, so it could only ever have
        // seen one. A part panned hard right (a doubled guitar, the far side of
        // a stereo pad) would draw as silence. The engine does not have this
        // bug: `host.rs` takes `peak.max(frame[0].abs()).max(frame[1].abs())`.
        let dir = try tempDir()
        let url = dir.appendingPathComponent("panned.wav")

        let rate = 44_100.0, frames = 44_100
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        do {
            var writer: AVAudioFile? = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<frames {
                data[0][i] = 0                                  // left: silence
                data[1][i] = i % 200 < 40 ? 0.95 : 0.0          // right: the whole part
            }
            try writer!.write(from: buffer)
            writer = nil
        }

        let samples = WaveformData.extractSamples(from: url, count: 400)
        XCTAssertEqual(samples.count, 400, "the panned fixture did not decode at all")

        // VACUITY GUARD — the fixture must really be silent on the left, or a
        // channel-0-only reader would pass this by accident. Asserted against
        // the decode of a LEFT-only copy of the same shape: it must come back
        // as nothing to draw.
        let leftOnly = dir.appendingPathComponent("left-silent-check.wav")
        do {
            var writer: AVAudioFile? = try AVAudioFile(
                forWriting: leftOnly,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            let monoFormat = try XCTUnwrap(
                AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<frames { data[0][i] = 0 }
            try writer!.write(from: buffer)
            writer = nil
        }
        // A wholly silent file decodes to a full row of ZEROS, not to nothing.
        // That distinction is deliberate: `bucketedAnything` returns [] only when
        // the decode itself failed, so an empty result and a flat midline must not
        // look alike. An earlier version of this guard asserted `.isEmpty` here and
        // failed against the very design it was written to protect.
        let silentSamples = WaveformData.extractSamples(from: leftOnly, count: 400)
        XCTAssertEqual(silentSamples.count, 400,
                       "the silent control did not decode; every comparison below is vacuous")
        XCTAssertEqual(silentSamples.max() ?? 1, 0, accuracy: 0.0001,
                       "the silent control is not actually silent, so it cannot stand in for "
                       + "a dropped channel")

        let blank = try raster(body: Path(), binCount: 0)
        let mass = try raster(body: StemLaneRender.body(forSamples: samples),
                              binCount: samples.count).inkMass(over: blank)

        // The bound is DERIVED, not chosen. A reader that took channel 0 only would
        // decode this hard-panned file to exactly what the silent control decodes to,
        // so `mass` would collapse onto `silentMass`. Comparing against a constant
        // could not make that argument; comparing against the silent raster does.
        let silentMass = try raster(body: StemLaneRender.body(forSamples: silentSamples),
                                    binCount: silentSamples.count).inkMass(over: blank)
        XCTAssertGreaterThan(mass, silentMass * 10,
                             "a part panned hard right drew \(mass) channel-units against "
                             + "\(silentMass) for silence — the extractor is looking at one "
                             + "channel and calling it the file")
    }

    func testTheLaneAppliesTheLoudnessCurveOnceNotTwice() throws {
        // `WaveformData.extractSamples` returns HEIGHTS — it has already put
        // the normalised peak through `StudioWaveformScale`. Building the body
        // with `buildPath(peaks:)` curves them a SECOND time: a -20 dBFS body
        // is 0.1 -> 0.3162 -> 0.5623, so it draws 1.78x too tall and the
        // loud:quiet ratio collapses from 3.16 to 1.78 — under the > 2.0 bound
        // `LibraryWaveformScaleTests.dynamicsSurvive` states as the point of
        // having a curve.
        let dir = try tempDir()
        let url = dir.appendingPathComponent("song.wav")
        try writeSong(channels: 2, frames: 44_100, to: url)

        let samples = WaveformData.extractSamples(from: url, count: 400)
        XCTAssertEqual(samples.count, 400, "no samples: everything below is vacuous")

        // A bin in the -20 dBFS body, well clear of the 5%-wide transient.
        let bodyBin = 300
        XCTAssertEqual(Double(samples[bodyBin]), 0.3162, accuracy: 0.02,
                       "the extractor's own output for a -20 dBFS body is not the single-curve "
                       + "height, so this test would be pinning the wrong number")

        let blank = try raster(body: Path(), binCount: 0)
        let once = try raster(body: StemLaneRender.body(forSamples: samples),
                              binCount: samples.count)
        let twice = try raster(body: StudioWaveformTileStore.buildPath(peaks: samples),
                               binCount: samples.count)

        let x = Int(probeWidth) * bodyBin / samples.count
        let onceRows = once.inkedRows(atX: x, over: blank)
        let twiceRows = twice.inkedRows(atX: x, over: blank)

        // The geometry: the DECODER's own height for this bin * laneHeight *
        // 0.92, doubled for the symmetric body. Derived from the decode, not
        // from the 0.3162 literal — that literal is pinned separately above,
        // against the fixture's written amplitude and the documented curve, so
        // the two anchors are independent.
        let expected = Double(samples[bodyBin]) * Double(probeHeight) * 0.92
        XCTAssertEqual(Double(onceRows), expected, accuracy: 4,
                       "the lane drew \(onceRows) rows for a -20 dBFS body; "
                       + "\(Int(expected)) is one curve, \(Int(0.5623 * Double(probeHeight) * 0.92)) is two")
        XCTAssertGreaterThan(twiceRows, onceRows + 8,
                             "double-curving did not change the drawn height, so this test "
                             + "cannot tell the two apart and proves nothing")
    }
}
