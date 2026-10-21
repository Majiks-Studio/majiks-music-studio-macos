import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// The command palette, held to its own claim.
//
// The claim is narrow and testable: **every row ⌘K lists either sends its
// catalog command or is shown disabled with a reason.** There is no third
// state, and the third state is what this palette shipped twice — first as 71
// listed / 11 wired (selecting most of them did nothing), then as 11 listed of
// 119 (the honest fix was never done).
//
// So the assertions here are structural rather than sampled:
//
//   1. `testEveryCatalogCommandIsOfferedOrRefusedInWriting` — `all` and
//      `excluded` partition the whole catalog. A command added to
//      command-catalog.v2.json lands in neither and fails this by name, so it
//      cannot slip past unconsidered.
//   2. `testEveryOfferedCommandReachesTheCommandBus` — for EVERY row in `all`,
//      not a sample: stage the app so the row is runnable, drive the same
//      confirm/argument flow the view drives, and assert the row's own catalog
//      name arrives on the bus. A row nobody can stage FAILS BY NAME rather
//      than being quietly skipped, which is what stops an unprovable row from
//      shipping.
//   3. `testNoOfferedRowIsListedWithoutEitherReadinessOrAReason` — the binary
//      invariant, checked on a bare project where most rows are blocked.
//
// The bus is the real one. `PaletteSpyEngine` records what `send` was called
// with and then delegates to `StudioMockEngine`, so nothing here is asserted
// against a test-only seam: the rows call the same view-model and controller
// methods the buttons call.

// MARK: - The bus, watched

/// Records every command and then behaves exactly like the preview engine.
/// Routing reads are forwarded, because `StudioRoutingController` refuses to
/// dispatch against a chain it cannot see and the default protocol
/// implementation returns nil.
actor PaletteSpyEngine: StudioEngineProtocol {
    private let inner = StudioMockEngine()
    private(set) var sent: [StudioEngineCommand] = []

    func snapshot(ifNewerThan revision: UInt64?) async -> StudioProjectSnapshot? {
        await inner.snapshot(ifNewerThan: revision)
    }

    @discardableResult
    func send(_ command: StudioEngineCommand) async -> StudioCommandResult {
        sent.append(command)
        return await inner.send(command)
    }

    func setMetronome(enabled: Bool?, levelDB: Double?, countInBeats: Int?) async {
        await inner.setMetronome(enabled: enabled, levelDB: levelDB, countInBeats: countInBeats)
    }

    func importAudio(path: String, trackID: UUID?, startTicks: Int64) async -> StudioCommandResult {
        await inner.importAudio(path: path, trackID: trackID, startTicks: startTicks)
    }

    @discardableResult func undo() async -> Bool { await inner.undo() }
    @discardableResult func redo() async -> Bool { await inner.redo() }

    func waveformTile(_ key: StudioTileKey) async -> StudioWaveformTile? {
        await inner.waveformTile(key)
    }

    func addInstrumentTrack(name: String, lengthTicks: Int64) async -> StudioInstrumentTrackOutcome {
        await inner.addInstrumentTrack(name: name, lengthTicks: lengthTicks)
    }

    func openInStudio(_ request: StudioLandingRequest) async -> StudioCommandResult {
        await inner.openInStudio(request)
    }

    func routingTrackID(_ id: UUID) async -> String? { await inner.routingTrackID(id) }
    func routingState() async -> StudioRoutingState? { await inner.routingState() }

    func names() -> [String] { sent.map(\.catalogName) }
}

// MARK: - A staged Studio

/// A whole Studio, on the preview engine, with both controllers attached — the
/// three objects the palette's context is built from.
@MainActor
final class PaletteFixture {
    let spy: PaletteSpyEngine
    let model: StudioViewModel
    let noteEngine: StudioMockNoteEngine
    let roll: StudioPianoRollController
    let routing: StudioRoutingController

    /// The clip the piano roll is opened on. Its notes are deliberately OFF the
    /// grid so a quantize has something to do.
    static let midiClipID = UUID(uuidString: "51DE51DE-0001-4002-8003-000000000004")!

