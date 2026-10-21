import XCTest
@testable import MajiksMusicStudio

// Lane E1-ui: piano-roll INTERACTIONS, driven end to end.
//
// Each test presses, drags and releases at real points on a real layout, then
// asserts against the ENGINE'S JOURNAL — not against view state. That is what
// makes "every mutation is a journaled command" a proven property rather than a
// convention: if any edit path ever pokes the model directly, the journal comes
// back empty and these fail.
//
// Still out of reach without a GUI: whether the drag FEELS right. These prove
// the numbers, not the tactility.

@MainActor
final class StudioPianoRollInteractionTests: XCTestCase {

    private let sig = StudioTimeSignature.fourFour
    private let bar: Int64 = 3840
    private let clipStart: Int64 = 3840 * 2
    private let clipLength: Int64 = 3840 * 4
    private let viewSize = CGSize(width: 900, height: 500)

    private func note(
        _ id: String, _ start: Int64, _ length: Int64, _ pitch: Int, _ velocity: Int = 100
    ) -> StudioNote {
        StudioNote(id: id, startTicks: start, lengthTicks: length,
                   pitch: StudioNote.clampPitch(pitch), velocity: velocity)
    }

    private func makeFixture(
        notes: [StudioNote],
        phaseAnchorTicks: Int64 = 0
    ) async -> (StudioPianoRollController, StudioMockNoteEngine) {
        let clipID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let clip = StudioMidiClipSnapshot(
            id: clipID, trackID: UUID(), name: "Test",
            startTicks: clipStart, lengthTicks: clipLength,
            notes: StudioNote.sorted(notes), kind: .other)
        let engine = StudioMockNoteEngine(
            clip: clip,
            barGrid: StudioBarGrid(timeSignature: sig, phaseAnchorTicks: phaseAnchorTicks),
            tempoMap: .constant(bpm: 120))
        let controller = StudioPianoRollController(engine: engine)
        await controller.attach(clipID: clipID)
        controller.pxPerTick = 0.1
        controller.rowHeight = 14
        controller.scrollTicks = clipStart
        controller.scrollY = CGFloat(127 - 84) * 14      // pitches 84 down to ~55 visible
        controller.grid = .sixteenth
        return (controller, engine)
    }

    /// A controller whose clip has NOT been adopted yet — the state the roll is
    /// really in the moment it appears, because the engine answers the first poll
    /// a frame or more after the view has measured itself.
    private func makeUnattached(notes: [StudioNote]) -> (StudioPianoRollController, UUID) {
        let clipID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let clip = StudioMidiClipSnapshot(
            id: clipID, trackID: UUID(), name: "Instrument 1",
            startTicks: clipStart, lengthTicks: clipLength,
            notes: StudioNote.sorted(notes), kind: .other)
        let engine = StudioMockNoteEngine(
            clip: clip,
            barGrid: StudioBarGrid(timeSignature: sig),
            tempoMap: .constant(bpm: 120))
        let controller = StudioPianoRollController(engine: engine)
        controller.rowHeight = 14
        return (controller, clipID)
    }

    private func layout(_ c: StudioPianoRollController) -> StudioPianoRollLayout {
        c.layout(for: viewSize)
    }

    /// A point over a clip-relative tick and a pitch, nudged into the middle of
    /// the row so it is unambiguous.
    private func point(
        _ c: StudioPianoRollController, clipTicks: Int64, pitch: Int, yOffset: CGFloat = 7
    ) -> CGPoint {
        let l = layout(c)
        return CGPoint(
            x: l.x(forTicks: clipStart + clipTicks),
            y: l.y(forPitch: StudioNote.clampPitch(pitch)) + yOffset)
    }

    private func drag(
        _ c: StudioPianoRollController,
        from: CGPoint, to: CGPoint,
        modifiers: StudioNoteModifiers = .none
    ) async {
        let l = layout(c)
        c.press(at: from, modifiers: modifiers, layout: l)
        c.dragged(to: to, modifiers: modifiers, layout: l)
        c.released(at: to, modifiers: modifiers, layout: l)
        await c.settle()
    }

