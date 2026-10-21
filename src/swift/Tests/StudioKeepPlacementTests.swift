import Testing
import Foundation
@testable import MajiksMusicStudio

// KEEP: where it lands, and how to throw one away.
//
// A person played a 56-note passage and pressed Keep. It worked — one clean
// undo step, every note at the rhythm it was played — and the clip landed at
// bar 1,076, off screen, with nothing saying so. The engine half of that fix
// (anchor the take to the music rather than to a runaway clock) is proven in
// `engine/agent-surface/tests/performance_placement.rs`, on the real MIDI pump.
//
// This file covers the half the engine cannot: WHERE THE USER IS LOOKING. A
// clip the app placed correctly and never showed is indistinguishable from
// nothing having happened.

@MainActor
private func adoptedViewModel(_ engine: StudioMockEngine) async throws -> StudioViewModel {
    let vm = StudioViewModel(engine: engine)
    vm.startPolling()
    for _ in 0..<200 where vm.snapshot == nil {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    vm.stopPolling()
    try #require(vm.snapshot != nil, "the view model never adopted a snapshot")
    return vm
}

@Suite("Keep puts the notes on screen")
struct StudioRevealTests {

    @Test("reveal scrolls to a bar before the target so the clip is not against the edge")
    @MainActor
    func revealScrolls() async throws {
        let vm = try await adoptedViewModel(StudioMockEngine())
        let perBar = Int64(vm.timeSignature.ticksPerBar)

        vm.reveal(ticks: 12 * perBar)
        #expect(vm.scrollTicks == 11 * perBar,
                "a clip flush against the left edge reads as cut off; reveal leaves a bar in front")
    }

    /// A take at bar 1 must not scroll to a negative position.
    @Test("revealing the very start clamps at zero")
    @MainActor
    func revealClampsAtZero() async throws {
        let vm = try await adoptedViewModel(StudioMockEngine())
        vm.reveal(ticks: 0)
        #expect(vm.scrollTicks == 0)
    }

    /// THE part that is easy to miss. Playhead-following is on by default; a
    /// reveal that left it on would be dragged straight back to wherever the
    /// transport has got to — which, on the day this was written, was bar 1,076.
    @Test("reveal turns playhead-following off")
    @MainActor
    func revealStopsFollowing() async throws {
        let vm = try await adoptedViewModel(StudioMockEngine())
        vm.followPlayhead = true

        vm.reveal(ticks: 40 * Int64(vm.timeSignature.ticksPerBar))

        #expect(vm.followPlayhead == false, """
            reveal left playhead-following on, so the view scrolls straight back to the \
            transport and the person never sees what they just played.
            """)
    }

    /// Bars are 1-based everywhere on screen, so the sentence a person reads
    /// has to be too. "bar 0" would send them looking in the wrong place.
    @Test("the bar label a toast prints is 1-based")
    @MainActor
    func barLabelIsOneBased() async throws {
        let vm = try await adoptedViewModel(StudioMockEngine())
        let perBar = Int64(vm.timeSignature.ticksPerBar)
        #expect(vm.barLabel(0) == "bar 1")
        #expect(vm.barLabel(perBar) == "bar 2")
        #expect(vm.barLabel(8 * perBar) == "bar 9")
    }
}

@Suite("The keyboard rail can throw a take away")
struct StudioDiscardWiringTests {

    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Studio")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// The affordance exists, is next to Keep, and calls something.
    @Test("the control rail offers a discard beside Keep, and it sends")
    func theRailHasADiscard() throws {
        let keyboard = try Self.source("StudioOnScreenKeyboard.swift")
        #expect(keyboard.contains("discardButton"), """
            the keyboard rail has no discard affordance. Keep is the only exit from the \
            retro-capture buffer again, which leaves "how do I not keep notes?" unanswered.
            """)
        #expect(keyboard.contains("model.discardPerformance()"),
                "the discard button sends nothing — it is decoration")
        #expect(keyboard.contains("keepButton"), "Keep vanished")
    }

    /// The help text is the whole safety story for a destructive-looking
    /// button, and this user has never used a DAW. It has to say what CANNOT be
    /// reached, and that there is nothing to undo — a person who presses Cmd-Z
    /// expecting the take back and gets their previous edit undone instead is
    /// worse off than before the button existed.
    @Test("the discard help says what it cannot reach and that there is no undo")
    func theDiscardHelpIsHonest() throws {
        let keyboard = try Self.source("StudioOnScreenKeyboard.swift")
        // Phrases short enough to survive the line breaks the help string is
        // written across — a needle that spans a `+` join would fail on
        // formatting rather than on meaning.
        for phrase in ["without", "nothing to undo", "already in your"] {
            #expect(keyboard.contains(phrase), """
                the discard button's help no longer says "\(phrase)". That sentence is the \
                entire safety story for a button with a trash can on it.
                """)
        }
    }

    /// Keep must still put the result on screen. Deleting the reveal is a
    /// silent regression: everything else about Keep keeps working.
    @Test("keeping a performance reveals where it landed")
    func keepReveals() throws {
        let vm = try Self.source("StudioViewModel.swift")
        #expect(vm.contains("reveal(ticks: outcome.startTicks)"), """
            keepPerformance no longer scrolls to the clip it just made. A clip the app placed \
            correctly and never showed is indistinguishable from nothing having happened — \
            which is exactly how a 56-note take at bar 1,076 went unnoticed.
            """)
        #expect(vm.contains("outcome.snapped"), """
            keepPerformance no longer tells the user when the engine moved their take. \
            Relocating someone's work silently is the same class of bug as hiding it.
            """)
    }
}
