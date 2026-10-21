import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// TYPING A TEMPO, FROM THE KEYSTROKE END.
//
// THE DEFECT THESE TESTS EXIST FOR. The transport's BPM and KEY readouts were
// `TextField("", text: <computed Binding>)` whose SETTER called the command
// bus. A macOS `TextField` writes its binding on every character, so typing
// `130` over `120.0` sent one command per keystroke — and `setTempo` clamps to
// 20…300, so the sequence on the journal was `project.setTempo(20)`,
// `project.setTempo(20)`, `project.setTempo(130)`: three entries, three Cmd-Z
// steps, and two tempi nobody asked for. The binding's GETTER read engine truth
// straight back, so the 30 Hz snapshot poll then replaced the half-typed text
// with `20.0` underneath the caret.
//
// `StudioMixerControls.swift` states the rule this broke, in its own header:
// "the binding NEVER commits — typing 2500 must not send 2, then 25, then 250,
// then 2500". Fifty numeric controls in the mixer, the FX pane and the
// instrument panel obey it through `StudioTypedValueField`. The transport's two
// readouts were the pair that never did.
//
// SO NOTHING HERE ASSERTS THAT A `@State` CHANGED. Every wiring test builds the
// REAL `StudioTransportBar`, asks it for the field it draws, drives the exact
// call the text field makes per character, and then asserts against the mock
// engine's JOURNAL — the commands the bus actually accepted.
//
// Hops traversed: view -> `StudioCommittedReadoutField` ->
// `StudioTransportEntry` -> `StudioTypedEntry.outcome` (parse + clamp) ->
// `StudioViewModel.setTempo` -> `StudioEngineProtocol.send` -> journal.
// Hops SKIPPED, stated plainly: AppKit's own keystroke delivery. No test here
// can prove that macOS calls the binding once per character — that is a
// documented `TextField` behaviour and a human check, not something this
// process can observe. What these tests DO prove is that when it does, nothing
// reaches the bus until the user commits.

@MainActor
final class StudioTransportTypingTests: XCTestCase {

    // MARK: Helpers

