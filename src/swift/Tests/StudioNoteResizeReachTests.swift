import XCTest
@testable import MajiksMusicStudio

// `note.resize` existed in the catalog, was implemented, was journaled, had an
// inverse — and could be reached by exactly ONE gesture: grabbing the few
// points at the edge of a drawn note and dragging them.
//
// That is a fine gesture at a desk with a mouse. The owner drives this on a 4K
// television from a couch, where a fine-motor grab on a 3 pt edge is not a
// gesture at all. `handleKey` covered arrows, Cmd-U, `b`, `[`, `]` and `v`;
// there was no key, no menu item and no palette row. A command nobody can
// invoke is the same defect class as a control that does nothing — the app
// CAN change a note's length, and a person cannot ask it to.
//
// So this file asserts the three things that make it genuinely reachable:
//
//   1. One gesture is ONE journaled command, and undo restores the exact prior
//      length. (Not "a resize happened" — the length, to the tick.)
//   2. The KEY is wired to it. Asserting `resizeSelection` works would prove
//      nothing about whether anything calls it; this repo has shipped a palette
//      that listed 71 commands and wired 11.
//   3. It is offered by the palette rather than refused, which is the route a
//      person at couch distance actually has (Cmd-K, type "longer", Return).
//      `StudioPaletteReachTests` then holds that row to the bus like every
//      other; this file only asserts the decision moved.

@MainActor
final class StudioNoteResizeReachTests: XCTestCase {

    private let sig = StudioTimeSignature.fourFour
    private let clipStart: Int64 = 3840 * 2
    private let clipLength: Int64 = 3840 * 4
    /// One sixteenth at 4/4 with 960 ticks to the beat.
    private let step: Int64 = 240

    private func note(_ id: String, _ start: Int64, _ length: Int64, _ pitch: Int) -> StudioNote {
        StudioNote(id: id, startTicks: start, lengthTicks: length,
                   pitch: StudioNote.clampPitch(pitch), velocity: 100)
    }

    private func makeFixture(
        notes: [StudioNote]
    ) async -> (StudioPianoRollController, StudioMockNoteEngine) {
        let clipID = UUID(uuidString: "11111111-2222-4333-8444-666666666666")!
        let clip = StudioMidiClipSnapshot(
            id: clipID, trackID: UUID(), name: "Test",
            startTicks: clipStart, lengthTicks: clipLength,
            notes: StudioNote.sorted(notes), kind: .other)
        let engine = StudioMockNoteEngine(
            clip: clip,
            barGrid: StudioBarGrid(timeSignature: sig, phaseAnchorTicks: 0),
            tempoMap: .constant(bpm: 120))
        let controller = StudioPianoRollController(engine: engine)
        await controller.attach(clipID: clipID)
        controller.grid = .sixteenth
        return (controller, engine)
    }

    // MARK: - 1. One gesture, one journal entry, an exact inverse

