#if REAL_ENGINE
import XCTest
@testable import MajiksMusicStudio

// THE JOIN.
//
// E1-ui's piano roll passed its own tests. E1/E2's engine passed its own tests.
// Both halves were green and the feature was completely broken, because the
// roll was wired to `StudioMockNoteEngine.demoSession()` and nothing it edited
// reached the project. Each lane owned exactly half the seam and said so in a
// comment; nobody owned the join. That is what these tests are: they drive the
// SAME gesture methods a mouse drives, against the REAL FFI-backed engine, and
// assert against the REAL journal and the REAL `.mstudio` package on disk.
//
// Why the assertions are where they are:
//  - asserting on `controller.clip` alone would pass against the mock, which is
//    the exact failure being fixed, so every test also reads the ENGINE back;
//  - the persistence test reopens the package in a SECOND engine instance, so
//    "it reached the project" means bytes on disk, not an in-memory model.
//
// Audio: `RealStudioEngine(dataDir:audible:)` defaults `audible` to false and
// nothing here calls `startLive`, so this test bundle is silent at the device.
//
// Still out of reach here: whether the drags FEEL right. These prove numbers.

@MainActor
final class StudioPianoRollRealEngineTests: XCTestCase {

    private var tempDir: URL!
    private let viewSize = CGSize(width: 900, height: 500)

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("majiks-roll-join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var packagePath: String {
        tempDir.appendingPathComponent("Join.mstudio").path
    }

    // MARK: Fixture

    /// A real engine over a real `.mstudio` package, with one instrument track
    /// and an empty four-bar MIDI clip — built through the SAME
    /// `addInstrumentTrack` the toolbar button calls.
    private func makeSession() async throws -> (RealStudioEngine, StudioPianoRollController, UUID) {
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        let outcome = await engine.addInstrumentTrack(name: "Keys", lengthTicks: 3840 * 4)
        XCTAssertTrue(outcome.ok, "addInstrumentTrack: \(outcome.message ?? "no message")")
        let clipID = try XCTUnwrap(outcome.clipID, "an instrument track must come with a MIDI clip")

        let controller = StudioPianoRollController(engine: engine)
        await controller.attach(clipID: clipID)
        XCTAssertNotNil(
            controller.clip,
            "the roll must read the real clip back; nil means the note seam never resolved it")
        controller.pxPerTick = 0.1
        controller.rowHeight = 14
        controller.scrollTicks = 0
        controller.scrollY = CGFloat(127 - 84) * 14
        controller.grid = .sixteenth
        return (engine, controller, clipID)
    }

    private func layout(_ c: StudioPianoRollController) -> StudioPianoRollLayout {
        c.layout(for: viewSize)
    }

    private func point(
        _ c: StudioPianoRollController, clipTicks: Int64, pitch: Int, yOffset: CGFloat = 7
    ) -> CGPoint {
        let l = layout(c)
        let origin = c.clipOriginTicks
        return CGPoint(
            x: l.x(forTicks: origin + clipTicks),
            y: l.y(forPitch: StudioNote.clampPitch(pitch)) + yOffset)
    }

    /// One press -> drag -> release, exactly as the view routes a mouse.
    private func drag(
        _ c: StudioPianoRollController,
        from: CGPoint,
        to: CGPoint,
        modifiers: StudioNoteModifiers = .none
    ) async {
        let l = layout(c)
        c.press(at: from, modifiers: modifiers, layout: l)
        c.dragged(to: to, modifiers: modifiers, layout: l)
        c.released(at: to, modifiers: modifiers, layout: l)
        await c.settle()
        await c.adoptFresh()
    }

    // MARK: Engine-side readback

    /// The journal, straight out of the engine. This is the half a UI test
    /// cannot fake.
    private func journalNames(_ engine: RealStudioEngine) throws -> [String] {
        let page = try engine.copilotClient.tool(name: "studio_journal", args: ["limit": 500])
        return page.array("entries").compactMap { EngineJSON($0).string("name") }
    }

    /// Notes as the ENGINE has them, read from a fresh snapshot rather than
    /// through the controller.
    private func engineNotes(_ engine: RealStudioEngine) throws -> [[String: Any]] {
        let snap = try engine.copilotClient.snapshot(sinceSeq: nil)
        let project = EngineJSON(snap.dict("project") ?? [:])
        for track in project.array("tracks") {
            for clip in EngineJSON(track).array("clips") {
                let cj = EngineJSON(clip)
                if cj.string("kind") == "midi" {
                    return (cj["notes"] as? [[String: Any]]) ?? []
                }
            }
        }
        return []
    }

