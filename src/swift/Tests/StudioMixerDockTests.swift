import Testing
import Foundation
import SwiftUI
@testable import MajiksMusicStudio

// The mixer dock pins its strips to a fixed height. When a strip's intrinsic
// height outgrows that frame the overflow is CLIPPED, silently and with no
// error: at the previous 236 pt the bottom 42 pt of every channel strip was cut
// off, which meant the per-track Mute and Solo buttons were never drawn and
// could never be clicked. Nothing about that fails a build or a unit test — it
// only shows up as "the mixer's mute button does nothing".
//
// So measure the real strips the same way StudioMixerEvidence renders them
// (ImageRenderer, deterministic, no window) and assert they still fit.

@MainActor
@Suite("mixer dock geometry")
struct StudioMixerDockTests {

    private func idealSize<V: View>(_ view: V) -> CGSize? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        return CGSize(width: cg.width, height: cg.height)
    }

    private func bootedModel() async throws -> StudioViewModel {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        for _ in 0..<80 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return model
    }

    @Test("a channel strip fits the dock, so M / S stay clickable")
    func channelStripFitsDock() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let snapshot = try #require(model.snapshot)
        let track = try #require(snapshot.tracks.first)

        let size = try #require(idealSize(StudioMixerStrip(model: model, track: track)))
        let needed = size.height + StudioMixerDock.stripVerticalPadding * 2
        #expect(
            needed <= StudioMixerDock.dockHeight,
            """
            A channel strip needs \(needed) pt but the dock is \
            \(StudioMixerDock.dockHeight) pt. The overflow is clipped, not \
            scrolled — the bottom of the strip (Mute / Solo) would be invisible \
            and unclickable. Raise StudioMixerDock.stripHeight.
            """
        )
    }

    @Test("the master strip fits the dock too")
    func masterStripFitsDock() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let snapshot = try #require(model.snapshot)

        let size = try #require(idealSize(StudioMasterStrip(model: model, master: snapshot.master)))
        let needed = size.height + StudioMixerDock.stripVerticalPadding * 2
        #expect(
            needed <= StudioMixerDock.dockHeight,
            "The master strip needs \(needed) pt but the dock is \(StudioMixerDock.dockHeight) pt."
        )
    }
}
