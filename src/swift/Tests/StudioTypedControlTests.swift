import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// TYPED NUMERIC ENTRY, tested from the gesture end.
//
// Every numeric control in the mixer, the routing/FX pane and the instrument
// panel was drag-only: 0 `TextField`s across the four surfaces, 2 `Stepper`s in
// the whole Studio, and 38 `FX_PARAM_KEYS` + 10 `DEVICE_PARAM_KEYS` behind a
// 30 pt circle. This lane put an editable number and up/down arrows on the three
// shared primitives. These tests exist to make sure that is a working control
// and not another one that compiles, appears and does nothing — the class of
// defect this codebase has shipped repeatedly (a meter that was `abs(sin(t))`, a
// piano roll wired to a mock, a palette listing 71 commands and wiring 11).
//
// So nothing here asserts that a SwiftUI `@State` changed. Every wiring test
// builds the REAL view — `StudioMixerStrip`, `StudioMasterStrip`,
// `StudioFxEditor`, `StudioSendRow`, `StudioRoutingPane`,
// `StudioSynthToneEditor` — asks it for the control it draws, drives that
// control's typed field, and then asserts against the ENGINE'S JOURNAL: the
// commands the bus actually accepted, and that undo puts the value back. The
// mock engine applies real inverses, so a no-op cannot pass.
//
// Hops traversed: view -> the control it builds -> `StudioTypedValueField`
// -> `StudioTypedEntry.outcome` (parse + clamp) -> the view model / routing
// controller -> `StudioEngineProtocol.send` -> apply + inverse + undo.
// Hops SKIPPED, stated plainly: the FFI boundary, and the pixels — no test here
// can tell you whether the field is big enough to hit from a sofa.

// MARK: - 1. The parser and the stepping rules, on their own

@MainActor
final class StudioTypedValueMathTests: XCTestCase {

    /// THE round-trip requirement, and the reason `format:` is passed into the
    /// field rather than duplicated: the field is seeded with exactly what the
    /// control prints, so every string any formatter in the product produces
    /// has to read back to the number it came from. A control whose own display
    /// is not valid input is a control you cannot retype.
    func testParsingReadsBackEveryStringTheControlsPrint() {
        // Pan: "C" / "L40" / "R40" (StudioMixerStrip.panLabel)
        XCTAssertEqual(try XCTUnwrap(StudioParamUnit.pan.parse("C", in: -1...1)), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(StudioParamUnit.pan.parse("L40", in: -1...1)), -0.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(StudioParamUnit.pan.parse("R40", in: -1...1)), 0.4, accuracy: 1e-9)

        // Sends: "45%" (StudioMixerStrip.pctLabel)
        XCTAssertEqual(try XCTUnwrap(StudioParamUnit.percent.parse("45%", in: 0...1)), 0.45, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(StudioParamUnit.percent.parse("45", in: 0...1)), 0.45, accuracy: 1e-9)

        // dB, in all four spellings the product prints or a person types.
        for (text, expected) in [("-6.0 dB", -6.0), ("+3.5 dB", 3.5), ("-1.0", -1.0), ("12", 12.0)] {
            XCTAssertEqual(try XCTUnwrap(StudioParamUnit.decibels.parse(text, in: -60...12)),
                           expected, accuracy: 1e-9, "\"\(text)\"")
        }
        // The send level's own word for zero. This is the value a user is most
        // likely to want to retype and the only one printed as letters.
        XCTAssertEqual(try XCTUnwrap(StudioParamUnit.decibels.parse("-inf", in: -60...12)),
                       -60, accuracy: 1e-9)

        // Frequency, including the shorthand the ask named explicitly ("2.5 kHz").
        for (text, expected) in [("2500 Hz", 2500.0), ("2500", 2500.0),
                                 ("2.5k", 2500.0), ("2.5 kHz", 2500.0)] {
            XCTAssertEqual(try XCTUnwrap(StudioParamUnit.hertz.parse(text, in: 20...20_000)),
                           expected, accuracy: 1e-9, "\"\(text)\"")
        }

        // Times. The delay prints ms; the instrument envelope prints seconds;
        // both accept the other, because "50 ms" and "0.05 s" are one thought.
        XCTAssertEqual(try XCTUnwrap(StudioParamUnit.milliseconds.parse("375 ms", in: 1...2000)),
                       375, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(StudioParamUnit.milliseconds.parse("0.5 s", in: 1...2000)),
                       500, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(StudioParamUnit.seconds.parse("0.005 s", in: 0...2)),
                       0.005, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(StudioParamUnit.seconds.parse("5 ms", in: 0...2)),
                       0.005, accuracy: 1e-12)

        // The compressor's ratio prints "4.0 :1".
        XCTAssertEqual(try XCTUnwrap(StudioParamUnit.ratio.parse("4.0 :1", in: 1...20)),
                       4, accuracy: 1e-9)
    }

