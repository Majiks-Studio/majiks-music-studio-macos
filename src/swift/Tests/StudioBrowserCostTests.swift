import Testing
import Foundation
import SwiftUI
@testable import MajiksMusicStudio

// The same defect as the keychain P0, one order of magnitude down, found by
// sweeping every computed property a `body` reads rather than by sampling —
// because a 12 µs accessor never shows up as a single fat frame in `sample`,
// it shows up as the main thread being uniformly busy.
//
//   StudioLibrarySongRow.body
//     -> loadable                      (x6 per pass)
//       -> Track.audioFileExists
//         -> URL.appendingPathComponent(_:).path   ~80% of the cost
//           -> FileManager.fileExists -> stat(2)   ~20% of the cost
//
// Measured on this box with `swiftc -O` (load ~120 on 12 cores, so the absolute
// figures are inflated and only the RATIO is a claim):
//
//     URL append + .path (no syscall)      ~ 9,600 ns
//     FileManager.fileExists (miss)        ~ 1,900 ns
//     the whole accessor                   ~12,400 ns
//     SecItemCopyMatching (miss) = the P0  ~130,000 ns
//
// One row read it six times; the Songs pane draws up to SIXTY rows in a plain,
// deliberately non-lazy `ForEach(matches.prefix(60))`. 360 calls per browser
// body pass ~ 4.5 ms of main-thread layout, against ~0.65 ms per pass for the
// keychain P0 (5 reads x 130 µs). Per pass, with the library open, this was the
// bigger of the two — which is why it is worth an assertion even though the unit
// cost looks harmless.
//
// ⚠️ THESE TESTS COUNT WORK, THEY DO NOT TIME IT. `probeCount` is incremented
// inside `FileExistenceProbe.exists` beside the URL build and the syscall, so a
// pass here has observed real work being skipped. Nothing below has a wall-clock
// bound, so nothing below can go red because the box is loaded — which is the
// failure mode the two MIDI-render assertions and `landing.rs` already have.

@MainActor
@Suite("browser row cost", .serialized)
struct StudioBrowserCostTests {

    /// A library song whose audio file does NOT exist — the case that costs the
    /// full probe and the one the owner's machine is mostly in (remote-only
    /// songs render dimmed). A hit and a miss cost the same URL build either way.
    private func fixture(_ title: String) -> Track {
        Track(
            id: UUID(), title: title, caption: "",
            audioFileName: "\(UUID().uuidString)/variant-1.wav",
            createdAt: Date(), duration: 1
        )
    }

    private func render<V: View>(_ view: V, times: Int) {
        for _ in 0..<times {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            _ = renderer.cgImage
        }
    }

    // MARK: - the artifact, not the assembly

    @Test("thirty renders of the real song row cost thirty filesystem probes, not 180")
    func rowBodyProbesTheFilesystemOncePerPass() {
        let model = StudioViewModel(engine: StudioMockEngine())
        let row = StudioLibrarySongRow(model: model, track: fixture("Midnight Drive"))
            .environment(\.colorScheme, .dark)

        let before = FileExistenceProbe.probeCount
        render(row, times: 30)
        let probes = FileExistenceProbe.probeCount - before

        // Guard against a VACUOUS pass. If the row stopped consulting the
        // filesystem at all — a restructured body, a cached flag hoisted into
        // the parent — `probes` would be 0 and the equality below would be green
        // while guarding nothing. Do not relax this; find out why the body
        // stopped reaching `Track.audioFileExists`.
        #expect(
            probes >= 1,
            "the row never probed the filesystem across 30 renders, so this test no longer exercises the path it exists to guard"
        )
        #expect(
            probes == 30,
            """
            30 row renders cost \(probes) filesystem probes. One per pass is the \
            contract; before the hoist it was six, because `body` read `loadable` \
            for highlighted, dimmed, help, hint, traits and the trailing `if`.
            """
        )
    }

    // MARK: - the multiplier is the whole reason this matters

    @Test("the cost scales with rows, one probe each — sixty rows is sixty probes")
    func aFullSongsPaneCostsOneProbePerRow() {
        // `ForEach(matches.prefix(60))` is the real cap in `StudioBrowserView.songs`
        // and the list is deliberately NOT lazy, so every one of these rows
        // evaluates its body on every pass. Sixty is therefore the real worst
        // case, not a stress figure.
        let model = StudioViewModel(engine: StudioMockEngine())
        let tracks = (0..<60).map { fixture("Song \($0)") }
        let pane = VStack(spacing: 2) {
            ForEach(tracks) { StudioLibrarySongRow(model: model, track: $0) }
        }
        .environment(\.colorScheme, .dark)

        let before = FileExistenceProbe.probeCount
        render(pane, times: 5)
        let probes = FileExistenceProbe.probeCount - before

        #expect(probes >= 60, "the pane never probed per row; the fixture is not reaching the row bodies")
        #expect(
            probes == 300,
            """
            5 passes over 60 rows cost \(probes) probes; 300 is one per row per \
            pass. Before the hoist this figure was 1,800 — about 22 ms of \
            main-thread layout for five redraws of a list nobody touched.
            """
        )
    }

    // MARK: - the accessor is honest about being counted

    @Test("every accessor call is counted — the accessor has no memo of its own")
    func theAccessorAndTheCounterAgreeOneToOne() {
        // What makes every render figure above meaningful, and the reason they
        // are not circular: the render tests assert "30 renders cost 30 probes",
        // which only means "one read per pass" while one READ costs one PROBE.
        // If `Track.audioFileExists` ever grows a memo of its own, this test
        // drops to 1 while the render counts stay at 30 — the two assertions
        // disagree and somebody has to look, rather than the suite going quietly
        // green on a number that has stopped meaning body passes.
        //
        // Deliberately a MISS: a miss pays the same URL build and the same
        // `stat(2)` as a hit, and the owner's library is mostly misses —
        // remote-only songs are exactly the rows that draw dimmed. This is the
        // same lesson as `StudioKeychainCostTests.absentItemAlsoCollapsesToOneRead`:
        // the machine that HAD the bug had no item and no file. A seam that only
        // counted hits would have reported the defect as absent on it.
        //
        // No fixture on disk, on purpose. A first draft created a real file
        // under `FileStore.shared.audioDirectory` and asserted the hit; it failed
        // in CI because that directory is the developer's real library location
        // and the test had no business writing there. Recorded rather than
        // quietly relaxed.
        let track = fixture("Counted Every Time")
        let before = FileExistenceProbe.probeCount

        for _ in 0..<5 { #expect(track.audioFileExists == false) }

        #expect(
            FileExistenceProbe.probeCount - before == 5,
            "5 accessor calls were counted as \(FileExistenceProbe.probeCount - before) probes"
        )
    }
}
