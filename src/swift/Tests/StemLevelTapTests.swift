import XCTest
import AVFoundation
@testable import MajiksMusicStudio

// Pressing Play on the Stems tab killed the app.
//
// `StemEngine` is `@MainActor`. `installLevelTaps()` used to hand AVFAudio two
// closure LITERALS written inside that main-actor method, and under the Swift 6
// language mode a non-`@Sendable` closure literal inherits the isolation of the
// context it is written in. AVFAudio calls tap blocks on
// `RealtimeMessenger.mServiceQueue`, so the first buffer that reached a tap
// tripped `swift_task_isCurrentExecutor` -> `dispatch_assert_queue` ->
// SIGTRAP. Deterministic, on any stem, on the first playback.
//
// `swift build` cannot see it: the executor check is emitted for RUN time, and
// the shipped 3.4.11 build compiled clean. So the test has to do the one thing
// the build cannot — call the tap body from a queue that is not the main queue.
//
// If the fix is reverted, `theTapBodyRunsOffTheMainQueue` does not politely
// fail: the process takes the same SIGTRAP it took in front of the owner, and
// XCTest reports the crash against this test's name. The source-shape test
// below fails cleanly by name at the same time, so a regression is legible
// even from a crashed run's log.
final class StemLevelTapTests: XCTestCase {

    // MARK: - Buffers
    //
    // Built INSIDE whatever context is about to use them: `AVAudioPCMBuffer` is
    // not Sendable, and the whole point of these tests is that they respect the
    // isolation rules the shipped code broke.

    /// A stereo buffer whose first half sits at `peak` and second half at
    /// silence, so peak and RMS are different, known numbers:
    /// peak = `peak`, rms = `peak` / sqrt(2).
    private nonisolated static func halfToneBuffer(
        peak: Float, frames: AVAudioFrameCount = 512
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = frames
        let half = Int(frames) / 2
        for channel in 0..<Int(format.channelCount) {
            let samples = channels[channel]
            for i in 0..<Int(frames) {
                samples[i] = i < half ? peak : 0
            }
        }
        return buffer
    }

    // MARK: - 1. The crash itself

    /// THE regression test. Drives the real tap body from a real background
    /// queue. Before the fix this SIGTRAPs; after it, the levels arrive.
    func testTheTapBodyRunsOffTheMainQueueWithoutTrapping() throws {
        let accumulator = StemLevelAccumulator()
        let block = StemEngine.levelTapBlock(for: accumulator)

        let ran = expectation(description: "tap block returned off the main queue")
        // A private serial queue: emphatically not the main queue, the same
        // shape as AVFAudio's RealtimeMessenger service queue.
        DispatchQueue(label: "majiks.test.stem.tap").async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            guard let buffer = Self.halfToneBuffer(peak: 0.8) else { return }
            block(buffer, AVAudioTime(sampleTime: 0, atRate: 44_100))
            ran.fulfill()
        }
        wait(for: [ran], timeout: 5)