    /// Clamping is VISIBLE, not silent. `.clamped` is a distinct outcome from
    /// `.accepted` precisely so the field can put the pulled-back number on
    /// screen — and so a mutation that makes the clamp return its input fails
    /// here with a wrong VALUE rather than a wrong case only.
    func testOutOfRangeTypedValuesAreClampedAndReportedAsClamped() {
        let fader = -60.0...12.0
        XCTAssertEqual(
            StudioTypedEntry.outcome(text: "999", unit: .decibels, range: fader,
                                     current: 0, format: StudioFaderControl.dbLabel),
            .clamped(12),
            "a number above the fader's top must land at +12 dB, and say that it was pulled back")
        XCTAssertEqual(
            StudioTypedEntry.outcome(text: "-500", unit: .decibels, range: fader,
                                     current: 0, format: StudioFaderControl.dbLabel),
            .clamped(-60))

        // An IN-range value is `.accepted`, not `.clamped` — otherwise the two
        // cases would be indistinguishable and the clamp untestable.
        XCTAssertEqual(
            StudioTypedEntry.outcome(text: "-6", unit: .decibels, range: fader,
                                     current: 0, format: StudioFaderControl.dbLabel),
            .accepted(-6))

        // Pan, where the display domain (percent) is not the value domain.
        XCTAssertEqual(
            StudioTypedEntry.outcome(text: "R400", unit: .pan, range: -1...1,
                                     current: 0, format: StudioMixerStrip.panLabel),
            .clamped(1))
    }

    /// Rubbish REVERTS. It is never read as zero, and it never sends.
    func testRubbishIsRejectedAndSendsNothing() {
        for text in ["", "   ", "abc", "12abc", "--", ".", "dB", "L", "l-", "1.2.3"] {
            let outcome = StudioTypedEntry.outcome(
                text: text, unit: .decibels, range: -60...12,
                current: -6, format: StudioFaderControl.dbLabel)
            XCTAssertEqual(outcome, .rejected, "\"\(text)\" was read as a number")
            XCTAssertNil(outcome.committedValue, "\"\(text)\" would have sent a command")
            XCTAssertNil(outcome.displayValue,
                         "\"\(text)\" must put the PREVIOUS value back, visibly")
        }
    }

    /// One arrow press, per kind, against hardcoded numbers rather than against
    /// the constant under test. `XCTAssertEqual(step, unit.step(...))` would
    /// pass for every value including zero, which is the shape of assertion
    /// that let a zero-width note ship in this repo today.
    func testArrowStepsAreTheRightSizeForEachKind() {
        // 1 dB for gains.
        XCTAssertEqual(StudioParamUnit.decibels.stepped(-6, by: 1, in: -60...12), -5, accuracy: 1e-9)
        XCTAssertEqual(StudioParamUnit.decibels.stepped(-6, by: -1, in: -60...12), -7, accuracy: 1e-9)
        // 0.1 for ratios and Q.
        XCTAssertEqual(StudioParamUnit.ratio.stepped(4, by: 1, in: 1...20), 4.1, accuracy: 1e-9)
        XCTAssertEqual(StudioParamUnit.plain.stepped(0.7, by: 1, in: 0.05...10), 0.8, accuracy: 1e-9)
        // 1 percentage point on a 0...1 send.
        XCTAssertEqual(StudioParamUnit.percent.stepped(0.45, by: 1, in: 0...1), 0.46, accuracy: 1e-9)
        // 5 points of pan.
        XCTAssertEqual(StudioParamUnit.pan.stepped(0, by: -1, in: -1...1), -0.05, accuracy: 1e-9)
        // ms, scaled by the parameter's own range: 10 ms on the delay's 1...2000,
        // 1 ms on an attack's 0...200, a tenth on the chorus's 0...9.
        XCTAssertEqual(StudioParamUnit.milliseconds.stepped(375, by: 1, in: 1...2000), 380, accuracy: 1e-9)
        XCTAssertEqual(StudioParamUnit.milliseconds.stepped(10, by: 1, in: 0...200), 11, accuracy: 1e-9)
        XCTAssertEqual(StudioParamUnit.milliseconds.stepped(3, by: 1, in: 0...9), 3.1, accuracy: 1e-9)
        // 10 ms on a seconds-denominated envelope.
        XCTAssertEqual(StudioParamUnit.seconds.stepped(0.2, by: -1, in: 0...4), 0.19, accuracy: 1e-9)
        // Grid snapping: an arbitrary value left by a drag walks to round
        // numbers rather than carrying its remainder forever.
        XCTAssertEqual(StudioParamUnit.decibels.stepped(-6.37, by: 1, in: -60...12), -6, accuracy: 1e-9)
        // And the range is the ceiling.
        XCTAssertEqual(StudioParamUnit.decibels.stepped(12, by: 1, in: -60...12), 12, accuracy: 1e-9)
    }