    // MARK: - Draw

    func testDrawDragEmitsExactlyOneJournaledAddWithASnappedStart() async {
        let (c, engine) = await makeFixture(notes: [])
        c.tool = .draw
        // Press slightly after the 1/16 line at 480, drag out to ~1440.
        await drag(c, from: point(c, clipTicks: 500, pitch: 64),
                   to: point(c, clipTicks: 1450, pitch: 64))

        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 1, "a draw is ONE journal entry")
        guard case .add(_, let added) = log[0] else { return XCTFail("expected note.add, got \(log[0])") }
        XCTAssertEqual(added.count, 1)
        // Draw snaps DOWN to the line at or before the press, so the note starts
        // on the beat you clicked in, not the next one.
        XCTAssertEqual(added[0].startTicks, 480)
        XCTAssertEqual(added[0].pitch, 64)
        XCTAssertEqual(added[0].velocity, c.drawVelocity)
        XCTAssertEqual(c.clip?.notes.count, 1)
        XCTAssertEqual(c.selection, [added[0].id])
    }

    func testAQuickDrawClickGetsTheGridLength() async {
        let (c, _) = await makeFixture(notes: [])
        c.tool = .draw
        c.grid = .eighth
        let p = point(c, clipTicks: 960, pitch: 60)
        await drag(c, from: p, to: p)
        XCTAssertEqual(c.clip?.notes.first?.lengthTicks, 480)   // one eighth
    }

    func testDrawHonorsThePhaseAnchoredBarGrid() async {
        // Half-bar lead-in: 1/16 lines sit at 1920 + n*240 in ABSOLUTE ticks,
        // which is clip-relative 1920+n*240 - clipStart. A note drawn near a
        // naive line must land on the anchored one.
        // The anchor is deliberately NOT a multiple of the beat: with a 1920
        // lead-in the anchored lines would coincide with the naive ones and the
        // test would pass without proving anything.
        let (c, engine) = await makeFixture(notes: [], phaseAnchorTicks: 1000)
        c.tool = .draw
        c.grid = .quarter
        let targetAbsolute: Int64 = 1000 + 960 * 8            // an anchored beat line
        let clipRelative = targetAbsolute - clipStart
        await drag(c, from: point(c, clipTicks: clipRelative + 40, pitch: 62),
                   to: point(c, clipTicks: clipRelative + 40, pitch: 62))
        let log = await engine.commandLog()
        guard case .add(_, let added) = log[0] else { return XCTFail("expected add") }
        XCTAssertEqual(added[0].startTicks + clipStart, targetAbsolute)
        // ...and NOT on the naive grid line.
        XCTAssertNotEqual((added[0].startTicks + clipStart) % 960, 0)
    }

    // MARK: - Select

    func testClickSelectsShiftAddsAndShiftDeselects() async {
        let (c, _) = await makeFixture(notes: [
            note("a", 0, 480, 60), note("b", 960, 480, 64),
        ])
        let l = layout(c)
        c.press(at: point(c, clipTicks: 100, pitch: 60), modifiers: .none, layout: l)
        c.released(at: point(c, clipTicks: 100, pitch: 60), modifiers: .none, layout: l)
        XCTAssertEqual(c.selection, ["a"])

        let shift = StudioNoteModifiers(shift: true)
        c.press(at: point(c, clipTicks: 1000, pitch: 64), modifiers: shift, layout: l)
        c.released(at: point(c, clipTicks: 1000, pitch: 64), modifiers: shift, layout: l)
        XCTAssertEqual(c.selection, ["a", "b"])

        c.press(at: point(c, clipTicks: 1000, pitch: 64), modifiers: shift, layout: l)
        XCTAssertEqual(c.selection, ["a"], "shift-click on a selected note removes it")
        XCTAssertEqual(c.drag.kind, .none, "and starts no drag")
    }

    func testMarqueeSelectsAcrossPitchesAndClickingEmptySpaceClears() async {
        let (c, _) = await makeFixture(notes: [
            note("a", 0, 480, 60), note("b", 240, 480, 64), note("c", 3000, 480, 70),
        ])
        await drag(c, from: point(c, clipTicks: 60, pitch: 68, yOffset: 0),
                   to: point(c, clipTicks: 900, pitch: 58, yOffset: 0))
        XCTAssertEqual(c.selection, ["a", "b"])

        // A click on empty space clears.
        let p = point(c, clipTicks: 3600, pitch: 58)
        await drag(c, from: p, to: p)
        XCTAssertTrue(c.selection.isEmpty)
    }

    func testSelectAllAndDeleteRoundTripThroughOneCommandAndOneUndo() async {
        let (c, engine) = await makeFixture(notes: [
            note("a", 0, 480, 60), note("b", 240, 480, 64), note("c", 480, 480, 67),
        ])
        c.selectAll()
        XCTAssertEqual(c.selection.count, 3)
        c.deleteSelection()
        await c.settle()
        XCTAssertEqual(c.clip?.notes.count, 0)

        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 1, "deleting a selection is ONE journal entry")
        XCTAssertEqual(log[0].catalogName, "note.remove")

        c.undo()
        await c.settle()
        XCTAssertEqual(c.clip?.notes.count, 3)
        XCTAssertEqual(c.clip?.notes.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(c.clip?.notes.map(\.startTicks), [0, 240, 480])
    }

    // MARK: - Move

    func testChordDragEmitsOneMoveAndKeepsItsVoicing() async {
        let (c, engine) = await makeFixture(notes: [
            note("a", 960, 480, 60), note("b", 960, 480, 64), note("c", 960, 480, 67),
        ])
        c.selection = ["a", "b", "c"]
        // Grab the bottom note and drag a beat right and two semitones up.
        await drag(c, from: point(c, clipTicks: 1100, pitch: 60),
                   to: point(c, clipTicks: 2060, pitch: 62))

        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 1, "one drag, one journal entry")
        guard case .move(_, let ids, let dt, let dp) = log[0] else {
            return XCTFail("expected note.move, got \(log[0])")
        }
        XCTAssertEqual(Set(ids), ["a", "b", "c"])
        XCTAssertEqual(dt, 960)
        XCTAssertEqual(dp, 2)

        let notes = c.clip!.notes
        XCTAssertEqual(notes.map(\.startTicks), [1920, 1920, 1920])
        XCTAssertEqual(notes.map { Int($0.pitch) }.sorted(), [62, 66, 69])

        c.undo()
        await c.settle()
        XCTAssertEqual(c.clip!.notes.map(\.startTicks), [960, 960, 960])
        XCTAssertEqual(c.clip!.notes.map { Int($0.pitch) }.sorted(), [60, 64, 67])
    }

    func testAMoveThatEndsWhereItStartedJournalsNothing() async {
        let (c, engine) = await makeFixture(notes: [note("a", 960, 480, 60)])
        c.selection = ["a"]
        let p = point(c, clipTicks: 1100, pitch: 60)
        await drag(c, from: p, to: p)
        let log = await engine.commandLog()
        XCTAssertTrue(log.isEmpty, "a no-op drag must not write an empty undo step")
    }

    func testCommandBypassesTheGridAndLandsOffTheLine() async {
        let (c, engine) = await makeFixture(notes: [note("a", 960, 480, 60)])
        c.selection = ["a"]
        let bypass = StudioNoteModifiers(command: true)
        await drag(c, from: point(c, clipTicks: 1200, pitch: 60),
                   to: point(c, clipTicks: 1297, pitch: 60), modifiers: bypass)
        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 1)
        let start = c.clip!.notes[0].startTicks
        XCTAssertNotEqual(start % 240, 0, "⌘ should have bypassed the 1/16 grid, got \(start)")
        XCTAssertEqual(start, 960 + 97)
    }

    func testMidDragTheDisplayedNotesAreTheDraggedOnes() async {
        // "What you see is what you grab": drawing and hit-testing both read
        // displayNotes(), so the provisional position is grabbable mid-drag.
        let (c, _) = await makeFixture(notes: [note("a", 960, 960, 60)])
        c.selection = ["a"]
        let l = layout(c)
        // Press in the BODY: x within the note but clear of either grab zone.
        c.press(at: point(c, clipTicks: 1400, pitch: 60), modifiers: .none, layout: l)
        XCTAssertEqual(c.drag.kind, .move)
        c.dragged(to: point(c, clipTicks: 2400, pitch: 63), modifiers: .none, layout: l)

        let shown = c.displayNotes()
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].startTicks, 1920)
        XCTAssertEqual(shown[0].pitch, 63)
        // The engine has NOT been told yet — the roll is showing a provisional.
        XCTAssertEqual(c.clip!.notes[0].startTicks, 960)
        XCTAssertEqual(c.clip!.notes[0].pitch, 60)

        c.cancelDrag()
        XCTAssertEqual(c.displayNotes()[0].startTicks, 960, "escape abandons the provisional")
    }

    func testEscapeDuringADragJournalsNothing() async {
        let (c, engine) = await makeFixture(notes: [note("a", 960, 480, 60)])
        c.selection = ["a"]
        let l = layout(c)
        c.press(at: point(c, clipTicks: 1200, pitch: 60), modifiers: .none, layout: l)
        c.dragged(to: point(c, clipTicks: 2200, pitch: 65), modifiers: .none, layout: l)
        c.cancelDrag()
        await c.settle()
        let afterEscape = await engine.commandLog()
        XCTAssertTrue(afterEscape.isEmpty)
        XCTAssertEqual(c.clip!.notes[0].startTicks, 960)
    }

    // MARK: - Resize

    func testResizingFromTheTrailingEdgeEmitsOneResize() async {
        let (c, engine) = await makeFixture(notes: [note("a", 960, 480, 60)])
        c.selection = ["a"]
        let l = layout(c)
        // Grab within the trailing grab zone of the drawn rect.
        let rect = l.rect(for: c.clip!.notes[0], clipOriginTicks: clipStart)
        let grab = CGPoint(x: rect.maxX - 2, y: rect.midY)
        c.press(at: grab, modifiers: .none, layout: l)
        XCTAssertEqual(c.drag.kind, .resizeTrailing)
        c.dragged(to: point(c, clipTicks: 1930, pitch: 60), modifiers: .none, layout: l)
        c.released(at: point(c, clipTicks: 1930, pitch: 60), modifiers: .none, layout: l)
        await c.settle()

        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 1)
        guard case .resize(_, _, let edge, _) = log[0] else { return XCTFail("expected resize") }
        XCTAssertEqual(edge, .trailing)
        XCTAssertEqual(c.clip!.notes[0].startTicks, 960, "the far edge must not move")
        XCTAssertEqual(c.clip!.notes[0].endTicks, 1920)
    }

    func testResizingFromTheLeadingEdgeMovesOnlyTheStart() async {
        let (c, engine) = await makeFixture(notes: [note("a", 960, 960, 60)])
        c.selection = ["a"]
        let l = layout(c)
        let rect = l.rect(for: c.clip!.notes[0], clipOriginTicks: clipStart)
        c.press(at: CGPoint(x: rect.minX + 2, y: rect.midY), modifiers: .none, layout: l)
        XCTAssertEqual(c.drag.kind, .resizeLeading)
        c.dragged(to: point(c, clipTicks: 490, pitch: 60), modifiers: .none, layout: l)
        c.released(at: point(c, clipTicks: 490, pitch: 60), modifiers: .none, layout: l)
        await c.settle()

        let leadingLog = await engine.commandLog()
        XCTAssertEqual(leadingLog.count, 1)
        XCTAssertEqual(c.clip!.notes[0].startTicks, 480)
        XCTAssertEqual(c.clip!.notes[0].endTicks, 1920, "the trailing edge stayed put")

        c.undo()
        await c.settle()
        XCTAssertEqual(c.clip!.notes[0].startTicks, 960)
        XCTAssertEqual(c.clip!.notes[0].lengthTicks, 960)
    }

    func testATinyNoteIsStillResizableFromItsTrailingEdge() async {
        // A 1/32 note at this zoom draws ~12 px wide: below the two-edge
        // threshold, so it gets one edge and stays fully editable.
        let (c, _) = await makeFixture(notes: [note("a", 960, 120, 60)])
        c.selection = ["a"]
        let l = layout(c)
        let rect = l.rect(for: c.clip!.notes[0], clipOriginTicks: clipStart)
        XCTAssertLessThan(rect.width, StudioPianoRollGeometry.twoEdgeMinWidth)
        c.press(at: CGPoint(x: rect.maxX - 1, y: rect.midY), modifiers: .none, layout: l)
        XCTAssertEqual(c.drag.kind, .resizeTrailing)
        c.cancelDrag()
        // ...and the left half still moves it.
        c.press(at: CGPoint(x: rect.minX + 1, y: rect.midY), modifiers: .none, layout: l)
        XCTAssertEqual(c.drag.kind, .move)
    }

    // MARK: - Duplicate

    func testOptionDragCopiesInsteadOfMoving() async {
        let (c, engine) = await makeFixture(notes: [
            note("a", 960, 480, 60), note("b", 960, 480, 64),
        ])
        c.selection = ["a", "b"]
        await drag(c, from: point(c, clipTicks: 1200, pitch: 60),
                   to: point(c, clipTicks: 2160, pitch: 60),
                   modifiers: StudioNoteModifiers(option: true))

        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].catalogName, "note.duplicate")
        XCTAssertEqual(c.clip!.notes.count, 4, "the originals stayed put")
        XCTAssertEqual(c.clip!.notes.filter { $0.startTicks == 960 }.count, 2)
        XCTAssertEqual(c.clip!.notes.filter { $0.startTicks == 1920 }.count, 2)
        XCTAssertEqual(c.selection.count, 2, "the copies are what stays selected")

        c.undo()
        await c.settle()
        XCTAssertEqual(c.clip!.notes.count, 2)
    }

    func testDuplicateSelectionLandsAfterTheSelectionSpan() async {
        let (c, engine) = await makeFixture(notes: [
            note("a", 0, 480, 60), note("b", 480, 480, 64),
        ])
        c.selectAll()
        c.grid = .quarter
        c.duplicateSelection()
        await c.settle()
        let dupLog = await engine.commandLog()
        XCTAssertEqual(dupLog.count, 1)
        XCTAssertEqual(c.clip!.notes.count, 4)
        // Span is 960; at a quarter grid the copies land exactly one beat on.
        XCTAssertEqual(c.clip!.notes.map(\.startTicks), [0, 480, 960, 1440])
    }

    // MARK: - Velocity

    func testDraggingAVelocityStemEmitsOneVelocityCommand() async {
        let (c, engine) = await makeFixture(notes: [
            note("a", 960, 480, 60, 60), note("b", 960, 480, 64, 90),
        ])
        c.selection = ["a", "b"]
        let l = layout(c)
        let stem = CGPoint(x: l.x(forTicks: clipStart + 960), y: l.velocityY(60))
        c.press(at: stem, modifiers: .none, layout: l)
        XCTAssertEqual(c.drag.kind, .velocity)
        let target = CGPoint(x: stem.x, y: l.velocityY(80))
        c.dragged(to: target, modifiers: .none, layout: l)
        c.released(at: target, modifiers: .none, layout: l)
        await c.settle()

        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].catalogName, "note.velocity.set")
        let velocities = c.clip!.notes.sorted { $0.pitch < $1.pitch }.map(\.velocity)
        XCTAssertEqual(velocities, [80, 110], "the group moved together, keeping its dynamics")

        c.undo()
        await c.settle()
        XCTAssertEqual(
            c.clip!.notes.sorted { $0.pitch < $1.pitch }.map(\.velocity), [60, 90])
    }

    func testVelocityNudgeIsAlsoJournaled() async {
        let (c, engine) = await makeFixture(notes: [note("a", 0, 480, 60, 100)])
        c.selection = ["a"]
        c.nudgeVelocity(by: -20)
        await c.settle()
        let velLog = await engine.commandLog()
        XCTAssertEqual(velLog.count, 1)
        XCTAssertEqual(c.clip!.notes[0].velocity, 80)
    }

    // MARK: - Keyboard

    func testArrowNudgesAreJournaledCommandsToo() async {
        let (c, engine) = await makeFixture(notes: [
            note("a", 960, 480, 60), note("b", 1200, 480, 64),
        ])
        c.selectAll()
        c.grid = .sixteenth
        c.handleKey("", arrow: .right, shift: false, command: false)
        await c.settle()
        XCTAssertEqual(c.clip!.notes.map(\.startTicks), [1200, 1440])

        c.handleKey("", arrow: .up, shift: true, command: false)   // octave
        await c.settle()
        XCTAssertEqual(c.clip!.notes.map { Int($0.pitch) }.sorted(), [72, 76])

        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 2)
        XCTAssertTrue(log.allSatisfy { $0.catalogName == "note.move" })
    }

    func testGridAndToolShortcutsAreConsumed() async {
        let (c, _) = await makeFixture(notes: [])
        XCTAssertTrue(c.handleKey("b", arrow: nil, shift: false, command: false))
        XCTAssertEqual(c.tool, .draw)
        XCTAssertTrue(c.handleKey("b", arrow: nil, shift: false, command: false))
        XCTAssertEqual(c.tool, .select)

        c.grid = .quarter
        XCTAssertTrue(c.handleKey("]", arrow: nil, shift: false, command: false))
        XCTAssertEqual(c.grid, .eighthTriplet)
        XCTAssertTrue(c.handleKey("[", arrow: nil, shift: false, command: false))
        XCTAssertEqual(c.grid, .quarter)

        XCTAssertFalse(c.handleKey("q", arrow: nil, shift: false, command: false))
    }

    // MARK: - Redo, and the undo stack depth the toolbar reads

    func testUndoRedoDepthsTrackTheJournal() async {
        let (c, _) = await makeFixture(notes: [note("a", 0, 480, 60)])
        XCTAssertFalse(c.canUndo)
        c.selection = ["a"]
        c.nudgeSelection(gridSteps: 1, semitones: 0)
        await c.settle()
        XCTAssertTrue(c.canUndo)
        XCTAssertFalse(c.canRedo)

        c.undo()
        await c.settle()
        XCTAssertFalse(c.canUndo)
        XCTAssertTrue(c.canRedo)
        XCTAssertEqual(c.clip!.notes[0].startTicks, 0)

        c.redo()
        await c.settle()
        XCTAssertEqual(c.clip!.notes[0].startTicks, 240)
        XCTAssertTrue(c.canUndo)
    }

    func testRepeatedUndoWalksTheWholeHistoryBack() async {
        let (c, _) = await makeFixture(notes: [note("a", 0, 480, 60, 100)])
        c.selection = ["a"]
        c.nudgeSelection(gridSteps: 2, semitones: 0)
        await c.settle()
        c.nudgeSelection(gridSteps: 0, semitones: 3)
        await c.settle()
        c.nudgeVelocity(by: 20)
        await c.settle()
        XCTAssertEqual(c.clip!.notes[0].startTicks, 480)
        XCTAssertEqual(Int(c.clip!.notes[0].pitch), 63)
        XCTAssertEqual(c.clip!.notes[0].velocity, 120)

        for _ in 0..<3 { c.undo(); await c.settle() }
        let restored = c.clip!.notes[0]
        XCTAssertEqual(restored.startTicks, 0)
        XCTAssertEqual(Int(restored.pitch), 60)
        XCTAssertEqual(restored.velocity, 100)
        XCTAssertFalse(c.canUndo)
    }

    // MARK: - Ruler scrub + play head

    func testScrubbingTheRulerSeeksAndNeverEdits() async {
        let (c, engine) = await makeFixture(notes: [note("a", 0, 480, 60)])
        var seeks: [Int64] = []
        c.onSeek = { seeks.append($0) }
        let l = layout(c)
        let inRuler = CGPoint(x: l.x(forTicks: clipStart + 1920), y: 8)
        c.press(at: inRuler, modifiers: .none, layout: l)
        c.dragged(to: CGPoint(x: inRuler.x + 40, y: 8), modifiers: .none, layout: l)
        c.released(at: CGPoint(x: inRuler.x + 40, y: 8), modifiers: .none, layout: l)
        await c.settle()
        XCTAssertEqual(seeks.first, clipStart + 1920)
        XCTAssertEqual(seeks.count, 2)
        let scrubLog = await engine.commandLog()
        XCTAssertTrue(scrubLog.isEmpty, "scrubbing is not an edit")
    }

    func testGutterPressAuditionsAndNeverEdits() async {
        let (c, engine) = await makeFixture(notes: [])
        var previews: [UInt8] = []
        c.onPreview = { pitch, _ in previews.append(pitch) }
        let l = layout(c)
        c.press(at: CGPoint(x: 20, y: l.y(forPitch: 67) + 5), modifiers: .none, layout: l)
        XCTAssertEqual(previews, [67])
        XCTAssertEqual(c.drag.kind, .none)
        let gutterLog = await engine.commandLog()
        XCTAssertTrue(gutterLog.isEmpty)
    }

    func testPlayheadUsesTheTempoMapNotTheDeclaredBpm() async {
        let clipID = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!
        let clip = StudioMidiClipSnapshot(
            id: clipID, trackID: UUID(), name: "T",
            startTicks: 0, lengthTicks: bar * 8, notes: [], kind: .other)
        let engine = StudioMockNoteEngine(
            clip: clip, barGrid: StudioBarGrid(),
            tempoMap: .from(changes: [(0, 120), (bar * 2, 60)]),
            transport: StudioTransportSnapshot(
                isPlaying: true, positionTicks: bar, capturedAtHostTime: 0, loopRegion: nil))
        let c = StudioPianoRollController(engine: engine)
        await c.attach(clipID: clipID)

        // The transport reported bar 1 (= 2 s of audio). The tempo change lands
        // at 4 s, so 2 of the 5 elapsed seconds run at 120 and 3 at 60.
        let landed = c.playheadTicks(now: 5.0)
        XCTAssertEqual(landed, bar * 2 + 2880)
        let naive = bar + Int64(5.0 * 120.0 / 60.0 * Double(StudioTick.ppq))
        XCTAssertNotEqual(landed, naive, "the play head must not use naive BPM math")
    }

    // MARK: - Framing

    func testOpeningAClipFramesItsNotesInsteadOfLandingOnEmptyAir() async {
        let (c, _) = await makeFixture(notes: [
            note("a", 0, 480, 60), note("b", 960, 480, 72),
        ])
        c.scrollY = 0                       // as if it opened at the top of the keyboard
        let l = layout(c)
        c.fitToContent(layout: l)
        let fitted = layout(c)
        // Every note is inside the visible pitch window after fitting.
        for n in c.clip!.notes {
            XCTAssertTrue(
                fitted.visiblePitchRange.contains(n.pitch),
                "pitch \(n.pitch) not framed by \(fitted.visiblePitchRange)")
        }
        XCTAssertEqual(c.scrollTicks, clipStart)
    }

    func testAnEmptyClipOpensCentredOnMiddleCNotTheTopOfTheKeyboard() async {
        // The Instrument button's clip: brand new, no notes. There is nothing to
        // frame, so the roll has to land somewhere PLAYABLE on its own judgement.
        // Opening at the top of the keyboard makes the first note you draw a C8.
        let (c, _) = await makeFixture(notes: [])
        c.scrollY = 0
        c.fitToContent(layout: layout(c))
        let fitted = layout(c)
        XCTAssertEqual(
            fitted.pitch(forY: fitted.noteRect.midY), 60,
            "an empty clip opens with middle C in the middle of the roll")
    }

    func testFittingCentresTheNotesWhenTheZoomClampCapsTheRowHeight() async throws {
        // A tall window and a narrow note span: `clampRowHeight` caps the zoom, so
        // the fitted window ends up far taller than the notes need. Hanging the
        // span from `high + 2` drops every one of those spare rows underneath the
        // notes and leaves them pinned near the top edge.
        let (c, _) = await makeFixture(notes: [
            note("a", 0, 480, 60), note("b", 960, 480, 62),
        ])
        c.velocityLaneShown = false
        let tall = CGSize(width: 900, height: 800)
        c.fitToContent(layout: c.layout(for: tall))

        XCTAssertEqual(
            c.rowHeight, StudioPianoRollLayout.maxRowHeight,
            "the zoom clamp is the condition this test exists for")
        let fitted = c.layout(for: tall)
        let centre = try XCTUnwrap(fitted.pitch(forY: fitted.noteRect.midY))
        XCTAssertTrue(
            (60...62).contains(Int(centre)),
            "the notes sit in the middle of the fitted window, not against its top edge (got \(centre))")
    }

    func testTheFitRunsWhenTheClipArrivesAfterTheViewHasMeasured() async {
        // The real order for the Instrument button: the roll is put on screen and
        // measures itself BEFORE the poll hands back the clip it was opened on.
        // A fit armed only at onAppear therefore never runs at all, and the roll
        // sits at scrollY 0 — the top of the keyboard — for the whole session.
        let (c, clipID) = makeUnattached(notes: [])
        XCTAssertNil(c.clip)
        c.autoFitIfNeeded(layout: c.layout(for: viewSize))
        XCTAssertEqual(c.scrollY, 0, "nothing to frame before the clip lands")

        await c.attach(clipID: clipID)          // the poll delivers the clip

        let fitted = c.layout(for: viewSize)
        XCTAssertEqual(
            fitted.pitch(forY: fitted.noteRect.midY), 60,
            "the fit must run when the clip lands, not only when the view appears")
    }

    func testAClipThatArrivesLateWithNotesFramesThoseNotesNotMiddleC() async throws {
        // Same late arrival, but the clip already has notes: the empty-clip
        // fallback must not win over real content. The notes sit deliberately far
        // from middle C so the two outcomes cannot be confused.
        let (c, clipID) = makeUnattached(notes: [
            note("a", 0, 480, 84), note("b", 960, 480, 91),
        ])
        c.autoFitIfNeeded(layout: c.layout(for: viewSize))
        await c.attach(clipID: clipID)

        let fitted = c.layout(for: viewSize)
        for n in c.clip!.notes {
            XCTAssertTrue(
                fitted.visiblePitchRange.contains(n.pitch),
                "pitch \(n.pitch) not framed by \(fitted.visiblePitchRange)")
        }
        let centre = try XCTUnwrap(fitted.pitch(forY: fitted.noteRect.midY))
        XCTAssertTrue(
            (84...91).contains(Int(centre)),
            "a clip with notes centres on ITS notes, not on middle C (got \(centre))")
    }

    // MARK: - The house rule, checked directly

    func testEveryMutatingPathGoesThroughTheCommandBus() async {
        // One test that sweeps the whole edit surface: after exercising each
        // path, the number of journal entries equals the number of edits made.
        // If any path ever mutated the model directly, this count drops.
        let (c, engine) = await makeFixture(notes: [note("a", 960, 480, 60, 100)])
        c.selection = ["a"]

        c.nudgeSelection(gridSteps: 1, semitones: 0); await c.settle()          // 1 move
        c.nudgeVelocity(by: 5); await c.settle()                                // 2 velocity
        c.duplicateSelection(); await c.settle()                                // 3 duplicate
        c.selectAll()
        c.deleteSelection(); await c.settle()                                   // 4 remove
        c.tool = .draw
        await drag(c, from: point(c, clipTicks: 480, pitch: 62),
                   to: point(c, clipTicks: 1000, pitch: 62))                    // 5 add

        let log = await engine.commandLog()
        XCTAssertEqual(log.map(\.catalogName), [
            "note.move", "note.velocity.set", "note.duplicate", "note.remove", "note.add",
        ])
    }
}
