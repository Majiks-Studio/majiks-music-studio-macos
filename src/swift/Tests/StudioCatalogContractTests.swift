import Combine
import XCTest
@testable import MajiksMusicStudio

/// THE CLASS GUARD: Swift's catalog parameters have to be the contract's, and
/// something other than a person reading has to say so.
///
/// # What went wrong, and why six gates were green
///
/// Eleven shipping gestures sent the **mock engine's** parameter names rather
/// than the catalog's — `gain` for `gainDb`, `height` for `heightPx`, `index`
/// for `newIndex`, and `marker.set` / `section.set` did not send the contract's
/// parameters at all. `engine/timeline-core/src/session.rs` validates params
/// against `command-catalog.v2.json` with `additionalProperties: false` before
/// apply, so the real engine refused every one of them.
///
/// **`StudioMockEngine.applyCatalog` read the same wrong keys.** So every test
/// of every one of those gestures passed. The test seam agreed with the bug,
/// which is the only reason a wrong key could survive being written eleven
/// times: there was no build in which it failed.
///
/// # What this file asserts, and what each assertion can distinguish
///
/// The mock is the thing that hid this, so "it passes under `MAJIKS_ENGINE=mock`"
/// proves less than usual here. Each test below therefore names its own
/// target:
///
///  * `testTheEmbeddedContractMatchesCommandCatalogV2OnDisk` compares the
///    generated copy to **the contract file**. Nothing about the mock can make
///    it pass.
///  * `testEveryShippingGestureBuildsAnEnvelopeTheContractAccepts` validates
///    what the view model actually emits against **the schema read from disk at
///    test time** — not against the embedded copy, and not against the mock's
///    idea of the keys. If Swift and the contract disagree it fails, whichever
///    of them is wrong.
///  * `testAWrongParameterNameIsRefusedUnderTheMock` is the guard itself: it
///    proves a **newly written** wrong key fails in the mock build, which is
///    the build every other test runs in. This is the assertion that closes the
///    class rather than the eleven instances.
///  * `testACorrectEnvelopeIsAcceptedUnderTheMock` is its negative control. A
///    guard that refuses everything would satisfy the test above and break the
///    app.
///
/// # One traversal, not two
///
/// `catalog_descriptions.rs` was mutated and survived, because its coverage
/// assertion counted parameters with its **own copy** of the traversal it was
/// policing: deleting the array descent from the real walk left both tests
/// green. The same trap applies here, so every check below goes through
/// `StudioCatalogSchema.violations` — the exact entry point the mock engine
/// calls. There is no second validator in this file to disagree with the
/// shipping one.
@MainActor
final class StudioCatalogContractTests: XCTestCase {

    // MARK: The contract, read from disk

    /// `{commandName: paramsSchema}` straight out of the contract file.
    ///
    /// Located from `#filePath` rather than the working directory: a filtered
    /// or IDE-launched run has a different cwd, and a test that silently reads
    /// nothing is the failure mode this whole file exists to prevent.
    private static func contractOnDisk() throws -> [String: Any] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // swift
            .deletingLastPathComponent()   // src
            .deletingLastPathComponent()   // repo root
        let url = repoRoot
            .appendingPathComponent("engine")
            .appendingPathComponent("contracts")
            .appendingPathComponent("command-catalog.v2.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "command-catalog.v2.json is not a JSON object")
        let commands = try XCTUnwrap(root["commands"] as? [[String: Any]],
                                     "command-catalog.v2.json has no commands array")
        XCTAssertFalse(commands.isEmpty, "read an EMPTY catalog - the path is wrong")
        var out: [String: Any] = [:]
        for command in commands {
            let name = try XCTUnwrap(command["name"] as? String)
            out[name] = try XCTUnwrap(command["paramsSchema"],
                                      "\(name) has no paramsSchema")
        }
        return out
    }