    /// Frequency does NOT step by 1 Hz. A semitone is the smallest musically
    /// meaningful move and it is the same size at 20 Hz and at 10 kHz, which is
    /// the whole reason `.hertz` is a kind rather than a suffix.
    func testFrequencyArrowsMoveBySemitoneAndNeverStall() {
        let range = 20.0...20_000.0
        // 2500 Hz up a semitone is 2648.5, shown to the nearest 10 Hz.
        XCTAssertEqual(StudioParamUnit.hertz.stepped(2500, by: 1, in: range), 2650, accuracy: 0.5)
        XCTAssertEqual(StudioParamUnit.hertz.stepped(2500, by: -1, in: range), 2360, accuracy: 0.5)
        // An octave is twelve presses, to within the rounding at each step.
        var f = 440.0
        for _ in 0..<12 { f = StudioParamUnit.hertz.stepped(f, by: 1, in: range) }
        XCTAssertEqual(f, 880, accuracy: 6, "twelve presses must be about an octave, got \(f)")

        // No stall anywhere, including the sub-Hz end of a chorus rate and the
        // very bottom and top of the audio range. An arrow that visibly does
        // nothing reads as a broken control.
        // The range is deliberately wider than every value tested, so a stop at
        // the range's own edge cannot be mistaken for a stall.
        let wide = 0.001...25_000.0
        for start in [0.01, 0.8, 20.0, 100.0, 999.0, 1000.0, 19_999.0] {
            let up = StudioParamUnit.hertz.stepped(start, by: 1, in: wide)
            XCTAssertGreaterThan(up, start, "up-arrow stalled at \(start)")
            let down = StudioParamUnit.hertz.stepped(start, by: -1, in: wide)
            XCTAssertLessThan(down, start, "down-arrow stalled at \(start)")
        }
    }

    /// Walks the REAL parameter tables — all 38 `FX_PARAM_KEYS` — so a new DSP
    /// row cannot arrive with an arrow that does nothing or one that jumps the
    /// whole range. Both are controls that look wired and are not.
    func testEveryFxParameterGetsAnArrowThatActuallyMoves() {
        for kind in StudioFxKind.allCases {
            for spec in kind.params where !spec.isSwitch {
                let range = spec.minValue...spec.maxValue
                let start = spec.defaultValue
                let up = spec.paramUnit.stepped(start, by: 1, in: range)
                let down = spec.paramUnit.stepped(start, by: -1, in: range)
                let name = "\(kind.label).\(spec.key)"

                if start < spec.maxValue {
                    XCTAssertGreaterThan(up, start, "\(name): the up arrow does nothing")
                }
                if start > spec.minValue {
                    XCTAssertLessThan(down, start, "\(name): the down arrow does nothing")
                }
                let travel = spec.maxValue - spec.minValue
                XCTAssertLessThanOrEqual(
                    abs(up - start), travel / 4,
                    "\(name): one arrow press moves more than a quarter of the range")
                XCTAssertTrue(range.contains(up) && range.contains(down),
                              "\(name): an arrow left the parameter's range")
            }
        }
    }
}

// MARK: - 2. The field itself: one gesture, one command

@MainActor
final class StudioTypedFieldTests: XCTestCase {

    /// A field wired to a recorder, so "did this send, and what" is a count and
    /// a list rather than an inference from state.
    private final class Recorder {
        var sent: [Double] = []
    }

    private func field(value: Double,
                       unit: StudioParamUnit = .decibels,
                       range: ClosedRange<Double> = -60...12,
                       into recorder: Recorder) -> StudioTypedValueField {
        StudioTypedValueField(
            value: value, range: range, unit: unit,
            format: StudioFaderControl.dbLabel, label: "Fader",
            onCommit: { recorder.sent.append($0) })
    }

    func testTypingAValueCommitsExactlyOnce() {
        let r = Recorder()
        let outcome = field(value: 0, into: r).submit("-6.0 dB")
        XCTAssertEqual(outcome, .accepted(-6))
        XCTAssertEqual(r.sent, [-6],
                       "a typed edit must be ONE command — not one per keystroke, not none")
    }

    /// Return, then clicking away, is one user gesture. The blur commit is
    /// deliberately unconditional (a typed number must not be thrown away by
    /// clicking elsewhere), so the "same value sends nothing" rule is what
    /// keeps it to one journal entry — and therefore one Cmd-Z.
    func testReturnThenBlurIsOneCommandNotTwo() {
        let r = Recorder()
        let f = field(value: -6, into: r)
        _ = f.submit("-12")                     // Return
        XCTAssertEqual(r.sent, [-12])
        // The field has re-seeded from the engine value it just asked for.
        let second = field(value: -12, into: r).submit("-12.0 dB")   // blur
        XCTAssertEqual(second, .unchanged(-12))
        XCTAssertEqual(r.sent, [-12], "the blur added a second command for the same value")
    }

