import Testing
import Foundation
@testable import MajiksMusicStudio

/// The command palette must never drift from the catalog again.
/// This test loads the canonical v2 JSON and verifies the palette's name
/// list matches it exactly.
struct StudioCommandPaletteTests {

    @Test("catalogNames count matches v2 catalog")
    func paletteCountMatchesCatalog() throws {
        // Locate command-catalog.v2.json relative to the repo root.
        // The test runner's cwd is the package directory (src/swift).
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let repoRoot = cwd
            .deletingLastPathComponent()  // src
            .deletingLastPathComponent()  // wt-batch
        let catalogURL = repoRoot
            .appendingPathComponent("engine")
            .appendingPathComponent("contracts")
            .appendingPathComponent("command-catalog.v2.json")

        let data = try Data(contentsOf: catalogURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let commands = json?["commands"] as? [[String: Any]]
        #expect(commands != nil, "v2 catalog has a commands array")
        #expect(commands?.count == CatalogNames.names.count,
                "CatalogNames.names (\(CatalogNames.names.count)) != catalog (\(commands?.count ?? 0))")

        // Verify every palette name exists in the catalog.
        let catalogNames = Set(commands?.compactMap { $0["name"] as? String } ?? [])
        for name in CatalogNames.names {
            #expect(catalogNames.contains(name),
                    "\(name) in CatalogNames but not in command-catalog.v2.json")
        }
    }
}
