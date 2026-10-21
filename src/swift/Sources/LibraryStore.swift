import Foundation
import AVFoundation

/// Metadata for artists (for custom photos)
struct ArtistMetadata: Codable {
    var name: String
    var photoFileName: String?
}

/// Metadata for albums (for custom artwork)
struct AlbumMetadata: Codable {
    var artistName: String
    var albumName: String
    var artworkFileName: String?
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published var trackModifiedDates: [UUID: Date] = [:]
    @Published private(set) var artistMetadata: [String: ArtistMetadata] = [:]
    @Published private(set) var albumMetadata: [String: AlbumMetadata] = [:]  // Key: "artist|album"

    // MARK: - Cached Indexes (lazily built, invalidated on mutation)

    /// Tracks grouped by artist name. Tracks with nil/empty artist keyed as "Working Files".
    private var _artistIndex: [String: [Track]]?
    /// Tracks grouped by album name. Tracks with nil/empty album keyed as "Unsorted".
    private var _albumIndex: [String: [Track]]?
    /// Pre-lowercased searchable fields per track id. Built once per library
    /// mutation, not once per keystroke — see `LibraryTrackQuery`.
    private var _searchHaystacks: [UUID: LibrarySearchHaystack]?
    /// Bumped on every `invalidateIndexes()`. Fed into `LibraryFilterKey` so
    /// the filter result memo cannot return a list from a previous library
    /// contents. Starts at 1 so a zero-value key is never accidentally valid.
    private(set) var tracksRevision: Int = 1

    private var artistIndex: [String: [Track]] {
        if let cached = _artistIndex { return cached }
        let index = Dictionary(grouping: tracks) { track -> String in
            if let artist = track.artist, !artist.isEmpty {
                return artist
            }
            return "Working Files"
        }
        _artistIndex = index
        return index
    }

    private var albumIndex: [String: [Track]] {
        if let cached = _albumIndex { return cached }
        let index = Dictionary(grouping: tracks) { track -> String in
            if let album = track.album, !album.isEmpty {
                return album
            }
            return "Unsorted"
        }
        _albumIndex = index
        return index
    }

    /// Pre-lowercased search fields for every track. Built lazily on first
    /// filter after a mutation; subsequent keystrokes re-use the same map.
    ///
    /// ⚠️ Do not rebuild this inside a per-keystroke filter. That is the
    /// defect. `LibrarySearchCostTests` fails if a query change rebuilds.
    func searchHaystacks() -> [UUID: LibrarySearchHaystack] {
        if let cached = _searchHaystacks { return cached }
        var map: [UUID: LibrarySearchHaystack] = [:]
        map.reserveCapacity(tracks.count)
        for track in tracks {
            map[track.id] = LibrarySearchHaystack.build(from: track)
        }
        _searchHaystacks = map
        return map
    }

    /// Invalidate cached indexes. Must be called whenever `tracks` is mutated.
    /// Also drops the filter result memo so a body cannot keep a stale list.
    private func invalidateIndexes() {
        _artistIndex = nil
        _albumIndex = nil
        _searchHaystacks = nil
        tracksRevision &+= 1
        LibraryTrackQuery.invalidateResultMemo()
    }

    private let fileStore = FileStore.shared

    /// Pending debounced save task. Cancelled and replaced on each debounced save request.
    private var saveTask: Task<Void, Never>?

    private var artistMetadataURL: URL {
        fileStore.appSupportDirectory.appendingPathComponent("artist_metadata.json")
    }

    private var albumMetadataURL: URL {
        fileStore.appSupportDirectory.appendingPathComponent("album_metadata.json")
    }

    func load() {
        do {
            let data = try Data(contentsOf: fileStore.libraryURL)

            // Decode each track individually so one bad entry doesn't destroy the entire library
            let jsonArray = try JSONDecoder().decode([FailableDecodable<Track>].self, from: data)
            let decoded = jsonArray.compactMap { $0.value }

            let skipped = jsonArray.count - decoded.count
            if skipped > 0 {
                print("[LibraryStore] Warning: \(skipped) track(s) failed to decode and were skipped")
            }

            tracks = decoded.sorted { $0.createdAt > $1.createdAt }
            invalidateIndexes()
        } catch {
            print("[LibraryStore] Failed to load library: \(error)")
            tracks = []
            invalidateIndexes()
        }

        // Load artist metadata
        if let data = try? Data(contentsOf: artistMetadataURL),
           let metadata = try? JSONDecoder().decode([String: ArtistMetadata].self, from: data) {
            artistMetadata = metadata
        }

        // Load album metadata
        if let data = try? Data(contentsOf: albumMetadataURL),
           let metadata = try? JSONDecoder().decode([String: AlbumMetadata].self, from: data) {
            albumMetadata = metadata
        }

        loadTrackModifiedDates()
    }

