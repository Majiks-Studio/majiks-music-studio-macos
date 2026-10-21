import XCTest
@testable import MajiksMusicStudio

// The "load a Library song onto the timeline" path.
//
// StudioBrowserView's Library rows (StudioLibrarySongRow) load a song by calling
// model.importAudio(path:), the SAME entry the "Import audio…" button and the
// timeline file-drop use. This test drives that model entry against the preview
// engine (MAJIKS_ENGINE=mock) and asserts a clip lands on the target track, so
// the timeline has something to draw a waveform for.

final class StudioImportTests: XCTestCase {

    @MainActor
    func testImportAudioLandsClipOnANewTrack() async throws {
        // The multitrack default: importing a song builds up the session by
        // landing the clip on its OWN new track (track.add), NOT by piling it onto
        // the first existing track. So the track count grows by one, the clip is
        // on the new track, and the existing first track is left untouched.
        let vm = StudioViewModel(engine: StudioMockEngine())
        vm.startPolling()
        try await Task.sleep(nanoseconds: 150_000_000)   // adopt the first snapshot
        guard let before = vm.snapshot, let firstBefore = before.tracks.first else {
            vm.stopPolling(); return XCTFail("no initial snapshot")
        }
        let beforeTrackCount = before.tracks.count
        let firstBeforeClipCount = firstBefore.clips.count
        let beforeIDs = Set(before.tracks.map(\.id))

        // Exactly what a plain double-click / drag of a Library song does.
        vm.importAudio(path: "/tmp/imports/My Song.wav")
        try await Task.sleep(nanoseconds: 400_000_000)   // track.add + re-poll + import + adopt
        vm.stopPolling()

        guard let after = vm.snapshot else { return XCTFail("no snapshot after import") }
        XCTAssertEqual(after.tracks.count, beforeTrackCount + 1,
                       "importing a song added a new track (the session builds up)")
        // The existing first track is untouched — the clip did NOT pile onto it.
        guard let firstAfter = after.tracks.first(where: { $0.id == firstBefore.id }) else {
            return XCTFail("the existing first track disappeared")
        }
        XCTAssertEqual(firstAfter.clips.count, firstBeforeClipCount,
                       "the existing first track was left untouched")
        // The clip landed on the freshly-added track.
        guard let newTrack = after.tracks.first(where: { !beforeIDs.contains($0.id) }) else {
            return XCTFail("no new track was added")
        }
        XCTAssertEqual(newTrack.clips.count, 1, "the imported clip landed on the new track")
        XCTAssertTrue(
            newTrack.clips.contains { $0.name == "My Song" && !$0.generative },
            "the placed clip is named from the file and is a non-generative (imported) clip")
        XCTAssertEqual(vm.importProgress, 1, "import reported success")
    }

    @MainActor
    func testImportingTwoSongsBuildsTwoTracks() async throws {
        // "Can we have many tracks": loading songs must build up MULTIPLE tracks.
        // Two different songs imported into a project yield two tracks, each
        // carrying its own clip — not two clips stacked onto track 1.
        let vm = StudioViewModel(engine: StudioMockEngine(project: .empty))
        vm.startPolling()
        try await Task.sleep(nanoseconds: 150_000_000)   // adopt the empty snapshot
        XCTAssertEqual(vm.snapshot?.tracks.count, 0, "the project starts empty (0 tracks)")

        // Serialize the two imports so the async track.add/import of the first
        // completes (and is adopted) before the second begins.
        vm.importAudio(path: "/tmp/imports/Song A.wav")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.snapshot?.tracks.count, 1, "the first song created the first track")

        vm.importAudio(path: "/tmp/imports/Song B.wav")
        try await Task.sleep(nanoseconds: 400_000_000)
        vm.stopPolling()

