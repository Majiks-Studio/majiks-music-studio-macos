import XCTest
@testable import MajiksMusicStudio

// Lane L9: the Revise / Extend / Add-a-Layer flow, UI side.
// Pure audition-state math + the preview engine's whole hands-on flow
// (MAJIKS_ENGINE=mock exercises exactly this path).

final class StudioReviseTests: XCTestCase {

    private let sig = StudioTimeSignature.fourFour   // 3840 ticks/bar

    // MARK: - Audition state (pure)

    private func audition(variantCount: Int) -> StudioAuditionState {
        let variants = (0..<variantCount).map { i in
            StudioReviseVariant(index: i, seed: UInt64(i),
                promotions: [StudioPromotion(takeID: "t\(i)", clipID: UUID(), stem: .drums)])
        }
        let drafts = Dictionary(uniqueKeysWithValues: variants.map { ($0.index, ["t\($0.index)"]) })
        let region = StudioRegionSelection(rawStart: 0, rawEnd: sig.ticksPerBar)!
        return StudioAuditionState(variants: variants, draftTakeIDsByVariant: drafts,
            loop: 0...sig.ticksPerBar, region: region, auditioningVariant: 0)
    }

    func testVariantForKeyMapsOneBasedKeysAndRejectsOutOfRange() {
        let a = audition(variantCount: 3)
        XCTAssertEqual(a.variantForKey(1), 0)
        XCTAssertEqual(a.variantForKey(3), 2)
        XCTAssertNil(a.variantForKey(4), "key beyond the variant count is ignored")
        XCTAssertNil(a.variantForKey(0), "there is no take 0")
    }

    func testAuditionedPromotionsFollowTheSelectedVariant() {
        var a = audition(variantCount: 3)
        a.auditioningVariant = 2
        XCTAssertEqual(a.auditionedPromotions?.first?.takeID, "t2")
        XCTAssertEqual(a.auditionedDraftTakeIDs, ["t2"])
        // A returns to the original: no promotions to commit.
        a.auditioningVariant = nil
        XCTAssertNil(a.auditionedPromotions)
        XCTAssertTrue(a.auditionedDraftTakeIDs.isEmpty)
    }

    // MARK: - The preview engine (StudioMockEngine) drives the whole flow

    /// A clip id + its stem from the mock's synthetic project, plus the region
    /// that covers it, for building a revise request.
    private func firstClip(_ snap: StudioProjectSnapshot) -> (clip: StudioClipSnapshot, kind: StudioStemKind, track: UUID) {
        for track in snap.tracks {
            if let clip = track.clips.first {
                return (clip, track.kind, track.id)
            }
        }
        fatalError("mock project has no clips")
    }