    func addTrack(_ track: Track) {
        tracks.insert(track, at: 0)
        invalidateIndexes()
        saveImmediately()
    }

    func updateTrack(_ track: Track) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index] = track
            invalidateIndexes()
            trackModifiedDates[track.id] = Date()
            saveTrackModifiedDates()
            save()
        }
    }

    func updateTrackISRC(_ trackId: UUID, isrc: String) {
        if let index = tracks.firstIndex(where: { $0.id == trackId }) {
            tracks[index].isrc = isrc
            invalidateIndexes()
            save()
        }
    }

    func setRating(_ trackId: UUID, rating: Int) {
        let clamped = max(0, min(rating, 5))
        if let index = tracks.firstIndex(where: { $0.id == trackId }) {
            tracks[index].rating = clamped
            invalidateIndexes()
            save()
        }
    }

    func removeTrack(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        invalidateIndexes()
        do {
            try FileManager.default.removeItem(at: track.audioURL)
        } catch {
            print("[LibraryStore] Error removing audio file: \(error)")
        }
        saveImmediately()
    }

    // Scan audio directory and import missing files.
    // Returns the tracks that were freshly added so callers can run
    // follow-up work (e.g. metadata extraction) against the real delta.
    @discardableResult
    func scanAndImportMissingTracks() async -> [Track] {
        let audioURLs = collectAudioURLs()
        return await performImport(for: audioURLs)
    }

    /// Walk the audio directory synchronously and return every supported
    /// audio file URL outside the staging directory.
    /// FileManager.DirectoryEnumerator's iterator is not safe to use from
    /// an async context, so this stays synchronous and is called from the
    /// outer async entry point.
    private func collectAudioURLs() -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: fileStore.audioDirectory, includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey]) else {
            return []
        }

        var audioURLs: [URL] = []
        let stagingPath = fileStore.stagingDirectory.path
        for case let fileURL as URL in enumerator {
            // Skip staging directory - those are temporary/unkept tracks
            if fileURL.path.hasPrefix(stagingPath) {
                continue
            }

            guard fileURL.pathExtension.lowercased() == "wav" ||
                  fileURL.pathExtension.lowercased() == "mp3" ||
                  fileURL.pathExtension.lowercased() == "flac" else {
                continue
            }
            audioURLs.append(fileURL)
        }
        return audioURLs
    }

    @MainActor
    @discardableResult
    private func performImport(for fileURLs: [URL]) async -> [Track] {
        let fileManager = FileManager.default
        var importedCount = 0
        var newTracks: [Track] = []
        let existingFiles = Set(tracks.map { $0.audioFileName })

        for fileURL in fileURLs {
            // Get relative path from Audio directory
            let relativePath = fileURL.path.replacingOccurrences(of: fileStore.audioDirectory.path + "/", with: "")

            // Check if already in library (O(1) lookup)
            if existingFiles.contains(relativePath) {
                continue
            }

            // Import this file
            do {
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                let creationDate = attributes[.creationDate] as? Date ?? Date()

                // Get audio duration using modern async API
                let asset = AVURLAsset(url: fileURL)
                let loadedDuration = try await asset.load(.duration)
                let duration = CMTimeGetSeconds(loadedDuration)

                let track = Track(
                    id: UUID(),
                    title: fileURL.deletingPathExtension().lastPathComponent,
                    caption: "",
                    audioFileName: relativePath,
                    createdAt: creationDate,
                    duration: duration,
                    rating: 0,
                    bpm: nil,
                    key: nil,
                    artist: nil,
                    album: nil,
                    genre: nil,
                    lyrics: nil
                )

                tracks.insert(track, at: 0)
                newTracks.append(track)
                importedCount += 1
                print("[LibraryStore] Imported: \(relativePath)")
            } catch {
                print("[LibraryStore] Failed to import \(relativePath): \(error)")
            }
        }

        if importedCount > 0 {
            tracks.sort { $0.createdAt > $1.createdAt }
            invalidateIndexes()
            saveImmediately()
            print("[LibraryStore] Imported \(importedCount) missing track(s)")
        }
        return newTracks
    }

    // Remove tracks whose audio files no longer exist
    func cleanupMissingFiles() {
        let beforeCount = tracks.count
        tracks.removeAll { !$0.audioFileExists }
        if tracks.count < beforeCount {
            invalidateIndexes()
            saveImmediately()
            print("[LibraryStore] Removed \(beforeCount - tracks.count) track(s) with missing audio files")
        }
    }

    @Published private(set) var lastSaveError: String?

    func clearLastSaveError() {
        lastSaveError = nil
    }

    // MARK: - Save Debouncing

    /// Schedule a debounced save. Coalesces rapid edits into a single disk write
    /// after a 0.5-second quiet period. Use `saveImmediately()` for destructive
    /// operations (removes, adds) that must persist right away.
    private func save() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
            guard !Task.isCancelled else { return }
            _writeToDisk()
        }
    }

    /// Flush any pending debounced save and write to disk immediately.
    ///
    /// Called from destructive operations (add, remove, import, cleanup) and
    /// from `applicationWillTerminate` in `Main.swift`. That last caller did not
    /// exist while this comment already claimed it did, which left every
    /// `save()`-path edit — a rating, a retitle, an artwork swap — losable by
    /// quitting inside the 0.5 s debounce window.
    func saveImmediately() {
        saveTask?.cancel()
        saveTask = nil
        _writeToDisk()
    }

    /// Perform the actual JSON encode, backup, and atomic write.
    private func _writeToDisk() {
        createBackup()
        do {
            let data = try JSONEncoder().encode(tracks)
            try data.write(to: fileStore.libraryURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = "Failed to save library: \(error.localizedDescription)"
            print("[LibraryStore] Error saving library: \(error)")
        }
    }

    // MARK: - Backup System

    private var backupDirectory: URL {
        fileStore.baseDirectory.appendingPathComponent("Backups")
    }

    private func createBackup() {
        let libraryURL = fileStore.libraryURL
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return }

        do {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HHmmss"
            let timestamp = formatter.string(from: Date())
            let backupFile = backupDirectory.appendingPathComponent("library_\(timestamp).json")
            try FileManager.default.copyItem(at: libraryURL, to: backupFile)
        } catch {
            print("[LibraryStore] Backup failed: \(error)")
        }

        pruneBackups(in: backupDirectory, keepCount: 10)
    }

    private func pruneBackups(in directory: URL, keepCount: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            .filter({ $0.lastPathComponent.hasPrefix("library_") && $0.pathExtension == "json" })
            .sorted(by: {
                let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return d1 > d2  // newest first
            }) else { return }

        for file in files.dropFirst(keepCount) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func manualBackup() -> URL? {
        createBackup()
        return try? FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    func listBackups() -> [(url: URL, date: Date, trackCount: Int)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.creationDateKey])
            .filter({ $0.lastPathComponent.hasPrefix("library_") && $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else { return [] }

        return files.map { url in
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let count = (try? JSONDecoder().decode([FailableDecodable<Track>].self, from: Data(contentsOf: url)).compactMap(\.value).count) ?? 0
            return (url: url, date: date, trackCount: count)
        }
    }

    func restoreFromBackup(_ backupURL: URL) throws {
        // First backup current state
        createBackup()

        // Verify the backup is valid JSON
        let data = try Data(contentsOf: backupURL)
        let decoded = try JSONDecoder().decode([FailableDecodable<Track>].self, from: data)
        let validTracks = decoded.compactMap(\.value)

        // Replace current library
        let libraryURL = fileStore.libraryURL
        try data.write(to: libraryURL, options: .atomic)

        // Reload
        self.tracks = validTracks
        invalidateIndexes()
        print("[LibraryStore] Restored \(validTracks.count) tracks from backup")
    }

    func backupDirectoryURL() -> URL {
        return backupDirectory
    }

    private func loadTrackModifiedDates() {
        let url = fileStore.baseDirectory.appendingPathComponent("track_modified_dates.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String: Date].self, from: data)
            trackModifiedDates = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                guard let uuid = UUID(uuidString: key) else { return nil }
                return (uuid, value)
            })
        } catch {
            print("[LibraryStore] Failed to load track modified dates: \(error)")
        }
    }

    private func saveTrackModifiedDates() {
        let url = fileStore.baseDirectory.appendingPathComponent("track_modified_dates.json")
        let encoded = Dictionary(uniqueKeysWithValues: trackModifiedDates.map { (key, value) in
            (key.uuidString, value)
        })
        do {
            let data = try JSONEncoder().encode(encoded)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[LibraryStore] Failed to save track modified dates: \(error)")
        }
    }

    // MARK: - Folder-Based Organization

    func getArtistFolder(for artist: String?) -> URL {
        let artistName = artist ?? "Unknown Artist"
        return fileStore.audioDirectory
            .appendingPathComponent(artistName, isDirectory: true)
    }

    func getAlbumFolder(for artist: String?, album: String?) -> URL {
        let artistFolder = getArtistFolder(for: artist)
        let albumName = album ?? "Singles"
        return artistFolder.appendingPathComponent(albumName, isDirectory: true)
    }

    func getTrackPath(for track: Track) -> URL {
        let albumFolder = getAlbumFolder(for: track.artist, album: track.album)

        // Create safe filename from title
        let safeTitle = track.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "|", with: "")

        // Preserve original file extension (don't force .wav)
        let fileExtension = track.audioURL.pathExtension
        return albumFolder.appendingPathComponent("\(safeTitle).\(fileExtension)")
    }

    /// Resolve a non-colliding destination URL for `track`. If the natural
    /// path is free or already belongs to this track, returns it unchanged.
    /// Otherwise appends `-2`, `-3`, … before the extension until a free
    /// slot is found. This protects against silent overwrites when two
    /// distinct tracks share the same artist/album/title triple.
    private func uniqueTrackPath(for track: Track) -> URL {
        let fileManager = FileManager.default
        let baseURL = getTrackPath(for: track)

        // If nothing is in the way, or the file already at that path is the
        // one we're trying to organize, the base path is fine.
        if !fileManager.fileExists(atPath: baseURL.path) || baseURL.path == track.audioURL.path {
            return baseURL
        }

        let folder = baseURL.deletingLastPathComponent()
        let ext = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent

        var suffix = 2
        while true {
            let candidate = folder.appendingPathComponent("\(stem)-\(suffix).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
            // Safety valve — should never trigger in practice.
            if suffix > 9999 { return candidate }
        }
    }

    func organizeTrack(_ track: Track) {
        let fileManager = FileManager.default
        let oldURL = track.audioURL
        let newURL = uniqueTrackPath(for: track)

        // Create directory structure
        do {
            try fileManager.createDirectory(
                at: newURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            print("[LibraryStore] Failed to create directory: \(error)")
            return
        }

        // Move file if it exists and isn't already in the right place
        if oldURL.path != newURL.path && fileManager.fileExists(atPath: oldURL.path) {
            do {
                // uniqueTrackPath guarantees newURL is free, so no destructive
                // pre-delete is needed. Use moveItem which will fail loudly if
                // a race ever creates the destination between the check and
                // the move (better than silently clobbering user data).
                try fileManager.moveItem(at: oldURL, to: newURL)

                // Update track's audioFileName
                var updatedTrack = track
                let relativePath = newURL.path.replacingOccurrences(
                    of: fileStore.audioDirectory.path + "/",
                    with: ""
                )
                updatedTrack.audioFileName = relativePath
                updateTrack(updatedTrack)

                print("[LibraryStore] Organized: \(track.title) -> \(relativePath)")
            } catch {
                print("[LibraryStore] Failed to move file: \(error)")
            }
        }
    }

    func organizeAllTracks() {
        print("[LibraryStore] Organizing all tracks into folder structure...")
        for track in tracks {
            organizeTrack(track)
        }
        print("[LibraryStore] Organization complete!")
    }

    // MARK: - Artist/Album Management

    func getAllArtists() -> [String] {
        var artists = Set(tracks.compactMap { $0.artist })
        // Add "Working Files" if there are tracks without an artist
        if tracks.contains(where: { $0.artist == nil || $0.artist?.isEmpty == true }) {
            artists.insert("Working Files")
        }
        return Array(artists).sorted()
    }

    func getAllAlbums(for artist: String? = nil) -> [String] {
        let filteredTracks: [Track]
        if artist == "Working Files" {
            // For "Working Files", get tracks with no artist
            filteredTracks = tracks.filter { $0.artist == nil || $0.artist?.isEmpty == true }
        } else if let artist = artist {
            filteredTracks = tracks.filter { $0.artist == artist }
        } else {
            filteredTracks = tracks
        }

        var albums = Set(filteredTracks.compactMap { $0.album })
        // Add "Unsorted" if there are tracks without an album in this artist
        if filteredTracks.contains(where: { $0.album == nil || $0.album?.isEmpty == true }) {
            albums.insert("Unsorted")
        }
        return Array(albums).sorted()
    }

    func getTracksCount(for artist: String) -> Int {
        if artist == "Working Files" {
            return tracks.filter { $0.artist == nil || $0.artist?.isEmpty == true }.count
        }
        return tracks.filter { $0.artist == artist }.count
    }

    func getTracksCount(for artist: String, album: String) -> Int {
        if artist == "Working Files" {
            if album == "Unsorted" {
                return tracks.filter { ($0.artist == nil || $0.artist?.isEmpty == true) && ($0.album == nil || $0.album?.isEmpty == true) }.count
            }
            return tracks.filter { ($0.artist == nil || $0.artist?.isEmpty == true) && $0.album == album }.count
        }
        if album == "Unsorted" {
            return tracks.filter { $0.artist == artist && ($0.album == nil || $0.album?.isEmpty == true) }.count
        }
        return tracks.filter { $0.artist == artist && $0.album == album }.count
    }

    /// Build ArtistViewModel with aggregated data and metadata
    func getArtistViewModel(name: String) -> ArtistViewModel {
        let artistTracks: [Track]
        if name == "Working Files" {
            artistTracks = tracks.filter { $0.artist == nil || $0.artist?.isEmpty == true }
        } else {
            artistTracks = tracks.filter { $0.artist == name }
        }

        let albums = getAllAlbums(for: name)
        let bpms = artistTracks.compactMap { $0.bpm }.map { Int($0) }

        return ArtistViewModel(
            name: name,
            trackCount: artistTracks.count,
            albumCount: albums.count,
            totalDuration: artistTracks.reduce(0) { $0 + $1.duration },
            bpmRange: bpms.isEmpty ? nil : (min: bpms.min()!, max: bpms.max()!),
            photoFileName: artistMetadata[name]?.photoFileName
        )
    }

    /// Build AlbumViewModel with aggregated data and metadata
    func getAlbumViewModel(artist: String, album: String) -> AlbumViewModel {
        let albumTracks: [Track]
        if artist == "Working Files" {
            if album == "Unsorted" {
                albumTracks = tracks.filter { ($0.artist == nil || $0.artist?.isEmpty == true) && ($0.album == nil || $0.album?.isEmpty == true) }
            } else {
                albumTracks = tracks.filter { ($0.artist == nil || $0.artist?.isEmpty == true) && $0.album == album }
            }
        } else if album == "Unsorted" {
            albumTracks = tracks.filter { $0.artist == artist && ($0.album == nil || $0.album?.isEmpty == true) }
        } else {
            albumTracks = tracks.filter { $0.artist == artist && $0.album == album }
        }

        let bpms = albumTracks.compactMap { $0.bpm }.map { Int($0) }
        let key = "\(artist)|\(album)"

        return AlbumViewModel(
            artistName: artist,
            albumName: album,
            trackCount: albumTracks.count,
            totalDuration: albumTracks.reduce(0) { $0 + $1.duration },
            bpmRange: bpms.isEmpty ? nil : (min: bpms.min()!, max: bpms.max()!),
            artworkFileName: albumMetadata[key]?.artworkFileName
        )
    }

    // MARK: - Artwork Management

    /// Set or remove artist photo
    func setArtistPhoto(_ artistName: String, imageURL: URL?) {
        if let previous = artistMetadata[artistName]?.photoFileName {
            let previousURL = fileStore.artworkDirectory.appendingPathComponent(previous)
            ArtworkDecodeCache.remove(url: previousURL)
        }
        if let imageURL = imageURL {
            // Copy image to artwork directory
            let filename = "artist-\(UUID().uuidString).jpg"
            let destURL = fileStore.artworkDirectory.appendingPathComponent(filename)

            do {
                try FileManager.default.copyItem(at: imageURL, to: destURL)
                artistMetadata[artistName] = ArtistMetadata(name: artistName, photoFileName: filename)
            } catch {
                print("[LibraryStore] Failed to copy artist photo: \(error)")
                return
            }
        } else {
            artistMetadata[artistName]?.photoFileName = nil
        }
        saveArtistMetadata()
    }

    /// Set or remove album artwork
    func setAlbumArtwork(artist: String, album: String, imageURL: URL?) {
        let key = "\(artist)|\(album)"
        // Drop any previously-cached decode for this album slot so a replace
        // cannot keep showing the old pixels. New files use a fresh UUID name,
        // but removal must still clear the path the rows were reading.
        if let previous = albumMetadata[key]?.artworkFileName {
            let previousURL = fileStore.artworkDirectory.appendingPathComponent(previous)
            ArtworkDecodeCache.remove(url: previousURL)
        }
        if let imageURL = imageURL {
            let filename = "album-\(UUID().uuidString).jpg"
            let destURL = fileStore.artworkDirectory.appendingPathComponent(filename)

            do {
                try FileManager.default.copyItem(at: imageURL, to: destURL)
                albumMetadata[key] = AlbumMetadata(
                    artistName: artist,
                    albumName: album,
                    artworkFileName: filename
                )
            } catch {
                print("[LibraryStore] Failed to copy album artwork: \(error)")
                return
            }
        } else {
            albumMetadata[key]?.artworkFileName = nil
        }
        saveAlbumMetadata()
    }

    /// Set or remove custom artwork for a specific track
    func setTrackArtwork(_ trackId: UUID, imageURL: URL?) {
        guard let index = tracks.firstIndex(where: { $0.id == trackId }) else { return }

        if let previous = tracks[index].customArtworkFileName {
            let previousURL = fileStore.artworkDirectory.appendingPathComponent(previous)
            ArtworkDecodeCache.remove(url: previousURL)
        }

        if let imageURL = imageURL {
            let filename = "track-\(UUID().uuidString).jpg"
            let destURL = fileStore.artworkDirectory.appendingPathComponent(filename)

            do {
                try FileManager.default.copyItem(at: imageURL, to: destURL)
                tracks[index].customArtworkFileName = filename
            } catch {
                print("[LibraryStore] Failed to copy track artwork: \(error)")
                return
            }
        } else {
            tracks[index].customArtworkFileName = nil
        }
        // Artwork filename is searchable-state-adjacent only via the track
        // record; revision bump so any view caching the track list refreshes.
        invalidateIndexes()
        save()
    }

    private func saveArtistMetadata() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(artistMetadata)
            try data.write(to: artistMetadataURL, options: .atomic)
        } catch {
            print("[LibraryStore] Error saving artist metadata: \(error)")
        }
    }

    private func saveAlbumMetadata() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(albumMetadata)
            try data.write(to: albumMetadataURL, options: .atomic)
        } catch {
            print("[LibraryStore] Error saving album metadata: \(error)")
        }
    }

    // MARK: - Metadata Export

    func exportTrackMetadata(track: Track, to url: URL) throws {
        let metadata: [String: Any] = [
            "id": track.id.uuidString,
            "title": track.title,
            "caption": track.caption,
            "createdAt": ISO8601DateFormatter().string(from: track.createdAt),
            "duration": track.duration,
            "rating": track.rating,
            "bpm": track.bpm as Any,
            "key": track.key as Any,
            "artist": track.artist as Any,
            "album": track.album as Any,
            "genre": track.genre as Any,
            "lyrics": track.lyrics as Any,
            "originalPrompt": track.originalPrompt as Any,
            "generationParams": encodeGenerationParams(track.generationParams) as Any,
            "sessionId": track.sessionId?.uuidString as Any,
            "conversationId": track.conversationId?.uuidString as Any
        ]

        let jsonData = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try jsonData.write(to: url, options: .atomic)
    }

    private func encodeGenerationParams(_ params: GenerationParams?) -> [String: Any]? {
        guard let params = params else { return nil }
        var dict: [String: Any] = [:]
        dict["bpm"] = params.bpm
        dict["key"] = params.key
        dict["duration"] = params.duration
        dict["variantCount"] = params.variantCount
        dict["model"] = params.model
        dict["lmModel"] = params.lmModel
        dict["guidanceScale"] = params.guidanceScale
        dict["lyrics"] = params.lyrics
        dict["style"] = params.style
        if let ts = params.timestamp {
            dict["timestamp"] = ISO8601DateFormatter().string(from: ts)
        }
        dict["genre"] = params.genre
        dict["mood"] = params.mood
        dict["artist"] = params.artist
        dict["album"] = params.album
        return dict.compactMapValues { $0 }
    }
}