    func testTypingRubbishCommitsNothingAndKeepsThePreviousValue() {
        let r = Recorder()
        let outcome = field(value: -6, into: r).submit("loud")
        XCTAssertEqual(outcome, .rejected)
        XCTAssertTrue(r.sent.isEmpty, "rubbish reached the command bus")
        XCTAssertNil(outcome.displayValue, "the field would have shown something other than -6")
    }

    func testTypingOutOfRangeCommitsTheClampedValueAndShowsIt() {
        let r = Recorder()
        let outcome = field(value: 0, into: r).submit("999")
        XCTAssertEqual(outcome, .clamped(12))
        XCTAssertEqual(r.sent, [12], "the engine must receive the clamped number, not 999")
        XCTAssertEqual(outcome.displayValue, 12, "the field must SHOW where the number landed")
    }

    func testArrowButtonsCommitTheSteppedValue() {
        let r = Recorder()
        XCTAssertEqual(field(value: -6, into: r).nudge(1), -5, accuracy: 1e-9)
        XCTAssertEqual(r.sent, [-5])
        XCTAssertEqual(field(value: -5, into: r).nudge(-1), -6, accuracy: 1e-9)
        XCTAssertEqual(r.sent, [-5, -6], "each arrow press is its own command, and its own undo step")
    }

    /// THE "shown clamped" half of the requirement, which is about the TEXT and
    /// not about the outcome enum. Found by a mutation that survived: the
    /// commit, the clamp and the command were all proven, and the field could
    /// still have gone on displaying the number the engine refused.
    func testTheFieldShowsWhereAClampedNumberLanded() {
        let r = Recorder()
        let f = field(value: 0, into: r)
        let outcome = f.submit("999")
        XCTAssertEqual(
            StudioTypedValueField.displayText(after: outcome, previous: 0,
                                              format: StudioFaderControl.dbLabel),
            "12.0 dB",
            "the field must READ the clamped value; showing 999 would be a silent refusal")
    }

    /// And the reverting half: after rubbish the field reads the PREVIOUS
    /// value, not an empty box and not "0.0 dB".
    func testTheFieldPutsThePreviousValueBackAfterRubbish() {
        let r = Recorder()
        let outcome = field(value: -6, into: r).submit("loud")
        XCTAssertEqual(
            StudioTypedValueField.displayText(after: outcome, previous: -6,
                                              format: StudioFaderControl.dbLabel),
            "-6.0 dB")
        XCTAssertNotEqual(
            StudioTypedValueField.displayText(after: outcome, previous: -6,
                                              format: StudioFaderControl.dbLabel),
            "0.0 dB",
            "rubbish must never be read as zero")
    }

    /// An arrow at the end of the range sends NOTHING rather than a no-op
    /// command, so holding it at the top does not fill the undo stack.
    func testAnArrowAtTheEndOfTheRangeSendsNothing() {
        let r = Recorder()
        XCTAssertEqual(field(value: 12, into: r).nudge(1), 12, accuracy: 1e-9)
        XCTAssertTrue(r.sent.isEmpty)
    }
}

// MARK: - 3. Through the real views, into the real journal

@MainActor
final class StudioTypedControlWiringTests: XCTestCase {

    // MARK: Fixtures

    private func bootedModel() async throws -> (StudioViewModel, StudioMockEngine) {
        let engine = StudioMockEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        for _ in 0..<120 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        _ = try XCTUnwrap(model.snapshot?.tracks.first, "the preview engine never published a track")
        return (model, engine)
    }