    func testReviseLandsTakesThenCommitFoldsThemIn() async throws {
        let engine = StudioMockEngine()
        guard let snap = await engine.snapshot(ifNewerThan: nil) else { return XCTFail("no snapshot") }
        let (clip, kind, _) = firstClip(snap)
        let req = StudioReviseRequest(
            clipIDs: [clip.id], regionStartTicks: clip.startTicks, regionEndTicks: clip.endTicks,
            scope: [kind], allStems: false, instruction: "half-time", variants: 3,
            keepLyrics: true, crossfadeMs: 20, seed: 22)

        let outcome = await engine.revise(req)
        // ⚠️ `try XCTUnwrap`, not `XCTAssertTrue` + a subscript. An XCTAssert
        // RECORDS and CONTINUES, so when `revise` refuses — which is what a
        // preview engine that lost this capability does, and what
        // `StudioEngineProtocol`'s default does today — `variants[1]` on the
        // empty variant list was a `Fatal error: Index out of range` that took
        // the whole XCTest process down. Measured, not feared: deleting the
        // mock's `revise` override killed the runner mid-suite — 371 of 590
        // cases had started and 219 never did, with nothing naming a single one of
        // them; the log simply ends. A
        // capability going quiet must fail HERE, by name, and let the rest of
        // the suite run.
        XCTAssertTrue(outcome.ok, "revise refused: \(outcome.message ?? "no message")")
        XCTAssertEqual(outcome.variants.count, 3, "three variants (P0-A: seed dominates)")
        let first = try XCTUnwrap(outcome.variants.first, "revise landed no variants")
        XCTAssertEqual(first.promotions.first?.clipID, clip.id)
        // Take lanes materialized on the scoped track.
        let auditioningOrNil = await engine.snapshot(ifNewerThan: nil)
        let auditioning = try XCTUnwrap(auditioningOrNil)
        XCTAssertTrue(auditioning.tracks.contains { $0.clips.contains { $0.id == clip.id } && $0.takeLane != nil })

        // Commit variant 1: the clip becomes generated audio, the take lane clears.
        let promotions = try XCTUnwrap(outcome.variants.dropFirst().first?.promotions,
                                       "revise landed fewer than two variants, so there is no second one to commit")
        let commit = await engine.commitRevise(promotions, reason: "revise")
        XCTAssertTrue(commit.ok, "commit refused: \(commit.message ?? "no message")")
        let committedOrNil = await engine.snapshot(ifNewerThan: nil)
        let committed = try XCTUnwrap(committedOrNil)
        let committedClip = committed.tracks.flatMap(\.clips).first { $0.id == clip.id }
        XCTAssertEqual(committedClip?.generative, true, "committed clip reads as generated (shimmer)")
        XCTAssertFalse(committed.tracks.contains { $0.clips.contains { $0.id == clip.id } && $0.takeLane != nil },
                       "take lane folded in on commit")
    }

    func testDiscardClearsTheAuditionTakeLanes() async throws {
        let engine = StudioMockEngine()
        let snapOrNil = await engine.snapshot(ifNewerThan: nil)
        let snap = try XCTUnwrap(snapOrNil)
        let (clip, kind, _) = firstClip(snap)
        let revised = await engine.revise(StudioReviseRequest(
            clipIDs: [clip.id], regionStartTicks: clip.startTicks, regionEndTicks: clip.endTicks,
            scope: [kind], allStems: false, instruction: "", variants: 2, keepLyrics: false, crossfadeMs: 20, seed: nil))

        // ⚠️ THE SETUP IS ASSERTED, and it was not. "The lanes are clear" is
        // vacuously true of a project where no lane was ever armed, so a
        // `revise` that silently refused made this test pass while proving
        // nothing at all — and that was MEASURED, not imagined: with the mock's
        // `revise` override removed, this test stayed green through a
        // capability that had stopped existing. `StudioEngineProtocol`'s default
        // `revise` refuses, so that is one deleted `func` away at all times.
        XCTAssertTrue(revised.ok, "revise refused, so there is no audition to discard: \(revised.message ?? "no message")")
        let armedOrNil = await engine.snapshot(ifNewerThan: nil)
        let armed = try XCTUnwrap(armedOrNil)
        XCTAssertTrue(
            armed.tracks.contains { $0.clips.contains { $0.id == clip.id } && $0.takeLane != nil },
            "no take lane was ever armed, so the discard below has nothing to clear and its success means nothing")

        _ = await engine.discardRevise(takeIDs: ["mocktake"])
        let afterOrNil = await engine.snapshot(ifNewerThan: nil)
        let after = try XCTUnwrap(afterOrNil)
        let stillArmed = after.tracks.contains { $0.clips.contains { $0.id == clip.id } && $0.takeLane != nil }
        XCTAssertFalse(stillArmed, "discard clears the audition take lanes")
    }

