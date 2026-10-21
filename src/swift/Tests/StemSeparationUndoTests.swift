import Testing
import Foundation
@testable import MajiksMusicStudio

// ONE GESTURE, ONE UNDO STEP — the separation half.
//
// Splitting a song in the Studio lands FOUR tracks and FOUR clips. Under the
// import path alone that is four brackets, so taking it back meant four presses
// of Cmd-Z while the arrangement came apart a row at a time. The house rule
// everywhere else in this app is that one gesture is one step.
//
// The fix is the bracket `performImport` already uses, one level out:
// `timeline_core::session::OpenTxn` is RE-ENTRANT (it counts depth, elides the
// inner markers, and closes exactly one `UndoUnit` on the outermost commit), so
// wrapping the four imports in one more `txn.begin`/`txn.commit` makes the whole
// separation a single unit. No new command, no new FFI.
//
// ⚠️ THE PREVIEW ENGINE CANNOT PROVE THE UNDO, for the same reason
// `StudioImportUndoTests` records: `StudioMockEngine.inverse(of:)` has no
// `.trackAdd` arm, so a track added in the mock reverses to nothing and an
// assertion here would be asserting against a gap. So the mock proves the
// GRAMMAR (one outer bracket around the four inner ones) and the real engine
// proves the BEHAVIOUR (one Cmd-Z takes all four rows and all four clips).

// MARK: - A separator that produces four real files

private final class FourPartSeparator: StemSeparating, @unchecked Sendable {
    private(set) var askedFor: [String] = []
    private let seconds: Int
    init(seconds: Int = 1) { self.seconds = seconds }

    func separateIntoStems(sourceAudioPath: String, outputDir: String) async throws -> [String: String] {
        askedFor.append(sourceAudioPath)
        let dir = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [String: String] = [:]
        for part in ["vocals", "drums", "bass", "other"] {
            let url = dir.appendingPathComponent("\(part).wav")
            try StemSeparationFixtures.writeTone(to: url, seconds: seconds)
            out[part] = url.path
        }
        return out
    }
}

private final class DeadSeparator: StemSeparating, @unchecked Sendable {
    func separateIntoStems(sourceAudioPath: String, outputDir: String) async throws -> [String: String] {
        throw StemSeparationTestError(StemSeparationFixtures.engineRefusal)
    }
}

// MARK: - The grammar (preview engine)

@MainActor
@Suite("Separation in the Studio — one gesture, one bracket", .serialized)
struct StemSeparationBracketTests {

    private func adopted(_ engine: StudioMockEngine) async throws -> StudioViewModel {
        let vm = StudioViewModel(engine: engine)
        vm.startPolling()
        for _ in 0..<200 where vm.snapshot == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        vm.stopPolling()
        try #require(vm.snapshot != nil, "the view model never adopted a snapshot")
        return vm
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemSeparationBracket-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("splitting a song emits ONE outer bracket around the four imports")
    func separationIsOneOuterBracket() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("Neon Getaway.wav")
        try StemSeparationFixtures.writeTone(to: song)

        let engine = StudioMockEngine()
        let vm = try await adopted(engine)
        let separator = FourPartSeparator()
        vm.stemSeparator = separator
        let before = try #require(vm.snapshot).tracks.count
        let mark = await engine.journal.count

        await vm.separateIntoStemTracks(path: song.path, named: "Neon Getaway", outputRoot: root)

        #expect(separator.askedFor == [song.path],
                "the Studio's separation never asked the separator for the song")

        let emitted = Array(await engine.journal.dropFirst(mark)).map(\.catalogName)
        // ONE bracket in the journal, wrapping all four imports.
        //
        // ⚠️ THE INNER MARKERS ARE ABSENT, and it is worth writing down WHY,
        // because the two engines get here by different routes and a future
        // reader will otherwise assume this expectation is just wrong.
        //
        // `performImport` sends a `txn.begin` and a `txn.commit` of its own for
        // every one of the four files — that is not in question, it is the same
        // code `StudioImportBracketTests` pins. What differs is what receives
        // them. The REAL engine's `OpenTxn` is re-entrant: an inner begin pushes
        // an id and journals nothing, an inner commit pops it and journals
        // nothing, and only the outermost commit closes the `UndoUnit`. The
        // PREVIEW engine is still v1 — it REFUSES a nested begin outright ("v1
        // transactions do not nest") and refuses a commit whose txnId is not the
        // open one. Neither result is read by `performImport`, so in both
        // engines the outcome is identical and correct: one bracket, one unit,
        // everything inside it.
        //
        // So this is a real assertion about the shape, not a paraphrase of the
        // implementation — and the BEHAVIOUR it is there to protect (one Cmd-Z
        // takes all four rows back) is proven against the real engine below,
        // because the preview engine models no inverse for `track.add` and
        // cannot answer it.
        let expected = ["txn.begin"]
            + Array(repeating: ["track.add", "import.audio"], count: 4).flatMap { $0 }
            + ["txn.commit"]
        #expect(emitted == expected,
                "one split must journal one bracket around four imports, got \(emitted)")
        #expect(emitted.filter { $0 == "txn.begin" }.count == 1,
                "more than one bracket was opened, so the split is more than one undo step")
        #expect(emitted.last == "txn.commit",
                "the bracket was left open, which refuses undo and every later gesture for the session")

        let after = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(after.tracks.count == before + 4, "four parts did not become four rows")
        #expect(after.tracks.suffix(4).map(\.name) == ["Vocals", "Drums", "Bass", "Other"])
        for track in after.tracks.suffix(4) {
            #expect(track.clips.count == 1, "the \(track.name) row has no audio on it")
        }
    }

    /// The failure half: a refusal opens NO bracket at all. A bracket opened and
    /// never closed refuses undo, redo and every later gesture for the rest of
    /// the session — the exact hazard `performImport`'s own comment names.
    @Test("a refused separation opens no bracket and mints no track")
    func aRefusalOpensNoBracket() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("Song.wav")
        try StemSeparationFixtures.writeTone(to: song)

        let engine = StudioMockEngine()
        let vm = try await adopted(engine)
        vm.stemSeparator = DeadSeparator()
        let before = try #require(vm.snapshot).tracks.count
        let mark = await engine.journal.count

        await vm.separateIntoStemTracks(path: song.path, named: "Song", outputRoot: root)

        let emitted = Array(await engine.journal.dropFirst(mark)).map(\.catalogName)
        #expect(emitted.isEmpty,
                "a refused separation still sent commands to the engine: \(emitted)")
        let after = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(after.tracks.count == before, "a refused separation left rows behind")

        let shown = try #require(vm.separationError, "a refused separation said nothing")
        #expect(shown.contains("cannot import demucs"), "the reason was rewritten: \(shown)")
        #expect(shown.contains("screech when soloed"), "the refusal was truncated")
        #expect(vm.separating == false, "the progress state never cleared")
    }

    /// With nothing behind it the gesture must SAY so rather than look broken.
    @Test("with no separator installed the Studio refuses by name")
    func noSeparatorRefusesByName() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StudioMockEngine()
        let vm = try await adopted(engine)
        vm.stemSeparator = nil
        let mark = await engine.journal.count

        await vm.separateIntoStemTracks(path: "/tmp/whatever.wav", named: "Whatever", outputRoot: root)

        #expect(Array(await engine.journal.dropFirst(mark)).isEmpty)
        let shown = try #require(vm.separationError)
        #expect(shown == StudioViewModel.noSeparatorReason)
        #expect(shown.count >= 30, "\"\(shown)\" is too short to be a reason")
    }
}

