import Foundation
import Security
#if canImport(AppKit)
import AppKit
#endif

// The HOST side of the Studio's MCP server.
//
// The engine already owns the whole server: `agent-surface`'s `mcp.rs` is an
// rmcp localhost streamable-HTTP server serving the generated 109-tool registry,
// and `ffi.rs` exports `mcp_start` / `mcp_stop` / `mcp_running` across UniFFI
// (see Sources/Engine/Generated/majiks_engine.swift). What was missing was the
// host: nothing in the app ever CALLED it at launch, and there was no human
// surface to turn it on. This file is that host.
//
// Two ways in, one code path:
//   1. Launch arguments  `--studio-mcp-pat <TOKEN> [--studio-mcp-port <N>]`
//      (the documented headless/dev path; the operator already typed the token,
//      so the full `claude mcp add` line is logged verbatim).
//   2. Settings ▸ MCP / API: a persisted enable toggle plus a PAT minted into
//      the login Keychain. The token is never logged in this path — the pane
//      copies the connection line to the pasteboard instead.
//
// Fail closed, everywhere: no PAT means no server; an empty/blank PAT is
// refused before the engine is even touched; the engine binds 127.0.0.1 only
// and rejects `enabled: false`. When MCP is off we never materialize
// `StudioEngineFactory.shared`, so the app stays as lazy as it was.

// MARK: - Wire helpers (pure, testable, no engine, no MainActor)

enum StudioMCPWire {
    /// The engine's fixed default port (agent-surface `mcp::DEFAULT_MCP_PORT`),
    /// chosen distinct from Majik's DJ's 8471 so both can serve at once.
    static let defaultPort: UInt16 = 8478
    static let httpPath = "/mcp"
    /// The MCP server name an agent host registers us under.
    static let serverName = "majiks-studio"

    static let patFlag = "--studio-mcp-pat"
    static let portFlag = "--studio-mcp-port"

    /// What the launch arguments asked for. `nil` when no usable PAT was given —
    /// that is the fail-closed case, not an error.
    struct LaunchFlags: Equatable {
        var pat: String
        var port: UInt16
    }

    /// Parse `--studio-mcp-pat <TOKEN>` / `--studio-mcp-pat=<TOKEN>` and the
    /// optional `--studio-mcp-port`. Returns nil when the PAT flag is absent,
    /// has no value, or the value is blank: no PAT, no server.
    static func parseLaunchFlags(_ args: [String]) -> LaunchFlags? {
        guard let pat = flagValue(patFlag, in: args)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !pat.isEmpty
        else { return nil }

        var port = defaultPort
        if let raw = flagValue(portFlag, in: args)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let parsed = UInt16(raw), parsed > 0 {
            port = parsed
        }
        return LaunchFlags(pat: pat, port: port)
    }

    /// `--flag value` or `--flag=value`, whichever the caller used.
    static func flagValue(_ flag: String, in args: [String]) -> String? {
        if let i = args.firstIndex(of: flag) {
            guard i + 1 < args.count else { return nil }
            let next = args[i + 1]
            // `--studio-mcp-pat --studio-mcp-port 9000` is a missing value, not
            // a token named "--studio-mcp-port".
            guard !next.hasPrefix("--") else { return nil }
            return next
        }
        let prefix = flag + "="
        if let joined = args.first(where: { $0.hasPrefix(prefix) }) {
            return String(joined.dropFirst(prefix.count))
        }
        return nil
    }

    /// The `claude mcp add` line, verbatim in the shape docs/MCP_API.md
    /// documents. `token` is whatever the caller decided is safe to show.
    static func connectionLine(port: UInt16, token: String) -> String {
        "claude mcp add \(serverName) --transport http --url http://127.0.0.1:\(port)\(httpPath) --header \"Authorization: Bearer \(token)\""
    }

    static func healthURL(port: UInt16) -> URL? {
        URL(string: "http://127.0.0.1:\(port)/health")
    }