    func testAddLayerPreparesTrackThenCommitPlacesClip() async throws {
        let engine = StudioMockEngine()
        let beforeOrNil = await engine.snapshot(ifNewerThan: nil)
        let before = try XCTUnwrap(beforeOrNil)
        let trackCountBefore = before.tracks.count
        let out = await engine.addLayer(
            instruction: "warm analog bass", regionStartTicks: 0, regionEndTicks: 2 * sig.ticksPerBar,
            contextClipID: nil, stem: .bass, variants: 2)
        XCTAssertTrue(out.ok, "addLayer refused: \(out.message ?? "no message")")
        let preparedTrackID = try XCTUnwrap(out.targetTrackID, "addLayer prepared no track")
        let preparedOrNil = await engine.snapshot(ifNewerThan: nil)
        let prepared = try XCTUnwrap(preparedOrNil)
        XCTAssertEqual(prepared.tracks.count, trackCountBefore + 1, "layer prepared a new track")

        // XCTUnwrap, not `takes[0]`: an engine that refused returns no takes and
        // the subscript is a process-killing crash rather than a named failure.
        let take = try XCTUnwrap(out.takes.first, "addLayer landed no take to commit")
        let commit = await engine.commitLayer(takeID: take.takeID, targetTrackID: preparedTrackID, regionStartTicks: 0)
        XCTAssertTrue(commit.ok, "commitLayer refused: \(commit.message ?? "no message")")
        let afterOrNil = await engine.snapshot(ifNewerThan: nil)
        let after = try XCTUnwrap(afterOrNil)
        let layerTrack = after.tracks.first { $0.id.uuidString == preparedTrackID }
        XCTAssertEqual(layerTrack?.clips.count, 1, "layer clip placed on the new track")
        XCTAssertEqual(layerTrack?.clips.first?.generative, true)
    }

    func testExtendPlacesATailClip() async throws {
        let engine = StudioMockEngine()
        let snapOrNil = await engine.snapshot(ifNewerThan: nil)
        let snap = try XCTUnwrap(snapOrNil)
        let (clip, _, trackID) = firstClip(snap)
        let clipsBefore = try XCTUnwrap(snap.tracks.first { $0.id == trackID }).clips.count
        let out = await engine.extendClip(clipID: clip.id, addedSeconds: 2.0, instruction: "outro", variants: 1)
        XCTAssertTrue(out.ok, "extendClip refused: \(out.message ?? "no message")")
        let take = try XCTUnwrap(out.takes.first, "extendClip landed no tail take to commit")
        let commit = await engine.commitExtend(takeID: take.takeID, clipID: clip.id)
        XCTAssertTrue(commit.ok, "commitExtend refused: \(commit.message ?? "no message")")
        let afterOrNil = await engine.snapshot(ifNewerThan: nil)
        let after = try XCTUnwrap(afterOrNil)
        let clipsAfter = try XCTUnwrap(after.tracks.first { $0.id == trackID }).clips.count
        XCTAssertEqual(clipsAfter, clipsBefore + 1, "extend placed a tail clip")
    }

    // MARK: - The view model's region -> targets resolution

    @MainActor
    func testViewModelResolvesStemScopeTargets() async {
        let vm = StudioViewModel(engine: StudioMockEngine())
        vm.startPolling()
        // Let the first snapshot land.
        try? await Task.sleep(nanoseconds: 120_000_000)
        vm.stopPolling()
        guard let snap = vm.snapshot else { return XCTFail("no snapshot adopted") }
        // A region across the whole song, scope drums+other.
        vm.reviseScope = [.drums, .other]
        let region = StudioRegionSelection(rawStart: 0, rawEnd: snap.lengthTicks)!
        let (clipIDs, scope, allStems) = vm.reviseTargets(region: region)
        XCTAssertFalse(allStems, "a multi-track session is stem-scoped, not a single mix clip")
        XCTAssertFalse(clipIDs.isEmpty, "found scoped stem clips under the region")
        XCTAssertTrue(scope.allSatisfy { $0 == .drums || $0 == .other }, "only scoped stems targeted")
        XCTAssertEqual(clipIDs.count, scope.count, "one clip per scoped stem")
    }
}
