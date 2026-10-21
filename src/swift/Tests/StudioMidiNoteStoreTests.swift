import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// Where the arrangement's notes come from.
//
// NOT from `StudioProjectSnapshot`: that is polled at 30 Hz and rebuilt on every
// poll while the transport rolls, so notes on the snapshot would be decoded,
// allocated and `Equatable`-compared thirty times a second for every clip, and
// the only symptom would be a timeline that stutters during playback. Instead
// the store below reads the note seam the piano roll already uses, caches per
// clip, and gates re-reads on the project's journal revision — which a rolling
// transport does not move.
//
// These tests drive the REAL fetch path (`StudioMockNoteEngine`, which really
// applies and journals edits) rather than seeding the cache, so "an edit in the
// piano roll reaches the arrangement" is proven rather than asserted.
@MainActor
final class StudioMidiNoteStoreTests: XCTestCase {

    private let clipID = UUID()
    private let trackID = UUID()

    private func note(_ pitch: Int, _ beat: Double) -> StudioNote {
        StudioNote(
            id: String(format: "N%03d%03d", pitch, Int(beat * 10)),
            startTicks: Int64(beat * Double(StudioTick.ppq)),
            lengthTicks: Int64(StudioTick.ppq),
            pitch: StudioNote.clampPitch(pitch),
            velocity: 100)
    }

    private func engine(_ notes: [StudioNote]) -> StudioMockNoteEngine {
        StudioMockNoteEngine(clip: StudioMidiClipSnapshot(
            id: clipID, trackID: trackID, name: "piano",
            startTicks: 0, lengthTicks: 4 * StudioTimeSignature.fourFour.ticksPerBar,
            notes: StudioNote.sorted(notes), kind: .other))
    }

