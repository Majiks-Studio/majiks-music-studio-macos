import Foundation

// MARK: - When the project had to be REBUILT, say so
//
// THE DEFECT THIS EXISTS FOR
//
// `journal.jsonl` is the project. Every command is written through to it at
// submit time (`StudioProjectSaver` says so at length, and `FileJournal::append`
// is what makes it true); `project.json` is only a checkpoint so the next open
// is fast instead of a full replay.
//
// `StudioHost::open_or_create` decided whether a package existed by looking at
// the CHECKPOINT alone, and the create path opens the journal with a call that
// truncates. So a package with an intact journal and a missing checkpoint — a
// fully recoverable project — was answered by overwriting the truth with an
// empty file. The engine now decides on the journal and rebuilds the session by
// replaying it, which is the same path a `kill -9` already took.
//
// WHY THERE IS ANYTHING ON SCREEN AT ALL
//
// Because a recovery that works but says nothing is only half a fix. When the
// app has just rebuilt a project from its command log, the person who made that
// music is entitled to know — that is the one moment when checking the work and
// taking a copy is worth doing, and they cannot choose to do it if nothing tells
// them. It is the same rule the rest of this Studio follows: the engine's
// finding is carried to the user rather than left in an NSLog nobody reads.
//
// TWO RULES
//
//  1. An ORDINARY reopen says nothing. A checkpoint that was present and matched
//     is the overwhelmingly common case, and a notice that fires every launch is
//     one nobody reads on the launch that matters.
//  2. The sentence is written for someone who has never opened a DAW. It does
//     not say "journal", "checkpoint", "hash chain" or "replay". It says what
//     happened to their song and what, if anything, was lost.

// MARK: - What the engine reported

/// The engine's account of what the last package open had to do.
///
/// All-false / all-zero is an ordinary reopen. Deliberately a plain value type
/// with no engine reference so the rule below can be tested by calling it.
struct StudioProjectRecoveryFacts: Equatable, Sendable {
    /// `project.json` was gone. On its own this is the fully-recoverable case:
    /// the journal had everything.
    var checkpointMissing = false
    /// The session was rebuilt by replaying the command log rather than read
    /// from the checkpoint.
    var replayedFromJournal = false
    /// How many commands the recovered session actually contains.
    var commandsRecovered = 0
    /// One half-written final command was dropped — the ordinary signature of a
    /// crash or a power cut, and the smallest possible loss.
    var tornTailDropped = 0
    /// Commands that could not be read because the log was damaged before them.
    /// This is the one that costs real work.
    var corruptLinesDropped = 0
    /// Where the unreadable bytes were set aside, if any were.
    var quarantinedJournal: String?
    /// The checkpoint describes more work than the command log holds, so this
    /// open returned less than the package once had.
    var checkpointAheadOfJournal = false

    init() {}

    #if REAL_ENGINE
    /// Parse the engine's `open_recovery` JSON. An absent or unparseable payload
    /// yields the ordinary-reopen value: an app that cannot read the report must
    /// stay quiet, never invent a scare.
    ///
    /// `#if REAL_ENGINE` because `EngineJSON` lives in `Sources/Engine`, which
    /// Package.swift excludes from the no-framework build. The RULE above is
    /// deliberately outside the flag so it is compiled and tested in BOTH
    /// builds; only the decode of the real engine's bytes is conditional, and
    /// gate 5 compiles it while gate 7 runs it.
    init(engineJSON json: EngineJSON) {
        checkpointMissing = json.bool("checkpointMissing") ?? false
        replayedFromJournal = json.bool("replayedFromJournal") ?? false
        commandsRecovered = Int(json.int64("commandsRecovered") ?? 0)
        tornTailDropped = Int(json.int64("tornTailDropped") ?? 0)
        corruptLinesDropped = Int(json.int64("corruptLinesDropped") ?? 0)
        quarantinedJournal = json.string("quarantinedJournal")
        checkpointAheadOfJournal = json.bool("checkpointAheadOfJournal") ?? false
    }
    #endif
}

// MARK: - The rule

enum StudioProjectRecovery {

    /// The message for one open, or nil when there is nothing to say.
    ///
    /// Ordered worst first, because a damaged log matters more than a missing
    /// checkpoint and the user should be told the thing that cost them
    /// something, not the thing that cost them nothing.
    ///
    ///  1. Commands were LOST to damage → say how many, and that the rest was
    ///     kept. This is the only branch that reports a loss.
    ///  2. The checkpoint claimed more than the log held → say the project may
    ///     be missing its most recent work.
    ///  3. Rebuilt from the log with nothing lost → reassure, and suggest the
    ///     one action worth taking.
    ///  4. Only a half-written last command was dropped (an ordinary crash) →
    ///     say that one thing may be missing. Cheap to re-do, but silence here
    ///     is how a person concludes the app "lost" something at random.
    ///  5. Otherwise → nothing.
    static func notice(for facts: StudioProjectRecoveryFacts) -> String? {
        if facts.corruptLinesDropped > 0 {
            let lost = facts.corruptLinesDropped
            let kept = facts.commandsRecovered
            var sentence = "Part of this project's saved history was damaged. "
                + "\(kept) \(kept == 1 ? "change was" : "changes were") recovered and "
                + "\(lost) \(lost == 1 ? "was" : "were") lost. "
                + "Check the song before you carry on."
            if facts.quarantinedJournal != nil {
                // Named, not pathed: the sentence stays readable, and a person
                // who needs the file can be walked to it. The path is on the
                // facts for whoever asks.
                sentence += " The damaged file was kept alongside the project."
            }
            return sentence
        }
        if facts.checkpointAheadOfJournal {
            return "This project's saved history is shorter than its project file, "
                + "so some recent work may be missing. Check the song before you carry on."
        }
        if facts.replayedFromJournal || facts.checkpointMissing {
            let n = facts.commandsRecovered
            return "This project was rebuilt from its saved history — "
                + "\(n) \(n == 1 ? "change" : "changes") recovered, nothing lost. "
                + "Press \u{2318}S to write a fresh copy."
        }
        if facts.tornTailDropped > 0 {
            return "The app closed unexpectedly last time, so the very last thing "
                + "you did may not have been saved. Everything before it is here."
        }
        return nil
    }
}

// MARK: - The surface

/// Puts the notice where the user is looking, exactly once per launch.
///
/// One-shot on purpose: the facts describe an event at open time, so repeating
/// them on every tab switch would be nagging about something already dealt with.
/// Routed through `ToastManager` like every other Studio notice, so it lands
/// inside the DAW frame rather than at the far top of the window.
@MainActor
final class StudioProjectRecoveryReporter {
    static let shared = StudioProjectRecoveryReporter()

    private var reported = false

    func report(_ facts: StudioProjectRecoveryFacts?) {
        guard !reported, let facts else { return }
        guard let message = StudioProjectRecovery.notice(for: facts) else {
            // Nothing to say IS the answer for an ordinary open; mark it done so
            // a later tab switch does not re-ask.
            reported = true
            return
        }
        reported = true
        ToastManager.shared.show(message, style: .warning, seconds: ToastDuration.actionable)
    }

    /// For tests: forget that anything was reported, so ordering between cases
    /// cannot leak a one-shot from one into the next.
    func resetForTesting() { reported = false }
}
