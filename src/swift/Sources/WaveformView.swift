import SwiftUI
import AVFoundation

// MARK: - Waveform Data Extraction

/// Extracts audio sample data from a file URL and caches the result.
/// Reads actual PCM audio samples and downsamples to a fixed bar count for visualization.
@MainActor
final class WaveformData: ObservableObject {
    @Published var samples: [Float] = []
    @Published var isLoading = false

    private static var cache: [URL: [Float]] = [:]

    func load(from url: URL, targetSampleCount: Int = 200) {
        if let cached = Self.cache[url] {
            self.samples = cached
            return
        }

        guard !isLoading else { return }
        isLoading = true

        let count = targetSampleCount
        Task {
            let extracted = await Self.extractSamplesInBackground(from: url, count: count)
            Self.cache[url] = extracted
            self.samples = extracted
            self.isLoading = false
        }
    }

    /// Performs the actual AVAudioFile read on a background thread, returning
    /// the resulting sample array. The function is nonisolated so it can run
    /// off the main actor; all AVFoundation work is self-contained.
    private nonisolated static func extractSamplesInBackground(
        from url: URL, count: Int
    ) async -> [Float] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = extractSamples(from: url, count: count)
                continuation.resume(returning: result)
            }
        }
    }

    /// Reads audio samples from `url`, bucketing them into `count` bar heights.
    ///
    /// Returns HEIGHTS, not raw amplitudes: normalised to the file's own peak
    /// and then put through `StudioWaveformScale`. Internal rather than private
    /// so `LibraryWaveformScaleTests` can read a real file through this exact
    /// function — asserting the curve constant alone passes whether or not this
    /// function ever calls it.
    ///
    /// ⚠️ READ IN THE FILE'S OWN `processingFormat`. THIS IS THE DEFECT THAT
    /// DREW FOUR EMPTY STEM LANES.
    ///
    /// `AVAudioFile.read(into:)` does not convert. It requires a buffer whose
    /// format is EXACTLY `processingFormat`, and returns `kAudio_ParamError`
    /// (-50) otherwise. The old code built its own
    /// `AVAudioFormat(standardFormatWithSampleRate:channels: 1)` — mono, always
    /// — and read a stereo file into it. Measured on the owner's own bass stem
    /// (2 ch, 44100 Hz, Int16; `processingFormat` 2 ch Float32 deinterleaved):
    ///
    ///     READ THREW: Error Domain=com.apple.coreaudio.avfaudio Code=-50
    ///                 failed call=ExtAudioFileRead(...)
    ///     RESULT COUNT: 0
    ///
    /// The `catch` swallowed it and returned `[]`, so every caller of this
    /// function drew nothing at all for any file with more than one channel.
    /// htdemucs writes stereo, so all four stems of every separation hit it,
    /// 100% of the time — a blank lane, not a "missing file" lane, because the
    /// file is right there and the ENGINE opens it correctly and plays it.
    /// The Library's own rows and the player bar sat on the same bug for every
    /// stereo track; it read as "that row just doesn't have a waveform".
    ///
    /// The peak is taken across ALL channels, which is what
    /// `StudioHost::waveform` does for the arrangement ("a true peak per bin
    /// over both channels"). Taking channel 0 only would silently halve a
    /// hard-panned part.
    ///
    /// Read in CHUNKS rather than one buffer the length of the file. The old
    /// shape allocated `length` frames up front; at four lanes × a 4½-minute
    /// stereo stem that is ~380 MB of transient float buffers for a picture
    /// 400 bins wide. A fixed window costs 2 MB and reads the same numbers.
    nonisolated static func extractSamples(from url: URL, count: Int) -> [Float] {
        guard count > 0, let audioFile = try? AVAudioFile(forReading: url) else { return [] }

        let totalFrames = Int(audioFile.length)
        guard totalFrames > 0 else { return [] }

        let format = audioFile.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return [] }

        // Bucketing is UNCHANGED from the shipped version, deliberately: same
        // integer division, same dropped tail remainder, same short-file
        // behaviour (a file with fewer frames than bins yields one bucket per
        // frame). Only the decode underneath it moved.
        let framesPerBucket = max(1, totalFrames / count)
        let bucketCount = min(count, totalFrames)
        guard bucketCount > 0 else { return [] }

        // ~6 s at 44.1 kHz. Big enough that the per-read overhead disappears,
        // small enough that the window is a fixed cost regardless of song
        // length.
        let chunkFrames: AVAudioFrameCount = 1 << 18
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
        else { return [] }

        var result = [Float](repeating: 0, count: bucketCount)
        var frameIndex = 0
        /// Whether ANY audio actually reached a bucket. A decode that never
        /// produced a frame must answer "nothing to draw" (`[]`), not a row of
        /// zeros — a row of zeros is a flat midline, which is what a genuinely
        /// SILENT file draws, and those two must not look the same.
        var bucketedAnything = false

        while frameIndex < totalFrames, frameIndex / framesPerBucket < bucketCount {
            do {
                try audioFile.read(into: buffer, frameCount: chunkFrames)
            } catch {
                // A partial read is still a picture: keep what has been
                // bucketed rather than throwing the whole lane away. A read
                // that fails on the FIRST chunk leaves `result` all zeros,
                // which the normalisation below turns into an empty array —
                // the same "nothing to draw" answer as before.
                break
            }
            let got = Int(buffer.frameLength)
            if got == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }

            for f in 0..<got {
                let bucket = (frameIndex + f) / framesPerBucket
                if bucket >= bucketCount { break }
                var amp: Float = 0
                for c in 0..<channelCount {
                    let a = abs(channelData[c][f])
                    if a > amp { amp = a }
                }
                if amp > result[bucket] { result[bucket] = amp }
                bucketedAnything = true
            }
            frameIndex += got
        }

        guard bucketedAnything else { return [] }

        // Normalize to 0...1, then put the normalized peak through the SAME
        // perceptual curve the Studio's waveform uses.
        //
        // Order matters and this order is the correct one. Normalising first
        // means the loudest bar in the file is 1.0; `StudioWaveformScale` is
        // anchored at 1.0, so the loudest bar still fills the row and only the
        // quiet ones move.
        //
        // Why this view needed it at all, when normalisation already rescues
        // the case the Studio suffered: the Studio's defect was ABSOLUTE (a
        // whole file at -20 dBFS drew 4.2 pt of ink on a 90 pt row). This view
        // cannot have that one — it divides by the file's own peak. What it DID
        // have is the RELATIVE case, which is the common one: a track with a
        // loud transient and a quiet body. Linear amplitude drew that body at a
        // tenth of the row, and everything below roughly -34 dBFS sat on the
        // `max(2, ...)` floor where it all looks identical. The curve lifts
        // -20 dBFS from 8 pt to 26 pt of a 90 pt row while keeping loud and
        // quiet ordered.
        //
        // PIXELS ONLY. No decoded sample changes; this is the same peak, drawn
        // at a height a person can see.
        let peak = result.max() ?? 1.0
        if peak > 0 {
            result = result.map { StudioWaveformScale.height(forPeak: $0 / peak) }
        }

        return result
    }

    /// Clears the in-memory waveform cache. Call when library is refreshed or
    /// audio files are deleted.
    static func clearCache() {
        cache.removeAll()
    }

    /// Evicts cached waveforms for audio files under `directory` — e.g. a
    /// stem session's folder that is being deleted. Keeps the rest of the
    /// cache warm.
    static func evictCache(under directory: URL) {
        let prefix = directory.standardizedFileURL.path
        cache = cache.filter { !$0.key.standardizedFileURL.path.hasPrefix(prefix) }
    }
}