    /// Wait for the store's in-flight read to land. Bounded, and it asserts
    /// rather than silently proceeding — a test that gives up quietly is a test
    /// that passes for the wrong reason.
    private func settle(_ store: StudioMidiNoteStore, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if !store.hasPendingReads { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the note read never came back", file: file, line: line)
    }

    // MARK: The read

    func testAClipsNotesAreReadOffTheNoteSeamAndCached() async {
        let store = StudioMidiNoteStore()
        let engine = engine([note(48, 0), note(55, 1), note(60, 2)])

        XCTAssertEqual(store.content(for: clipID), .pending, "nothing has been read yet")

        store.request(clipID, projectRevision: 1, from: engine, now: 0)
        await settle(store)

        guard case .notes(let held) = store.content(for: clipID) else {
            return XCTFail("the arrangement still has no notes for a clip that has three: \(store.content(for: clipID))")
        }
        XCTAssertEqual(held.notes.count, 3)
        XCTAssertEqual(held.lowPitch, 48)
        XCTAssertEqual(held.highPitch, 60)
        XCTAssertEqual(store.cachedClipCount, 1)
    }

    func testAClipWithNoNotesReadsAsEmptyNotAsUnread() async {
        let store = StudioMidiNoteStore()
        store.request(clipID, projectRevision: 1, from: engine([]), now: 0)
        await settle(store)

        XCTAssertEqual(
            store.content(for: clipID), .empty,
            "a clip the engine says has no notes must read as EMPTY, not as 'not read yet' — telling those two apart is the point of the whole change")
    }

    // MARK: The staleness gate (why playback is free)

    func testACachedClipIsNotReReadWhileTheProjectHasNotMoved() async {
        let store = StudioMidiNoteStore()
        let engine = engine([note(48, 0)])
        store.request(clipID, projectRevision: 4, from: engine, now: 0)
        await settle(store)

        // A rolling transport repaints this canvas continuously and does NOT
        // move the journal revision. Every one of those frames must cost a
        // dictionary lookup and no engine call.
        for frame in 0..<120 {
            store.request(clipID, projectRevision: 4, from: engine, now: Double(frame) * 10)
            XCTAssertFalse(
                store.hasPendingReads,
                "frame \(frame) armed another note read on an unchanged project: the arrangement is hitting the engine once per frame during playback")
        }
    }

    func testAnEditInThePianoRollReachesTheArrangement() async {
        let store = StudioMidiNoteStore()
        let engine = engine([note(48, 0), note(55, 1)])
        store.request(clipID, projectRevision: 1, from: engine, now: 0)
        await settle(store)
        guard case .notes(let before) = store.content(for: clipID) else {
            return XCTFail("first read produced nothing")
        }
        XCTAssertEqual(before.notes.count, 2)

        // A real journaled note.add on the real mock engine, exactly as the
        // piano roll would send it.
        let added = await engine.send(.add(clipID: clipID, notes: [note(72, 3)]))
        XCTAssertTrue(added.ok, added.message ?? "")

        // The project's revision has moved; the next frame re-reads.
        store.request(clipID, projectRevision: 2, from: engine, now: 100)
        await settle(store)

        guard case .notes(let after) = store.content(for: clipID) else {
            return XCTFail("the re-read produced nothing")
        }
        XCTAssertEqual(
            after.notes.count, 3,
            "a note drawn in the piano roll never appeared in the arrangement: the store is caching forever instead of following the journal revision")
        XCTAssertEqual(after.highPitch, 72, "the cached pitch range did not follow the new note")
    }

    func testTwoReadsForTheSameClipAreNotArmedAtOnce() async {
        let store = StudioMidiNoteStore()
        let engine = engine([note(48, 0)])
        store.request(clipID, projectRevision: 1, from: engine, now: 0)
        XCTAssertTrue(store.hasPendingReads)
        // Same frame, same clip, drawn again (selection ghost, a second pass):
        // the in-flight guard must swallow it.
        store.request(clipID, projectRevision: 1, from: engine, now: 0)
        store.request(clipID, projectRevision: 1, from: engine, now: 0)
        await settle(store)
        XCTAssertEqual(store.cachedClipCount, 1)
    }

    func testRepeatedRevisionBumpsDoNotStackUpReads() async {
        // A gesture that journals continuously — a fader drag, a note drag —
        // bumps the revision on every command. Without a floor on the refetch
        // interval each bump would arm another whole-project read.
        let store = StudioMidiNoteStore()
        let engine = engine([note(48, 0)])
        store.request(clipID, projectRevision: 1, from: engine, now: 0)
        await settle(store)

        for bump in 2...40 {
            store.request(clipID, projectRevision: UInt64(bump), from: engine, now: 0.001 * Double(bump))
            XCTAssertFalse(
                store.hasPendingReads,
                "revision bump \(bump) armed a read inside the refetch window: a continuous edit gesture would issue a whole-project read per command")
        }
    }

    // MARK: No note seam at all

    func testAnEngineWithNoNoteSeamLeavesTheClipHonestlyUnread() async {
        // StudioMockEngine does not conform to the note seam (and never
        // produces a MIDI clip either). The arrangement must say "I do not
        // know", not invent notes.
        let store = StudioMidiNoteStore()
        store.request(clipID, projectRevision: 1, from: nil, now: 0)
        XCTAssertFalse(store.hasPendingReads)
        XCTAssertEqual(store.content(for: clipID), .pending)
        XCTAssertEqual(store.cachedClipCount, 0)
    }

    func testTheViewModelFindsTheNoteSeamOnlyWhenTheEngineHasOne() {
        // The mock build's honest answer. On a real-engine build this is the
        // SAME actor as `engine`, which is what makes a clip UUID mean the same
        // thing to the arrangement and to the piano roll.
        let model = StudioViewModel(engine: StudioMockEngine())
        XCTAssertNil(
            model.noteEngine,
            "StudioMockEngine appears to have grown a note seam; if that is deliberate the arrangement should be reading notes from it in a mock build too")
    }
}