    private func settled(_ model: StudioViewModel, timeout: TimeInterval = 3.0,
                         until condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func tempoCommands(_ engine: StudioMockEngine) async -> [Double] {
        await engine.journal.compactMap {
            if case .projectSetTempo(let bpm) = $0 { return bpm }
            return nil
        }
    }

    private func keyCommands(_ engine: StudioMockEngine) async -> [String] {
        await engine.journal.compactMap {
            if case .projectSetKey(let key) = $0 { return key }
            return nil
        }
    }

    /// A live model on the mock engine, with its first snapshot landed.
    private func liveModel() async -> (StudioMockEngine, StudioViewModel) {
        let engine = StudioMockEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        await settled(model) { model.snapshot != nil }
        XCTAssertNotNil(model.snapshot, "the mock engine produced a first snapshot")
        return (engine, model)
    }

    // MARK: - 1. The keystroke path does not reach the bus

    /// THE REGRESSION TEST FOR THE DEFECT ITSELF, driven one character at a
    /// time exactly as a `TextField` binding is.
    ///
    /// It is deliberately written against `textDidChange` rather than against
    /// the draft it writes: `textDidChange` is the ONE thing `body`'s binding
    /// calls, so re-wiring the binding to commit — which is precisely what
    /// shipped — puts the commit back inside the call this test makes, and the
    /// count below goes from 1 to 4.
    func testTypingATempoOneCharacterAtATimePutsNothingOnTheBusUntilItIsCommitted() async {
        let (engine, model) = await liveModel()
        defer { model.stopPolling() }
        let field = StudioTransportBar(model: model).tempoField

        for keystroke in ["1", "13", "130"] {
            field.textDidChange(keystroke)
        }
        // A beat for anything the keystrokes might have posted to reach the bus.
        try? await Task.sleep(nanoseconds: 120_000_000)
        let duringTyping = await tempoCommands(engine)
        XCTAssertEqual(
            duringTyping, [],
            """
            typing put \(duringTyping) on the journal. A keystroke is not a \
            gesture: only Return or losing focus may reach the bus.
            """)

        field.submit("130")
        await settled(model) { model.snapshot?.tempoBPM == 130 }

        let afterCommit = await tempoCommands(engine)
        XCTAssertEqual(
            afterCommit, [130],
            "committing a typed tempo is exactly one journaled command")
        XCTAssertEqual(try XCTUnwrap(model.snapshot?.tempoBPM), 130, accuracy: 1e-9)
    }

    /// The same for KEY, which had the identical shape and the worse spelling
    /// of it: `setKey` does not clamp, so typing "Em" over "C" wrote a project
    /// key of "E" and then "Em" — the first of which is a different key.
    func testTypingAKeyOneCharacterAtATimePutsNothingOnTheBusUntilItIsCommitted() async {
        let (engine, model) = await liveModel()
        defer { model.stopPolling() }
        let field = StudioTransportBar(model: model).keyField

        for keystroke in ["E", "Em"] {
            field.textDidChange(keystroke)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        let duringTyping = await keyCommands(engine)
        XCTAssertEqual(duringTyping, [], "typing a key must not reach the bus")

        field.submit("Em")
        await settled(model) { model.snapshot?.key == "Em" }

        let afterCommit = await keyCommands(engine)
        XCTAssertEqual(afterCommit, ["Em"],
                       "committing a typed key is exactly one journaled command")
        XCTAssertEqual(model.snapshot?.key, "Em")
    }

    // MARK: - 2. What a commit does, and what it refuses to do

    /// Click in, click out, change nothing: NOT a journal entry. This is the
    /// property that makes "Return then blur" one command rather than two, and
    /// it is the one a naive `!= current` check gets wrong — the field prints
    /// `120.0` over an engine value of `120.0`, and comparing raw doubles after
    /// a parse of the field's own text would send a command every time.
    func testCommittingTheTextTheFieldAlreadyShowsSendsNothing() async {
        let (engine, model) = await liveModel()
        defer { model.stopPolling() }
        let bar = StudioTransportBar(model: model)

        let shownTempo = StudioTransportEntry.tempoText(model.snapshot?.tempoBPM ?? 120)
        bar.tempoField.submit(shownTempo)
        bar.tempoField.submit(shownTempo)   // Return, then blur
        bar.keyField.submit(model.snapshot?.key ?? "-")

        try? await Task.sleep(nanoseconds: 150_000_000)
        let tempoSent = await tempoCommands(engine)
        let keySent = await keyCommands(engine)
        XCTAssertEqual(tempoSent, [], "an unchanged tempo commit is not a command")
        XCTAssertEqual(keySent, [], "an unchanged key commit is not a command")
    }

    /// Out of range is CLAMPED AND SHOWN CLAMPED. The clamp lives in
    /// `StudioViewModel.tempoRangeBPM` and the field reads the same constant,
    /// so the number the engine accepted and the number on screen cannot
    /// disagree — which is what "type 900, watch it snap back to 300" means to
    /// a person.
    func testAnOutOfRangeTempoIsClampedAndTheFieldSaysWhereItLanded() async {
        let (engine, model) = await liveModel()
        defer { model.stopPolling() }
        let field = StudioTransportBar(model: model).tempoField

        let shown = field.submit("900")
        await settled(model) { model.snapshot?.tempoBPM == 300 }

        let sent = await tempoCommands(engine)
        XCTAssertEqual(sent, [300], "one command, at the clamp")
        XCTAssertEqual(shown, "300.0",
                       "the field must read the number the engine accepted, not the one typed")
        XCTAssertEqual(try XCTUnwrap(model.snapshot?.tempoBPM), 300, accuracy: 1e-9)
    }

    /// Rubbish REVERTS, visibly, and sends nothing. Read as zero it would be a
    /// silent 20 BPM (the clamp floor); dropped silently it would look like the
    /// field was dead.
    func testRubbishRevertsAndSendsNothing() async {
        let (engine, model) = await liveModel()
        defer { model.stopPolling() }
        let field = StudioTransportBar(model: model).tempoField
        let before = model.snapshot?.tempoBPM ?? 120

        let shown = field.submit("fast")

        try? await Task.sleep(nanoseconds: 150_000_000)
        let sent = await tempoCommands(engine)
        XCTAssertEqual(sent, [], "\"fast\" is not a tempo")
        XCTAssertEqual(shown, StudioTransportEntry.tempoText(before),
                       "the field puts back what was there")
        XCTAssertEqual(try XCTUnwrap(model.snapshot?.tempoBPM), before, accuracy: 1e-9)
    }

    /// An empty key is not a key. `setKey` already refuses it; the field must
    /// not ask, or clearing the box to retype fires a refusal toast at someone
    /// who is mid-edit.
    func testAnEmptyKeyCommitSendsNothingAndRevertsToEngineTruth() async {
        let (engine, model) = await liveModel()
        defer { model.stopPolling() }
        let field = StudioTransportBar(model: model).keyField
        let before = model.snapshot?.key ?? "-"

        let shown = field.submit("   ")

        try? await Task.sleep(nanoseconds: 150_000_000)
        let sent = await keyCommands(engine)
        XCTAssertEqual(sent, [])
        XCTAssertEqual(shown, before)
    }

    // MARK: - 3. Engine truth must not yank the text out from under the caret

    /// The OTHER half of what shipped. The old binding's getter was engine
    /// truth, so every 30 Hz poll rewrote whatever was half-typed. That is the
    /// "fader fights the hand" bug in a text field, and
    /// `StudioTypedValueField` guards it with the same `focused` test.
    ///
    /// Both branches, with DIFFERENT values, so a mutation that returns one
    /// argument unconditionally fails on the other case rather than passing by
    /// coincidence.
    func testEngineTruthReseedsTheFieldOnlyWhileItIsNotBeingEdited() {
        XCTAssertEqual(
            StudioCommittedReadoutField.reseed(
                draft: "13", engineTruth: "120.0", focused: true),
            "13",
            "a poll must not replace a half-typed value")
        XCTAssertEqual(
            StudioCommittedReadoutField.reseed(
                draft: "13", engineTruth: "120.0", focused: false),
            "120.0",
            "with the caret elsewhere the field shows engine truth")
    }

    // MARK: - 4. The rules themselves, without a view

    func testTheTempoRuleParsesClampsAndReportsUnchanged() {
        XCTAssertEqual(StudioTransportEntry.tempo("130", current: 120).send, 130)
        XCTAssertEqual(StudioTransportEntry.tempo("130", current: 120).display, "130.0")

        XCTAssertEqual(StudioTransportEntry.tempo("900", current: 120).send, 300)
        XCTAssertEqual(StudioTransportEntry.tempo("1", current: 120).send, 20)

        XCTAssertNil(StudioTransportEntry.tempo("120.0", current: 120).send)
        XCTAssertNil(StudioTransportEntry.tempo("120abc", current: 120).send,
                     "a lenient prefix parse turns a typo into a silent write")
        XCTAssertNil(StudioTransportEntry.tempo("", current: 120).send)
    }

    func testTheKeyRuleTrimsAndRefusesEmptyAndUnchanged() {
        XCTAssertEqual(StudioTransportEntry.key("  Em ", current: "C").send, "Em")
        XCTAssertNil(StudioTransportEntry.key("C", current: "C").send)
        XCTAssertNil(StudioTransportEntry.key("", current: "C").send)
        XCTAssertEqual(StudioTransportEntry.key("", current: "C").display, "C")
    }

    /// The clamp the field shows and the clamp the command applies are ONE
    /// constant. Asserted through `setTempo` rather than by reading the range
    /// twice, so a second copy of `20…300` appearing in either place fails
    /// here rather than being discovered by a user typing 900.
    func testTheFieldsClampAndTheCommandsClampAreTheSameNumbers() async {
        let (engine, model) = await liveModel()
        defer { model.stopPolling() }

        model.setTempo(bpm: 10_000)
        model.setTempo(bpm: -5)
        while await tempoCommands(engine).count < 2 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let sent = await tempoCommands(engine)
        XCTAssertEqual(sent, [
            StudioViewModel.tempoRangeBPM.upperBound,
            StudioViewModel.tempoRangeBPM.lowerBound,
        ])
        XCTAssertEqual(StudioTransportEntry.tempo("10000", current: 120).send,
                       StudioViewModel.tempoRangeBPM.upperBound)
        XCTAssertEqual(StudioTransportEntry.tempo("-5", current: 120).send,
                       StudioViewModel.tempoRangeBPM.lowerBound)
    }
}
