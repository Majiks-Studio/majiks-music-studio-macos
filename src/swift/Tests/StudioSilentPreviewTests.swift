import XCTest
@testable import MajiksMusicStudio

// The silent-preview notice.
//
// Two things can rot here and they pull in opposite directions:
//
//  1. SWALLOWING. The reason stops reaching the user and the app is silent
//     about being silent again — the original bug. `testTheEnginesWordsAreCarriedVerbatim`
//     and the real-engine test in StudioPianoRollRealEngineTests are the guards.
//  2. STORMING. Every key press posts a toast, so a chord throws six of them and
//     the app looks broken rather than quiet — which would be a worse outcome
//     than the bug. `testAHeldChordProducesOneMessageNotSix` is the guard.
//
// The rule is a pure function over an explicit clock, so both are asserted by
// calling it rather than by sleeping.

final class StudioSilentPreviewTests: XCTestCase {

    /// The engine's actual sentences, copied here as fixtures. They are the
    /// engine's to change; this file only asserts that whatever it says is
    /// carried through unaltered, so a reword does not fail these tests — it
    /// just changes what the user reads, which is the point.
    private static let noDevice = "the track has no instrument device"
    private static let holdOff =
        "you just undid the instrument that was created for you; lift the keys and play again, "
        + "or add an instrument to a track"

    private func silent(_ reason: String) -> StudioNotePreviewOutcome {
        StudioNotePreviewOutcome(audible: false, reason: reason)
    }

    private var t0: Date { Date(timeIntervalSince1970: 1_000_000) }

    // MARK: - Carrying the reason

    func testTheEnginesWordsAreCarriedVerbatim() {
        var state = StudioSilentPreview.State()
        let message = StudioSilentPreview.notice(
            for: silent(Self.noDevice), gate: .oneShot, state: &state, now: t0)
        let text = try! XCTUnwrap(message)
        XCTAssertTrue(
            text.contains(Self.noDevice),
            "the engine's reason was paraphrased or dropped: \(text)")
    }

    func testTheMessagePointsAtTheWayForward() {
        var state = StudioSilentPreview.State()
        let text = try! XCTUnwrap(StudioSilentPreview.notice(
            for: silent(Self.noDevice), gate: .oneShot, state: &state, now: t0))
        XCTAssertTrue(
            text.contains(StudioSilentPreview.remedy),
            "a silent note that says only WHY leaves the user exactly as stuck: \(text)")
    }

    /// The engine's hold-off reason already ends with "…or add an instrument to
    /// a track". Following that with the app's own differently-worded remedy
    /// reads as two conflicting fixes.
    func testAReasonThatAlreadyNamesARemedyDoesNotGetASecondOne() {
        var state = StudioSilentPreview.State()
        let text = try! XCTUnwrap(StudioSilentPreview.notice(
            for: silent(Self.holdOff), gate: .oneShot, state: &state, now: t0))
        XCTAssertTrue(text.contains(Self.holdOff))
        XCTAssertFalse(
            text.contains(StudioSilentPreview.remedy),
            "two remedies in one sentence: \(text)")
    }

    // MARK: - Nothing to say

    func testAnAudibleNoteSaysNothing() {
        var state = StudioSilentPreview.State()
        XCTAssertNil(StudioSilentPreview.notice(
            for: .audibleNote, gate: .oneShot, state: &state, now: t0))
    }

    /// A call that never reached the engine has no engine sentence, and the app
    /// must not invent one.
    func testAnUnreachableEngineSaysNothingRatherThanGuessing() {
        var state = StudioSilentPreview.State()
        XCTAssertNil(StudioSilentPreview.notice(
            for: .unreachable, gate: .oneShot, state: &state, now: t0))
    }

    func testANoteOffIsNeverReported() {
        var state = StudioSilentPreview.State()
        XCTAssertNil(
            StudioSilentPreview.notice(
                for: silent(Self.noDevice), gate: .off, state: &state, now: t0),
            "a key coming up would double every notice, and the key going down already said it")
    }

    // MARK: - Once, not once per key

    /// THE storm check. Six note-ons inside one gesture, same reason, ~6 ms
    /// apart: one message.
    func testAHeldChordProducesOneMessageNotSix() {
        var state = StudioSilentPreview.State()
        var shown: [String] = []
        for (index, _) in [60, 64, 67, 72, 76, 79].enumerated() {
            let now = t0.addingTimeInterval(Double(index) * 0.006)
            if let text = StudioSilentPreview.notice(
                for: silent(Self.noDevice), gate: .on, state: &state, now: now) {
                shown.append(text)
            }
        }
        XCTAssertEqual(
            shown.count, 1,
            "a six-note chord posted \(shown.count) toasts; a toast storm is worse than the silence it replaces")
    }