    func testLengtheningTheSelectionJournalsExactlyOneResize() async {
        let (c, engine) = await makeFixture(notes: [note("a", 960, 480, 60)])
        c.selection = ["a"]

        c.resizeSelection(gridSteps: 1)
        await c.settle()

        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 1, "one keystroke wrote \(log.count) journal entries, so undo will not peel it back in one press")
        guard case .resize(_, let ids, let edge, let delta) = log[0] else {
            return XCTFail("expected a note.resize, got \(log[0].catalogName)")
        }
        XCTAssertEqual(ids, ["a"])
        XCTAssertEqual(edge, .trailing, "the keyboard lengthens from the END of the note; moving the start is what the arrows already do")
        XCTAssertEqual(delta, step)
        XCTAssertEqual(c.clip!.notes[0].lengthTicks, 480 + step)
        XCTAssertEqual(c.clip!.notes[0].startTicks, 960, "the note's start moved, so this shortened the wrong edge")
    }

    func testUndoRestoresTheExactPriorLength() async {
        let (c, _) = await makeFixture(notes: [note("a", 960, 480, 60)])
        c.selection = ["a"]
        let before = c.clip!.notes[0].lengthTicks

        c.resizeSelection(gridSteps: 3)
        await c.settle()
        XCTAssertNotEqual(c.clip!.notes[0].lengthTicks, before, "the resize changed nothing, so the undo below proves nothing")

        c.undo()
        await c.settle()
        XCTAssertEqual(c.clip!.notes[0].lengthTicks, before,
                       "one undo did not put the note back to its exact length")
        XCTAssertEqual(c.clip!.notes[0].startTicks, 960)
    }

    /// A chord shortens as a group and stops as one, exactly like a drag: the
    /// group clamp is the SAME `StudioNoteEdit.resizeDelta` the mouse uses, so
    /// the keyboard cannot squeeze a note below the minimum the mouse refuses to.
    func testAChordShortensAsOneGroupAndNeverBelowTheMinimum() async {
        let (c, engine) = await makeFixture(notes: [
            note("a", 960, 960, 60),
            note("b", 960, 240, 64),
        ])
        c.selection = ["a", "b"]

        // Ask for four steps SHORTER: "b" is only 240 ticks long, so the group
        // may only shrink until "b" hits the floor.
        c.resizeSelection(gridSteps: -4)
        await c.settle()

        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 1, "one keystroke on a two-note chord must be one undo step")
        XCTAssertGreaterThanOrEqual(
            c.clip!.notes.map(\.lengthTicks).min() ?? 0, StudioNoteEdit.minLengthTicks,
            "the keyboard squeezed a note below the minimum length the mouse refuses to go past")
        // Relative dynamics of the chord survive: both moved by the same delta.
        let lengths = c.clip!.notes.sorted { $0.pitch < $1.pitch }.map(\.lengthTicks)
        XCTAssertEqual(lengths[0] - lengths[1], 960 - 240,
                       "the two notes moved by different amounts, so the chord was pulled apart")
    }

    func testNothingSelectedWritesNothing() async {
        let (c, engine) = await makeFixture(notes: [note("a", 960, 480, 60)])
        c.selection = []
        c.resizeSelection(gridSteps: 1)
        await c.settle()
        let log = await engine.commandLog()
        XCTAssertTrue(log.isEmpty, "a stray keystroke reached a note the user was not pointing at")
    }

    func testAnOffGridRollRefusesRatherThanGuessingAStep() async {
        let (c, engine) = await makeFixture(notes: [note("a", 960, 480, 60)])
        c.selection = ["a"]
        c.grid = .off
        c.resizeSelection(gridSteps: 1)
        await c.settle()
        let log = await engine.commandLog()
        XCTAssertTrue(
            log.isEmpty,
            "with the grid Off there is no step to lengthen by, and the roll invented one")
    }

    // MARK: - 2. The key is wired

    /// The half that cannot be assumed. `resizeSelection` working says nothing
    /// about whether any keystroke calls it.
    func testShiftArrowsReachTheResizeAndPlainArrowsStillMove() async {
        let (c, engine) = await makeFixture(notes: [note("a", 960, 480, 60)])
        c.selection = ["a"]

        XCTAssertTrue(c.handleKey("", arrow: .right, shift: true, command: false),
                      "Shift-Right was not consumed by the roll")
        await c.settle()
        var log = await engine.commandLog()
        XCTAssertEqual(log.map(\.catalogName), ["note.resize"],
                       "Shift-Right did not reach note.resize; the only route to a note's length is still a 3 pt edge drag")
        XCTAssertEqual(c.clip!.notes[0].lengthTicks, 480 + step)

        XCTAssertTrue(c.handleKey("", arrow: .left, shift: true, command: false))
        await c.settle()
        log = await engine.commandLog()
        XCTAssertEqual(log.map(\.catalogName), ["note.resize", "note.resize"])
        XCTAssertEqual(c.clip!.notes[0].lengthTicks, 480, "Shift-Left did not shorten it back")

        // And the plain arrows are untouched: they still MOVE the note.
        let startBefore = c.clip!.notes[0].startTicks
        XCTAssertTrue(c.handleKey("", arrow: .right, shift: false, command: false))
        await c.settle()
        log = await engine.commandLog()
        XCTAssertEqual(log.map(\.catalogName), ["note.resize", "note.resize", "note.move"],
                       "the plain right arrow stopped moving the note; a resize binding took a move binding's key")
        XCTAssertEqual(c.clip!.notes[0].startTicks, startBefore + step)
        XCTAssertEqual(c.clip!.notes[0].lengthTicks, 480, "a plain arrow changed the note's LENGTH")
    }

    // MARK: - 3. Reachable from the palette

    func testThePaletteOffersNoteResizeRatherThanRefusingIt() {
        XCTAssertTrue(
            StudioPaletteCommands.all.contains { $0.name == "note.resize" },
            """
            note.resize is still absent from the palette. Cmd-K is the route a \
            person driving this from a couch actually has, and without a row \
            there the only way to change a note's length is a 3 pt edge drag.
            """)
        XCTAssertNil(
            StudioPaletteCommands.excluded["note.resize"],
            "note.resize is both offered and refused in writing; StudioPaletteReachTests partitions the catalog and one of the two is now a lie")
    }
}
