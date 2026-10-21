import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// Quantize.
//
// The catalog had no quantize at all before this lane — not in the engine, not
// in the command catalog, not in the MCP tools; the only trace anywhere in the
// tree was a fabricated MIDI binding in a mock pointing at `tools.quantize`, a
// command that has never existed. So everything below is about a NEW capability
// rather than a wiring job, and the assertions are correspondingly paranoid.
//
// Two properties matter more than the feature:
//
//   1. UNDO RESTORES THE PERFORMANCE, not the grid. The owner's own recorded
//      take sits deliberately off the grid — the project tempo was fitted to
//      his playing rather than his playing quantized to a tempo. A "quantize
//      back" inverse would return the notes to the LINES, which looks correct
//      in every count-based test and is the destruction of the only real piece
//      of music in this app. Every test here asserts the original, off-grid
//      tick positions come back exactly.
//
//   2. NOTHING QUANTIZES BY ITSELF. Not on capture, not on open, not as a side
//      effect of another edit, not at any strength. `testNothingButAnExplicit…`
//      drives a whole editing session and asserts the journal never sees one.
//
// Everything is asserted against the mock engine's JOURNAL and against real
// tick numbers written out longhand, never against view state. The mock applies
// real inverses, so a quantize that returned its input could not pass.

@MainActor
final class StudioQuantizeTests: XCTestCase {

    private let sig = StudioTimeSignature.fourFour
    private let clipStart: Int64 = 3840 * 2          // 7680: bar 3, a multiple of every grid
    private let clipLength: Int64 = 3840 * 4
    private let viewSize = CGSize(width: 900, height: 500)

    /// A take played by hand: three notes, none of them on a line.
    ///   early  3 ticks BEFORE the sixteenth at 240
    ///   late  10 ticks AFTER  the same line
    ///   drag   2 ticks BEFORE the sixteenth at 1920
    private var loosePerformance: [StudioNote] {
        [
            StudioNote(id: "early", startTicks: 237, lengthTicks: 461, pitch: 60, velocity: 100),
            StudioNote(id: "late", startTicks: 250, lengthTicks: 240, pitch: 64, velocity: 90),
            StudioNote(id: "drag", startTicks: 1918, lengthTicks: 240, pitch: 67, velocity: 80),
        ]
    }