// MARK: - Full-Size Waveform View

/// Renders audio waveform as vertical bars from real sample data.
/// Use this in track detail views or any context where a full waveform is desired.
struct AudioWaveformView: View {
    let url: URL
    var barColor: Color = .accentColor
    var backgroundColor: Color = .clear
    /// Optional playback progress from 0.0 to 1.0. Bars before this point render
    /// at full opacity; bars after render dimmed.
    var playbackProgress: Double? = nil

    @StateObject private var data = WaveformData()

    var body: some View {
        GeometryReader { _ in
            if data.samples.isEmpty && data.isLoading {
                // Loading placeholder — subtle pulse
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.1))
            } else if data.samples.isEmpty {
                // No data or failed to load
                EmptyView()
            } else {
                Canvas { context, size in
                    let barCount = data.samples.count
                    let gap = size.width / CGFloat(barCount)
                    let barWidth = max(1, gap * 0.7)
                    let midY = size.height / 2

                    for (index, amplitude) in data.samples.enumerated() {
                        let x = CGFloat(index) * gap + gap / 2
                        let barHeight = max(2, CGFloat(amplitude) * size.height * 0.9)

                        let rect = CGRect(
                            x: x - barWidth / 2,
                            y: midY - barHeight / 2,
                            width: barWidth,
                            height: barHeight
                        )

                        // Color based on playback position
                        let progress = playbackProgress ?? 0
                        let barProgress = CGFloat(index) / CGFloat(barCount)
                        let color: Color = barProgress <= CGFloat(progress)
                            ? barColor
                            : barColor.opacity(0.3)

                        context.fill(
                            Path(roundedRect: rect, cornerRadius: barWidth / 2),
                            with: .color(color)
                        )
                    }
                }
            }
        }
        .background(backgroundColor)
        .onAppear {
            data.load(from: url)
        }
        .onChange(of: url) { _, newURL in
            data.load(from: newURL)
        }
        .accessibilityLabel("Audio waveform")
        .accessibilityHidden(true)
    }
}

// MARK: - Compact Waveform for Player Bar

/// A thin, compact waveform suitable for the persistent player bar.
/// Shows played vs. unplayed portions using accent color vs. gray.
struct CompactWaveformView: View {
    let url: URL
    var playbackProgress: Double = 0
    var accentColor: Color = .accentColor

    @StateObject private var data = WaveformData()

    var body: some View {
        GeometryReader { _ in
            if !data.samples.isEmpty {
                Canvas { context, size in
                    let count = data.samples.count
                    let step = size.width / CGFloat(count)

                    for (index, amplitude) in data.samples.enumerated() {
                        let x = CGFloat(index) * step
                        let height = max(1, CGFloat(amplitude) * size.height)
                        let y = (size.height - height) / 2

                        let barProgress = CGFloat(index) / CGFloat(count)
                        let color: Color = barProgress <= CGFloat(playbackProgress)
                            ? accentColor
                            : Color.gray.opacity(0.3)

                        let rect = CGRect(
                            x: x,
                            y: y,
                            width: max(1, step * 0.6),
                            height: height
                        )
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 0.5),
                            with: .color(color)
                        )
                    }
                }
            }
        }
        .onAppear { data.load(from: url, targetSampleCount: 100) }
        .onChange(of: url) { _, newURL in data.load(from: newURL, targetSampleCount: 100) }
        .accessibilityHidden(true)
    }
}
