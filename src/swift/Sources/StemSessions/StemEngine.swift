import AVFoundation
import Accelerate
import Foundation
import Combine
import os

// MARK: - Level Metering

/// Post-gain peak/RMS levels for one metering point (linear amplitude,
/// 0 = silence, 1 = 0 dBFS full scale; peaks above 1 mean clipping).
struct StemLevels: Equatable {
    var peak: Float
    var rms: Float

    static let zero = StemLevels(peak: 0, rms: 0)
}

/// Thread-safe peak/RMS accumulator fed by an audio tap on the render side
/// and drained by the UI timer (~20 Hz). Peak is max-hold between reads so
/// short transients can't slip between UI frames; RMS is the latest buffer's.
///
/// EVERYTHING HERE RUNS ON AVFAudio's TAP QUEUE, never the main thread. It is
/// deliberately a plain `@unchecked Sendable` class and not an actor, and every
/// member is `nonisolated`, because the tap block that calls `ingest` must
/// carry NO actor isolation at all — see `StemEngine.levelTapBlock(for:)` for
/// what happens when it does.
///
/// The critical section is two float stores under `os_unfair_lock`
/// (`OSAllocatedUnfairLock`) rather than `NSLock`: no allocation, no ObjC
/// message send, no retain traffic on the audio side. A lock at all is
/// tolerable here — and only here — because an AVFAudio tap block is dispatched
/// on `RealtimeMessenger.mServiceQueue` from buffers the render thread has
/// already handed off, so the IO thread never blocks on this lock. Nothing else
/// in this file may take a lock on the audio side.
final class StemLevelAccumulator: @unchecked Sendable {
    private struct Held {
        var peakHold: Float = 0
        var latestRMS: Float = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: Held())

    /// Ingests one tap buffer (any channel count; deinterleaved float32).
    /// Peak = max magnitude across channels; RMS is averaged across channels.
    ///
    /// Allocation-free: the vDSP reductions write into stack scalars and the
    /// critical section touches two stored floats. A tap block is a real-time
    /// context — nothing in here may allocate, log, or await.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        let frames = vDSP_Length(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return }

        var peak: Float = 0
        var meanSquareSum: Float = 0
        for channel in 0..<channelCount {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &channelPeak, frames)
            peak = max(peak, channelPeak)
            var meanSquare: Float = 0
            vDSP_measqv(channels[channel], 1, &meanSquare, frames)
            meanSquareSum += meanSquare
        }
        let rms = (meanSquareSum / Float(channelCount)).squareRoot()

        // Copied into lets: `withLock`'s body is a sending closure, so it
        // cannot reach for the `var`s the vDSP reductions wrote into.
        let bufferPeak = peak
        let bufferRMS = rms
        state.withLock { held in
            held.peakHold = max(held.peakHold, bufferPeak)
            held.latestRMS = bufferRMS
        }
    }

    /// Returns the levels accumulated since the last read and re-arms the
    /// peak hold. The RMS value persists until the next buffer overwrites it.
    ///
    /// READ-AND-RESET: there is exactly ONE caller (`StemEngine.publishLevels`,
    /// on the 20 Hz UI tick). A second poller would drain the same hold and the
    /// two would each see about half the peaks.
    func read() -> StemLevels {
        state.withLock { held in
            let levels = StemLevels(peak: held.peakHold, rms: held.latestRMS)
            held.peakHold = 0
            return levels
        }
    }

    func reset() {
        state.withLock { held in
            held.peakHold = 0
            held.latestRMS = 0
        }
    }
}

/// Errors surfaced by StemEngine operations.
enum StemEngineError: LocalizedError {
    case noStemsLoaded
    case bounceInProgress
    case engineStartFailed(String)
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .noStemsLoaded:
            return "No stems are loaded."
        case .bounceInProgress:
            return "A bounce is already in progress."
        case .engineStartFailed(let message):
            return "Audio engine failed to start: \(message)"
        case .renderFailed(let message):
            return "Bounce render failed: \(message)"
        }
    }
}