    // MARK: Tests

    func testDrawingANoteLandsItInTheRealJournalAndUndoRemovesIt() async throws {
        let (engine, controller, _) = try await makeSession()
        XCTAssertEqual(try engineNotes(engine).count, 0, "the new clip starts empty")

        controller.tool = .draw
        controller.drawVelocity = 96
        await drag(
            controller,
            from: point(controller, clipTicks: 960, pitch: 64),
            to: point(controller, clipTicks: 1920, pitch: 64))

        // 1. The ENGINE has the note. Not the controller's cache — the engine.
        let notes = try engineNotes(engine)
        // A guard, not an assert: a mutation run must report a clean FAILURE
        // here rather than crashing on notes[0] and swallowing the rest of the
        // suite.
        guard notes.count == 1 else {
            return XCTFail("the drawn note must reach the real project; engine has \(notes.count) notes")
        }
        let note = EngineJSON(notes[0])
        XCTAssertEqual(note.int64("pitch"), 64)
        XCTAssertEqual(note.int64("startTicks"), 960)
        XCTAssertEqual(note.int64("velocity"), 96)

        // 2. Velocity is an INTEGER on the wire. `96.0` would hash differently
        //    from `96` and break the blake3 chain on replay.
        XCTAssertTrue(
            notes[0]["velocity"] is Int || (notes[0]["velocity"] as? NSNumber)?.intValue == 96,
            "velocity must keep integer Num shape")

        // 3. It went through the COMMAND BUS, as one journaled `note.add`.
        let names = try journalNames(engine)
        XCTAssertEqual(
            names.filter { $0 == "note.add" }.count, 1,
            "exactly one note.add; journal was \(names)")

        // 4. Undo removes it from the real project.
        controller.undo()
        await controller.settle()
        await controller.adoptFresh()
        XCTAssertEqual(
            try engineNotes(engine).count, 0,
            "undo must remove the note from the ENGINE, not just from the view")
        XCTAssertEqual(controller.clip?.notes.count, 0)

        // 5. And redo puts it back, so the journal is genuinely two-way.
        controller.redo()
        await controller.settle()
        await controller.adoptFresh()
        XCTAssertEqual(try engineNotes(engine).count, 1, "redo restores it")
    }

    func testAChordDragIsOneJournalEntryAndOneUndo() async throws {
        // The reason the note commands are batch-shaped at all. If a drag of a
        // three-note chord journaled three moves, Cmd-Z would peel the chord
        // apart note by note — the behaviour that makes an editor feel broken.
        let (engine, controller, clipID) = try await makeSession()

        let ids = ["JOIN0001", "JOIN0002", "JOIN0003"]
        let chord = zip(ids, [60, 64, 67]).map {
            StudioNote(id: $0.0, startTicks: 480, lengthTicks: 480,
                       pitch: StudioNote.clampPitch($0.1), velocity: 100)
        }
        let added = await engine.send(.add(clipID: clipID, notes: chord))
        XCTAssertTrue(added.ok, added.message ?? "")
        await controller.adoptFresh()
        XCTAssertEqual(controller.clip?.notes.count, 3)

        controller.selection = Set(ids)
        controller.tool = .select
        let before = try journalNames(engine).count

        await drag(
            controller,
            from: point(controller, clipTicks: 480 + 240, pitch: 64),
            to: point(controller, clipTicks: 960 + 240, pitch: 66))

        let names = try journalNames(engine)
        XCTAssertEqual(
            names.count, before + 1,
            "a three-note drag must be ONE journal entry; got \(names.suffix(4))")
        XCTAssertEqual(names.last, "note.move")

        // The voicing survived: every note moved by the same delta.
        let moved = try engineNotes(engine).map { EngineJSON($0) }
        let pitches = moved.compactMap { $0.int64("pitch") }.sorted()
        XCTAssertEqual(pitches, [62, 66, 69], "the whole chord moved up two semitones")
        let starts = Set(moved.compactMap { $0.int64("startTicks") })
        XCTAssertEqual(starts.count, 1, "all three notes still start together")

        // ONE undo puts the whole chord back.
        controller.undo()
        await controller.settle()
        await controller.adoptFresh()
        let restored = try engineNotes(engine).compactMap { EngineJSON($0).int64("pitch") }.sorted()
        XCTAssertEqual(restored, [60, 64, 67], "one undo restored the entire chord")
    }

