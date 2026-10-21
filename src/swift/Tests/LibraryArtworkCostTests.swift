import Testing
import Foundation
import AppKit
import SwiftUI
@testable import MajiksMusicStudio

// Finding #2: LibraryTrackRow / AlbumGridCell / artist+album rows each did a
// synchronous uncached NSImage(contentsOf:) inside body. Measured 577 µs per
// call (~116× a stat). These tests COUNT decodes through ArtworkDecodeCache —
// they do not time them — so a green pass has observed real file opens being
// skipped, not a flag being set.

@MainActor
@Suite("library artwork cost", .serialized)
struct LibraryArtworkCostTests {

    /// 1×1 PNG — enough to exercise NSImage, small enough for a unit test.
    private static let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    private func scratchPNG() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-art-cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("art.png")
        try Self.pngData.write(to: url)
        return url
    }

    private func render<V: View>(_ view: V, times: Int) {
        for _ in 0..<times {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            _ = renderer.cgImage
        }
    }

    private func row(for track: Track) -> some View {
        LibraryTrackRow(
            track: track,
            isSelected: false,
            isPlaying: false,
            selectionMode: false,
            isChecked: false,
            onToggleSelection: {},
            onPlay: {},
            onPause: {},
            onStop: {},
            onEdit: {},
            onExport: {},
            onCopy: {},
            onDelete: {},
            onRatingChange: { _ in },
            onAutoName: {},
            onSendToStudio: {},
            onMoveTrack: {}
        )
        .environment(\.colorScheme, .dark)
        .frame(width: 800, height: 80)
    }

    // MARK: - Cache collapses re-decodes

    @Test("a hundred loads of the same path decode the file ONCE")
    func repeatedLoadsDecodeOnce() throws {
        ArtworkDecodeCache.resetForTesting()
        let url = try scratchPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let before = ArtworkDecodeCache.decodeCount
        var last: NSImage?
        for _ in 0..<100 {
            last = ArtworkDecodeCache.image(at: url)
        }
        let decodes = ArtworkDecodeCache.decodeCount - before

        #expect(last != nil, "fixture PNG failed to decode; the cache test is vacuous")
        #expect(
            decodes == 1,
            """
            100 loads of the same path cost \(decodes) file decodes. Before the \
            cache this equalled the number of loads — every body pass re-opened \
            the file.
            """
        )
    }

    @Test("thirty renders of a LibraryTrackRow with custom art decode once, not thirty")
    func rowBodyDecodesArtworkOnceAcrossRenders() throws {
        ArtworkDecodeCache.resetForTesting()
        let url = try scratchPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Point a track at our scratch file via customArtworkFileName. The
        // URL is built from FileStore.shared.artworkDirectory, so copy there.
        let fileStore = FileStore.shared
        let filename = "test-art-\(UUID().uuidString).png"
        let dest = fileStore.artworkDirectory.appendingPathComponent(filename)
        try FileManager.default.createDirectory(
            at: fileStore.artworkDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: url, to: dest)
        defer { try? FileManager.default.removeItem(at: dest) }

        let track = Track(
            id: UUID(),
            title: "Art Row",
            caption: "",
            audioFileName: "\(UUID().uuidString)/v.wav",
            createdAt: Date(),
            duration: 1,
            customArtworkFileName: filename
        )

        let beforeDecodes = ArtworkDecodeCache.decodeCount
        let beforeLookups = ArtworkDecodeCache.lookupCount
        render(row(for: track), times: 30)
        let decodes = ArtworkDecodeCache.decodeCount - beforeDecodes
        let lookups = ArtworkDecodeCache.lookupCount - beforeLookups

        // Vacuity: the row must have consulted the cache. If a restructure
        // stopped loading art entirely, lookups would be 0 and a decode==0
        // assertion would pass while guarding nothing.
        #expect(
            lookups >= 1,
            "LibraryTrackRow never looked up artwork across 30 renders; the cost test no longer exercises the path"
        )
        #expect(
            decodes == 1,
            """
            30 row renders cost \(decodes) artwork decodes (lookups=\(lookups)). \
            One decode for the path is the contract; before the cache every \
            body pass re-opened the file.
            """
        )
    }

    // MARK: - Invalidation

    @Test("remove(path:) drops the entry so the next load re-decodes")
    func removeInvalidatesExactly() throws {
        ArtworkDecodeCache.resetForTesting()
        let url = try scratchPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(ArtworkDecodeCache.image(at: url) != nil)
        let afterFirst = ArtworkDecodeCache.decodeCount

        // Hit — no new decode.
        #expect(ArtworkDecodeCache.image(at: url) != nil)
        #expect(ArtworkDecodeCache.decodeCount == afterFirst)

        ArtworkDecodeCache.remove(url: url)

        #expect(ArtworkDecodeCache.image(at: url) != nil)
        #expect(
            ArtworkDecodeCache.decodeCount == afterFirst + 1,
            "after remove, the next load must re-decode; decodeCount stayed at \(ArtworkDecodeCache.decodeCount)"
        )
    }

    @Test("the invalidation the store performs — remove(path:) — forgets the pixels")
    func storeShapedInvalidationForgetsPixels() throws {
        // Does not call LibraryStore.setTrackArtwork: that writes library.json
        // in the developer's real library. The store's contract is "call
        // ArtworkDecodeCache.remove on the previous path"; this test pins the
        // artifact of that call, and LibrarySearchCostTests pins the call site.
        ArtworkDecodeCache.resetForTesting()
        let url = try scratchPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(ArtworkDecodeCache.image(at: url) != nil)
        #expect(ArtworkDecodeCache.cachedEntryCount >= 1)

        // setTrackArtwork(nil) path: drop the previous file's decode.
        ArtworkDecodeCache.remove(url: url)
        #expect(
            ArtworkDecodeCache.cachedImage(at: url) == nil,
            "after remove, cachedImage must not still return the old pixels"
        )

        // Re-set writes a NEW UUID filename in the real store; simulate that
        // with a second path so the old entry staying gone is observable.
        let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.png")
        try Self.pngData.write(to: replacement)
        #expect(ArtworkDecodeCache.image(at: replacement) != nil)
        #expect(ArtworkDecodeCache.cachedImage(at: url) == nil,
                "loading a replacement path must not resurrect the removed one")
    }

    // MARK: - Seam honesty

    @Test("every image(at:) call is counted as a lookup — hits and misses")
    func lookupsAreCountedOneToOne() throws {
        ArtworkDecodeCache.resetForTesting()
        let url = try scratchPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let before = ArtworkDecodeCache.lookupCount
        for _ in 0..<5 { _ = ArtworkDecodeCache.image(at: url) }
        #expect(ArtworkDecodeCache.lookupCount - before == 5)

        let missing = url.deletingLastPathComponent().appendingPathComponent("nope.png")
        let beforeMiss = ArtworkDecodeCache.lookupCount
        for _ in 0..<3 { _ = ArtworkDecodeCache.image(at: missing) }
        #expect(ArtworkDecodeCache.lookupCount - beforeMiss == 3)
    }
}
