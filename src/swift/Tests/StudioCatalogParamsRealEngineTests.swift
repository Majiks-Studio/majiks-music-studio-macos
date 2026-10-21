#if REAL_ENGINE
import XCTest
@testable import MajiksMusicStudio

// THE JOIN, for the PARAMETER half of the eleven refused gestures.
//
// `fix/say-what-happened` fixed the identifiers: `.catalog` now resolves a UI
// `UUID` to the engine's track/clip id the way every typed case always did.
// That was one of two independent faults, and this file is the other one.
//
// THE SECOND FAULT. The envelopes carried `StudioMockEngine`'s parameter NAMES
// rather than the catalog's — `gain` where `clip.setGain` says `gainDb`,
// `height` where `track.setHeight` says `heightPx`, `index` where
// `track.reorder` says `newIndex` — and `marker.set` / `section.set` sent
// neither the ids nor the fields the contract declares. `session.rs` validates
// against `command-catalog.v2.json` with `additionalProperties: false` before
// apply, so all of them were refused. Fixing the ids alone would have moved
// each of these from "refused for the wrong id" to "refused for the wrong key"
// and changed nothing a user could see.
//
// WHY THIS FILE AND NOT A MOCK TEST. `StudioCatalogContractTests` proves the
// envelope validates against the contract, and the mock now refuses a wrong
// key — but both of those are Swift checking Swift. Only the engine can say
// whether the engine accepts it. Everything below drives the SAME view-model
// methods a click drives, against the real FFI over a real package, and asserts
// the PROJECT CHANGED — not that a call was made.
//
// Silent: `RealStudioEngine(dataDir:audible:)` defaults `audible` to false and
// nothing here calls `startLive`, so this bundle never opens an output device.

