import Foundation

// MARK: - Counted library search / filter
//
// Finding #1 from the main-thread stall sweep that deliberately left the Library
// alone: `LibraryView.filteredTracks` lowercased six fields per track —
// including lyrics (~1 KB) — on every evaluation, and the computed property was
// read ~6× per body pass. Measured ~4–10 ms per pass at 2000 tracks, which is
// in the same league as the browser-row filesystem storm fixed the same day
// (4.5 ms/pass) and well above the keychain P0 (0.65 ms/pass). Unlike those,
// this one fires while the user *types*.
//
// Two traps, both established by measurement on this box:
//
//   1. Replacing `lowercased().contains` with `range(of:options:.caseInsensitive)`
//      measured ~7× SLOWER. Do not "simplify" the predicate that way.
//   2. Memoising only the final filter result helps the 6× body-read multiplier,
//      but every keystroke changes the query and still pays the full per-track
//      lowercasing. The cost that survives a result-only memo is the
//      lowercasing of lyrics. So the haystack below is the pre-lowercased
//      fields — the work that is independent of the query.
//
// `haystackBuildCount` counts TRACKS whose searchable fields were lowercased
// (the expensive thing), not filter evaluations. `filterEvaluationCount` counts
// full filter passes so a multi-read body can be pinned separately. Both are
// process-wide counters behind a lock, same shape as `FileExistenceProbe`.
//
// ⚠️ THESE ARE TEST SEAMS, NOT DEBUG COUNTERS. A pass that only asserts a cache
// variable was assigned has not observed the work being skipped.

/// Pre-lowercased searchable fields for one track.
///
/// Kept as six separate strings (not one concatenated blob) so short-circuit
/// `||` still wins on a title hit and we never scan lyrics when the title
/// already matched. Measured: a single concatenated blob was no faster on hits
/// and forced a full lyrics scan on every miss.
struct LibrarySearchHaystack: Equatable, Sendable {
    let title: String
    let caption: String
    let artist: String
    let album: String
    let genre: String
    let lyrics: String

    /// Build from a track, counting the lowercasing work.
    static func build(from track: Track) -> LibrarySearchHaystack {
        LibraryTrackQuery.noteHaystackBuild()
        return LibrarySearchHaystack(
            title: track.title.lowercased(),
            caption: track.caption.lowercased(),
            artist: (track.artist ?? "").lowercased(),
            album: (track.album ?? "").lowercased(),
            genre: (track.genre ?? "").lowercased(),
            lyrics: (track.lyrics ?? "").lowercased()
        )
    }

    /// Case-folded equality against an already-lowercased needle.
    func matches(lowercasedQuery: String) -> Bool {
        guard !lowercasedQuery.isEmpty else { return true }
        return title.contains(lowercasedQuery)
            || caption.contains(lowercasedQuery)
            || artist.contains(lowercasedQuery)
            || album.contains(lowercasedQuery)
            || genre.contains(lowercasedQuery)
            || lyrics.contains(lowercasedQuery)
    }

    /// Case-folded equality for a category filter value (artist / album / genre).
    func fieldEquals(_ field: LibrarySearchField, lowercasedValue: String) -> Bool {
        switch field {
        case .artist: return artist == lowercasedValue
        case .album: return album == lowercasedValue
        case .genre: return genre == lowercasedValue
        }
    }
}

enum LibrarySearchField: Sendable {
    case artist, album, genre
}

/// Inputs that fully determine a filtered+sorted library list.
///
/// Equatable so the result memo can skip re-work when a body re-reads
/// `filteredTracks` six times with the same state.
struct LibraryFilterKey: Equatable, Sendable {
    let tracksRevision: Int
    let searchText: String
    let filterTypeRaw: String
    let selectedFilterValue: String
    let ratingFilterRaw: String
    let sortByRaw: String
}

enum LibraryTrackQuery {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _haystackBuilds = 0
    private nonisolated(unsafe) static var _filterEvaluations = 0

