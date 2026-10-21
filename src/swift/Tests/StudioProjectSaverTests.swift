import XCTest
@testable import MajiksMusicStudio

// The save affordance, asserted on BEHAVIOUR rather than on a label.
//
// The bug this guards: `project.save` existed in the catalog and nothing in the
// app ever sent it. A test that asserted "the indicator says Saved" would have
// passed over exactly that defect — the whole point is that a save GESTURE
// reaches the COMMAND BUS. So every assertion here goes through
// `StudioEngineProtocol.send` and reads the engine's own count.
//
// The saver is a `@MainActor` singleton (the app-termination path has no
// instance to reach otherwise), so these tests share it and reset it between
// cases via `resetForTesting()`.

@MainActor
final class StudioProjectSaverTests: XCTestCase {

    private func freshSaver(_ engine: StudioMockEngine) -> StudioProjectSaver {
        let saver = StudioProjectSaver.shared
        saver.resetForTesting()
        saver.attach(engine)
        return saver
    }

    // -----------------------------------------------------------------------
    // The load-bearing one: ⌘S actually submits project.save.
    // -----------------------------------------------------------------------

    func testSaveSubmitsProjectSaveToTheCommandBus() async throws {
        let engine = StudioMockEngine()
        let saver = freshSaver(engine)

        let before = await engine.savesRequested
        XCTAssertEqual(before, 0, "control: nothing submitted yet")

        let ok = await saver.save(force: true)
        XCTAssertTrue(ok, "the mock engine acknowledges project.save")

        let after = await engine.savesRequested
        XCTAssertEqual(
            after, 1,
            "⌘S must reach the engine's command bus. Before this lane the save gesture did not exist at all, and a UI-only assertion would not have noticed."
        )
    }

    func testForcedSaveWorksEvenWhenNothingChanged() async throws {
        let engine = StudioMockEngine()
        let saver = freshSaver(engine)
        saver.noteRevision(7)
        XCTAssertFalse(saver.hasUncheckpointedWork, "a fresh session is current")

        _ = await saver.save(force: true)
        let count = await engine.savesRequested
        XCTAssertEqual(
            count, 1,
            "a user who presses ⌘S out of habit must get a real save, not a silent no-op that looks like the app cannot save"
        )
    }

    // -----------------------------------------------------------------------
    // Dirty state is derived from ENGINE revisions, not from UI guesses.
    // -----------------------------------------------------------------------

    func testAFreshlyOpenedProjectIsNotReportedAsUnsaved() {
        let engine = StudioMockEngine()
        let saver = freshSaver(engine)
        XCTAssertFalse(saver.hasUncheckpointedWork, "no snapshot yet: nothing to report")

        saver.noteRevision(42)
        XCTAssertFalse(
            saver.hasUncheckpointedWork,
            "the first snapshot of a session describes what is ALREADY on disk; reporting it as unsaved would cry wolf on every launch"
        )
        XCTAssertEqual(saver.status, .saved(nil))
    }

    func testANewRevisionMarksTheCheckpointBehind() {
        let engine = StudioMockEngine()
        let saver = freshSaver(engine)
        saver.noteRevision(1)
        saver.noteRevision(2)
        XCTAssertTrue(saver.hasUncheckpointedWork)
        XCTAssertEqual(saver.status, .pendingCheckpoint)
    }

    func testASaveClearsTheDirtyStateAndAFurtherEditSetsItAgain() async throws {
        let engine = StudioMockEngine()
        let saver = freshSaver(engine)
        saver.noteRevision(1)
        saver.noteRevision(2)
        XCTAssertTrue(saver.hasUncheckpointedWork)

        _ = await saver.save()
        XCTAssertFalse(saver.hasUncheckpointedWork, "the checkpoint now covers revision 2")

        saver.noteRevision(3)
        XCTAssertTrue(saver.hasUncheckpointedWork, "a later edit is uncheckpointed again")
    }

    /// An unforced save on a clean project must NOT write. An idle Studio that
    /// rewrote project.json every autosave tick would churn the disk forever.
    func testAnIdleProjectIsNotRewrittenOnEveryAutosaveTick() async throws {
        let engine = StudioMockEngine()
        let saver = freshSaver(engine)
        saver.noteRevision(5)

        _ = await saver.save()
        _ = await saver.save()
        _ = await saver.save()
        let count = await engine.savesRequested
        XCTAssertEqual(count, 0, "nothing changed, so nothing should have been written")
    }

    // -----------------------------------------------------------------------
    // Failure honesty.
    // -----------------------------------------------------------------------

    func testARefusedSaveIsReportedAndDoesNotClaimTheWorkIsCheckpointed() async throws {
        let engine = StudioMockEngine()
        await engine.setRefuseSave(true)
        let saver = freshSaver(engine)
        saver.noteRevision(1)
        saver.noteRevision(2)

        let ok = await saver.save()
        XCTAssertFalse(ok)
        guard case .failed = saver.status else {
            return XCTFail("a refused save must surface as .failed, got \(saver.status)")
        }
        XCTAssertTrue(
            saver.hasUncheckpointedWork,
            "a failed save must NOT mark the revision checkpointed — that is the optimistic-confirm bug: reporting done before success"
        )
    }

    // -----------------------------------------------------------------------
    // The affordance is discoverable from the palette too.
    // -----------------------------------------------------------------------

    func testTheCommandPaletteListsProjectSaveAsWiredNotAsComingLater() {
        let entries = StudioPaletteCatalog.entries()
        guard let save = entries.first(where: { $0.id == "project.save" }) else {
            return XCTFail("project.save missing from the palette")
        }
        guard case .catalogWired = save.kind else {
            return XCTFail(
                "project.save is still .catalogListed — invoking it shows a toast saying it 'wires into Studio in a later build' while the user's project goes unsaved"
            )
        }
    }
}
