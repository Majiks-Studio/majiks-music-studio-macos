import Foundation
import AppKit
import Security

// MARK: - Sterling copilot backend seam
//
// A narrow seam the dock talks to, so the copilot UI compiles and runs in the
// mock build (no MajiksEngine) and drives the real FFI in the packaged app.
// Config (endpoint + model) lives in UserDefaults; the API key lives in the
// Keychain. Nothing here ever hands the key to the model: the FFI passes it as
// the Authorization header only, and the engine scrubs it from every event.
//
// Sterling is the Studio's copilot (replacing the app's generic default agent).
// He is distinct from MC Majik Mane, the DJ app's performer.

/// The copilot backend: job-style send/poll/cancel over one engine instance.
/// Synchronous because the FFI calls are quick and non-blocking (send returns a
/// turn id; the loop runs on a Rust background thread).
protocol StudioCopilotBackend: AnyObject {
    /// True when the real FFI is wired (the packaged app). False in the mock
    /// build, where the dock shows a plain "runs in the packaged app" note.
    var isAvailable: Bool { get }

    /// Start one turn; returns a turn id to poll. The route decides whether the
    /// turn runs through the local engine copilot loop or Unicorn Brigade.
    func send(_ request: StudioCopilotSendRequest) throws -> UInt64
    /// Cumulative turn state JSON: `{turn_id, state, events: [...]}`.
    func poll(_ turnId: UInt64) throws -> String
    func cancel(_ turnId: UInt64) throws
    func clearHistory() throws

    /// Undo the most recent command-bus action (last-in-first-out). Returns
    /// whether anything was undone. The dock offers this on Sterling's newest
    /// landed edit so the person can reverse what he just did.
    func undo() throws -> Bool
}

// MARK: - Persona

enum SterlingPersona {
    static let name = "Sterling"
    // Sterling is the PRODUCER: creative direction, arrangement, song
    // decisions. The separate built-in technical specialist keeps the name
    // "The Engineer" (capture, levels, EQ, mixing, parameter extraction).
    static let role = "The Producer"
    static let greeting =
        "Sterling here. I run the session with you: arrangement, generation, mixing, mastering. Tell me what you want and watch the timeline do it. Every move shows up as a chip you can click and undo."
    static let examples = [
        "Make the outro 16 bars longer and duck the bed under my VO",
        "What's on the timeline right now?",
        "Add a warm analog bass under the chorus",
    ]

    /// Sterling's mascot art, decoded once from the embedded base64.
    static let avatar: NSImage? = {
        guard let data = Data(base64Encoded: SterlingAvatarAsset.base64) else { return nil }
        return NSImage(data: data)
    }()
}

// MARK: - Config store (endpoint + model in UserDefaults; key in Keychain)

enum SterlingConfig {
    private static let endpointKey = "sterling.endpoint"
    private static let modelKey = "sterling.model"

    static var endpoint: String {
        get { UserDefaults.standard.string(forKey: endpointKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: endpointKey) }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    /// Configured = a place to send and a model to run. The key is optional (a
    /// local gateway needs none).
    static var isConfigured: Bool {
        !endpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Keychain (the API key, never in UserDefaults, never logged)

enum SterlingKeychain {
    /// The item, and the test seam. Same shape as `BrigadeKeychain`, and the
    /// same reason: `hasKey` is read from `@State` initialisers in three views
    /// (SterlingAgentManager, BrigadeSettingsSection, SetupWizard), each of
    /// which runs on every construction of the surrounding View struct — not
    /// once per mount. See `StudioKeychainItem`.
    static let item = StudioKeychainItem(
        service: "com.majik.musicstudio.sterling",
        account: "api_key"
    )

    static func setKey(_ key: String) { item.set(key) }

    static func key() -> String? { item.value() }

    static var hasKey: Bool { item.hasValue }

    static func deleteKey() { item.delete() }
}

// MARK: - Disabled backend (mock build / no engine)

/// Compiles and renders the dock without the FFI. Sends fail with a plain note;
/// the dock shows the "runs in the packaged app" state.
final class DisabledCopilotBackend: StudioCopilotBackend {
    var isAvailable: Bool { false }

    func send(_ request: StudioCopilotSendRequest) throws -> UInt64 {
        throw StudioCopilotError.unavailable
    }
    func poll(_ turnId: UInt64) throws -> String { "{}" }
    func cancel(_ turnId: UInt64) throws {}
    func clearHistory() throws {}
    func undo() throws -> Bool { false }
}

enum StudioCopilotError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Sterling runs in the packaged app (the real engine). This is a preview build."
        }
    }
}

// MARK: - Factory (real backend when the engine is FFI-backed, else disabled)

enum StudioCopilotBackendFactory {
    /// The copilot backend for the engine the Studio tab is already running, so
    /// Sterling drives the SAME host the UI does. Real under the packaged app;
    /// disabled on the mock engine.
    static func make(for engine: any StudioEngineProtocol) -> any StudioCopilotBackend {
        #if REAL_ENGINE
        if let real = engine as? RealStudioEngine {
            return RoutedCopilotBackend(local: FfiCopilotBackend(client: real.copilotClient))
        }
        #endif
        return DisabledCopilotBackend()
    }
}

enum StudioCopilotRoute: Equatable, Sendable {
    case local
    case brigade(agentID: String, displayName: String?)

    var isBrigade: Bool {
        if case .brigade = self { return true }
        return false
    }
}

struct StudioCopilotSendRequest: Sendable {
    let text: String
    let route: StudioCopilotRoute
    let systemPromptOverride: String?
}
