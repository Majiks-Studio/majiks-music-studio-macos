import SwiftUI

// MARK: - Catalogue Section Models

struct CatalogueSection: Identifiable {
    let id: String
    let artistName: String
    let trackCount: Int
    let albums: [AlbumGroup]
}

struct AlbumGroup: Identifiable {
    let id: String
    let name: String
    let tracks: [CatalogueTrack]
    let variations: [String: [CatalogueTrack]]
}

enum CatalogueSortOrder: String, CaseIterable {
    case publishDate = "Date"
    case publishDateAsc = "Oldest"
    case title = "Title"
    case playCount = "Plays"
    case album = "Album"
}

enum CatalogueViewMode: String, CaseIterable {
    case list = "List"
    case grid = "Grid"
    case album = "Album"
    case stats = "Stats"

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        case .album: return "opticaldisc"
        case .stats: return "chart.bar"
        }
    }
}

enum CatalogueDateRange: String, CaseIterable {
    case allTime = "All Time"
    case thisMonth = "This Month"
    case thisWeek = "This Week"
    case today = "Today"
}

// MARK: - Catalogue View

struct CatalogueView: View {
    @EnvironmentObject var publisherStore: PublisherStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var backend: BackendViewModel

    @State private var editingCatalogueTrack: CatalogueTrack?
    @State private var trackToUnpublish: CatalogueTrack?
    @State private var catalogueArtistFilter: String?
    @State private var catalogueSortOrder: CatalogueSortOrder = .publishDate
    @State private var searchText: String = ""
    @State private var genreFilter: String?
    @State private var albumFilter: String?
    @State private var selectedTrackId: String?
    @State private var selectionMode = false
    @State private var selectedTrackIds: Set<String> = []
    @State private var showBatchUnpublishConfirm = false
    @State private var viewMode: CatalogueViewMode = .list
    @State private var dateRangeFilter: CatalogueDateRange = .allTime
    @State private var losslessOnly: Bool = false
    @State private var collapsedAlbums: Set<String> = []
    @FocusState private var isSearchFocused: Bool

