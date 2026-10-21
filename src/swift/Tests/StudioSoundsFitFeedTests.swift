import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// THE TWO FIT CHIPS, AND THE ONE LINE THAT FEEDS THEM.
//
// `StudioSoundsSearch.matches` is right, and 26 existing tests prove it — they
// all call it with `projectBPM:` and `projectKey:` as literals. What none of
// them touched is how those two values GET there, which is two `.onChange`
// closures in `StudioSoundsBrowser.body`.
//
// `.onChange` fires on a CHANGE. The browser is built when the user picks the
// Sounds section in the rail — long after the snapshot landed and stopped
// moving — so on the ordinary path neither closure ever ran:
//
//   * `projectBPM` stayed at its `120` default, so "In tempo" filtered a 96 BPM
//     song against 120 and hid every loop that fit.
//   * `projectKey` stayed `nil`, and `matches` opens the key test with
//     `guard let projectKey ... else { return false }` — so "In key" hid EVERY
//     sound in the vault, always, behind an empty state that blamed the search
//     terms ("Try fewer words, or turn a filter off").
//
// Leaving Sounds and coming back destroys the `@StateObject` and puts both
// defaults back, so it could not even be fixed by fiddling.
//
// This is the shape `StudioSoundsVaultTests` names in its own header as the
// commonest survivor on this repo — "every component proven and the single line
// in the view that feeds it unasserted" — so the test below is deliberately a
// FEED-LINE test: it renders the REAL `StudioBrowserView` with the Sounds
// section selected, through `ImageRenderer` (the deterministic no-window path),
// and then asks the vault model what the view told it.
//
// What this cannot prove, stated plainly: pixels and clicks. It proves the two
// numbers the filter runs on are the project's, not the defaults.

@MainActor
final class StudioSoundsFitFeedTests: XCTestCase {

    private func renderedSize<V: View>(_ view: V) -> CGSize? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        return renderer.nsImage?.size
    }

    private func asset(
        _ name: String, kind: StudioSoundKind = .loop, bpm: Double? = nil, key: String? = nil
    ) -> StudioSoundAsset {
        StudioSoundAsset(
            id: "Pack/\(name).wav", name: name,
            path: "/tmp/vault/Pack/\(name).wav", pack: "Pack",
            kind: kind, bpm: bpm, key: key,
            metadata: bpm == nil && key == nil ? .absent : .index)
    }

    private func settled(_ model: StudioViewModel, until condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 1. The feed line

    /// Open Sounds on a song that is NOT at the defaults, and the vault must be
    /// holding the song's numbers.
    ///
    /// The values are chosen to be different from BOTH defaults on purpose: 96
    /// is not 120, and "F min" is not nil. A mutation that pushes a constant,
    /// or that pushes nothing, fails on one of the two.
    func testOpeningSoundsHandsTheVaultTheSongsOwnTempoAndKey() async throws {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await settled(model) { model.snapshot != nil }

        model.setTempo(bpm: 96)
        model.setKey("F min")
        await settled(model) { model.snapshot?.tempoBPM == 96 && model.snapshot?.key == "F min" }
        XCTAssertEqual(model.snapshot?.key, "F min", "the project reached the state the test needs")

        let vault = StudioSoundsVaultModel()
        vault.adoptForTesting([asset("Loop A", bpm: 96, key: "F min")])

        _ = renderedSize(
            StudioBrowserView(model: model, initialSection: .sounds, injectedVault: vault)
                .environmentObject(LibraryStore())
                .frame(width: 260, height: 600))

        XCTAssertEqual(
            vault.projectBPM, 96, accuracy: 1e-9,
            """
            the vault is still measuring "In tempo" against \(vault.projectBPM) BPM while the \
            song runs at 96 — the fit chip is filtering against a default nobody set.
            """)
        XCTAssertEqual(
            vault.projectKey, "F min",
            """
            the vault was never told the song's key, so "In key" hides every sound in it \
            whatever the user types.
            """)
    }

    /// And the consequence, end to end: with both fit chips on, a sound that
    /// genuinely fits the song is VISIBLE. This is the assertion a user would
    /// make, and it fails on the defaults for two independent reasons at once.
    func testWithBothFitChipsOnASoundThatFitsTheSongIsListed() async throws {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await settled(model) { model.snapshot != nil }

        model.setTempo(bpm: 96)
        model.setKey("F min")
        await settled(model) { model.snapshot?.tempoBPM == 96 && model.snapshot?.key == "F min" }

        let vault = StudioSoundsVaultModel()
        vault.adoptForTesting([
            asset("Fits", bpm: 96, key: "Fmin"),        // same key, spelled the other way
            asset("Wrong tempo", bpm: 174, key: "Fmin"),
            asset("Wrong key", bpm: 96, key: "A maj"),
        ])
        vault.filter.inTempo = true
        vault.filter.inKey = true

        _ = renderedSize(
            StudioBrowserView(model: model, initialSection: .sounds, injectedVault: vault)
                .environmentObject(LibraryStore())
                .frame(width: 260, height: 600))

        XCTAssertEqual(
            vault.visible.map(\.name), ["Fits"],
            """
            with In tempo and In key on, a 96 BPM F-minor loop in a 96 BPM F-minor song \
            listed \(vault.visible.map(\.name)). The two chips are the only filters on, and \
            the only sound that should survive them is the one that fits.
            """)
    }

    // MARK: - 2. The residual case, said honestly

    /// A song whose key was never detected is still a real state, and "In key"
    /// still cannot match anything in it. What must NOT happen is the generic
    /// "try fewer words" — that blames the search for a filter that is
    /// structurally incapable of matching.
    ///
    /// Both branches asserted, with the SAME assets and query, so a message
    /// that ignored its inputs would fail one of them.
    func testInKeyWithNoSongKeySaysWhichControlToReachFor() {
        let vault = StudioSoundsVaultModel()
        vault.adoptForTesting([asset("Loop A", bpm: 120, key: "F min")])
        vault.filter.inKey = true

        vault.projectKey = nil
        let unset = try? XCTUnwrap(vault.emptyMessage)
        XCTAssertNotNil(unset)
        XCTAssertTrue(
            unset?.contains("no key yet") == true && unset?.contains("KEY") == true,
            "\"\(unset ?? "nil")\" does not say the song has no key, or where to set one")
        XCTAssertFalse(
            unset?.contains("Try fewer words") == true,
            "the empty state blames the search for a filter that cannot match")

        // Empty string is the same state spelled differently, and the engine
        // can publish it.
        vault.projectKey = ""
        XCTAssertEqual(vault.emptyMessage, unset)

        // With a key set, the same filter over the same assets matches, so the
        // message is gone entirely — not merely different.
        vault.projectKey = "F min"
        XCTAssertNil(
            vault.emptyMessage,
            "a matching key left an empty state behind, so the branch above is unreachable "
            + "for the wrong reason")
        XCTAssertEqual(vault.visible.map(\.name), ["Loop A"])
    }
}