    func testTheEmbeddedContractMatchesCommandCatalogV2OnDisk() throws {
        let disk = try Self.contractOnDisk()
        let embedded = StudioCatalogSchema.schemas
        XCTAssertEqual(
            Set(embedded.keys), Set(disk.keys),
            "CatalogSchemas.swift lists different commands than the contract - "
            + "run src/swift/scripts/generate-catalog-names.sh")
        for (name, schema) in disk {
            // NSDictionary equality compares the parsed JSON structurally, so
            // key order cannot make this pass or fail for the wrong reason.
            XCTAssertEqual(
                embedded[name] as? NSDictionary, schema as? NSDictionary,
                "\(name)'s paramsSchema in CatalogSchemas.swift is not the one in "
                + "command-catalog.v2.json - run src/swift/scripts/generate-catalog-names.sh")
        }
    }

    // MARK: The eleven

    /// Every gesture, the method that drives it, and what a person clicked.
    ///
    /// Table-driven so a twelfth gesture is one row rather than a new test
    /// nobody writes.
    private struct Gesture {
        var catalogName: String
        var describedAs: String
        var drive: @MainActor (StudioViewModel, StudioProjectSnapshot) -> Void
    }

    private static func theElevenGestures() -> [Gesture] {
        [
            Gesture(catalogName: "track.rename", describedAs: "Rename Track") { model, snap in
                guard let track = snap.tracks.first else { return }
                model.renameTrack(track.id, name: "Drums")
            },
            Gesture(catalogName: "track.reorder", describedAs: "drag a track to a new row") { model, snap in
                guard let track = snap.tracks.first else { return }
                model.reorderTrack(track.id, to: 2)
            },
            Gesture(catalogName: "track.setColor", describedAs: "the colour swatch menu") { model, snap in
                guard let track = snap.tracks.first else { return }
                model.setTrackColor(track.id, color: .orange)
            },
            Gesture(catalogName: "track.setHeight", describedAs: "the H menu -> Large") { model, snap in
                guard let track = snap.tracks.first else { return }
                model.setTrackHeight(track.id, height: 160)
            },
            Gesture(catalogName: "clip.rename", describedAs: "Rename Clip") { model, snap in
                guard let clip = snap.tracks.first?.clips.first else { return }
                model.renameClip(clip.id, name: "Main Riff")
            },
            Gesture(catalogName: "clip.setGain", describedAs: "Clip Gain -> -3 dB") { model, snap in
                guard let clip = snap.tracks.first?.clips.first else { return }
                model.setClipGain(clip.id, gainDB: -3)
            },
            Gesture(catalogName: "clip.mute", describedAs: "Mute clip") { model, snap in
                guard let clip = snap.tracks.first?.clips.first else { return }
                model.setClipMute(clip.id, muted: true)
            },
            Gesture(catalogName: "marker.set", describedAs: "Add Marker Here") { model, _ in
                model.setMarker(name: "CHORUS", bar: 16)
            },
            Gesture(catalogName: "marker.remove", describedAs: "Remove Marker") { model, _ in
                model.removeMarker(markerID: "mk_1")
            },
            Gesture(catalogName: "section.set", describedAs: "Add Section Here") { model, _ in
                model.setSection(name: "VERSE 1", startBar: 8)
            },
            Gesture(catalogName: "section.remove", describedAs: "Remove Section") { model, snap in
                model.removeSection(sectionID: snap.sections.first?.id ?? "sec_1")
            },
        ]
    }

