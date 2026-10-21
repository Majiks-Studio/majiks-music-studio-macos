import XCTest
@testable import MajiksMusicStudio

// Lane L10: the Takes system, UI side.
//  - the pure browser filter (prompt / region / kind / auditionable);
//  - the preview engine's take list + classification (landing = provenance,
//    out of the auditionable list; the L8 follow-up);
//  - per-stem take mixing composes one take PER stem and commits it (on L9);
//  - purge reclaims candidate takes (records stay as lineage, read offline);
//  - re-roll prefills Revise from a take's lineage; drag-to-timeline promotes.
// MAJIKS_ENGINE=mock exercises exactly these paths.

final class StudioTakesTests: XCTestCase {

    private let sig = StudioTimeSignature.fourFour

    private func item(
        id: String, kind: StudioTakeKind, stem: String, prompt: String,
        auditionable: Bool, provenance: Bool = false, offline: Bool = false,
        region: (Int64, Int64)? = nil, seq: Int = 0
    ) -> StudioTakeBrowserItem {
        StudioTakeBrowserItem(
            takeID: id, requestID: "r", kind: kind, stemName: stem, status: .candidate,
            promotedInto: nil, assetHash: "a", auditionable: auditionable, provenance: provenance,
            offline: offline, createdTs: nil, createdSeq: seq,
            lineage: StudioTakeLineage(prompt: prompt, seed: 7, model: "m", steps: 8, device: "cpu",
                regionStartTicks: region?.0, regionEndTicks: region?.1))
    }

    // MARK: - Pure filter

    func testFilterAuditionableHidesProvenanceAndPurged() {
        let items = [
            item(id: "rev", kind: .revise, stem: "drums", prompt: "darker", auditionable: true),
            item(id: "land", kind: .landing, stem: "mix", prompt: "the song", auditionable: false, provenance: true),
            item(id: "gone", kind: .revise, stem: "bass", prompt: "sub", auditionable: false, offline: true),
        ]
        var f = StudioTakesFilter()
        f.auditionableOnly = true
        let out = f.apply(items)
        XCTAssertEqual(out.map(\.takeID), ["rev"], "only the auditionable alternative survives")
    }

    func testFilterSearchMatchesPromptAndKind() {
        let items = [
            item(id: "a", kind: .revise, stem: "drums", prompt: "half-time darker pads", auditionable: true),
            item(id: "b", kind: .layer, stem: "other", prompt: "warm analog bass", auditionable: true),
        ]
        var f = StudioTakesFilter(); f.auditionableOnly = false
        f.search = "analog"
        XCTAssertEqual(f.apply(items).map(\.takeID), ["b"])
        f.search = "layer"
        XCTAssertEqual(f.apply(items).map(\.takeID), ["b"], "kind label is searchable")
        f.search = ""
        f.kind = .revise
        XCTAssertEqual(f.apply(items).map(\.takeID), ["a"])
    }

    func testFilterRegionKeepsOnlyOverlappingTakes() {
        let bar = sig.ticksPerBar
        let items = [
            item(id: "in", kind: .revise, stem: "drums", prompt: "x", auditionable: true, region: (bar, 2 * bar)),
            item(id: "out", kind: .revise, stem: "drums", prompt: "y", auditionable: true, region: (8 * bar, 9 * bar)),
            item(id: "none", kind: .landing, stem: "mix", prompt: "z", auditionable: false),
        ]
        var f = StudioTakesFilter(); f.auditionableOnly = false
        f.region = StudioRegionSelection(rawStart: bar, rawEnd: 2 * bar)
        XCTAssertEqual(f.apply(items).map(\.takeID), ["in"], "only takes whose region overlaps the selection")
    }

    // MARK: - The preview engine's take list + classification

    func testMockListsTakesAndClassifiesLandingProvenance() async {
        let engine = StudioMockEngine()
        let all = await engine.takes(query: .all)
        XCTAssertFalse(all.isEmpty, "the fixture seeds the Takes browser")
        let landing = all.first { $0.kind == .landing }
        XCTAssertNotNil(landing, "the landed song is recorded")
        XCTAssertEqual(landing?.provenance, true)
        XCTAssertEqual(landing?.auditionable, false, "the landed song is provenance, not an alternative")
        XCTAssertNotNil(landing?.lineage.prompt, "still queryable as lineage")

        // auditionableOnly (the L8 decision) drops the landing provenance.
        let audi = await engine.takes(query: StudioTakesQuery(auditionableOnly: true))
        XCTAssertFalse(audi.contains { $0.kind == .landing }, "landing filtered out of the auditionable list")
        XCTAssertTrue(audi.allSatisfy { $0.auditionable }, "only auditionable alternatives")
        // But the landing stays reachable by kind (a lineage view).
        let landings = await engine.takes(query: StudioTakesQuery(kind: .landing))
        XCTAssertEqual(landings.count, 1)
    }

