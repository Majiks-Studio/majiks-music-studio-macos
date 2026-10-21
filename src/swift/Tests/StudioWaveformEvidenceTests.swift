import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// WHAT THE ARRANGEMENT DRAWS, MEASURED AGAINST KNOWN AUDIO.
//
// The owner's report: "why don't I see much waveform on the bass track?
// Actually vocals look a little light. Are those real waveforms or are they
// mock?" They are real — `StudioHost::waveform` reads decoded samples out of
// `self.sources` and takes a true peak per bin — and they were still wrong,
// for two independent reasons this file pins.
//
// 1. UNIT CONFLATION between the UI's tile lattice and the engine's.
//    `StudioTileScheme`'s bucket is TICKS per bin (120 << bucket at 960 PPQ).
//    `StudioHost::waveform`'s `zoom` is SAMPLES per bin (256 << zoom). The
//    seam passed the bucket straight through as the zoom. At the owner's
//    130.125 BPM / 48 kHz one tick is 23.05 samples, so a bucket-2 bin is
//    11066 samples and a zoom-2 bin is 1024 — a factor of 10.8. Four tiles of
//    256 bins therefore covered 21.8 s of a 210 s song, drawn across the whole
//    clip: the arrangement showed the INTRO, stretched, for three and a half
//    minutes. Nothing looked blank, which is why it shipped.
//
// 2. LINEAR AMPLITUDE. A peak of 0.1 (-20 dBFS) drawn linearly on the default
//    90 pt track row is 4.2 pt of ink. That is not visible on a television
//    across a room, and it is plainly audible.
//
// Measured on the owner's own stems (peak/RMS unchanged by any of this):
//
//   mean drawn half-height, of 42 pt available, default 90 pt row
//   stem     shipped   unit fix   unit fix + curve
//   Vocals     3.4        9.9         16.7
//   Drums      3.3       10.2         15.4
//   Bass       3.8        6.7         12.0
//   Other      4.5       10.1         17.9

@MainActor
final class StudioWaveformEvidenceTests: XCTestCase {

    // MARK: - The unit bridge (pure; runs under both engines)

    /// The owner's session, exactly: 130.125 BPM, 48 kHz, 960 PPQ.
    private let ownerSamplesPerTick = StudioEngineTileFetch.samplesPerTick(
        sampleRate: 48_000, bpm: 130.125)

    func testSamplesPerTickIsTheProjectsOwnNumber() {
        // 48000 * 60 / (130.125 * 960) = 23.05475...
        XCTAssertEqual(ownerSamplesPerTick, 23.0547, accuracy: 0.0005)
        // 120 BPM at 48 kHz is exactly 25, which `TempoMap::tick_to_frame`
        // pins on the Rust side (tempo.rs: tick_to_frame_is_exact_at_120).
        XCTAssertEqual(
            StudioEngineTileFetch.samplesPerTick(sampleRate: 48_000, bpm: 120), 25.0,
            accuracy: 1e-9)
    }

    func testTheEngineZoomIsChosenInSAMPLESNotBuckets() {
        let ticksPerBin = Double(StudioTileScheme.ticksPerBin(bucket: 2))
        XCTAssertEqual(ticksPerBin, 480)
        let spb = ticksPerBin * ownerSamplesPerTick
        XCTAssertEqual(spb, 11066.3, accuracy: 0.5)
        // 256 << 5 = 8192 fits inside an 11066-sample UI bin; 256 << 6 = 16384
        // does not. The shipped seam asked for zoom 2 (1024 samples).
        XCTAssertEqual(StudioEngineTileFetch.zoom(forSamplesPerUIBin: spb), 5)
    }

