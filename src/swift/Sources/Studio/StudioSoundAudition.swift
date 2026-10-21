import Foundation
import AVFoundation

// MARK: - Auditioning a vault sound: hearing it WITHOUT committing to it
//
// WHY THIS IS ITS OWN THING, AND NOT AN IMPORT.
//
// Clicking a kick to hear whether it is the right kick is not an edit. It must
// not create a track, must not create a clip, and must not put anything in the
// journal — a person who clicks forty snares looking for one has not made forty
// changes to their song, and forty undo steps standing between them and their
// last real edit would make undo useless.
//
// So audition does not touch the engine, the command bus or the view model at
// all. It cannot: this type holds none of them. `StudioSoundsBrowserActions`
// is the only door into it, and `StudioSoundsVaultTests` drives THAT door and
// asserts `StudioMockEngine.journal` is exactly where it was.
//
// THE CRASH THIS FILE IS SHAPED AROUND.
//
// `StemEngine.levelTapBlock` documents it in full and the same rule applies
// here verbatim: under Swift 6 a closure LITERAL written inside a `@MainActor`
// method inherits main-actor isolation unless the parameter it is passed to is
// `@Sendable`, and AVFAudio invokes its callbacks on its own realtime queue.
// That combination fails `dispatch_assert_queue` and the process takes a
// SIGTRAP — deterministic, not a race. It shipped once and killed the app on
// every stem playback.
//
// `AVAudioPlayerNodeCompletionHandler` is a bare
// `(AVAudioPlayerNodeCompletionCallbackType) -> Void`. NOT `@Sendable`. So the
// completion block is built by the `nonisolated static` factory below and is
// never written inline; the explicit `@Sendable` return type means the
// compiler now rejects any future edit that reaches for main-actor state from
// inside it.
//
// AND WHY THERE IS AN INAUDIBLE MODE.
//
// Not as a test seam that bypasses the real path — this repo has been burned by
// exactly that (a piano roll wired to a mock; a 15 ms MIDI delay that shipped
// 100% green because the test path skipped the production one). `audible:
// false` changes ONE thing: where the graph's output goes. Same file decode,
// same connection, same scheduling, same player node; the frames land in a
// buffer a test can measure instead of in the default output device. That is
// what lets the audition tests assert on real signal without making a noise on
// somebody's machine mid-session.

/// What an audition actually produced.
///
/// Peak and RMS of real decoded samples through the real graph, so a test can
/// assert on SIGNAL rather than on "a play method was called". This repo has
/// shipped a meter driven by `abs(sin(t))` and a separator that zeroed 75% of
/// every sample, both with green suites; a boolean saying playback started
/// would prove nothing at all.
struct StudioAuditionProbe: Sendable, Equatable {
    let frames: Int
    let peak: Float
    let rms: Float

    static let silent = StudioAuditionProbe(frames: 0, peak: 0, rms: 0)
}

enum StudioAuditionError: Error, CustomStringConvertible {
    case cannotRender(String)
    case notInRenderingMode

    var description: String {
        switch self {
        case .cannotRender(let s): return "cannot render: \(s)"
        case .notInRenderingMode: return "this player sends its audio to the output device"
        }
    }
}

@MainActor
final class StudioSoundAuditionPlayer: ObservableObject {

    /// Which sound is currently sounding, so the row can show it. nil when
    /// nothing is playing.
    @Published private(set) var auditioningID: String?

    /// Set when a file could not be opened, so a click on a sound that is not
    /// really there SAYS so instead of doing nothing. Two of this codebase's
    /// worst inert controls (`importStatus`, `landingError`) were variables
    /// written by a failure path and read by nobody.
    @Published private(set) var failure: String?

    /// False routes the graph into manual rendering: nothing is heard, and the
    /// frames can be pulled with `probe(seconds:)`.
    let audible: Bool

    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private var connectedFormat: AVAudioFormat?

    init(audible: Bool = true) {
        self.audible = audible
        let graph = Self.makeGraph()
        self.engine = graph.engine
        self.player = graph.player
    }