    init() {
        let spy = PaletteSpyEngine()
        self.spy = spy
        model = StudioViewModel(engine: spy)
        let clip = StudioMidiClipSnapshot(
            id: Self.midiClipID, trackID: UUID(), name: "Keys",
            startTicks: 7680, lengthTicks: 3840 * 4,
            notes: StudioNote.sorted([
                StudioNote(id: "n1", startTicks: 237, lengthTicks: 461, pitch: 60, velocity: 100),
                StudioNote(id: "n2", startTicks: 1918, lengthTicks: 240, pitch: 64, velocity: 90),
            ]),
            kind: .other)
        let noteEngine = StudioMockNoteEngine(
            clip: clip,
            barGrid: StudioBarGrid(timeSignature: .fourFour, phaseAnchorTicks: 0),
            tempoMap: .constant(bpm: 120))
        self.noteEngine = noteEngine
        roll = StudioPianoRollController(engine: noteEngine)
        routing = StudioRoutingController(engine: spy)
    }

    var context: StudioPaletteContext {
        StudioPaletteContext(model: model, pianoRoll: roll, routing: routing)
    }

    /// The state every row is measured from: a project on screen, a clip
    /// selected (which is what resolves BOTH the target clip and the target
    /// track), the piano roll open with its notes selected, and the effects
    /// panel attached.
    func stageStandard() async {
        model.startPolling()
        await wait { self.model.snapshot != nil }
        if let clip = model.snapshot?.tracks.first?.clips.first {
            model.selection = StudioSelection(clipIDs: [clip.id], region: nil)
        }
        await roll.attach(clipID: Self.midiClipID)
        roll.grid = .sixteenth
        roll.selectAll()
        await routing.attach()
        // `project.save` is the ONE row that does not go through the view
        // model: `StudioProjectSaver` holds its own engine reference (it owns
        // the checkpoint cadence). Attaching the same spy is what the shell
        // does at launch, so the row is proven on the real path rather than
        // excused.
        StudioProjectSaver.shared.attach(spy)
        // The play head sits inside the selected clip but not at its start, so
        // `clip.move` and `clip.trim` both have somewhere to land.
        if let clip = model.snapshot?.tracks.first?.clips.first {
            model.seek(toTicks: clip.startTicks + clip.lengthTicks / 2)
            await wait { self.model.snapshot?.transport.positionTicks ?? 0 > clip.startTicks }
        }
    }

    func teardown() {
        model.stopPolling()
        roll.stopPolling()
        routing.stopPolling()
    }