// MARK: - The seam (real engine, gate 7)

#if REAL_ENGINE
import XCTest

/// THE JOIN for the separation bracket. Same shape and same reasoning as
/// `RealEngineImportUndoTests`: the grammar above is provable against the
/// preview engine and the BEHAVIOUR is not, because the preview engine models
/// no inverse for `track.add`.
///
/// Silent: `RealStudioEngine(dataDir:audible:)` defaults `audible` to false and
/// nothing here starts a live session, so this bundle opens no output device.
@MainActor
final class RealEngineSeparationUndoTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("majiks-separate-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testOneUndoTakesBackAllFourStemTracksAndTheirClips() async throws {
        let engine = try RealStudioEngine(
            dataDir: tempDir.appendingPathComponent("SeparateUndo.mstudio").path, audible: false)
        // A track that was there FIRST. If the bracket ever reached past the
        // gesture, this is what it would eat, and nothing else could tell.
        let seeded = await engine.send(.trackAdd(trackID: UUID().uuidString, name: "Mine", index: 0))
        XCTAssertTrue(seeded.ok, "track.add: \(seeded.message ?? "no message")")

        let vm = StudioViewModel(engine: engine)
        vm.startPolling()
        for _ in 0..<200 where vm.snapshot?.tracks.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        vm.stopPolling()
        let before = try XCTUnwrap(vm.snapshot)
        XCTAssertEqual(before.tracks.count, 1)
        let seededID = before.tracks[0].id

        let song = tempDir.appendingPathComponent("Neon Getaway.wav")
        try StemSeparationFixtures.writeTone(to: song)
        vm.stemSeparator = FourPartSeparator()

        await vm.separateIntoStemTracks(path: song.path, named: "Neon Getaway", outputRoot: tempDir)
        XCTAssertNil(vm.separationError, "the split refused: \(vm.separationError ?? "")")

        let afterSnap = await engine.snapshot(ifNewerThan: nil)
        let after = try XCTUnwrap(afterSnap)
        XCTAssertEqual(after.tracks.count, 5, "four parts did not become four rows")
        let made = after.tracks.filter { $0.id != seededID }
        XCTAssertEqual(made.map(\.name), ["Vocals", "Drums", "Bass", "Other"])
        for track in made {
            XCTAssertEqual(track.clips.count, 1, "the \(track.name) row has no audio on it")
        }

        // ONE press of Cmd-Z.
        let undone = await engine.undo()
        XCTAssertTrue(undone, "there was nothing to undo")
        let restoredSnap = await engine.snapshot(ifNewerThan: nil)
        let restored = try XCTUnwrap(restoredSnap)
        XCTAssertEqual(restored.tracks.map(\.id), [seededID], """
            one undo did not take the whole split back. That is four presses of \
            Cmd-Z watching the song come apart a row at a time: the outer bracket \
            in `separateIntoStemTracks` plus the re-entrant `OpenTxn` in \
            timeline-core are what make the four imports one unit.
            """)
        XCTAssertTrue(restored.tracks[0].clips.isEmpty, "one undo left a clip behind")

        // And a second Cmd-Z reaches PAST the gesture rather than finishing it,
        // which is the proof it was one unit and not four.
        let again = await engine.undo()
        XCTAssertTrue(again, "the undo stack was empty one step too early")
        let pastSnap = await engine.snapshot(ifNewerThan: nil)
        let past = try XCTUnwrap(pastSnap)
        XCTAssertTrue(past.tracks.isEmpty,
                      "the second undo finished the split instead of reaching past it")
    }
}
#endif