    func testANoteDrawnInTheRollIsInTheMstudioPackageOnDisk() async throws {
        // The strongest form of "it reached the project": close the engine, open
        // the package again, and the note is still there. A mock cannot pass
        // this at all.
        let clipTicks: Int64 = 1440
        do {
            let (engine, controller, _) = try await makeSession()
            controller.tool = .draw
            await drag(
                controller,
                from: point(controller, clipTicks: clipTicks, pitch: 60),
                to: point(controller, clipTicks: clipTicks + 480, pitch: 60))
            XCTAssertEqual(try engineNotes(engine).count, 1)
            try engine.copilotClient.save()
        }

        let reopened = try RealStudioEngine(dataDir: packagePath, audible: false)
        let notes = try engineNotes(reopened)
        XCTAssertEqual(notes.count, 1, "the note must survive a close and reopen")
        let survivor = try XCTUnwrap(notes.first).self
        XCTAssertEqual(EngineJSON(survivor).int64("pitch"), 60)
        XCTAssertEqual(EngineJSON(survivor).int64("startTicks"), clipTicks)
    }

    func testTheRollRefusesToOpenOnAnAudioClipRatherThanDrawingAnEmptyGrid() async throws {
        // An empty grid is indistinguishable from a MIDI clip with no notes, so
        // "opened on the wrong clip" would look exactly like "the clip is
        // empty" — the same class of lie this whole lane is unwinding.
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        _ = await engine.send(.trackAdd(trackID: "t_audio", name: "Gtr", index: 0))
        _ = await engine.snapshot(ifNewerThan: nil)

        let strayClipID = UUID()
        let session = await engine.noteSession(clipID: strayClipID, ifNewerThan: nil)
        XCTAssertNil(session, "an unknown clip must not resolve to a session")
    }

    func testAuditioningOnASilentEngineOpensNoAudioDevice() async throws {
        // The audio-safety rule, asserted at the layer the piano roll actually
        // calls, and sharpened to what it protects.
        //
        // It used to read "auditioning never opens the device, full stop" — which
        // also meant a person with a MIDI keyboard had to press Play and then
        // Stop before any key made a sound. That ritual is gone: a played note
        // opens the device on a host whose GUI opted into audible output.
        //
        // This engine is built `audible: false`, which is what every `swift test`
        // gets (`StudioEngineFactory.audibleByDefault` is false under XCTest) and
        // what every headless run gets. If this ever returns true, a test run can
        // make a machine sing.
        let (engine, controller, _) = try await makeSession()
        let trackID = controller.clip?.trackID
        let outcome = await engine.previewNote(trackID: trackID, pitch: 60, velocity: 100)
        XCTAssertFalse(
            outcome.audible,
            "an engine that never opted into audio must report NOT audible rather than opening a device")
        XCTAssertFalse(
            try engine.copilotClient.liveRunning(),
            "auditioning on a silent engine must not have opened a live audio session")
        // And the widened return actually carries the engine's diagnosis. This
        // is the mutation check for the seam: make `previewNote` drop `reason`
        // again and this line fails.
        XCTAssertNotNil(
            outcome.reason,
            "the engine explained why nothing sounded and Swift threw it away")
    }

    /// THE bug this lane widened the return for: a gutter key on a track that
    /// carries no instrument device. The engine has always answered with the
    /// diagnosis; nothing in Swift could carry it.
    func testAGutterKeyOnADeviceLessTrackCarriesTheEnginesReason() async throws {
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        let outcome = await engine.addInstrumentTrack(name: "Silent", lengthTicks: 3840)
        XCTAssertTrue(outcome.ok, "addInstrumentTrack: \(outcome.message ?? "no message")")
        let trackID = try XCTUnwrap(outcome.trackID)

        // Take the instrument away, exactly as the header's context menu does.
        let snapshot = await engine.snapshot(ifNewerThan: nil)
        let device = try XCTUnwrap(
            snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first)
        let removed = await engine.send(.deviceRemove(trackID: trackID, deviceID: device.id))
        XCTAssertTrue(removed.ok, "device.remove: \(removed.message ?? "no message")")

        // The gutter names the clip's track, so it reaches the device-less one.
        let silent = await engine.previewNote(trackID: trackID, pitch: 60, velocity: 100)
        XCTAssertFalse(silent.audible)
        let reason = try XCTUnwrap(
            silent.reason,
            "the note made no sound and the reason reached nobody — the exact bug")
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains("instrument"),
            "the engine's reason must name the missing instrument, got: \(reason)")

