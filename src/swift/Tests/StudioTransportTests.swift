import Testing
import Foundation
@testable import MajiksMusicStudio

// Transport contract for the Studio DAW (the "Stop and Pause don't work" fix):
//
//  - Play starts the transport and the play head advances.
//  - Pause HALTS IN PLACE: `isPlaying` goes false and the play head holds where
//    it was (not the start); a later Play resumes from there.
//  - Stop HALTS AND REWINDS: `isPlaying` goes false and the play head resets to
//    0, and stays there (no wall-clock run-away).
//
// Driven through the view model onto the silent mock engine, so it runs under
// `MAJIKS_ENGINE=mock swift test` with no audio device. The play head is read
// via `playheadTicks(now:)` — the same wall-clock-interpolated value the
// transport bar and timeline draw — so a regression where a stopped/paused head
// keeps advancing is caught here.
@MainActor
@Suite("Studio transport")
struct StudioTransportTests {

    /// Poll the 30 Hz view model until `condition` holds (or time out). The
    /// transport commands are async (a command out, a snapshot back), so tests
    /// wait on the observable end-state rather than sleeping a fixed amount.
    private func wait(
        _ model: StudioViewModel,
        timeout: TimeInterval = 3.0,
        until condition: @MainActor (StudioViewModel) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(model) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    @Test("Pause holds the play head in place; Stop halts and rewinds to the start")
    func pauseHoldsStopResets() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }

        // The engine's first snapshot must land before we drive the transport.
        await wait(model) { $0.snapshot != nil }
        #expect(model.snapshot != nil, "engine produced a first snapshot")
        #expect(!model.isPlaying, "the transport is idle at start")

        // --- Play: the transport goes live and the play head advances. ---
        model.play()
        await wait(model) { $0.isPlaying }
        #expect(model.isPlaying, "Play started the transport")
        let p0 = model.playheadTicks(now: now())
        try? await Task.sleep(nanoseconds: 150_000_000)
        let p1 = model.playheadTicks(now: now())
        #expect(p1 > p0, "the play head advances while playing (\(p0) -> \(p1))")

        // --- Pause: halt IN PLACE. isPlaying false; play head held (> 0), frozen. ---
        model.pause()
        await wait(model) { !$0.isPlaying }
        #expect(!model.isPlaying, "Pause halted the transport")
        let held = model.playheadTicks(now: now())
        #expect(held > 0, "Pause holds the play head where it was, not at the start (\(held))")
        try? await Task.sleep(nanoseconds: 150_000_000)
        let heldLater = model.playheadTicks(now: now())
        #expect(heldLater == held, "a paused play head does not drift (\(held) -> \(heldLater))")

        // --- Play again: resume from the held position (not from 0). ---
        model.play()
        await wait(model) { $0.isPlaying }
        #expect(model.isPlaying, "Play resumes after a Pause")
        let resumed = model.playheadTicks(now: now())
        #expect(resumed >= held, "resume continues from the paused position (\(held) -> \(resumed))")

        // --- Stop: halt AND rewind toward the start, and stay there. ---
        // (The play head lands at ~0: the render core's stop declick advances a
        // few frames past the seek target, so this asserts "near the start", not
        // a single exact tick — while still catching a Stop that stayed put
        // (pause) or, worse, resumed and kept advancing.)
        let startTolerance: Int64 = 48   // << `held` (hundreds of ticks); ~25 ms at 120 BPM
        model.stop()
        await wait(model) { !$0.isPlaying && $0.playheadTicks(now: self.now()) <= startTolerance }
        #expect(!model.isPlaying, "Stop halted the transport")
        let afterStop = model.playheadTicks(now: now())
        #expect(afterStop < held, "Stop rewound the play head back toward the start (\(held) -> \(afterStop))")
        #expect(afterStop <= startTolerance, "Stop lands at (approximately) the start (\(afterStop))")
        try? await Task.sleep(nanoseconds: 120_000_000)
        let afterStopLater = model.playheadTicks(now: now())
        #expect(afterStopLater == afterStop, "a stopped play head stays put, no wall-clock drift (\(afterStop) -> \(afterStopLater))")
    }

    @Test("PlayheadTicks never exceeds lengthTicks and auto-stop guard prevents drift after stop")
    func playheadRespectsLengthTicks() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        let lengthTicks = model.projectLengthTicks
        #expect(lengthTicks > 0, "a project has a positive length")

        // While stopped, playheadTicks must respect lengthTicks.
        let beforeStart = model.playheadTicks(now: now())
        #expect(beforeStart < lengthTicks || beforeStart == lengthTicks,
                "playhead starts before the end of content")

        model.play()
        await wait(model) { $0.isPlaying }

        // The playhead advances but never exceeds lengthTicks.
        let midPlay = model.playheadTicks(now: now())
        #expect(midPlay > beforeStart, "playhead advances during playback")
        #expect(midPlay <= lengthTicks, "playhead never exceeds lengthTicks")

        // Stop the transport.  The play head must stay frozen.
        model.stop()
        await wait(model) { !$0.isPlaying }
        let afterStop = model.playheadTicks(now: now())
        try? await Task.sleep(nanoseconds: 100_000_000)
        let afterStopLater = model.playheadTicks(now: now())
        #expect(afterStopLater == afterStop,
                "a stopped play head stays put (\(afterStop) -> \(afterStopLater))")
    }
}