    /// Suppression is not permanent. Someone who read the message, tried
    /// something else and came back to a still-silent track gets told again.
    func testTheSameReasonComesBackAfterTheCooldown() {
        var state = StudioSilentPreview.State()
        XCTAssertNotNil(StudioSilentPreview.notice(
            for: silent(Self.noDevice), gate: .on, state: &state, now: t0))
        XCTAssertNil(
            StudioSilentPreview.notice(
                for: silent(Self.noDevice), gate: .on, state: &state,
                now: t0.addingTimeInterval(StudioSilentPreview.repeatSameReasonAfter - 1)),
            "inside the cooldown the same reason must stay quiet")
        XCTAssertNotNil(
            StudioSilentPreview.notice(
                for: silent(Self.noDevice), gate: .on, state: &state,
                now: t0.addingTimeInterval(StudioSilentPreview.repeatSameReasonAfter + 1)),
            "after the cooldown a still-broken track must say so again")
    }

    /// A DIFFERENT reason is new information and is not held for the full
    /// cooldown — but it still must not overwrite a message the user is
    /// mid-way through reading.
    func testADifferentReasonWaitsOnlyForTheOneOnScreenToClear() {
        var state = StudioSilentPreview.State()
        XCTAssertNotNil(StudioSilentPreview.notice(
            for: silent(Self.noDevice), gate: .on, state: &state, now: t0))
        XCTAssertNil(
            StudioSilentPreview.notice(
                for: silent(Self.holdOff), gate: .on, state: &state,
                now: t0.addingTimeInterval(StudioSilentPreview.minimumGap - 1)),
            "the previous toast is still on screen; replacing it mid-read is how a message reads as never shown")
        XCTAssertNotNil(
            StudioSilentPreview.notice(
                for: silent(Self.holdOff), gate: .on, state: &state,
                now: t0.addingTimeInterval(StudioSilentPreview.minimumGap + 0.1)),
            "a new reason must not be held for the SAME-reason cooldown; it is different news")
    }

    /// Fixing the problem must not leave a cooldown armed. Otherwise: add an
    /// instrument, hear it, remove it again, play — and the app is silently
    /// silent for another 20 seconds, which is the original bug wearing a hat.
    func testSoundComingBackClearsTheCooldown() {
        var state = StudioSilentPreview.State()
        XCTAssertNotNil(StudioSilentPreview.notice(
            for: silent(Self.noDevice), gate: .on, state: &state, now: t0))

        _ = StudioSilentPreview.notice(
            for: .audibleNote, gate: .on, state: &state, now: t0.addingTimeInterval(1))

        XCTAssertNotNil(
            StudioSilentPreview.notice(
                for: silent(Self.noDevice), gate: .on, state: &state,
                now: t0.addingTimeInterval(2)),
            "the silence came back and the stale cooldown swallowed the message")
    }

    // MARK: - The two surfaces share one cooldown

    /// The gutter and the on-screen keyboard are one problem, not two. They
    /// share `StudioSilentPreviewReporter.shared`, so the state is shared by
    /// construction — this asserts the reporter is actually stateful rather
    /// than re-deciding from scratch on every call.
    @MainActor
    func testTheReporterRemembersBetweenCalls() {
        let reporter = StudioSilentPreviewReporter.shared
        reporter.resetForTesting()
        ToastManager.shared.currentToast = nil

        reporter.report(silent(Self.noDevice), gate: .on, now: t0)
        let first = ToastManager.shared.currentToast
        XCTAssertNotNil(first, "the first silent note must produce a toast")

        ToastManager.shared.currentToast = nil
        reporter.report(silent(Self.noDevice), gate: .on, now: t0.addingTimeInterval(0.01))
        XCTAssertNil(
            ToastManager.shared.currentToast,
            "the second note of the same chord posted a second toast")

        reporter.resetForTesting()
        ToastManager.shared.currentToast = nil
    }

    /// The refusal is actionable — it names a control the user has to go find —
    /// so it gets the long duration, not the acknowledgement one.
    @MainActor
    func testTheNoticeUsesTheActionableDuration() {
        let reporter = StudioSilentPreviewReporter.shared
        reporter.resetForTesting()
        ToastManager.shared.currentToast = nil

        reporter.report(silent(Self.noDevice), gate: .on, now: t0)
        let toast = try! XCTUnwrap(ToastManager.shared.currentToast)
        XCTAssertEqual(toast.seconds, ToastDuration.actionable)

        reporter.resetForTesting()
        ToastManager.shared.currentToast = nil
    }
}
