import Testing
import Foundation
@testable import MajiksMusicStudio

// ONE GESTURE, ONE UNDO STEP — the import half.
//
// Dragging a file onto the timeline builds a row and puts the audio on it, and
// that is TWO journaled operations: `track.add`, then the engine's own import
// transaction. So one drag cost two presses of Cmd-Z — the first took the clip
// off and left the user looking at an empty row they never asked for, the
// second took the row away. `StudioDeleteAndDiscoverTests` already pins the
// same rule for Delete Track; this is the gesture that was still breaking it.
//
// ⚠️ THE PREVIEW ENGINE CANNOT PROVE THE UNDO, and the reason is worth writing
// down rather than working around. `StudioMockEngine.inverse(of:)` has no
// `.trackAdd` arm at all — a track added in the mock reverses to NOTHING — so
// in the mock the second Cmd-Z this lane removes never existed to begin with,
// and an assertion here that "one undo takes the row back" would be asserting
// against a gap the mock shares with nothing. Measured, not assumed: written
// first as a mock assertion, it failed with the row still present and its clip
// count at 0.
//
// So the mock proves the half it genuinely owns — the GRAMMAR, that the gesture
// emits one bracket and that an overdub is not wrapped in one — and the seam
// (one undo puts back the row AND the clip) is proven twice where it is real:
// against the FFI engine in `RealEngineImportUndoTests` below (gate 7), and in
// Rust in `agent-surface/tests/import.rs`.

// MARK: - Helpers

@MainActor
private func adoptedViewModel(_ engine: StudioMockEngine) async throws -> StudioViewModel {
    let vm = StudioViewModel(engine: engine)
    vm.startPolling()
    for _ in 0..<200 where vm.snapshot == nil {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    // Freeze the poll so assertions never race it.
    vm.stopPolling()
    try #require(vm.snapshot != nil, "the view model never adopted a snapshot")
    return vm
}

private func journaledNames(_ engine: StudioMockEngine, after mark: Int) async -> [String] {
    let all = await engine.journal
    return Array(all.dropFirst(mark)).map(\.catalogName)
}

// MARK: - The grammar (preview engine)

@Suite("Import — one gesture, one bracket")
struct StudioImportBracketTests {

    @Test("importing onto a new track emits exactly one txn bracket")
    @MainActor
    func importOntoANewTrackIsOneBracket() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let before = try #require(vm.snapshot)
        let mark = await engine.journal.count

        let landed = await vm.performImport(path: "/tmp/Some Song.wav")
        #expect(landed, "the import did not land: \(vm.importStatus)")

        let emitted = await journaledNames(engine, after: mark)
        #expect(emitted == ["txn.begin", "track.add", "import.audio", "txn.commit"],
                "one drag must journal one bracket, got \(emitted)")

        let after = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(after.tracks.count == before.tracks.count + 1, "the gesture did not build a row")
        let made = try #require(
            after.tracks.first { t in !before.tracks.contains { $0.id == t.id } },
            "no new row, so the bracket above wrapped nothing")
        #expect(made.clips.count == 1, "the audio did not land on the row the gesture made")
    }

    /// The negative half, and the one that stops the bracket being wired to
    /// fire always: an overdub onto a row that already exists is ONE journaled
    /// command and must not be wrapped in markers it does not need.
    @Test("an overdub onto an existing track emits no bracket")
    @MainActor
    func overdubOntoAnExistingTrackIsNotBracketed() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let target = try #require(vm.snapshot?.tracks.first)
        let mark = await engine.journal.count

        let landed = await vm.performImport(path: "/tmp/Overdub.wav", ontoTrackID: target.id, newTrack: false)
        #expect(landed, "the overdub did not land: \(vm.importStatus)")

        let emitted = await journaledNames(engine, after: mark)
        #expect(emitted == ["import.audio"], "an overdub is one command, got \(emitted)")
    }
}

// MARK: - The seam (real engine, gate 7)

#if REAL_ENGINE
import XCTest