        guard let after = vm.snapshot else { return XCTFail("no snapshot after imports") }
        XCTAssertEqual(after.tracks.count, 2,
                       "two songs built two tracks (multitrack), not one track with two clips")
        for track in after.tracks {
            XCTAssertEqual(track.clips.count, 1, "each imported song landed on its own track")
        }
        let clipNames = Set(after.tracks.flatMap { $0.clips.map(\.name) })
        XCTAssertEqual(clipNames, ["Song A", "Song B"],
                       "each track holds exactly the clip named from its own song")
        XCTAssertEqual(vm.importProgress, 1, "the second import reported success")
    }

    @MainActor
    func testCommandModifierImportOverdubsOntoExistingTrack() async throws {
        // ⌘-double-click is the deliberate overdub: newTrack:false lands the clip
        // on an existing track instead of minting a new one, so a user can still
        // stack onto one track when they want to.
        let vm = StudioViewModel(engine: StudioMockEngine())
        vm.startPolling()
        try await Task.sleep(nanoseconds: 150_000_000)
        guard let before = vm.snapshot, let firstBefore = before.tracks.first else {
            vm.stopPolling(); return XCTFail("no initial snapshot")
        }
        let beforeTrackCount = before.tracks.count
        let firstBeforeClipCount = firstBefore.clips.count

        // The ⌘-double-click path.
        vm.importAudio(path: "/tmp/imports/Overdub.wav", newTrack: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        vm.stopPolling()

        guard let after = vm.snapshot,
              let firstAfter = after.tracks.first(where: { $0.id == firstBefore.id }) else {
            return XCTFail("no snapshot / first track after import")
        }
        XCTAssertEqual(after.tracks.count, beforeTrackCount, "overdub did NOT add a track")
        XCTAssertEqual(firstAfter.clips.count, firstBeforeClipCount + 1,
                       "the clip landed on the existing first track")
        XCTAssertTrue(
            firstAfter.clips.contains { $0.name == "Overdub" && !$0.generative },
            "the overdubbed clip is named from the file and is non-generative")
        XCTAssertEqual(vm.importProgress, 1, "import reported success")
    }

    @MainActor
    func testLibrarySearchNarrowsTheSongList() {
        // The Studio browser's Songs search: case-insensitive substring over
        // title / artist / album / genre, live as you type. Mirrors the Library
        // tab so a specific song is findable in a list of 100s.
        let tracks = [
            makeTrack(title: "Midnight Drive", artist: "The Aurora", album: "Neon", genre: "Synthwave"),
            makeTrack(title: "Coffee Shop", artist: "Jane Doe", album: "Mornings", genre: "Folk"),
            makeTrack(title: "Drive Home", artist: "Nightcar", album: "Commute", genre: "Lo-fi"),
        ]
        // Empty query = the whole list (unfiltered).
        XCTAssertEqual(StudioLibrarySearch.filter(tracks, query: "").count, 3)
        XCTAssertEqual(StudioLibrarySearch.filter(tracks, query: "   ").count, 3,
                       "whitespace-only query is treated as empty")
        // Title substring, case-insensitive, order-preserving.
        XCTAssertEqual(StudioLibrarySearch.filter(tracks, query: "DrIvE").map(\.title),
                       ["Midnight Drive", "Drive Home"])
        // Artist / album / genre each match.
        XCTAssertEqual(StudioLibrarySearch.filter(tracks, query: "aurora").map(\.title),
                       ["Midnight Drive"])
        XCTAssertEqual(StudioLibrarySearch.filter(tracks, query: "commute").map(\.title),
                       ["Drive Home"])
        XCTAssertEqual(StudioLibrarySearch.filter(tracks, query: "folk").map(\.title),
                       ["Coffee Shop"])
        // No match narrows to empty.
        XCTAssertTrue(StudioLibrarySearch.filter(tracks, query: "zzz").isEmpty)
    }

    /// Minimal Track fixture for the search test (only the searched fields matter;
    /// the rest of Track's optionals default to nil via the memberwise init).
    private func makeTrack(title: String, artist: String?, album: String?, genre: String?) -> Track {
        Track(id: UUID(), title: title, caption: "", audioFileName: "\(UUID().uuidString).wav",
              createdAt: Date(), duration: 1, artist: artist, album: album, genre: genre)
    }

    @MainActor
    func testImportIntoEmptyProjectCreatesTrackAndLandsClip() async throws {
        // The "make the DAW usable" regression: a brand-new "Studio" project has
        // 0 tracks, and the engine places a clip onto a REQUIRED existing track,
        // so a fresh project silently no-oped every double-click / drag / Import.
        // importAudio must now auto-create a track AND land the clip on it.
        let vm = StudioViewModel(engine: StudioMockEngine(project: .empty))
        vm.startPolling()
        try await Task.sleep(nanoseconds: 150_000_000)   // adopt the empty snapshot
        guard let before = vm.snapshot else {
            vm.stopPolling(); return XCTFail("no initial snapshot")
        }
        XCTAssertEqual(before.tracks.count, 0, "the project starts empty (0 tracks)")

        // Exactly what a double-click / drag of a Library song does.
        vm.importAudio(path: "/tmp/imports/First Song.wav")
        try await Task.sleep(nanoseconds: 400_000_000)   // track.add + re-poll + import + adopt
        vm.stopPolling()

        guard let after = vm.snapshot else { return XCTFail("no snapshot after import") }
        XCTAssertEqual(after.tracks.count, 1,
                       "importing into an empty project auto-created a track (0 -> 1)")
        guard let track = after.tracks.first else { return XCTFail("no track after import") }
        XCTAssertEqual(track.clips.count, 1, "the imported clip landed on the created track")
        XCTAssertTrue(
            track.clips.contains { $0.name == "First Song" && !$0.generative },
            "the placed clip is named from the file and is a non-generative (imported) clip")
        XCTAssertEqual(vm.importProgress, 1, "import reported success")
    }

    @MainActor
    func testImportAudioWithoutProjectReportsInsteadOfCrashing() async {
        // No polling: the view model has no snapshot yet, so there is no target
        // track. importAudio must report a clear status, not fault.
        let vm = StudioViewModel(engine: StudioMockEngine())
        vm.importAudio(path: "/tmp/imports/whatever.wav")
        XCTAssertNotNil(vm.importStatus, "a status explains why nothing was imported")
        XCTAssertEqual(vm.importProgress, 0, "no progress without a target project")
    }
}
