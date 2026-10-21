#if REAL_ENGINE
import XCTest
@testable import MajiksMusicStudio

// THE JOIN, for reopening a project.
//
// A mock package layer cannot exhibit a truncation bug in the real one. The
// defect was that `StudioHost::open_or_create` decided a package existed by
// looking at `project.json` alone while `Package::create` truncates the journal,
// so a package with an intact journal and no checkpoint was ERASED on reopen.
// Nothing in Swift can see that; only a real engine writing a real
// `journal.jsonl` can. These run under gate 7.
//
// ⚠️ SAFETY. Every test here builds its OWN package under a temp directory
// namespaced by process id, and constructs `RealStudioEngine(dataDir:)` on that
// path directly. NOTHING here touches `StudioEngineFactory.shared`,
// `StudioEngineFactory.realEngine()` or `defaultProjectPath()` — materializing
// the shared engine under gate 7 would open the OWNER'S REAL PROJECT, on a
// machine where he is using the app right now, and these are tests about
// DESTROYING projects. `assertIsScratch` below makes that a checked fact rather
// than a promise, on every single construction.
//
// Audio: constructed with the default `audible: false` and nothing calls
// startLive, so this bundle is silent at the device.

@MainActor
final class StudioProjectRecoveryRealEngineTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "majiks-recovery-join-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Nothing here drives the reporter (these assert the ENGINE's facts and
        // the pure notice rule), so there is no one-shot to reset -- and
        // XCTest's setUp is nonisolated, so reaching the MainActor reporter from
        // it would be an actor-isolation violation.
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The guard that makes "no test touches the real project" checkable instead
    /// of merely intended. Every engine construction in this file goes through
    /// `openEngine`, and every one of them passes through here first.
    private func assertIsScratch(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(path.hasPrefix(tempDir.path),
                      "a test package must live under this case's temp dir, not \(path)",
                      file: file, line: line)
        XCTAssertFalse(path.contains("Application Support"),
                       "a test must never open the user's real project", file: file, line: line)
    }

    private func packagePath(_ name: String) -> String {
        tempDir.appendingPathComponent("\(name).mstudio").path
    }

    private func openEngine(_ path: String) throws -> RealStudioEngine {
        assertIsScratch(path)
        return try RealStudioEngine(dataDir: path)
    }

    private func journalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).appendingPathComponent("journal.jsonl")
    }

    /// A package with real, named work in it, closed cleanly.
    private func seed(_ path: String) throws {
        let engine = try openEngine(path)
        let client = engine.copilotClient
        for (id, name) in [("t1", "Sofa Drums"), ("t2", "Folly Bass"), ("t3", "Sunset Keys")] {
            _ = try client.submit(name: "track.add", params: ["trackId": id, "name": name])
        }
        _ = try client.submit(name: "mix.gain", params: ["trackId": "t2", "gainDb": -4.5])
    }

    private func trackNames(_ engine: RealStudioEngine) async -> [String] {
        (await engine.snapshot(ifNewerThan: nil))?.tracks.map(\.name) ?? []
    }

    // MARK: - The defect

    /// The whole point. Checkpoint gone, journal intact — the state a failed
    /// first run or a partial restore leaves — and the app opens it.
    ///
    /// Asserted BY CONTENT, on names this test alone supplies. A count would be
    /// satisfied by any three tracks, and "no error was thrown" would be
    /// satisfied by the erasure itself: the old code returned a perfectly valid,
    /// perfectly empty project and reported success.
    func testAProjectWithNoCheckpointComesBackWithItsRealContents() async throws {
        let path = packagePath("Song")
        try seed(path)
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).appendingPathComponent("project.json"))
        let before = try Data(contentsOf: journalURL(path))
        XCTAssertFalse(before.isEmpty, "the fixture must have a real journal on disk")

        let reopened = try openEngine(path)

        let names = await trackNames(reopened)
        XCTAssertEqual(names, ["Sofa Drums", "Folly Bass", "Sunset Keys"],
                       "the recovered project must carry the work that was journaled")

        // THE ARTIFACT. The file the NEXT launch will read must still be there,
        // byte for byte. This is the assertion the defect fails: the old path
        // replaced it with 0 bytes and the in-memory session looked fine.
        XCTAssertEqual(try Data(contentsOf: journalURL(path)), before,
                       "reopening must not rewrite one byte of an intact journal")

        let facts = try XCTUnwrap(reopened.openRecovery, "the engine must report the open")
        XCTAssertTrue(facts.checkpointMissing)
        XCTAssertTrue(facts.replayedFromJournal)
        XCTAssertEqual(facts.commandsRecovered, 4)
        XCTAssertEqual(facts.corruptLinesDropped, 0)

        // And the user is told, in the app's own words.
        let notice = StudioProjectRecovery.notice(for: facts) ?? ""
        XCTAssertTrue(notice.contains("rebuilt"), "the recovery is surfaced: \(notice)")
    }

    /// The reassurance test, and the one that keeps the notice worth reading: an
    /// intact package must open silently. Also proves the assertion above is not
    /// simply always true.
    func testAnIntactProjectOpensSilently() async throws {
        let path = packagePath("Intact")
        try seed(path)
        _ = try openEngine(path).copilotClient.submit(name: "project.save", params: [:])

        let reopened = try openEngine(path)
        let names = await trackNames(reopened)
        XCTAssertEqual(names, ["Sofa Drums", "Folly Bass", "Sunset Keys"])
        let facts = try XCTUnwrap(reopened.openRecovery)
        XCTAssertFalse(facts.checkpointMissing)
        XCTAssertNil(StudioProjectRecovery.notice(for: facts),
                     "an ordinary reopen must say nothing at all")
    }

    /// Partial recovery, through the real engine: a log damaged partway keeps
    /// everything ahead of the break instead of costing the whole session.
    func testADamagedHistoryKeepsTheWorkAheadOfTheDamage() async throws {
        let path = packagePath("Damaged")
        try seed(path)
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).appendingPathComponent("project.json"))

        let lines = try String(contentsOf: journalURL(path), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        // Repeat entry 0 at position 2: entries 0 and 1 still chain, nothing
        // after does.
        let mangled = [lines[0], lines[1], lines[0], lines[3]].joined(separator: "\n") + "\n"
        try mangled.write(to: journalURL(path), atomically: true, encoding: .utf8)

        let reopened = try openEngine(path)

        let names = await trackNames(reopened)
        XCTAssertEqual(names, ["Sofa Drums", "Folly Bass"],
                       "the work ahead of the damage survives (2, not 3, and not 0)")
        let facts = try XCTUnwrap(reopened.openRecovery)
        XCTAssertEqual(facts.commandsRecovered, 2)
        XCTAssertEqual(facts.corruptLinesDropped, 2)

        // The bytes that could not be read were set aside, not deleted.
        let quarantine = try XCTUnwrap(facts.quarantinedJournal)
        XCTAssertEqual(try String(contentsOfFile: quarantine, encoding: .utf8), mangled,
                       "the quarantine holds the original file, byte for byte")

        let notice = StudioProjectRecovery.notice(for: facts) ?? ""
        XCTAssertTrue(notice.contains("lost"), "a real loss is stated plainly: \(notice)")
    }
}
#endif