/// Multi-stem synchronized playback + offline bounce engine (S1 foundation).
///
/// Graph, per stem:
///   AVAudioPlayerNode → AVAudioUnitEQ (0 bands; globalGain = stem dB)
///     → AVAudioMixerNode (outputVolume targets 0/1 = effective mute; pan)
///     → shared bus mixer → master AVAudioUnitEQ (globalGain = master dB)
///     → mainMixerNode → output.
///
/// Gain staging rationale: AVAudioMixerNode.outputVolume is documented for the
/// 0.0–1.0 range only, so dB gain — including boosts up to +12 dB — lives on
/// AVAudioUnitEQ.globalGain (documented −96…+24 dB). Mixer volumes carry only
/// mute states (target 0 or 1; intermediate values exist transiently while a
/// ~20 ms ramp runs) and bus summing. All state mutations happen on the main
/// actor via node properties — nothing blocks or allocates on the render thread.
///
/// Clickless parameter changes: mute/solo/gain/pan edits never step node
/// parameters full-scale. While audio is rendering they run through a short
/// stepped ramp (~20 ms, `parameterRampDuration`) driven from the main-thread
/// apply path — a wall-clock ticker during live playback, and render-clock
/// advancement between (shrunken) render blocks during an offline bounce, so
/// a mid-bounce mute lands in the file as a ramp, not a step.
///
/// Design decisions (documented per S1 spec):
/// - **Streaming, not buffers**: stems are scheduled with
///   `scheduleSegment(AVAudioFile, startingFrame:...)`. Seek stays clean (stop
///   players, re-schedule the remaining segment from the target frame) and memory
///   stays flat regardless of stem count/length. This is also Apple's canonical
///   pattern for offline manual rendering, which bounce reuses on the SAME graph.
/// - **Per-stem sample-rate conversion**: player→EQ→stem-mixer run at the FILE's
///   processing format; the stem-mixer→bus connection uses the canonical session
///   format (stereo float32 @ the highest stem sample rate). The stem mixer
///   performs SRC/channel up-mix, so the mix bus math is uniform.
/// - **Sample-accurate sync**: every (re)start schedules all stems from the same
///   musical position and starts every player against ONE common
///   `AVAudioTime(hostTime:)` anchor ~120 ms in the future.
/// - **Render-clock position**: the transport position derives from the reference
///   (longest) player's `playerTime(forNodeTime: lastRenderTime)` plus the frame
///   base of the last schedule — never wall-clock.
/// - **Pause = capture + stop**: pause captures the render-clock position and stops
///   the players; resume re-schedules from that exact frame with a fresh anchor.
///   This trades ~120 ms resume latency for guaranteed re-sync (no per-node
///   `play()` resume drift can accumulate).
@MainActor
final class StemEngine: ObservableObject {
    // MARK: - Published State

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBouncing = false
    @Published private(set) var bounceProgress: Double = 0
    /// Stem IDs whose audio files could not be opened (missing/unreadable).
    @Published private(set) var missingStemIDs: Set<UUID> = []

    /// Post-gain (post-EQ, post-mute) levels per stem, published at the UI
    /// tick rate (~20 Hz) while playing; empty when the transport is stopped.
    @Published private(set) var stemLevels: [UUID: StemLevels] = [:]
    /// Master-bus levels (post master gain), same cadence as stemLevels.
    @Published private(set) var masterLevels: StemLevels = .zero

    /// Called when playback reaches the end of the longest stem.
    var onPlaybackFinished: (() -> Void)?

    // MARK: - Private State

    private struct LoadedStem {
        let stemID: UUID
        let file: AVAudioFile
        let player: AVAudioPlayerNode
        /// 0-band EQ carrying the stem's dB gain via globalGain (−96…+24 dB).
        let eq: AVAudioUnitEQ
        /// Per-stem mixer: outputVolume targets 0 (effective mute) or 1, with
        /// transient in-between values while a mute/unmute ramp runs; pan
        /// rides here too. Never read it back as a boolean mute flag.
        let mixer: AVAudioMixerNode
        let fileSampleRate: Double
        let lengthFrames: AVAudioFramePosition

        var durationSeconds: Double {
            fileSampleRate > 0 ? Double(lengthFrames) / fileSampleRate : 0
        }
    }

    private let engine = AVAudioEngine()
    /// Shared session bus that sums all stem mixers (volume stays 1).
    private let busMixer = AVAudioMixerNode()
    /// Master gain stage (globalGain = master dB).
    private let masterEQ = AVAudioUnitEQ()

    private var loadedStems: [LoadedStem] = []
    private var timer: Timer?

    /// Tap-side level accumulators, keyed by stem ID (+ one for the master
    /// bus). Populated only while taps are installed.
    private var levelAccumulators: [UUID: StemLevelAccumulator] = [:]
    private let masterLevelAccumulator = StemLevelAccumulator()
    private var levelTapsInstalled = false

