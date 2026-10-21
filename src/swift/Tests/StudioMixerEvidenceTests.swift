import Testing
import Foundation
import SwiftUI
@testable import MajiksMusicStudio

// Evidence generator (also an end-to-end boot-test of the UI command path):
// drives the mixer + automation commands through the view model onto the mock
// engine, then renders the resulting dock + automation lane to PNGs via
// ImageRenderer. Only runs when L12_EVIDENCE=<outDir> is set, so a normal
// `swift test` never writes files.

@MainActor
@Suite("L12 evidence")
struct StudioMixerEvidenceTests {

    @Test("drive the bus and render the mixer dock + automation lane",
          .enabled(if: ProcessInfo.processInfo.environment["L12_EVIDENCE"] != nil))
    func renderEvidence() async throws {
        let dir = ProcessInfo.processInfo.environment["L12_EVIDENCE"]!
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }

        for _ in 0..<80 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let s0 = try #require(model.snapshot)
        #expect(s0.tracks.count >= 3)

        // Every call is a journaled command through the bus; the rendered dock
        // reads the results back from the snapshot (the round-trip, visible).
        model.setTrackEq(s0.tracks[0].id, band: 1, freqHz: 320, gainDB: 5, q: 1.1)
        model.setTrackEq(s0.tracks[0].id, band: 3, freqHz: 9000, gainDB: -3, q: 0.7)
        model.setTrackPan(s0.tracks[1].id, pan: -0.4)
        model.setTrackSend(s0.tracks[2].id, bus: .a, amount: 0.45)
        model.setLimiter(enabled: true, ceilingDB: -1, releaseMs: 60)
        model.togglePlayback()   // preview transport so the meters read
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Confirm the commands landed in the snapshot the dock renders.
        let s1 = try #require(model.snapshot)
        #expect(abs(s1.tracks[1].pan - -0.4) < 1e-6, "pan command round-tripped")
        #expect(s1.master.limiterEnabled, "limiter enabled round-tripped")

        let written = StudioMixerEvidence.render(model: model, to: dir)
        #expect(!written.isEmpty, "evidence PNGs written")
        for p in written {
            #expect(FileManager.default.fileExists(atPath: p), "wrote \(p)")
        }
    }
}