/// THE JOIN for the import bracket. Same shape and same reasoning as
/// `StudioSamplerRealEngineTests`: the grammar above is provable against the
/// preview engine and the BEHAVIOUR is not, because the preview engine models
/// no inverse for `track.add` and opens no transaction inside its own import.
/// Both of those are exactly what this lane changed, so the mock is the last
/// thing that would notice if it regressed.
///
/// Silent: `RealStudioEngine(dataDir:audible:)` defaults `audible` to false and
/// nothing here starts a live session, so this bundle opens no output device.
@MainActor
final class RealEngineImportUndoTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("majiks-import-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A real 16-bit mono WAV the engine can genuinely decode. Written by hand
    /// rather than pulled from a fixture directory so this test has no
    /// dependency on another lane's generated files.
    private func writeTone(named name: String) throws -> String {
        let rate = 48_000
        let frames = rate      // one second
        var body = Data()
        for i in 0..<frames {
            let v = sin(2 * .pi * 440 * Double(i) / Double(rate)) * 0.6
            var s = Int16(max(-1, min(1, v)) * 32_000)
            withUnsafeBytes(of: &s) { body.append(contentsOf: $0) }
        }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8)
        wav += le32(36 + body.count)
        wav += Data("WAVEfmt ".utf8)
        wav += le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        wav += Data("data".utf8) + le32(body.count) + body
        let url = tempDir.appendingPathComponent(name)
        try wav.write(to: url)
        return url.path
    }

    func testOneUndoTakesBackBothTheRowAndTheClip() async throws {
        let engine = try RealStudioEngine(
            dataDir: tempDir.appendingPathComponent("ImportUndo.mstudio").path, audible: false)
        // A track that was there FIRST. If the bracket ever reached past the
        // gesture, this is what it would eat — and nothing else in the fixture
        // could tell.
        let seeded = await engine.send(.trackAdd(trackID: UUID().uuidString, name: "Mine", index: 0))
        XCTAssertTrue(seeded.ok, "track.add: \(seeded.message ?? "no message")")

        let vm = StudioViewModel(engine: engine)
        vm.startPolling()
        for _ in 0..<200 where vm.snapshot?.tracks.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        vm.stopPolling()
        let before = try XCTUnwrap(vm.snapshot, "the view model never adopted a snapshot")
        XCTAssertEqual(before.tracks.count, 1)
        let seededID = before.tracks[0].id

        let tonePath = try writeTone(named: "Some Song.wav")
        let landed = await vm.performImport(path: tonePath)
        XCTAssertTrue(landed, "the import did not land: \(vm.importStatus)")

        let afterSnap = await engine.snapshot(ifNewerThan: nil)
        let after = try XCTUnwrap(afterSnap)
        XCTAssertEqual(after.tracks.count, 2, "the gesture did not build a row")
        let made = try XCTUnwrap(after.tracks.first { $0.id != seededID })
        XCTAssertEqual(made.clips.count, 1, "the audio did not land on the row the gesture made")

        // ONE press of Cmd-Z.
        let undone = await engine.undo()
        XCTAssertTrue(undone, "there was nothing to undo")
        let restoredSnap = await engine.snapshot(ifNewerThan: nil)
        let restored = try XCTUnwrap(restoredSnap)
        XCTAssertFalse(restored.tracks.contains { $0.id == made.id }, """
            the empty row outlived the undo. That second Cmd-Z is the defect \
            this lane removes: `track.add` and the engine's import transaction \
            were two undo units, and the bracket in `performImport` plus the \
            re-entrant `OpenTxn` in timeline-core make them one.
            """)
        XCTAssertEqual(restored.tracks.map(\.id), [seededID],
                       "one undo did not restore the arrangement the import found")
        XCTAssertTrue(restored.tracks[0].clips.isEmpty, "one undo left a clip behind")

        // And a second Cmd-Z reaches PAST the gesture rather than finishing it:
        // it takes the seeded track, which is the proof the import was one unit
        // and not two.
        let again = await engine.undo()
        XCTAssertTrue(again, "the undo stack was empty one step too early")
        let pastSnap = await engine.snapshot(ifNewerThan: nil)
        let past = try XCTUnwrap(pastSnap)
        XCTAssertTrue(past.tracks.isEmpty,
                      "the second undo finished the import instead of reaching past it")
    }
}
#endif
