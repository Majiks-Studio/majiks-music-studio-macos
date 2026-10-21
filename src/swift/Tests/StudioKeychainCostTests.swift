import Testing
import Foundation
import SwiftUI
@testable import MajiksMusicStudio

// The P0 these tests exist for (3.4.13, found by sampling the running app):
//
//   StudioCopilotDock.body.getter
//     -> BrigadeKeychain.key()
//       -> SecItemCopyMatching
//         -> SecItemAuthDoQuery
//           -> securityd_send_sync_and_do
//             -> security_fw_send_message_with_reply_sync_inner   [BLOCKING XPC]
//
// ~40% of the main thread, about every 110 ms, for an eight-hour session — from
// a property that reads like a field access. See `StudioKeychainItem`.
//
// THESE TESTS ASSERT SYSCALLS, NOT STATE. `keychainReadCount` is incremented
// beside the `SecItemCopyMatching` call itself, so a test that passes here has
// observed the real round trip being skipped, not a cache variable being
// assigned. That distinction is the whole point: this codebase has shipped a
// level meter driven by `abs(sin(t))`, a piano roll wired to a mock and a
// separator that zeroed three quarters of every sample, all behind green suites.
//
// Everything that WRITES here writes to a per-test service name. Nothing in this
// file mutates the developer's real Sterling, Brigade or MCP secrets; the two
// tests that touch a real item only READ it, and drop the cache first so the
// count starts cold.

@MainActor
@Suite("keychain cost", .serialized)
struct StudioKeychainCostTests {

    /// A throwaway item under a service name no build ever uses.
    private func scratchItem() -> StudioKeychainItem {
        StudioKeychainItem(
            service: "com.majik.musicstudio.tests.\(UUID().uuidString)",
            account: "api_key"
        )
    }

    // MARK: - N accesses, one round trip

    @Test("a hundred presence checks on a stored key cost ONE securityd round trip")
    func presenceChecksOnAStoredKeyCollapseToOneRead() {
        let item = scratchItem()
        defer { item.delete() }
        item.set("sk-scratch-value")
        // Start COLD. `set` already caches what securityd accepted, so without
        // this the count would be 0 and the test would be measuring the write
        // path rather than the read path it exists to pin. (The first draft of
        // this test asserted 1 and failed on 0 — the cache was working better
        // than the assertion assumed. Recorded here rather than quietly relaxed.)
        item.invalidateCache()
        let before = item.keychainReadCount

        for _ in 0..<100 { _ = item.hasValue }

        #expect(item.hasValue == true)
        #expect(
            item.keychainReadCount - before == 1,
            """
            100 accesses cost \(item.keychainReadCount - before) securityd round \
            trips. The whole defect is that this number used to equal the number \
            of accesses.
            """
        )
    }

    @Test("a MISS is cached too — the melted machine had no Brigade item at all")
    func absentItemAlsoCollapsesToOneRead() {
        // Checked on the owner's login keychain while diagnosing this:
        // `com.majik.musicstudio.brigade / api_key` DOES NOT EXIST. Every one of
        // those thousands of round trips was a miss, and a miss costs the full
        // XPC pair. A cache that only remembered hits would have fixed nothing
        // for the person who actually reported the bug.
        let item = scratchItem()
        let before = item.keychainReadCount

        for _ in 0..<100 { #expect(item.hasValue == false) }

        #expect(
            item.keychainReadCount - before == 1,
            "an absent item still cost \(item.keychainReadCount - before) round trips"
        )
    }

    @Test("BrigadeConfig.isConfigured — the exact accessor the dock evaluated — reads once")
    func brigadeIsConfiguredReadsOnce() {
        BrigadeKeychain.item.invalidateCache()
        let before = BrigadeKeychain.item.keychainReadCount

        for _ in 0..<200 { _ = BrigadeConfig.isConfigured }

        let reads = BrigadeKeychain.item.keychainReadCount - before
        #expect(reads == 1, "200 reads of isConfigured cost \(reads) securityd round trips")
    }

    @Test("SterlingKeychain.hasKey reads once as well")
    func sterlingHasKeyReadsOnce() {
        SterlingKeychain.item.invalidateCache()
        let before = SterlingKeychain.item.keychainReadCount

        for _ in 0..<200 { _ = SterlingKeychain.hasKey }

        let reads = SterlingKeychain.item.keychainReadCount - before
        #expect(reads == 1, "200 reads of hasKey cost \(reads) securityd round trips")
    }

    // MARK: - the cache is exact, not approximate

    @Test("a write is visible on the very next read, with no stale window")
    func setInvalidatesExactly() {
        let item = scratchItem()
        defer { item.delete() }

        // Warm the cache with the WRONG answer first, or the test proves nothing
        // about invalidation — only that a cold read works.
        #expect(item.hasValue == false)

        item.set("sk-scratch-value")

        #expect(item.value() == "sk-scratch-value")
        #expect(item.hasValue == true)
    }

    @Test("a delete is visible on the very next read")
    func deleteInvalidatesExactly() {
        let item = scratchItem()
        item.set("sk-scratch-value")
        #expect(item.hasValue == true)      // warm the cache with PRESENT

        item.delete()

        #expect(item.value() == nil)
        #expect(item.hasValue == false)
    }

    @Test("set(\"\") is a delete, exactly as the inline code it replaced was")
    func emptySetClearsTheItem() {
        let item = scratchItem()
        defer { item.delete() }
        item.set("sk-scratch-value")
        #expect(item.hasValue == true)

        item.set("   ")

        #expect(item.value() == nil)
    }

    @Test("a stored value is trimmed, exactly as the inline code it replaced was")
    func storedValueIsTrimmed() {
        let item = scratchItem()
        defer { item.delete() }
        item.set("  sk-scratch-value\n")
        #expect(item.value() == "sk-scratch-value")
    }

    // MARK: - the artifact, not the assembly

    @Test("rendering the real Copilot dock thirty times costs ONE keychain read")
    func dockBodyDoesNotHitSecuritydPerPass() {
        // The deliverable assertion. `ImageRenderer` is the deterministic
        // no-window path StudioMidiClipRenderTests / StudioPaneSizingTests
        // already use; each `cgImage` forces a real body evaluation of the real
        // `StudioCopilotDock`, including the `.task(id: BrigadeConfig.isConfigured)`
        // whose id expression is what the sample caught in the act.
        BrigadeKeychain.item.invalidateCache()
        let before = BrigadeKeychain.item.keychainReadCount

        let model = StudioViewModel(engine: StudioMockEngine())
        let dock = StudioCopilotDock(studio: model)
            .environmentObject(StudioCoordinator())
            .environmentObject(AgentStore())
            .environment(\.colorScheme, .dark)

        for _ in 0..<30 {
            let renderer = ImageRenderer(content: dock)
            renderer.scale = 1
            _ = renderer.cgImage
        }

        let reads = BrigadeKeychain.item.keychainReadCount - before

        // Guard against a VACUOUS pass. If the dock stopped touching the Brigade
        // item at all — a collapsed `open`, a restructured body — `reads` would
        // be 0 and the assertion below would be green while guarding nothing.
        #expect(
            reads >= 1,
            """
            The dock never read the Brigade item across 30 renders, so this test \
            is no longer exercising the path it exists to guard. Do not relax it \
            — find out why the body stopped reaching BrigadeConfig.isConfigured.
            """
        )
        #expect(
            reads == 1,
            """
            30 dock renders cost \(reads) securityd round trips. Before the fix \
            this was one per body pass; at the ~9 body passes per second the \
            owner's machine was doing, that is what melted the main thread.
            """
        )
    }
}