    /// Wait for the view model's fire-and-forget `Task { await engine.send(...) }`
    /// to land, then for the poll to adopt the result.
    private func settle(_ model: StudioViewModel, _ engine: StudioMockEngine,
                        untilJournalReaches target: Int) async {
        for _ in 0..<160 {
            if await engine.journal.count >= target { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if model.snapshot != nil { break }
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private func names(_ engine: StudioMockEngine, after mark: Int) async -> [String] {
        await engine.journal.dropFirst(mark).map(\.catalogName)
    }

    private func track(_ model: StudioViewModel) throws -> StudioTrackSnapshot {
        try XCTUnwrap(model.snapshot?.tracks.first)
    }

    // MARK: The mixer strip

    /// THE headline assertion for the mixer: typing into the pan field of the
    /// REAL channel strip puts one `mix.pan` on the bus with the value the
    /// user's notation meant, and one undo takes it back.
    func testTypingIntoTheMixerPanKnobIsOneJournaledCommandAndUndoReverses() async throws {
        let (model, engine) = try await bootedModel()
        defer { model.stopPolling() }
        let t = try track(model)
        let mark = await engine.journal.count

        let strip = StudioMixerStrip(model: model, track: t)
        let outcome = strip.panKnob.typedField().submit("L40")
        XCTAssertEqual(outcome, .accepted(-0.4),
                       "\"L40\" is 40% to the left, which is -0.4 on the wire")
        await settle(model, engine, untilJournalReaches: mark + 1)

        let panLog = await names(engine, after: mark)
        XCTAssertEqual(panLog, ["mix.pan"],
                       "one typed edit must be exactly one journaled command")
        XCTAssertEqual(
            try XCTUnwrap(model.snapshot?.tracks.first(where: { $0.id == t.id })?.pan),
            -0.4, accuracy: 1e-9,
            "the pan field is decoration: the value never reached the engine")

        let undone = await engine.undo()
        XCTAssertTrue(undone, "there was one unit to undo")
        let afterSnapshot = await engine.snapshot(ifNewerThan: nil)
        let after = try XCTUnwrap(afterSnapshot)
        XCTAssertEqual(
            try XCTUnwrap(after.tracks.first(where: { $0.id == t.id })?.pan),
            t.pan, accuracy: 1e-9, "one Cmd-Z must put the previous pan back")
    }

    /// The sends print percentages and the wire carries 0…1. Typing "45%" has
    /// to arrive as 0.45 — a field that wrote 45 would be silently 100x wrong
    /// and would look, on screen, exactly like a field that worked.
    func testTypingAPercentIntoASendArrivesAsAFraction() async throws {
        let (model, engine) = try await bootedModel()
        defer { model.stopPolling() }
        let t = try track(model)
        let mark = await engine.journal.count

        let strip = StudioMixerStrip(model: model, track: t)
        XCTAssertEqual(strip.sendKnob(.a).typedField().submit("45%"), .accepted(0.45))
        await settle(model, engine, untilJournalReaches: mark + 1)

        let sendLog = await names(engine, after: mark)
        XCTAssertEqual(sendLog, ["mix.send"])
        XCTAssertEqual(
            try XCTUnwrap(model.snapshot?.tracks.first(where: { $0.id == t.id })?.sendA),
            0.45, accuracy: 1e-9)
    }

    func testTypingIntoTheTrackFaderReachesTheBusAndUndoReverses() async throws {
        let (model, engine) = try await bootedModel()
        defer { model.stopPolling() }
        let t = try track(model)
        let mark = await engine.journal.count

        let strip = StudioMixerStrip(model: model, track: t)
        XCTAssertEqual(strip.gainFader.typedField().submit("-6.0 dB"), .accepted(-6))
        await settle(model, engine, untilJournalReaches: mark + 1)

        let gainLog = await names(engine, after: mark)
        XCTAssertEqual(gainLog, ["mix.gain"])
        XCTAssertEqual(
            try XCTUnwrap(model.snapshot?.tracks.first(where: { $0.id == t.id })?.volumeDB),
            -6, accuracy: 1e-9)

        let undoneGain = await engine.undo()
        XCTAssertTrue(undoneGain)
        let afterSnapshot = await engine.snapshot(ifNewerThan: nil)
        let after = try XCTUnwrap(afterSnapshot)
        XCTAssertEqual(
            try XCTUnwrap(after.tracks.first(where: { $0.id == t.id })?.volumeDB),
            t.volumeDB, accuracy: 1e-9)
    }

    /// The limiter ceiling is the sharpest case for typing in the whole mixer —
    /// "-1 dBTP" is a number an encoder demands, not something a person finds
    /// by dragging. Typed out of range, it must land clamped IN THE ENGINE.
    func testTypingOutOfRangeIntoTheMasterCeilingLandsClampedInTheEngine() async throws {
        let (model, engine) = try await bootedModel()
        defer { model.stopPolling() }
        let master = try XCTUnwrap(model.snapshot?.master)
        let mark = await engine.journal.count

        let strip = StudioMasterStrip(model: model, master: master)
        // The knob's range is -6...0 dBTP; +6 is above it.
        XCTAssertEqual(strip.ceilingKnob.typedField().submit("6"), .clamped(0))
        await settle(model, engine, untilJournalReaches: mark + 1)

        let ceilLog = await names(engine, after: mark)
        XCTAssertEqual(ceilLog, ["mix.limiter.set"])
        XCTAssertEqual(try XCTUnwrap(model.snapshot?.master.limiterCeilingDBTP), 0, accuracy: 1e-9,
                       "an out-of-range ceiling must arrive clamped, never dropped and never as typed")
    }

    func testArrowOnTheMasterReleaseIsOneJournaledCommand() async throws {
        let (model, engine) = try await bootedModel()
        defer { model.stopPolling() }
        let master = try XCTUnwrap(model.snapshot?.master)
        let mark = await engine.journal.count

        let strip = StudioMasterStrip(model: model, master: master)
        // 50 ms default, a 1...1000 ms range: one press is 10 ms.
        XCTAssertEqual(strip.releaseKnob.typedField().nudge(1), 60, accuracy: 1e-9)
        await settle(model, engine, untilJournalReaches: mark + 1)

        let relLog = await names(engine, after: mark)
        XCTAssertEqual(relLog, ["mix.limiter.set"])
        XCTAssertEqual(try XCTUnwrap(model.snapshot?.master.limiterReleaseMs), 60, accuracy: 1e-9)
    }

    // MARK: The routing / FX pane

    private func loadedController() async -> StudioRoutingController {
        let engine = StudioMockEngine()
        let c = StudioRoutingController(engine: engine)
        await c.attach()
        return c
    }

    /// The ask, literally: "nobody dials an EQ to 2.5 kHz by dragging". This
    /// types it, into the real FX editor, and checks the engine got 2500.
    func testTypingTwoPointFiveKilohertzIntoTheEqReachesTheEngineAsHertz() async throws {
        let c = await loadedController()
        let engine = try XCTUnwrap(c.engine as? StudioMockEngine)
        _ = c.addFx(to: .master, kind: .eq)
        await c.settle()
        let fx = try XCTUnwrap(c.state.masterFx.first)
        c.selectedFxID = fx.id
        let mark = await engine.journal.count

        let editor = StudioFxEditor(controller: c, fx: fx)
        // band0Freq, whose DSP default is 80 Hz — deliberately not band2Freq,
        // whose default IS 2500, which would make a broken commit and a correct
        // one look identical.
        let spec = try XCTUnwrap(StudioFxKind.eq.spec(for: "band0Freq"))
        XCTAssertEqual(editor.paramKnob(spec).typedField().submit("2.5k"), .accepted(2500))
        await c.settle()

        let eqLog = await engine.journal.dropFirst(mark).map(\.catalogName)
        XCTAssertEqual(eqLog, ["fx.param.set"],
                       "one typed edit must be exactly one journaled command")
        let stored = try XCTUnwrap(c.state.fx(on: .master, id: fx.id))
        XCTAssertEqual(stored.value(for: "band0Freq"), 2500, accuracy: 1e-9)

        _ = await engine.undo()
        await c.reload()
        let restored = try XCTUnwrap(c.state.fx(on: .master, id: fx.id))
        XCTAssertFalse(restored.isSet("band0Freq"),
                       "undo must return the key to ABSENT — sparsity is what makes an unset key mean the DSP default")
    }

    /// Every one of the 38 `FX_PARAM_KEYS`, through the real editor's real
    /// knob, typed in the notation the control itself prints.
    ///
    /// The assertion is a ROUND TRIP rather than a comparison against the
    /// parser: what the effect now displays must be exactly what was typed. A
    /// dropped commit, a clamp that ate the value, or a unit read wrongly all
    /// fail it; nothing about it can pass by construction.
    func testTypingIntoEveryFxParameterReachesTheBus() async throws {
        for kind in StudioFxKind.allCases {
            let c = await loadedController()
            let engine = try XCTUnwrap(c.engine as? StudioMockEngine)
            _ = c.addFx(to: .master, kind: kind)
            await c.settle()
            let fx = try XCTUnwrap(c.state.masterFx.first)
            c.selectedFxID = fx.id

            for spec in kind.params where !spec.isSwitch {
                let target = min(spec.maxValue,
                                 max(spec.minValue,
                                     spec.defaultValue + (spec.maxValue - spec.minValue) * 0.3))
                let text = spec.format(target)
                let name = "\(kind.label).\(spec.key)"
                let mark = await engine.journal.count

                let editor = StudioFxEditor(controller: c, fx: try XCTUnwrap(c.state.fx(on: .master, id: fx.id)))
                let outcome = editor.paramKnob(spec).typedField().submit(text)
                XCTAssertNotEqual(outcome, .rejected,
                                  "\(name): the control prints \"\(text)\" and will not read it back")
                await c.settle()

                let after = await engine.journal.dropFirst(mark).map(\.catalogName)
                guard outcome != .unchanged(target) else { continue }
                XCTAssertEqual(after, ["fx.param.set"], "\(name): typing did not reach the bus")

                let stored = try XCTUnwrap(c.state.fx(on: .master, id: fx.id))
                XCTAssertEqual(
                    spec.format(stored.value(for: spec.key)), text,
                    "\(name): typed \"\(text)\", the effect now shows \"\(spec.format(stored.value(for: spec.key)))\"")
            }
        }
    }

    func testTypingIntoTheBusFaderIsOneCommandAndUndoRestoresThePriorGain() async throws {
        let c = await loadedController()
        let engine = try XCTUnwrap(c.engine as? StudioMockEngine)
        let busID = try XCTUnwrap(c.addBus(kind: .bus, name: "Drum Bus"))
        await c.settle()
        c.focus = .bus(busID)
        let mark = await engine.journal.count

        let pane = StudioRoutingPane(controller: c)
        XCTAssertEqual(pane.busFaderKnob(busID).typedField().submit("-6.5 dB"), .accepted(-6.5))
        await c.settle()

        let busLog = await engine.journal.dropFirst(mark).map(\.catalogName)
        XCTAssertEqual(busLog, ["route.node.set"])
        XCTAssertEqual(c.state.node(busID)?.gainDB ?? .nan, -6.5, accuracy: 1e-9)

        _ = await engine.undo()
        await c.reload()
        XCTAssertEqual(c.state.node(busID)?.gainDB ?? .nan, 0, accuracy: 1e-9,
                       "undo must restore the prior gain")
    }

    /// The send level prints "-inf" at zero. Typing that word back must reach
    /// the engine as a level of zero, not be rejected as rubbish.
    func testTypingMinusInfIntoASendLevelSilencesTheConnection() async throws {
        let c = await loadedController()
        let engine = try XCTUnwrap(c.engine as? StudioMockEngine)
        let track = try XCTUnwrap(c.tracks.first?.ref)
        let busID = try XCTUnwrap(c.addBus(kind: .bus, name: "Verb"))
        await c.settle()
        _ = try XCTUnwrap(c.connect(from: track, to: .bus(busID)))
        await c.settle()
        let edge = try XCTUnwrap(c.state.outgoing(from: track).first)
        let mark = await engine.journal.count

        let row = StudioSendRow(controller: c, edge: edge)
        XCTAssertEqual(row.levelKnob.typedField().submit("-inf"), .accepted(-60))
        await c.settle()

        let edgeLog = await engine.journal.dropFirst(mark).map(\.catalogName)
        XCTAssertEqual(edgeLog, ["route.edge.set"])
        let updated = try XCTUnwrap(c.state.outgoing(from: track).first)
        XCTAssertEqual(updated.level, 0, accuracy: 1e-9,
                       "\"-inf\" is what this control prints for silence; it has to read back as silence")
    }

    // MARK: The instrument panel

    /// `device.param.set` — the verb that, until very recently, no control in
    /// the app could send at all. Typing a brightness reaches it, and one
    /// Cmd-Z returns the key to ABSENT (the DSP default), not to a written zero.
    func testTypingIntoAnInstrumentControlIsOneDeviceParamSetAndUndoReverses() async throws {
        let engine = StudioMockEngine()
        let model = StudioViewModel(engine: engine)
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Keys", index: 0))
        _ = await engine.send(.deviceAdd(trackID: trackID, deviceID: "inst_typed", kind: "synth"))
        model.startPolling()
        for _ in 0..<160 {
            if model.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first != nil { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        defer { model.stopPolling() }
        let device = try XCTUnwrap(
            model.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        let mark = await engine.journal.count

        let editor = StudioSynthToneEditor(model: model, trackID: trackID, device: device)
        let slider = editor.paramSlider(key: "cutoff", label: "Brightness", range: 200...16000,
                                        helpID: "instrument.tone.cutoff", unit: .hertz,
                                        format: { "\(Int($0)) Hz" })
        XCTAssertEqual(slider.typedField().submit("2.5 kHz"), .accepted(2500))
        for _ in 0..<160 {
            if await engine.journal.count > mark { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)

        let cutoffLog = await engine.journal.dropFirst(mark).map(\.catalogName)
        XCTAssertEqual(cutoffLog, ["device.param.set"],
                       "one typed edit must be one device.param.set")
        XCTAssertEqual(
            model.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first?.params["cutoff"],
            2500)

        let undoneParam = await engine.undo()
        XCTAssertTrue(undoneParam)
        let afterSnapshot = await engine.snapshot(ifNewerThan: nil)
        let after = try XCTUnwrap(afterSnapshot)
        let restored = try XCTUnwrap(after.tracks.first(where: { $0.id == trackID })?.devices.first)
        XCTAssertNil(restored.params["cutoff"],
                     "undo must clear the key to ABSENT, which is what an unset parameter means")
    }

    /// The envelope is denominated in seconds and a person thinks in
    /// milliseconds. Both spellings have to land on the same number.
    func testTypingMillisecondsIntoASecondsDenominatedEnvelopeReachesTheEngine() async throws {
        let engine = StudioMockEngine()
        let model = StudioViewModel(engine: engine)
        let trackID = UUID()
        _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Keys", index: 0))
        _ = await engine.send(.deviceAdd(trackID: trackID, deviceID: "inst_env", kind: "synth"))
        model.startPolling()
        for _ in 0..<160 {
            if model.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first != nil { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        defer { model.stopPolling() }
        let device = try XCTUnwrap(
            model.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        let mark = await engine.journal.count

        let editor = StudioSynthToneEditor(model: model, trackID: trackID, device: device)
        let stage = try XCTUnwrap(StudioInstrumentTone.envelope.first { $0.id == "attack" })
        let slider = editor.paramSlider(key: stage.id, label: stage.label, range: stage.range,
                                        helpID: "instrument.tone.envelope",
                                        unit: StudioParamUnit.forSpecUnit(stage.unit),
                                        format: { String(format: "%.3f %@", $0, stage.unit) })
        XCTAssertEqual(slider.typedField().submit("250 ms"), .accepted(0.25))
        for _ in 0..<160 {
            if await engine.journal.count > mark { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)

        let envLog = await engine.journal.dropFirst(mark).map(\.catalogName)
        XCTAssertEqual(envLog, ["device.param.set"])
        XCTAssertEqual(
            model.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first?.params["attack"],
            0.25)
    }
}

// MARK: - 4. The wiring inside `body`, which no method call can reach

/// `submit(_:)` and `nudge(_:)` are proven above by calling them. What those
/// calls CANNOT see is whether `body` still routes Return, blur and the arrow
/// buttons into them — cut those three lines and every test above stays green
/// while the control goes dead on screen. That is the exact shape of the bug
/// this codebase keeps shipping, so it gets a source scan, the same tool
/// `StudioInstrumentToneTests` uses to pin that the tone panel's controls call
/// a gesture at all.
final class StudioTypedControlWiringSourceTests: XCTestCase {

    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Studio")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    func testTheFieldCommitsOnReturnAndOnBlurAndTheArrowsNudge() throws {
        let s = try Self.source("StudioMixerControls.swift")
        XCTAssertTrue(s.contains(".onSubmit { apply(submit(draft)) }"),
                      "Return no longer commits: the field would accept typing and send nothing")
        XCTAssertTrue(s.contains("if !isFocused { apply(submit(draft)) }"),
                      "clicking away from a typed field would throw the number away")
        XCTAssertTrue(s.contains("Button { _ = nudge(direction) }"),
                      "the arrow buttons are no longer wired to nudge(_:)")
        XCTAssertTrue(s.contains("if let v = outcome.committedValue { onCommit(v) }"),
                      "submit(_:) no longer reaches onCommit, so nothing a user types is sent")
        // The three lines that put the RESULT on screen. Each was a surviving
        // mutation before it was pinned here: the commit can be perfect and the
        // field still show a number the engine refused, or show nothing at all.
        XCTAssertTrue(s.contains("draft = Self.displayText(after: outcome, previous: value, format: format)"),
                      "the field no longer re-reads after a commit, so a clamp is invisible and rubbish looks accepted")
        XCTAssertTrue(s.contains(".onAppear { draft = format(value) }"),
                      "the field is no longer seeded, so every number in the Studio starts blank")
        XCTAssertTrue(s.contains("if !focused { draft = format(v) }"),
                      "the field no longer follows engine truth, so a drag, an agent or an undo would leave it stale")
    }

    /// All three numeric primitives draw the SHARED field. A primitive that
    /// grew its own text entry would drift — a different parser, a different
    /// clamp, a different idea of one arrow press — which is the whole reason
    /// this was built once rather than fifty times.
    func testTheNumericPrimitivesDrawTheSharedField() throws {
        let controls = try Self.source("StudioMixerControls.swift")
        // StudioKnob and StudioFaderControl each build one, and each body draws it.
        XCTAssertEqual(controls.components(separatedBy: "func typedField() -> StudioTypedValueField").count - 1, 2,
                       "StudioKnob and StudioFaderControl must each expose the field they draw")
        XCTAssertEqual(controls.components(separatedBy: "typedField()\n").count - 1, 2,
                       "a primitive stopped DRAWING its typed field, so the number went back to being read-only")

        let instrument = try Self.source("StudioInstrumentView.swift")
        XCTAssertTrue(instrument.contains("func typedField() -> StudioTypedValueField"))
        XCTAssertTrue(instrument.contains("typedField()"),
                      "StudioParamSlider stopped drawing its typed field")
        XCTAssertFalse(instrument.contains("TextField("),
                       "the instrument panel grew its own text entry instead of using the shared one")
        let routing = try Self.source("StudioRoutingView.swift")
        XCTAssertFalse(routing.contains("TextField("),
                       "the routing pane grew its own text entry instead of using the shared one")
    }

    /// Every knob in the product states its unit. The compiler already demands
    /// it (`StudioKnob.unit` has no default), so this is a readable statement of
    /// the count rather than a guard — and it fails loudly if a future lane
    /// gives `unit` a default to make a call site compile.
    func testEveryKnobStatesItsUnit() throws {
        let s = try Self.source("StudioMixerControls.swift")
        XCTAssertTrue(s.contains("var unit: StudioParamUnit\n"),
                      "StudioKnob.unit acquired a default, so a new knob can silently get plain-number arrows")
    }
}
