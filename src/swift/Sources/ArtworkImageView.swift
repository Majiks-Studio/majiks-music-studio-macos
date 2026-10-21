import SwiftUI
import AppKit

enum ArtworkType {
    case artist(name: String)
    case album(artist: String, album: String)
    case track(id: UUID)
}

struct ArtworkImageView: View {
    let type: ArtworkType
    let imageURL: URL?
    let size: CGFloat

    @State private var loadedImage: NSImage?

    var body: some View {
        Group {
            if let loadedImage = loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Procedural fallback
                proceduralArtwork
            }
        }
        .frame(width: size, height: size)
        .clipShape(clipShape)
        .onAppear {
            loadImageIfNeeded()
        }
        .onChange(of: imageURL) { _, _ in
            loadImageIfNeeded()
        }
    }

    private var clipShape: some Shape {
        switch type {
        case .artist:
            return AnyShape(Circle())
        case .album, .track:
            return AnyShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var proceduralArtwork: some View {
        switch type {
        case .artist(let name):
            return AnyView(
                AlbumArtGenerator.generate(for: name, size: size)
                    .clipShape(Circle())
            )
        case .album(let artist, let album):
            return AnyView(
                AlbumArtGenerator.generate(for: "\(artist)|\(album)", size: size)
            )
        case .track(let id):
            return AnyView(
                AlbumArtGenerator.generate(for: id.uuidString, size: size)
            )
        }
    }

    private func loadImageIfNeeded() {
        guard let imageURL = imageURL else {
            loadedImage = nil
            return
        }

        // Lookup-only on the main actor. A hit is free; a miss must NOT call
        // `image(at:)` here or we reintroduce the 577 µs body-stall this
        // view exists to avoid. Decode happens off-main below.
        if let cached = ArtworkDecodeCache.cachedImage(at: imageURL) {
            loadedImage = cached
            return
        }

        let url = imageURL
        DispatchQueue.global(qos: .userInitiated).async {
            // Counts as one decode through the seam; subsequent main-actor
            // lookups in other rows hit the cache.
            let image = ArtworkDecodeCache.image(at: url)
            DispatchQueue.main.async {
                loadedImage = image
            }
        }
    }
}

// Helper for type-erased Shape
struct AnyShape: Shape {
    private let pathFunc: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        pathFunc = { rect in
            shape.path(in: rect)
        }
    }

    func path(in rect: CGRect) -> Path {
        pathFunc(rect)
    }
}