    // MARK: - Per-stem take mixing (build on L9's audition)

    @MainActor
    func testPerStemMixCommitsChosenTakePerStem() async throws {
        let vm = StudioViewModel(engine: StudioMockEngine())
        vm.startPolling()
        try await Task.sleep(nanoseconds: 150_000_000)
        vm.stopPolling()
        guard let snap = vm.snapshot else { return XCTFail("no snapshot") }

        vm.reviseScope = [.drums, .other]
        vm.selection.region = StudioRegionSelection(rawStart: 0, rawEnd: snap.lengthTicks)
        vm.generateRevise()
        try await Task.sleep(nanoseconds: 150_000_000)
        guard let a = vm.audition, a.variants.count >= 2 else { return XCTFail("no audition with 2+ variants") }

        // The per-stem mix: drums from take 1 (variant 0), other from take 2 (v1).
        func take(_ v: Int, _ stem: StudioStemKind) -> String {
            a.variants.first { $0.index == v }!.promotions.first { $0.stem == stem }!.takeID
        }
        let drumsV0 = take(0, .drums)
        let otherV1 = take(1, .other)
        let drumsV1 = take(1, .drums)
        let otherV0 = take(0, .other)
        XCTAssertNotEqual(drumsV0, drumsV1, "distinct drums takes exist (a real mix)")

        vm.auditionVariant(0)                    // base = variant 0
        vm.auditionStemVariant(.other, variant: 1)  // but other from variant 1
        vm.commitAudition()
        try await Task.sleep(nanoseconds: 200_000_000)

        // The COMPOSED selection is promoted; the un-chosen ones stay candidates.
        let takes = vm.takesBrowserItems
        func status(_ id: String) -> StudioTakeStatusKind? { takes.first { $0.takeID == id }?.status }
        XCTAssertEqual(status(drumsV0), .promoted, "drums = variant 0's take")
        XCTAssertEqual(status(otherV1), .promoted, "other = variant 1's take")
        XCTAssertEqual(status(drumsV1), .candidate, "variant 1's drums was NOT chosen")
        XCTAssertEqual(status(otherV0), .candidate, "variant 0's other was NOT chosen")
    }

    // MARK: - Purge

    @MainActor
    func testPurgeReclaimsCandidatesKeepsLineage() async throws {
        let vm = StudioViewModel(engine: StudioMockEngine())
        vm.startPolling()
        try await Task.sleep(nanoseconds: 150_000_000)
        vm.stopPolling()
        let before = vm.takesBrowserItems
        XCTAssertTrue(before.contains { $0.auditionable }, "there are auditionable takes to purge")

        vm.purgeTakes(scope: .all)
        try await Task.sleep(nanoseconds: 150_000_000)

        let after = vm.takesBrowserItems
        XCTAssertEqual(after.count, before.count, "records stay (queryable as lineage)")
        XCTAssertFalse(after.contains { $0.auditionable }, "nothing auditionable after purge")
        XCTAssertTrue(after.contains { $0.offline }, "purged takes read offline")
        // The landed-song provenance is never purged.
        XCTAssertTrue(after.contains { $0.kind == .landing && !$0.offline })
    }

    // MARK: - Re-roll + drag-to-timeline

    @MainActor
    func testRerollPrefillsReviseFromLineage() async {
        let vm = StudioViewModel(engine: StudioMockEngine())
        let bar = sig.ticksPerBar
        let it = item(id: "x", kind: .revise, stem: "drums", prompt: "half-time darker",
                      auditionable: true, region: (bar, 3 * bar))
        vm.rerollFromTake(it)
        XCTAssertEqual(vm.reviseInstruction, "half-time darker")
        XCTAssertEqual(vm.reviseSeedText, "7")
        XCTAssertTrue(vm.reviseArmed)
        XCTAssertEqual(vm.selection.region?.startTicks, bar)
    }

    @MainActor
    func testDropTakePromotesOntoClipUnderPoint() async throws {
        let vm = StudioViewModel(engine: StudioMockEngine())
        vm.startPolling()
        try await Task.sleep(nanoseconds: 150_000_000)
        vm.stopPolling()
        guard let snap = vm.snapshot,
              let track = snap.tracks.first(where: { !$0.clips.isEmpty }),
              let clip = track.clips.first else { return XCTFail("no clip") }
        let takeID = vm.takesBrowserItems.first { $0.auditionable }!.takeID

        vm.dropTake(takeID: takeID, trackID: track.id, atTicks: clip.startTicks + 1)
        try await Task.sleep(nanoseconds: 150_000_000)

        // The take is promoted into the dropped-on clip.
        let promoted = vm.takesBrowserItems.first { $0.takeID == takeID }
        XCTAssertEqual(promoted?.status, .promoted, "drag-to-timeline promoted the take")
        XCTAssertEqual(promoted?.promotedInto, clip.id.uuidString)
    }
}