    func wait(timeout: TimeInterval = 3.0, until condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Did `name` reach either bus? The arrangement bus for most rows, the note
    /// bus for `note.*` — both are journals, neither is a test-only hook.
    func busSaw(_ name: String, timeout: TimeInterval = 3.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await spy.names().contains(name) { return true }
            if await noteEngine.commandLog().map(\.catalogName).contains(name) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

// MARK: - Staging, shared
//
// Extracted from `StudioPaletteReachTests` (where it was `private static`) so
// the MENU suite can stage the app the identical way. It has to be the same
// table: two staging tables for one set of commands would drift, and a menu
// test that staged differently from the palette test would be proving a
// different app.

@MainActor
enum PaletteStaging {

    /// Extra staging for rows the standard fixture cannot make runnable.
    /// A row with no entry here must be runnable from `stageStandard` alone.
    static let extra: [String: @MainActor (PaletteFixture) async -> Void] = [
        "transport.loop.set": { f in
            f.model.selection.region = StudioRegionSelection(rawStart: 0, rawEnd: 3840 * 4)
        },
        "transport.loop.clear": { f in
            f.model.setLoop(startTicks: 0, endTicks: 3840 * 4)
            await f.wait { f.model.effectiveLoopRegion != nil }
        },
        "device.remove": { f in
            guard let track = f.context.targetTrack else { return }
            _ = f.model.addInstrument(trackID: track.id)
            await f.wait { (f.context.targetTrack?.devices.isEmpty == false) }
        },
        "record.start": { f in await armFirstTrack(f) },
        "record.rotate": { f in await startRecording(f) },
        "record.stop": { f in await startRecording(f) },
        "record.cancel": { f in await startRecording(f) },
        "route.node.remove": { f in await focusABus(f) },
        "route.node.set": { f in await focusABus(f) },
        "fx.remove": { f in await selectAnFx(f) },
        "fx.move": { f in await selectAnFx(f, count: 2) },
        // Only a compressor or a gate has a keyable detector, and master can
        // never be the key source (it is the mix bus). So: a compressor on
        // master, keyed off a real track.
        "fx.sidechain.clear": { f in
            guard let id = f.routing.addFx(to: .master, kind: .compressor) else { return }
            await f.routing.settle()
            await f.routing.reload()
            f.routing.selectedFxID = id
            guard let engineID = f.routing.tracks.compactMap(\.engineID).first else { return }
            f.routing.setSidechain(on: .master, id: id, source: .track(engineID))
            await f.routing.settle()
            await f.routing.reload()
        },
    ]

    /// Values typed into the argument field where the pre-filled one would be a
    /// deliberate no-op. `fx.move` pre-fills the effect's CURRENT position, and
    /// the controller refuses to journal a move to where it already is — which
    /// is correct behaviour and would make a dispatch assertion here a lie.
    static let typedOverride: [String: String] = [
        "fx.move": "2",
    ]

    static func armFirstTrack(_ f: PaletteFixture) async {
        guard let track = f.model.snapshot?.tracks.first else { return }
        f.model.setTrackArm(track.id, armed: true)
        await f.wait { f.model.firstArmedTrack != nil }
    }

    static func startRecording(_ f: PaletteFixture) async {
        await armFirstTrack(f)
        f.model.countInBeats = 0          // the count-in is a timer; this is not what is under test
        f.model.selection.region = nil    // no punch region, so nothing auto-stops mid-test
        f.model.toggleRecord()
        await f.wait { f.model.isRecording }
    }

    static func focusABus(_ f: PaletteFixture) async {
        guard let id = f.routing.addBus(kind: .bus, name: "Reverb bus") else { return }
        await f.routing.settle()
        await f.routing.reload()
        f.routing.focus = .bus(id)
    }

    static func selectAnFx(_ f: PaletteFixture, count: Int = 1) async {
        var ids: [String] = []
        for kind in [StudioFxKind.reverb, .delay].prefix(count) {
            if let id = f.routing.addFx(to: .master, kind: kind) { ids.append(id) }
        }
        await f.routing.settle()
        await f.routing.reload()
        f.routing.selectedFxID = ids.first
    }

}

// MARK: - The tests

@MainActor
final class StudioPaletteReachTests: XCTestCase {

    // -----------------------------------------------------------------------
    // 1. The partition. Offered or refused in writing — never neither.
    // -----------------------------------------------------------------------

    func testEveryCatalogCommandIsOfferedOrRefusedInWriting() {
        let offered = Set(StudioPaletteCommands.all.map(\.name))
        let excluded = Set(StudioPaletteCommands.excluded.keys)
        let catalog = Set(CatalogNames.names)

        XCTAssertEqual(
            StudioPaletteCommands.all.count, offered.count,
            "a command name is offered twice, so one of the two rows is unreachable")
        XCTAssertTrue(
            offered.isDisjoint(with: excluded),
            "offered and excluded overlap: \(offered.intersection(excluded).sorted())")

        let unconsidered = catalog.subtracting(offered).subtracting(excluded)
        XCTAssertTrue(
            unconsidered.isEmpty,
            """
            \(unconsidered.sorted()) are in command-catalog.v2.json but neither \
            offered by the palette nor listed in `excluded` with a reason. A new \
            command must be one or the other — silently dropping it is how the \
            palette got to 11 of 119.
            """)

        let invented = offered.union(excluded).subtracting(catalog)
        XCTAssertTrue(
            invented.isEmpty,
            "\(invented.sorted()) are named by the palette but are not in the catalog")

        // The catalog is 119 at this tip; the two tables must account for all
        // of it. Written out so a drift is a number, not a shrug.
        XCTAssertEqual(catalog.count, 119, "regenerate CatalogNames.swift")
        XCTAssertEqual(offered.count + excluded.count, 119)
    }

    func testEveryExclusionStatesAReasonSomebodyCanRead() {
        for (name, reason) in StudioPaletteCommands.excluded {
            XCTAssertGreaterThanOrEqual(
                reason.count, 30,
                "\(name): \"\(reason)\" is too short to be a reason")
            XCTAssertFalse(
                reason.lowercased().contains("not implemented"),
                "\(name): \"not implemented\" is a status, not a reason a user can act on")
        }
    }

    func testViewRowsNeverBorrowACatalogName() async {
        let catalog = Set(CatalogNames.names)
        for entry in StudioPaletteCatalog.entries() {
            guard entry.command == nil else { continue }
            XCTAssertFalse(
                catalog.contains(entry.id),
                """
                \(entry.id) is shown as one of this build's view rows but is also \
                a catalog command name. A view row does not put that command on \
                the bus, so borrowing its name is a claim the palette cannot keep.
                """)
        }
    }

    // -----------------------------------------------------------------------
    // 2. Every listed row is READY or BLOCKED-WITH-A-REASON. No third state.
    // -----------------------------------------------------------------------

    func testNoOfferedRowIsListedWithoutEitherReadinessOrAReason() async {
        let f = PaletteFixture()
        f.model.startPolling()
        await f.wait { f.model.snapshot != nil }
        defer { f.teardown() }

        // Deliberately UNSTAGED: nothing selected, no roll, no routing. Most
        // rows should be blocked here, and every one of them has to say why.
        let bare = StudioPaletteContext(model: f.model)
        var blockedCount = 0
        for command in StudioPaletteCommands.all {
            switch command.availability(in: bare) {
            case .ready:
                continue
            case .blocked(let reason):
                blockedCount += 1
                XCTAssertGreaterThanOrEqual(
                    reason.count, 20,
                    "\(command.name): blocked with \"\(reason)\", which does not tell anyone what to do")
                XCTAssertNotEqual(
                    reason, command.title,
                    "\(command.name): the reason just repeats the title")
            }
        }
        XCTAssertGreaterThan(
            blockedCount, 20,
            """
            Only \(blockedCount) rows were blocked on a bare project with nothing \
            selected. Rows that need a clip, a track, the piano roll or the \
            effects panel must block there — if they read as ready, selecting \
            them does nothing, which is the exact defect this lane exists to fix.
            """)
    }

    // -----------------------------------------------------------------------
    // 3. THE ONE THAT MATTERS. Every offered row reaches the bus.
    // -----------------------------------------------------------------------

    func testEveryOfferedCommandReachesTheCommandBus() async {
        var proven: [String] = []
        for command in StudioPaletteCommands.all {
            let f = PaletteFixture()
            await f.stageStandard()
            if let extra = PaletteStaging.extra[command.name] { await extra(f) }

            guard case .ready = command.availability(in: f.context) else {
                let reason = command.availability(in: f.context).reason ?? "?"
                XCTFail(
                    """
                    \(command.name) is offered by the palette but nothing in this \
                    file could make it runnable — it stayed blocked with \
                    "\(reason)". Either add its staging, or stop offering it. A \
                    row that cannot be proven is a row that ships unproven.
                    """)
                f.teardown()
                continue
            }

            // Drive the SAME flow the view drives: confirm, then argument, then
            // commit. Three iterations is one more than the deepest path, so a
            // flow that never reaches `.commit` fails rather than spinning.
            var stage = StudioPaletteStage.browsing
            var typed = PaletteStaging.typedOverride[command.name] ?? ""
            var committed: StudioPaletteValue?
            for _ in 0..<3 {
                switch StudioPaletteFlow.step(
                    for: command, stage: stage, typed: typed, in: f.context
                ) {
                case .askForConfirmation:
                    stage = .confirming(name: command.name)
                case .askForArgument(_, let initial):
                    if PaletteStaging.typedOverride[command.name] == nil { typed = initial }
                    stage = .argument(name: command.name)
                case .commit(let value):
                    committed = value
                case .blocked(let why):
                    XCTFail("\(command.name): blocked mid-flow with \"\(why)\"")
                case .rejected(let why):
                    XCTFail("\(command.name): its own pre-filled value was rejected — \(why)")
                }
                if committed != nil { break }
            }

            guard let value = committed else {
                XCTFail("\(command.name): the palette's flow never reached a commit")
                f.teardown()
                continue
            }

            command.perform(f.context, value)
            // `project.save` is the ONE row that does not ride the view model's
            // bus. `StudioProjectSaver` is a singleton that holds its own engine
            // and whose `attach` is idempotent, so whichever test constructed a
            // fixture first owns it — a spy attached here may never be the one
            // the saver talks to, and asserting on this fixture's spy would be
            // an assertion that passes or fails on test ORDER.
            //
            // It is proven on the saver's own observable state machine instead:
            // only `save(force:)` drives `.saving -> .saved(a date)`, and
            // `StudioProjectSaverTests` already proves that `save(force:)` puts
            // `project.save` on the bus as a catalog envelope. Two halves, both
            // asserted, neither assumed.
            if command.name == "project.save" {
                var landed = false
                await f.wait(timeout: 3.0) {
                    if case .saved(let date) = StudioProjectSaver.shared.status, date != nil {
                        landed = true
                    }
                    return landed
                }
                XCTAssertTrue(
                    landed,
                    "project.save: the palette row never drove StudioProjectSaver to a written checkpoint")
                if landed { proven.append(command.name) }
                f.teardown()
                continue
            }
            let reached = await f.busSaw(command.name)
            XCTAssertTrue(
                reached,
                """
                \(command.name): the palette LISTS it, it read as ready, and \
                selecting it put nothing on the command bus. That is exactly the \
                "listed but inert" row this lane exists to make impossible.
                """)
            if reached { proven.append(command.name) }
            f.teardown()
        }

        // A guard against the whole loop degenerating: `Executed 0` has passed
        // on this repo before.
        XCTAssertEqual(
            proven.count, StudioPaletteCommands.all.count,
            "unproven rows: \(Set(StudioPaletteCommands.all.map(\.name)).subtracting(proven).sorted())")
        XCTAssertGreaterThanOrEqual(
            proven.count, 50,
            "the palette reaches only \(proven.count) commands; it reached 11 before this lane")
    }

    // -----------------------------------------------------------------------
    // 4. Destructive rows do not fire on one keystroke.
    // -----------------------------------------------------------------------

    func testADestructiveRowNeedsASecondReturn() async {
        let f = PaletteFixture()
        await f.stageStandard()
        defer { f.teardown() }

        let remove = StudioPaletteCommands.all.first { $0.name == "clip.remove" }!
        XCTAssertTrue(remove.destructive)

        // First Return: a question, and NOTHING on the bus.
        let first = StudioPaletteFlow.step(
            for: remove, stage: .browsing, typed: "", in: f.context)
        guard case .askForConfirmation(let prompt) = first else {
            return XCTFail("clip.remove fired on the first Return of a fuzzy match")
        }
        XCTAssertTrue(prompt.lowercased().contains("return again"),
                      "the confirm prompt must say what to press: \"\(prompt)\"")
        let sentBefore = await f.spy.names()
        XCTAssertFalse(sentBefore.contains("clip.remove"),
                       "clip.remove reached the bus while only a confirmation was shown")

        // Second Return: it commits.
        let second = StudioPaletteFlow.step(
            for: remove, stage: .confirming(name: "clip.remove"), typed: "", in: f.context)
        guard case .commit(let value) = second else {
            return XCTFail("a second Return on a confirmed row still did not commit")
        }
        remove.perform(f.context, value)
        let reached = await f.busSaw("clip.remove")
        XCTAssertTrue(reached, "the confirmed delete never reached the bus")
    }

    func testEveryRowThatRemovesSomethingIsMarkedDestructive() {
        // Named longhand rather than derived from the name, so a row that
        // deletes under a gentler verb still has to be listed here on purpose.
        let removers = ["track.remove", "clip.remove", "device.remove", "note.remove",
                        "autolane.clear", "route.node.remove", "fx.remove", "record.cancel"]
        for name in removers {
            guard let command = StudioPaletteCommands.all.first(where: { $0.name == name }) else {
                XCTFail("\(name) is no longer offered; drop it from this list on purpose")
                continue
            }
            XCTAssertTrue(
                command.destructive,
                """
                \(name) destroys something the user made and a fuzzy-matched \
                Return can land on it by accident. It must ask a second time.
                """)
        }
    }

    // -----------------------------------------------------------------------
    // 5. The two typed strings that are not numbers.
    // -----------------------------------------------------------------------

    func testTimeSignatureParsingIsStrict() {
        XCTAssertEqual(StudioPaletteParse.timeSignature("3/4"),
                       StudioTimeSignature(beatsPerBar: 3, beatUnit: 4))
        XCTAssertEqual(StudioPaletteParse.timeSignature(" 6 / 8 "),
                       StudioTimeSignature(beatsPerBar: 6, beatUnit: 8))
        // 3 is not a power of two, which is what the catalog's own enum says.
        XCTAssertNil(StudioPaletteParse.timeSignature("4/3"))
        XCTAssertNil(StudioPaletteParse.timeSignature("4"))
        XCTAssertNil(StudioPaletteParse.timeSignature("four/four"))
        XCTAssertNil(StudioPaletteParse.timeSignature("0/4"))
    }

    func testEffectNamesAreReadTheWayTheyArePrinted() {
        XCTAssertEqual(StudioPaletteParse.fxKind("reverb"), .reverb)
        XCTAssertEqual(StudioPaletteParse.fxKind("Reverb"), .reverb)
        XCTAssertEqual(StudioPaletteParse.fxKind("EQ"), .eq)
        XCTAssertEqual(StudioPaletteParse.fxKind("Compressor"), .compressor)
        XCTAssertNil(StudioPaletteParse.fxKind("flanger"))
        XCTAssertEqual(StudioFxKind.allCases.count, 9,
                       "nine effects; a tenth needs a line in this test")
    }

    func testRubbishInAnArgumentIsRejectedNotReadAsZero() {
        let tempo = StudioPaletteCommands.all.first { $0.name == "project.setTempo" }!
        XCTAssertNil(tempo.parse("banana"), "\"banana\" must not become a tempo")
        XCTAssertNil(tempo.parse(""), "an empty field must not become a tempo")
        XCTAssertEqual(tempo.parse("140"), .number(140))
        // Out of range is CLAMPED and the clamped value is what is sent, the
        // same contract `StudioTypedEntry` states for every other field.
        XCTAssertEqual(tempo.parse("900"), .number(300))
        XCTAssertEqual(tempo.parse("1"), .number(20))
    }

    // -----------------------------------------------------------------------
    // 6. Searching for it in the words a person actually has.
    // -----------------------------------------------------------------------

    func testTheListIsSearchableByWhatCommandsDoNotOnlyByTheirNames() {
        let entries = StudioPaletteCatalog.entries()
        let quantize = StudioPaletteCatalog.matches("beat", in: entries)
        XCTAssertTrue(
            quantize.contains { $0.id == "note.quantize" },
            "typing \"beat\" does not find quantize; nobody types \"note.quantize\"")

        let louder = StudioPaletteCatalog.matches("volume", in: entries)
        XCTAssertTrue(louder.contains { $0.id == "mix.gain" },
                      "typing \"volume\" does not find the track fader")

        // A typed command NAME still wins its own tie.
        let split = StudioPaletteCatalog.matches("clip.sp", in: entries)
        XCTAssertEqual(split.first?.id, "clip.split",
                       "an exact name prefix must rank first")
    }

    func testThePaletteReachesFarMoreThanTheElevenItStartedWith() {
        let entries = StudioPaletteCatalog.entries()
        let catalogRows = entries.filter { $0.command != nil }
        XCTAssertEqual(
            catalogRows.count, StudioPaletteCommands.all.count,
            "a row in the table is not being listed, or one is listed twice")
        XCTAssertGreaterThanOrEqual(catalogRows.count, 50)
        // The headline: quantize shipped and could not be found from ⌘K.
        for name in ["note.quantize", "fx.add", "mix.gain", "track.setInputChannel",
                     "route.node.add", "project.setTempo"] {
            XCTAssertTrue(catalogRows.contains { $0.id == name },
                          "\(name) is still not reachable from the command palette")
        }
    }

    // -----------------------------------------------------------------------
    // 7. Pixels. The reason string is a whole sentence in a tight HStack, which
    //    is the shape that blew the transport row to 475 pt.
    // -----------------------------------------------------------------------

    func testABlockedRowsReasonDoesNotBlowTheRowHeight() async {
        let f = PaletteFixture()
        f.model.startPolling()
        await f.wait { f.model.snapshot != nil }
        defer { f.teardown() }

        let palette = StudioCommandPalette(model: f.model)
        let renderer = ImageRenderer(content: palette.environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            return XCTFail("the palette did not rasterize at all")
        }
        XCTAssertEqual(image.width, 520,
                       "the palette is 520 pt wide by declaration")
        // A row is ~26 pt and the list is capped at 320 pt plus the field. If a
        // reason wrapped to one character per line the height would run into
        // the thousands.
        XCTAssertLessThanOrEqual(
            image.height, 420,
            """
            The palette rasterized \(image.height) pt tall. The list is capped at \
            320 pt, so anything much over that means a Text wrapped — the \
            reason string is the long one, and an unconstrained Text in a tight \
            HStack wraps to one character per line.
            """)
        XCTAssertGreaterThan(image.height, 60, "the palette drew nothing but its field")
    }
}

// MARK: - One row, measured

/// The palette as a whole is capped at 320 pt by `frame(maxHeight:)`, so its
/// overall raster height cannot report a row that wrapped — which is why the
/// mutation that removed the reason string's `lineLimit(1)` passed the
/// whole-palette pixel test. This measures ONE row, which is the thing that can
/// actually go wrong.
@MainActor
final class StudioPaletteRowPixelTests: XCTestCase {

    private func height(_ view: some View, width: CGFloat) -> CGFloat? {
        let renderer = ImageRenderer(
            content: view.frame(width: width).environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        return CGFloat(cg.height)
    }

    private var longReasonRow: StudioPaletteRow {
        // The longest reason in the table, verbatim. If a longer one is added,
        // this test should be pointed at that one.
        StudioPaletteRow(
            entry: StudioPaletteEntry(
                id: "track.setInputChannel",
                title: "Choose which microphone socket this track records from",
                subtitle: "command catalog v2", keys: nil,
                kind: .view { _ in }),
            availability: .blocked(StudioPaletteContext.noTrackReason),
            highlighted: false)
    }

    func testABlockedRowIsOneLineTallAtThePalettesOwnWidth() throws {
        let h = try XCTUnwrap(height(longReasonRow, width: 520))
        XCTAssertEqual(
            h, StudioPaletteRow.rowHeight,
            """
            One palette row rasterized \(h) pt at the palette's own 520 pt width, \
            not the \(StudioPaletteRow.rowHeight) pt every row is declared to be. \
            The reason string is a whole sentence in a tight HStack: without \
            lineLimit(1) it wraps, and an unconstrained Text wraps to ONE \
            CHARACTER PER LINE — which is what took the transport row to 475 pt.
            """)
    }

    /// The same row squeezed. A narrow palette must truncate the sentence, never
    /// grow the row — this is the width at which a wrap would actually happen.
    func testABlockedRowStillDoesNotGrowWhenTheReasonHasNoRoom() throws {
        let h = try XCTUnwrap(height(longReasonRow, width: 260))
        XCTAssertEqual(
            h, StudioPaletteRow.rowHeight,
            "a row squeezed to 260 pt became \(h) pt instead of truncating its reason")
    }

    func testAReadyRowAndABlockedRowAreTheSameHeight() throws {
        let ready = StudioPaletteRow(
            entry: StudioPaletteEntry(
                id: "clip.split", title: "Cut the clip in two at the play head",
                subtitle: "command catalog v2", keys: "Cmd E", kind: .view { _ in }),
            availability: .ready, highlighted: false)
        let a = try XCTUnwrap(height(ready, width: 520))
        let b = try XCTUnwrap(height(longReasonRow, width: 520))
        XCTAssertEqual(
            a, b,
            "a blocked row is \(b) pt and a ready row is \(a) pt — the list would jitter as the selection changes")
    }

    // The assertion that actually moves when the constraint is removed. The row
    // is pinned to `rowHeight`, so measuring the ROW cannot see a wrap — it
    // reports 28 pt whether the sentence fitted or was clipped. This measures
    // the label, which is the only thing in the row that can wrap.
    func testTheRemedySentenceNeverWraps() throws {
        let label = StudioPaletteReasonLabel(reason: StudioPaletteContext.noTrackReason)
        // 90 pt is far narrower than the sentence needs, so an unlimited Text
        // would wrap here — to several lines at best, one character per line at
        // worst.
        let squeezed = try XCTUnwrap(height(label, width: 90))
        XCTAssertEqual(
            squeezed, StudioPaletteReasonLabel.singleLineHeight,
            """
            The remedy sentence rasterized \(squeezed) pt at 90 pt wide, not the \
            \(StudioPaletteReasonLabel.singleLineHeight) pt of one 10 pt line. It \
            wrapped. In a tight HStack an unconstrained Text wraps to ONE \
            CHARACTER PER LINE, which took the transport row to 475 pt.
            """)
        let roomy = try XCTUnwrap(height(label, width: 520))
        XCTAssertEqual(roomy, StudioPaletteReasonLabel.singleLineHeight,
                       "the sentence is not one line even with room to spare")
    }
}