    func testEveryShippingGestureBuildsAnEnvelopeTheContractAccepts() async throws {
        let disk = try Self.contractOnDisk()
        let spy = CommandSpyEngine()
        let model = StudioViewModel(engine: spy)
        model.startPolling()
        defer { model.stopPolling() }
        await Self.wait(until: { model.snapshot != nil }, describedAs: "first snapshot")
        let snapshot = try XCTUnwrap(model.snapshot)
        XCTAssertFalse(snapshot.tracks.isEmpty, "fixture has no tracks to drive gestures on")

        let gestures = Self.theElevenGestures()
        XCTAssertEqual(gestures.count, 11, "the eleven refused gestures")
        for gesture in gestures { gesture.drive(model, snapshot) }

        let wanted = Set(gestures.map(\.catalogName))
        await Self.wait(
            until: {
                let seen = await Set(spy.commands.map(\.catalogName))
                return wanted.isSubset(of: seen)
            },
            describedAs: "all eleven envelopes reach the engine")

        var envelopes: [String: [String: AnyHashable]] = [:]
        for command in await spy.commands {
            if case .catalog(let name, let params) = command { envelopes[name] = params }
        }

        for gesture in gestures {
            guard let params = envelopes[gesture.catalogName] else {
                XCTFail("\(gesture.describedAs) sent no \(gesture.catalogName) envelope at all")
                continue
            }
            let schema = try XCTUnwrap(disk[gesture.catalogName],
                                       "\(gesture.catalogName) is not in the contract")
            // Against the schema READ FROM DISK, through the SAME walk the mock
            // engine runs. Not against CatalogSchemas.swift, so a stale
            // generated file cannot make a wrong envelope look right; not
            // against a second validator written here, so this cannot pass by
            // agreeing with a copy of itself.
            let violations = StudioCatalogSchema.violations(against: schema, params: params)
            XCTAssertTrue(
                violations.isEmpty,
                "\(gesture.describedAs) builds a \(gesture.catalogName) the engine refuses: "
                + "\(violations.joined(separator: "; ")) - params were \(params)")
        }
    }

    /// …and every one of them CHANGES THE PROJECT.
    ///
    /// Found by mutation: making `StudioMockEngine`'s apply half read `gain`
    /// while the envelope correctly says `gainDb` left all 444 tests green. The
    /// existing reachability tests assert only that a command with the right
    /// NAME reached the engine — the same green-on-the-wrong-axis shape as
    /// asserting a 200 rather than asserting the check passed. So an envelope
    /// could be schema-legal, be accepted, and do nothing, and nothing would
    /// say so.
    ///
    /// Each assertion below is on the SNAPSHOT after the gesture, which is what
    /// the user sees. It is sequential rather than table-driven on purpose:
    /// each effect is a different shape, and folding them into one comparison
    /// would blunt every one of them.
    func testEveryShippingGestureChangesTheProject() async throws {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await Self.wait(until: { model.snapshot != nil }, describedAs: "first snapshot")

        let trackID = try XCTUnwrap(model.snapshot?.tracks.first?.id)
        let clipID = try XCTUnwrap(model.snapshot?.tracks.first?.clips.first?.id)
        func track() -> StudioTrackSnapshot? {
            model.snapshot?.tracks.first { $0.id == trackID }
        }
        func clip() -> StudioClipSnapshot? {
            model.snapshot?.tracks.flatMap(\.clips).first { $0.id == clipID }
        }

        model.renameTrack(trackID, name: "Wurlitzer")
        await Self.wait(until: { track()?.name == "Wurlitzer" }, describedAs: "track.rename")

        model.setTrackColor(trackID, color: .teal)
        await Self.wait(until: { track()?.color == StudioTrackColor.teal.hex },
                        describedAs: "track.setColor")

        model.setTrackHeight(trackID, height: 160)
        await Self.wait(until: { track()?.height == 160 }, describedAs: "track.setHeight")

        model.renameClip(clipID, name: "Main Riff")
        await Self.wait(until: { clip()?.name == "Main Riff" }, describedAs: "clip.rename")

        model.setClipGain(clipID, gainDB: -3)
        await Self.wait(until: { clip()?.gainDB == -3 }, describedAs: "clip.setGain")

        model.setClipMute(clipID, muted: true)
        await Self.wait(until: { clip()?.muted == true }, describedAs: "clip.mute")

        // Reorder LAST among the track edits, so the lookups above are not
        // reading a row that moved under them.
        let namesBefore = try XCTUnwrap(model.snapshot?.tracks.map(\.name))
        model.reorderTrack(trackID, to: 2)
        await Self.wait(until: { model.snapshot?.tracks.map(\.name) != namesBefore },
                        describedAs: "track.reorder")
        XCTAssertEqual(model.snapshot?.tracks[2].id, trackID, "the track did not land at index 2")

        model.setMarker(name: "CHORUS", bar: 16)
        await Self.wait(until: { model.snapshot?.markers.contains { $0.name == "CHORUS" } == true },
                        describedAs: "marker.set")
        let marker = try XCTUnwrap(model.snapshot?.markers.first { $0.name == "CHORUS" })
        XCTAssertEqual(marker.bar, 16, "the marker landed at the wrong bar")

        model.removeMarker(markerID: marker.id)
        await Self.wait(until: { model.snapshot?.markers.contains { $0.id == marker.id } == false },
                        describedAs: "marker.remove")

        model.setSection(name: "SOLO", startBar: 40)
        await Self.wait(until: { model.snapshot?.sections.contains { $0.name == "SOLO" } == true },
                        describedAs: "section.set")
        let section = try XCTUnwrap(model.snapshot?.sections.first { $0.name == "SOLO" })
        XCTAssertEqual(section.startBar, 40, "the section landed at the wrong bar")

        model.removeSection(sectionID: section.id)
        await Self.wait(until: { model.snapshot?.sections.contains { $0.id == section.id } == false },
                        describedAs: "section.remove")
    }