    /// Times a track's searchable fields were lowercased into a haystack.
    /// The expensive work the Library used to redo on every keystroke.
    static var haystackBuildCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _haystackBuilds
    }

    /// Times a full filter+sort pass actually ran (cache miss on the result memo).
    static var filterEvaluationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _filterEvaluations
    }

    /// Test-only: reset both counters. Production code never calls this.
    static func resetCountsForTesting() {
        lock.lock()
        _haystackBuilds = 0
        _filterEvaluations = 0
        lock.unlock()
    }

    static func noteHaystackBuild() {
        lock.lock()
        _haystackBuilds += 1
        lock.unlock()
    }

    private static func noteFilterEvaluation() {
        lock.lock()
        _filterEvaluations += 1
        lock.unlock()
    }

    // MARK: - Result memo
    //
    // One body pass reads `filteredTracks` for the header count, the play-all
    // disabled state, the list itself, the selection chrome, etc. Without a
    // memo those are independent O(n) passes. The memo is keyed on every input
    // that affects the output — a new track bumps `tracksRevision`, a keystroke
    // changes `searchText` — so staleness is impossible by construction.
    //
    // Held under the same lock as the counters. The payload is value-typed
    // `[Track]`; the only risk is reading a torn key/result pair, which the
    // lock prevents.

    private nonisolated(unsafe) static var memoKey: LibraryFilterKey?
    private nonisolated(unsafe) static var memoResult: [Track] = []

    /// Drop the result memo. Haystacks live on `LibraryStore` and are
    /// invalidated there; this only clears the per-query answer.
    static func invalidateResultMemo() {
        lock.lock()
        memoKey = nil
        memoResult = []
        lock.unlock()
    }

    /// Filter + sort the library. Counts one evaluation when the memo misses.
    ///
    /// `haystacks` must contain an entry for every track id that can survive
    /// the category filters; missing entries are treated as non-matches for
    /// the search text (safer than re-lowercasing on the hot path and
    /// silently undoing the cache).
    static func filteredTracks(
        tracks: [Track],
        haystacks: [UUID: LibrarySearchHaystack],
        key: LibraryFilterKey,
        filterType: LibraryView.FilterType,
        selectedFilterValue: String,
        ratingFilter: LibraryView.RatingFilter,
        sortBy: LibraryView.SortOption
    ) -> [Track] {
        lock.lock()
        if let memoKey, memoKey == key {
            let hit = memoResult
            lock.unlock()
            return hit
        }
        lock.unlock()

        noteFilterEvaluation()

        var result = applyCategoryFilter(
            tracks: tracks,
            haystacks: haystacks,
            filterType: filterType,
            selectedFilterValue: selectedFilterValue,
            ratingFilter: ratingFilter
        )

        let needle = key.searchText.lowercased()
        if !needle.isEmpty {
            result = result.filter { track in
                guard let hay = haystacks[track.id] else { return false }
                return hay.matches(lowercasedQuery: needle)
            }
        }

        sort(&result, by: sortBy, haystacks: haystacks)

        lock.lock()
        memoKey = key
        memoResult = result
        lock.unlock()
        return result
    }

    // MARK: - Category / rating (no search)

    private static func applyCategoryFilter(
        tracks: [Track],
        haystacks: [UUID: LibrarySearchHaystack],
        filterType: LibraryView.FilterType,
        selectedFilterValue: String,
        ratingFilter: LibraryView.RatingFilter
    ) -> [Track] {
        switch filterType {
        case .all:
            break
        case .artist:
            if !selectedFilterValue.isEmpty {
                let v = selectedFilterValue.lowercased()
                return tracks.filter { haystacks[$0.id]?.fieldEquals(.artist, lowercasedValue: v) == true }
            }
        case .album:
            if !selectedFilterValue.isEmpty {
                let v = selectedFilterValue.lowercased()
                return tracks.filter { haystacks[$0.id]?.fieldEquals(.album, lowercasedValue: v) == true }
            }
        case .genre:
            if !selectedFilterValue.isEmpty {
                let v = selectedFilterValue.lowercased()
                return tracks.filter { haystacks[$0.id]?.fieldEquals(.genre, lowercasedValue: v) == true }
            }
        case .rating:
            switch ratingFilter {
            case .all:
                break
            case .five:
                return tracks.filter { $0.rating == 5 }
            case .fourPlus:
                return tracks.filter { $0.rating >= 4 }
            case .threePlus:
                return tracks.filter { $0.rating >= 3 }
            case .unrated:
                return tracks.filter { $0.rating == 0 }
            }
            return tracks
        }
        return tracks
    }

    private static func sort(
        _ tracks: inout [Track],
        by sortBy: LibraryView.SortOption,
        haystacks: [UUID: LibrarySearchHaystack]
    ) {
        switch sortBy {
        case .dateNewest:
            tracks.sort { $0.createdAt > $1.createdAt }
        case .dateOldest:
            tracks.sort { $0.createdAt < $1.createdAt }
        case .nameAZ:
            // Use the pre-lowercased title so sorting does not re-pay lowercasing.
            tracks.sort {
                (haystacks[$0.id]?.title ?? $0.title.lowercased())
                    < (haystacks[$1.id]?.title ?? $1.title.lowercased())
            }
        case .nameZA:
            tracks.sort {
                (haystacks[$0.id]?.title ?? $0.title.lowercased())
                    > (haystacks[$1.id]?.title ?? $1.title.lowercased())
            }
        case .ratingHigh:
            tracks.sort { $0.rating > $1.rating }
        case .ratingLow:
            tracks.sort { $0.rating < $1.rating }
        case .durationLong:
            tracks.sort { $0.duration > $1.duration }
        case .durationShort:
            tracks.sort { $0.duration < $1.duration }
        }
    }
}
