import Testing
import Foundation
import AVFoundation
@testable import MajiksMusicStudio

// MARK: - StemEngine Bounce Tests
//
// These run fully headless: the engine is only ever started in manual offline
// rendering mode (no audio hardware needed). Stems are generated sine WAVs, so
// the mixed output can be compared SAMPLE-WISE against the analytic mix — a
// one-frame misalignment of any stem produces errors ~10x above the tolerance,
// which is the sample-alignment evidence required by the S1 acceptance.

@MainActor
@Suite("StemEngine bounce", .serialized)
struct StemEngineTests {

    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a stereo float32 WAV sine (identical channels, phase 0 at frame 0).
    private func writeSineWAV(
        to url: URL,
        frequency: Double,
        amplitude: Double,
        seconds: Double,
        sampleRate: Double = 44100
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for n in 0..<Int(frames) {
                data[n] = Float(amplitude * sin(2.0 * .pi * frequency * Double(n) / sampleRate))
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    /// Writes a MONO float32 WAV sine (scoped writer so the file is closed
    /// before it is read back).
    private func writeMonoSineWAV(
        to url: URL,
        frequency: Double,
        amplitude: Double,
        seconds: Double,
        sampleRate: Double = 44100
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for n in 0..<Int(frames) {
            buffer.floatChannelData![0][n] = Float(amplitude * sin(2.0 * .pi * frequency * Double(n) / sampleRate))
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    /// Channel-0 convenience over readAudioChannels.
    private func readAudio(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let (channels, sampleRate) = try readAudioChannels(url)
        return (channels.first ?? [], sampleRate)
    }

    /// Reads every channel (for pan / up-mix assertions).
    private func readAudioChannels(_ url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: max(frames, 1))!
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var channels: [[Float]] = []
        for ch in 0..<channelCount {
            var samples = [Float](repeating: 0, count: count)
            if let data = buffer.floatChannelData?[ch] {
                for n in 0..<count { samples[n] = data[n] }
            }
            channels.append(samples)
        }
        return (channels, file.processingFormat.sampleRate)
    }

    private func rmsOf(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// One analytically expected stem in the mix (same-rate tests only).
    private struct ExpectedStem {
        let frequency: Double
        let amplitude: Double        // amplitude in the source file
        let lengthFrames: Int        // frames at the session rate
        let linearGain: Double       // effective stem gain (0 = excluded)
    }

    /// Compares output samples against the analytic piecewise mix.
    private func compare(
        samples: [Float],
        against expected: [ExpectedStem],
        masterLinear: Double,
        sampleRate: Double
    ) -> (maxDiff: Double, rms: Double) {
        var maxDiff = 0.0
        var sumSquares = 0.0
        for n in 0..<samples.count {
            var predicted = 0.0
            for stem in expected where n < stem.lengthFrames && stem.linearGain > 0 {
                predicted += stem.linearGain * stem.amplitude
                    * sin(2.0 * .pi * stem.frequency * Double(n) / sampleRate)
            }
            predicted *= masterLinear
            maxDiff = max(maxDiff, abs(Double(samples[n]) - predicted))
            sumSquares += Double(samples[n]) * Double(samples[n])
        }
        let rms = samples.isEmpty ? 0 : (sumSquares / Double(samples.count)).squareRoot()
        return (maxDiff, rms)
    }

    private func makeStem(_ id: UUID, name: String, gainDB: Double = 0, muted: Bool = false, solo: Bool = false, pan: Double = 0) -> SessionStem {
        SessionStem(id: id, fileName: "test/\(name).wav", displayName: name, gainDB: gainDB, muted: muted, solo: solo, pan: pan)
    }

    // MARK: Tests

    @Test("bounce is sample-aligned: exact frame count and sample-wise mix match")
    func bounceSampleAligned() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Three stems: full-length A, half-length B, muted C.
        let urlA = dir.appendingPathComponent("a.wav")
        let urlB = dir.appendingPathComponent("b.wav")
        let urlC = dir.appendingPathComponent("c.wav")
        try writeSineWAV(to: urlA, frequency: 441, amplitude: 0.4, seconds: 2.0)
        try writeSineWAV(to: urlB, frequency: 882, amplitude: 0.3, seconds: 1.0)
        try writeSineWAV(to: urlC, frequency: 1323, amplitude: 0.5, seconds: 1.5)

        let idA = UUID(), idB = UUID(), idC = UUID()
        let doc = StemSessionDocument(name: "Align", stems: [
            makeStem(idA, name: "A"),
            makeStem(idB, name: "B"),
            makeStem(idC, name: "C", muted: true)
        ])

        let engine = StemEngine()
        engine.loadStems([(stemID: idA, url: urlA), (stemID: idB, url: urlB), (stemID: idC, url: urlC)])
        #expect(engine.missingStemIDs.isEmpty)
        #expect(engine.duration == 2.0)  // duration = longest stem
        #expect(engine.totalSessionFrames == 88200)
        // Per-stem durations drive the editor's proportional waveform lanes.
        #expect(engine.stemDuration(for: idA) == 2.0)
        #expect(engine.stemDuration(for: idB) == 1.0)
        #expect(engine.stemDuration(for: idC) == 1.5)

        let out = dir.appendingPathComponent("mix.wav")
        try await engine.bounce(to: out, mix: doc)

        let (samples, rate) = try readAudio(out)
        #expect(rate == 44100)
        #expect(samples.count == 88200)  // output sample count == longest stem, exactly

        let (maxDiff, rms) = compare(
            samples: samples,
            against: [
                ExpectedStem(frequency: 441, amplitude: 0.4, lengthFrames: 88200, linearGain: 1.0),
                ExpectedStem(frequency: 882, amplitude: 0.3, lengthFrames: 44100, linearGain: 1.0),
                ExpectedStem(frequency: 1323, amplitude: 0.5, lengthFrames: 66150, linearGain: 0.0)  // muted
            ],
            masterLinear: 1.0,
            sampleRate: 44100
        )
        // A one-frame misalignment of stem A alone would produce ~0.025 error;
        // we require an order of magnitude tighter.
        #expect(maxDiff < 0.002, "max sample deviation \(maxDiff)")

        // RMS ≈ sqrt(0.4²/2 + (0.3²/2)·(1/2)) = 0.32016
        let expectedRMS = (0.08 + 0.0225).squareRoot()
        #expect(abs(rms - expectedRMS) / expectedRMS < 0.01, "rms \(rms) vs \(expectedRMS)")
    }

    @Test("bounce honors solo, per-stem dB gain, and master gain")
    func bounceSoloGainMaster() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urlA = dir.appendingPathComponent("a.wav")
        let urlB = dir.appendingPathComponent("b.wav")
        try writeSineWAV(to: urlA, frequency: 441, amplitude: 0.5, seconds: 1.0)
        try writeSineWAV(to: urlB, frequency: 660, amplitude: 0.5, seconds: 1.0)

        let idA = UUID(), idB = UUID()
        // A soloed at -6 dB; B unmuted but NOT soloed → implicitly silent.
        // Master at -6 dB scales the survivor again.
        let doc = StemSessionDocument(
            name: "SoloGain",
            stems: [
                makeStem(idA, name: "A", gainDB: -6, solo: true),
                makeStem(idB, name: "B")
            ],
            masterGainDB: -6
        )

        let engine = StemEngine()
        engine.loadStems([(stemID: idA, url: urlA), (stemID: idB, url: urlB)])

        let out = dir.appendingPathComponent("mix.wav")
        try await engine.bounce(to: out, mix: doc)

        let (samples, _) = try readAudio(out)
        #expect(samples.count == 44100)

        let minus6 = pow(10.0, -6.0 / 20.0)
        let (maxDiff, rms) = compare(
            samples: samples,
            against: [
                ExpectedStem(frequency: 441, amplitude: 0.5, lengthFrames: 44100, linearGain: minus6),
                ExpectedStem(frequency: 660, amplitude: 0.5, lengthFrames: 44100, linearGain: 0.0)  // solo'd out
            ],
            masterLinear: minus6,
            sampleRate: 44100
        )
        #expect(maxDiff < 0.002, "max sample deviation \(maxDiff)")

        // RMS ≈ (0.5·10^(-6/20)·10^(-6/20)) / √2
        let expectedRMS = 0.5 * minus6 * minus6 / 2.0.squareRoot()
        #expect(abs(rms - expectedRMS) / expectedRMS < 0.01, "rms \(rms) vs \(expectedRMS)")
    }

    @Test("+12 dB boost is applied faithfully (EQ gain stage, not mixer volume)")
    func bounceAppliesBoost() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("a.wav")
        try writeSineWAV(to: url, frequency: 441, amplitude: 0.2, seconds: 1.0)

        let id = UUID()
        let doc = StemSessionDocument(name: "Boost", stems: [makeStem(id, name: "A", gainDB: 12)])

        let engine = StemEngine()
        engine.loadStems([(stemID: id, url: url)])

        let out = dir.appendingPathComponent("mix.wav")
        try await engine.bounce(to: out, mix: doc)

        let (samples, _) = try readAudio(out)
        let plus12 = pow(10.0, 12.0 / 20.0)  // ≈ 3.981
        let (maxDiff, rms) = compare(
            samples: samples,
            against: [ExpectedStem(frequency: 441, amplitude: 0.2, lengthFrames: 44100, linearGain: plus12)],
            masterLinear: 1.0,
            sampleRate: 44100
        )
        #expect(maxDiff < 0.004, "max sample deviation \(maxDiff)")
        let expectedRMS = 0.2 * plus12 / 2.0.squareRoot()
        #expect(abs(rms - expectedRMS) / expectedRMS < 0.01, "rms \(rms) vs \(expectedRMS)")
    }

    @Test("eight stems load, mix, and bounce to the longest stem's length")
    func eightStems() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var sources: [(stemID: UUID, url: URL)] = []
        var stems: [SessionStem] = []
        var expected: [ExpectedStem] = []
        for i in 0..<8 {
            let url = dir.appendingPathComponent("stem\(i).wav")
            let frequency = 150.0 * Double(i + 1)
            let seconds = 0.25 * Double(i + 1)   // staggered 0.25 … 2.0 s
            try writeSineWAV(to: url, frequency: frequency, amplitude: 0.08, seconds: seconds)
            let id = UUID()
            sources.append((stemID: id, url: url))
            stems.append(makeStem(id, name: "Stem \(i + 1)"))
            expected.append(ExpectedStem(
                frequency: frequency,
                amplitude: 0.08,
                lengthFrames: Int((seconds * 44100).rounded()),
                linearGain: 1.0
            ))
        }
        let doc = StemSessionDocument(name: "Eight", stems: stems)

        let engine = StemEngine()
        engine.loadStems(sources)
        #expect(engine.loadedStemCount == 8)
        #expect(engine.duration == 2.0)

        let out = dir.appendingPathComponent("mix.wav")
        try await engine.bounce(to: out, mix: doc)

        let (samples, _) = try readAudio(out)
        #expect(samples.count == 88200)

        let (maxDiff, rms) = compare(samples: samples, against: expected, masterLinear: 1.0, sampleRate: 44100)
        #expect(maxDiff < 0.003, "max sample deviation \(maxDiff)")

        // mean-square = Σ (0.08²/2)·(lenᵢ/2.0) with Σ lenᵢ = 9.0 s → rms = 0.12
        let expectedRMS = 0.12
        #expect(abs(rms - expectedRMS) / expectedRMS < 0.02, "rms \(rms) vs \(expectedRMS)")
    }