    // Computed filtered tracks for search + genre filter
    private var filteredTracks: [CatalogueTrack] {
        var tracks = publisherStore.catalogueTracks

        // Text search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            tracks = tracks.filter {
                $0.title.lowercased().contains(query) ||
                $0.artist.lowercased().contains(query) ||
                $0.album.lowercased().contains(query) ||
                $0.genre.lowercased().contains(query)
            }
        }

        // Artist filter
        if let filter = catalogueArtistFilter {
            tracks = tracks.filter { $0.artistProfileId == filter }
        }

        // Genre filter
        if let genre = genreFilter {
            tracks = tracks.filter { $0.genre.lowercased() == genre.lowercased() }
        }

        // Album filter
        if let album = albumFilter {
            tracks = tracks.filter { $0.album.lowercased() == album.lowercased() }
        }

        // Date range filter
        if dateRangeFilter != .allTime {
            let calendar = Calendar.current
            let now = Date()
            let cutoff: Date
            switch dateRangeFilter {
            case .allTime:
                cutoff = .distantPast
            case .thisMonth:
                cutoff = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            case .thisWeek:
                cutoff = calendar.date(byAdding: .weekOfYear, value: -1, to: now) ?? now
            case .today:
                cutoff = calendar.startOfDay(for: now)
            }
            tracks = tracks.filter { ($0.publishedAt ?? .distantPast) >= cutoff }
        }

        // Lossless filter
        if losslessOnly {
            tracks = tracks.filter { $0.hasLossless }
        }

        return tracks
    }

    private var availableAlbums: [String] {
        let albums = Set(publisherStore.catalogueTracks.compactMap {
            $0.album.isEmpty ? nil : $0.album
        })
        return albums.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var availableGenres: [String] {
        let genres = Set(publisherStore.catalogueTracks.compactMap {
            $0.genre.isEmpty ? nil : $0.genre
        })
        return genres.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            catalogueToolbar
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            if publisherStore.catalogueTracks.isEmpty {
                catalogueEmptyState
            } else {
                HSplitView {
                    Group {
                        switch viewMode {
                        case .list:
                            catalogueList
                        case .grid:
                            catalogueGridView
                        case .album:
                            catalogueAlbumView
                        case .stats:
                            catalogueStatsView
                        }
                    }
                    .frame(minWidth: 400)

                    // Detail panel
                    if let trackId = selectedTrackId,
                       let track = publisherStore.catalogueTracks.first(where: { $0.trackId == trackId }) {
                        CatalogueDetailPanel(
                            track: track,
                            importState: publisherStore.importStates[track.trackId],
                            profileName: publisherStore.artistProfiles.first(where: { $0.id == track.artistProfileId })?.artistName
                        ) {
                            editingCatalogueTrack = track
                        } onOpen: {
                            let urlStr = track.pageUrl.isEmpty
                                ? "https://majiks.online/track/\(track.trackSlug)"
                                : track.pageUrl
                            if let url = URL(string: urlStr) {
                                NSWorkspace.shared.open(url)
                            }
                        } onUnpublish: {
                            trackToUnpublish = track
                        }
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                    }
                }
            }
        }
        .onAppear {
            if publisherStore.catalogueState == .idle {
                Task {
                    await publisherStore.fetchCatalogue(backend: backend, library: library)
                    if !publisherStore.profilesLoaded {
                        await publisherStore.fetchArtistProfiles(backend: backend)
                    }
                }
            }
        }
        .sheet(item: $editingCatalogueTrack) { track in
            CatalogueEditSheet(track: track) { updated in
                Task { await publisherStore.updateCatalogueTrack(updated, backend: backend) }
            }
        }
        .alert("Unpublish Track", isPresented: Binding(
            get: { trackToUnpublish != nil },
            set: { if !$0 { trackToUnpublish = nil } }
        )) {
            Button("Cancel", role: .cancel) { trackToUnpublish = nil }
            Button("Unpublish", role: .destructive) {
                if let track = trackToUnpublish {
                    Task { await publisherStore.unpublishCatalogueTrack(track, backend: backend) }
                }
                trackToUnpublish = nil
            }
        } message: {
            if let track = trackToUnpublish {
                Text("Are you sure you want to unpublish \"\(track.title)\"? This will remove it from majiks.online.")
            }
        }
        .alert("Unpublish \(selectedTrackIds.count) Tracks?", isPresented: $showBatchUnpublishConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Unpublish All", role: .destructive) {
                let ids = selectedTrackIds
                Task {
                    for id in ids {
                        if let track = publisherStore.catalogueTracks.first(where: { $0.trackId == id }) {
                            await publisherStore.unpublishCatalogueTrack(track, backend: backend)
                        }
                    }
                    selectedTrackIds.removeAll()
                    selectionMode = false
                }
            }
        } message: {
            Text("This will remove \(selectedTrackIds.count) tracks from majiks.online. This cannot be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FocusCatalogueSearch"))) { _ in
            isSearchFocused = true
        }
    }

    // MARK: - Catalogue Toolbar

    private var catalogueToolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    Task { await publisherStore.fetchCatalogue(backend: backend, library: library) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(publisherStore.catalogueState == .loading)
                .help("Refresh catalogue from server")

                // Search field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search catalogue...", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
                .frame(maxWidth: 220)

                if publisherStore.artistProfiles.count > 1 {
                    Picker("Artist", selection: $catalogueArtistFilter) {
                        Text("All Artists").tag(String?.none)
                        ForEach(publisherStore.artistProfiles) { profile in
                            Text(profile.artistName).tag(Optional(profile.id))
                        }
                    }
                    .frame(maxWidth: 160)
                    .help("Filter catalogue by artist profile")
                }

                if !availableGenres.isEmpty {
                    Picker("Genre", selection: $genreFilter) {
                        Text("All Genres").tag(String?.none)
                        ForEach(availableGenres, id: \.self) { genre in
                            Text(genre).tag(Optional(genre))
                        }
                    }
                    .frame(maxWidth: 140)
                    .help("Filter catalogue by genre")
                }

                if !availableAlbums.isEmpty {
                    Picker("Album", selection: $albumFilter) {
                        Text("All Albums").tag(String?.none)
                        ForEach(availableAlbums, id: \.self) { album in
                            Text(album).tag(Optional(album))
                        }
                    }
                    .frame(maxWidth: 160)
                    .help("Filter catalogue by album")
                }

                Picker("Sort", selection: $catalogueSortOrder) {
                    ForEach(CatalogueSortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .frame(maxWidth: 100)
                .help("Sort catalogue tracks")

                Picker("Date", selection: $dateRangeFilter) {
                    ForEach(CatalogueDateRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .frame(maxWidth: 120)
                .help("Filter by publish date range")

                Toggle(isOn: $losslessOnly) {
                    Image(systemName: "waveform")
                }
                .toggleStyle(.button)
                .help("Show only tracks with lossless audio")

                // View mode toggle
                Picker("View", selection: $viewMode) {
                    ForEach(CatalogueViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)
                .help("Switch between list, grid, album, and stats views")

                Spacer()

                // Selection mode toggle
                Toggle(isOn: $selectionMode) {
                    Image(systemName: "checkmark.circle")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Selection mode")
                .accessibilityValue(selectionMode ? "On" : "Off")
                .help("Toggle selection mode for batch operations")
                .onChange(of: selectionMode) { _, newValue in
                    if !newValue { selectedTrackIds.removeAll() }
                }

                // Status
                switch publisherStore.catalogueState {
                case .idle:
                    Text("Not loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .loaded(let totalCount):
                    let showing = filteredTracks.count
                    if showing < totalCount {
                        Text("\(showing)/\(totalCount) shown")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(totalCount) track\(totalCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            // Batch actions bar
            if selectionMode && !selectedTrackIds.isEmpty {
                HStack(spacing: 12) {
                    Text("\(selectedTrackIds.count) selected")
                        .font(.caption)
                        .fontWeight(.medium)

                    Button("Select All") {
                        selectedTrackIds = Set(filteredTracks.map(\.trackId))
                    }
                    .controlSize(.small)
                    .help("Select all visible tracks")

                    Button("Deselect All") {
                        selectedTrackIds.removeAll()
                    }
                    .controlSize(.small)
                    .help("Deselect all tracks")

                    Spacer()

                    Button {
                        let ids = selectedTrackIds
                        let tracks = publisherStore.catalogueTracks.filter { ids.contains($0.trackId) }
                        for track in tracks {
                            Task { await publisherStore.importCatalogueTrack(track, backend: backend, library: library) }
                        }
                    } label: {
                        Label("Import Selected", systemImage: "arrow.down.circle")
                    }
                    .controlSize(.small)
                    .help("Import selected tracks to library")

                    Button(role: .destructive) {
                        showBatchUnpublishConfirm = true
                    } label: {
                        Label("Unpublish Selected", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .help("Unpublish selected tracks")
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Catalogue Sections

    private var catalogueSections: [CatalogueSection] {
        var tracks = filteredTracks

        // Sort
        switch catalogueSortOrder {
        case .publishDate:
            tracks.sort { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        case .publishDateAsc:
            tracks.sort { ($0.publishedAt ?? .distantFuture) < ($1.publishedAt ?? .distantFuture) }
        case .title:
            tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .playCount:
            tracks.sort { $0.playCount > $1.playCount }
        case .album:
            tracks.sort {
                let cmp = $0.album.localizedCaseInsensitiveCompare($1.album)
                if cmp == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return cmp == .orderedAscending
            }
        }

        // Group by artist profile (or artist name if no profile)
        let grouped = Dictionary(grouping: tracks) { track -> String in
            track.artistProfileId ?? track.artist
        }

        return grouped.map { key, artistTracks in
            let artistName = publisherStore.artistProfiles.first(where: { $0.id == key })?.artistName
                ?? artistTracks.first?.artist ?? key

            // Separate parent tracks from variations
            let withoutParent = artistTracks.filter { $0.parentTrackId == nil }
            let withParent = artistTracks.filter { $0.parentTrackId != nil }
            let withoutParentIds = Set(withoutParent.map { $0.trackId })

            // Only link variations whose parent exists in this group
            let linkedVariations = withParent.filter { withoutParentIds.contains($0.parentTrackId!) }
            let orphanVariations = withParent.filter { !withoutParentIds.contains($0.parentTrackId!) }
            let variationMap = Dictionary(grouping: linkedVariations) { $0.parentTrackId! }

            // Main tracks = parent tracks + orphan variations
            let mainTracks = withoutParent + orphanVariations

            // Group main tracks by album
            let albumGrouped = Dictionary(grouping: mainTracks) {
                $0.album.isEmpty ? "" : $0.album
            }

            let albums = albumGrouped.keys.sorted { a, b in
                if a.isEmpty { return false }
                if b.isEmpty { return true }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }.map { albumName in
                AlbumGroup(
                    id: albumName.isEmpty ? "\(key)-uncategorized" : "\(key)-\(albumName)",
                    name: albumName.isEmpty ? "Singles" : albumName,
                    tracks: albumGrouped[albumName] ?? [],
                    variations: variationMap
                )
            }

            return CatalogueSection(
                id: key,
                artistName: artistName,
                trackCount: artistTracks.count,
                albums: albums
            )
        }.sorted { $0.trackCount > $1.trackCount }
    }

    private var catalogueEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            if publisherStore.catalogueState == .loading {
                Text("Loading catalogue...")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                Text("No published tracks")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Once you publish tracks, they'll appear here for management")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 300)
                Button("Load Catalogue") {
                    Task { await publisherStore.fetchCatalogue(backend: backend, library: library) }
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
    }

    private var catalogueList: some View {
        let sections = catalogueSections
        return List(selection: $selectedTrackId) {
            ForEach(sections) { section in
                DisclosureGroup {
                    ForEach(section.albums) { album in
                        if section.albums.count == 1 && album.name == "Singles" {
                            catalogueAlbumContent(album)
                        } else {
                            DisclosureGroup {
                                catalogueAlbumContent(album)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: album.name == "Singles" ? "music.note" : "opticaldisc")
                                        .foregroundStyle(.secondary)
                                    Text(album.name)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    let count = album.tracks.count + album.tracks.reduce(0) {
                                        $0 + (album.variations[$1.trackId]?.count ?? 0)
                                    }
                                    Text("\(count)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.blue)
                        Text(section.artistName)
                            .font(.headline)
                        Text("\(section.trackCount) track\(section.trackCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Grid View

    private var sortedFilteredTracks: [CatalogueTrack] {
        var tracks = filteredTracks
        switch catalogueSortOrder {
        case .publishDate:
            tracks.sort { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        case .publishDateAsc:
            tracks.sort { ($0.publishedAt ?? .distantFuture) < ($1.publishedAt ?? .distantFuture) }
        case .title:
            tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .playCount:
            tracks.sort { $0.playCount > $1.playCount }
        case .album:
            tracks.sort {
                let cmp = $0.album.localizedCaseInsensitiveCompare($1.album)
                if cmp == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return cmp == .orderedAscending
            }
        }
        return tracks
    }

    private var catalogueGridView: some View {
        ScrollView {
            let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)]
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(sortedFilteredTracks) { track in
                    CatalogueGridCard(
                        track: track,
                        isSelected: selectedTrackId == track.trackId,
                        onEdit: { editingCatalogueTrack = track },
                        onOpen: {
                            let urlStr = track.pageUrl.isEmpty
                                ? "https://majiks.online/track/\(track.trackSlug)"
                                : track.pageUrl
                            if let url = URL(string: urlStr) {
                                NSWorkspace.shared.open(url)
                            }
                        },
                        onCopyLink: {
                            let urlStr = track.pageUrl.isEmpty
                                ? "https://majiks.online/track/\(track.trackSlug)"
                                : track.pageUrl
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(urlStr, forType: .string)
                        },
                        onUnpublish: { trackToUnpublish = track }
                    )
                    .onTapGesture { selectedTrackId = track.trackId }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Album View

    private var catalogueAlbumView: some View {
        let albumGroups = groupTracksByAlbum(sortedFilteredTracks)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(albumGroups, id: \.name) { group in
                    let albumId = group.name.isEmpty ? "__singles__" : group.name
                    let isCollapsed = collapsedAlbums.contains(albumId)
                    let totalPlays = group.tracks.reduce(0) { $0 + $1.playCount }
                    let firstGenre = group.tracks.first(where: { !$0.genre.isEmpty })?.genre
                    let publishDates = group.tracks.compactMap(\.publishedAt).sorted()

                    VStack(alignment: .leading, spacing: 8) {
                        // Album header
                        HStack(spacing: 12) {
                            if let firstTrack = group.tracks.first {
                                CatalogueArtworkView(
                                    trackId: firstTrack.trackId,
                                    artworkUrl: firstTrack.artworkUrl,
                                    size: 80,
                                    thumbUrl: firstTrack.artworkThumbUrl
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.name.isEmpty ? "Singles" : group.name)
                                    .font(.title3)
                                    .fontWeight(.semibold)

                                HStack(spacing: 8) {
                                    Text("\(group.tracks.count) track\(group.tracks.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    if totalPlays > 0 {
                                        HStack(spacing: 3) {
                                            Image(systemName: "play.fill")
                                                .font(.system(size: 8))
                                            Text("\(totalPlays)")
                                                .font(.caption)
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                }

                                HStack(spacing: 8) {
                                    if let genre = firstGenre {
                                        Text(genre)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(.secondary.opacity(0.15))
                                            .clipShape(Capsule())
                                    }

                                    if let earliest = publishDates.first {
                                        let dateStr = CatalogueAlbumTrackRow.shortDateFormatter.string(from: earliest)
                                        if let latest = publishDates.last, !Calendar.current.isDate(earliest, inSameDayAs: latest) {
                                            let lateDateStr = CatalogueAlbumTrackRow.shortDateFormatter.string(from: latest)
                                            Text("\(dateStr) - \(lateDateStr)")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        } else {
                                            Text(dateStr)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            Spacer()

                            // Collapse toggle
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if isCollapsed {
                                        collapsedAlbums.remove(albumId)
                                    } else {
                                        collapsedAlbums.insert(albumId)
                                    }
                                }
                            } label: {
                                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(isCollapsed ? "Expand album" : "Collapse album")
                        }
                        .padding(.horizontal, 16)

                        // Track rows in this album (collapsible)
                        if !isCollapsed {
                            ForEach(group.tracks) { track in
                                CatalogueAlbumTrackRow(
                                    track: track,
                                    isSelected: selectedTrackId == track.trackId,
                                    onEdit: { editingCatalogueTrack = track },
                                    onOpen: {
                                        let urlStr = track.pageUrl.isEmpty
                                            ? "https://majiks.online/track/\(track.trackSlug)"
                                            : track.pageUrl
                                        if let url = URL(string: urlStr) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    },
                                    onCopyLink: {
                                        let urlStr = track.pageUrl.isEmpty
                                            ? "https://majiks.online/track/\(track.trackSlug)"
                                            : track.pageUrl
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(urlStr, forType: .string)
                                    },
                                    onUnpublish: { trackToUnpublish = track }
                                )
                                .onTapGesture { selectedTrackId = track.trackId }
                            }
                        }

                        Divider()
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 16)
        }
    }

    private struct AlbumViewGroup {
        let name: String
        let tracks: [CatalogueTrack]
    }

    private func groupTracksByAlbum(_ tracks: [CatalogueTrack]) -> [AlbumViewGroup] {
        let grouped = Dictionary(grouping: tracks) { $0.album }
        return grouped.keys.sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }.map { key in
            AlbumViewGroup(name: key, tracks: grouped[key] ?? [])
        }
    }

    // MARK: - Stats View

    private var catalogueStatsView: some View {
        let tracks = sortedFilteredTracks
        let totalPlays = tracks.reduce(0) { $0 + $1.playCount }
        let totalDuration = tracks.reduce(0.0) { $0 + $1.duration }
        let avgDuration = tracks.isEmpty ? 0.0 : totalDuration / Double(tracks.count)

        // Top tracks by play count
        let topTracks = Array(tracks.sorted { $0.playCount > $1.playCount }.prefix(20))

        // Genre breakdown
        let genreCounts: [(String, Int)] = {
            var counts: [String: Int] = [:]
            for t in tracks {
                let g = t.genre.isEmpty ? "Unknown" : t.genre
                counts[g, default: 0] += 1
            }
            return counts.sorted { $0.value > $1.value }
        }()
        let maxGenreCount = genreCounts.first?.1 ?? 1

        // Publishing timeline (tracks per month)
        let monthlyPublishing: [(String, Int)] = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM yyyy"
            var counts: [String: Int] = [:]
            var order: [String] = []
            for t in tracks {
                guard let date = t.publishedAt else { continue }
                let key = formatter.string(from: date)
                if counts[key] == nil { order.append(key) }
                counts[key, default: 0] += 1
            }
            return order.map { ($0, counts[$0] ?? 0) }
        }()
        let maxMonthlyCount = monthlyPublishing.map(\.1).max() ?? 1

        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Totals row
                HStack(spacing: 0) {
                    statsCard(title: "Total Tracks", value: "\(tracks.count)", icon: "music.note.list")
                    statsCard(title: "Total Plays", value: "\(totalPlays)", icon: "play.fill")
                    statsCard(
                        title: "Avg Duration",
                        value: String(format: "%d:%02d", Int(avgDuration) / 60, Int(avgDuration) % 60),
                        icon: "clock"
                    )
                    statsCard(
                        title: "Total Duration",
                        value: {
                            let hours = Int(totalDuration) / 3600
                            let mins = (Int(totalDuration) % 3600) / 60
                            return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
                        }(),
                        icon: "timer"
                    )
                }

                // Top Tracks
                if !topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Top Tracks")
                        ForEach(Array(topTracks.enumerated()), id: \.element.trackId) { index, track in
                            HStack(spacing: 10) {
                                Text("#\(index + 1)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .trailing)

                                CatalogueArtworkView(
                                    trackId: track.trackId,
                                    artworkUrl: track.artworkUrl,
                                    size: 32,
                                    thumbUrl: track.artworkThumbUrl
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                HStack(spacing: 3) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 8))
                                    Text("\(track.playCount)")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedTrackId = track.trackId }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Genre breakdown
                if !genreCounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Genre Breakdown")
                        ForEach(genreCounts, id: \.0) { genre, count in
                            HStack(spacing: 8) {
                                Text(genre)
                                    .font(.caption)
                                    .frame(width: 100, alignment: .trailing)

                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor.opacity(0.7))
                                        .frame(width: max(4, geo.size.width * CGFloat(count) / CGFloat(maxGenreCount)))
                                }
                                .frame(height: 16)

                                Text("\(count)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Publishing timeline
                if !monthlyPublishing.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Publishing Timeline")
                        ForEach(monthlyPublishing, id: \.0) { month, count in
                            HStack(spacing: 8) {
                                Text(month)
                                    .font(.caption)
                                    .frame(width: 80, alignment: .trailing)

                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.green.opacity(0.7))
                                        .frame(width: max(4, geo.size.width * CGFloat(count) / CGFloat(maxMonthlyCount)))
                                }
                                .frame(height: 16)

                                Text("\(count)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(16)
        }
    }

    private func statsCard(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func catalogueAlbumContent(_ album: AlbumGroup) -> some View {
        ForEach(album.tracks) { track in
            catalogueTrackRow(track)
            if let variations = album.variations[track.trackId] {
                ForEach(variations) { variant in
                    catalogueTrackRow(variant)
                        .padding(.leading, 24)
                }
            }
        }
    }

    private func catalogueTrackRow(_ track: CatalogueTrack) -> some View {
        HStack(spacing: 0) {
            if selectionMode {
                Toggle(isOn: Binding(
                    get: { selectedTrackIds.contains(track.trackId) },
                    set: { isSelected in
                        if isSelected { selectedTrackIds.insert(track.trackId) }
                        else { selectedTrackIds.remove(track.trackId) }
                    }
                )) { }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Select \(track.title)")
                .padding(.trailing, 8)
            }

            CatalogueRow(
                track: track,
                profileName: publisherStore.artistProfiles.first(where: { $0.id == track.artistProfileId })?.artistName,
                importState: publisherStore.importStates[track.trackId],
                fetchProvenance: { trackId in
                    try await backend.fetchProvenance(trackId: trackId)
                }
            ) {
                editingCatalogueTrack = track
            } onOpen: {
                let urlStr = track.pageUrl.isEmpty
                    ? "https://majiks.online/track/\(track.trackSlug)"
                    : track.pageUrl
                if let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }
            } onUnpublish: {
                trackToUnpublish = track
            } onImport: {
                Task { await publisherStore.importCatalogueTrack(track, backend: backend, library: library) }
            } onUpdateMetadata: { localTrackId in
                publisherStore.updateLocalMetadataFromCatalogue(track, localTrackId: localTrackId, library: library)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTrackId = track.trackId
        }
    }
}

// MARK: - Catalogue Detail Panel

struct CatalogueDetailPanel: View {
    let track: CatalogueTrack
    let importState: CatalogueImportState?
    let profileName: String?
    let onEdit: () -> Void
    let onOpen: () -> Void
    let onUnpublish: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Large artwork
                CatalogueArtworkView(trackId: track.trackId, artworkUrl: track.artworkUrl, size: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                    .accessibilityLabel("Artwork for \(track.title)")

                // Title + Artist
                VStack(spacing: 4) {
                    Text(track.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)

                    if let profileName, !profileName.isEmpty {
                        Text(profileName)
                            .font(.body)
                            .foregroundStyle(.blue)
                    } else if !track.artist.isEmpty {
                        Text(track.artist)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    if !track.album.isEmpty {
                        Text(track.album)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                // Metadata
                VStack(alignment: .leading, spacing: 8) {
                    if !track.genre.isEmpty {
                        detailRow("Genre", track.genre)
                    }
                    if !track.subgenre.isEmpty {
                        detailRow("Subgenre", track.subgenre)
                    }
                    if !track.bpm.isEmpty {
                        detailRow("BPM", track.bpm)
                    }
                    if !track.musicalKey.isEmpty {
                        detailRow("Key", track.musicalKey)
                    }
                    if track.duration > 0 {
                        let mins = Int(track.duration) / 60
                        let secs = Int(track.duration) % 60
                        detailRow("Duration", String(format: "%d:%02d", mins, secs))
                    }
                    if !track.mood.isEmpty {
                        detailRow("Mood", track.mood)
                    }
                    if !track.language.isEmpty {
                        detailRow("Language", track.language)
                    }
                    if track.isExplicit {
                        detailRow("Content", "Explicit")
                    }
                }

                Divider()

                // Stats
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Stats")

                    detailRow("Plays", "\(track.playCount)")
                    if track.rating > 0 {
                        detailRow("Rating", String(format: "%.1f", track.rating))
                    }
                    if let date = track.publishedAt {
                        detailRow("Published", Self.dateFormatter.string(from: date))
                    }
                    if track.hasLossless {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                            Text("Lossless available")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }

                Divider()

                // Actions
                VStack(spacing: 8) {
                    Button { onEdit() } label: {
                        Label("Edit Metadata", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Edit this track's metadata on the server")

                    Button { onOpen() } label: {
                        Label("View on majiks.online", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Open this track's page in your browser")

                    Button {
                        let urlStr = track.pageUrl.isEmpty
                            ? "https://majiks.online/track/\(track.trackSlug)"
                            : track.pageUrl
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(urlStr, forType: .string)
                    } label: {
                        Label("Copy Link", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Copy the track's shareable link to clipboard")

                    Button(role: .destructive) { onUnpublish() } label: {
                        Label("Unpublish", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .help("Remove this track from majiks.online")
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
    }
}

// MARK: - Catalogue Artwork View

struct CatalogueArtworkView: View {
    let trackId: String
    let artworkUrl: String
    let size: CGFloat
    var thumbUrl: String = ""

    @State private var image: NSImage?

    private var cacheURL: URL {
        let prefix = thumbUrl.isEmpty ? "catalogue-" : "catalogue-thumb-"
        return FileStore.shared.artworkDirectory.appendingPathComponent("\(prefix)\(trackId).jpg")
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                AlbumArtGenerator.generate(for: trackId, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear { loadArtwork() }
    }

    private func loadArtwork() {
        // Check cache first
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let cached = ArtworkDecodeCache.image(at: cacheURL) {
            image = cached
            return
        }

        // Download if URL is available (prefer thumbnail for list rows)
        let downloadUrl = thumbUrl.isEmpty ? artworkUrl : thumbUrl
        guard !downloadUrl.isEmpty, let url = URL(string: downloadUrl) else { return }

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                      let nsImg = NSImage(data: data) else { return }

                // Cache to disk
                try? data.write(to: cacheURL)

                await MainActor.run { image = nsImg }
            } catch {
                // Silently fall back to procedural art
            }
        }
    }
}

// MARK: - Catalogue Row

struct CatalogueRow: View {
    let track: CatalogueTrack
    let profileName: String?
    let importState: CatalogueImportState?
    let fetchProvenance: (String) async throws -> ProvenanceCertificate?
    let onEdit: () -> Void
    let onOpen: () -> Void
    let onUnpublish: () -> Void
    let onImport: () -> Void
    let onUpdateMetadata: (UUID) -> Void

    @EnvironmentObject private var player: AudioPlayer
    @State private var showProvenance = false
    @State private var certificate: ProvenanceCertificate?
    @State private var isLoadingCert = false
    @State private var isStreaming = false

    private var isPlayingThis: Bool {
        guard let url = player.currentURL else { return false }
        return player.isPlaying && url.lastPathComponent == "catalogue-\(track.trackId).m4a"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        HStack(spacing: 14) {
            // Play/Pause button for catalogue streaming
            if !track.audioUrl.isEmpty {
                Button(action: { Task { await toggleCataloguePlayback() } }) {
                    if isStreaming {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isPlayingThis ? .orange : .blue)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isStreaming ? "Loading \(track.title)" : (isPlayingThis ? "Pause \(track.title)" : "Play \(track.title)"))
                .help(isPlayingThis ? "Pause" : "Play preview")
                .disabled(isStreaming)
            }

            // Artwork thumbnail — larger for better visibility
            CatalogueArtworkView(trackId: track.trackId, artworkUrl: track.artworkUrl, size: 56, thumbUrl: track.artworkThumbUrl)
                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)

            // Track info — two-line layout with richer metadata
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let profileName, !profileName.isEmpty {
                        Label(profileName, systemImage: "person.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else if !track.artist.isEmpty {
                        Label(track.artist, systemImage: "person.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !track.genre.isEmpty {
                        Text(track.genre)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 10) {
                    if !track.bpm.isEmpty {
                        Label("\(track.bpm)", systemImage: "metronome")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !track.musicalKey.isEmpty {
                        Label(track.musicalKey, systemImage: "music.note")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if track.duration > 0 {
                        let mins = Int(track.duration) / 60
                        let secs = Int(track.duration) % 60
                        Label(String(format: "%d:%02d", mins, secs), systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Play count
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                    Text("\(track.playCount)")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)

                // Published date
                if let date = track.publishedAt {
                    Text(Self.dateFormatter.string(from: date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Import button
            importButton

            // Actions menu — cleaner than a row of icons
            Menu {
                Button { onEdit() } label: {
                    Label("Edit Metadata", systemImage: "pencil")
                }
                Button { onOpen() } label: {
                    Label("Open on majiks.online", systemImage: "safari")
                }
                Button {
                    showProvenance = true
                    if certificate == nil {
                        isLoadingCert = true
                        Task {
                            do {
                                certificate = try await fetchProvenance(track.trackId)
                            } catch {
                                AppLog.error("Failed to fetch provenance: \(error)")
                            }
                            isLoadingCert = false
                        }
                    }
                } label: {
                    Label("Provenance Certificate", systemImage: "shield.checkered")
                }

                Divider()

                Button {
                    let urlStr = track.pageUrl.isEmpty
                        ? "https://majiks.online/track/\(track.trackSlug)"
                        : track.pageUrl
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlStr, forType: .string)
                } label: {
                    Label("Copy Link", systemImage: "link")
                }

                Button { } label: {
                    Label("Share to ACE Music (Coming Soon)", systemImage: "music.note.house")
                }
                .disabled(true)

                Divider()

                Button(role: .destructive) { onUnpublish() } label: {
                    Label("Unpublish", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .accessibilityLabel("Actions for \(track.title)")
            .popover(isPresented: $showProvenance) {
                ProvenancePopover(track: track, certificate: certificate, isLoading: isLoadingCert)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var importButton: some View {
        switch importState {
        case .none, .idle:
            Button { onImport() } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Import \(track.title) to library")
            .help("Import to Library")

        case .downloading, .converting, .importing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Importing \(track.title)")
                .help("Importing...")

        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("\(track.title) imported")
                .help("Imported to library")

        case .failed(let message):
            Button { onImport() } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Retry import of \(track.title)")
            .help("Import failed: \(message). Click to retry.")

        case .alreadyExists(let localTrackId, let metadataDiffers):
            if metadataDiffers {
                Button { onUpdateMetadata(localTrackId) } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Update \(track.title) metadata from server")
                .help("Update local metadata from server")
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(track.title) already in library")
                    .help("Already in library")
            }
        }
    }

    private func toggleCataloguePlayback() async {
        if isPlayingThis {
            player.pause()
            return
        }

        guard let url = URL(string: track.audioUrl) else { return }
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-\(track.trackId).m4a")

        // Download to temp file if not cached
        if !FileManager.default.fileExists(atPath: tempFile.path) {
            isStreaming = true
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: tempFile)
            } catch {
                AppLog.error("[CatalogueRow] Stream download failed: \(error)")
                isStreaming = false
                return
            }
            isStreaming = false
        }

        player.load(url: tempFile)
        player.nowPlaying = NowPlayingInfo(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            artworkURL: nil
        )
        player.play()
    }
}

// MARK: - Catalogue Grid Card

struct CatalogueGridCard: View {
    let track: CatalogueTrack
    let isSelected: Bool
    var onEdit: () -> Void = {}
    var onOpen: () -> Void = {}
    var onCopyLink: () -> Void = {}
    var onUnpublish: () -> Void = {}

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomLeading) {
                    CatalogueArtworkView(
                        trackId: track.trackId,
                        artworkUrl: track.artworkUrl,
                        size: 180,
                        thumbUrl: track.artworkThumbUrl
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)

                    // Play count + duration overlay
                    HStack(spacing: 6) {
                        if track.playCount > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 7))
                                Text("\(track.playCount)")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        if track.duration > 0 {
                            let mins = Int(track.duration) / 60
                            let secs = Int(track.duration) % 60
                            Text(String(format: "%d:%02d", mins, secs))
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .padding(6)
                }

                // Publish status indicator
                Circle()
                    .fill(track.publishedAt != nil ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                    .padding(6)
            }

            VStack(spacing: 3) {
                Text(track.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(track.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Genre chip
                if !track.genre.isEmpty {
                    Text(track.genre)
                        .font(.system(size: 9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                // BPM + Key row
                if !track.bpm.isEmpty || !track.musicalKey.isEmpty {
                    HStack(spacing: 6) {
                        if !track.bpm.isEmpty {
                            Label(track.bpm, systemImage: "metronome")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        if !track.musicalKey.isEmpty {
                            Label(track.musicalKey, systemImage: "music.note")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .frame(width: 180)
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button { onEdit() } label: {
                Label("Edit Metadata", systemImage: "pencil")
            }
            Button { onOpen() } label: {
                Label("Open on majiks.online", systemImage: "safari")
            }
            Button { onCopyLink() } label: {
                Label("Copy Link", systemImage: "link")
            }
            Button { } label: {
                Label("Share to ACE Music (Coming Soon)", systemImage: "music.note.house")
            }
            .disabled(true)
            Divider()
            Button(role: .destructive) { onUnpublish() } label: {
                Label("Unpublish", systemImage: "trash")
            }
        }
    }
}

// MARK: - Catalogue Album Track Row

struct CatalogueAlbumTrackRow: View {
    let track: CatalogueTrack
    let isSelected: Bool
    var onEdit: () -> Void = {}
    var onOpen: () -> Void = {}
    var onCopyLink: () -> Void = {}
    var onUnpublish: () -> Void = {}

    @EnvironmentObject private var player: AudioPlayer
    @State private var isStreaming = false

    private var isPlayingThis: Bool {
        guard let url = player.currentURL else { return false }
        return player.isPlaying && url.lastPathComponent == "catalogue-\(track.trackId).m4a"
    }

    static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            // Play/Pause button for catalogue streaming
            if !track.audioUrl.isEmpty {
                Button(action: { Task { await toggleAlbumTrackPlayback() } }) {
                    if isStreaming {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle.fill")
                            .font(.body)
                            .foregroundStyle(isPlayingThis ? .orange : .blue)
                    }
                }
                .buttonStyle(.plain)
                .help(isPlayingThis ? "Pause" : "Play preview")
                .disabled(isStreaming)
            }

            // Small artwork thumbnail
            CatalogueArtworkView(
                trackId: track.trackId,
                artworkUrl: track.artworkUrl,
                size: 36,
                thumbUrl: track.artworkThumbUrl
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Publish status dot
            Circle()
                .fill(track.publishedAt != nil ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !track.genre.isEmpty {
                        Text(track.genre)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    if track.duration > 0 {
                        let mins = Int(track.duration) / 60
                        let secs = Int(track.duration) % 60
                        Text(String(format: "%d:%02d", mins, secs))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !track.bpm.isEmpty {
                        Label(track.bpm, systemImage: "metronome")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !track.musicalKey.isEmpty {
                        Label(track.musicalKey, systemImage: "music.note")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Published date
            if let date = track.publishedAt {
                Text(Self.shortDateFormatter.string(from: date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Play count
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                Text("\(track.playCount)")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button { onEdit() } label: {
                Label("Edit Metadata", systemImage: "pencil")
            }
            Button { onOpen() } label: {
                Label("Open on majiks.online", systemImage: "safari")
            }
            Button { onCopyLink() } label: {
                Label("Copy Link", systemImage: "link")
            }
            Button { } label: {
                Label("Share to ACE Music (Coming Soon)", systemImage: "music.note.house")
            }
            .disabled(true)
            Divider()
            Button(role: .destructive) { onUnpublish() } label: {
                Label("Unpublish", systemImage: "trash")
            }
        }
    }

    private func toggleAlbumTrackPlayback() async {
        if isPlayingThis {
            player.pause()
            return
        }

        guard let url = URL(string: track.audioUrl) else { return }
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-\(track.trackId).m4a")

        if !FileManager.default.fileExists(atPath: tempFile.path) {
            isStreaming = true
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: tempFile)
            } catch {
                AppLog.error("[CatalogueAlbumTrackRow] Stream download failed: \(error)")
                isStreaming = false
                return
            }
            isStreaming = false
        }

        player.load(url: tempFile)
        player.nowPlaying = NowPlayingInfo(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            artworkURL: nil
        )
        player.play()
    }
}

// MARK: - Catalogue Edit Sheet

struct CatalogueEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var backend: BackendViewModel
    @State var track: CatalogueTrack
    let onSave: (CatalogueTrack) -> Void
    @State private var artStudioAvailable = false
    @State private var isGeneratingArtwork = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Artwork Section
                    VStack(spacing: 12) {
                        CatalogueArtworkView(trackId: track.trackId, artworkUrl: track.artworkUrl, size: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)

                        Button {
                            isGeneratingArtwork = true
                            Task {
                                do {
                                    let (imagePath, _) = try await backend.generateTrackArtwork(
                                        trackId: track.trackId,
                                        title: track.title,
                                        artist: track.artist,
                                        genre: track.genre
                                    )
                                    if !imagePath.isEmpty {
                                        AppLog.info("Art Studio generated artwork at: \(imagePath)")
                                    }
                                } catch {
                                    AppLog.error("Art Studio generation failed: \(error)")
                                }
                                isGeneratingArtwork = false
                            }
                        } label: {
                            if isGeneratingArtwork {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Generate with Art Studio", systemImage: "paintbrush")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        .disabled(!artStudioAvailable || isGeneratingArtwork)
                        .help(artStudioAvailable ? "Generate artwork using Majik's Art Studio" : "Art Studio not running")
                    }

                    Divider()

                    // Shared form sections
                    TrackMetadataFormSections(
                        title: $track.title,
                        artist: $track.artist,
                        album: $track.album,
                        genre: $track.genre,
                        subgenre: $track.subgenre,
                        description: $track.description,
                        backstory: $track.backstory,
                        backstoryVisibility: $track.backstoryVisibility,
                        mood: $track.mood,
                        energy: $track.energy,
                        tags: $track.tags,
                        language: $track.language,
                        isExplicit: $track.isExplicit,
                        credits: $track.credits,
                        bpmString: $track.bpm,
                        musicalKey: $track.musicalKey,
                        lyrics: $track.lyrics,
                        duration: track.duration
                    )

                    Divider()

                    // Publishing Info (read-only)
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Publishing Info")

                        VStack(alignment: .leading, spacing: 8) {
                            if let date = track.publishedAt {
                                InfoRow(label: "Published", value: Self.dateFormatter.string(from: date))
                            }
                            InfoRow(label: "Play Count", value: "\(track.playCount)")
                            if track.rating > 0 {
                                InfoRow(label: "Rating", value: String(format: "%.1f", track.rating))
                            }
                            if !track.trackSlug.isEmpty {
                                InfoRow(label: "Slug", value: track.trackSlug)
                            }
                            if !track.studioTrackId.isEmpty {
                                InfoRow(label: "Studio Track ID", value: track.studioTrackId)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    // Actions
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Button {
                                let urlStr = track.pageUrl.isEmpty
                                    ? "https://majiks.online/track/\(track.trackSlug)"
                                    : track.pageUrl
                                if let url = URL(string: urlStr) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label("Open on majiks.online", systemImage: "safari")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                let urlStr = track.pageUrl.isEmpty
                                    ? "https://majiks.online/track/\(track.trackSlug)"
                                    : track.pageUrl
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(urlStr, forType: .string)
                            } label: {
                                Label("Copy Link", systemImage: "link")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Edit Published Track")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(track)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(width: 600, height: 850)
        .onAppear {
            Task {
                do {
                    let (available, _) = try await backend.checkArtStudioHealth()
                    artStudioAvailable = available
                } catch {
                    artStudioAvailable = false
                }
            }
        }
    }
}

// MARK: - Sync Review Sheet

struct SyncReviewSheet: View {
    @EnvironmentObject var publisherStore: PublisherStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var backend: BackendViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var syncDirection: SyncDirection = .pushToServer
    @State private var selectedIds: Set<String> = []
    @State private var isSyncing = false
    @State private var syncResult: Int?

    struct SyncItem: Identifiable {
        let id: String  // catalogue trackId
        let title: String
        let localTrack: Track
        let catalogueTrack: CatalogueTrack
        let diffs: [MetadataDiff]
    }

    private var syncItems: [SyncItem] {
        publisherStore.catalogueTracks.compactMap { catalogueTrack in
            guard !catalogueTrack.studioTrackId.isEmpty,
                  let localId = UUID(uuidString: catalogueTrack.studioTrackId),
                  let localTrack = library.tracks.first(where: { $0.id == localId }) else {
                return nil
            }
            let diffs = publisherStore.computeDiffs(localTrack: localTrack, catalogueTrack: catalogueTrack)
            guard !diffs.isEmpty else { return nil }
            return SyncItem(
                id: catalogueTrack.trackId,
                title: catalogueTrack.title,
                localTrack: localTrack,
                catalogueTrack: catalogueTrack,
                diffs: diffs
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Review")
                        .font(.headline)
                    Text("\(syncItems.count) track\(syncItems.count == 1 ? " has" : "s have") differences")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Direction", selection: $syncDirection) {
                    Label("Push to Server", systemImage: "arrow.up.circle")
                        .tag(SyncDirection.pushToServer)
                    Label("Pull to Local", systemImage: "arrow.down.circle")
                        .tag(SyncDirection.pullToLocal)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .accessibilityLabel("Sync direction")
                .accessibilityValue(syncDirection == .pushToServer ? "Push to server" : "Pull to local")
            }
            .padding()

            Divider()

            if syncItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Everything is in sync!")
                        .font(.title3)
                    Spacer()
                }
            } else {
                // Diff table
                List {
                    ForEach(syncItems) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { selectedIds.contains(item.id) },
                                    set: { selected in
                                        if selected { selectedIds.insert(item.id) }
                                        else { selectedIds.remove(item.id) }
                                    }
                                )) { }
                                .toggleStyle(.checkbox)
                                .accessibilityLabel("Select \(item.title) for sync")

                                Text(item.title)
                                    .font(.headline)
                                    .lineLimit(1)

                                Spacer()

                                Text("\(item.diffs.count) field\(item.diffs.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            // Field-level diffs
                            ForEach(item.diffs) { diff in
                                HStack(spacing: 12) {
                                    Text(diff.fieldName.capitalized)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .frame(width: 60, alignment: .trailing)

                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text("Local:")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            Text(diff.localValue.isEmpty ? "—" : diff.localValue)
                                                .font(.caption)
                                                .lineLimit(1)
                                        }
                                        HStack(spacing: 4) {
                                            Text("Server:")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            Text(diff.serverValue.isEmpty ? "—" : diff.serverValue)
                                                .font(.caption)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()
                                }
                                .padding(.leading, 28)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Select All") {
                    selectedIds = Set(syncItems.map(\.id))
                }
                .controlSize(.small)
                .help("Select all tracks for sync")

                Spacer()

                if let result = syncResult {
                    Label("Synced \(result) track\(result == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Button {
                    isSyncing = true
                    Task {
                        for item in syncItems where selectedIds.contains(item.id) {
                            switch syncDirection {
                            case .pushToServer:
                                await publisherStore.pushLocalMetadataToServer(
                                    item.localTrack,
                                    catalogueTrack: item.catalogueTrack,
                                    backend: backend
                                )
                            case .pullToLocal:
                                if let localId = UUID(uuidString: item.catalogueTrack.studioTrackId) {
                                    publisherStore.updateLocalMetadataFromCatalogue(
                                        item.catalogueTrack,
                                        localTrackId: localId,
                                        library: library
                                    )
                                }
                            }
                        }
                        syncResult = selectedIds.count
                        let syncCount = syncResult ?? 0
                        selectedIds.removeAll()
                        isSyncing = false
                        ToastManager.shared.show(
                            "Synced \(syncCount) track\(syncCount == 1 ? "" : "s")",
                            style: .success
                        )

                        // Refresh catalogue to see updated data
                        await publisherStore.fetchCatalogue(backend: backend, library: library)
                    }
                } label: {
                    if isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(
                            syncDirection == .pushToServer ? "Push Selected to Server" : "Pull Selected to Local",
                            systemImage: syncDirection == .pushToServer ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIds.isEmpty || isSyncing)
            }
            .padding()
        }
        .frame(width: 650, height: 500)
        .onAppear {
            // Auto-select all items
            selectedIds = Set(syncItems.map(\.id))
        }
    }
}

// MARK: - Provenance Popover

struct ProvenancePopover: View {
    let track: CatalogueTrack
    let certificate: ProvenanceCertificate?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "shield.checkered")
                    .foregroundStyle(.green)
                Text("Provenance Certificate")
                    .font(.headline)
            }

            if isLoading {
                ProgressView("Loading certificate...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else if let cert = certificate {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Track") { Text(cert.title).lineLimit(1) }
                    LabeledContent("Artist") { Text(cert.artist).lineLimit(1) }
                    LabeledContent("Published") { Text(cert.publishedAt) }
                    LabeledContent("Hash") {
                        Text(cert.provenanceHash.prefix(24) + "...")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Divider()

                Text("This certificate proves first publication of this audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Copy Hash") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cert.provenanceHash, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Copy provenance hash to clipboard")

                    if !cert.verificationUrl.isEmpty {
                        Button("Verify Online") {
                            if let url = URL(string: cert.verificationUrl) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Verify provenance certificate online")
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Certificate not yet available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .frame(width: 350)
    }
}
