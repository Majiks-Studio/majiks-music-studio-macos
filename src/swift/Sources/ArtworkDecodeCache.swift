import Foundation
import AppKit

// MARK: - Counted, path-keyed artwork decode
//
// Finding #2 from the same main-thread stall sweep: `LibraryTrackRow`,
// `AlbumGridCell`, and the artist/album rows each did a synchronous,
// uncached `NSImage(contentsOf:)` inside their `body`. Measured 577 µs per
// call — about 116× a `stat(2)` — and it re-ran on every body pass for every
// visible row. Scrolling or typing (which re-renders the list) re-decoded the
// same files over and over.
//
// Trap, same lesson as `FileExistenceProbe`: the expensive thing is the whole
// decode, not a side check. Counting only "cache lookups" would go green while
// a body that still called `NSImage(contentsOf:)` directly kept paying. So
// `decodeCount` is incremented BESIDE the `NSImage(contentsOf:)` call, and
// every body-reachable decode in the Library must go through this seam.
//
// Invalidation is explicit and keyed by path:
//   - replaced artwork file (same logical slot, new file on disk under a new
//     name — the Library always writes `album-<uuid>.jpg` / `track-<uuid>.jpg`,
//     so a replacement is a NEW path and needs no invalidation of the old one;
//     the old entry is orphaned until `remove(path:)` or process exit)
//   - removed artwork: caller must `remove(path:)` so a row does not keep
//     showing the deleted image
//   - track deleted: optional; a stale cache entry is memory only, not wrong
//     pixels, because the path is gone from every view model
//
// ⚠️ A cache that never invalidates can show the wrong art after a replace-in-
// place of the same path. The Library does not currently overwrite in place
// (new UUID filenames), but `remove` + re-set still goes through the same
// helpers so a future in-place write cannot silently break the suite.

/// Process-wide artwork decode cache. Counts real file decodes.
enum ArtworkDecodeCache {
    private static let lock = NSLock()
    /// `nonisolated(unsafe)` for the same reason as `FileExistenceProbe`: the
    /// lock is held across every read and write; Swift 6 cannot see it.
    private nonisolated(unsafe) static var images: [String: NSImage] = [:]
    private nonisolated(unsafe) static var _decodeCount = 0
    private nonisolated(unsafe) static var _lookupCount = 0

    /// Times `NSImage(contentsOf:)` actually ran through this seam.
    static var decodeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _decodeCount
    }

    /// Times `image(at:)` was called (hit or miss). Used by cost tests to
    /// prove a body is still consulting the cache rather than having stopped
    /// loading art entirely (vacuity).
    static var lookupCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _lookupCount
    }

    /// Test-only. Drops every entry and zeroes the counters.
    static func resetForTesting() {
        lock.lock()
        images.removeAll(keepingCapacity: false)
        _decodeCount = 0
        _lookupCount = 0
        lock.unlock()
    }

    /// Lookup only — never opens the file. Used by async loaders that want a
    /// free main-actor hit and will decode off-main on a miss.
    static func cachedImage(at url: URL) -> NSImage? {
        cachedImage(atPath: url.path)
    }

    static func cachedImage(atPath path: @autoclosure () -> String) -> NSImage? {
        let resolved = path()
        lock.lock()
        _lookupCount += 1
        let hit = images[resolved]
        lock.unlock()
        return hit
    }

    /// Synchronous path-keyed load. Returns nil when the file is missing or
    /// unreadable. Counts every call as a lookup; counts a decode only when
    /// the file is actually opened. Prefer this from a body that already paid
    /// a `FileExistenceProbe` and needs pixels this frame; prefer
    /// `cachedImage` + off-main `image` from async loaders.
    static func image(at url: URL) -> NSImage? {
        image(atPath: url.path)
    }

    static func image(atPath path: @autoclosure () -> String) -> NSImage? {
        let resolved = path()
        lock.lock()
        _lookupCount += 1
        if let hit = images[resolved] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // Decode OUTSIDE the lock — NSImage I/O is the slow part and must not
        // serialise other rows. Double-checked insert below.
        let decoded = NSImage(contentsOfFile: resolved)
        lock.lock()
        _decodeCount += 1
        if let decoded {
            // Prefer the first decoder if two rows raced; both paid the decode
            // (counted) but only one image is retained.
            if let existing = images[resolved] {
                lock.unlock()
                return existing
            }
            images[resolved] = decoded
            lock.unlock()
            return decoded
        } else {
            // Do not cache a miss: an art file may appear after a download
            // finishes, and a permanent blank is worse than one extra probe.
            // Callers on the Library hot path typically FileExistenceProbe
            // first, so this branch is rare there.
            lock.unlock()
            return nil
        }
    }

    /// Drop one path. Call when artwork is removed or replaced at a known path.
    static func remove(path: String) {
        lock.lock()
        images.removeValue(forKey: path)
        lock.unlock()
    }

    static func remove(url: URL) {
        remove(path: url.path)
    }

    /// Drop everything. Used when the library is reloaded wholesale.
    static func removeAll() {
        lock.lock()
        images.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// Current resident entry count — test observability, not a product API.
    static var cachedEntryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return images.count
    }
}
