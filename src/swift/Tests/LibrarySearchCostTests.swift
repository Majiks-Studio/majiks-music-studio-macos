import Testing
import Foundation
@testable import MajiksMusicStudio

// Finding #1: LibraryView.filteredTracks lowercased six fields per track
// (including lyrics ~1 KB) and was evaluated ~6× per body pass. Measured
// ~4–10 ms/pass at 2000 tracks. These tests COUNT the expensive work — they
// do not time it — same discipline as StudioBrowserCostTests / FileExistenceProbe.
//
// Two counters, two claims:
//   haystackBuildCount     — times a track's searchable fields were lowercased
//   filterEvaluationCount  — times a full filter+sort pass actually ran
//
// A result-only memo without haystacks would still re-lowercase on every
// keystroke. A haystack without a result memo would still re-filter six times
// per body. Both are pinned, and both have vacuity guards so a path that
// stops doing the work cannot pass by going to zero.

@MainActor
@Suite("library search cost", .serialized)
struct LibrarySearchCostTests {

    private let lyricsBlob = String(repeating: "verse line with some words\n", count: 40)

    private func makeTrack(
        title: String,
        artist: String? = "The Aurora",
        album: String? = "Neon",
        genre: String? = "Synthwave",
        lyrics: String? = nil,
        rating: Int = 0,
        createdAt: Date = Date()
    ) -> Track {
        Track(
            id: UUID(),
            title: title,
            caption: "caption",
            audioFileName: "\(UUID().uuidString)/v.wav",
            createdAt: createdAt,
            duration: 120,
            rating: rating,
            artist: artist,
            album: album,
            genre: genre,
            lyrics: lyrics ?? lyricsBlob
        )
    }

    private func filter(
        _ tracks: [Track],
        haystacks: [UUID: LibrarySearchHaystack],
        revision: Int,
        search: String,
        filterType: LibraryView.FilterType = .all,
        selected: String = "",
        rating: LibraryView.RatingFilter = .all,
        sortBy: LibraryView.SortOption = .dateNewest
    ) -> [Track] {
        let key = LibraryFilterKey(
            tracksRevision: revision,
            searchText: search,
            filterTypeRaw: filterType.rawValue,
            selectedFilterValue: selected,
            ratingFilterRaw: rating.rawValue,
            sortByRaw: sortBy.rawValue
        )
        return LibraryTrackQuery.filteredTracks(
            tracks: tracks,
            haystacks: haystacks,
            key: key,
            filterType: filterType,
            selectedFilterValue: selected,
            ratingFilter: rating,
            sortBy: sortBy
        )
    }

    // MARK: - Correctness (the artifact, not the assembly)

