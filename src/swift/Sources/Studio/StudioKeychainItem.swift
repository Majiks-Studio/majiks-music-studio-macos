import Foundation
import Security

// MARK: - A keychain item that is honest about what it costs
//
// `SecItemCopyMatching` is not a memory read. It is a BLOCKING XPC round trip to
// securityd — `SecItemAuthDoQuery` -> `securityd_send_sync_and_do` ->
// `security_fw_send_message_with_reply_sync_inner` — and it blocks whichever
// thread asked, including the main thread in the middle of a SwiftUI layout
// pass.
//
// That is exactly what shipped in 3.4.13. `BrigadeConfig.isConfigured` READ like
// a field access, so it was written like one: `StudioCopilotDock.body` reached
// it through `.task(id: BrigadeConfig.isConfigured)`, and every body evaluation
// paid a securityd round trip. Sampling the owner's running process found the
// main thread spending ~40% of its time in SwiftUI layout with that call at the
// bottom of the stack, firing about every 110 ms for an eight-hour session. The
// keychain was never the problem. THE ACCESSOR WAS LYING ABOUT ITS COST.
//
// So: make the cheap thing actually cheap, and make the expensive thing look
// expensive. `value()` is a function because it can pay; `hasValue` is a
// property because after the first read it cannot.
//
// The cache is EXACT, not approximate, and deliberately NOT a TTL. This process
// is the only writer of these items and `set`/`delete` are the only two ways a
// value can change, so invalidation happens by construction rather than by
// expiry. A TTL would have traded a performance bug for a correctness bug: a
// stale `false` tells someone who HAS a key that they have none. The one case
// the cache cannot see is an item changed by something OTHER than this process
// (Keychain Access, the `security` CLI, a second copy of the app); nothing in
// the app does that, and `invalidateCache()` is the way back if anything ever
// does.
//
// `keychainReadCount` is a counting SEAM, not a debug counter. It counts
// syscalls, not accesses, so `StudioKeychainCostTests` can assert that N reads
// of `isConfigured` cost ONE round trip. Asserting that a cache variable had
// been assigned would prove nothing — this codebase has shipped a level meter
// driven by `abs(sin(t))` behind a fully green suite.
final class StudioKeychainItem: @unchecked Sendable {
    private let service: String
    private let account: String

    /// The lock is held ACROSS the securityd call, not merely around the cache
    /// write. Two threads racing a cold cache would otherwise each pay a round
    /// trip and the "N accesses, one read" claim would hold only while nothing
    /// else was looking; the waiter blocks on a result it would have blocked on
    /// anyway. Never taken from the audio thread — nothing in the render path
    /// reads a key.
    private let lock = NSLock()

    /// Three states, which is why this is a double optional:
    ///   `nil`             — unknown; ask securityd
    ///   `.some(nil)`      — known ABSENT. A miss costs a full round trip too,
    ///                       so it is cached: the owner's machine has no Brigade
    ///                       item at all, and that miss was the P0.
    ///   `.some(.some(v))` — known present
    private var cached: String??

    /// Actual `SecItemCopyMatching` calls made by this item.
    private var reads = 0

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// The stored secret, or nil when none is stored. One securityd round trip
    /// per cache miss; none afterwards.
    func value() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let fetched = copyFromKeychainLocked()
        cached = .some(fetched)
        return fetched
    }

    /// Whether a secret is stored. This is the accessor a SwiftUI body may
    /// evaluate on every layout pass, so it must never be the one that pays.
    var hasValue: Bool { value() != nil }

    /// Round trips to securityd this item has made. The test seam: it counts
    /// SYSCALLS, so a test observes the real call rather than a mock of the
    /// cache in front of it.
    var keychainReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    /// Replace the stored secret. Mirrors the behaviour this replaced exactly:
    /// any existing item is removed first, and an empty or whitespace-only
    /// value stores nothing — `set("")` is a delete.
    func set(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        deleteLocked()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        // Cache only what securityd actually accepted. On a failed add the cache
        // goes back to UNKNOWN rather than to a value that is not there: a lie
        // in that direction is a correctness bug, not a slow frame.
        cached = status == errSecSuccess ? .some(trimmed) : nil
    }

    /// Remove the stored secret.
    func delete() {
        lock.lock()
        defer { lock.unlock() }
        deleteLocked()
    }

    /// Drop the cache so the next read asks securityd again. For tests that need
    /// a cold start, and for the out-of-process writer this cache cannot see.
    func invalidateCache() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    // MARK: - locked internals (the caller already holds `lock`)

    private func deleteLocked() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // "Not found" is the same end state as a successful delete. Anything
        // else means we do not know what is stored, so say so rather than
        // caching an absence that may not be true.
        cached = (status == errSecSuccess || status == errSecItemNotFound) ? .some(nil) : nil
    }

    private func copyFromKeychainLocked() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        // Counted immediately beside the call it counts, so the seam cannot
        // drift away from the syscall it exists to measure.
        reads += 1
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }
}
