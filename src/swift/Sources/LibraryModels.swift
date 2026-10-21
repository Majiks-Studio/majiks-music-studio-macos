import Foundation

/// Represents an artist with aggregated data from tracks
struct ArtistViewModel: Identifiable, Hashable {
    let name: String
    var id: String { name }

    let trackCount: Int
    let albumCount: Int
    let totalDuration: Double
    let bpmRange: (min: Int, max: Int)?

    // Optional custom photo
    var photoFileName: String?

    var photoURL: URL? {
        guard let fileName = photoFileName else { return nil }
        return FileStore.shared.artworkDirectory.appendingPathComponent(fileName)
    }

    // Fallback to procedural if no photo.
    // ⚠️ A syscall behind a property — read it once per body pass. Counted by
    // `FileExistenceProbe`; see that file for what one of these actually costs.
    var hasCustomPhoto: Bool {
        if let url = photoURL {
            return FileExistenceProbe.exists(url)
        }
        return false
    }

    // Implement Hashable conformance for tuple
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(trackCount)
        hasher.combine(albumCount)
        hasher.combine(totalDuration)
        hasher.combine(bpmRange?.min)
        hasher.combine(bpmRange?.max)
        hasher.combine(photoFileName)
    }

    static func == (lhs: ArtistViewModel, rhs: ArtistViewModel) -> Bool {
        lhs.name == rhs.name &&
        lhs.trackCount == rhs.trackCount &&
        lhs.albumCount == rhs.albumCount &&
        lhs.totalDuration == rhs.totalDuration &&
        lhs.bpmRange?.min == rhs.bpmRange?.min &&
        lhs.bpmRange?.max == rhs.bpmRange?.max &&
        lhs.photoFileName == rhs.photoFileName
    }
}

/// Represents an album with aggregated data from tracks
struct AlbumViewModel: Identifiable, Hashable {
    let artistName: String
    let albumName: String
    var id: String { "\(artistName)|\(albumName)" }

    let trackCount: Int
    let totalDuration: Double
    let bpmRange: (min: Int, max: Int)?

    // Optional custom album art
    var artworkFileName: String?

    var artworkURL: URL? {
        guard let fileName = artworkFileName else { return nil }
        return FileStore.shared.artworkDirectory.appendingPathComponent(fileName)
    }

    // ⚠️ A syscall behind a property — read it once per body pass. Counted by
    // `FileExistenceProbe`; see that file for what one of these actually costs.
    var hasCustomArtwork: Bool {
        if let url = artworkURL {
            return FileExistenceProbe.exists(url)
        }
        return false
    }

    // Implement Hashable conformance for tuple
    func hash(into hasher: inout Hasher) {
        hasher.combine(artistName)
        hasher.combine(albumName)
        hasher.combine(trackCount)
        hasher.combine(totalDuration)
        hasher.combine(bpmRange?.min)
        hasher.combine(bpmRange?.max)
        hasher.combine(artworkFileName)
    }

    static func == (lhs: AlbumViewModel, rhs: AlbumViewModel) -> Bool {
        lhs.artistName == rhs.artistName &&
        lhs.albumName == rhs.albumName &&
        lhs.trackCount == rhs.trackCount &&
        lhs.totalDuration == rhs.totalDuration &&
        lhs.bpmRange?.min == rhs.bpmRange?.min &&
        lhs.bpmRange?.max == rhs.bpmRange?.max &&
        lhs.artworkFileName == rhs.artworkFileName
    }
}