    @Test("mixed sample rates: session runs at the highest rate, length = longest stem")
    func mixedSampleRates() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urlA = dir.appendingPathComponent("a44.wav")
        let urlB = dir.appendingPathComponent("b22.wav")
        try writeSineWAV(to: urlA, frequency: 441, amplitude: 0.4, seconds: 2.0, sampleRate: 44100)
        try writeSineWAV(to: urlB, frequency: 300, amplitude: 0.25, seconds: 1.0, sampleRate: 22050)

        let idA = UUID(), idB = UUID()
        let doc = StemSessionDocument(name: "SRC", stems: [makeStem(idA, name: "A"), makeStem(idB, name: "B")])

        let engine = StemEngine()
        engine.loadStems([(stemID: idA, url: urlA), (stemID: idB, url: urlB)])
        #expect(engine.duration == 2.0)
        #expect(engine.sessionFormat.sampleRate == 44100)  // highest stem rate wins

        let out = dir.appendingPathComponent("mix.wav")
        try await engine.bounce(to: out, mix: doc)

        let (samples, rate) = try readAudio(out)
        #expect(rate == 44100)
        #expect(samples.count == 88200)

        // SRC smears edges, so only energy is asserted here:
        // rms ≈ sqrt(0.4²/2 + (0.25²/2)·(1/2)) = 0.3092
        var sumSquares = 0.0
        for sample in samples { sumSquares += Double(sample) * Double(sample) }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        let expectedRMS = (0.08 + 0.015625).squareRoot()
        #expect(abs(rms - expectedRMS) / expectedRMS < 0.08, "rms \(rms) vs \(expectedRMS)")
    }

    @Test("stereo pan is a balance law: far channel attenuates linearly (1−|pan|), near channel stays at unity")
    func bouncePanBalance() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.wav")
        try writeSineWAV(to: url, frequency: 441, amplitude: 0.5, seconds: 0.5)
        let id = UUID()

        // Hard left: L carries the signal untouched, R is dead silent.
        let hardLeft = StemSessionDocument(name: "PanL", stems: [makeStem(id, name: "A", pan: -1)])
        let engineL = StemEngine()
        engineL.loadStems([(stemID: id, url: url)])
        let outL = dir.appendingPathComponent("left.wav")
        try await engineL.bounce(to: outL, mix: hardLeft)

        let (leftChannels, _) = try readAudioChannels(outL)
        #expect(leftChannels.count == 2)
        let (maxDiffL, _) = compare(
            samples: leftChannels[0],
            against: [ExpectedStem(frequency: 441, amplitude: 0.5, lengthFrames: 22050, linearGain: 1.0)],
            masterLinear: 1.0,
            sampleRate: 44100
        )
        #expect(maxDiffL < 0.002, "hard-left L deviation \(maxDiffL)")
        #expect(leftChannels[1].allSatisfy { abs($0) < 1e-6 }, "hard-left R must be silent")

        // Half right (+0.5): far (left) channel × (1 − 0.5), near channel unity.
        let halfRight = StemSessionDocument(name: "PanR", stems: [makeStem(id, name: "A", pan: 0.5)])
        let engineR = StemEngine()
        engineR.loadStems([(stemID: id, url: url)])
        let outR = dir.appendingPathComponent("right.wav")
        try await engineR.bounce(to: outR, mix: halfRight)

        let (rightChannels, _) = try readAudioChannels(outR)
        let (maxDiffFar, _) = compare(
            samples: rightChannels[0],
            against: [ExpectedStem(frequency: 441, amplitude: 0.5, lengthFrames: 22050, linearGain: 0.5)],
            masterLinear: 1.0,
            sampleRate: 44100
        )
        let (maxDiffNear, _) = compare(
            samples: rightChannels[1],
            against: [ExpectedStem(frequency: 441, amplitude: 0.5, lengthFrames: 22050, linearGain: 1.0)],
            masterLinear: 1.0,
            sampleRate: 44100
        )
        #expect(maxDiffFar < 0.002, "half-right far-channel deviation \(maxDiffFar)")
        #expect(maxDiffNear < 0.002, "half-right near-channel deviation \(maxDiffNear)")
    }

    @Test("mid-bounce mute ramps inside the ~20 ms window — no full-scale step between adjacent samples")
    func bounceMidRenderMuteRamps() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Low-frequency sine so the natural sample-to-sample slope is far
        // below any mute step: 100 Hz @ 0.5 amplitude → natural adjacent-
        // sample delta ≤ 0.5·2π·100/44100 ≈ 0.0071. A HARD mute could step
        // up to the full 0.5 amplitude between two samples.
        let url = dir.appendingPathComponent("a.wav")
        try writeSineWAV(to: url, frequency: 100, amplitude: 0.5, seconds: 2.0)
        let id = UUID()
        let doc = StemSessionDocument(name: "MidMute", stems: [makeStem(id, name: "A")])

        let engine = StemEngine()
        engine.loadStems([(stemID: id, url: url)])
        let out = dir.appendingPathComponent("mix.wav")

        let bounceTask = Task { try await engine.bounce(to: out, mix: doc) }
        // Wait until the render is well underway (bounce yields to the main
        // actor and publishes progress every 16 blocks).
        var spins = 0
        while engine.bounceProgress < 0.4, engine.bounceProgress < 1.0, spins < 5_000_000 {
            spins += 1
            await Task.yield()
        }
        try #require(engine.isBouncing, "mute must arrive while the render is still running")

        // The same path the UI takes for a live mute during a bounce.
        var mutedDoc = doc
        mutedDoc.stems[0].muted = true
        engine.applyMix(from: mutedDoc)
        try await bounceTask.value

        let (samples, rate) = try readAudio(out)
        #expect(rate == 44100)
        #expect(samples.count == 88200)

        // Head (pre-mute) at full level; tail fully silent (mute did land).
        let window = Int(0.3 * 44100)
        let fullRMS = 0.5 / 2.0.squareRoot()
        let headRMS = rmsOf(Array(samples[0..<window]))
        let tailRMS = rmsOf(Array(samples[(samples.count - window)...]))
        #expect(abs(headRMS - fullRMS) / fullRMS < 0.02, "head rms \(headRMS)")
        #expect(tailRMS < 1e-4, "tail rms \(tailRMS)")

        // The transition spans a ramp, not a cut: from the last full-scale
        // sample to full silence within parameterRampDuration plus slack for
        // sine phase (≤ ½ period = 5 ms) and render-block quantization.
        // Measured: ~0.027 s (20 ms ramp + slack).
        let lastLoud = samples.lastIndex { abs($0) > 0.45 } ?? 0
        let lastNonSilent = samples.lastIndex { abs($0) > 1e-4 } ?? 0
        let transitionSeconds = Double(lastNonSilent - lastLoud) / 44100
        #expect(transitionSeconds > 0.008, "transition \(transitionSeconds)s — looks like a hard cut")
        #expect(transitionSeconds < 0.06, "transition \(transitionSeconds)s — exceeds the ramp window")

        // The clickless guarantee itself: a hard mute could step up to the
        // full 0.5 amplitude between adjacent samples; the ramped render
        // must stay at the signal's own slope. Measured: 0.0071 — exactly
        // the natural sine slope, i.e. the ramp adds no detectable step.
        var maxDelta: Float = 0
        for n in 1..<samples.count {
            maxDelta = max(maxDelta, abs(samples[n] - samples[n - 1]))
        }
        #expect(maxDelta < 0.012, "max adjacent-sample delta \(maxDelta)")
    }

    @Test("mono stems up-mix at EQUAL POWER: −3 dB (×1/√2) into each stereo channel")
    func monoStemUpmixesEqualPower() async throws {
        // The stem mixer performs the mono→stereo up-mix on its way to the
        // shared bus (see loadStems). Current AU behavior, pinned here so a
        // future AVFoundation change can't silently shift mix levels:
        // each output channel carries mono × 1/√2 — acoustic (power) sum
        // matches the mono original, unlike equal-AMPLITUDE (×1.0 per
        // channel), which would play mono stems ~3 dB hot.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mono.wav")
        try writeMonoSineWAV(to: url, frequency: 441, amplitude: 0.5, seconds: 0.5)

        let id = UUID()
        let doc = StemSessionDocument(name: "Mono", stems: [makeStem(id, name: "M")])
        let engine = StemEngine()
        engine.loadStems([(stemID: id, url: url)])
        #expect(engine.missingStemIDs.isEmpty)
        #expect(engine.duration == 0.5)

        let out = dir.appendingPathComponent("mix.wav")
        try await engine.bounce(to: out, mix: doc)

        let (channels, rate) = try readAudioChannels(out)
        #expect(rate == 44100)
        #expect(channels.count == 2)

        // Both channels carry the source at exactly −3 dB (equal power law).
        let equalPowerGain = 1.0 / 2.0.squareRoot()
        for channel in channels {
            let (maxDiff, _) = compare(
                samples: channel,
                against: [ExpectedStem(frequency: 441, amplitude: 0.5, lengthFrames: 22050, linearGain: equalPowerGain)],
                masterLinear: 1.0,
                sampleRate: 44100
            )
            #expect(maxDiff < 0.002, "up-mix deviation from −3 dB law: \(maxDiff)")
        }
        // And they are identical — a centered dual-mono image.
        var maxChannelDiff: Float = 0
        for n in 0..<min(channels[0].count, channels[1].count) {
            maxChannelDiff = max(maxChannelDiff, abs(channels[0][n] - channels[1][n]))
        }
        #expect(maxChannelDiff < 1e-6, "channels differ by \(maxChannelDiff)")
    }

    @Test("missing stem files are reported and an empty engine refuses to bounce")
    func missingFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let engine = StemEngine()
        engine.loadStems([(stemID: id, url: dir.appendingPathComponent("nope.wav"))])
        #expect(engine.missingStemIDs.contains(id))
        #expect(engine.loadedStemCount == 0)
        #expect(engine.duration == 0)
        #expect(engine.stemDuration(for: id) == nil)

        await #expect(throws: StemEngineError.self) {
            try await engine.bounce(to: dir.appendingPathComponent("out.wav"), mix: StemSessionDocument(name: "X"))
        }
    }
}