    /// Builds the audition graph. `nonisolated`, and used by BOTH output modes.
    nonisolated static func makeGraph() -> (engine: AVAudioEngine, player: AVAudioPlayerNode) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        return (engine, player)
    }

    /// The scheduled-file completion block, built OUTSIDE any actor context.
    ///
    /// See the file header. Do not inline this at the call site: an inline
    /// closure inherits `@MainActor` here, and AVFAudio calling it on its own
    /// queue is a SIGTRAP, not a warning.
    nonisolated static func completionBlock(
        _ onFinished: @escaping @Sendable () -> Void
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { type in
            guard type == .dataPlayedBack else { return }
            onFinished()
        }
    }

    /// Play one sound, straight through, once.
    ///
    /// Auditioning a second sound replaces the first rather than layering: a
    /// person scanning a folder for the right hat wants to compare them, not to
    /// build a chord out of the ones that were wrong.
    func audition(_ asset: StudioSoundAsset) {
        stop()
        let url = URL(fileURLWithPath: asset.path)
        do {
            let file = try AVAudioFile(forReading: url)
            try prepare(for: file.processingFormat)

            let id = asset.id
            player.scheduleFile(
                file, at: nil, completionCallbackType: .dataPlayedBack,
                completionHandler: Self.completionBlock { [weak self] in
                    Task { @MainActor in
                        guard let self, self.auditioningID == id else { return }
                        self.auditioningID = nil
                    }
                })
            player.play()
            auditioningID = asset.id
            failure = nil
        } catch {
            auditioningID = nil
            failure = "Could not play \(asset.name): \(error)"
        }
    }

    func stop() {
        if player.isPlaying { player.stop() }
        auditioningID = nil
    }

    /// Connect and start the graph for a file's format. The ONE place the two
    /// output modes differ, and it is three lines of it.
    private func prepare(for format: AVAudioFormat) throws {
        if connectedFormat == nil || connectedFormat?.isEqual(format) == false {
            if engine.isRunning { engine.stop() }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedFormat = format
            if !audible {
                engine.disableManualRenderingMode()
                guard let renderFormat = AVAudioFormat(
                    standardFormatWithSampleRate: format.sampleRate,
                    channels: format.channelCount)
                else { throw StudioAuditionError.cannotRender("no render format") }
                try engine.enableManualRenderingMode(
                    .offline, format: renderFormat, maximumFrameCount: 4096)
            }
        }
        if !engine.isRunning { try engine.start() }
    }

    /// Pull frames out of an inaudible audition and report what came out.
    ///
    /// Only available when `audible == false`; asking an audible player for its
    /// samples would mean tapping the output device, which is a different — and
    /// much less honest — measurement.
    func probe(seconds: Double = 0.5) throws -> StudioAuditionProbe {
        guard !audible else { throw StudioAuditionError.notInRenderingMode }
        guard engine.isRunning, engine.manualRenderingMode == .offline,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { throw StudioAuditionError.cannotRender("engine is not rendering") }

        let sampleRate = engine.manualRenderingFormat.sampleRate
        let target = AVAudioFramePosition(seconds * sampleRate)
        var rendered: AVAudioFramePosition = 0
        var peak: Float = 0
        var sumOfSquares: Double = 0
        var samples = 0

        while rendered < target {
            let want = AVAudioFrameCount(
                min(AVAudioFramePosition(engine.manualRenderingMaximumFrameCount),
                    target - rendered))
            let status: AVAudioEngineManualRenderingStatus
            do { status = try engine.renderOffline(want, to: buffer) }
            catch { throw StudioAuditionError.cannotRender("\(error)") }
            guard status == .success || status == .insufficientDataFromInputNode else { break }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                guard let data = buffer.floatChannelData?[channel] else { continue }
                for frame in 0..<frames {
                    let value = data[frame]
                    let magnitude = abs(value)
                    if magnitude > peak { peak = magnitude }
                    sumOfSquares += Double(value) * Double(value)
                    samples += 1
                }
            }
            rendered += AVAudioFramePosition(frames)
        }

        let rms = samples > 0 ? Float((sumOfSquares / Double(samples)).squareRoot()) : 0
        return StudioAuditionProbe(frames: Int(rendered), peak: peak, rms: rms)
    }
}