    /// THE DEFECT, as a number. Tile 3 of the owner's bass clip must read the
    /// audio around 2 minutes 57 into the song. The shipped seam read 16.4 s.
    func testTheFourthTileReadsTheFOURTHQuarterOfTheClipNotTheIntro() {
        let spb = Double(StudioTileScheme.ticksPerBin(bucket: 2)) * ownerSamplesPerTick
        let plan = StudioEngineTileFetch.plan(
            tileIndex: 3, binsPerTile: StudioTileScheme.binsPerTile,
            samplesPerUIBin: spb, sourceOffsetSamples: 0)
        XCTAssertEqual(plan.zoom, 5)
        XCTAssertEqual(plan.samplesPerEngineBin, 8192)
        XCTAssertEqual(plan.startBin, 1037)
        XCTAssertEqual(plan.maxBins, 347)
        let startSeconds = plan.firstSample / 48_000
        XCTAssertGreaterThan(startSeconds, 150.0, """
            tile 3 begins \(startSeconds) s into the source. The shipped seam \
            passed the tile bucket through as the engine's zoom, which put this \
            tile at 16.4 s — so four tiles covered 21.8 s of a 210 s song and \
            the whole arrangement drew the intro, stretched.
            """)
        XCTAssertLessThan(startSeconds, 180.0)

        // And the four tiles between them must cover the clip, not 10% of it.
        let covered = (plan.firstSample + Double(StudioTileScheme.binsPerTile) * spb) / 48_000
        XCTAssertGreaterThan(covered, 200.0,
                             "four tiles cover only \(covered) s of a 210 s clip")
    }