    private func makeFixture(
        notes: [StudioNote],
        phaseAnchorTicks: Int64 = 0
    ) async -> (StudioPianoRollController, StudioMockNoteEngine) {
        let clipID = UUID(uuidString: "9A9A9A9A-1111-4222-8333-444444444444")!
        let clip = StudioMidiClipSnapshot(
            id: clipID, trackID: UUID(), name: "Keys",
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
        controller.scrollY = CGFloat(127 - 84) * 14
        controller.grid = .sixteenth
        return (controller, engine)
    }

    /// `(id, startTicks, lengthTicks)` in the model's canonical order.
    private func timing(_ c: StudioPianoRollController) -> [(String, Int64, Int64)] {
        (c.clip?.notes ?? []).map { ($0.id, $0.startTicks, $0.lengthTicks) }
    }

    private func assertTiming(
        _ c: StudioPianoRollController,
        _ expected: [(String, Int64, Int64)],
        _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = timing(c)
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.0, e.0, "\(message) (id)", file: file, line: line)
            XCTAssertEqual(a.1, e.1, "\(message) (\(a.0) start)", file: file, line: line)
            XCTAssertEqual(a.2, e.2, "\(message) (\(a.0) length)", file: file, line: line)
        }
    }

    // MARK: - Where the notes land

    func testQuantizingASelectionPullsEveryNoteOntoItsLineAndLeavesLengthsAlone() async {
        let (c, engine) = await makeFixture(notes: loosePerformance)
        c.selectAll()
        c.quantizeStrengthPercent = 100
        c.quantizeEnds = false
        c.quantizeSelection()
        await c.settle()

        assertTiming(c, [
            ("early", 240, 461),      // 237 -> 240
            ("late", 240, 240),       // 250 -> 240
            ("drag", 1920, 240),      // 1918 -> 1920
        ], "a 100% quantize must land every note on the sixteenth grid")

        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 1, "a quantize is ONE journal entry for the whole selection")
        guard case .quantize(_, let ids, let grid, let strength, let ends) = log[0] else {
            return XCTFail("expected note.quantize, got \(log[0])")
        }
        XCTAssertEqual(ids.sorted(), ["drag", "early", "late"])
        XCTAssertEqual(grid, 240, "the grid picker's 1/16 is 240 ticks at PPQ 960")
        XCTAssertEqual(strength, 100)
        XCTAssertFalse(ends)
        XCTAssertEqual(log[0].catalogName, "note.quantize")
    }

    func testAPartialStrengthTightensTheTimingWithoutFlatteningIt() async {
        let (c, _) = await makeFixture(notes: loosePerformance)
        c.selectAll()
        c.quantizeStrengthPercent = 50
        c.quantizeSelection()
        await c.settle()

        assertTiming(c, [
            // early needs +3; half of 3 rounds away from zero to +2.
            ("early", 239, 461),
            // late needs -10; half is -5.
            ("late", 245, 240),
            // drag needs +2; half is +1.
            ("drag", 1919, 240),
        ], "at 50% the notes must be TIGHTER but still off the line")
    }

    func testTheDefaultStrengthIsDeliberatelyShortOfMechanical() async {
        let (c, _) = await makeFixture(notes: loosePerformance)
        XCTAssertEqual(
            c.quantizeStrengthPercent, 80,
            "the default must not be 100: a fully quantized take stops sounding played")
        XCTAssertFalse(
            c.quantizeEnds,
            "quantizing note ENDS by default chops legato phrasing; it must be opt-in")

        c.selectAll()
        c.quantizeSelection()
        await c.settle()
        assertTiming(c, [
            ("early", 239, 461),      // 80% of +3 is 2.4 -> +2
            ("late", 242, 240),       // 80% of -10 is -8
            ("drag", 1920, 240),      // 80% of +2 is 1.6 -> +2
        ], "the shipped default must move notes by the amount the picker says")
    }

    func testQuantizeFollowsTheProjectPhaseAnchorRatherThanTickZero() async {
        // A landed generative song has a lead-in: bar 1 is not at tick 0. Grid
        // lines measured from zero are not where that song's beats are, so a
        // quantize anchored at zero moves notes OFF the beat, confidently.
        let (c, _) = await makeFixture(notes: loosePerformance, phaseAnchorTicks: 120)
        c.selectAll()
        c.quantizeStrengthPercent = 100
        c.quantizeSelection()
        await c.settle()

        // Absolute lines are now 120, 360, ... The note at clip-relative 237
        // sits at absolute 7917; the nearest line is 7800, i.e. clip-relative
        // 120 — NOT the 240 an unanchored grid would give.
        assertTiming(c, [
            // early: absolute 7917 - 120 = 7797 = 32*240 + 117; 117 is short of
            // the half step, so it falls BACK to the line at 7800 -> 120.
            ("early", 120, 461),
            // late: absolute 7930 - 120 = 7810 = 32*240 + 130; 130 is past the
            // half step, so it goes FORWARD to 8040 -> 360. An unanchored grid
            // would have put both of these on the same line at 240.
            ("late", 360, 240),
            ("drag", 1800, 240),
        ], "the quantize grid must be measured from the project's phase anchor")
    }

    func testQuantizingEndsChangesLengthsAndLeavingItOffDoesNot() async {
        let (withEnds, _) = await makeFixture(notes: loosePerformance)
        withEnds.selectAll()
        withEnds.quantizeStrengthPercent = 100
        withEnds.quantizeEnds = true
        withEnds.quantizeSelection()
        await withEnds.settle()
        assertTiming(withEnds, [
            // start 237 -> 240 (+3); end 698 -> 720 (+22); length 461+22-3 = 480.
            ("early", 240, 480),
            ("late", 240, 240),
            ("drag", 1920, 240),
        ], "with quantizeEnds on, the note END is pulled to the grid too")

        let (withoutEnds, _) = await makeFixture(notes: loosePerformance)
        withoutEnds.selectAll()
        withoutEnds.quantizeStrengthPercent = 100
        withoutEnds.quantizeEnds = false
        withoutEnds.quantizeSelection()
        await withoutEnds.settle()
        XCTAssertEqual(
            withoutEnds.clip?.note("early")?.lengthTicks, 461,
            "with quantizeEnds off the length must be untouched, to the tick")
    }

    // MARK: - Undo restores the PERFORMANCE

    func testUndoRestoresTheExactOriginalTickPositionsAndNotTheGrid() async {
        for strength in [100, 80, 65, 25] {
            let (c, engine) = await makeFixture(notes: loosePerformance)
            let before = timing(c)
            c.selectAll()
            c.quantizeStrengthPercent = strength
            c.quantizeSelection()
            await c.settle()
            XCTAssertNotEqual(
                timing(c).map(\.1), before.map(\.1),
                "quantize at \(strength)% moved nothing, so the undo below proves nothing")

            c.undo()
            await c.settle()
            assertTiming(
                c, before,
                "undo of a \(strength)% quantize must restore the performance, tick for tick")

            // And the undo went through the ABSOLUTE setter, never a reverse
            // quantize — the whole reason `note.timing.set` exists.
            let log = await engine.commandLog()
            XCTAssertEqual(log.count, 1, "undo must not journal a second forward command")
            XCTAssertEqual(log[0].catalogName, "note.quantize")
        }
    }

    func testRedoAfterUndoPutsTheQuantizeBackExactly() async {
        let (c, _) = await makeFixture(notes: loosePerformance)
        c.selectAll()
        c.quantizeStrengthPercent = 100
        c.quantizeSelection()
        await c.settle()
        let quantized = timing(c)

        c.undo()
        await c.settle()
        c.redo()
        await c.settle()
        assertTiming(c, quantized, "redo must reproduce the quantize exactly")
    }

    func testUndoAlsoRestoresLengthsWhenEndsWereQuantized() async {
        let (c, _) = await makeFixture(notes: loosePerformance)
        let before = timing(c)
        c.selectAll()
        c.quantizeStrengthPercent = 100
        c.quantizeEnds = true
        c.quantizeSelection()
        await c.settle()
        XCTAssertEqual(c.clip?.note("early")?.lengthTicks, 480, "the length did change")

        c.undo()
        await c.settle()
        assertTiming(c, before, "undo must restore the played LENGTHS as well as the starts")
    }

    // MARK: - Scope: selection vs whole clip

    func testQuantizeSelectionTouchesOnlyTheSelectedNotes() async {
        let (c, engine) = await makeFixture(notes: loosePerformance)
        c.selection = ["late"]
        c.quantizeStrengthPercent = 100
        c.quantizeSelection()
        await c.settle()

        assertTiming(c, [
            ("early", 237, 461),      // untouched
            ("late", 240, 240),       // the only one asked for
            ("drag", 1918, 240),      // untouched
        ], "quantize must move the selection and nothing else")

        let log = await engine.commandLog()
        guard case .quantize(_, let ids, _, _, _) = log[0] else {
            return XCTFail("expected note.quantize, got \(log[0])")
        }
        XCTAssertEqual(ids, ["late"])
    }

    func testQuantizeAllNotesIsASeparateExplicitCommand() async {
        let (c, engine) = await makeFixture(notes: loosePerformance)
        c.selection = []
        c.quantizeStrengthPercent = 100
        c.quantizeAllNotesInClip()
        await c.settle()

        assertTiming(c, [
            ("early", 240, 461),
            ("late", 240, 240),
            ("drag", 1920, 240),
        ], "the whole-clip command must reach every note")

        let log = await engine.commandLog()
        XCTAssertEqual(log.count, 1, "the whole clip is still ONE undo step")
        guard case .quantize(_, let ids, _, _, _) = log[0] else {
            return XCTFail("expected note.quantize, got \(log[0])")
        }
        XCTAssertEqual(ids, ["drag", "early", "late"])
    }

    func testQuantizingAnEmptySelectionJournalsNothing() async {
        let (c, engine) = await makeFixture(notes: loosePerformance)
        c.selection = []
        c.quantizeSelection()
        await c.settle()
        let log = await engine.commandLog()
        XCTAssertTrue(
            log.isEmpty,
            "⌘U with nothing selected must be a no-op, not a whole-clip quantize: \(log)")
        assertTiming(c, [("early", 237, 461), ("late", 250, 240), ("drag", 1918, 240)],
                     "nothing may move")
    }

    func testAnOffGridSettingRefusesToQuantizeRatherThanGuessing() async {
        let (c, engine) = await makeFixture(notes: loosePerformance)
        c.grid = .off
        c.selectAll()
        XCTAssertNil(c.quantizeGridTicks, "Grid: Off has no lines to pull toward")
        XCTAssertFalse(c.canQuantizeSelection, "so the control must disable")
        c.quantizeSelection()
        await c.settle()
        let log = await engine.commandLog()
        XCTAssertTrue(log.isEmpty, "a quantize with no grid must journal nothing: \(log)")
    }

    func testAZeroStrengthQuantizeIsDroppedRatherThanJournaledAsANoOp() async {
        let (c, engine) = await makeFixture(notes: loosePerformance)
        c.selectAll()
        c.quantizeStrengthPercent = 0
        c.quantizeSelection()
        await c.settle()
        let log = await engine.commandLog()
        XCTAssertTrue(
            log.isEmpty,
            "0% moves nothing; journaling it would put an undo step that does nothing on the stack")
        XCTAssertFalse(c.canUndo, "and it must not appear on the undo stack")
    }

    func testTheGridPickerIsWhatDecidesTheDivision() async {
        // Not a constant the lane hardcoded: change the picker, the wire
        // payload changes with it.
        for (grid, ticks) in [
            (StudioNoteGrid.quarter, Int64(960)),
            (.eighth, 480),
            (.sixteenth, 240),
            (.thirtySecond, 120),
            (.eighthTriplet, 320),
            (.bar, 3840),
        ] {
            let (c, engine) = await makeFixture(notes: loosePerformance)
            c.grid = grid
            c.selectAll()
            c.quantizeSelection()
            await c.settle()
            let log = await engine.commandLog()
            guard case .quantize(_, _, let sent, _, _) = log[0] else {
                return XCTFail("expected note.quantize for \(grid), got \(log[0])")
            }
            XCTAssertEqual(sent, ticks, "grid \(grid.label) must send \(ticks) ticks")
        }
    }

    // MARK: - The safety property

    func testNothingButAnExplicitQuantizeEverQuantizes() async {
        // A whole editing session: open the clip, adopt it, draw, drag a chord,
        // resize, nudge with the arrow keys, delete, undo. Not one of those may
        // tidy a played note onto the grid, and none of them may journal a
        // quantize. This is the assertion that protects the owner's take.
        let (c, engine) = await makeFixture(notes: loosePerformance)
        // Wide enough that the press below lands in the note BODY rather than
        // on its resize edge — at 0.1 px/tick "early" is 46 pt wide and its
        // start pixel IS its leading edge.
        c.pxPerTick = 0.5
        let l = c.layout(for: viewSize)

        c.selectAll()
        // Drag the whole selection with the grid BYPASSED (Command), so the
        // gesture itself cannot be what tidies anything up. Grab at 450 (inside
        // early's 237...698) and let go 480 ticks later.
        let from = CGPoint(x: l.x(forTicks: clipStart + 450), y: l.y(forPitch: 60) + 7)
        let to = CGPoint(x: l.x(forTicks: clipStart + 930), y: l.y(forPitch: 60) + 7)
        let mods = StudioNoteModifiers(shift: false, command: true, option: false)
        c.press(at: from, modifiers: mods, layout: l)
        c.dragged(to: to, modifiers: mods, layout: l)
        c.released(at: to, modifiers: mods, layout: l)
        await c.settle()

        c.nudgeSelection(gridSteps: 0, semitones: 1)
        await c.settle()
        c.nudgeVelocity(by: -5)
        await c.settle()
        c.duplicateSelection()
        await c.settle()
        c.undo()
        await c.settle()
        await c.adoptFresh()

        let log = await engine.commandLog()
        XCTAssertFalse(log.isEmpty, "the session must actually have done something")
        XCTAssertTrue(
            log.allSatisfy { $0.catalogName != "note.quantize" },
            "something quantized without being asked: \(log.map(\.catalogName))")
        // And the notes are STILL off the grid, by exactly the amount they were
        // played off it. 237 + 480 = 717, three ticks shy of the line at 720.
        XCTAssertEqual(
            c.clip?.note("early")?.startTicks, 717,
            "an edit path rounded a played note onto the grid")
    }

    func testCommandUQuantizesAndABareUDoesNot() async {
        let (c, engine) = await makeFixture(notes: loosePerformance)
        c.selectAll()
        c.quantizeStrengthPercent = 100

        XCTAssertTrue(
            c.handleKey("u", arrow: nil, shift: false, command: true),
            "⌘U must be consumed by the roll")
        await c.settle()
        XCTAssertEqual(c.clip?.note("early")?.startTicks, 240, "⌘U must quantize")

        c.undo()
        await c.settle()
        XCTAssertEqual(c.clip?.note("early")?.startTicks, 237)

        XCTAssertFalse(
            c.handleKey("u", arrow: nil, shift: false, command: false),
            "a bare u is not a quantize; it must fall through unhandled")
        await c.settle()
        XCTAssertEqual(
            c.clip?.note("early")?.startTicks, 237,
            "a bare u moved a note")
        let log = await engine.commandLog()
        XCTAssertEqual(
            log.filter { $0.catalogName == "note.quantize" }.count, 1,
            "exactly one quantize, from the ⌘U: \(log.map(\.catalogName))")
    }

    // MARK: - The absolute setter on its own

    func testSetTimingIsAbsoluteAndItsUndoIsExact() async {
        let (c, engine) = await makeFixture(notes: loosePerformance)
        let before = timing(c)
        _ = await engine.send(.setTiming(
            clipID: c.clip!.id,
            timings: [StudioNoteTiming(noteID: "early", startTicks: 42, lengthTicks: 99)]))
        await c.adoptFresh()
        XCTAssertEqual(c.clip?.note("early")?.startTicks, 42, "absolute, not a delta")
        XCTAssertEqual(c.clip?.note("early")?.lengthTicks, 99)
        // Pitch and velocity are not this command's business.
        XCTAssertEqual(c.clip?.note("early")?.pitch, 60)
        XCTAssertEqual(c.clip?.note("early")?.velocity, 100)

        _ = await engine.undo()
        await c.adoptFresh()
        assertTiming(c, before, "note.timing.set must undo to the exact pre-state")
    }

    // MARK: - Pixels
    //
    // ImageRenderer, the deterministic no-window path. A quantize that updated
    // the model but not the drawing would pass every assertion above.

    private func raster(_ c: StudioPianoRollController) throws -> (bytes: [UInt8], width: Int) {
        let view = StudioPianoRollView(controller: c, frameStats: StudioFrameStats())
            .frame(width: viewSize.width, height: viewSize.height)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.cgImage, "the piano roll did not rasterize at all")
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (bytes, cg.width)
    }

    private func pixel(_ raster: (bytes: [UInt8], width: Int), _ x: Int, _ y: Int) -> [Int] {
        let i = (y * raster.width + x) * 4
        return [Int(raster.bytes[i + 1]), Int(raster.bytes[i + 2]), Int(raster.bytes[i + 3])]
    }

    private func near(_ a: [Int], _ b: [Int], tolerance: Int = 6) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    func testAQuantizedNoteIsDrawnInItsNewPlace() async throws {
        // One note, one quarter-note grid, and a displacement big enough to see:
        // clip-relative 480 sits exactly half a quarter past the line at 0, and
        // a tie rounds to the LATER line, so it travels +480 ticks.
        let note = StudioNote(id: "n", startTicks: 480, lengthTicks: 480, pitch: 60, velocity: 100)
        let (c, _) = await makeFixture(notes: [note])
        c.grid = .quarter
        c.quantizeStrengthPercent = 100
        c.velocityLaneShown = false
        // The roll frames its clip ONCE, on the first layout it is handed, and
        // that fit rewrites pxPerTick / rowHeight / scroll. Burn that render
        // first, or the transforms pinned below are silently overwritten and
        // every coordinate computed from them points at empty grid.
        _ = try raster(c)
        c.pxPerTick = 0.25                       // 480 ticks = 120 pt of travel
        c.rowHeight = 14
        c.scrollTicks = clipStart
        c.scrollY = CGFloat(127 - 66) * c.rowHeight

        let l = c.layout(for: viewSize)
        let row = Int(l.y(forPitch: 60) + c.rowHeight / 2)
        let insideBefore = Int(l.x(forTicks: clipStart + 600))    // within 480...960
        let insideAfter = Int(l.x(forTicks: clipStart + 1080))    // within 960...1440

        let before = try raster(c)
        let noteInk = pixel(before, insideBefore, row)
        let emptyInk = pixel(before, insideAfter, row)
        XCTAssertFalse(
            near(noteInk, emptyInk),
            "the probe cannot tell a note from empty grid, so it can prove nothing: \(noteInk) vs \(emptyInk)")

        c.quantizeAllNotesInClip()
        await c.settle()
        XCTAssertEqual(c.clip?.note("n")?.startTicks, 960, "the model moved the note first")

        let after = try raster(c)
        XCTAssertTrue(
            near(pixel(after, insideAfter, row), noteInk),
            "the note is not DRAWN in its new place: \(pixel(after, insideAfter, row)) vs \(noteInk)")
        XCTAssertTrue(
            near(pixel(after, insideBefore, row), emptyInk),
            "the note is still drawn where it used to be: \(pixel(after, insideBefore, row)) vs \(emptyInk)")
    }


    // MARK: - The line that FEEDS it
    //
    // Everything above proves the controller and the engine. The commonest way
    // a lane on this repo ships a dead feature is with both halves proven and
    // the single view line that calls them missing — planning an edit correctly
    // and committing it correctly are worth nothing if nothing calls both.
    //
    // A menu item cannot be clicked without a window, so this is a SOURCE SCAN:
    // it fails by name the moment the toolbar stops calling the controller.
    // `StudioHelpTests.testEveryCatalogEntryIsAttachedToAControl` covers the
    // other half (the control exists and carries its help id). What neither can
    // tell you is whether the menu is reachable with a mouse — see the report's
    // human checks.

    func testThePianoRollToolbarActuallyCallsTheQuantizeCommands() throws {
        let view = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Studio/StudioPianoRollView.swift")
            .standardizedFileURL
        let text = try String(contentsOf: view, encoding: .utf8)
        XCTAssertGreaterThan(text.count, 5_000, "the scan did not read the view at all")

        for call in [
            "controller.quantizeSelection()",
            "controller.quantizeAllNotesInClip()",
            "$controller.quantizeStrengthPercent",
            "$controller.quantizeEnds",
            "\"pianoRoll.quantize\"",
            // The menu has to be IN the toolbar row, not merely defined.
            "quantizeMenu",
        ] {
            XCTAssertTrue(
                text.contains(call),
                "the piano roll toolbar no longer references \(call), so quantize is unreachable from the UI")
        }
    }

    func testTheQuantizeControlCarriesHelpWrittenForSomeoneWhoHasNeverUsedADAW() throws {
        let entry = try XCTUnwrap(
            StudioHelpCatalog.entry("pianoRoll.quantize"),
            "a new control with no help entry fails the table-driven help tests")
        XCTAssertTrue(
            entry.teaching.lowercased().contains("undo"),
            "the teaching text must say the notes can be put back; that is the whole reassurance")
    }
}