    // MARK: The class guard

    /// A wrong parameter name written TODAY fails in the mock build.
    ///
    /// This is the headline. `track.setHeight` with `height` is exactly what
    /// shipped, and under the old mock it was accepted and applied — the gesture
    /// looked like it worked in every test while the real engine refused it.
    func testAWrongParameterNameIsRefusedUnderTheMock() async throws {
        let engine = StudioMockEngine()
        let fresh = await engine.snapshot(ifNewerThan: nil)
        let snapshot = try XCTUnwrap(fresh)
        let track = try XCTUnwrap(snapshot.tracks.first)

        let result = await engine.send(.catalog(name: "track.setHeight", params: [
            "trackId": track.id.uuidString,
            "height": 160,          // the mock's old name; the contract says heightPx
        ]))
        XCTAssertFalse(result.ok, "the mock accepted a parameter the engine refuses")
        let message = try XCTUnwrap(result.message)
        XCTAssertTrue(message.contains("height"),
                      "the refusal must name the offending key, got: \(message)")
    }

    /// A missing REQUIRED parameter fails too — the other half of
    /// `additionalProperties: false`, and the half `marker.set` was breaking.
    func testAMissingRequiredParameterIsRefusedUnderTheMock() async {
        let engine = StudioMockEngine()
        let result = await engine.send(.catalog(name: "marker.set", params: [
            "markerId": "mk_1",
            "positionTicks": 0,
            // no label
        ]))
        XCTAssertFalse(result.ok, "the mock accepted marker.set with no label")
        XCTAssertTrue(result.message?.contains("label") ?? false,
                      "the refusal must name the missing key, got: \(result.message ?? "nil")")
    }

    /// The negative control. A guard that refused everything would pass both
    /// tests above and break every gesture in the app.
    func testACorrectEnvelopeIsAcceptedUnderTheMock() async throws {
        let engine = StudioMockEngine()
        let fresh = await engine.snapshot(ifNewerThan: nil)
        let snapshot = try XCTUnwrap(fresh)
        let track = try XCTUnwrap(snapshot.tracks.first)

        let result = await engine.send(.catalog(name: "track.setHeight", params: [
            "trackId": track.id.uuidString,
            "heightPx": 160,
        ]))
        XCTAssertTrue(result.ok, "the contract's own spelling was refused: \(result.message ?? "")")
    }

    // MARK: The walk actually walks