    /// Canonical mix format: stereo float32 at the highest stem sample rate.
    private(set) var sessionFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    /// Transport position (seconds) at the origin of the last schedule — the
    /// base that render-clock elapsed time is added to.
    private var playheadBase: Double = 0

    /// Lead time before the common start anchor. Long enough for all players to
    /// arm; short enough to feel immediate.
    private let startLeadTime: Double = 0.12

    // MARK: - Parameter Ramps (clickless mute/solo/gain/pan)

    /// Length of the stepped ramp applied to mute/solo/gain/pan changes while
    /// audio is rendering (~20 ms: inaudible as a fade, but no click).
    nonisolated static let parameterRampDuration: Double = 0.02

    private enum RampParam: Hashable {
        case volume, gain, pan
    }

    /// One ramp per (node, parameter): retargeting replaces the entry,
    /// starting from the currently applied value.
    private struct RampKey: Hashable {
        let node: ObjectIdentifier
        let param: RampParam
    }

    private struct ParamRamp {
        let from: Float
        let to: Float
        var elapsed: Double
        let duration: Double
        let apply: (Float) -> Void
    }

    private var activeRamps: [RampKey: ParamRamp] = [:]
    private var rampTicker: Task<Void, Never>?
    /// Live tick interval (~5 ms → ≥4 steps per ramp; the AU mixer's internal
    /// per-buffer parameter smoothing interpolates between the steps).
    private let rampTickInterval: Double = 0.005

    private var hasActiveRamps: Bool { !activeRamps.isEmpty }

    /// Routes a node-parameter change through the ramp system. Snaps directly
    /// when nothing is rendering (idle transport), when the caller demands it
    /// (bounce setup), or when the change is negligible.
    private func setRampedParameter(
        node: AnyObject,
        param: RampParam,
        from current: Float,
        to target: Float,
        immediate: Bool,
        apply: @escaping (Float) -> Void
    ) {
        let key = RampKey(node: ObjectIdentifier(node), param: param)
        let snap = immediate || (!isPlaying && !isBouncing)
        if snap || abs(target - current) < 1e-4 {
            activeRamps[key] = nil
            apply(target)
            return
        }
        activeRamps[key] = ParamRamp(
            from: current,
            to: target,
            elapsed: 0,
            duration: Self.parameterRampDuration,
            apply: apply
        )
        startRampTickerIfNeeded()
    }

    /// Advances every ramp by `dt` seconds and applies the interpolated
    /// values. dt is wall-clock time live and render-clock time in a bounce.
    private func advanceRamps(by dt: Double) {
        guard !activeRamps.isEmpty else { return }
        for (key, ramp) in activeRamps {
            var ramp = ramp
            ramp.elapsed += dt
            let t = min(1.0, ramp.elapsed / ramp.duration)
            ramp.apply(ramp.from + (ramp.to - ramp.from) * Float(t))
            activeRamps[key] = t >= 1.0 ? nil : ramp
        }
    }

    /// Jumps every ramp to its target (bounce teardown — live state must
    /// match the document exactly afterwards).
    private func finishRampsImmediately() {
        for ramp in activeRamps.values {
            ramp.apply(ramp.to)
        }
        activeRamps = [:]
    }

    /// Drops all ramps without applying (nodes are about to be detached).
    private func cancelAllRamps() {
        activeRamps = [:]
    }

    /// Wall-clock ramp driver for live playback. During a bounce the render
    /// loop advances ramps in render time instead (see bounce()).
    private func startRampTickerIfNeeded() {
        guard rampTicker == nil, !isBouncing else { return }
        rampTicker = Task { @MainActor [weak self] in
            while let self, !self.activeRamps.isEmpty, !self.isBouncing {
                self.advanceRamps(by: self.rampTickInterval)
                try? await Task.sleep(nanoseconds: UInt64(self.rampTickInterval * 1_000_000_000))
            }
            self?.rampTicker = nil
        }
    }

    var loadedStemCount: Int { loadedStems.count }

    /// Duration in seconds of one loaded stem (nil when missing/not loaded).
    /// Used by the editor to scale per-stem waveforms against the session
    /// timeline (stem width = stemDuration / duration of the full lane).
    func stemDuration(for stemID: UUID) -> Double? {
        loadedStems.first { $0.stemID == stemID }?.durationSeconds
    }

    init() {
        engine.attach(busMixer)
        engine.attach(masterEQ)
    }

