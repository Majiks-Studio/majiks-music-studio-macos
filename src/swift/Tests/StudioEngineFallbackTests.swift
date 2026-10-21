import XCTest
@testable import MajiksMusicStudio

// When the user's project cannot be opened, the app must SAY SO.
//
// `StudioEngineFactory.makeDefault()` catches a `RealStudioEngine` init failure
// — corrupt checkpoint, broken hash chain, permissions — and returns
// `StudioMockEngine`. That is not an empty stand-in. `StudioMockEngine`'s own
// header calls it "the L5 performance-gate fixture: exactly 8 tracks and 100
// clips". So the shipped behaviour was: your project fails to open, and you are
// shown a fully populated, fully interactive project that is a TEST FIXTURE,
// with the only trace an `NSLog` in Console.app. Every edit then made lands in
// the mock and reaches no `.mstudio` package at all.
//
// This is the codebase's signature failure — a piano roll wired to a mock while
// the real engine ran alongside — one layer up, with the whole project as the
// subject.
//
// ── WHAT THIS FILE CAN AND CANNOT PROVE ─────────────────────────────────────
//
// It cannot make `RealStudioEngine.init` throw. That needs a real framework, a
// real package on disk and a way to corrupt it, and none of that exists in a
// mock-engine test bundle. What it CAN pin is everything the fix is made of:
// the sentence, the fact that a healthy build reports nothing, and the one line
// in the view that turns the recorded reason into something a human sees.
//
// The uncovered half is stated plainly in the lane report rather than papered
// over with a test that asserts a constant against itself.

final class StudioEngineFallbackTests: XCTestCase {

    // MARK: - The sentence

    /// The notice has to carry the two facts that change what the user does
    /// next, and it must carry the engine's own reason so the cause is not lost.
    func testTheNoticeSaysItIsNotYourProjectAndWillNotBeSaved() {
        let notice = StudioEngineFactory.fallbackNotice(reason: "checkpoint is corrupt")

        XCTAssertTrue(
            notice.localizedCaseInsensitiveContains("could not be opened"),
            "the notice does not say the project failed to open, which is the whole news: \(notice)")
        XCTAssertTrue(
            notice.localizedCaseInsensitiveContains("nothing here is yours"),
            "the notice does not say the visible project is not the user's. Without that they will "
            + "reasonably assume the 8 tracks in front of them are their work: \(notice)")
        XCTAssertTrue(
            notice.localizedCaseInsensitiveContains("will not be saved"),
            "the notice does not warn that edits are discarded. That is the sentence that stops "
            + "someone working for an hour into a fixture: \(notice)")
        XCTAssertTrue(
            notice.contains("checkpoint is corrupt"),
            "the engine's own reason was dropped on the way to the user, which is exactly the "
            + "silent-degradation shape this fix exists to close: \(notice)")
    }

    /// Written for someone who has never opened a DAW. The owner of this app is
    /// not a DAW user and drives it from a sofa; "the engine fell back to the
    /// mock" is not a sentence that helps him.
    func testTheNoticeUsesNoDeveloperJargon() {
        let notice = StudioEngineFactory.fallbackNotice(reason: "io error")
        for jargon in ["mock", "engine", "fallback", "FFI", "nil", "exception"] {
            XCTAssertFalse(
                notice.localizedCaseInsensitiveContains(jargon),
                "the notice says \"\(jargon)\" — the person this is for has no such word. "
                + "Full text: \(notice)")
        }
    }

    // MARK: - The control

    /// A healthy build reports no degradation. Without this, a notice that fired
    /// unconditionally would pass every assertion above while crying wolf on
    /// every launch.
    ///
    /// Under the mock-engine test bundle there is no real engine to fail, so the
    /// `#else` branch of `makeDefault()` runs and must record nothing — a mock
    /// BUILD is not a mock FALLBACK, and conflating the two would make the
    /// warning meaningless.
    ///
    /// Note this reads the accessor WITHOUT materializing `StudioEngineFactory
    /// .shared`, and that is a property of the accessor rather than of the test:
    /// `RealStudioEngine.init` opens the user's `.mstudio` package, so under
    /// gate 7 an accessor that touched `shared` would make this test open the
    /// owner's real project — while the shipping app may well have it open.
    /// No test in this bundle touches `shared`, and this one must not become
    /// the first. See the comment on `engineFallbackReason`.
    func testABuildThatDidNotFallBackReportsNoReason() {
        XCTAssertNil(
            StudioEngineFactory.engineFallbackReason,
            "the Studio reported a project-open failure on a build where nothing failed. A warning "
            + "that appears when everything is fine is one the user learns to ignore.")
    }