    /// The validator descends into nested objects and array items.
    ///
    /// `catalog_descriptions.rs` shipped a coverage assertion that counted with
    /// a duplicate of the traversal it policed, so deleting the array descent
    /// from the real walk left both tests green. This asserts the descent
    /// through `violations` — the shipping entry point — using `note.add`,
    /// whose `notes` array carries per-item properties. Truncate the walk and
    /// this fails.
    func testTheValidatorDescendsIntoArrayItems() throws {
        let disk = try Self.contractOnDisk()
        let schema = try XCTUnwrap(disk["note.add"], "note.add is not in the contract")

        let good: [String: AnyHashable] = [
            "clipId": "clip_1",
            "notes": [["noteId": "n1", "pitch": 60, "startTicks": 0,
                       "lengthTicks": 480, "velocity": 100] as [String: AnyHashable]],
        ]
        XCTAssertEqual(StudioCatalogSchema.violations(against: schema, params: good), [],
                       "a well-formed note.add was refused")

        // The defect lives INSIDE an array item. Only a walk that descends can
        // see it.
        let bad: [String: AnyHashable] = [
            "clipId": "clip_1",
            "notes": [["noteId": "n1", "pitch": 60, "startTicks": 0, "lengthTicks": 480,
                       "velocity": 100, "loudness": 100] as [String: AnyHashable]],
        ]
        let violations = StudioCatalogSchema.violations(against: schema, params: bad)
        XCTAssertFalse(violations.isEmpty,
                       "an undeclared property inside notes[] was not seen - the walk stops at the array")
        XCTAssertTrue(violations.joined().contains("loudness"),
                      "the refusal must name the offending key, got \(violations)")
    }

    /// An unknown command name is an error, not a shrug.
    ///
    /// The alternative — answering "no violations" for a command the catalog
    /// has never heard of — would make every typo validate.
    func testAnUnknownCommandNameIsRefused() {
        let violations = StudioCatalogSchema.violations(name: "track.setHieght", params: [:])
        XCTAssertFalse(violations.isEmpty, "a misspelled command name validated clean")
    }

    // MARK: Saying so
    //
    // `StudioViewModel.send` used to be `Task { await engine.send(command) }` —
    // the result discarded. So a refusal and a success were the same event as
    // far as the app was concerned, and the person who right-clicked Rename got
    // nothing: no change, no message, no log line. These two tests are the
    // positive and the negative of that: a refused gesture says something a
    // person can read, and an accepted one says nothing at all.

    func testARefusedGestureSaysSoInWordsAPersonCanRead() async throws {
        let toasts = ToastLog()
        let engine = AlwaysRefusingEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        defer { model.stopPolling() }
        await Self.wait(until: { model.snapshot != nil }, describedAs: "first snapshot")
        let track = try XCTUnwrap(model.snapshot?.tracks.first)

        model.renameTrack(track.id, name: "Drums")
        // Wait for THE toast this test is about, not for "any toast at all".
        // The looser predicate wakes on the first message to arrive from a
        // shared publisher, which need not be ours — see ToastLog's note.
        await Self.wait(until: { toasts.contains("Could not rename that track", style: .warning) },
                        describedAs: "the refusal to be said")

        XCTAssertTrue(toasts.contains("Could not rename that track", style: .warning),
                      "a refused rename said nothing: \(toasts.seen.map(\.message))")
        // AND NOT the engine's own words. `track.rename: /: additional property
        // "nope" not allowed` is not a sentence to someone who has never used a
        // DAW — it reads as a crash. The detail belongs in the log.
        XCTAssertFalse(toasts.seen.contains { $0.message.contains(AlwaysRefusingEngine.rawEngineText) },
                       "the engine's raw refusal text was put in front of the user")
    }

    func testAnAcceptedGestureSaysNothing() async throws {
        let toasts = ToastLog()
        let engine = StudioMockEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        defer { model.stopPolling() }
        await Self.wait(until: { model.snapshot != nil }, describedAs: "first snapshot")
        let track = try XCTUnwrap(model.snapshot?.tracks.first)

        // A name NOTHING in the fixture already has, and the wait is on THIS
        // track carrying it. The first draft renamed to "Drums" and waited for
        // any track called "Drums" — and the fixture ships one, so the wait was
        // satisfied by the first snapshot and returned before the rename had
        // even been sent. It was a constant compared against itself, and it let
        // a `send` that toasts on SUCCESS through unnoticed.
        XCTAssertFalse(model.snapshot?.tracks.contains { $0.name == "Wurlitzer" } ?? true,
                       "the fixture already contains the name this test renames to")
        model.renameTrack(track.id, name: "Wurlitzer")
        await Self.wait(
            until: { model.snapshot?.tracks.first(where: { $0.id == track.id })?.name == "Wurlitzer" },
            describedAs: "the rename to land")
        // Give any toast the same window the failing case gets, so "nothing was
        // said" means nothing was said rather than "we looked too early".
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(toasts.contains("Could not rename", style: .warning),
                       "a rename that WORKED apologised for itself: \(toasts.seen.map(\.message))")
    }

