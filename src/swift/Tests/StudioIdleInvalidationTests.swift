import Testing
import Foundation
import Combine
@testable import MajiksMusicStudio

// Bug B of the keychain P0: something invalidated `StudioCopilotDock.body` about
// nine times a second while the owner was doing nothing but listening to music.
// A free body re-evaluating on a timer is a defect on its own; here it is what
// turned one blocking securityd round trip into ~290,000 of them over an
// eight-hour session.
//
// The driver, found by reading rather than guessing:
//
//   AudioPlayer.startTimer()          Timer, 0.1 s, repeats  (AudioPlayer.swift)
//     -> self.currentTime = player.currentTime      @Published, UNCONDITIONAL
//       -> objectWillChange
//         -> ContentView (@EnvironmentObject var player: AudioPlayer)
//           -> the whole TabView body, StudioRootView and the dock inside it
//             -> .task(id: BrigadeConfig.isConfigured)   -> SecItemCopyMatching
//
// 0.1 s is the ~110 ms the sample measured. Two fixes, independent:
//   1. `adoptClock` publishes on CHANGE, not on tick — asserted below.
//   2. `ContentView` no longer observes AudioPlayer at all; the bar does, from
//      its own leaf (`PersistentPlayerBarSlot`). NOT asserted here — see the
//      "known gap" note at the bottom.

@MainActor
@Suite("idle invalidation")
struct StudioIdleInvalidationTests {

    /// Count `objectWillChange` emissions, which is precisely what SwiftUI
    /// subscribes to. Not a proxy for the invalidation — it IS the invalidation.
    private func countingPublishes(
        of object: AudioPlayer,
        during body: () -> Void
    ) -> Int {
        var count = 0
        let token = object.objectWillChange.sink { _ in count += 1 }
        body()
        token.cancel()
        return count
    }

    @Test("a clock that has not moved publishes nothing")
    func anUnchangedClockDoesNotInvalidateEveryObserver() {
        let player = AudioPlayer()
        player.adoptClock(12.5)   // settle on a value before measuring

        let publishes = countingPublishes(of: player) {
            // 100 ticks is ten seconds of playback at the real 0.1 s interval.
            for _ in 0..<100 { player.adoptClock(12.5) }
        }

        #expect(
            publishes == 0,
            """
            100 no-op clock ticks published \(publishes) times. Each one of those \
            invalidates every view observing AudioPlayer.
            """
        )
    }

    @Test("a clock that HAS moved still publishes, once per real move")
    func arealMoveStillPublishes() {
        // The guard against fixing the noise by going deaf. If this test ever
        // reads 0, `adoptClock` has stopped reporting the transport and the
        // scrubber is frozen — a much worse bug than the one above.
        let player = AudioPlayer()
        player.adoptClock(0)

        let publishes = countingPublishes(of: player) {
            for tick in 1...10 { player.adoptClock(Double(tick) * 0.1) }
        }

        #expect(publishes == 10, "ten real clock moves published \(publishes) times")
        #expect(player.currentTime == 1.0)
    }

    // MARK: - the same defect, found by sweeping for it rather than by sampling
    //
    // `StudioInputScope` (the rolling waveform in the record cockpit) ran the
    // identical shape: a 30 Hz `Timer.publish` whose `.onReceive` assigned to
    // `@State history` UNCONDITIONALLY. @State does not compare — every
    // assignment invalidates and repaints the Canvas whether or not a pixel
    // moved — so the scope redrew thirty times a second for as long as a track
    // was armed, including with no input stream open and nothing to draw.
    //
    // Narrower than the AudioPlayer bug (the record bar only exists while a
    // track is armed, and the invalidation stops at the Canvas rather than
    // reaching the whole TabView), which is exactly why nothing had noticed it.
    //
    // `advanced` is pure and static so these count real updates without standing
    // up a view, the same seam shape `StudioViewModel.pollOnce` uses.

    @Test("a settled silent scope stops updating instead of repainting nothing")
    func anIdleInputScopeSettlesAndThenPublishesNothing() {
        var history = [Double](repeating: 0, count: 120)
        // Start from a real signal and let it decay, rather than from a zero
        // array — otherwise the test starts in the answer and proves only that
        // zeros stay zero.
        history[119] = 1.0

        var updates = 0
        var settledAfter: Int?
        // 300 ticks is ten seconds of a track sitting armed and silent.
        for tick in 0..<300 {
            guard let next = StudioInputScope.advanced(history, level: 0, active: false) else {
                if settledAfter == nil { settledAfter = tick }
                continue
            }
            history = next
            updates += 1
        }

        // The decay is real and must still run: 1.0 falling by 0.08 a tick
        // reaches 0 in 13 ticks, then the window needs to scroll that tail off
        // the end. What matters is that it STOPS.
        #expect(updates > 0, "the scope never updated at all; the decay is gone, not quiet")
        #expect(
            settledAfter != nil,
            "300 idle ticks never settled — the scope is still repainting on an empty input"
        )
        #expect(
            updates <= 140,
            """
            an idle scope took \(updates) updates to go quiet. It should decay \
            (13 ticks) and scroll the tail off a 120-sample window, then stop. \
            Before the change this figure was 300 — one per tick, forever.
            """
        )
        #expect(history.allSatisfy { $0 == 0 }, "settled on a non-silent window")
    }

    @Test("a LIVE scope still updates every tick — the guard against going deaf")
    func aLiveInputScopeStillScrolls() {
        // The counterpart, and the more important of the two: it is trivial to
        // make the assertion above pass by breaking the meter. If this ever
        // reads 0 the record scope is a flat line during an actual take.
        var history = [Double](repeating: 0, count: 120)
        var updates = 0
        for tick in 1...100 {
            // A moving signal, as a real input is.
            let level = 0.5 + 0.4 * sin(Double(tick) / 3.0)
            guard let next = StudioInputScope.advanced(history, level: level, active: true) else { continue }
            history = next
            updates += 1
        }
        #expect(updates == 100, "a live input published \(updates) of 100 ticks")
        #expect(history.last ?? 0 > 0, "the newest sample is silent on a live input")
    }

    @Test("a dead-flat live input is also nothing to redraw")
    func aFlatLiveInputAlsoGoesQuiet() {
        // Not a special case in the code — `advanced` compares the resulting
        // window — but worth pinning, because this is the state a track sits in
        // when the input is open and the room is quiet, which is most of a
        // session. An enumerated `if !active` check would have missed it.
        let history = [Double](repeating: 0.25, count: 120)
        #expect(StudioInputScope.advanced(history, level: 0.25, active: true) == nil)
        // …and a real move off that plateau still gets through.
        #expect(StudioInputScope.advanced(history, level: 0.26, active: true) != nil)
    }

    // KNOWN GAP, stated rather than papered over:
    //
    // Nothing here asserts that `ContentView.body` no longer re-evaluates when
    // the player publishes. SwiftUI exposes no headless seam for counting body
    // evaluations, and `ContentView` cannot be rendered through `ImageRenderer`
    // without standing up the entire app environment (LLMProviderSettings,
    // PlaybackQueue, LibraryStore, AudioPlayer, StudioCoordinator) — at which
    // point the thing under test is the harness.
    //
    // What IS asserted, in StudioKeychainCostTests: thirty real renders of the
    // real dock cost ONE securityd round trip. So even if some other publisher
    // is still driving the tree at 10 Hz, the cost of a pass is no longer an
    // XPC round trip. The observer decoupling in ContentView is a correctness
    // improvement whose effect is argued from the code, not measured.
}