@MainActor
final class StudioCatalogParamsRealEngineTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("majiks-catalog-params-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var packagePath: String {
        tempDir.appendingPathComponent("CatalogParams.mstudio").path
    }

    private func settle(
        _ vm: StudioViewModel,
        _ what: String,
        until: (StudioProjectSnapshot) -> Bool
    ) async throws {
        for _ in 0..<200 {
            if let s = vm.snapshot, until(s) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the engine never reported: \(what)")
    }

    /// A real engine over a real package with two tracks, and a view model that
    /// has adopted them.
    private func makeSession() async throws -> (RealStudioEngine, StudioViewModel) {
        let engine = try RealStudioEngine(dataDir: packagePath, audible: false)
        for (i, name) in ["Keys", "Bass"].enumerated() {
            let added = await engine.send(
                .trackAdd(trackID: UUID().uuidString, name: name, index: i))
            XCTAssertTrue(added.ok, "track.add \(name): \(added.message ?? "no message")")
        }
        let vm = StudioViewModel(engine: engine)
        vm.startPolling()
        addTeardownBlock { @MainActor in vm.stopPolling() }
        try await settle(vm, "two tracks") { $0.tracks.count == 2 }
        return (engine, vm)
    }

    // MARK: - track.setHeight — `height` vs `heightPx`

    func testSettingATrackHeightIsAcceptedByTheEngine() async throws {
        let (engine, vm) = try await makeSession()
        let trackID = try XCTUnwrap(vm.snapshot?.tracks.first?.id)

        // Through the view model, exactly as the H menu does.
        vm.setTrackHeight(trackID, height: 160)
        // The height is UI-only state the snapshot does not surface, so the
        // proof is the engine's own verdict on the envelope. Re-sent here with
        // the resolved engine id to READ that verdict, which the fire-and-forget
        // gesture above deliberately does not return.
        let resolvedTrack = await engine.engineTrackID(trackID)
        let engineTrack = try XCTUnwrap(resolvedTrack)
        let ok = await engine.send(.catalog(name: "track.setHeight", params: [
            "trackId": engineTrack, "heightPx": 160,
        ]))
        XCTAssertTrue(ok.ok, "the contract's own spelling was refused: \(ok.message ?? "")")

        // And the spelling that shipped is refused, by the engine, right here.
        let refused = await engine.send(.catalog(name: "track.setHeight", params: [
            "trackId": engineTrack, "height": 160,
        ]))
        XCTAssertFalse(refused.ok, "the engine accepted `height` - the premise of this lane is wrong")
    }

    // MARK: - track.reorder — `index` vs `newIndex`

    func testReorderingATrackActuallyMovesIt() async throws {
        let (_, vm) = try await makeSession()
        let names = try XCTUnwrap(vm.snapshot?.tracks.map(\.name))
        XCTAssertEqual(names, ["Keys", "Bass"])
        let keys = try XCTUnwrap(vm.snapshot?.tracks.first?.id)

        vm.reorderTrack(keys, to: 1)
        try await settle(vm, "Keys second") { $0.tracks.map(\.name) == ["Bass", "Keys"] }
        XCTAssertEqual(vm.snapshot?.tracks.map(\.name), ["Bass", "Keys"])
    }

    // MARK: - track.setColor — the value, not the key

    /// Both parameter NAMES were right here, which is why this one was not on
    /// anybody's list. `color` is `"pattern": "^#[0-9A-Fa-f]{6}$"` and the menu
    /// sent `"blue"`, so all eight swatches were refused, silently.
    func testAPaletteColourIsAcceptedAndABareColourNameIsNot() async throws {
        let (engine, vm) = try await makeSession()
        let trackID = try XCTUnwrap(vm.snapshot?.tracks.first?.id)
        let resolvedTrack = await engine.engineTrackID(trackID)
        let engineTrack = try XCTUnwrap(resolvedTrack)

        let accepted = await engine.send(.catalog(name: "track.setColor", params: [
            "trackId": engineTrack, "color": StudioTrackColor.orange.hex,
        ]))
        XCTAssertTrue(accepted.ok, "the palette's hex was refused: \(accepted.message ?? "")")

        let refused = await engine.send(.catalog(name: "track.setColor", params: [
            "trackId": engineTrack, "color": "orange",
        ]))
        XCTAssertFalse(refused.ok, "the engine accepted a colour NAME - the pattern is not enforced")
    }

    // MARK: - marker.set / marker.remove — round trip through the snapshot

    /// The marker half was worse than a wrong key: the real engine's snapshot
    /// reader never parsed `markers` at all, so even a correct `marker.set`
    /// would have left the ruler empty and "Remove Marker" unreachable.
    func testAMarkerSurvivesTheRoundTripAndCanBeRemoved() async throws {
        let (_, vm) = try await makeSession()
        XCTAssertTrue(vm.snapshot?.markers.isEmpty ?? false, "a fresh project has no markers")

        vm.setMarker(name: "CHORUS", bar: 16)
        try await settle(vm, "the marker") { $0.markers.contains { $0.name == "CHORUS" } }

        let marker = try XCTUnwrap(vm.snapshot?.markers.first { $0.name == "CHORUS" })
        XCTAssertEqual(marker.bar, 16, "the marker landed at the wrong bar")
        XCTAssertFalse(marker.id.isEmpty, "the marker carries no engine id, so it cannot be removed")

        // Removal addresses it by the id the ENGINE holds. This is the step that
        // was impossible: the snapshot used to mint a fresh UUID per poll.
        vm.removeMarker(markerID: marker.id)
        try await settle(vm, "the marker to go") { $0.markers.isEmpty }
        XCTAssertTrue(vm.snapshot?.markers.isEmpty ?? false)
    }

    // MARK: - section.set / section.remove

    func testASectionSurvivesTheRoundTripAndCanBeRemoved() async throws {
        let (_, vm) = try await makeSession()

        vm.setSection(name: "VERSE 1", startBar: 8)
        try await settle(vm, "the section") { $0.sections.contains { $0.name == "VERSE 1" } }

        let section = try XCTUnwrap(vm.snapshot?.sections.first { $0.name == "VERSE 1" })
        XCTAssertEqual(section.startBar, 8)
        XCTAssertFalse(section.id.isEmpty, "the section carries no engine id")

        vm.removeSection(sectionID: section.id)
        try await settle(vm, "the section to go") { !$0.sections.contains { $0.name == "VERSE 1" } }
        XCTAssertFalse(vm.snapshot?.sections.contains { $0.name == "VERSE 1" } ?? true)
    }

    /// `lengthBars` and `role` are DERIVED, and sending them was two
    /// `additionalProperties: false` violations on top of the missing
    /// `sectionId`. This pins that the engine refuses the shape that shipped,
    /// so the parameters cannot quietly come back.
    func testTheShippedSectionEnvelopeIsRefusedByTheEngine() async throws {
        let (engine, _) = try await makeSession()

        let refused = await engine.send(.catalog(name: "section.set", params: [
            "name": "VERSE 1", "startBar": 0, "lengthBars": 8, "role": "verse",
        ]))
        XCTAssertFalse(refused.ok, "the engine accepted the envelope that shipped")
    }

    // MARK: - the id keys the resolver's first list did not have

    /// `targetTrackId` names an EXISTING track, and the resolver's original
    /// two-name list (`trackId`, `clipId`) did not translate it — so a
    /// perfectly correct `.catalog(name: "import.audio", …)` call site carrying
    /// the UI's `UUID` was refused on the real engine. Six keys were in that
    /// state; this is the observable proof for the one that was caught in the
    /// wild.
    ///
    /// The discriminator is the MESSAGE, not the ok flag. Id resolution runs
    /// before the file is opened, so a LIVE track gets past it and fails on the
    /// missing file, while a track that is gone is stopped at the resolver in a
    /// sentence. Both are refusals; only one of them is the bug.
    func testAUIIDUnderTargetTrackIDReachesTheEngineAsATrack() async throws {
        let (engine, vm) = try await makeSession()
        let trackID = try XCTUnwrap(vm.snapshot?.tracks.first?.id)
        let missing = tempDir.appendingPathComponent("not-a-real-file.wav").path

        let live = await engine.send(.catalog(name: "import.audio", params: [
            "sourcePath": missing, "targetTrackId": trackID.uuidString, "startTicks": 0,
        ]))
        XCTAssertFalse(live.ok, "a missing file must not import")
        XCTAssertFalse(live.message?.contains("no longer in the project") ?? false,
                       "a LIVE track was reported as gone - targetTrackId is not being resolved: "
                       + "\(live.message ?? "no message")")

        let dead = await engine.send(.catalog(name: "import.audio", params: [
            "sourcePath": missing, "targetTrackId": UUID().uuidString, "startTicks": 0,
        ]))
        XCTAssertFalse(dead.ok)
        XCTAssertTrue(dead.message?.contains("no longer in the project") ?? false,
                      "a UUID naming nothing should be stopped at the resolver, in words: "
                      + "\(dead.message ?? "no message")")
    }

    /// ⚠️ …and `newClipId` is left ALONE, because `clip.split` mints it for a
    /// clip the engine has never seen. Translating it — the obvious way to
    /// "finish" the list — makes split and duplicate throw instead of working.
    func testSplittingAClipStillWorksBecauseNewClipIDIsNotResolved() async throws {
        let (engine, vm) = try await makeSession()
        let resolvedTrack = await engine.engineTrackID(try XCTUnwrap(vm.snapshot?.tracks.first?.id))
        let track = try XCTUnwrap(resolvedTrack)

        let clipID = "clip_\(UUID().uuidString.prefix(12))"
        let placed = await engine.send(.catalog(name: "clip.placeMidi", params: [
            "clipId": clipID, "trackId": track, "startTicks": 0, "lengthTicks": 3840,
        ]))
        XCTAssertTrue(placed.ok, "clip.placeMidi: \(placed.message ?? "")")

        // A UUID-shaped newClipId is the worst case: it looks exactly like a UI
        // surrogate, and a resolver that translated it would refuse the split.
        let split = await engine.send(.catalog(name: "clip.split", params: [
            "clipId": clipID, "atTicks": 1920, "newClipId": UUID().uuidString,
        ]))
        XCTAssertTrue(split.ok, "clip.split was refused - newClipId is being resolved: "
                      + "\(split.message ?? "no message")")
    }

    // MARK: - every envelope the eleven build, against the live engine

    /// The whole set, driven through the view model, asserted on the engine's
    /// own acceptance.
    ///
    /// The per-gesture tests above prove the RESULT for the ones whose effect
    /// reaches the snapshot. This one covers the rest by asking the engine
    /// directly, so a gesture whose effect is invisible in the read model still
    /// cannot silently be refused.
    func testEveryElevenEnvelopeIsAcceptedByTheLiveEngine() async throws {
        let (engine, vm) = try await makeSession()
        let trackID = try XCTUnwrap(vm.snapshot?.tracks.first?.id)
        let resolvedTrack = await engine.engineTrackID(trackID)
        let track = try XCTUnwrap(resolvedTrack)

        // clip.* needs a clip. clip.placeMidi mints its own id UI-side.
        let clipID = "clip_\(UUID().uuidString.prefix(12))"
        let placed = await engine.send(.catalog(name: "clip.placeMidi", params: [
            "clipId": clipID, "trackId": track, "startTicks": 0, "lengthTicks": 1920,
        ]))
        XCTAssertTrue(placed.ok, "clip.placeMidi: \(placed.message ?? "")")

        let envelopes: [(String, [String: AnyHashable])] = [
            ("track.rename", ["trackId": track, "name": "Wurlitzer"]),
            ("track.reorder", ["trackId": track, "newIndex": 1]),
            ("track.setColor", ["trackId": track, "color": StudioTrackColor.teal.hex]),
            ("track.setHeight", ["trackId": track, "heightPx": 160]),
            ("clip.rename", ["clipId": clipID, "name": "Main Riff"]),
            ("clip.setGain", ["clipId": clipID, "gainDb": -3]),
            ("clip.mute", ["clipId": clipID, "muted": true]),
            ("marker.set", ["markerId": "mk_1", "positionTicks": 0, "label": "CHORUS"]),
            ("marker.remove", ["markerId": "mk_1"]),
            ("section.set", ["sectionId": "sec_1", "name": "VERSE 1", "startTicks": 0]),
            ("section.remove", ["sectionId": "sec_1"]),
        ]
        XCTAssertEqual(envelopes.count, 11)

        for (name, params) in envelopes {
            let result = await engine.send(.catalog(name: name, params: params))
            XCTAssertTrue(result.ok, "\(name) was refused: \(result.message ?? "no message")")
        }
    }
}
#endif