    // MARK: Helpers

    private static func wait(
        until condition: @MainActor () async -> Bool,
        describedAs what: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }
}

/// Collects every toast posted while it lives.
///
/// `ToastManager` is a shared singleton and the suites run in parallel, so
/// reading `currentToast` after an await races other tests' toasts; collecting
/// each `@Published` change synchronously cannot lose the one this test caused.
/// (`StudioDeleteAndDiscoverTests` has the same shape, private to that file.)
@MainActor
final class ToastLog {
    private(set) var seen: [ToastMessage] = []
    private var cancellable: AnyCancellable?
    init() {
        // ⚠️ `dropFirst()` IS LOAD-BEARING. `ToastManager.shared` is process-wide
        // and `$currentToast` is `@Published`, so `sink` REPLAYS the current
        // value the instant we subscribe. Without this, a toast left behind by
        // whichever test ran before us is recorded before this test has done
        // anything at all — and a wait on "any toast has arrived" then returns
        // immediately, on somebody else's message.
        //
        // That is not hypothetical: merging two lanes that had each touched the
        // toast pipeline produced exactly this, and the failure read
        // `a refused rename said nothing: ["Deleted Drums. Cmd-Z brings it back."]`
        // — a delete this test never performs. Same shape as the process-wide
        // `guard::violations()` trap in GATES.md.
        cancellable = ToastManager.shared.$currentToast.dropFirst().sink { [weak self] toast in
            if let toast { self?.seen.append(toast) }
        }
    }
    func contains(_ fragment: String, style: ToastStyle) -> Bool {
        seen.contains { $0.message.contains(fragment) && $0.style == style }
    }
}

/// An engine that accepts nothing, so the app's refusal path can be observed.
///
/// It wraps a real `StudioMockEngine` for the READ half — the view model needs
/// a snapshot with a track in it before there is anything to rename — and
/// refuses every `send`. The refusal text is deliberately the shape the real
/// engine produces, so the test can assert that this string is exactly what
/// does NOT reach the user.
actor AlwaysRefusingEngine: StudioEngineProtocol {
    static let rawEngineText = #"track.rename: /: additional property "nope" not allowed"#

    private let inner = StudioMockEngine()

    func snapshot(ifNewerThan revision: UInt64?) async -> StudioProjectSnapshot? {
        await inner.snapshot(ifNewerThan: revision)
    }

    @discardableResult
    func send(_ command: StudioEngineCommand) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: Self.rawEngineText)
    }

    func setMetronome(enabled: Bool?, levelDB: Double?, countInBeats: Int?) async {
        await inner.setMetronome(enabled: enabled, levelDB: levelDB, countInBeats: countInBeats)
    }

    func importAudio(path: String, trackID: UUID?, startTicks: Int64) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: Self.rawEngineText)
    }

    @discardableResult
    func undo() async -> Bool { false }

    @discardableResult
    func redo() async -> Bool { false }

    func waveformTile(_ key: StudioTileKey) async -> StudioWaveformTile? {
        await inner.waveformTile(key)
    }

    func addInstrumentTrack(name: String, lengthTicks: Int64) async -> StudioInstrumentTrackOutcome {
        await inner.addInstrumentTrack(name: name, lengthTicks: lengthTicks)
    }

    func openInStudio(_ request: StudioLandingRequest) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: Self.rawEngineText)
    }
}