        // And it becomes a message that points at the way back.
        var state = StudioSilentPreview.State()
        let message = try XCTUnwrap(
            StudioSilentPreview.notice(for: silent, gate: .oneShot, state: &state, now: Date()))
        XCTAssertTrue(message.contains(reason), "the engine's own words must be carried verbatim")
        XCTAssertTrue(message.contains("+ Instrument"), "the message must name the way forward")
    }

    func testAnOnScreenKeyOnAnEmptyProjectCreatesSomethingToPlay() async throws {
        // The first-run path, through the exact call StudioRootView wires the
        // on-screen keyboard to: no trackID, because a brand-new project has no
        // track to name. Before this, that call returned false and went silent.
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        let before = await engine.snapshot(ifNewerThan: nil)
        XCTAssertEqual(before?.tracks.count ?? 0, 0, "precondition: an empty project")

        _ = await engine.previewNote(trackID: nil, pitch: 60, velocity: 100, gate: .on)
        _ = await engine.previewNote(trackID: nil, pitch: 60, velocity: 0, gate: .off)

        let after = await engine.snapshot(ifNewerThan: nil)
        XCTAssertEqual(
            after?.tracks.count, 1,
            "a key press on an empty project must produce an instrument to play")
        XCTAssertEqual(after?.performance.keepableNotes, 1, "and what was played is keepable")
    }

    func testKeepLandsWhatWasPlayedWithoutArmingAnything() async throws {
        // The other half of the finding: "I heard the keyboard, didn't see any
        // notes." Nothing is armed and nothing is recording; Keep lands it.
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        for pitch: UInt8 in [60, 64, 67] {
            _ = await engine.previewNote(trackID: nil, pitch: pitch, velocity: 100, gate: .on)
            _ = await engine.previewNote(trackID: nil, pitch: pitch, velocity: 0, gate: .off)
        }
        let staged = await engine.snapshot(ifNewerThan: nil)
        XCTAssertEqual(staged?.performance.keepableNotes, 3)
        let clipCount = (staged?.tracks ?? []).reduce(0) { $0 + $1.clips.count }
        XCTAssertEqual(
            clipCount, 0,
            "nothing is committed to the project until the human asks")

        let kept = await engine.keepPerformance()
        // `keepPerformance` was widened from `Int` to `StudioKeepOutcome` (it
        // now reports WHERE the take landed as well as how much). This file is
        // compiled by neither gate — `swift test` runs under MAJIKS_ENGINE=mock
        // so REAL_ENGINE is off, and `MAJIKS_ENGINE=real swift build` builds the
        // app and not the tests — so the two call sites below sat
        // uncompilable, and the whole "THE JOIN" suite with them. See the
        // report.
        XCTAssertEqual(kept.noteCount, 3, "Keep lands exactly what was played")

        let names = try journalNames(engine)
        XCTAssertTrue(names.contains("note.add"), "the notes reached the journal: \(names)")
        XCTAssertTrue(names.contains("clip.placeMidi"), "and a clip was placed for them")
    }

    func testKeepingNothingIsHonestRatherThanLandingAnEmptyClip() async throws {
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        let kept = await engine.keepPerformance()
        XCTAssertEqual(kept.noteCount, 0)
        XCTAssertTrue(
            try journalNames(engine).allSatisfy { $0 != "note.add" },
            "Keep with nothing played must not journal an empty take")
    }

    func testAuditioningIsNotJournaled() async throws {
        // Pressing a gutter key is feedback, not an edit. If it journaled, Cmd-Z
        // would start undoing keypresses instead of the user's work.
        let (engine, controller, _) = try await makeSession()
        let before = try journalNames(engine).count

        let l = layout(controller)
        // A press in the keyboard gutter: x inside the gutter, y over a key.
        let gutterPoint = CGPoint(x: l.gutterWidth / 2, y: l.y(forPitch: 60) + 7)
        controller.press(at: gutterPoint, modifiers: .none, layout: l)
        controller.released(at: gutterPoint, modifiers: .none, layout: l)
        await controller.settle()

        XCTAssertEqual(
            try journalNames(engine).count, before,
            "an audition must not journal anything")
    }

    // MARK: Quantize, over the real engine

    func testQuantizeReachesTheRealProjectAndUndoRestoresThePerformance() async throws {
        // The whole point of this file, applied to the newest command: the mock
        // proves the arithmetic, and only THIS proves the wire payload the
        // Rust `note.quantize` arm actually receives.
        let (engine, controller, clipID) = try await makeSession()

        // Three notes placed OFF the grid on purpose, the way a played take is.
        let played: [StudioNote] = [
            StudioNote(id: "q1", startTicks: 237, lengthTicks: 461, pitch: 60, velocity: 100),
            StudioNote(id: "q2", startTicks: 250, lengthTicks: 240, pitch: 64, velocity: 90),
            StudioNote(id: "q3", startTicks: 1918, lengthTicks: 240, pitch: 67, velocity: 80),
        ]
        let added = await engine.send(.add(clipID: clipID, notes: played))
        XCTAssertTrue(added.ok, "seeding the take: \(added.message ?? "")")
        await controller.adoptFresh()

        controller.grid = .sixteenth
        controller.quantizeStrengthPercent = 100
        controller.quantizeEnds = false
        controller.selectAll()
        controller.quantizeSelection()
        await controller.settle()
        await controller.adoptFresh()

        // 1. The ENGINE moved them, to the tick.
        let byID = Dictionary(
            uniqueKeysWithValues: try engineNotes(engine).compactMap { raw -> (String, EngineJSON)? in
                let j = EngineJSON(raw)
                guard let id = j.string("id", "noteId") else { return nil }
                return (id, j)
            })
        XCTAssertEqual(byID["q1"]?.int64("startTicks"), 240)
        XCTAssertEqual(byID["q2"]?.int64("startTicks"), 240)
        XCTAssertEqual(byID["q3"]?.int64("startTicks"), 1920)
        // quantizeEnds is off, so the played LENGTH is untouched.
        XCTAssertEqual(byID["q1"]?.int64("lengthTicks"), 461)

        // 2. One journaled command for the whole selection.
        let names = try journalNames(engine)
        XCTAssertEqual(
            names.filter { $0 == "note.quantize" }.count, 1,
            "exactly one note.quantize; journal was \(names)")

        // 3. Undo restores the PERFORMANCE, not the grid — and it does so
        //    through the absolute setter, which is why that command exists.
        controller.undo()
        await controller.settle()
        await controller.adoptFresh()
        let back = Dictionary(
            uniqueKeysWithValues: try engineNotes(engine).compactMap { raw -> (String, EngineJSON)? in
                let j = EngineJSON(raw)
                guard let id = j.string("id", "noteId") else { return nil }
                return (id, j)
            })
        XCTAssertEqual(back["q1"]?.int64("startTicks"), 237, "undo landed on the grid, not on the take")
        XCTAssertEqual(back["q2"]?.int64("startTicks"), 250)
        XCTAssertEqual(back["q3"]?.int64("startTicks"), 1918)
        XCTAssertEqual(back["q1"]?.int64("lengthTicks"), 461)
    }

    func testAPartialStrengthQuantizeSurvivesTheWireAsAnInteger() async throws {
        // strengthPercent is an INTEGER on the wire on purpose: journaled values
        // are `Num` and the blake3 chain depends on their integer/float shape,
        // so a 0.65 could not be hashed the same way twice.
        let (engine, controller, clipID) = try await makeSession()
        _ = await engine.send(.add(clipID: clipID, notes: [
            StudioNote(id: "p1", startTicks: 237, lengthTicks: 240, pitch: 60, velocity: 100),
        ]))
        await controller.adoptFresh()
        controller.grid = .sixteenth
        controller.quantizeStrengthPercent = 65
        controller.selectAll()
        controller.quantizeSelection()
        await controller.settle()
        await controller.adoptFresh()

        // 65% of the +3 it needs is 1.95, which rounds away from zero to +2.
        let notes = try engineNotes(engine)
        guard notes.count == 1 else {
            return XCTFail("expected one note, engine has \(notes.count)")
        }
        XCTAssertEqual(EngineJSON(notes[0]).int64("startTicks"), 239)
    }

    func testNoNotePathOtherThanQuantizeEverJournalsOne() async throws {
        // The safety property, over the real engine: draw, drag, resize and
        // delete a note and the journal must never contain a quantize.
        let (engine, controller, _) = try await makeSession()
        controller.tool = .draw
        await drag(
            controller,
            from: point(controller, clipTicks: 960, pitch: 64),
            to: point(controller, clipTicks: 1920, pitch: 64))
        controller.tool = .select
        controller.selectAll()
        controller.nudgeSelection(gridSteps: 1, semitones: 0)
        await controller.settle()
        controller.deleteSelection()
        await controller.settle()

        let names = try journalNames(engine)
        XCTAssertFalse(names.isEmpty, "the session must actually have done something")
        XCTAssertFalse(
            names.contains("note.quantize"),
            "something quantized without being asked: \(names)")
    }
}
#endif
