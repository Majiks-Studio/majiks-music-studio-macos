import SwiftUI
import UniformTypeIdentifiers

/// Thread-safe counter for use in concurrent closures (e.g. NSItemProvider callbacks).
private final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var playbackQueue: PlaybackQueue
    @EnvironmentObject var backend: BackendViewModel
    @EnvironmentObject var studioCoordinator: StudioCoordinator
    @EnvironmentObject var publisherStore: PublisherStore
    @EnvironmentObject var stemSessionStore: StemSessionStore
    @State private var selectedTrack: Track?
    @State private var trackToEdit: Track?
    @State private var showEditSheet = false
    @State private var filterType: FilterType = .all
    @State private var selectedFilterValue: String = ""
    @State private var ratingFilter: RatingFilter = .all
    @State private var showArtistAlbumManager = false
    @State private var showNewArtist = false
    @State private var showNewAlbum = false
    @State private var showMoveTrack = false
    @State private var newArtistName = ""
    @State private var newAlbumName = ""
    @State private var trackToMove: Track?
    @State private var moveToArtist = ""
    @State private var moveToAlbum = ""
    @State private var selectionMode = false
    @State private var selectedTrackIds: Set<UUID> = []
    @State private var showBatchMoveDialog = false
    @State private var viewMode: LibraryViewMode = .hierarchical
    @State private var showEditArtist = false
    @State private var showEditAlbum = false
    @State private var artistToEdit: String?
    @State private var albumToEdit: (artist: String, album: String)?
    @State private var editedArtistName = ""
    @State private var editedAlbumName = ""
    @State private var showExportSheet = false
    @State private var exportTracks: [Track] = []
    @State private var showExportAlert = false
    @State private var exportAlertMessage = ""
    @State private var showBatchDeleteConfirmation = false
    @State private var artistToDelete: String?
    @State private var showDeleteArtistConfirmation = false
    @State private var albumToDelete: (artist: String, album: String)?
    @State private var showDeleteAlbumConfirmation = false
    @State private var showSyncReview = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var sortBy: SortOption = .dateNewest
    @State private var analyzingTrackId: UUID?

    enum LibraryViewMode {
        case flat
        case hierarchical
        case grid
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case dateNewest = "Date (Newest)"
        case dateOldest = "Date (Oldest)"
        case nameAZ = "Name (A-Z)"
        case nameZA = "Name (Z-A)"
        case ratingHigh = "Rating (High)"
        case ratingLow = "Rating (Low)"
        case durationLong = "Duration (Long)"
        case durationShort = "Duration (Short)"

        var id: String { rawValue }
    }

    enum FilterType: String, CaseIterable, Identifiable {
        case all = "All Tracks"
        case artist = "By Artist"
        case album = "By Album"
        case genre = "By Genre"
        case rating = "By Rating"

        var id: String { rawValue }
    }

    enum RatingFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case five = "5★"
        case fourPlus = "4★+"
        case threePlus = "3★+"
        case unrated = "Unrated"

        var id: String { rawValue }
    }

    /// Filtered + sorted library, shared by the header, the list, play-all,
    /// and selection chrome.
    ///
    /// ⚠️ NOT FREE. Before the haystack + result memo this lowercased six
    /// fields per track (including lyrics) and was re-evaluated ~6× per body
    /// pass — ~4–10 ms at 2000 tracks, on every keystroke. Now:
    ///   - searchable fields are lowercased once per library mutation into
    ///     `library.searchHaystacks()` (counted by `haystackBuildCount`)
    ///   - the filter+sort result is memoised on `LibraryFilterKey` so six
    ///     body reads cost one evaluation (counted by `filterEvaluationCount`)
    /// Do not restore the inline `lowercased().contains` loop. See
    /// `LibraryTrackQuery` and `LibrarySearchCostTests`.
    var filteredTracks: [Track] {
        let key = LibraryFilterKey(
            tracksRevision: library.tracksRevision,
            searchText: searchText,
            filterTypeRaw: filterType.rawValue,
            selectedFilterValue: selectedFilterValue,
            ratingFilterRaw: ratingFilter.rawValue,
            sortByRaw: sortBy.rawValue
        )
        return LibraryTrackQuery.filteredTracks(
            tracks: library.tracks,
            haystacks: library.searchHaystacks(),
            key: key,
            filterType: filterType,
            selectedFilterValue: selectedFilterValue,
            ratingFilter: ratingFilter,
            sortBy: sortBy
        )
    }

    var availableFilterValues: [String] {
        switch filterType {
        case .all:
            return []
        case .artist:
            return Array(Set(library.tracks.compactMap { $0.artist })).sorted()
        case .album:
            return Array(Set(library.tracks.compactMap { $0.album })).sorted()
        case .genre:
            return Array(Set(library.tracks.compactMap { $0.genre })).sorted()
        case .rating:
            return []
        }
    }

    // MARK: - Computed View Properties

    @ViewBuilder
    private var headerView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(filteredTracks.count) of \(library.tracks.count) track(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()

                // Library Management Buttons
                HStack(spacing: 8) {
                    Button(action: {
                        playbackQueue.playAll(filteredTracks)
                    }) {
                        Label("Play All", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(filteredTracks.isEmpty)
                    .help("Play all visible tracks")

                    Button(action: {
                        playbackQueue.shuffleAll(filteredTracks)
                    }) {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(filteredTracks.isEmpty)
                    .help("Shuffle all visible tracks")

                    Divider()
                        .frame(height: 20)

                    Menu {
                        Button(action: { showNewArtist = true }) {
                            Label("New Artist", systemImage: "person.badge.plus")
                        }
                        Button(action: { showNewAlbum = true }) {
                            Label("New Album", systemImage: "square.stack.3d.up.badge.automatic")
                        }
                        Divider()
                        Button(action: { showArtistAlbumManager = true }) {
                            Label("Browse Artists & Albums", systemImage: "list.bullet")
                        }
                    } label: {
                        Label("Library", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("Create artists, albums, and manage library")

                    // Sync button — only visible when authenticated
                    if publisherStore.authState.isAuthenticated {
                        Button {
                            Task {
                                if publisherStore.catalogueState == .idle {
                                    await publisherStore.fetchCatalogue(backend: backend, library: library)
                                }
                                showSyncReview = true
                            }
                        } label: {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                        .buttonStyle(.bordered)
                        .help("Sync metadata between library and majiks.online")
                    }

                    if selectionMode {
                        Button(action: {
                            selectionMode = false
                            selectedTrackIds.removeAll()
                        }) {
                            Label("Done", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Exit selection mode")
                    } else {
                        Button(action: {
                            selectionMode = true
                        }) {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .help("Select multiple tracks for batch operations")
                    }

                    Divider()
                        .frame(height: 20)

                    // Refresh button
                    Button(action: {
                        Task { await library.scanAndImportMissingTracks() }
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Scan for new audio files")

                    // View mode toggle
                    Picker("", selection: $viewMode) {
                        Label("List", systemImage: "list.bullet").tag(LibraryViewMode.flat)
                        Label("Folders", systemImage: "folder").tag(LibraryViewMode.hierarchical)
                        Label("Grid", systemImage: "square.grid.2x2").tag(LibraryViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .help("Switch between flat list, hierarchical folder, and album grid view")
                }
            }
            .padding()

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search tracks...", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .help("Search by title, artist, album, or genre")
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            // Filter controls
            HStack(spacing: 12) {
                Text("Sort:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("", selection: $sortBy) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .frame(maxWidth: 180)
                .help("Sort tracks by different criteria")

                Divider()
                    .frame(height: 20)

                Text("Filter:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("", selection: $filterType) {
                    ForEach(FilterType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .help("Filter tracks by category")
                .onChange(of: filterType) { _, _ in
                    selectedFilterValue = ""
                    ratingFilter = .all
                }

                if filterType == .rating {
                    Picker("", selection: $ratingFilter) {
                        ForEach(RatingFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .frame(maxWidth: 180)
                } else if filterType != .all && !availableFilterValues.isEmpty {
                    Picker("", selection: $selectedFilterValue) {
                        Text("All \(filterType.rawValue)").tag("")
                        ForEach(availableFilterValues, id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                    .frame(maxWidth: 200)
                }

                Spacer()

                // Library Manager button
                Button(action: {
                    showArtistAlbumManager = true
                }) {
                    Label("Manage Library", systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(.bordered)
                .help("View and organize library folder structure")

                // Quick organize button
                Button(action: {
                    library.organizeAllTracks()
                }) {
                    Label("Auto-Organize", systemImage: "arrow.up.arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .help("Automatically organize all tracks into Artist/Album folders")

                Button(action: {
                    beginExport(for: exportCandidates())
                }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(exportCandidates().isEmpty)
                .help("Export selected or current tracks")

                if filterType != .all {
                    Button("Clear") {
                        filterType = .all
                        selectedFilterValue = ""
                        ratingFilter = .all
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .background(Color.gray.opacity(0.1))
    }

    @ViewBuilder
    private var trackListContent: some View {
        if library.tracks.isEmpty {
            VStack(spacing: 20) {
                Image(systemName: "music.note.house")
                    .font(.system(size: 64))
                    .foregroundStyle(.tertiary)

                Text("Your Library is Empty")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Generate your first track in the Studio tab,\nor import audio files to get started.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button {
                        studioCoordinator.selectedTab = 1
                    } label: {
                        Label("Open Studio", systemImage: "waveform")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: importAudioFiles) {
                        Label("Import Audio", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if viewMode == .hierarchical {
            // 3-column browser (Artist → Album → Tracks)
            ColumnBrowserLibraryView(
                library: library,
                player: player,
                playbackQueue: playbackQueue,
                backend: backend,
                studioCoordinator: studioCoordinator,
                publisherStore: publisherStore,
                selectedTrack: $selectedTrack,
                trackToEdit: $trackToEdit,
                showEditSheet: $showEditSheet,
                onExportTrack: { track in
                    beginExport(for: [track])
                },
                analyzingTrackId: analyzingTrackId,
                searchText: searchText,
                filterType: filterType,
                selectedFilterValue: selectedFilterValue,
                ratingFilter: ratingFilter,
                sortBy: sortBy
            )
        } else if viewMode == .grid {
            AlbumGridView(
                library: library,
                player: player,
                playbackQueue: playbackQueue,
                publisherStore: publisherStore,
                filteredTracks: filteredTracks
            )
        } else {
            flatListView
        }
    }

    /// Says WHICH empty this is. `library.tracks.isEmpty` has its own state
    /// ("Your Library is Empty") one level up; this is the other one — tracks
    /// exist, but the search box or the filter row excluded all of them. The
    /// list previously just rendered nothing, which reads identically to a
    /// broken library.
    ///
    /// Reading `filteredTracks` a second time is free: `LibraryTrackQuery`
    /// memoises on `LibraryFilterKey`, which is what
    /// `LibrarySearchCostTests`' "six filter reads with identical inputs cost
    /// ONE evaluation, not six" pins.
    @ViewBuilder
    private var noMatchesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No tracks match")
                .font(.title3)
                .fontWeight(.semibold)
            Text(noMatchesReason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Names the control that is doing the excluding, so the way out is obvious.
    private var noMatchesReason: String {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSearch = !trimmed.isEmpty
        let hasFilter = filterType != .all
            && (filterType == .rating ? ratingFilter != .all : !selectedFilterValue.isEmpty)

        switch (hasSearch, hasFilter) {
        case (true, true):
            return "\(library.tracks.count) tracks in your library, but none match “\(trimmed)” with the current \(filterType.rawValue) filter. Clear the search box or set Filter back to All."
        case (true, false):
            return "\(library.tracks.count) tracks in your library, but none match “\(trimmed)”. Clear the search box to see them all."
        case (false, true):
            return "\(library.tracks.count) tracks in your library, but none pass the current \(filterType.rawValue) filter. Set Filter back to All to see them."
        case (false, false):
            // No control is excluding anything, so an empty result here means
            // the list genuinely has nothing to show rather than being filtered.
            return "\(library.tracks.count) tracks in your library, but none are showing. Try Manage Library → rescan."
        }
    }

    @ViewBuilder
    private var flatListView: some View {
        if filteredTracks.isEmpty {
            noMatchesView
        } else {
        List {
            ForEach(filteredTracks) { track in
                LibraryTrackRow(
                    track: track,
                    isSelected: selectedTrack?.id == track.id,
                    isPlaying: player.isPlaying && player.currentURL == track.audioURL,
                    selectionMode: selectionMode,
                    isChecked: selectedTrackIds.contains(track.id),
                    isPublished: isTrackPublished(track.id),
                    publishedTrack: publisherStore.catalogueTrackForLibraryTrack(track.id),
                    onToggleSelection: {
                        if selectedTrackIds.contains(track.id) {
                            selectedTrackIds.remove(track.id)
                        } else {
                            selectedTrackIds.insert(track.id)
                        }
                    },
                    onPlay: {
                        playbackQueue.playTrack(track, from: filteredTracks)
                        selectedTrack = track
                    },
                    onPause: {
                        player.pause()
                    },
                    onStop: {
                        player.stop()
                        selectedTrack = nil
                    },
                    onEdit: {
                        trackToEdit = track
                        showEditSheet = true
                    },
                    onExport: {
                        beginExport(for: [track])
                    },
                    onCopy: {
                        // Create a copy of the track with its own audio file
                        do {
                            let copiedAudioFileName = try FileStore.shared.copyAudioFile(from: track.audioFileName)
                            let newTrack = Track(
                                id: UUID(),
                                title: track.title + " (Copy)",
                                caption: track.caption,
                                audioFileName: copiedAudioFileName,
                                createdAt: Date(),
                                duration: track.duration,
                                rating: track.rating,
                                bpm: track.bpm,
                                key: track.key,
                                artist: track.artist,
                                album: track.album,
                                genre: track.genre,
                                lyrics: track.lyrics
                            )
                            library.addTrack(newTrack)
                        } catch {
                            AppLog.error("Failed to copy audio file: \(error)")
                        }
                    },
                    onDelete: {
                        library.removeTrack(track)
                    },
                    onRatingChange: { rating in
                        library.setRating(track.id, rating: rating)
                    },
                    onAutoName: {
                        Task {
                            do {
                                let result = try await backend.generateTrackName(
                                    caption: track.caption.isEmpty ? nil : track.caption,
                                    lyrics: track.lyrics,
                                    bpm: track.bpm,
                                    key: track.key,
                                    artist: track.artist,
                                    genre: track.genre
                                )
                                var updatedTrack = track
                                updatedTrack.title = result.name
                                if let genre = result.genre {
                                    updatedTrack.genre = genre
                                }
                                library.updateTrack(updatedTrack)
                            } catch {
                                AppLog.error("Auto-name failed: \(error)")
                            }
                        }
                    },
                    onSendToStudio: {
                        // Convert Track to MusicParameters and send to Studio
                        let params = BackendViewModel.MusicParameters(
                            caption: track.caption.isEmpty ? "Recreate this track" : track.caption,
                            duration: Int(track.duration),
                            variantCount: 1,
                            bpm: track.bpm.map { Int($0) },
                            key: track.key,
                            lyrics: track.lyrics
                        )
                        studioCoordinator.openStudioWithParameters(params)
                    },
                    onMoveTrack: {
                        trackToMove = track
                        moveToArtist = track.artist ?? ""
                        moveToAlbum = track.album ?? ""
                        showMoveTrack = true
                    },
                    onOpenInStudio: {
                        studioCoordinator.openInStudio(track: track)
                    },
                    onSeparateIntoStems: {
                        beginStemSplit(for: track)
                    },
                    isAnalyzing: analyzingTrackId == track.id
                )
            }
            .onDelete { indexSet in
                for index in indexSet {
                    library.removeTrack(filteredTracks[index])
                }
            }
        }
        .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var bottomToolbars: some View {
        // Batch Operations Toolbar (when in selection mode with selected tracks)
        if selectionMode && !selectedTrackIds.isEmpty {
            BatchOperationsToolbar(
                selectedCount: selectedTrackIds.count,
                onMoveAll: {
                    showBatchMoveDialog = true
                },
                onDeleteAll: {
                    showBatchDeleteConfirmation = true
                },
                onAutoNameAll: {
                    let tracksToName = library.tracks.filter { selectedTrackIds.contains($0.id) }
                    Task {
                        for track in tracksToName {
                            do {
                                let result = try await backend.generateTrackName(
                                    caption: track.caption.isEmpty ? nil : track.caption,
                                    lyrics: track.lyrics,
                                    bpm: track.bpm,
                                    key: track.key,
                                    artist: track.artist,
                                    genre: track.genre
                                )
                                var updatedTrack = track
                                updatedTrack.title = result.name
                                if let genre = result.genre {
                                    updatedTrack.genre = genre
                                }
                                library.updateTrack(updatedTrack)
                            } catch {
                                AppLog.error("Auto-name failed for \(track.title): \(error)")
                            }
                        }
                    }
                    selectedTrackIds.removeAll()
                },
                onExportAll: {
                    beginExport(for: exportCandidates())
                },
                onSelectAll: {
                    selectedTrackIds = Set(filteredTracks.map { $0.id })
                },
                onDeselectAll: {
                    selectedTrackIds.removeAll()
                }
            )
        }

        // Playback controls moved to persistent PersistentPlayerBar in ContentView
    }

    // MARK: - Sheet Helpers

    @ViewBuilder
    private func trackDetailSheet(_ track: Track) -> some View {
        TrackDetailView(
            track: track,
            onSave: { updatedTrack in
                library.updateTrack(updatedTrack)
                library.organizeTrack(updatedTrack)
            },
            onExport: { beginExport(for: [track]) },
            onDelete: {
                library.removeTrack(track)
                trackToEdit = nil
            },
            onSendToStudio: {
                let params = BackendViewModel.MusicParameters(
                    caption: track.caption.isEmpty ? "Recreate this track" : track.caption,
                    duration: Int(track.duration),
                    variantCount: 1,
                    bpm: track.bpm.map { Int($0) },
                    key: track.key,
                    lyrics: track.lyrics
                )
                studioCoordinator.openStudioWithParameters(params)
                trackToEdit = nil
            }
        )
        .environmentObject(library)
    }

    // MARK: - Body

    private var libraryContentWithSheets: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                headerView

                // Track count display
                if !library.tracks.isEmpty {
                    HStack {
                        let count = filteredTracks.count
                        let total = library.tracks.count
                        if count == total {
                            Text("\(count) track\(count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("\(count) of \(total) track\(total == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                trackListContent
                    .onDrop(of: [.audio, .fileURL], isTargeted: nil) { providers in
                        handleFileDrop(providers)
                        return true
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(direction: .down)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(direction: .up)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        if let track = selectedTrack {
                            trackToEdit = track
                            showEditSheet = true
                        }
                        return .handled
                    }
                    .onKeyPress(.delete) {
                        if selectionMode && !selectedTrackIds.isEmpty {
                            showBatchDeleteConfirmation = true
                        } else if let track = selectedTrack {
                            library.removeTrack(track)
                            selectedTrack = nil
                        }
                        return .handled
                    }

                bottomToolbars
            }

            // Floating volume control (bottom-right corner)
            LibraryVolumeControlView()
                .padding(.trailing, 20)
                .padding(.bottom, 20)
        }
        .sheet(item: $trackToEdit) { track in
            trackDetailSheet(track)
        }
        .sheet(isPresented: $showArtistAlbumManager) {
            ArtistAlbumManagerView()
                .environmentObject(library)
        }
        .sheet(isPresented: $showNewArtist) {
            NewArtistSheet(
                artistName: $newArtistName,
                onSave: {
                    createNewArtist()
                    showNewArtist = false
                },
                onCancel: {
                    newArtistName = ""
                    showNewArtist = false
                }
            )
        }
        .alert("Delete Selected Tracks?", isPresented: $showBatchDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                let tracksToDelete = library.tracks.filter { selectedTrackIds.contains($0.id) }
                for track in tracksToDelete {
                    library.removeTrack(track)
                }
                selectedTrackIds.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all selected tracks.")
        }
        .alert("Delete Artist?", isPresented: $showDeleteArtistConfirmation) {
            Button("Delete", role: .destructive) {
                if let artist = artistToDelete {
                    deleteArtist(artist)
                    artistToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                artistToDelete = nil
            }
        } message: {
            Text("This will permanently delete the artist \"\(artistToDelete ?? "")\" and all associated tracks.")
        }
        .alert("Delete Album?", isPresented: $showDeleteAlbumConfirmation) {
            Button("Delete", role: .destructive) {
                if let info = albumToDelete {
                    deleteAlbum(artist: info.artist, album: info.album)
                    albumToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                albumToDelete = nil
            }
        } message: {
            Text("This will permanently delete the album \"\(albumToDelete?.album ?? "")\" and all its tracks.")
        }
        .sheet(isPresented: $showNewAlbum) {
            NewAlbumSheet(
                albumName: $newAlbumName,
                artistName: newArtistName,
                onSave: {
                    createNewAlbum()
                    showNewAlbum = false
                },
                onCancel: {
                    newAlbumName = ""
                    showNewAlbum = false
                }
            )
        }
        .sheet(isPresented: $showMoveTrack) {
            if let track = trackToMove {
                MoveTrackSheet(
                    track: track,
                    library: library,
                    selectedArtist: $moveToArtist,
                    selectedAlbum: $moveToAlbum,
                    onSave: {
                        moveTrack(track)
                        showMoveTrack = false
                    },
                    onCancel: {
                        trackToMove = nil
                        moveToArtist = ""
                        moveToAlbum = ""
                        showMoveTrack = false
                    }
                )
            }
        }
        .sheet(isPresented: $showBatchMoveDialog) {
            BatchMoveTracksSheet(
                trackCount: selectedTrackIds.count,
                library: library,
                selectedArtist: $moveToArtist,
                selectedAlbum: $moveToAlbum,
                onSave: {
                    batchMoveTracks()
                    showBatchMoveDialog = false
                },
                onCancel: {
                    moveToArtist = ""
                    moveToAlbum = ""
                    showBatchMoveDialog = false
                }
            )
        }
        .sheet(isPresented: $showEditArtist) {
            if let artist = artistToEdit {
                EditArtistSheet(
                    originalName: artist,
                    editedName: $editedArtistName,
                    onSave: {
                        renameArtist(from: artist, to: editedArtistName)
                        showEditArtist = false
                    },
                    onCancel: {
                        artistToEdit = nil
                        editedArtistName = ""
                        showEditArtist = false
                    }
                )
            }
        }
        .sheet(isPresented: $showEditAlbum) {
            if let albumInfo = albumToEdit {
                EditAlbumSheet(
                    artistName: albumInfo.artist,
                    originalAlbumName: albumInfo.album,
                    editedName: $editedAlbumName,
                    onSave: {
                        renameAlbum(artist: albumInfo.artist, from: albumInfo.album, to: editedAlbumName)
                        showEditAlbum = false
                    },
                    onCancel: {
                        albumToEdit = nil
                        editedAlbumName = ""
                        showEditAlbum = false
                    }
                )
            }
        }
    }

    private var libraryWithExportAndAlerts: some View {
        libraryContentWithSheets
        .sheet(isPresented: $showExportSheet) {
            ExportView(tracks: exportTracks) { request in
                Task {
                    do {
                        // Convert bitrate to string format (e.g., "192k")
                        let bitrateStr = request.bitrateKbps.map { "\($0)k" }

                        var exportedPaths: [String] = []

                        // Verify destination directory exists and is writable
                        let destDir = request.destination
                            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
                        if !FileManager.default.fileExists(atPath: destDir.path) {
                            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                        }

                        // Export each track
                        for track in request.tracks {
                            // Verify source audio file exists
                            guard track.audioFileExists else {
                                throw NSError(
                                    domain: "MajikExport", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Audio file not found for '\(track.title)'. The source file may have been moved or deleted."]
                                )
                            }

                            // Generate output path
                            let filename = "\(track.title).\(request.format.fileExtension)"
                            let outputURL = destDir.appendingPathComponent(filename)

                            // Build metadata dict for audio tag embedding
                            var exportMetadata: [String: String] = [:]
                            exportMetadata["title"] = track.title
                            if let artist = track.artist { exportMetadata["artist"] = artist }
                            if let album = track.album { exportMetadata["album"] = album }
                            if let genre = track.genre { exportMetadata["genre"] = genre }
                            if let bpm = track.bpm { exportMetadata["bpm"] = String(Int(bpm)) }
                            if let isrc = track.isrc { exportMetadata["isrc"] = isrc }

                            // Call backend
                            let exportedPath = try await backend.exportTrack(
                                filePath: track.audioURL.path,
                                outputPath: outputURL.path,
                                format: request.format.fileExtension,
                                bitrate: bitrateStr,
                                metadata: exportMetadata
                            )

                            // Verify export produced a file
                            guard FileManager.default.fileExists(atPath: exportedPath) else {
                                throw NSError(
                                    domain: "MajikExport", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "Export completed but file not found at '\(exportedPath)'."]
                                )
                            }

                            exportedPaths.append(exportedPath)
                            AppLog.info("Exported: \(track.title) -> \(exportedPath)")
                        }

                        // Success
                        await MainActor.run {
                            exportAlertMessage = "Successfully exported \(exportedPaths.count) track(s) to \(request.destination?.path ?? "~/Music")"
                            showExportAlert = true
                            showExportSheet = false
                        }

                    } catch {
                        // Error
                        await MainActor.run {
                            exportAlertMessage = "Export failed: \(error.localizedDescription)"
                            showExportAlert = true
                            showExportSheet = false
                        }
                        AppLog.error("Export error: \(error)")
                    }
                }
            }
        }
        .sheet(isPresented: $showSyncReview) {
            SyncReviewSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowNewArtist"))) { _ in
            showNewArtist = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowNewAlbum"))) { _ in
            showNewAlbum = true
        }
        .alert("Export", isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage)
        }
        .onAppear {
            // Auto-fetch catalogue for publish status badges
            if publisherStore.authState.isAuthenticated,
               publisherStore.catalogueState == .idle {
                Task { await publisherStore.fetchCatalogue(backend: backend) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SetArtistPhoto"))) { notification in
            guard let info = notification.userInfo,
                  let artist = info["artist"] as? String else { return }
            let url = info["url"] as? URL
            library.setArtistPhoto(artist, imageURL: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SetAlbumArtwork"))) { notification in
            guard let info = notification.userInfo,
                  let artist = info["artist"] as? String,
                  let album = info["album"] as? String else { return }
            let url = info["url"] as? URL
            library.setAlbumArtwork(artist: artist, album: album, imageURL: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RenameArtist"))) { notification in
            if let artist = notification.userInfo?["artist"] as? String {
                editedArtistName = artist
                artistToEdit = artist
                showEditArtist = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DeleteArtist"))) { notification in
            if let artist = notification.userInfo?["artist"] as? String {
                artistToDelete = artist
                showDeleteArtistConfirmation = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RenameAlbum"))) { notification in
            if let artist = notification.userInfo?["artist"] as? String,
               let album = notification.userInfo?["album"] as? String {
                albumToEdit = (artist: artist, album: album)
                editedAlbumName = album
                showEditAlbum = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DeleteAlbum"))) { notification in
            if let artist = notification.userInfo?["artist"] as? String,
               let album = notification.userInfo?["album"] as? String {
                albumToDelete = (artist: artist, album: album)
                showDeleteAlbumConfirmation = true
            }
        }
    }

    var body: some View {
        libraryWithExportAndAlerts
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PublishTrack"))) { notification in
            if let trackId = notification.userInfo?["trackId"] as? UUID,
               let track = library.tracks.first(where: { $0.id == trackId }) {
                Task {
                    let candidate = PublishCandidate(from: track)
                    publisherStore.addCandidates(from: [track])
                    await publisherStore.publishSingle(candidate, backend: backend, library: library)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("StageForPublish"))) { notification in
            if let trackId = notification.userInfo?["trackId"] as? UUID,
               let track = library.tracks.first(where: { $0.id == trackId }) {
                publisherStore.addCandidates(from: [track])
                studioCoordinator.selectedTab = 3
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UnpublishTrack"))) { notification in
            if let trackId = notification.userInfo?["trackId"] as? UUID,
               let catalogueTrack = publisherStore.catalogueTrackForLibraryTrack(trackId) {
                Task {
                    await publisherStore.unpublishCatalogueTrack(catalogueTrack, backend: backend)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UpdatePublishedTrack"))) { notification in
            if let trackId = notification.userInfo?["trackId"] as? UUID,
               let track = library.tracks.first(where: { $0.id == trackId }),
               let catalogueTrack = publisherStore.catalogueTrackForLibraryTrack(trackId) {
                Task {
                    do {
                        guard let auth = await publisherStore.validAuthContext() else { return }
                        try await backend.updatePublishedTrack(
                            trackId: catalogueTrack.trackId,
                            keycloakId: auth.keycloakId,
                            title: track.title,
                            genre: track.genre,
                            artist: track.artist,
                            bpm: track.bpm.map { String(Int($0)) },
                            musicalKey: track.key,
                            lyrics: track.lyrics,
                            accessToken: auth.accessToken
                        )
                        // Refresh catalogue to pick up changes
                        await publisherStore.fetchCatalogue(backend: backend)
                    } catch {
                        AppLog.error("Failed to update published track: \(error)")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MoveTrackToArtist"))) { notification in
            if let trackIdString = notification.userInfo?["trackId"] as? String,
               let trackId = UUID(uuidString: trackIdString),
               let artistName = notification.userInfo?["artist"] as? String {
                if var track = library.tracks.first(where: { $0.id == trackId }) {
                    let targetArtist = artistName == "Working Files" ? nil : artistName
                    track.artist = targetArtist
                    track.album = nil
                    library.updateTrack(track)
                    library.organizeTrack(track)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MoveTrackToAlbum"))) { notification in
            if let trackIdString = notification.userInfo?["trackId"] as? String,
               let trackId = UUID(uuidString: trackIdString),
               let artistName = notification.userInfo?["artist"] as? String,
               let albumName = notification.userInfo?["album"] as? String {
                if var track = library.tracks.first(where: { $0.id == trackId }) {
                    let targetArtist = artistName == "Working Files" ? nil : artistName
                    let targetAlbum = albumName == "Unsorted" ? nil : albumName
                    track.artist = targetArtist
                    track.album = targetAlbum
                    library.updateTrack(track)
                    library.organizeTrack(track)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FocusLibrarySearch"))) { _ in
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ImportAudioToLibrary"))) { _ in
            importAudioFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AnalyzeWithEngineer"))) { notification in
            if let trackId = notification.userInfo?["trackId"] as? UUID,
               let track = library.tracks.first(where: { $0.id == trackId }) {
                analyzingTrackId = trackId
                Task {
                    do {
                        let result = try await backend.analyzeAudioFile(
                            path: track.audioURL.path,
                            caption: track.caption,
                            title: track.title
                        )
                        // Update the track with extracted parameters
                        if var updatedTrack = library.tracks.first(where: { $0.id == trackId }) {
                            if result.bpm != nil {
                                updatedTrack.bpm = Double(result.bpm!)
                            }
                            if let key = result.key, !key.isEmpty {
                                updatedTrack.key = key
                            }
                            if result.duration > 0 {
                                updatedTrack.duration = Double(result.duration)
                            }
                            if let lyrics = result.lyrics, !lyrics.isEmpty {
                                updatedTrack.lyrics = lyrics
                            }
                            if !result.caption.isEmpty {
                                updatedTrack.caption = result.caption
                            }
                            library.updateTrack(updatedTrack)
                            AppLog.info("Engineer analysis complete for '\(updatedTrack.title)': BPM=\(updatedTrack.bpm.map { String(Int($0)) } ?? "nil"), key=\(updatedTrack.key ?? "nil")")
                        }
                    } catch {
                        AppLog.error("Engineer analysis failed for track \(trackId): \(error)")
                    }
                    analyzingTrackId = nil
                }
            }
        }
    }

    private enum SelectionDirection { case up, down }

    private func moveSelection(direction: SelectionDirection) {
        let tracks = filteredTracks
        guard !tracks.isEmpty else { return }
        if let current = selectedTrack,
           let idx = tracks.firstIndex(where: { $0.id == current.id }) {
            switch direction {
            case .down:
                let next = idx + 1 < tracks.count ? idx + 1 : idx
                selectedTrack = tracks[next]
            case .up:
                let prev = idx > 0 ? idx - 1 : 0
                selectedTrack = tracks[prev]
            }
        } else {
            selectedTrack = direction == .down ? tracks.first : tracks.last
        }
    }

    private func createNewArtist() {
        guard !newArtistName.isEmpty else { return }

        let artistFolder = library.getArtistFolder(for: newArtistName)
        let singlesFolder = artistFolder.appendingPathComponent("Singles", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: singlesFolder,
                withIntermediateDirectories: true
            )
        } catch {
            AppLog.error("Failed to create artist directory for '\(newArtistName)': \(error.localizedDescription)")
        }

        AppLog.info("Created artist: \(newArtistName)")
        newArtistName = ""
    }

    private func createNewAlbum() {
        guard !newAlbumName.isEmpty else { return }

        // If no specific artist context, use "Unknown Artist"
        let artist = newArtistName.isEmpty ? "Unknown Artist" : newArtistName
        let albumFolder = library.getAlbumFolder(for: artist, album: newAlbumName)

        try? FileManager.default.createDirectory(
            at: albumFolder,
            withIntermediateDirectories: true
        )

        AppLog.info("Created album: \(newAlbumName) for \(artist)")
        newAlbumName = ""
    }

    private func moveTrack(_ track: Track) {
        var updatedTrack = track
        updatedTrack.artist = moveToArtist.isEmpty ? nil : moveToArtist
        updatedTrack.album = moveToAlbum.isEmpty ? nil : moveToAlbum

        library.updateTrack(updatedTrack)
        library.organizeTrack(updatedTrack)

        AppLog.info("Moved track '\(track.title)' to \(moveToArtist)/\(moveToAlbum)")

        // Reset state
        trackToMove = nil
        moveToArtist = ""
        moveToAlbum = ""
    }

    private func batchMoveTracks() {
        let tracksToMove = library.tracks.filter { selectedTrackIds.contains($0.id) }

        for track in tracksToMove {
            var updatedTrack = track
            updatedTrack.artist = moveToArtist.isEmpty ? nil : moveToArtist
            updatedTrack.album = moveToAlbum.isEmpty ? nil : moveToAlbum

            library.updateTrack(updatedTrack)
            library.organizeTrack(updatedTrack)
        }

        AppLog.info("Batch moved \(tracksToMove.count) track(s) to \(moveToArtist)/\(moveToAlbum)")

        // Reset state
        selectedTrackIds.removeAll()
        moveToArtist = ""
        moveToAlbum = ""
    }

    private func renameArtist(from oldName: String, to newName: String) {
        guard !newName.isEmpty, oldName != newName else { return }

        let isMerge = library.getAllArtists().contains(newName)

        // Update all tracks with this artist
        let tracksToUpdate = library.tracks.filter { $0.artist == oldName }
        for track in tracksToUpdate {
            var updatedTrack = track
            updatedTrack.artist = newName
            library.updateTrack(updatedTrack)
            library.organizeTrack(updatedTrack)
        }

        // Handle folder on disk
        let oldFolder = library.getArtistFolder(for: oldName)
        if isMerge {
            // organizeTrack already moved files into the existing artist folder;
            // remove the now-empty old folder
            try? FileManager.default.removeItem(at: oldFolder)
            AppLog.info("Merged artist '\(oldName)' into existing artist '\(newName)'")
        } else {
            // Simple rename – move the folder
            let newFolder = library.getArtistFolder(for: newName)
            do {
                try FileManager.default.moveItem(at: oldFolder, to: newFolder)
            } catch {
                AppLog.error("Failed to rename artist folder from '\(oldName)' to '\(newName)': \(error.localizedDescription)")
            }
            AppLog.info("Renamed artist '\(oldName)' to '\(newName)'")
        }

        artistToEdit = nil
        editedArtistName = ""
    }

    private func deleteArtist(_ artist: String) {
        // Delete all tracks by this artist
        let tracksToDelete = library.tracks.filter { $0.artist == artist }
        for track in tracksToDelete {
            library.removeTrack(track)
        }

        // Delete folder on disk
        let artistFolder = library.getArtistFolder(for: artist)
        try? FileManager.default.removeItem(at: artistFolder)

        AppLog.info("Deleted artist '\(artist)' and \(tracksToDelete.count) track(s)")
    }

    private func renameAlbum(artist: String, from oldName: String, to newName: String) {
        guard !newName.isEmpty, oldName != newName else { return }

        let isMerge = library.getAllAlbums(for: artist).contains(newName)

        // Update all tracks in this album
        let tracksToUpdate = library.tracks.filter { $0.artist == artist && $0.album == oldName }
        for track in tracksToUpdate {
            var updatedTrack = track
            updatedTrack.album = newName
            library.updateTrack(updatedTrack)
            library.organizeTrack(updatedTrack)
        }

        // Handle folder on disk
        let oldFolder = library.getAlbumFolder(for: artist, album: oldName)
        if isMerge {
            // organizeTrack already moved files into the existing album folder;
            // remove the now-empty old folder
            try? FileManager.default.removeItem(at: oldFolder)
            AppLog.info("Merged album '\(oldName)' into existing album '\(newName)' for artist '\(artist)'")
        } else {
            // Simple rename – move the folder
            let newFolder = library.getAlbumFolder(for: artist, album: newName)
            try? FileManager.default.moveItem(at: oldFolder, to: newFolder)
            AppLog.info("Renamed album '\(oldName)' to '\(newName)' for artist '\(artist)'")
        }

        albumToEdit = nil
        editedAlbumName = ""
    }

    private func deleteAlbum(artist: String, album: String) {
        // Delete all tracks in this album
        let tracksToDelete = library.tracks.filter { $0.artist == artist && $0.album == album }
        for track in tracksToDelete {
            library.removeTrack(track)
        }

        // Delete folder on disk
        let albumFolder = library.getAlbumFolder(for: artist, album: album)
        try? FileManager.default.removeItem(at: albumFolder)

        AppLog.info("Deleted album '\(album)' by '\(artist)' and \(tracksToDelete.count) track(s)")
    }

    private func exportCandidates() -> [Track] {
        if selectionMode && !selectedTrackIds.isEmpty {
            return library.tracks.filter { selectedTrackIds.contains($0.id) }
        }
        if let selected = selectedTrack {
            return [selected]
        }
        return []
    }

    /// Returns whether a track is published on majiks.online.
    private func isTrackPublished(_ trackId: UUID) -> Bool {
        return publisherStore.isTrackPublished(trackId)
    }

    private func beginExport(for tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        exportTracks = tracks
        showExportSheet = true
    }

    private func importAudioFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mp3, UTType(filenameExtension: "flac") ?? .audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose audio files to import to your library"
        panel.prompt = "Import"

        if panel.runModal() == .OK {
            var importedCount = 0
            for url in panel.urls {
                let dest = FileStore.shared.audioDirectory.appendingPathComponent(url.lastPathComponent)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.copyItem(at: url, to: dest)
                }
                importedCount += 1
            }
            // Await the scan so we know which tracks were actually added,
            // then run metadata extraction against the real delta. The old
            // code raced the scan task and almost always saw an empty delta.
            Task {
                let newTracks = await library.scanAndImportMissingTracks()
                ToastManager.shared.show("Imported \(importedCount) track(s)", style: .success)
                if !newTracks.isEmpty {
                    extractMetadataForTracks(newTracks)
                }
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) {
        let audioExtensions: Set<String> = ["wav", "mp3", "flac", "m4a", "aac", "aif", "aiff"]
        let counter = SendableCounter()
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                group.enter()
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    defer { group.leave() }
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          audioExtensions.contains(url.pathExtension.lowercased()) else { return }
                    let dest = FileStore.shared.audioDirectory.appendingPathComponent(url.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try? FileManager.default.copyItem(at: url, to: dest)
                    }
                    counter.increment()
                }
            }
        }

        group.notify(queue: .main) {
            let count = counter.value
            if count > 0 {
                Task {
                    let newTracks = await library.scanAndImportMissingTracks()
                    ToastManager.shared.show("Imported \(count) file(s)", style: .success)
                    if !newTracks.isEmpty {
                        extractMetadataForTracks(newTracks)
                    }
                }
            }
        }
    }

    /// Run background metadata extraction on newly imported tracks.
    /// Uses the backend's ``understand_music`` RPC which provides BPM, key,
    /// caption, lyrics, language and time signature via ACE-Step's music
    /// understanding (falls back to librosa for basic BPM/key when AI models
    /// are unavailable).
    /// Split this song into its parts and show them in the Stems tab.
    ///
    /// The Library is the second place a person looks for this, and until now
    /// it offered "Open in Studio" (which separates, but lands a whole
    /// arrangement on the timeline) and nothing that says the word a person
    /// would search for.
    ///
    /// ⚠️ THE TAB SWITCH HAPPENS FIRST, BEFORE the minutes of work. That is
    /// deliberate: the run publishes its progress into the Stems tab, so a
    /// person who stayed here would sit in the Library with no feedback at all
    /// for several minutes and reasonably conclude the menu item did nothing —
    /// which is the exact defect class this lane exists to close. Sending them
    /// to the screen that shows the progress bar is the honest move, and it is
    /// also where the result lands.
    private func beginStemSplit(for track: Track) {
        let run = StemSeparationRun.shared
        guard let separator = studioCoordinator.stemSeparator else {
            run.failure = StemSeparationRun.noSeparatorReason
            studioCoordinator.openStemSessions()
            return
        }
        guard !run.isRunning else {
            run.failure = StemSeparationRun.alreadyRunningRefusal
            studioCoordinator.openStemSessions()
            return
        }
        studioCoordinator.openStemSessions()
        Task {
            _ = await run.separateIntoSession(
                source: track.audioURL,
                title: track.title,
                sourceTrackID: track.id,
                using: separator,
                store: stemSessionStore,
                coordinator: studioCoordinator,
                outputRoot: FileStore.shared.baseDirectory)
        }
    }

    private func extractMetadataForTracks(_ tracks: [Track]) {
        guard backend.isConnected else { return }
        for track in tracks {
            Task {
                do {
                    let result = try await backend.understandMusic(audioPath: track.audioURL.path)
                    // Find the track again (it may have moved in the array)
                    guard var updated = library.tracks.first(where: { $0.id == track.id }) else { return }

                    var changed = false
                    if updated.bpm == nil, let bpm = result.bpm {
                        updated.bpm = bpm
                        changed = true
                    }
                    if updated.key == nil || updated.key?.isEmpty == true, let key = result.key, !key.isEmpty {
                        updated.key = key
                        changed = true
                    }
                    if !result.caption.isEmpty && updated.caption.isEmpty {
                        updated.caption = result.caption
                        changed = true
                    }
                    if updated.lyrics == nil || updated.lyrics?.isEmpty == true,
                       !result.lyrics.isEmpty {
                        updated.lyrics = result.lyrics
                        changed = true
                    }
                    if updated.genre == nil || updated.genre?.isEmpty == true,
                       let lang = result.language, !lang.isEmpty {
                        // Store language in extendedMetadata since Track doesn't have a language field
                        var meta = updated.extendedMetadata ?? [:]
                        meta["language"] = lang
                        updated.extendedMetadata = meta
                        changed = true
                    }
                    if let ts = result.timeSignature, !ts.isEmpty {
                        var meta = updated.extendedMetadata ?? [:]
                        meta["time_signature"] = ts
                        updated.extendedMetadata = meta
                        changed = true
                    }

                    if changed {
                        library.updateTrack(updated)
                    }
                } catch {
                    // Silent fail — metadata extraction is best-effort.
                    // Users can always set metadata manually or re-analyze later.
                    AppLog.info("Auto-metadata extraction failed for \(track.title): \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Library Volume Control

struct LibraryVolumeControlView: View {
    @EnvironmentObject var player: AudioPlayer
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 8) {
            if isExpanded {
                Slider(value: $player.volume, in: 0...1)
                    .frame(width: 100)
                    .controlSize(.small)
            }

            Button(action: { isExpanded.toggle() }) {
                Image(systemName: volumeIcon)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Volume: \(Int(player.volume * 100))%")
        }
        .padding(8)
        .background(.regularMaterial)
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private var volumeIcon: String {
        if player.volume == 0 {
            return "speaker.slash.fill"
        } else if player.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if player.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}

struct GlobalPlaybackControls: View {
    let track: Track?
    @ObservedObject var player: AudioPlayer
    let onStop: () -> Void
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 16) {
                // Track info
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(
                            colors: [.blue.opacity(0.6), .purple.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(.white)
                        )

                    if let track = track {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Text(formatDuration(player.currentTime) + " / " + formatDuration(track.duration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("No track selected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                // Progress bar
                if let track = track {
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { isSeeking ? seekPosition : player.currentTime },
                                set: { newValue in
                                    seekPosition = newValue
                                    isSeeking = true
                                }
                            ),
                            in: 0...track.duration,
                            onEditingChanged: { editing in
                                if !editing {
                                    player.seek(to: seekPosition)
                                    isSeeking = false
                                }
                            }
                        )
                        .frame(maxWidth: 300)
                    }
                }

                Spacer()

                // Playback controls
                HStack(spacing: 12) {
                    Button(action: { player.seek(to: max(0, player.currentTime - 10)) }) {
                        Image(systemName: "gobackward.10")
                    }
                    .buttonStyle(.bordered)

                    if player.isPlaying {
                        Button(action: { player.pause() }) {
                            Image(systemName: "pause.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: { player.play() }) {
                            Image(systemName: "play.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button(action: { player.seek(to: min(track?.duration ?? 0, player.currentTime + 10)) }) {
                        Image(systemName: "goforward.10")
                    }
                    .buttonStyle(.bordered)

                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                Spacer()

                // Volume control
                HStack(spacing: 8) {
                    Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Slider(value: $player.volume, in: 0...1)
                        .frame(width: 100)
                    Text("\(Int(player.volume * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 35)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.05))
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Album Grid View

struct AlbumGridView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: AudioPlayer
    @ObservedObject var playbackQueue: PlaybackQueue
    @ObservedObject var publisherStore: PublisherStore
    let filteredTracks: [Track]

    @State private var selectedAlbum: String?
    @State private var hoveredAlbum: String?

    /// Groups tracks by album name. Tracks without an album use their title as the key
    /// prefixed with a sentinel so they sort separately and don't collide with real album names.
    private var albumGroups: [(key: String, tracks: [Track])] {
        let grouped = Dictionary(grouping: filteredTracks) { track -> String in
            track.album ?? "\u{0000}__single__\(track.id.uuidString)"
        }
        return grouped
            .sorted { lhs, rhs in
                // Put real albums first, singles (sentinel-prefixed) last
                let lhsIsSingle = lhs.key.hasPrefix("\u{0000}__single__")
                let rhsIsSingle = rhs.key.hasPrefix("\u{0000}__single__")
                if lhsIsSingle != rhsIsSingle { return !lhsIsSingle }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { (key: $0.key, tracks: $0.value) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 16) {
                ForEach(albumGroups, id: \.key) { group in
                    let isSingle = group.key.hasPrefix("\u{0000}__single__")
                    let displayName = isSingle ? group.tracks.first?.title ?? "Unknown" : group.key
                    let artistName = group.tracks.first?.artist ?? "Unknown Artist"

                    AlbumGridCell(
                        albumKey: group.key,
                        displayName: displayName,
                        artistName: artistName,
                        tracks: group.tracks,
                        isSingle: isSingle,
                        isHovered: hoveredAlbum == group.key,
                        isSelected: selectedAlbum == group.key,
                        library: library,
                        onPlay: {
                            playbackQueue.playAll(group.tracks)
                        },
                        onSelect: {
                            if selectedAlbum == group.key {
                                selectedAlbum = nil
                            } else {
                                selectedAlbum = group.key
                            }
                        }
                    )
                    .onHover { hovering in
                        hoveredAlbum = hovering ? group.key : nil
                    }
                }
            }
            .padding()

            // Expanded track list for selected album
            if let selected = selectedAlbum,
               let group = albumGroups.first(where: { $0.key == selected }) {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    let isSingle = selected.hasPrefix("\u{0000}__single__")
                    Text(isSingle ? (group.tracks.first?.title ?? "Track") : selected)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .padding(.horizontal)
                        .padding(.top, 4)

                    ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 24, alignment: .trailing)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(track.artist ?? "Unknown Artist")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(formatDuration(track.duration))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            // Play/pause button for individual track
                            Button(action: {
                                if player.isPlaying && player.currentURL == track.audioURL {
                                    player.pause()
                                } else {
                                    playbackQueue.playTrack(track, from: group.tracks)
                                }
                            }) {
                                Image(systemName: player.isPlaying && player.currentURL == track.audioURL ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(player.currentURL == track.audioURL ? Color.accentColor.opacity(0.1) : Color.clear)
                        )
                    }
                }
                .padding(.bottom)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

struct AlbumGridCell: View {
    let albumKey: String
    let displayName: String
    let artistName: String
    let tracks: [Track]
    let isSingle: Bool
    let isHovered: Bool
    let isSelected: Bool
    let library: LibraryStore
    let onPlay: () -> Void
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Artwork with play overlay
            ZStack {
                artworkView
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)

                if isHovered {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.3))
                        .frame(width: 160, height: 160)

                    Button(action: onPlay) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onTapGesture {
                onSelect()
            }

            // Album name
            Text(displayName)
                .font(.headline)
                .lineLimit(1)

            // Artist name
            Text(artistName)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            // Track count (only for albums with multiple tracks)
            if !isSingle {
                Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 160)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
    }

    @ViewBuilder
    private var artworkView: some View {
        // Every decode goes through ArtworkDecodeCache — uncached
        // NSImage(contentsOf:) inside a grid cell body was finding #2 of the
        // main-thread stall sweep (577 µs/call, re-run every body pass).
        if !isSingle,
           let firstTrack = tracks.first,
           let artist = firstTrack.artist,
           let album = firstTrack.album {
            // Try album-level artwork first
            let albumVM = library.getAlbumViewModel(artist: artist, album: album)
            if let artworkURL = albumVM.artworkURL,
               FileExistenceProbe.exists(atPath: artworkURL.path),
               let nsImage = ArtworkDecodeCache.image(at: artworkURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let customURL = firstTrack.customArtworkURL,
                      FileExistenceProbe.exists(atPath: customURL.path),
                      let nsImage = ArtworkDecodeCache.image(at: customURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                AlbumArtGenerator.generate(for: "\(artist)|\(album)", size: 160)
            }
        } else if let track = tracks.first {
            // Single track or no album
            if let customURL = track.customArtworkURL,
               FileExistenceProbe.exists(atPath: customURL.path),
               let nsImage = ArtworkDecodeCache.image(at: customURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                AlbumArtGenerator.generate(for: track.id.uuidString, size: 160)
            }
        } else {
            AlbumArtGenerator.generate(for: albumKey, size: 160)
        }
    }
}

// MARK: - Persistent Player Bar (app-wide, below TabView)

struct ColumnBrowserLibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: AudioPlayer
    @ObservedObject var playbackQueue: PlaybackQueue
    @ObservedObject var backend: BackendViewModel
    @ObservedObject var studioCoordinator: StudioCoordinator
    @ObservedObject var publisherStore: PublisherStore
    @Binding var selectedTrack: Track?
    @Binding var trackToEdit: Track?
    @Binding var showEditSheet: Bool
    let onExportTrack: (Track) -> Void
    var analyzingTrackId: UUID? = nil

    // Filter parameters (read-only, controlled by LibraryView)
    let searchText: String
    let filterType: LibraryView.FilterType
    let selectedFilterValue: String
    let ratingFilter: LibraryView.RatingFilter
    let sortBy: LibraryView.SortOption

    // Selection state
    @State private var selectedArtist: String?
    @State private var selectedAlbum: String?
    @State private var focusedColumn: ColumnFocus = .artists

    enum ColumnFocus {
        case artists, albums, tracks
    }

    // MARK: - Filtered Data

    /// Applies the same filter logic as LibraryView.filteredTracks so the
    /// column browser respects search, category and rating filters.
    private func isTrackPublished(_ trackId: UUID) -> Bool {
        return publisherStore.isTrackPublished(trackId)
    }

    /// Same predicate as `LibraryView.filteredTracks`, without the sort step
    /// the column browser applies later per-column. Goes through the counted
    /// haystack path so typing in the shared search box does not re-lowercase
    /// lyrics for every column derivation.
    private var filteredLibraryTracks: [Track] {
        let key = LibraryFilterKey(
            tracksRevision: library.tracksRevision,
            searchText: searchText,
            filterTypeRaw: filterType.rawValue,
            selectedFilterValue: selectedFilterValue,
            ratingFilterRaw: ratingFilter.rawValue,
            // Column browser re-sorts its own track list; pin the memo on the
            // same sort the parent is using so the two views share one pass
            // when both are alive (they are not, but the key must be total).
            sortByRaw: sortBy.rawValue
        )
        return LibraryTrackQuery.filteredTracks(
            tracks: library.tracks,
            haystacks: library.searchHaystacks(),
            key: key,
            filterType: filterType,
            selectedFilterValue: selectedFilterValue,
            ratingFilter: ratingFilter,
            sortBy: sortBy
        )
    }

    /// Derives the artist list from the filtered tracks (mirrors
    /// LibraryStore.getAllArtists but scoped to filtered results).
    private var filteredArtists: [String] {
        var artists = Set(filteredLibraryTracks.compactMap { $0.artist }.filter { !$0.isEmpty })
        if filteredLibraryTracks.contains(where: { $0.artist == nil || $0.artist?.isEmpty == true }) {
            artists.insert("Working Files")
        }
        return Array(artists).sorted()
    }

    /// Derives the album list for a given artist from the filtered tracks
    /// (mirrors LibraryStore.getAllAlbums but scoped to filtered results).
    private func filteredAlbums(for artist: String) -> [String] {
        let artistTracks: [Track]
        if artist == "Working Files" {
            artistTracks = filteredLibraryTracks.filter { $0.artist == nil || $0.artist?.isEmpty == true }
        } else {
            artistTracks = filteredLibraryTracks.filter { $0.artist == artist }
        }

        var albums = Set(artistTracks.compactMap { $0.album }.filter { !$0.isEmpty })
        if artistTracks.contains(where: { $0.album == nil || $0.album?.isEmpty == true }) {
            albums.insert("Unsorted")
        }
        return Array(albums).sorted()
    }

    var body: some View {
        HSplitView {
            // Column 1: Artists
            artistColumn
                .frame(minWidth: 250, idealWidth: 300)

            // Column 2: Albums
            if selectedArtist != nil {
                albumColumn
                    .frame(minWidth: 250, idealWidth: 350)
            }

            // Column 3: Tracks
            if selectedArtist != nil && selectedAlbum != nil {
                trackColumn
                    .frame(minWidth: 400)
            }
        }
        .onAppear {
            // Auto-select first artist if none selected
            if selectedArtist == nil, let firstArtist = filteredArtists.first {
                selectedArtist = firstArtist
                if let firstAlbum = filteredAlbums(for: firstArtist).first {
                    selectedAlbum = firstAlbum
                }
            }
        }
        .onChange(of: searchText) { revalidateSelection() }
        .onChange(of: filterType) { revalidateSelection() }
        .onChange(of: selectedFilterValue) { revalidateSelection() }
        .onChange(of: ratingFilter) { revalidateSelection() }
        .onChange(of: sortBy) { revalidateSelection() }
    }

    /// Re-validate artist/album selection when filters change so the UI
    /// does not display a stale selection that no longer exists in the
    /// filtered data set.
    private func revalidateSelection() {
        let artists = filteredArtists

        // If the currently selected artist is no longer in the filtered list,
        // fall back to the first available artist (or nil).
        if let current = selectedArtist, !artists.contains(current) {
            selectedArtist = artists.first
        }

        // Re-validate album within the (possibly new) artist
        if let artist = selectedArtist {
            let albums = filteredAlbums(for: artist)
            if let currentAlbum = selectedAlbum, !albums.contains(currentAlbum) {
                selectedAlbum = albums.first
            }
        } else {
            selectedAlbum = nil
        }
    }

    // MARK: - Artist Column
    private var artistColumn: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Artists")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Artist list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredArtists, id: \.self) { artist in
                        ArtistRowView(
                            artist: library.getArtistViewModel(name: artist),
                            isSelected: selectedArtist == artist,
                            onSelect: {
                                selectedArtist = artist
                                selectedAlbum = filteredAlbums(for: artist).first
                                focusedColumn = .albums
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Album Column
    private var albumColumn: some View {
        VStack(spacing: 0) {
            if let artist = selectedArtist {
                // Header
                HStack {
                    Text("Albums")
                        .font(.headline)
                    Spacer()
                }
                .padding()

                Divider()

                // Album list
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredAlbums(for: artist), id: \.self) { album in
                            AlbumRowView(
                                album: library.getAlbumViewModel(artist: artist, album: album),
                                isSelected: selectedAlbum == album,
                                onSelect: {
                                    selectedAlbum = album
                                    focusedColumn = .tracks
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Track Column
    private var trackColumn: some View {
        VStack(spacing: 0) {
            if let artist = selectedArtist, let album = selectedAlbum {
                trackColumnContent(artist: artist, album: album)
            }
        }
        .background(Color(.windowBackgroundColor))
    }

    @ViewBuilder
    private func trackColumnContent(artist: String, album: String) -> some View {
        // Header
        HStack {
            VStack(alignment: .leading) {
                Text(album)
                    .font(.headline)
                Text(artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()

        Divider()

        // Track list
        let tracks = getTracksForAlbum(artist: artist, album: album)

        if tracks.isEmpty {
            VStack {
                Spacer()
                Text("No tracks in this album")
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tracks) { track in
                        trackRowForBrowser(track: track, artist: artist, album: album, tracks: tracks)
                    }
                }
                .padding()
            }
        }
    }

    private func trackRowForBrowser(track: Track, artist: String, album: String, tracks: [Track]) -> some View {
        TrackRowView(
            track: track,
            albumArtwork: library.getAlbumViewModel(artist: artist, album: album).artworkURL,
            isPlaying: player.isPlaying && player.currentURL == track.audioURL,
            isSelected: selectedTrack?.id == track.id,
            isPublished: isTrackPublished(track.id),
            onSelect: {
                selectedTrack = track
            },
            onPlay: {
                playbackQueue.playTrack(track, from: tracks)
                selectedTrack = track
            },
            onPause: {
                player.pause()
            },
            onEdit: {
                trackToEdit = track
                showEditSheet = true
            },
            onExport: {
                onExportTrack(track)
            },
            onDelete: {
                library.removeTrack(track)
            },
            onRatingChange: { rating in
                library.setRating(track.id, rating: rating)
            },
            isAnalyzing: analyzingTrackId == track.id
        )
    }

    private func getTracksForAlbum(artist: String, album: String) -> [Track] {
        var tracks = filteredLibraryTracks.filter { track in
            let matchesArtist = artist == "Working Files"
                ? (track.artist == nil || track.artist?.isEmpty == true)
                : track.artist == artist

            let matchesAlbum = album == "Unsorted"
                ? (track.album == nil || track.album?.isEmpty == true)
                : track.album == album

            return matchesArtist && matchesAlbum
        }

        // Apply sort order
        switch sortBy {
        case .dateNewest:
            tracks.sort { $0.createdAt > $1.createdAt }
        case .dateOldest:
            tracks.sort { $0.createdAt < $1.createdAt }
        case .nameAZ:
            tracks.sort { $0.title.lowercased() < $1.title.lowercased() }
        case .nameZA:
            tracks.sort { $0.title.lowercased() > $1.title.lowercased() }
        case .ratingHigh:
            tracks.sort { $0.rating > $1.rating }
        case .ratingLow:
            tracks.sort { $0.rating < $1.rating }
        case .durationLong:
            tracks.sort { $0.duration > $1.duration }
        case .durationShort:
            tracks.sort { $0.duration < $1.duration }
        }

        return tracks
    }
}

// MARK: - Artist Row View

struct ArtistRowView: View {
    let artist: ArtistViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    var onChangePhoto: ((String) -> Void)? = nil

    @State private var isHovered = false
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 12) {
            // Artist photo (circular)
            ArtworkImageView(
                type: .artist(name: artist.name),
                imageURL: artist.photoURL,
                size: 40
            )

            // Artist info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if artist.hasCustomPhoto,
                       let photoURL = artist.photoURL,
                       let nsImage = ArtworkDecodeCache.image(at: photoURL) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 24, height: 24)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(Color.accentColor.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Text(String(artist.name.prefix(1)).uppercased())
                                    .font(.caption2)
                                    .fontWeight(.bold)
                            )
                    }

                    Text(artist.name)
                        .font(.body)
                        .fontWeight(isSelected ? .semibold : .regular)
                }

                Text("\(artist.trackCount) track(s) • \(artist.albumCount) album(s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.gray.opacity(0.05) : Color.clear))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isDropTarget ? 1 : 0)
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isDropTarget ? 0.1 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onDrop(of: [.text], isTargeted: $isDropTarget) { providers in
            handleDrop(providers: providers)
        }
        .contextMenu {
            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.jpeg, .png, .heic]
                panel.allowsMultipleSelection = false
                panel.message = "Choose a photo for \(artist.name)"
                if panel.runModal() == .OK, let url = panel.url {
                    onChangePhoto?(artist.name)
                    // The actual photo setting is done via the callback
                    // but we need the URL. Use a notification pattern instead.
                    NotificationCenter.default.post(
                        name: NSNotification.Name("SetArtistPhoto"),
                        object: nil,
                        userInfo: ["artist": artist.name, "url": url]
                    )
                }
            } label: {
                Label("Change Photo...", systemImage: "photo")
            }

            if artist.hasCustomPhoto {
                Button(role: .destructive) {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("SetArtistPhoto"),
                        object: nil,
                        userInfo: ["artist": artist.name]
                    )
                } label: {
                    Label("Remove Photo", systemImage: "trash")
                }
            }

            Divider()

            Button {
                NotificationCenter.default.post(
                    name: NSNotification.Name("RenameArtist"),
                    object: nil,
                    userInfo: ["artist": artist.name]
                )
            } label: {
                Label("Rename Artist...", systemImage: "pencil")
            }

            Button(role: .destructive) {
                NotificationCenter.default.post(
                    name: NSNotification.Name("DeleteArtist"),
                    object: nil,
                    userInfo: ["artist": artist.name]
                )
            } label: {
                Label("Delete Artist", systemImage: "trash")
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, _ in
                if let data = data as? Data, let trackIdString = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("MoveTrackToArtist"),
                            object: nil,
                            userInfo: ["trackId": trackIdString, "artist": artist.name]
                        )
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Album Row View

struct AlbumRowView: View {
    let album: AlbumViewModel
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 12) {
            // Album artwork (rounded square)
            ArtworkImageView(
                type: .album(artist: album.artistName, album: album.albumName),
                imageURL: album.artworkURL,
                size: 50
            )

            // Album info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if album.hasCustomArtwork,
                       let artworkURL = album.artworkURL,
                       let nsImage = ArtworkDecodeCache.image(at: artworkURL) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.caption2)
                            )
                    }

                    Text(album.albumName)
                        .font(.body)
                        .fontWeight(isSelected ? .semibold : .regular)
                }

                Text("\(album.trackCount) track(s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.gray.opacity(0.05) : Color.clear))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isDropTarget ? 1 : 0)
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isDropTarget ? 0.1 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onDrop(of: [.text], isTargeted: $isDropTarget) { providers in
            handleDrop(providers: providers)
        }
        .contextMenu {
            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.jpeg, .png, .heic]
                panel.allowsMultipleSelection = false
                panel.message = "Choose artwork for \(album.albumName)"
                if panel.runModal() == .OK, let url = panel.url {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("SetAlbumArtwork"),
                        object: nil,
                        userInfo: ["artist": album.artistName, "album": album.albumName, "url": url]
                    )
                }
            } label: {
                Label("Change Album Art...", systemImage: "photo")
            }

            if album.hasCustomArtwork {
                Button(role: .destructive) {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("SetAlbumArtwork"),
                        object: nil,
                        userInfo: ["artist": album.artistName, "album": album.albumName]
                    )
                } label: {
                    Label("Remove Album Art", systemImage: "trash")
                }
            }

            Divider()

            Button {
                NotificationCenter.default.post(
                    name: NSNotification.Name("RenameAlbum"),
                    object: nil,
                    userInfo: ["artist": album.artistName, "album": album.albumName]
                )
            } label: {
                Label("Rename Album...", systemImage: "pencil")
            }

            Button(role: .destructive) {
                NotificationCenter.default.post(
                    name: NSNotification.Name("DeleteAlbum"),
                    object: nil,
                    userInfo: ["artist": album.artistName, "album": album.albumName]
                )
            } label: {
                Label("Delete Album", systemImage: "trash")
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, _ in
                if let data = data as? Data, let trackIdString = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("MoveTrackToAlbum"),
                            object: nil,
                            userInfo: ["trackId": trackIdString, "artist": album.artistName, "album": album.albumName]
                        )
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Track Row View

struct TrackRowView: View {
    let track: Track
    let albumArtwork: URL?  // Shared album artwork
    let isPlaying: Bool
    let isSelected: Bool
    var isPublished: Bool = false
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    let onRatingChange: (Int) -> Void
    var isAnalyzing: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Album/track artwork
            ZStack {
                // Use custom track artwork if exists, else album artwork
                ArtworkImageView(
                    type: .track(id: track.id),
                    imageURL: track.customArtworkURL ?? albumArtwork,
                    size: 50
                )

                // Play/pause overlay on hover
                if isAnalyzing {
                    Color.black.opacity(0.4)
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if isHovered && !isPlaying {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
                } else if isPlaying {
                    Button(action: onPause) {
                        Image(systemName: "pause.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
                }
            }

            // Track info
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)

                HStack(spacing: 8) {
                    // Duration
                    Text(formatDuration(track.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // BPM
                    if let bpm = track.bpm {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text("\(Int(bpm)) BPM")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Rating
                    StarRatingView(rating: track.rating, isInteractive: true, onRatingChange: onRatingChange)
                        .scaleEffect(0.8)

                    // Published indicator
                    if isPublished {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .help("Published on majiks.online")
                    }
                }
            }

            Spacer()

            // Context menu - always visible, but more prominent when hovered
            Menu {
                Button("Edit Track...") { onEdit() }
                Button("Export...") { onExport() }

                Button {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("AnalyzeWithEngineer"),
                        object: nil,
                        userInfo: ["trackId": track.id]
                    )
                } label: {
                    Label("Analyze with Engineer", systemImage: "tuningfork")
                }

                Divider()
                Button("Delete", role: .destructive) { onDelete() }

                // Publishing actions
                if isPublished {
                    Divider()
                    Button {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("UpdatePublishedTrack"),
                            object: nil,
                            userInfo: ["trackId": track.id]
                        )
                    } label: {
                        Label("Update on majiks.online", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button(role: .destructive) {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("UnpublishTrack"),
                            object: nil,
                            userInfo: ["trackId": track.id]
                        )
                    } label: {
                        Label("Unpublish", systemImage: "icloud.slash")
                    }
                } else {
                    Divider()
                    Button {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("PublishTrack"),
                            object: nil,
                            userInfo: ["trackId": track.id]
                        )
                    } label: {
                        Label("Publish to majiks.online", systemImage: "icloud.and.arrow.up")
                    }
                    Button {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("StageForPublish"),
                            object: nil,
                            userInfo: ["trackId": track.id]
                        )
                    } label: {
                        Label("Add to Publish Queue", systemImage: "text.badge.plus")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(isHovered ? .primary : .secondary)
            }
            .menuStyle(.borderlessButton)
            .help("Track actions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.gray.opacity(0.1) : Color.clear))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click to edit
            onEdit()
        }
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onDrag {
            let provider = NSItemProvider(object: track.id.uuidString as NSString)
            provider.suggestedName = track.title
            if let nsURL = track.audioURL as NSURL? {
                provider.registerObject(nsURL, visibility: .all)
            }
            return provider
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