    /// Display form of a secret: first 4 characters, then dots. Mirrors the
    /// engine's `secret::redact` so the app and the engine agree about what a
    /// masked token looks like.
    static func mask(_ token: String) -> String {
        guard !token.isEmpty else { return "" }
        let head = String(token.prefix(4))
        return head + "\u{2022}\u{2022}\u{2022}\u{2022}"
    }

    /// Mint a fresh opaque PAT: `mms_` plus 52 Crockford-base32 characters of
    /// CSPRNG entropy, the same shape the engine's `secret::generate_pat` makes
    /// (two ULIDs' worth). 32 divides 256, so the byte->alphabet map is uniform.
    static func generatePAT() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var bytes = [UInt8](repeating: 0, count: 52)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Never silently fall back to a weak token.
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        let body = String(bytes.map { alphabet[Int($0 % 32)] })
        return "mms_" + body
    }
}

// MARK: - State

enum StudioMCPState: Equatable {
    /// Fail-closed default: not enabled, or no PAT.
    case off
    case starting
    case running(port: UInt16)
    /// The engine refused or the bind failed. Carries the engine's message.
    case failed(String)
    /// There is no engine to serve from (mock build / real-engine init failed).
    /// NOT a success state — nothing is listening.
    case unavailable(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

enum StudioMCPHealth: Equatable {
    case unknown
    case ok
    case unreachable(String)
}

// MARK: - The host model

/// Owns the app's MCP server lifecycle: launch-argument bootstrap, the persisted
/// Settings toggle, the Keychain PAT, and the `GET /health` liveness probe.
@MainActor
final class StudioMCPServerModel: ObservableObject {
    static let shared = StudioMCPServerModel()

    // Persisted (UserDefaults) — the enable flag and the port.
    static let enabledKey = "majiks_studio_mcp_enabled"
    static let portKey = "majiks_studio_mcp_port"
    // Keychain (login keychain, same service the rest of the app uses).
    static let keychainService = "com.majik.musicstudio"
    static let keychainAccount = "studio_mcp_pat"

    @Published private(set) var state: StudioMCPState = .off
    @Published private(set) var health: StudioMCPHealth = .unknown
    /// Last non-fatal note for the pane (e.g. "port changed; restart to apply").
    @Published private(set) var note: String?

    /// Whether the server is available at all in this build. False on the mock
    /// build, where there is no engine and therefore nothing to serve.
    var engineAvailable: Bool {
        #if REAL_ENGINE
        return true
        #else
        return false
        #endif
    }

    /// The honest reason the server cannot run in this build.
    static let mockBuildReason = """
    This build runs the mock Studio engine — MajiksEngine.xcframework is not \
    linked, so there is no MCP server to start. Build the app with the real \
    engine (scripts/build-engine.sh, then build-release.sh) to serve MCP.
    """

    private let defaults: UserDefaults
    /// The PAT's keychain item. Injectable for the same reason `defaults` is:
    /// `StudioMCPHostTests` gave itself a throwaway UserDefaults suite so it
    /// would never touch the user's real settings, but had no way to say the
    /// same about the Keychain — so `connectionLineIsMaskedByDefault` read the
    /// developer's REAL login keychain and failed on any machine that had ever
    /// generated a token. See `StudioKeychainItem` for the caching this also
    /// brings: `hasPAT` is evaluated four times per body pass of the MCP pane.
    let pat: StudioKeychainItem
    private var healthTask: Task<Void, Never>?
    /// The port the server is ACTUALLY bound to, recorded when we started it.
    /// The engine's `mcp_running` is a bare Bool, so this host is the only thing
    /// that knows — never infer the live port from the configured one.
    private var servingPort: UInt16?

    init(
        defaults: UserDefaults = .standard,
        pat: StudioKeychainItem = StudioKeychainItem(
            service: StudioMCPServerModel.keychainService,
            account: StudioMCPServerModel.keychainAccount
        )
    ) {
        self.defaults = defaults
        self.pat = pat
        if defaults.object(forKey: Self.portKey) == nil {
            defaults.set(Int(StudioMCPWire.defaultPort), forKey: Self.portKey)
        }
    }

    // MARK: Persisted settings

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var port: UInt16 {
        get {
            let raw = defaults.integer(forKey: Self.portKey)
            guard raw > 0, raw <= Int(UInt16.max) else { return StudioMCPWire.defaultPort }
            return UInt16(raw)
        }
        set { defaults.set(Int(newValue), forKey: Self.portKey) }
    }

    /// The port actually being served, when the server is up; otherwise the
    /// configured one.
    var activePort: UInt16 {
        if case .running(let p) = state { return p }
        return port
    }

    // MARK: The PAT (Keychain)

    /// The stored PAT, or nil when none has been minted. Still never cached in a
    /// @Published property — the pane asks for it only when it copies/reveals —
    /// but the securityd round trip behind it is now paid once, not once per
    /// ask. See `StudioKeychainItem`.
    func storedPAT() -> String? {
        guard let value = pat.value() else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasPAT: Bool { storedPAT() != nil }

    /// Mint (or rotate) the PAT and persist it in the Keychain. Returns the new
    /// token. Rotating invalidates every client holding the old one.
    @discardableResult
    func regeneratePAT() -> String? {
        let token = StudioMCPWire.generatePAT()
        pat.set(token)
        // `set` caches only what securityd accepted, so a failed write leaves
        // the cache UNKNOWN and this read goes back to the keychain to find out.
        guard pat.value() == token else {
            note = "Could not write the token to the Keychain."
            AppLog.error("Studio MCP: keychain write failed")
            return nil
        }
        note = nil
        return token
    }

    func deletePAT() {
        pat.delete()
    }

    /// The connection line for the pane. `revealed: false` masks the token, so
    /// nothing renders a live secret unless the human asked for it.
    func connectionLine(revealed: Bool) -> String {
        let token = storedPAT() ?? ""
        let shown = revealed ? token : StudioMCPWire.mask(token)
        return StudioMCPWire.connectionLine(port: activePort, token: shown.isEmpty ? "<TOKEN>" : shown)
    }

    // MARK: Launch bootstrap

    /// Called once from `applicationDidFinishLaunching`. Resolves where the PAT
    /// comes from and starts the server — or does nothing at all, which is the
    /// documented default.
    ///
    /// Deliberately resolves the config BEFORE touching the engine: when MCP is
    /// off we must not force `StudioEngineFactory.shared` to materialize, or a
    /// plain launch would open the `.mstudio` package for no reason.
    func bootstrapAtLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) {
        if let flags = StudioMCPWire.parseLaunchFlags(arguments) {
            // The operator put the token on the command line, so it is already
            // visible to `ps`; logging the full, paste-ready line here is what
            // docs/MCP_API.md promises and costs no additional exposure.
            Task { await self.start(pat: flags.pat, port: flags.port, logTokenInClear: true) }
            return
        }

        guard isEnabled else {
            state = .off
            return
        }
        guard let pat = storedPAT() else {
            state = .off
            note = "MCP is enabled but no token exists yet. Generate one in Settings ▸ MCP / API."
            AppLog.info("Studio MCP: enabled but no PAT in the Keychain; not starting (fail closed).")
            return
        }
        Task { await self.start(pat: pat, port: port, logTokenInClear: false) }
    }

    // MARK: Lifecycle

    /// Start the engine's MCP server. Returns whether something is actually
    /// listening — a false return never leaves the UI claiming success.
    @discardableResult
    func start(pat: String, port requestedPort: UInt16, logTokenInClear: Bool) async -> Bool {
        let token = pat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            state = .failed("Refusing to start: the personal access token is empty.")
            AppLog.error("Studio MCP: refusing to start with an empty PAT (fail closed).")
            return false
        }
        let wantPort = requestedPort > 0 ? requestedPort : StudioMCPWire.defaultPort

        #if REAL_ENGINE
        state = .starting
        guard let engine = StudioEngineFactory.realEngine() else {
            let why = "The real Studio engine failed to initialize, so there is nothing to serve. See the log for the engine error."
            state = .unavailable(why)
            AppLog.error("Studio MCP: no real engine instance; server not started.")
            return false
        }
        if await engine.isMCPRunning() {
            // Already serving — a second bind would just fail with "address
            // already in use". Report the port it is ACTUALLY on, which is the
            // one we recorded when we started it, not the one just requested.
            let live = servingPort ?? wantPort
            state = .running(port: live)
            if live != wantPort {
                note = "The server is already running on port \(live). Turn it off and on again to move it to \(wantPort)."
            }
            startHealthPolling()
            return true
        }
        do {
            // The engine returns its own REDACTED snippet; we build the usable
            // one ourselves because only the host knows the clear token.
            let redacted = try await engine.startMCP(port: wantPort, pat: token, enabled: true)
            servingPort = wantPort
            state = .running(port: wantPort)
            note = nil
            if logTokenInClear {
                AppLog.info("Studio MCP server listening on 127.0.0.1:\(wantPort)\(StudioMCPWire.httpPath)")
                AppLog.info(StudioMCPWire.connectionLine(port: wantPort, token: token))
            } else {
                AppLog.info("Studio MCP server listening on 127.0.0.1:\(wantPort)\(StudioMCPWire.httpPath) — \(redacted)")
                AppLog.info("Copy the connection line from Settings ▸ MCP / API (the token is not logged).")
            }
            startHealthPolling()
            return true
        } catch {
            let message = String(describing: error)
            state = .failed(message)
            AppLog.error("Studio MCP: start failed — \(message)")
            return false
        }
        #else
        // No engine is linked in this build. Say so; never report success.
        state = .unavailable(Self.mockBuildReason)
        AppLog.error("Studio MCP: refused to start — this is a mock-engine build, no server exists.")
        return false
        #endif
    }

    /// Start using whatever is persisted (the Settings toggle path).
    @discardableResult
    func startFromSettings() async -> Bool {
        guard let pat = storedPAT() else {
            state = .failed("Generate a token first — the server refuses to start without one.")
            return false
        }
        return await start(pat: pat, port: port, logTokenInClear: false)
    }

    func stop() async {
        stopHealthPolling()
        #if REAL_ENGINE
        if let engine = StudioEngineFactory.realEngine() {
            await engine.stopMCP()
        }
        #endif
        servingPort = nil
        health = .unknown
        state = .off
        AppLog.info("Studio MCP server stopped.")
    }

    /// The Settings toggle. Persists first, then acts, so a crash mid-start
    /// still leaves the intent recorded.
    func setEnabled(_ on: Bool) async {
        isEnabled = on
        if on {
            if storedPAT() == nil { _ = regeneratePAT() }
            _ = await startFromSettings()
        } else {
            await stop()
        }
    }

    /// Restart onto a new port / new token. A running server keeps serving the
    /// old token until this completes.
    func restart() async {
        await stop()
        _ = await startFromSettings()
    }

    // MARK: Health

    /// Probe `GET /health` on the configured port. This is the one check that
    /// distinguishes "we called start and it returned" from "something is
    /// actually answering on the socket".
    func probeHealth() async {
        guard let url = StudioMCPWire.healthURL(port: activePort) else {
            health = .unreachable("bad port")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 200 && body == "ok" {
                health = .ok
            } else {
                health = .unreachable("HTTP \(code)\(body.isEmpty ? "" : " \u{2014} \(body)")")
            }
        } catch {
            health = .unreachable(error.localizedDescription)
        }
    }

    /// Poll health in the background while the server is meant to be up, so a
    /// server that died is not still shown as green.
    func startHealthPolling(interval: UInt64 = 5) {
        stopHealthPolling()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeHealth()
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
    }

    func stopHealthPolling() {
        healthTask?.cancel()
        healthTask = nil
    }
}