    /// A peak anywhere in the engine's bins must survive the reduction onto the
    /// UI lattice. A resample that averaged, or that dropped the tail of each
    /// span, would lose exactly the transients a waveform exists to show.
    func testTheReductionOntoTheUILatticeKeepsPeaks() {
        let spb = 3000.0
        let plan = StudioEngineTileFetch.plan(
            tileIndex: 0, binsPerTile: 4, samplesPerUIBin: spb, sourceOffsetSamples: 0)
        XCTAssertEqual(plan.samplesPerEngineBin, 2048, "zoom must fit inside the UI bin")
        // 6 engine bins of 2048 = 12288 samples covers 4 UI bins of 3000.
        var engine = [Float](repeating: 0, count: 6)
        engine[3] = 1.0
        let out = StudioEngineTileFetch.resample(
            enginePeaks: engine, plan: plan, binsPerTile: 4, samplesPerUIBin: spb)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out.max() ?? 0, 1.0, accuracy: 1e-6,
                       "the reduction lost a full-scale engine bin: \(out)")
        // Engine bin 3 spans samples 6144..8192, i.e. UI bin 2 (6000..9000).
        XCTAssertEqual(out[2], 1.0, accuracy: 1e-6, "the peak landed in the wrong bin: \(out)")
        XCTAssertEqual(out[0], 0.0, accuracy: 1e-6)
    }

    /// Nothing before the clip's source origin may be invented.
    func testBinsBeforeTheClipOriginDrawNothing() {
        let spb = 3000.0
        let plan = StudioEngineTileFetch.plan(
            tileIndex: 0, binsPerTile: 4, samplesPerUIBin: spb,
            sourceOffsetSamples: 9000)   // the clip starts 3 UI bins in
        XCTAssertLessThan(plan.firstSample, 0)
        let out = StudioEngineTileFetch.resample(
            enginePeaks: [Float](repeating: 1.0, count: 8), plan: plan,
            binsPerTile: 4, samplesPerUIBin: spb)
        XCTAssertEqual(out[0], 0, accuracy: 1e-6, "drew audio before the clip's source origin")
        XCTAssertEqual(out[1], 0, accuracy: 1e-6)
        XCTAssertEqual(out[2], 0, accuracy: 1e-6)
        XCTAssertEqual(out[3], 1.0, accuracy: 1e-6, "dropped the first bin of real audio")
    }

    // MARK: - The curve (pure)

    /// The default track row is 90 pt (`StudioTokens.trackHeightDefault`), and
    /// `drawWaveform` draws into `rect.height / 2 - 3`.
    private let halfHeight = StudioTokens.trackHeightDefault / 2 - 3   // 42

    func testTheCurveIsMonotoneAndPinnedAtBothEnds() {
        XCTAssertEqual(StudioWaveformScale.height(forPeak: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(StudioWaveformScale.height(forPeak: 1), 1, accuracy: 1e-6)
        // sqrt: -3 dBFS (0.7071) -> 0.8409, -20 dBFS (0.1) -> 0.3162,
        // -40 dBFS (0.01) -> 0.1. Hardcoded, not derived from the function.
        XCTAssertEqual(StudioWaveformScale.height(forPeak: 0.7071), 0.8409, accuracy: 0.0005)
        XCTAssertEqual(StudioWaveformScale.height(forPeak: 0.1), 0.3162, accuracy: 0.0005)
        XCTAssertEqual(StudioWaveformScale.height(forPeak: 0.01), 0.1, accuracy: 0.0005)
        // Out-of-range input is clamped, never reflected or wrapped.
        XCTAssertEqual(StudioWaveformScale.height(forPeak: -0.5), 0, accuracy: 1e-6)
        XCTAssertEqual(StudioWaveformScale.height(forPeak: 4), 1, accuracy: 1e-6)
    }

    /// The requirement in the owner's words: a -3 dB tone must draw visibly
    /// taller than a -20 dB one, and BOTH must be visible. Asserted in points
    /// on the real row height against hardcoded expectations, not against the
    /// renderer's own output.
    func testLoudAndQuietBothDrawAndTheLoudOneDrawsTaller() {
        func drawnHalfHeightPt(peak: Float) -> CGFloat {
            let path = StudioWaveformTileStore.buildPath(
                peaks: [Float](repeating: peak, count: 16))
            // buildPath is unit space, y in -1...1 around the midline.
            return path.boundingRect.height / 2 * halfHeight
        }
        let loud = drawnHalfHeightPt(peak: 0.7071)     // -3 dBFS
        let quiet = drawnHalfHeightPt(peak: 0.1)       // -20 dBFS

        // -3 dBFS: 0.8409 * 42 = 35.3 pt.
        XCTAssertEqual(loud, 35.3, accuracy: 1.0)
        // -20 dBFS: 0.3162 * 42 = 13.3 pt. Drawn LINEARLY this is 4.2 pt,
        // which is what shipped and what the owner could not see. The floor
        // below is the whole point of the curve and fails at 4.2.
        XCTAssertGreaterThan(quiet, 10.0, """
            a -20 dBFS peak draws \(quiet) pt on a 90 pt row. Linear peak-per-bin \
            gives 4.2 pt — invisible on a television across a room, for material \
            that is plainly audible.
            """)
        XCTAssertEqual(quiet, 13.3, accuracy: 1.0)
        // Still clearly ORDERED: the curve must not flatten loud into quiet.
        XCTAssertGreaterThan(loud, quiet * 2.0,
                             "the curve compressed the dynamic range out of the picture")
        // And silence stays silent.
        XCTAssertEqual(drawnHalfHeightPt(peak: 0), 0, accuracy: 1e-6)
    }

    // MARK: - The transport VOLUME cap (pure)

    /// "don't think volume works at the top".
    ///
    /// `StudioFaderControl` — the fader this control's own comment says it
    /// matches — inverts its cap position exactly: `p = 1 - (y - 7) / (h - 14)`
    /// against `capY = (h - 14) * (1 - pos)`, i.e. it compensates for the cap's
    /// own length. The transport control divided by the FULL track width while
    /// drawing the cap over `width - capWidth`, so the value it committed
    /// disagreed with where the cap was drawn, and +12 dB could not be reached
    /// by clicking the cap at all.
    func testClickingTheCapCommitsTheValueTheCapIsDrawnAt() {
        let w = Double(StudioTransportVolume.trackWidth)     // 72
        let cap = Double(StudioTransportVolume.capWidth)     // 10
        XCTAssertEqual(w, 72)
        XCTAssertEqual(cap, 10)

        for pos in [0.0, 0.25, 0.5, StudioFaderTaper.dbToPos(0), 0.9, 1.0] {
            let x = StudioTransportVolume.capX(forPos: pos, width: w) + cap / 2
            let back = StudioTransportVolume.pos(atX: x, width: w)
            XCTAssertEqual(back, pos, accuracy: 1e-9,
                           "grabbing the cap at pos \(pos) committed pos \(back)")
        }

        // In dB, on the shared taper, at the two places it matters:
        // unity (the default) and the top of the range.
        let unityPos = StudioFaderTaper.dbToPos(0)
        let unityX = StudioTransportVolume.capX(forPos: unityPos, width: w) + cap / 2
        XCTAssertEqual(
            StudioFaderTaper.posToDB(StudioTransportVolume.pos(atX: unityX, width: w)),
            0.0, accuracy: 1e-6,
            "clicking the cap at unity moved the master gain")
        // The right-hand end of the travel is +12 dB and is reachable.
        let topX = StudioTransportVolume.capX(forPos: 1.0, width: w) + cap / 2
        XCTAssertEqual(topX, 67.0, accuracy: 1e-9)
        XCTAssertEqual(
            StudioFaderTaper.posToDB(StudioTransportVolume.pos(atX: topX, width: w)),
            12.0, accuracy: 1e-6,
            "+12 dB is not reachable by clicking the cap at the end of its travel")
        // And the left-hand end is the floor, not something above it.
        let botX = StudioTransportVolume.capX(forPos: 0.0, width: w) + cap / 2
        XCTAssertEqual(
            StudioFaderTaper.posToDB(StudioTransportVolume.pos(atX: botX, width: w)),
            -60.0, accuracy: 1e-6)
    }

    /// The commit path itself still sends what the position says. Drives the
    /// REAL control, not a rebuilt twin.
    func testTheControlCommitsTheTaperValue() {
        var sent: [Double] = []
        let control = StudioTransportVolumeControl(valueDB: 0) { sent.append($0) }
        XCTAssertEqual(control.commit(position: 1.0), 12.0)
        XCTAssertEqual(control.commit(position: 0.0), -60.0)
        XCTAssertEqual(control.commit(position: StudioFaderTaper.dbToPos(-6)), -6.0, accuracy: 1e-9)
        XCTAssertEqual(sent, [12.0, -60.0, -6.0])
    }
}
// MARK: - The seam (real engine, gate 7)

#if REAL_ENGINE

/// THE JOIN for the waveform and for master volume.
///
/// `MAJIKS_ENGINE=mock swift test` cannot see either defect. `StudioMockEngine
/// .generateTile` synthesises peaks from the tile key itself, so the mock's
/// tiles agree with any tick/sample conflation whatsoever — the conflation
/// lived in the ONE place the mock does not model. And the mock stores master
/// gain as a `Double` on a Swift struct with no JSON in between, so a snapshot
/// key that never matched would round-trip perfectly in every mock test.
///
/// Silent: `RealStudioEngine(dataDir:audible:)` defaults `audible` to false and
/// nothing here starts a live session, so this bundle opens no output device.
@MainActor
final class RealEngineWaveformAndMasterVolumeTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("majiks-waveform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A real 16-bit mono WAV: `silentSeconds` of digital silence, then
    /// `toneSeconds` of 440 Hz at `amplitude`. Written by hand so the test owns
    /// its own known audio and depends on no fixture directory.
    private func writeHalfSilentTone(
        named name: String, amplitude: Double,
        silentSeconds: Int = 12, toneSeconds: Int = 12
    ) throws -> String {
        let rate = 48_000
        var body = Data()
        body.reserveCapacity((silentSeconds + toneSeconds) * rate * 2)
        for _ in 0..<(silentSeconds * rate) {
            var s = Int16(0)
            withUnsafeBytes(of: &s) { body.append(contentsOf: $0) }
        }
        for i in 0..<(toneSeconds * rate) {
            let v = sin(2 * .pi * 440 * Double(i) / Double(rate)) * amplitude
            var s = Int16((max(-1, min(1, v)) * 32_767).rounded())
            withUnsafeBytes(of: &s) { body.append(contentsOf: $0) }
        }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8)
        wav += le32(36 + body.count)
        wav += Data("WAVEfmt ".utf8)
        wav += le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        wav += Data("data".utf8) + le32(body.count) + body
        let url = tempDir.appendingPathComponent(name)
        try wav.write(to: url)
        return url.path
    }

    /// Every UI bin of a clip, in source order, as the timeline canvas would
    /// draw them: the same bucket, the same tile range, the same store.
    private func drawnPeaks(
        _ engine: RealStudioEngine, clip: StudioClipSnapshot, bucket: Int
    ) async throws -> [Float] {
        let range = StudioTileScheme.tileRange(
            bucket: bucket,
            sourceTicks: clip.sourceOffsetTicks..<(clip.sourceOffsetTicks + clip.lengthTicks))
        var out: [Float] = []
        for index in range {
            let key = StudioTileKey(seed: clip.waveformSeed, bucket: bucket, tileIndex: index)
            let fetched = await engine.waveformTile(key)
            let tile = try XCTUnwrap(fetched, "no tile for index \(index)")
            XCTAssertEqual(tile.peaks.count, StudioTileScheme.binsPerTile)
            out.append(contentsOf: tile.peaks)
        }
        return out
    }

    /// THE DEFECT. Twenty-four seconds of audio: silent for twelve, a -3 dBFS
    /// tone for twelve. The arrangement must draw silence over the first half
    /// of the clip and the tone over the second, and the step between them must
    /// land on the bin the clip's OWN tick geometry says it does.
    ///
    /// Before the fix the seam passed the tile BUCKET through as the engine's
    /// ZOOM. A bucket-0 bin is 120 ticks; a zoom-0 bin is 256 samples. At this
    /// project's tempo that is 2766 samples against 256, so the two tiles that
    /// cover this clip read its first 2.5 s — all silence — and drew that
    /// across the whole 24 s.
    ///
    /// ⚠️ THE TEMPO IS DELIBERATELY NOT THE DEFAULT. At 120 BPM / 48 kHz a tick
    /// is exactly 25 samples, which is also the seam's fallback, so a fixture
    /// at the default tempo cannot tell whether the conversion learned the
    /// project's numbers or simply never looked. 130.125 BPM (the owner's
    /// session) makes a tick 23.05 samples, and a seam that skipped the lookup
    /// puts the step 16 bins early.
    func testTheArrangementDrawsTheAudioWhereTheAudioIs() async throws {
        let engine = try RealStudioEngine(
            dataDir: tempDir.appendingPathComponent("Waveform.mstudio").path, audible: false)
        let tempo = await engine.send(.projectSetTempo(bpm: 130.125))
        XCTAssertTrue(tempo.ok, "project.setTempo: \(tempo.message ?? "no message")")

        let vm = StudioViewModel(engine: engine)
        vm.startPolling()
        for _ in 0..<200 where vm.snapshot == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        vm.stopPolling()

        let path = try writeHalfSilentTone(named: "HalfSilent.wav", amplitude: 0.7071)
        let landed = await vm.performImport(path: path)
        XCTAssertTrue(landed, "the import did not land: \(vm.importStatus)")

        // The snapshot is what teaches the seam the project's sample rate and
        // tempo, exactly as it does in the app.
        let snapshot = await engine.snapshot(ifNewerThan: nil)
        let snap = try XCTUnwrap(snapshot)
        XCTAssertEqual(snap.tempoBPM, 130.125, accuracy: 1e-6, "the tempo did not take")
        let clip = try XCTUnwrap(snap.tracks.compactMap { $0.clips.first }.first,
                                 "the import produced no clip")
        // 24 s at 130.125 BPM / 48 kHz: 1152000 / 23.0547 = 49968 ticks.
        XCTAssertEqual(Double(clip.lengthTicks), 49_968, accuracy: 240,
                       "the fixture is not the length this test reasons about")

        let peaks = try await drawnPeaks(engine, clip: clip, bucket: 0)
        XCTAssertEqual(peaks.count, 512, "two tiles of 256 bins")

        // Where the clip's own geometry says the tone starts: half its length,
        // in bins of `ticksPerBin`. 49968 / 2 / 120 = 208.
        let boundary = Int(clip.lengthTicks / 2 / StudioTileScheme.ticksPerBin(bucket: 0))
        XCTAssertEqual(Double(boundary), 208, accuracy: 2)

        let step = peaks.firstIndex { $0 > 0.35 } ?? -1
        XCTAssertEqual(Double(step), Double(boundary), accuracy: 3, """
            silence gives way to the tone at bin \(step); the clip's tick \
            geometry puts it at \(boundary). A seam that never read the \
            project's tempo would use the 25 samples-per-tick default and put \
            the step at bin 192.
            """)

        let firstHalf = peaks[10..<(boundary - 6)]
        let secondHalf = peaks[(boundary + 6)..<(boundary + 170)]
        let quiet = firstHalf.reduce(Float(0), +) / Float(firstHalf.count)
        let loud = secondHalf.reduce(Float(0), +) / Float(secondHalf.count)

        XCTAssertLessThan(quiet, 0.02,
                          "the silent first half of the clip drew ink (\(quiet))")
        XCTAssertGreaterThan(loud, 0.6, """
            the second half of the clip is a -3 dBFS tone and the arrangement \
            drew \(loud). This is the shipped defect: the UI's tile bucket is \
            TICKS per bin and StudioHost::waveform's zoom is SAMPLES per bin, \
            and the seam passed one through as the other.
            """)
        XCTAssertLessThan(loud, 0.78, "drew louder than the audio actually is")

        // Past the end of the clip there is nothing, and nothing is drawn.
        XCTAssertLessThan(peaks[440..<512].reduce(Float(0), +), 0.05,
                          "drew ink past the end of the source")
    }

    /// Both must be VISIBLE, and the loud one must be visibly taller. Real
    /// decoded audio at two known levels, measured in points on the default
    /// 90 pt track row.
    func testAQuietClipIsVisibleAndALoudClipIsTaller() async throws {
        let engine = try RealStudioEngine(
            dataDir: tempDir.appendingPathComponent("Levels.mstudio").path, audible: false)
        let vm = StudioViewModel(engine: engine)
        vm.startPolling()
        for _ in 0..<200 where vm.snapshot == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        vm.stopPolling()

        for (name, amp) in [("Loud.wav", 0.7071), ("Quiet.wav", 0.1)] {
            let path = try writeHalfSilentTone(named: name, amplitude: amp)
            let landed = await vm.performImport(path: path)
            XCTAssertTrue(landed, "\(name) did not import: \(vm.importStatus)")
        }
        let snapshot = await engine.snapshot(ifNewerThan: nil)
        let snap = try XCTUnwrap(snapshot)
        let clips = snap.tracks.compactMap { $0.clips.first }
        XCTAssertEqual(clips.count, 2)

        let halfHeight = StudioTokens.trackHeightDefault / 2 - 3   // 42 pt
        var measured: [(peak: Float, pt: CGFloat)] = []
        for clip in clips {
            let peaks = try await drawnPeaks(engine, clip: clip, bucket: 0)
            // The loudest bin of the tone half, as the canvas would draw it.
            let peak = peaks[200..<380].max() ?? 0
            measured.append((peak, CGFloat(StudioWaveformScale.height(forPeak: peak)) * halfHeight))
        }
        // Identified by the level the engine measured, not by track order.
        measured.sort { $0.peak > $1.peak }
        XCTAssertEqual(Double(measured[0].peak), 0.7071, accuracy: 0.02,
                       "the loud clip did not decode at -3 dBFS")
        XCTAssertEqual(Double(measured[1].peak), 0.1, accuracy: 0.01,
                       "the quiet clip did not decode at -20 dBFS")
        let loud = measured[0].pt, quiet = measured[1].pt
        // -3 dBFS -> 0.8409 * 42 = 35.3 pt; -20 dBFS -> 0.3162 * 42 = 13.3 pt.
        XCTAssertEqual(loud, 35.3, accuracy: 1.5)
        XCTAssertGreaterThan(quiet, 10.0, """
            a -20 dBFS clip draws \(quiet) pt of the 42 available. Linear \
            peak-per-bin draws it at 4.2 pt, which is what shipped.
            """)
        XCTAssertGreaterThan(loud, quiet * 2.0, "loud and quiet are not distinguishable")
    }

    /// MASTER VOLUME, the read half, answered on its own.
    ///
    /// `StudioTransportBar.masterVolume` reads
    /// `model.snapshot?.master.volumeDB ?? 0`, which `RealStudioEngine` decodes
    /// with two spellings and a silent default of 0. If neither spelling
    /// matched what the engine emits, the write path could work perfectly and
    /// the control would still read dead. Nothing in the mock can tell: it
    /// stores the gain as a Swift `Double` with no JSON in between.
    func testMasterGainRoundTripsThroughTheSnapshot() async throws {
        let engine = try RealStudioEngine(
            dataDir: tempDir.appendingPathComponent("Master.mstudio").path, audible: false)
        let added = await engine.send(.trackAdd(trackID: UUID().uuidString, name: "One", index: 0))
        XCTAssertTrue(added.ok, "track.add: \(added.message ?? "no message")")

        let beforeSnapshot = await engine.snapshot(ifNewerThan: nil)
        let before = try XCTUnwrap(beforeSnapshot)
        XCTAssertEqual(before.master.volumeDB, 0, accuracy: 1e-9, "a fresh project is at unity")

        for target in [-13.5, -60.0, 12.0, -6.0] {
            let sent = await engine.send(.mixMasterGain(gainDB: target))
            XCTAssertTrue(sent.ok, "mix.master.gain \(target): \(sent.message ?? "no message")")
            let raw = await engine.snapshot(ifNewerThan: nil)
            let snap = try XCTUnwrap(raw)
            XCTAssertEqual(snap.master.volumeDB, target, accuracy: 1e-6, """
                the engine accepted mix.master.gain \(target) and the snapshot \
                reported \(snap.master.volumeDB). A slider that commits and \
                reads back a different number snaps back and reads as dead.
                """)
        }
    }

    /// And the whole gesture, through the control the transport actually holds.
    func testTheTransportControlMovesTheEnginesMasterGain() async throws {
        let engine = try RealStudioEngine(
            dataDir: tempDir.appendingPathComponent("Transport.mstudio").path, audible: false)
        let vm = StudioViewModel(engine: engine)
        vm.startPolling()
        defer { vm.stopPolling() }
        for _ in 0..<200 where vm.snapshot == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // The REAL control, wired the way StudioTransportBar wires it.
        let control = StudioTransportVolumeControl(
            valueDB: vm.snapshot?.master.volumeDB ?? 0
        ) { db in vm.setMasterGain(db) }
        // Grab the cap where it is drawn for -6 dB and let go without moving.
        let w = Double(StudioTransportVolume.trackWidth)
        let x = StudioTransportVolume.capX(forPos: StudioFaderTaper.dbToPos(-6), width: w)
            + Double(StudioTransportVolume.capWidth) / 2
        let committed = control.commit(position: StudioTransportVolume.pos(atX: x, width: w))
        XCTAssertEqual(committed, -6.0, accuracy: 1e-6)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let db = vm.snapshot?.master.volumeDB, abs(db - (-6)) < 1e-6 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(vm.snapshot?.master.volumeDB ?? .nan, -6.0, accuracy: 1e-6,
                       "the transport VOLUME gesture did not reach the engine")
    }
}
#endif