// MARK: - Level Metering Tests

/// The tap→UI metering pipeline, minus the audio hardware: the accumulator is
/// exactly what the render-side taps feed and the 20 Hz UI tick drains.
@Suite("Stem level metering")
struct StemLevelAccumulatorTests {

    /// Stereo float32 buffer with per-channel constant fill values.
    private func makeBuffer(left: Float, right: Float, frames: AVAudioFrameCount = 512) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for n in 0..<Int(frames) {
            buffer.floatChannelData![0][n] = left
            buffer.floatChannelData![1][n] = right
        }
        return buffer
    }

    @Test("peak is max magnitude across channels; RMS averages channel power")
    func peakAndRMS() {
        let accumulator = StemLevelAccumulator()
        accumulator.ingest(makeBuffer(left: 0.5, right: -0.8))

        let levels = accumulator.read()
        #expect(abs(levels.peak - 0.8) < 1e-6)
        // RMS of constant signals: sqrt((0.5² + 0.8²) / 2) = sqrt(0.445)
        let expectedRMS = Float((0.445).squareRoot())
        #expect(abs(levels.rms - expectedRMS) < 1e-5)
    }

    @Test("peak max-holds between reads so transients can't slip between UI frames")
    func peakMaxHold() {
        let accumulator = StemLevelAccumulator()
        accumulator.ingest(makeBuffer(left: 0.9, right: 0.9))   // transient
        accumulator.ingest(makeBuffer(left: 0.1, right: 0.1))   // quiet tail

        let first = accumulator.read()
        #expect(abs(first.peak - 0.9) < 1e-6)   // transient survived the quiet buffer
        #expect(abs(first.rms - 0.1) < 1e-5)    // RMS is the LATEST buffer's

        // Read re-armed the peak hold: next read only sees what came after.
        accumulator.ingest(makeBuffer(left: 0.2, right: 0.2))
        let second = accumulator.read()
        #expect(abs(second.peak - 0.2) < 1e-6)
    }

    @Test("reset clears both peak and RMS")
    func resetClears() {
        let accumulator = StemLevelAccumulator()
        accumulator.ingest(makeBuffer(left: 0.7, right: 0.7))
        accumulator.reset()
        let levels = accumulator.read()
        #expect(levels == .zero)
    }
}
