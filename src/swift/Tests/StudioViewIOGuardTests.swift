import Testing
import Foundation
@testable import MajiksMusicStudio

// MARK: - The standing guard: filesystem IO in view code must be COUNTABLE
//
// The keychain P0 shipped because nothing could see it. The browser-row storm
// shipped for the same reason one floor down. Neither was invisible in a
// profiler — both were invisible in the SUITE, which is where a defect has to be
// visible to stay fixed.
//
// So the ratchet is not "no IO in a body" (unenforceable, and sometimes wrong —
// a one-shot check in an `.onAppear` is fine). It is: EVERY filesystem existence
// check reachable from a SwiftUI body goes through `FileExistenceProbe`, so that
// a cost test can count it. Once it is counted, a test like
// `StudioBrowserCostTests` can pin it; while it is a raw `FileManager` call, no
// test can say anything about it at all.
//
// ⚠️ WHAT THIS GUARD DOES NOT COVER — stated plainly, because a net advertised
// as catching more than it does is worse than no net (this repo has shipped one
// of those too):
//
//   1. INDIRECTION, WHICH IS HOW THE ACTUAL BUG HID. `StudioLibrarySongRow.body`
//      never contained the word `FileManager`. It read `loadable`, which read
//      `Track.audioFileExists` in Models.swift — a different type in a different
//      file, two hops away, and Models.swift declares no `View` at all so this
//      scan would never even open it. A text scan cannot follow that. What
//      covers it is the COUNTER plus a per-view render assertion, and that only
//      covers views somebody wrote an assertion for.
//   2. Other IO kinds still unscanned: directory enumeration, `Data(contentsOf:)`,
//      `JSONDecoder`, keychain, network. `NSImage(contentsOf:)` IS now seamed
//      (see the second test below) because the Library stall sweep found it
//      live in row bodies at 577 µs/call. The NSImage scan has the same
//      indirection blind spot as the FileManager one.
//   3. Cost. It counts call SHAPES in source; it says nothing about how long
//      one takes or how often a body evaluates.
//
// So this is two narrow ratchets on two shapes, and the honest claim for them
// is exactly that.

@Suite("view IO guard")
struct StudioViewIOGuardTests {

    private static let sourcesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../Sources")
        .standardizedFileURL

    /// Raw `FileManager.default.fileExists` call sites in View-declaring files
    /// that are NOT reachable from a `body`, each checked by hand and named with
    /// the reason. Adding a line here is a deliberate act; a NEW body-reachable
    /// call is what the test is for.
    ///
    /// Keyed by file name, valued by the WHOLE trimmed line, so the entry does
    /// not rot when somebody inserts a line above it — line numbers in an
    /// allowlist are a maintenance trap.
    ///
    /// ⚠️ WHOLE LINES, NOT FRAGMENTS. The first draft keyed on the variable name
    /// (`"url.path"`, `"dest.path"`), which would have silently allowlisted any
    /// FUTURE raw check in the same file that happened to use the same local
    /// name — a hole shaped exactly like the guard. A needle loose enough to
    /// match the next bug is not an exemption, it is a disabled test.
    private static let notReachableFromABody: [String: [String]] = [
        // All four are inside button actions / export paths, not layout.
        "LibraryView.swift": [
            "if !FileManager.default.fileExists(atPath: destDir.path) {",
            "guard FileManager.default.fileExists(atPath: exportedPath) else {",
            "if !FileManager.default.fileExists(atPath: dest.path) {",
        ],
        // `loadArtwork()` from .onAppear, and two export temp-file checks.
        "CatalogueView.swift": [
            "if FileManager.default.fileExists(atPath: cacheURL.path),",
            "if !FileManager.default.fileExists(atPath: tempFile.path) {",
        ],
        // A download bookkeeping helper, called from an async action.
        "ManageModelsView.swift": [
            "if FileManager.default.fileExists(atPath: url.path) {",
        ],
    ]

    private func swiftFiles() throws -> [URL] {
        let fm = FileManager.default
        let e = try #require(fm.enumerator(at: Self.sourcesDirectory, includingPropertiesForKeys: nil))
        return (e.allObjects.compactMap { $0 as? URL }).filter { $0.pathExtension == "swift" }
    }

