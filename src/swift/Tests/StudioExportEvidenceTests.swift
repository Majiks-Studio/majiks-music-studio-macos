import Testing
import Foundation
import SwiftUI
@testable import MajiksMusicStudio

// L13 evidence generator (also a boot-test of the export dialog + the provenance
// preview path): brings up the mock session, then renders the export +
// provenance dialog to a PNG via ImageRenderer. Only runs when L13_EVIDENCE=<dir>
// is set, so a normal `swift test` never writes files.

@MainActor
@Suite("L13 evidence")
struct StudioExportEvidenceTests {

    @Test("render the export + provenance dialog",
          .enabled(if: ProcessInfo.processInfo.environment["L13_EVIDENCE"] != nil))
    func renderEvidence() async throws {
        let dir = ProcessInfo.processInfo.environment["L13_EVIDENCE"]!
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }

        for _ in 0..<80 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let snap = try #require(model.snapshot)
        #expect(!snap.tracks.isEmpty)

        // The provenance preview is computed from the snapshot the dialog reads.
        let preview = StudioProvenancePreview.from(snap)
        #expect(preview.clipCount > 0, "mock session has clips to summarize")

        let written = StudioExportEvidence.render(model: model, to: dir)
        #expect(!written.isEmpty, "evidence PNG written")
        for p in written {
            #expect(FileManager.default.fileExists(atPath: p), "wrote \(p)")
        }
    }
}
