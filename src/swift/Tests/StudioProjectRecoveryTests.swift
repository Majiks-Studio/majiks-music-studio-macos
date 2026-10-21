import XCTest
@testable import MajiksMusicStudio

/// The RULE for what the app says when a project had to be rebuilt.
///
/// Pure: it constructs facts and calls the function. Nothing here touches an
/// engine, a package, or `StudioEngineFactory` — the real seam is proven in
/// `StudioProjectRecoveryRealEngineTests` against a temp package.
@MainActor
final class StudioProjectRecoveryTests: XCTestCase {

    // No `setUp` override: XCTest's is nonisolated, so reaching the MainActor
    // reporter from it is an actor-isolation violation (a warning today, an
    // error under strict concurrency). Only one test here touches the reporter,
    // and it resets in its own body, where the class's @MainActor applies.

    /// The rule that keeps the notice worth reading: an intact package says
    /// nothing at all. A warning on every launch is a warning nobody sees on
    /// the launch that matters.
    func testAnOrdinaryReopenSaysNothing() {
        XCTAssertNil(StudioProjectRecovery.notice(for: StudioProjectRecoveryFacts()))
    }

    /// The reported defect's happy ending: rebuilt, nothing lost, and the user
    /// is told — including the one action worth taking.
    func testARebuiltProjectTellsTheUserAndSuggestsASave() {
        var facts = StudioProjectRecoveryFacts()
        facts.checkpointMissing = true
        facts.replayedFromJournal = true
        facts.commandsRecovered = 47

        let message = StudioProjectRecovery.notice(for: facts) ?? ""
        XCTAssertFalse(message.isEmpty, "a rebuilt project must be announced")
        XCTAssertTrue(message.contains("rebuilt"), "the user is told it was rebuilt: \(message)")
        XCTAssertTrue(message.contains("47"), "and how much came back: \(message)")
        XCTAssertTrue(message.contains("nothing lost"), "and that nothing was lost: \(message)")
        XCTAssertTrue(message.contains("\u{2318}S"), "and what to do next: \(message)")
        // Written for someone who has never opened a DAW.
        for jargon in ["journal", "checkpoint", "hash", "replay", "chain"] {
            XCTAssertFalse(message.lowercased().contains(jargon),
                           "the notice must not use the word \"\(jargon)\": \(message)")
        }
    }

    /// The only branch that reports a LOSS says how much survived as well as how
    /// much did not — "part of your project is gone" with no number is a message
    /// that makes a person assume the worst.
    func testDamageReportsBothWhatWasLostAndWhatSurvived() {
        var facts = StudioProjectRecoveryFacts()
        facts.replayedFromJournal = true
        facts.commandsRecovered = 12
        facts.corruptLinesDropped = 3
        facts.quarantinedJournal = "/tmp/Song.mstudio/journal.jsonl.corrupt-0"

        let message = StudioProjectRecovery.notice(for: facts) ?? ""
        XCTAssertTrue(message.contains("12"), "what survived: \(message)")
        XCTAssertTrue(message.contains("3"), "what was lost: \(message)")
        XCTAssertTrue(message.contains("damaged"), "and that it was damage: \(message)")
        XCTAssertTrue(message.contains("kept alongside"),
                      "the set-aside file is mentioned when there is one: \(message)")
    }

    /// Damage outranks a missing checkpoint. Told only "rebuilt, nothing lost"
    /// while three commands were in fact lost, the user would carry on unaware —
    /// the exact silent-degradation shape this whole notice exists to end.
    func testALossIsReportedInPreferenceToAReassurance() {
        var facts = StudioProjectRecoveryFacts()
        facts.checkpointMissing = true
        facts.replayedFromJournal = true
        facts.commandsRecovered = 12
        facts.corruptLinesDropped = 3

        let message = StudioProjectRecovery.notice(for: facts) ?? ""
        XCTAssertFalse(message.contains("nothing lost"),
                       "a rebuild that lost commands must not claim nothing was lost: \(message)")
        XCTAssertTrue(message.contains("lost"), "\(message)")
    }

    /// A checkpoint that describes more work than the log holds is a DIFFERENT
    /// loss and gets its own sentence — it is the one the engine cannot repair,
    /// so leaving it unsaid is leaving the user unable to notice it.
    func testACheckpointAheadOfTheLogIsItsOwnWarning() {
        var facts = StudioProjectRecoveryFacts()
        facts.checkpointAheadOfJournal = true
        facts.commandsRecovered = 4

        let message = StudioProjectRecovery.notice(for: facts) ?? ""
        XCTAssertTrue(message.contains("recent work may be missing"), "\(message)")
    }

    /// The ordinary crash: one half-written command. Small, but silence here is
    /// how a person concludes the app loses things at random.
    func testATornLastCommandIsMentionedButNotAlarming() {
        var facts = StudioProjectRecoveryFacts()
        facts.tornTailDropped = 1
        facts.commandsRecovered = 9

        let message = StudioProjectRecovery.notice(for: facts) ?? ""
        XCTAssertTrue(message.contains("closed unexpectedly"), "\(message)")
        XCTAssertTrue(message.contains("Everything before it is here"), "\(message)")
    }

    /// Singular and plural are both written, because "1 changes recovered" in a
    /// message about lost work reads as a broken app at the worst moment.
    func testTheSentenceAgreesWithItsNumber() {
        var one = StudioProjectRecoveryFacts()
        one.replayedFromJournal = true
        one.commandsRecovered = 1
        XCTAssertTrue((StudioProjectRecovery.notice(for: one) ?? "").contains("1 change recovered"))

        var many = StudioProjectRecoveryFacts()
        many.replayedFromJournal = true
        many.commandsRecovered = 2
        XCTAssertTrue((StudioProjectRecovery.notice(for: many) ?? "").contains("2 changes recovered"))
    }

    /// One-shot: the facts describe an event at open time, so a tab switch must
    /// not re-announce it.
    func testTheReporterSpeaksOncePerLaunch() {
        StudioProjectRecoveryReporter.shared.resetForTesting()
        var facts = StudioProjectRecoveryFacts()
        facts.replayedFromJournal = true
        facts.commandsRecovered = 3

        ToastManager.shared.currentToast = nil
        StudioProjectRecoveryReporter.shared.report(facts)
        XCTAssertNotNil(ToastManager.shared.currentToast, "the first report is shown")

        // Clear the surface and ask again: a second report must put nothing back.
        ToastManager.shared.currentToast = nil
        StudioProjectRecoveryReporter.shared.report(facts)
        XCTAssertNil(ToastManager.shared.currentToast,
                     "a recovery is announced exactly once, not once per tab switch")
    }
}
