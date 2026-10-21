import Foundation

// MARK: - A counting seam in front of the filesystem
//
// Same lesson as `StudioKeychainItem`, one layer down and one order of magnitude
// cheaper — which is exactly why it survived the sweep that caught the keychain.
//
// `Track.audioFileExists` reads like a stored field. It is not. It builds a URL,
// renders that URL to a String path, and then makes a `stat(2)`. Measured on this
// box (`swiftc -O`, load ~120 on 12 cores, so the absolute numbers are inflated
// and only the RATIO is a claim):
//
//     URL append + .path (no syscall)          ~ 9,600 ns
//     FileManager.fileExists (miss)            ~ 1,900 ns
//     the whole accessor as written            ~12,400 ns
//     SecItemCopyMatching (miss) — the P0      ~130,000 ns
//
// Two things fall out of that, and the second one is the surprise:
//
//   1. One `audioFileExists` is ~10x cheaper than one securityd round trip. It
//      is not a P0 on its own.
//   2. THE SYSCALL IS NOT THE EXPENSIVE PART. Roughly 80% of the cost is the
//      `URL.appendingPathComponent(_:).path` in front of it. A "fix" that
//      memoised only the filesystem answer would have left most of the cost in
//      place while reporting a green counter — precisely the silent-degradation
//      shape this repo keeps getting caught by. So the counter below counts the
//      WHOLE accessor, not the syscall alone.
//
// What made it matter is arithmetic, not unit cost: `StudioLibrarySongRow.body`
// evaluated `loadable` — i.e. this accessor — SIX times per pass, and the Songs
// browser draws up to sixty of those rows in a plain (non-lazy) `ForEach`. 360
// calls per body pass, ~4.5 ms of main-thread layout, on a rail that redraws
// whenever the 30 Hz snapshot poll publishes.
//
// `probeCount` counts CALLS THROUGH THE ACCESSOR, incremented beside the work it
// measures, so `StudioBrowserCostTests` observes real work being skipped rather
// than a cache variable being assigned. It is a test seam, not a debug counter:
// the whole reason the keychain P0 shipped is that nothing could see it.
enum FileExistenceProbe {
    private static let lock = NSLock()
    /// `nonisolated(unsafe)` for the same reason `StudioKeychainItem` is
    /// `@unchecked Sendable`: the synchronisation is the `NSLock` below, held
    /// across every read and every write, which Swift 6 cannot see. The compiler
    /// is right that a bare mutable static is unsafe and wrong that this one is.
    private nonisolated(unsafe) static var count = 0

    /// Filesystem existence checks made through this seam since launch.
    static var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Build the path and ask the filesystem, counting the pair.
    ///
    /// The URL is taken as an `@autoclosure` so the *construction* — the
    /// expensive 80% — happens inside the seam and is therefore inside the count.
    /// Passing an already-built path would have measured the cheap half only.
    static func exists(_ url: @autoclosure () -> URL) -> Bool {
        lock.lock()
        count += 1
        lock.unlock()
        return FileManager.default.fileExists(atPath: url().path)
    }

    /// As above, for the call sites that already hold a path string.
    static func exists(atPath path: @autoclosure () -> String) -> Bool {
        lock.lock()
        count += 1
        lock.unlock()
        return FileManager.default.fileExists(atPath: path())
    }
}