        let levels = accumulator.read()
        XCTAssertEqual(levels.peak, 0.8, accuracy: 0.0005,
                       "the tap ran but the peak never reached the accumulator")
        // 0.8 / sqrt(2) = 0.565685…
        XCTAssertEqual(levels.rms, 0.565685, accuracy: 0.0005,
                       "RMS is not the half-tone buffer's true RMS")
    }

    /// The constructive half of the fix: the block's TYPE.
    ///
    /// The two coercions below only compile while `levelTapBlock` really is
    /// non-isolated — a main-actor-isolated closure does not convert to a
    /// `@Sendable` function type — and the second proves the `@Sendable` form
    /// is still what `installTap` accepts, so the safe shape is also the
    /// usable one. Then it runs on a global concurrent queue (another executor
    /// the main-actor check would reject) so the test is not purely a
    /// type-level claim.
    func testTheTapBlockConvertsToASendableAVFAudioTapAndRunsOffMain() throws {
        let accumulator = StemLevelAccumulator()
        let sendable: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void =
            StemEngine.levelTapBlock(for: accumulator)
        let tap: AVAudioNodeTapBlock = sendable

        let ran = expectation(description: "tap ran on a global concurrent queue")
        DispatchQueue.global(qos: .userInitiated).async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            guard let buffer = Self.halfToneBuffer(peak: 0.5) else { return }
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 44_100))
            ran.fulfill()
        }
        wait(for: [ran], timeout: 5)

        XCTAssertEqual(accumulator.read().peak, 0.5, accuracy: 0.0005)
    }

    // MARK: - 2. The shape that keeps it fixed

    private static let stemEngineSource: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                       // Tests
            .appendingPathComponent("../Sources/StemSessions/StemEngine.swift")
            .standardizedFileURL
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Every `installTap` in StemEngine must hand over the factory's block.
    ///
    /// This is the net that survives a crashed run: a SIGTRAP takes the process
    /// down and can make a log hard to read, whereas this fails as a named
    /// assertion. Re-inline a tap closure — which is exactly how the bug was
    /// written — and it names the file and the count.
    func testEveryTapInStemEngineUsesTheNonIsolatedFactory() throws {
        let source = Self.stemEngineSource
        XCTAssertFalse(source.isEmpty, "StemEngine.swift did not load, so this test proves nothing")

        let installs = source.components(separatedBy: "installTap(").count - 1
        let factoryUses = source.components(separatedBy: "block: Self.levelTapBlock(for:").count - 1

        XCTAssertEqual(installs, 2,
                       "StemEngine installs \(installs) taps; this test knows about 2 (per-stem + master)")
        XCTAssertEqual(factoryUses, installs,
                       """
                       \(installs - factoryUses) tap(s) in StemEngine.swift pass a closure literal \
                       instead of `block: Self.levelTapBlock(for:)`. A closure written inside this \
                       @MainActor type inherits main-actor isolation and SIGTRAPs on AVFAudio's tap \
                       queue the first time audio flows.
                       """)
    }

    /// The factory must stay `nonisolated`: that keyword is the fix. An edit
    /// that drops it re-isolates the block to the main actor and restores the
    /// crash, while everything still compiles.
    func testTheTapFactoryIsDeclaredNonIsolatedAndSendable() throws {
        let source = Self.stemEngineSource
        XCTAssertTrue(
            source.contains("nonisolated static func levelTapBlock("),
            "levelTapBlock lost its `nonisolated`; the tap block is main-actor isolated again")
        XCTAssertTrue(
            source.contains(") -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void"),
            "levelTapBlock lost its @Sendable return type, so the compiler will no longer reject a main-actor capture inside the tap")
    }

    // MARK: - 3. The accumulator under audio-side concurrency

    /// Peak is a MAX-HOLD across every buffer since the last read, from any
    /// number of queues at once. 64 concurrent ingests, one of which carries
    /// the loudest buffer: the reader must see that one.
    func testPeakHoldsTheLoudestBufferAcrossConcurrentTapQueues() {
        let accumulator = StemLevelAccumulator()
        let block = StemEngine.levelTapBlock(for: accumulator)
        let loudestIndex = 41

        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let peak: Float = i == loudestIndex ? 0.94 : 0.1
            guard let buffer = Self.halfToneBuffer(peak: peak, frames: 256) else { return }
            block(buffer, AVAudioTime(sampleTime: 0, atRate: 44_100))
        }

        XCTAssertEqual(accumulator.read().peak, 0.94, accuracy: 0.0005,
                       "a concurrent ingest lost the loudest buffer's peak")
    }

    /// `read()` is READ-AND-RESET, which is why there is exactly one poller.
    /// A second reader would find the hold already drained — this test pins
    /// that contract so nobody adds one and wonders where the peaks went.
    func testReadingLevelsReArmsThePeakHoldSoASecondReaderWouldSeeNothing() throws {
        let accumulator = StemLevelAccumulator()
        let block = StemEngine.levelTapBlock(for: accumulator)

        let ran = expectation(description: "ingested")
        DispatchQueue(label: "majiks.test.stem.tap.rearm").async {
            guard let buffer = Self.halfToneBuffer(peak: 0.6) else { return }
            block(buffer, AVAudioTime(sampleTime: 0, atRate: 44_100))
            ran.fulfill()
        }
        wait(for: [ran], timeout: 5)

        XCTAssertEqual(accumulator.read().peak, 0.6, accuracy: 0.0005)
        XCTAssertEqual(accumulator.read().peak, 0, accuracy: 0.0005,
                       "the peak hold did not re-arm, so the meter would stick at its maximum")
        // RMS deliberately persists until the next buffer overwrites it.
        XCTAssertEqual(accumulator.read().rms, 0.424264, accuracy: 0.0005)
    }

    func testResetClearsBothLevels() {
        let accumulator = StemLevelAccumulator()
        let block = StemEngine.levelTapBlock(for: accumulator)
        let ran = expectation(description: "ingested")
        DispatchQueue(label: "majiks.test.stem.tap.reset").async {
            guard let buffer = Self.halfToneBuffer(peak: 0.7) else { return }
            block(buffer, AVAudioTime(sampleTime: 0, atRate: 44_100))
            ran.fulfill()
        }
        wait(for: [ran], timeout: 5)

        accumulator.reset()
        let levels = accumulator.read()
        XCTAssertEqual(levels.peak, 0)
        XCTAssertEqual(levels.rms, 0)
    }
}