    @Test("search is case-insensitive over title artist album genre caption lyrics")
    func searchMatchesAllSixFields() {
        LibraryTrackQuery.resetCountsForTesting()
        LibraryTrackQuery.invalidateResultMemo()

        let tracks = [
            makeTrack(title: "Midnight Drive", artist: "X", album: "Y", genre: "Z", lyrics: "hello"),
            makeTrack(title: "Other", artist: "The Aurora", album: "Y", genre: "Z", lyrics: "hello"),
            makeTrack(title: "Other", artist: "X", album: "Neon Nights", genre: "Z", lyrics: "hello"),
            makeTrack(title: "Other", artist: "X", album: "Y", genre: "Synthwave", lyrics: "hello"),
            makeTrack(title: "Other", artist: "X", album: "Y", genre: "Z", lyrics: "uniqueLyricToken"),
            makeTrack(title: "Other", artist: "X", album: "Y", genre: "Z", lyrics: "hello", rating: 0),
        ]
        // Caption-only match: every other field must be inert so "aurora" /
        // "synth" queries do not also hit this row via the makeTrack defaults.
        var withCaption = makeTrack(
            title: "CapHit",
            artist: "Nobody",
            album: "Nowhere",
            genre: "Silence",
            lyrics: "nope"
        )
        withCaption.caption = "SpecialStyleTag"
        let all = tracks + [withCaption]
        let haystacks = Dictionary(uniqueKeysWithValues: all.map { ($0.id, LibrarySearchHaystack.build(from: $0)) })

        #expect(filter(all, haystacks: haystacks, revision: 1, search: "MiDnIgHt").map(\.title) == ["Midnight Drive"])
        #expect(filter(all, haystacks: haystacks, revision: 1, search: "aurora").map(\.title) == ["Other"])
        #expect(filter(all, haystacks: haystacks, revision: 1, search: "neon nights").map(\.title) == ["Other"])
        #expect(filter(all, haystacks: haystacks, revision: 1, search: "synth").map(\.title) == ["Other"])
        #expect(filter(all, haystacks: haystacks, revision: 1, search: "uniquelyrictoken").map(\.title) == ["Other"])
        #expect(filter(all, haystacks: haystacks, revision: 1, search: "specialstyletag").map(\.title) == ["CapHit"])
        #expect(filter(all, haystacks: haystacks, revision: 1, search: "zzz").isEmpty)
        #expect(filter(all, haystacks: haystacks, revision: 1, search: "").count == all.count,
                "empty search returns every track")
    }

    // MARK: - Haystacks are built once per library mutation, not per keystroke

    @Test("2000 tracks searched under 30 different queries build haystacks once each, not 60_000 times")
    func keystrokesDoNotRebuildHaystacks() {
        LibraryTrackQuery.resetCountsForTesting()
        LibraryTrackQuery.invalidateResultMemo()

        let tracks = (0..<2000).map { i in
            makeTrack(title: "Track \(i)", artist: i % 2 == 0 ? "Aurora" : "Other")
        }
        // Build haystacks the same way LibraryStore does: once, then reuse.
        let buildsBefore = LibraryTrackQuery.haystackBuildCount
        let haystacks = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, LibrarySearchHaystack.build(from: $0))
        })
        let buildsAfterWarm = LibraryTrackQuery.haystackBuildCount - buildsBefore
        #expect(buildsAfterWarm == 2000, "warm build should lowercase each track once, got \(buildsAfterWarm)")

        let buildsAtStart = LibraryTrackQuery.haystackBuildCount
        for ch in "abcdefghijklmnopqrstuvwxyz1234" {
            _ = filter(tracks, haystacks: haystacks, revision: 1, search: String(ch))
        }
        let buildsDuringQueries = LibraryTrackQuery.haystackBuildCount - buildsAtStart
        #expect(
            buildsDuringQueries == 0,
            """
            30 query changes rebuilt \(buildsDuringQueries) haystacks. The whole \
            defect is that typing used to re-lowercase every track's lyrics on \
            every keystroke. Haystacks must be independent of the query.
            """
        )
    }

    @Test("adding a track rebuilds only after invalidation — and the new title is findable")
    func newTrackInvalidatesAndIsSearchable() {
        LibraryTrackQuery.resetCountsForTesting()
        LibraryTrackQuery.invalidateResultMemo()

        // Simulate LibraryStore: mutation clears haystacks, next filter rebuilds.
        var tracks = [makeTrack(title: "Old Song")]
        var haystacks = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, LibrarySearchHaystack.build(from: $0))
        })
        var revision = 1

        #expect(filter(tracks, haystacks: haystacks, revision: revision, search: "old").count == 1)

        // User adds a track. Store bumps revision and drops haystacks.
        let added = makeTrack(title: "Brand New Arrival")
        tracks.append(added)
        revision += 1
        // Rebuild (what searchHaystacks() does after invalidateIndexes).
        let before = LibraryTrackQuery.haystackBuildCount
        haystacks = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, LibrarySearchHaystack.build(from: $0))
        })
        #expect(LibraryTrackQuery.haystackBuildCount - before == 2)

        let found = filter(tracks, haystacks: haystacks, revision: revision, search: "brand new")
        #expect(found.map(\.title) == ["Brand New Arrival"],
                "a track added after the previous haystack must be findable")
    }

    @Test("editing a track title is visible on the next search — no stale haystack")
    func editedTitleInvalidatesHaystack() {
        LibraryTrackQuery.resetCountsForTesting()
        LibraryTrackQuery.invalidateResultMemo()

        var track = makeTrack(title: "Original Title")
        var tracks = [track]
        var haystacks = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, LibrarySearchHaystack.build(from: $0))
        })
        var revision = 1

        #expect(filter(tracks, haystacks: haystacks, revision: revision, search: "original").count == 1)
        #expect(filter(tracks, haystacks: haystacks, revision: revision, search: "renamed").isEmpty)

        // Edit in place (updateTrack path): same id, new title, revision bump.
        track.title = "Renamed Title"
        tracks = [track]
        revision += 1
        haystacks = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, LibrarySearchHaystack.build(from: $0))
        })

        #expect(filter(tracks, haystacks: haystacks, revision: revision, search: "renamed").map(\.title) == ["Renamed Title"])
        #expect(filter(tracks, haystacks: haystacks, revision: revision, search: "original").isEmpty,
                "stale haystack would still match the old title")
    }

    // MARK: - Result memo collapses multi-read body passes

    @Test("six filter reads with identical inputs cost ONE evaluation, not six")
    func resultMemoCollapsesRepeatedReads() {
        LibraryTrackQuery.resetCountsForTesting()
        LibraryTrackQuery.invalidateResultMemo()

        let tracks = (0..<200).map { makeTrack(title: "Song \($0)") }
        let haystacks = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, LibrarySearchHaystack.build(from: $0))
        })

        let before = LibraryTrackQuery.filterEvaluationCount
        var last: [Track] = []
        for _ in 0..<6 {
            last = filter(tracks, haystacks: haystacks, revision: 1, search: "song")
        }
        let evals = LibraryTrackQuery.filterEvaluationCount - before

        // Vacuity: we must have produced a non-empty answer, or the memo is
        // guarding an empty path and the equality below means nothing.
        #expect(last.count >= 1, "fixture produced no matches; the memo test is vacuous")
        #expect(
            evals == 1,
            """
            6 identical filter reads cost \(evals) evaluations. Before the memo \
            this equalled the number of reads (~6 per body pass for the header \
            count, play-all disabled, list, selection chrome, …).
            """
        )
    }

    @Test("a keystroke (query change) is a new evaluation — the memo is not sticky across typing")
    func queryChangeMissesTheMemo() {
        LibraryTrackQuery.resetCountsForTesting()
        LibraryTrackQuery.invalidateResultMemo()

        let tracks = [makeTrack(title: "Alpha"), makeTrack(title: "Beta")]
        let haystacks = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, LibrarySearchHaystack.build(from: $0))
        })

        let before = LibraryTrackQuery.filterEvaluationCount
        _ = filter(tracks, haystacks: haystacks, revision: 1, search: "a")
        _ = filter(tracks, haystacks: haystacks, revision: 1, search: "al")
        _ = filter(tracks, haystacks: haystacks, revision: 1, search: "alp")
        let evals = LibraryTrackQuery.filterEvaluationCount - before

        #expect(evals == 3, "three distinct queries must be three evaluations, got \(evals)")
    }

    @Test("a tracksRevision bump misses the memo — a new track cannot be hidden by a stale list")
    func revisionBumpMissesTheMemo() {
        LibraryTrackQuery.resetCountsForTesting()
        LibraryTrackQuery.invalidateResultMemo()

        var tracks = [makeTrack(title: "Only One")]
        var haystacks = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, LibrarySearchHaystack.build(from: $0))
        })

        let first = filter(tracks, haystacks: haystacks, revision: 1, search: "")
        #expect(first.count == 1)

        tracks.append(makeTrack(title: "Second"))
        haystacks = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, LibrarySearchHaystack.build(from: $0))
        })
        let second = filter(tracks, haystacks: haystacks, revision: 2, search: "")
        #expect(second.count == 2,
                "stale memo at revision 1 would keep returning one track after an add")
    }

    // MARK: - LibraryStore integration without touching the developer's library
    //
    // `addTrack` / `updateTrack` call `saveImmediately()` against FileStore's
    // real library.json. These tests therefore do not mutate a live store.
    // What they pin is the *contract* the store implements: revision bumps,
    // haystack drop, result-memo drop. A source guard below fails if the
    // store stops calling invalidateIndexes / ArtworkDecodeCache from the
    // mutation methods that matter.

    @Test("LibraryStore source: track mutations call invalidateIndexes (haystack drop)")
    func storeMutationsInvalidateIndexes() throws {
        // Guards the feed line, not a reimplementation of the store. Deleting
        // the invalidateIndexes() call from addTrack would leave every pure
        // test green while the app re-served stale haystacks.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/LibraryStore.swift")
            .standardizedFileURL
        let text = try String(contentsOf: url, encoding: .utf8)
        let codeLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }

        // Vacuity: we are looking at the real file.
        #expect(codeLines.contains { $0.contains("func invalidateIndexes()") },
                "LibraryStore.swift no longer defines invalidateIndexes")
        // ⚠️ Whole non-comment lines only. A first draft used text.contains on
        // the raw file; commenting out `_searchHaystacks = nil` left the
        // substring in a `//` line and the guard stayed green while the app
        // served stale haystacks. Mutation-proven.
        #expect(codeLines.contains("_searchHaystacks = nil"),
                "invalidateIndexes must drop _searchHaystacks on a live (non-comment) line")
        #expect(codeLines.contains("LibraryTrackQuery.invalidateResultMemo()"),
                "invalidateIndexes must drop the filter result memo")
        #expect(codeLines.contains { $0.contains("tracksRevision") },
                "tracksRevision must exist so LibraryFilterKey can miss on mutation")
        #expect(codeLines.contains { $0.contains("tracksRevision &+= 1") || $0.contains("tracksRevision += 1") },
                "tracksRevision must be bumped on invalidation")

        // Each mutation that changes searchable content must invalidate.
        for method in ["func addTrack", "func updateTrack", "func removeTrack"] {
            #expect(text.contains(method), "missing \(method)")
        }
        // Require the call on the line after tracks.insert — whole-file
        // contains of both names is the survivor shape.
        #expect(
            text.contains("tracks.insert(track, at: 0)\n        invalidateIndexes()"),
            "addTrack must invalidate immediately after inserting"
        )
        #expect(
            text.contains("tracks[index] = track\n            invalidateIndexes()"),
            "updateTrack must invalidate immediately after replacing"
        )
        #expect(
            text.contains("tracks.removeAll { $0.id == track.id }\n        invalidateIndexes()"),
            "removeTrack must invalidate immediately after removing"
        )
    }

    @Test("LibraryStore source: artwork setters drop ArtworkDecodeCache for the previous path")
    func storeArtworkSettersInvalidateDecodeCache() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/LibraryStore.swift")
            .standardizedFileURL
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(text.contains("ArtworkDecodeCache.remove"),
                "artwork setters must call ArtworkDecodeCache.remove")
        // All three artwork surfaces.
        for method in ["func setArtistPhoto", "func setAlbumArtwork", "func setTrackArtwork"] {
            #expect(text.contains(method), "missing \(method)")
        }
        // Count remove call sites — one per setter is the contract.
        let removes = text.components(separatedBy: "ArtworkDecodeCache.remove").count - 1
        #expect(removes >= 3,
                "expected ≥3 ArtworkDecodeCache.remove call sites (artist/album/track), found \(removes)")
    }
}