    @Test("no NEW raw filesystem existence check in a file that declares a SwiftUI View")
    func viewFilesProbeThroughTheCountedSeam() throws {
        let files = try swiftFiles()

        // Vacuity guard FIRST. If the enumerator returns nothing — a moved test
        // file, a renamed directory — every assertion below is trivially true
        // and this suite becomes a green light attached to nothing.
        #expect(files.count > 100, "only \(files.count) Swift files found; the scan is not reaching Sources")

        var offenders: [String] = []
        var viewFilesScanned = 0

        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("var body: some View") else { continue }
            viewFilesScanned += 1
            let name = url.lastPathComponent
            let allowed = Self.notReachableFromABody[name] ?? []

            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains("FileManager.default.fileExists") else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Exact match on the whole trimmed line, not a substring of it.
                guard !allowed.contains(trimmed) else { continue }
                offenders.append("\(name):\(i + 1): \(trimmed)")
            }
        }

        // Second vacuity guard: the allowlist above names real lines, so if the
        // scan stopped finding View files the test would pass while looking at
        // nothing.
        #expect(viewFilesScanned > 20, "only \(viewFilesScanned) View files scanned; the detector is not matching")

        #expect(
            offenders.isEmpty,
            """
            Raw filesystem existence check in view code:

            \(offenders.joined(separator: "\n"))

            Route it through `FileExistenceProbe.exists` so a cost test can count \
            it, or — if it genuinely cannot be reached from a `body` — add it to \
            `notReachableFromABody` with the reason. Do not delete this test.
            """
        )
    }

    @Test("the detector actually detects — a planted call is caught")
    func theDetectorIsNotAsleep() {
        // Guards the guard. The scan is a substring match over source text, and
        // a typo'd needle would make it pass forever while catching nothing —
        // the exact failure of the first draft of `StudioBrowserPanesTests`,
        // which searched whole files and would have credited a pane with another
        // pane's gesture. Here the needle is exercised against a synthetic line
        // rather than trusted.
        let planted = "        if FileManager.default.fileExists(atPath: someURL.path) {"
        #expect(planted.contains("FileManager.default.fileExists"))

        // And the seam call must NOT trip it, or every routed site would be
        // reported as an offender and the allowlist would swallow the suite.
        let routed = "        if FileExistenceProbe.exists(atPath: someURL.path) {"
        #expect(!routed.contains("FileManager.default.fileExists"))
    }

    // MARK: - NSImage(contentsOf:) in View files
    //
    // The Library stall sweep measured 577 µs per uncached synchronous decode
    // inside row bodies. Routing those through `ArtworkDecodeCache` makes them
    // countable; this guard stops a new raw call from landing in a View file
    // uncounted. Same allowlist discipline as the FileManager scan: whole
    // trimmed lines, not fragments.

    /// Raw `NSImage(contentsOf…)` call sites in View-declaring files that are
    /// NOT body-reachable layout work, each checked by hand. Prefer routing
    /// through `ArtworkDecodeCache` over growing this list — every Library
    /// stall site was fixed that way. Empty by design after the migration.
    private static let nsImageNotReachableFromABody: [String: [String]] = [:]

    @Test("no NEW raw NSImage(contentsOf:) in a file that declares a SwiftUI View")
    func viewFilesDecodeArtworkThroughTheCountedSeam() throws {
        let files = try swiftFiles()
        #expect(files.count > 100, "only \(files.count) Swift files found; the scan is not reaching Sources")

        var offenders: [String] = []
        var viewFilesScanned = 0
        // Needles that mean "opened an image file on this line". contentsOfFile:
        // is the form ArtworkDecodeCache itself uses; contentsOf: is the form
        // the Library rows used. Both are the stall.
        let needles = ["NSImage(contentsOf:", "NSImage(contentsOfFile:"]

        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("var body: some View") else { continue }
            viewFilesScanned += 1
            let name = url.lastPathComponent
            // The cache implementation is the seam; if it ever grew a View it
            // would still be allowed to call NSImage — but it does not declare
            // a body today. Belt and braces: skip it by name.
            if name == "ArtworkDecodeCache.swift" { continue }
            let allowed = Self.nsImageNotReachableFromABody[name] ?? []

            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard needles.contains(where: { trimmed.contains($0) }) else { continue }
                // Comments documenting the ban must not trip the guard.
                if trimmed.hasPrefix("//") { continue }
                guard !allowed.contains(trimmed) else { continue }
                offenders.append("\(name):\(i + 1): \(trimmed)")
            }
        }

        #expect(viewFilesScanned > 20, "only \(viewFilesScanned) View files scanned; the detector is not matching")
        #expect(
            offenders.isEmpty,
            """
            Raw NSImage file decode in view code:

            \(offenders.joined(separator: "\n"))

            Route it through `ArtworkDecodeCache.image(at:)` (or `cachedImage` \
            + off-main decode) so a cost test can count it, or — if it genuinely \
            cannot be reached from a body — add the WHOLE trimmed line to \
            `nsImageNotReachableFromABody` with the reason. Do not delete this test.
            """
        )
    }

    @Test("the NSImage detector actually detects — a planted call is caught")
    func theNSImageDetectorIsNotAsleep() {
        let planted = "        let nsImage = NSImage(contentsOf: customURL)"
        #expect(planted.contains("NSImage(contentsOf:"))
        let plantedFile = "        let nsImage = NSImage(contentsOfFile: path)"
        #expect(plantedFile.contains("NSImage(contentsOfFile:"))

        let routed = "        let nsImage = ArtworkDecodeCache.image(at: customURL)"
        #expect(!routed.contains("NSImage(contentsOf:"))
        #expect(!routed.contains("NSImage(contentsOfFile:"))
    }
}
