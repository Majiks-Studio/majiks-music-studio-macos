import XCTest
@testable import MajiksMusicStudio

// The Stems tab and the Studio were a DEAD END from each other.
//
// The Stems tab holds one song's parts with per-part solo, mute and level. The
// Studio holds the same parts as tracks you can cut up and arrange. There was
// no route from either to the other, so a balance found in one could not be
// arranged in the other, and an arrangement could not be re-balanced.
//
// These tests drive the route that now exists: the Stems tab hands a request
// to the coordinator, the Studio tab consumes it, and each stem lands on its
// OWN track under its OWN name — through `track.add` + `import.audio`, the
// journalled bus a drag onto the timeline already uses. No new command.
final class StemStudioBridgeTests: XCTestCase {

    // MARK: - The hand-off

    @MainActor
    func testOpeningStemsInStudioStagesTheRequestAndSwitchesToTheStudioTab() {
        let coordinator = StudioCoordinator()
        coordinator.selectedTab = 4   // the Stems tab

        coordinator.openStemsInStudio(StudioStemImportRequest(
            sessionName: "Neon Getaway — Stems",
            stems: [
                .init(name: "Vocals", path: "/tmp/stems/a1b2c3d4_vocals.wav"),
                .init(name: "Drums", path: "/tmp/stems/e5f6a7b8_drums.wav"),
            ]))

        XCTAssertEqual(coordinator.selectedTab, StudioRootView.tabTag,
                       "the Studio tab did not come forward, so the stems went nowhere visible")
        let request = coordinator.pendingStemImport
        XCTAssertEqual(request?.sessionName, "Neon Getaway — Stems")
        XCTAssertEqual(request?.stems.map(\.name), ["Vocals", "Drums"])
        XCTAssertEqual(request?.stems.map(\.path),
                       ["/tmp/stems/a1b2c3d4_vocals.wav", "/tmp/stems/e5f6a7b8_drums.wav"])
    }

    @MainActor
    func testHandingOverNothingDoesNotYankTheUserToAnEmptyStudio() {
        let coordinator = StudioCoordinator()
        coordinator.selectedTab = 4
        coordinator.openStemsInStudio(
            StudioStemImportRequest(sessionName: "Empty", stems: []))
        XCTAssertEqual(coordinator.selectedTab, 4, "an empty request still switched tabs")
        XCTAssertNil(coordinator.pendingStemImport)
    }

    // MARK: - The landing

    @MainActor
    func testEveryStemLandsOnItsOwnTrackNamedAfterThePart() async throws {
        let vm = StudioViewModel(engine: StudioMockEngine(project: .empty))
        vm.startPolling()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(vm.snapshot?.tracks.count, 0, "the fixture project starts empty")

        await vm.importStemSession(StudioStemImportRequest(
            sessionName: "Neon Getaway — Stems",
            stems: [
                // Note the file names: stems on disk are prefixed with the
                // stem id, which is why the track name has to come from the
                // request and not from the path.
                .init(name: "Vocals", path: "/tmp/stems/a1b2c3d4_vocals.wav"),
                .init(name: "Drums", path: "/tmp/stems/e5f6a7b8_drums.wav"),
                .init(name: "Bass", path: "/tmp/stems/c9d0e1f2_bass.wav"),
                .init(name: "Other", path: "/tmp/stems/3a4b5c6d_other.wav"),
            ]))
        try await Task.sleep(nanoseconds: 200_000_000)   // adopt the final snapshot
        vm.stopPolling()

        let after = try XCTUnwrap(vm.snapshot, "no snapshot after importing the session")
        XCTAssertEqual(after.tracks.count, 4,
                       "four stems did not become four tracks — they were piled onto one")

        // Named for the PART, not for the file. "a1b2c3d4_vocals" helps nobody.
        XCTAssertEqual(after.tracks.map(\.name), ["Vocals", "Drums", "Bass", "Other"])

        // Each carries its own audio: a track with no clip is an empty lane
        // that looks like a successful import and plays nothing.
        for track in after.tracks {
            XCTAssertEqual(track.clips.count, 1,
                           "the \(track.name) track has \(track.clips.count) clips, expected exactly 1")
        }

        // Distinct clips, not the same one adopted four times — the failure
        // mode `performImport`'s "the id that wasn't there before" lookup has
        // if two imports run concurrently.
        let clipIDs = after.tracks.flatMap { $0.clips.map(\.id) }
        XCTAssertEqual(Set(clipIDs).count, 4, "two stems landed as the same clip")

        XCTAssertEqual(vm.importProgress, 1, "the session import did not report success")
        XCTAssertEqual(vm.importStatus,
                       "Opened Neon Getaway — Stems — 4 stems on their own tracks")
    }

    @MainActor
    func testImportingOneStemAddsOneTrackToAnExistingSession() async throws {
        let vm = StudioViewModel(engine: StudioMockEngine())
        vm.startPolling()
        try await Task.sleep(nanoseconds: 150_000_000)
        let before = try XCTUnwrap(vm.snapshot).tracks.count
        XCTAssertGreaterThan(before, 0, "the fixture project should already have tracks")

        await vm.importStemSession(StudioStemImportRequest(
            sessionName: "Neon Getaway — Stems",
            stems: [.init(name: "Vocals", path: "/tmp/stems/a1b2c3d4_vocals.wav")]))
        try await Task.sleep(nanoseconds: 200_000_000)
        vm.stopPolling()

        let after = try XCTUnwrap(vm.snapshot)
        XCTAssertEqual(after.tracks.count, before + 1,
                       "opening one stem should add exactly one track")
        XCTAssertEqual(after.tracks.last?.name, "Vocals")
    }

    @MainActor
    func testAnEmptyRequestIsANoOpOnTheStudioSide() async throws {
        let vm = StudioViewModel(engine: StudioMockEngine())
        vm.startPolling()
        try await Task.sleep(nanoseconds: 150_000_000)
        let before = try XCTUnwrap(vm.snapshot).tracks.count

        await vm.importStemSession(
            StudioStemImportRequest(sessionName: "Empty", stems: []))
        try await Task.sleep(nanoseconds: 100_000_000)
        vm.stopPolling()

        XCTAssertEqual(try XCTUnwrap(vm.snapshot).tracks.count, before,
                       "an empty stem request still created tracks")
    }
}