    // MARK: - Loading

    /// Loads a set of stems (ID + audio URL) into the graph, replacing any
    /// previous set. Stops the transport. IDs are used to map mix parameters
    /// from a StemSessionDocument in applyMix(from:).
    func loadStems(_ sources: [(stemID: UUID, url: URL)]) {
        stopTransport(resetPosition: true)
        cancelAllRamps()  // ramp closures hold the nodes being detached

        for stem in loadedStems {
            engine.detach(stem.player)
            engine.detach(stem.eq)
            engine.detach(stem.mixer)
        }
        loadedStems = []
        missingStemIDs = []

        // Open all files first so the session sample rate is known before wiring.
        var opened: [(UUID, AVAudioFile)] = []
        var maxRate: Double = 0
        for source in sources {
            do {
                let file = try AVAudioFile(forReading: source.url)
                opened.append((source.stemID, file))
                maxRate = max(maxRate, file.processingFormat.sampleRate)
            } catch {
                missingStemIDs.insert(source.stemID)
                print("[StemEngine] Could not open stem \(source.url.lastPathComponent): \(error)")
            }
        }

        let sessionRate = maxRate > 0 ? maxRate : 44100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sessionRate, channels: 2) else {
            print("[StemEngine] Could not create session format at \(sessionRate) Hz")
            return
        }
        sessionFormat = format

        // (Re)wire the shared bus at the session format:
        // busMixer → masterEQ → mainMixer. engine.connect replaces any previous
        // connection on the source node's output.
        engine.connect(busMixer, to: masterEQ, format: sessionFormat)
        engine.connect(masterEQ, to: engine.mainMixerNode, format: sessionFormat)
        busMixer.outputVolume = 1
        engine.mainMixerNode.outputVolume = 1

        for (stemID, file) in opened {
            let player = AVAudioPlayerNode()
            let eq = AVAudioUnitEQ(numberOfBands: 0)
            let mixer = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(eq)
            engine.attach(mixer)
            // Player/EQ speak the file's format; the stem mixer converts to
            // the session format on its way to the shared bus (SRC + channel
            // up-mix). Mono stems land in stereo at EQUAL POWER — ×1/√2
            // (−3 dB) into each channel, dual-mono image — pinned by the
            // monoStemUpmixesEqualPower test.
            engine.connect(player, to: eq, format: file.processingFormat)
            engine.connect(eq, to: mixer, format: file.processingFormat)
            engine.connect(mixer, to: busMixer, format: sessionFormat)

            loadedStems.append(LoadedStem(
                stemID: stemID,
                file: file,
                player: player,
                eq: eq,
                mixer: mixer,
                fileSampleRate: file.processingFormat.sampleRate,
                lengthFrames: file.length
            ))
        }