    // MARK: - The feed line
    //
    // The commonest survivor on this repo: every component proven and the ONE
    // line that feeds them asserted by nothing. `fallbackNotice` can be perfect
    // and `engineFallbackReason` can be set correctly, and if the view never
    // calls them the user still sees a fixture in silence. A `.onAppear` branch
    // cannot be observed without a window, so this reads the source — the same
    // idiom `StudioSoundsVaultTests` uses for the timeline's `.onDrop`.

    /// ⚠️ The first version of this test was itself a survivor, and the fix is
    /// the whole point of `JourneyAuditSource`.
    ///
    /// It asserted `text.contains("announceEngineFallbackIfNeeded()")` on the
    /// raw file. The DECLARATION — `private func announceEngineFallbackIfNeeded()
    /// {` — contains that substring, so deleting the CALL from `.onAppear` left
    /// it green. And the two other strings it checked live inside that same
    /// function's body, so the entire guard was answered by the function it was
    /// policing. Exactly the "entry-point scan satisfied by a method's own
    /// definition" shape this repo has shipped before.
    ///
    /// `callSites(of:in:)` strips comments and subtracts the declaration, so
    /// what is asserted is that something actually CALLS it.
    func testTheStudioActuallyAnnouncesTheFallbackOnAppear() throws {
        let text = try JourneyAuditSource.source("Studio/StudioRootView.swift")

        XCTAssertGreaterThan(
            JourneyAuditSource.callSites(of: "announceEngineFallbackIfNeeded", in: text), 0,
            "StudioRootView declares announceEngineFallbackIfNeeded but never CALLS it, so a "
            + "project that failed to open is back to being silent. (This assertion counts call "
            + "sites and excludes the declaration on purpose — the earlier version of it was "
            + "satisfied by the declaration alone.)")
        XCTAssertGreaterThan(
            JourneyAuditSource.mentions(of: "StudioEngineFactory.engineFallbackReason", in: text), 0,
            "the announcement no longer reads the recorded reason, so it can only ever be silent "
            + "or a lie")
        XCTAssertGreaterThan(
            JourneyAuditSource.mentions(of: "StudioEngineFactory.fallbackNotice(reason:", in: text), 0,
            "the announcement stopped going through the tested sentence")
    }

    /// Guard the guard: prove the scanner actually removes prose, so the two
    /// assertions above cannot be answered by a comment naming the symbol.
    ///
    /// Without this, `JourneyAuditSource.code` could quietly degrade to the
    /// identity function and every source-reading guard in this suite would go
    /// back to being satisfied by the comments that describe it.
    func testTheSourceScannerIgnoresCommentsAndDeclarations() {
        let fixture = """
        // announceEngineFallbackIfNeeded() written in a line comment
        /// announceEngineFallbackIfNeeded() written in a doc comment
        /* announceEngineFallbackIfNeeded() in a block */
        private func announceEngineFallbackIfNeeded() {
            let url = "https://example.com/announceEngineFallbackIfNeeded"
        }
        """
        XCTAssertEqual(
            JourneyAuditSource.callSites(of: "announceEngineFallbackIfNeeded", in: fixture), 0,
            "comments and the declaration were counted as call sites, which is precisely the "
            + "defect this scanner exists to prevent")

        let withCall = fixture + "\n        announceEngineFallbackIfNeeded()\n"
        XCTAssertEqual(
            JourneyAuditSource.callSites(of: "announceEngineFallbackIfNeeded", in: withCall), 1,
            "a real call site was not counted, so the scanner would fail an honest wiring")
    }

    /// The factory still records the reason on the failure path. Reading the
    /// source because the `#if REAL_ENGINE` catch block is compiled OUT of this
    /// bundle entirely — the GATES.md hazard: a `#if` nothing builds under is a
    /// file you have deleted without noticing, and gate 5 is what compiles it.
    func testTheFactoryRecordsTheReasonOnTheRealEngineFailurePath() throws {
        let text = try String(
            contentsOf: Self.sourcesDirectory
                .appendingPathComponent("Studio/StudioEngineFactory.swift"),
            encoding: .utf8)

        XCTAssertTrue(
            text.contains("_fallbackReason = \"\\(error)\""),
            "the real-engine catch no longer records why it failed, so engineFallbackReason is "
            + "always nil and the notice can never fire")
    }

    /// Where the test bundle's own source tree lives, for the two source reads
    /// above. Same derivation `StudioSoundsVaultTests` uses.
    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/StudioEngineFallbackTests.swift
            .deletingLastPathComponent()         // .../Tests
            .deletingLastPathComponent()         // .../swift
            .appendingPathComponent("Sources")
    }
}
