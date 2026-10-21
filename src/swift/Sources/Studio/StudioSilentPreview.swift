import Foundation

// MARK: - When a played note makes no sound, say so ONCE
//
// The engine has always answered the audition verb honestly. `preview_note`
// returns `{audible, reason}` and never claims a sound it did not make — there
// is deliberately no `ok` field on it, precisely so a caller cannot read "the
// call succeeded" as "the user heard something".
//
// Swift then threw the answer away. `previewNote` returned a bare `Bool`, every
// call site discarded even that, and so a piano-roll gutter key on a track with
// no instrument device produced: nothing. No sound, no message, no clue. The
// engine had written "the track has no instrument device" and it reached
// nobody. That is the shape of the report this whole run of lanes came from —
// "it went quiet and I couldn't get it back" — and it is a silent-degradation
// bug, not a missing feature: the diagnosis existed, the wire dropped it.
//
// Two rules govern what happens now, and both are here rather than at the call
// sites so they are testable without a view and cannot drift between the two
// surfaces that share the path.
//
// ── 1. The reason is the ENGINE's sentence ──────────────────────────────────
//
// It is carried verbatim, never paraphrased. A second copy of "why is this
// silent" written app-side would be one more thing to drift out of step with
// the engine's actual refusal rules, and this codebase has already paid for
// that once (the Swift copy of "which track do the keys play", deleted in
// RealStudioNoteEngine).
//
// What IS added app-side is the REMEDY, because the remedy is app knowledge the
// engine cannot have: the engine has no idea the track header now carries a
// button labelled "+ Instrument". Appended as its own sentence, never folded
// into the reason.
//
// ── 2. Once, not once per key ───────────────────────────────────────────────
//
// A held six-note chord is six `previewNote` calls in ~30 ms, each with the
// same reason. Six toasts stacking on top of each other would be a worse
// failure than the silence — it would make the app look broken rather than
// merely quiet. So the notice is deduplicated on the reason text with a
// cooldown, and no notice ever replaces one still on screen. See
// `StudioSilentPreview.notice` for the exact rule.

// MARK: - What previewNote actually answered

/// The outcome of auditioning one note.
///
/// `audible` is NOT "the call worked". It is whether a sound was made. `reason`
/// is the engine's own words for why it was not, and is nil exactly when there
/// is nothing to say (it was audible, or the call never reached the engine).
struct StudioNotePreviewOutcome: Sendable, Equatable {
    let audible: Bool
    /// The engine's refusal, verbatim. Never rewritten on the way through.
    let reason: String?

    static let audibleNote = StudioNotePreviewOutcome(audible: true, reason: nil)

    /// The call did not reach the engine at all. Deliberately reasonless: a
    /// transport failure is not a musical fact, and inventing a sentence for it
    /// would put words in the engine's mouth.
    static let unreachable = StudioNotePreviewOutcome(audible: false, reason: nil)
}

// MARK: - The rule

enum StudioSilentPreview {

    /// The way forward, in the app's own words because it is the app's own
    /// button. Kept as one sentence so it can be appended to any engine reason
    /// without reading as a rewrite of it.
    static let remedy = "Press + Instrument on the track header to add one."

    /// Engine reasons that already name a way back get no remedy appended —
    /// the auto-create hold-off reason ends with "…or add an instrument to a
    /// track", and following that with a second, differently-worded instruction
    /// reads as two conflicting fixes. Matched on the engine's own phrase; if
    /// the engine rewords it the remedy simply reappears, which is a harmless
    /// direction to fail in.
    static let reasonAlreadyNamesARemedy = "add an instrument"

    /// How long the SAME reason stays quiet after being shown. Long enough that
    /// a person experimenting with a silent track is not nagged on every
    /// attempt, short enough that coming back to the problem after reading the
    /// message and trying something else gets told again.
    static let repeatSameReasonAfter: TimeInterval = 20

    /// No notice ever replaces one still on screen, whatever the reason. The
    /// floor is the toast's own lifetime: overwriting a message mid-read is how
    /// a person ends up certain the app said nothing.
    static let minimumGap: TimeInterval = ToastDuration.actionable

    /// The throttle's memory. A value type so the rule can be tested by calling
    /// it, with no singleton and no clock.
    struct State: Equatable {
        var lastReason: String?
        var lastShownAt: Date?

        init() {}
    }

    /// The message for one engine reason: the reason, then the way forward.
    static func message(for reason: String) -> String {
        let carried = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if carried.range(of: reasonAlreadyNamesARemedy, options: .caseInsensitive) != nil {
            return "No sound — \(carried)."
        }
        return "No sound — \(carried). \(remedy)"
    }

    /// Whether this outcome earns a message right now, and what it says.
    ///
    /// The rule, in order:
    ///
    ///  1. It made a sound → nothing to say, and the memory is CLEARED, so the
    ///     next time it goes quiet the user is told immediately rather than
    ///     being swallowed by a cooldown left over from before they fixed it.
    ///  2. A note-OFF is never reported. Every held key is an on/off pair, so
    ///     reporting both would double every notice; and a key-up that made no
    ///     sound is not news — the key-down already said so.
    ///  3. No reason → nothing to say. Never manufacture one.
    ///  4. Within `minimumGap` of the last notice → suppressed, whatever the
    ///     reason: the previous message is still on screen.
    ///  5. Same reason within `repeatSameReasonAfter` → suppressed. This is the
    ///     clause that turns a six-note chord into one message.
    static func notice(
        for outcome: StudioNotePreviewOutcome,
        gate: StudioNoteAuditionGate,
        state: inout State,
        now: Date = Date()
    ) -> String? {
        guard !outcome.audible else {
            state = State()
            return nil
        }
        if case .off = gate { return nil }
        guard let reason = outcome.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }

        if let lastShownAt = state.lastShownAt {
            let since = now.timeIntervalSince(lastShownAt)
            if since < minimumGap { return nil }
            if reason == state.lastReason, since < repeatSameReasonAfter { return nil }
        }

        state.lastReason = reason
        state.lastShownAt = now
        return message(for: reason)
    }
}

// MARK: - The surface

/// Holds the throttle state for the whole app and puts the message where the
/// user is looking.
///
/// A singleton because the two surfaces that share `previewNote` — the piano
/// roll's gutter and the on-screen keyboard — must share ONE cooldown. Playing
/// the same silent track from both in turn is one problem, not two, and two
/// reporters would happily tell you about it twice.
///
/// The toast goes out through `ToastManager`, which routes it to the Studio's
/// own presenter while the Studio tab is frontmost, so it lands inside the DAW
/// frame next to the keys rather than at the far top of the window.
@MainActor
final class StudioSilentPreviewReporter {
    static let shared = StudioSilentPreviewReporter()

    private var state = StudioSilentPreview.State()

    /// `now` is injectable so a test can drive the cooldown without sleeping.
    func report(
        _ outcome: StudioNotePreviewOutcome,
        gate: StudioNoteAuditionGate,
        now: Date = Date()
    ) {
        guard let message = StudioSilentPreview.notice(
            for: outcome, gate: gate, state: &state, now: now) else { return }
        ToastManager.shared.show(message, style: .warning, seconds: ToastDuration.actionable)
    }

    /// For tests: forget everything, so ordering between test cases cannot leak
    /// a cooldown from one into the next.
    func resetForTesting() { state = StudioSilentPreview.State() }
}