        duration = loadedStems.map(\.durationSeconds).max() ?? 0
        playheadBase = 0
        currentTime = 0
    }

    /// Unloads everything and stops the engine (e.g. when leaving the editor).
    func unload() {
        stopTransport(resetPosition: true)
        cancelAllRamps()
        for stem in loadedStems {
            engine.detach(stem.player)
            engine.detach(stem.eq)
            engine.detach(stem.mixer)
        }
        loadedStems = []
        missingStemIDs = []
        duration = 0
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - Mix (parameter-only; never touches the graph)

    /// Applies gains/mutes/solos/pans/master from the document to the running
    /// graph. Parameter-only (EQ globalGain + 0/1 mixer volumes + mixer pan) —
    /// safe during playback and on every undo/redo of parameter ops. While
    /// audio renders, changes ramp over ~20 ms (clickless); `immediate: true`
    /// snaps (bounce setup, where the render must start at the exact mix).
    func applyMix(from document: StemSessionDocument, immediate: Bool = false) {
        let anySolo = document.hasSolo
        for stemDoc in document.stems {
            guard let stem = loadedStems.first(where: { $0.stemID == stemDoc.id }) else { continue }
            setStemGainStage(
                stem,
                gainDB: stemDoc.gainDB,
                effectivelyMuted: StemMix.isEffectivelyMuted(
                    muted: stemDoc.muted,
                    solo: stemDoc.solo,
                    anySolo: anySolo
                ),
                immediate: immediate
            )
            setStemPanStage(stem, pan: stemDoc.pan, immediate: immediate)
        }
        setMasterStage(gainDB: document.masterGainDB, immediate: immediate)
    }

    /// Transient gain preview during a slider drag (no document write).
    /// Commit the value through the store on drag end.
    func previewStemGain(stemID: UUID, gainDB: Double, effectivelyMuted: Bool) {
        guard let stem = loadedStems.first(where: { $0.stemID == stemID }) else { return }
        setStemGainStage(stem, gainDB: gainDB, effectivelyMuted: effectivelyMuted)
    }

    /// Transient pan preview during a slider drag (no document write).
    func previewStemPan(stemID: UUID, pan: Double) {
        guard let stem = loadedStems.first(where: { $0.stemID == stemID }) else { return }
        setStemPanStage(stem, pan: pan)
    }

    /// Transient master gain preview during a slider drag.
    func previewMasterGain(gainDB: Double) {
        setMasterStage(gainDB: gainDB)
    }

    /// dB gain rides on the EQ (documented −96…+24 dB); the mixer volume
    /// carries only mute states — 0 for effective mute or the −60 dB slider
    /// floor (true silence), 1 otherwise — ramped so toggles never click.
    /// Shared by the per-stem stage (stem mixer + stem EQ) and the master
    /// stage (main mixer + master EQ).
    private func setGainStage(
        mixer: AVAudioMixerNode,
        eq: AVAudioUnitEQ,
        gainDB: Double,
        effectivelyMuted: Bool,
        immediate: Bool
    ) {
        if effectivelyMuted || StemMix.linearGain(fromDB: gainDB) <= 0 {
            setRampedParameter(node: mixer, param: .volume, from: mixer.outputVolume, to: 0, immediate: immediate) {
                mixer.outputVolume = $0
            }
        } else {
            setRampedParameter(node: mixer, param: .volume, from: mixer.outputVolume, to: 1, immediate: immediate) {
                mixer.outputVolume = $0
            }
            let target = Float(min(max(gainDB, -96), 24))
            setRampedParameter(node: eq, param: .gain, from: eq.globalGain, to: target, immediate: immediate) {
                eq.globalGain = $0
            }
        }
    }

    private func setStemGainStage(_ stem: LoadedStem, gainDB: Double, effectivelyMuted: Bool, immediate: Bool = false) {
        setGainStage(mixer: stem.mixer, eq: stem.eq, gainDB: gainDB, effectivelyMuted: effectivelyMuted, immediate: immediate)
    }

    /// Pan rides on the stem mixer (AVAudioMixing.pan, −1…+1) at its
    /// connection into the shared bus mixer.
    ///
    /// Measured law (pinned by the bouncePanBalance test): for STEREO stems
    /// the AU mixer treats pan as a balance control — the far channel
    /// attenuates linearly (gain = 1 − |pan|) while the near channel stays at
    /// unity, so center (0) is bit-transparent with the pre-pan behavior.
    private func setStemPanStage(_ stem: LoadedStem, pan: Double, immediate: Bool = false) {
        let mixer = stem.mixer
        let target = Float(min(max(pan, StemMix.minPan), StemMix.maxPan))
        setRampedParameter(node: mixer, param: .pan, from: mixer.pan, to: target, immediate: immediate) {
            mixer.pan = $0
        }
    }

    private func setMasterStage(gainDB: Double, immediate: Bool = false) {
        setGainStage(mixer: engine.mainMixerNode, eq: masterEQ, gainDB: gainDB, effectivelyMuted: false, immediate: immediate)
    }

    // MARK: - Level Taps (transport-scoped: installed on play, removed on stop)

    /// The metering tap body, built OUTSIDE any actor context.
    ///
    /// THIS `nonisolated static` IS THE WHOLE FIX FOR A SHIPPED CRASH, so it is
    /// worth stating plainly what it is defending against.
    ///
    /// `StemEngine` is `@MainActor`. Under the Swift 6 language mode (this
    /// package is `swift-tools-version: 6.0`) a closure LITERAL written inside a
    /// main-actor-isolated method inherits that isolation unless the parameter
    /// it is passed to is `@Sendable`. `AVAudioNodeTapBlock` is a bare
    /// `(AVAudioPCMBuffer, AVAudioTime) -> Void` — not `@Sendable` — so the two
    /// tap closures that used to live inline in `installLevelTaps()` were
    /// compiled as main-actor-isolated, and the compiler put a
    /// `swift_task_isCurrentExecutor` check at their entry.
    ///
    /// AVFAudio invokes tap blocks on `RealtimeMessenger.mServiceQueue`. Never
    /// the main thread. So the FIRST buffer that reached the tap failed
    /// `dispatch_assert_queue` and the process took a SIGTRAP — deterministic,
    /// not a race, and it survived `swift build` because the check is emitted
    /// at run time. In effect the level meters could never have run with audio
    /// flowing: pressing Play on any stem killed the app.
    ///
    /// Building the block here fixes it two ways at once. `nonisolated` means
    /// no isolation is inherited, and the explicit `@Sendable` return type
    /// means the COMPILER now rejects any future edit that reaches for
    /// main-actor state from inside the block — the mistake cannot be made
    /// again silently. Everything the block touches is the `@unchecked
    /// Sendable` accumulator, whose whole contract is being callable from the
    /// audio side.
    nonisolated static func levelTapBlock(
        for accumulator: StemLevelAccumulator
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in accumulator.ingest(buffer) }
    }

    /// Installs post-gain metering taps: one on each stem mixer (downstream of
    /// the EQ gain stage and the 0/1 mute volume) and one on the main mixer
    /// (downstream of the master gain). Taps exist ONLY while the transport is
    /// playing — pause/stop removes them, so idle CPU cost is zero.
    ///
    /// Every block comes from `levelTapBlock(for:)`. Do not inline one here.
    private func installLevelTaps() {
        guard !levelTapsInstalled else { return }
        levelTapsInstalled = true

        levelAccumulators = [:]
        for stem in loadedStems {
            let accumulator = StemLevelAccumulator()
            levelAccumulators[stem.stemID] = accumulator
            stem.mixer.installTap(
                onBus: 0, bufferSize: 1024, format: nil,
                block: Self.levelTapBlock(for: accumulator))
        }
        masterLevelAccumulator.reset()
        engine.mainMixerNode.installTap(
            onBus: 0, bufferSize: 1024, format: nil,
            block: Self.levelTapBlock(for: masterLevelAccumulator))
    }

    /// Removes all metering taps and clears published levels. Must run before
    /// stem nodes are detached (loadStems/unload go through stopTransport).
    private func removeLevelTaps() {
        guard levelTapsInstalled else { return }
        levelTapsInstalled = false

        for stem in loadedStems {
            stem.mixer.removeTap(onBus: 0)
        }
        engine.mainMixerNode.removeTap(onBus: 0)
        levelAccumulators = [:]
        stemLevels = [:]
        masterLevels = .zero
    }

    /// Drains the tap accumulators into the published level state (called from
    /// the 20 Hz UI tick while playing).
    private func publishLevels() {
        guard levelTapsInstalled else { return }
        var levels: [UUID: StemLevels] = [:]
        levels.reserveCapacity(levelAccumulators.count)
        for (stemID, accumulator) in levelAccumulators {
            levels[stemID] = accumulator.read()
        }
        stemLevels = levels
        masterLevels = masterLevelAccumulator.read()
    }

    // MARK: - Transport

    func play() {
        guard !isBouncing, !loadedStems.isEmpty, !isPlaying else { return }
        // Restart from the top when the playhead is parked at the end.
        if playheadBase >= duration {
            playheadBase = 0
        }
        do {
            try startPlayback(from: playheadBase)
        } catch {
            ToastManager.shared.show("Could not start playback: \(error.localizedDescription)", style: .error)
            print("[StemEngine] Play failed: \(error)")
        }
    }

    func pause() {
        guard isPlaying else { return }
        let position = min(renderPosition, duration)
        for stem in loadedStems {
            stem.player.stop()
        }
        removeLevelTaps()
        playheadBase = position
        currentTime = position
        isPlaying = false
        stopTimer()
    }

    func stop() {
        stopTransport(resetPosition: true)
    }

    /// Seeks to a position in seconds. While playing, re-schedules every stem
    /// from the target frame and restarts them against a fresh common anchor.
    func seek(to seconds: Double) {
        guard !isBouncing else { return }
        let clamped = max(0, min(seconds, duration))
        if isPlaying {
            for stem in loadedStems {
                stem.player.stop()
            }
            do {
                try startPlayback(from: clamped)
            } catch {
                removeLevelTaps()
                playheadBase = clamped
                currentTime = clamped
                isPlaying = false
                stopTimer()
                print("[StemEngine] Seek restart failed: \(error)")
            }
        } else {
            playheadBase = clamped
            currentTime = clamped
        }
    }

    private func stopTransport(resetPosition: Bool) {
        for stem in loadedStems {
            stem.player.stop()
        }
        removeLevelTaps()
        if resetPosition {
            playheadBase = 0
            currentTime = 0
        }
        isPlaying = false
        stopTimer()
    }

    /// Schedules all stems from `seconds` and starts them on one shared anchor.
    private func startPlayback(from seconds: Double) throws {
        try ensureEngineRunning()
        installLevelTaps()
        scheduleAll(fromSeconds: seconds)

        // One common anchor slightly in the future → sample-accurate sync.
        let anchorHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: startLeadTime)
        let anchor = AVAudioTime(hostTime: anchorHostTime)
        for stem in loadedStems {
            stem.player.play(at: anchor)
        }

        playheadBase = seconds
        isPlaying = true
        startTimer()
    }

    /// Stops each player and schedules its remaining segment from `seconds`.
    /// Frame offsets are computed in each stem's own file sample rate.
    private func scheduleAll(fromSeconds seconds: Double) {
        for stem in loadedStems {
            stem.player.stop()
            let startFrame = AVAudioFramePosition((seconds * stem.fileSampleRate).rounded())
            let remaining = stem.lengthFrames - startFrame
            guard remaining > 0 else { continue }  // Stem ends before the seek point.
            stem.player.scheduleSegment(
                stem.file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil
            )
        }
    }

    private func ensureEngineRunning() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw StemEngineError.engineStartFailed(error.localizedDescription)
        }
    }

    // MARK: - Position (render clock, never wall clock)

    /// Longest stem = reference clock. Its player keeps rendering (silence)
    /// after shorter stems end, so it is valid for the whole session length.
    private var referenceStem: LoadedStem? {
        loadedStems.max { $0.durationSeconds < $1.durationSeconds }
    }

    /// Current position derived from the reference player's render time versus
    /// the last schedule base. Before the start anchor is reached, sampleTime
    /// can be negative — clamped to the base position.
    private var renderPosition: Double {
        guard isPlaying,
              let ref = referenceStem,
              let nodeTime = ref.player.lastRenderTime,
              let playerTime = ref.player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return playheadBase
        }
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        return playheadBase + max(0, elapsed)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        let position = renderPosition
        if position >= duration {
            // End of the longest stem — park at the end.
            for stem in loadedStems {
                stem.player.stop()
            }
            removeLevelTaps()
            playheadBase = duration
            currentTime = duration
            isPlaying = false
            stopTimer()
            onPlaybackFinished?()
        } else {
            currentTime = position
            publishLevels()
        }
    }

    // MARK: - Bounce (offline render of the SAME graph)

    /// Total session length in session-format frames (longest stem, converted
    /// to the session rate). This is the exact frame count a bounce writes.
    var totalSessionFrames: AVAudioFramePosition {
        let rate = sessionFormat.sampleRate
        return loadedStems
            .map { AVAudioFramePosition((Double($0.lengthFrames) * rate / $0.fileSampleRate).rounded(.up)) }
            .max() ?? 0
    }

    /// Renders the current graph offline to `url` with the mix from `document`,
    /// using `enableManualRenderingMode(.offline)` on the SAME engine/graph as
    /// live playback (same nodes, same gain staging) — so the bounce is
    /// sample-aligned with what monitoring plays. WAV output is float32 PCM and
    /// contains exactly `totalSessionFrames` frames; M4A adds AAC codec padding
    /// by nature.
    ///
    /// Runs on the main actor but yields between render blocks, so the UI stays
    /// responsive; offline mixing renders far faster than realtime.
    func bounce(to url: URL, mix document: StemSessionDocument) async throws {
        guard !loadedStems.isEmpty else { throw StemEngineError.noStemsLoaded }
        guard !isBouncing else { throw StemEngineError.bounceInProgress }

        isBouncing = true
        bounceProgress = 0

        // Capture live state, then halt the transport.
        let resumePosition = isPlaying ? min(renderPosition, duration) : playheadBase
        stopTransport(resetPosition: false)
        engine.stop()

        do {
            try engine.enableManualRenderingMode(
                .offline,
                format: sessionFormat,
                maximumFrameCount: 4096
            )
            // Same gain staging as live playback; immediate so the render
            // starts at the exact document mix (no initial ramp smear).
            applyMix(from: document, immediate: true)
            try engine.start()

            // In manual rendering mode the render clock starts at frame 0, so
            // scheduling from 0 and calling play() starts every stem at exactly
            // the first rendered frame.
            scheduleAll(fromSeconds: 0)
            for stem in loadedStems {
                stem.player.play()
            }

            let totalFrames = totalSessionFrames
            let outputFile = try AVAudioFile(
                forWriting: url,
                settings: Self.fileSettings(for: url, sampleRate: sessionFormat.sampleRate),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: engine.manualRenderingMaximumFrameCount
            ) else {
                throw StemEngineError.renderFailed("Could not allocate render buffer")
            }

            var blockCount = 0
            var stallCount = 0
            // Small-block countdown after a ramp's final step: AU parameter
            // changes smooth linearly across the NEXT render buffer, so the
            // last step must land in small buffers too or it would smear
            // across a full 4096-frame block (~93 ms) instead of ~3 ms.
            var rampSettleBlocks = 0
            while engine.manualRenderingSampleTime < totalFrames {
                let remaining = totalFrames - engine.manualRenderingSampleTime
                // While a parameter ramp is in flight (mid-bounce mute/gain/pan
                // change), render in ~3 ms blocks (128 frames @ 44.1 kHz) so the
                // ramp steps land INSIDE the ramp window in render time; the AU
                // mixer's per-buffer smoothing interpolates between the steps.
                let ramping = hasActiveRamps
                let blockCap: AVAudioFramePosition = (ramping || rampSettleBlocks > 0)
                    ? 128
                    : AVAudioFramePosition(buffer.frameCapacity)
                let framesToRender = AVAudioFrameCount(min(blockCap, remaining))
                let status = try engine.renderOffline(framesToRender, to: buffer)

                switch status {
                case .success:
                    stallCount = 0
                    try outputFile.write(from: buffer)
                    // Ramps advance on the RENDER clock during a bounce.
                    if ramping {
                        advanceRamps(by: Double(buffer.frameLength) / sessionFormat.sampleRate)
                        if !hasActiveRamps {
                            rampSettleBlocks = 4  // let the AU smoothing converge in small blocks
                        }
                    } else if rampSettleBlocks > 0 {
                        rampSettleBlocks -= 1
                    }
                case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                    stallCount += 1
                    if stallCount > 1000 {
                        throw StemEngineError.renderFailed("Render stalled at frame \(engine.manualRenderingSampleTime)")
                    }
                case .error:
                    throw StemEngineError.renderFailed("Render error at frame \(engine.manualRenderingSampleTime)")
                @unknown default:
                    throw StemEngineError.renderFailed("Unknown render status at frame \(engine.manualRenderingSampleTime)")
                }

                blockCount += 1
                if blockCount % 16 == 0 {
                    bounceProgress = Double(engine.manualRenderingSampleTime) / Double(max(totalFrames, 1))
                    await Task.yield()  // Keep the main thread breathing.
                }
            }
            bounceProgress = 1.0
        } catch {
            restoreAfterBounce(resumePosition: resumePosition)
            isBouncing = false
            throw error
        }

        restoreAfterBounce(resumePosition: resumePosition)
        isBouncing = false
        print("[StemEngine] Bounced \(loadedStems.count) stems to \(url.lastPathComponent)")
    }

    /// Returns the engine to live (stopped) state after a bounce, preserving
    /// the pre-bounce transport position. The engine restarts lazily on the
    /// next play().
    private func restoreAfterBounce(resumePosition: Double) {
        // A bounce can end mid-ramp; land every ramp on its target so the
        // live graph matches the document exactly.
        finishRampsImmediately()
        for stem in loadedStems {
            stem.player.stop()
        }
        engine.stop()
        engine.disableManualRenderingMode()
        playheadBase = min(resumePosition, duration)
        currentTime = playheadBase
        isPlaying = false
    }

    /// AVAudioFile settings for the bounce destination, keyed off the file
    /// extension. WAV = float32 PCM (bit-transparent with the render output).
    nonisolated static func fileSettings(for url: URL, sampleRate: Double) -> [String: Any] {
        switch url.pathExtension.lowercased() {
        case "m4a":
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000
            ]
        default:  // wav
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    // MARK: - Formatting

    /// "m:ss.cc" timecode for the transport bar.
    nonisolated static func formatTimecode(_ seconds: Double) -> String {
        let safe = max(0, seconds)
        let mins = Int(safe) / 60
        let secs = Int(safe) % 60
        let centis = Int((safe - floor(safe)) * 100)
        return String(format: "%d:%02d.%02d", mins, secs, centis)
    }
}
