import SwiftUI
import AppKit
import Foundation

// MARK: - Sign in with Unicorn Commander (Lane 1, Phase 2)
//
// OAuth 2.0 Device Authorization Grant (RFC 8628) against the uchub Keycloak
// realm, then a server-side key mint against Ops-Center, ported from Majik's DJ
// (src-tauri/src/uc_account.rs, verified 2026-07-24). Pure URLSession + SwiftUI,
// FFI-free.
//
// Flow: request a device code -> the person approves in a browser -> poll the
// token endpoint -> exchange the Keycloak access token for a per-user `uc_` key
// (minted once, server-side; the KC token is never persisted) -> store the key in
// the SAME Keychain item the Sterling backend already reads, and point the
// endpoint at the authed gateway. BYO endpoint+key stays as the Advanced fallback.
//
// Endpoint reality (brief, verified 2026-07-24): the CF host's /v1/chat/completions
// CSRF-blocks POSTs; the `uc_` path https://api.unicorncommander.ai/api/v1/llm is
// 200, so that is the endpoint we set. Sterling then POSTs .../api/v1/llm/chat/
// completions and the model list GETs .../api/v1/llm/models.
//
// Keychain note (two-tier discipline): the DJ stores the key across a shared
// data-protection keychain (access group 69CT7K6PWR.ai.unicorncommander.majiks.
// shared) with a legacy login-keychain fallback. This lane adds the app-side
// Keychain-Sharing entitlement file (`MajiksMusicStudio.entitlements`) so a
// signed build can join the suite-wide group; the runtime query path still uses
// the existing single-tier SterlingKeychain item until the full suite adopts the
// shared access-group read/write path.

@MainActor
final class UnicornAccountModel: ObservableObject {
    // Constants (uc_account.rs:39-64), retargeted to the Music Studio client.
    static let authBase = "https://auth.unicorncommander.ai/realms/uchub"
    static let apiBase = "https://api.unicorncommander.ai"
    /// The Keycloak public device-grant client.
    ///
    /// NOT `majiks-studio`, which this shipped with and which could never have
    /// worked: in the uchub realm that client is CONFIDENTIAL (publicClient
    /// false, so it expects a secret this app does not have) and has
    /// `oauth2.device.authorization.grant.enabled` unset. A public-style device
    /// request against it is a guaranteed `unauthorized_client` - verified live
    /// 2026-07-25, HTTP 401 {"error":"unauthorized_client"}. It could not simply
    /// be flipped to public: it also carries standard flow + web redirects for
    /// majiks.studio, and removing its secret would break that.
    ///
    /// `majiks-music-studio` is a dedicated PUBLIC client added alongside it,
    /// mirroring `majiks-dj` (the one native app in this realm whose device flow
    /// already works). Verified live: POST .../auth/device returns HTTP 200 with
    /// user_code, device_code, verification_uri_complete, interval 5,
    /// expires_in 600.
    static let clientID = "majiks-music-studio"
    static let llmEndpoint = "https://api.unicorncommander.ai/api/v1/llm"

    // MARK: the minted key's identity
    //
    // The mint used to POST an EMPTY body and take the server's defaults. That
    // was not a neutral choice, because of what the endpoint documents itself as
    // doing: "One live key per app name: any active keys with the same `name`
    // owned by the caller are revoked in the same transaction" - and
    // MintViaTokenRequest defaults `name` to `majiks-dj` (verified against the
    // published schema at api.unicorncommander.ai/openapi.json, 2026-07-25).
    // So Music Studio minted its key UNDER MAJIK'S DJ'S NAME and revoked the DJ's
    // live key on the way past. Ops-Center logged it: "replaced 1 prior
    // 'majiks-dj' key(s)". Signing into one app signed you out of another.

    /// The app name this key is minted under. Matches this app's Keycloak client
    /// id, the same way `majiks-dj`'s key name matches its client - so the two
    /// apps own two separate key rows and stop revoking each other.
    static let keyName = "majiks-music-studio"

    /// Sent explicitly for the same reason the name is. These ARE the schema's
    /// published defaults as of 2026-07-25, but a default is a value someone
    /// else can change without telling us, and inheriting one silently is the
    /// exact root cause above. Pinning them means a server-side change shows up
    /// as a deliberate edit here rather than as a live behaviour change.
    static let keyExpiresInDays = 90
    static let keyPermissions = ["llm:inference", "llm:models"]

    /// The mint request body. Split out so a test can pin it against the
    /// published MintViaTokenRequest schema without making a network call.
    static func mintRequestBody() -> [String: Any] {
        [
            "name": keyName,
            "expires_in_days": keyExpiresInDays,
            "permissions": keyPermissions,
        ]
    }

    private static let signedInKey = "sterling.uc.signedIn"
    private static let emailKey = "sterling.uc.email"
    private static let tierKey = "sterling.uc.tier"

    @Published private(set) var busy = false
    @Published private(set) var userCode: String?
    @Published private(set) var verificationURL: String?
    @Published private(set) var signedIn = false
    @Published private(set) var email: String?
    @Published private(set) var tier: String?
    @Published private(set) var credits: Double?
    @Published private(set) var error: String?
    /// Result of the connection check run right after a successful mint. Signing
    /// in repoints Sterling at a DIFFERENT gateway while leaving the model id
    /// alone, so "signed in" is not by itself proof that a turn will run - the
    /// new endpoint may not serve the model that is set. Same silent-degradation
    /// rule as the BYO pane: prove it now, not at first use.
    @Published private(set) var probeOutcome: SterlingProbeOutcome?
    @Published private(set) var probing = false
    /// What the configured model turned out to be worth on THIS account's
    /// gateway. Sign-in carries the existing model id across untouched, and the
    /// account may not serve it - that is how a successful mint was still
    /// followed by a 400 on the very first turn. Reporting that accurately was
    /// not enough; this is the state that lets the pane offer the fix.
    @Published private(set) var modelResolution: SterlingModelResolution?
    @Published private(set) var reconcilingModel = false
    /// The account's full published catalog, so "show me everything it serves"
    /// costs no second round trip.
    @Published private(set) var servedModels: [SterlingGatewayModel] = []

    private var flow: Task<Void, Never>?

    init() {
        signedIn = UserDefaults.standard.bool(forKey: Self.signedInKey) && SterlingKeychain.hasKey
        email = UserDefaults.standard.string(forKey: Self.emailKey)
        tier = UserDefaults.standard.string(forKey: Self.tierKey)
    }

    func refreshStatus() async {
        signedIn = UserDefaults.standard.bool(forKey: Self.signedInKey) && SterlingKeychain.hasKey
        guard signedIn, let key = SterlingKeychain.key() else { credits = nil; return }
        if let (remaining, tierName) = try? await Self.fetchCredits(key: key) {
            credits = remaining
            if let tierName { tier = tierName; UserDefaults.standard.set(tierName, forKey: Self.tierKey) }
        }
    }

    /// Begin the device flow. Requests a code, opens the browser, and polls.
    func startSignIn() {
        guard !busy else { return }
        busy = true
        error = nil
        userCode = nil
        verificationURL = nil
        flow = Task { await runFlow() }
    }

    func cancel() {
        flow?.cancel()
        flow = nil
        busy = false
        userCode = nil
        verificationURL = nil
    }

    func signOut() {
        let key = SterlingKeychain.key()
        flow?.cancel()
        SterlingKeychain.deleteKey()
        UserDefaults.standard.set(false, forKey: Self.signedInKey)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        UserDefaults.standard.removeObject(forKey: Self.tierKey)
        signedIn = false
        email = nil
        tier = nil
        credits = nil
        busy = false
        userCode = nil
        verificationURL = nil
        probeOutcome = nil
        modelResolution = nil
        servedModels = []
        // Best-effort server-side revoke; local sign-out already took effect.
        // `revoke-self` revokes exactly the key presented as the bearer, so this
        // cannot reach the key any other app minted (published behaviour,
        // verified 2026-07-25) - which is the property the named mint restores.
        if let key {
            Task.detached { try? await Self.revoke(key: key) }
        }
    }

    // MARK: endpoint precedence
    //
    // DECIDED: while you are signed in, YOUR ACCOUNT'S GATEWAY IS THE ONE THAT
    // SHOULD BE IN FORCE. Sign-in writes `llmEndpoint` into the same
    // sterling.endpoint the Advanced form edits, so the last write wins - and
    // the dangerous order is signing in and THEN leaving a manual endpoint in
    // place, because the two providers take different key families (`uc_` here,
    // `sk-` for a LiteLLM proxy) and the mismatch surfaces as a flat 401 in a
    // different tab. Rather than silently forcing the endpoint back on every
    // render (which would fight a deliberate BYO choice), the pane SAYS the
    // manual endpoint is overriding the account and offers one click to undo it.

    /// True when sterling.endpoint is the account gateway (trailing slash and
    /// surrounding space ignored).
    static func isSignedInGateway(_ endpoint: String) -> Bool {
        func normalize(_ value: String) -> String {
            var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            return trimmed.lowercased()
        }
        return normalize(endpoint) == normalize(llmEndpoint)
    }

    /// Signed in, but Sterling is aimed somewhere else - the state that produces
    /// a `uc_` key at an `sk-` gateway.
    var manualEndpointOverridesAccount: Bool {
        signedIn && !Self.isSignedInGateway(SterlingConfig.endpoint)
    }

    /// Put Sterling back on the account gateway and prove it.
    func useAccountGateway() async {
        SterlingConfig.endpoint = Self.llmEndpoint
        await reconcileModel()
        await runProbe()
    }

    // MARK: model reconciliation
    //
    // DECIDED: sign-in ASKS the account what it serves, and changes the model
    // only when there is exactly one thing it could mean. Three rules, in order:
    //
    //   1. The configured model is on the list -> leave it completely alone.
    //   2. It is on the list under the routing prefix the gateway requires, and
    //      only one candidate matches -> adopt that id and SAY so in the pane.
    //      Same model, the name this gateway files it under; that is a spelling
    //      correction, not a substitution.
    //   3. Anything else - unserved, ambiguous between machines, or nothing
    //      configured at all -> change NOTHING and offer a picker of what the
    //      account really publishes, closest first.
    //
    // The third case is the one that matters and the one a guess would ruin.
    // The model that was actually set, `qwen3.6-35b`, is served by nothing on
    // this API; the nearest things are `uc/chat-default` ("Majik Local - Qwen
    // 3.6 35B MoE") and `qwen/qwen3.6-flash`, which are a local MoE and a hosted
    // flash model - different machines, different cost, not interchangeable.
    // Picking one for someone would be a silent config rewrite that happens to
    // be wrong half the time. Offering both, in one click, ends sign-in with a
    // working assistant without pretending to know which they meant.

    /// Read the account's catalog and reconcile the configured model against it.
    /// Adopts only an unambiguous match; never invents an id.
    func reconcileModel() async {
        guard !reconcilingModel else { return }
        reconcilingModel = true
        defer { reconcilingModel = false }

        let endpoint = SterlingConfig.endpoint
        let configured = SterlingConfig.model
        do {
            let page = try await SterlingModelCatalog.fetchPage(
                endpoint: endpoint, apiKey: SterlingKeychain.key())
            servedModels = page.models
            let resolution = SterlingModelReconciler.resolve(configured: configured, page: page)
            if case .adopted(_, let to) = resolution {
                SterlingConfig.model = to
            }
            modelResolution = resolution
        } catch {
            // A catalog we could not read proves nothing about the model. Say
            // that, rather than accusing a model that may be perfectly fine.
            servedModels = []
            modelResolution = .undetermined(
                reason: "Sterling could not read the model list from your account (\(error.localizedDescription)).")
        }
    }

    /// Adopt a model the person picked from the account's own list, then prove it.
    func selectModel(_ id: String) async {
        SterlingConfig.model = id
        modelResolution = .served(id)
        await runProbe()
    }

    /// One real completion against the endpoint sign-in just set, with the model
    /// that is currently configured. The minted key goes from the Keychain to the
    /// Authorization header and is never held here.
    func runProbe() async {
        guard !probing else { return }
        probing = true
        probeOutcome = nil
        let outcome = await SterlingConnectionProbe.run(
            endpoint: SterlingConfig.endpoint,
            model: SterlingConfig.model,
            key: SterlingKeychain.key())
        probeOutcome = outcome
        probing = false
    }

    // MARK: flow

    private func runFlow() async {
        defer { busy = false }
        do {
            let device = try await Self.requestDeviceCode()
            guard !Task.isCancelled else { return }
            userCode = device.userCode
            verificationURL = device.verificationURIComplete ?? device.verificationURI
            if let urlString = verificationURL, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }

            let token = try await pollForToken(device: device)
            guard !Task.isCancelled else { return }

            let minted = try await Self.mintKey(accessToken: token)
            guard minted.apiKey.hasPrefix("uc_") else {
                throw AccountError.message("The gateway returned an unexpected key.")
            }

            // Land the key where the Sterling backend already reads it, and point
            // the endpoint at the authed gateway.
            SterlingKeychain.setKey(minted.apiKey)
            SterlingConfig.endpoint = Self.llmEndpoint
            // An empty model used to be filled in with a hardcoded id. That id
            // (`qwen3.6-35b`) is not served here, so the "default" handed every
            // first-time user a broken configuration. What the account serves is
            // reconciliation's answer to give, below - not a constant's.
            UserDefaults.standard.set(true, forKey: Self.signedInKey)
            if let email = minted.email {
                UserDefaults.standard.set(email, forKey: Self.emailKey)
                self.email = email
            }
            if let tierName = minted.tier {
                UserDefaults.standard.set(tierName, forKey: Self.tierKey)
                self.tier = tierName
            }
            credits = minted.creditsRemaining
            signedIn = true
            userCode = nil
            verificationURL = nil
            // Reconcile BEFORE probing, so the probe tests the model this
            // account can actually run rather than re-proving the one it cannot.
            await reconcileModel()
            await runProbe()
        } catch is CancellationError {
            // user cancelled; nothing to report
        } catch {
            if !Task.isCancelled {
                self.error = (error as? AccountError)?.text ?? error.localizedDescription
            }
        }
    }

    /// Poll the token endpoint honoring the server's own cadence: sleep the
    /// `interval` it returned (live: 5s) between polls, add 5s on every
    /// `slow_down` per RFC 8628 §3.5, and give up at `expires_in` (live: 600s).
    /// The four non-token outcomes stay four different sentences - "still
    /// waiting", "you declined", "the code aged out", and "back off" are not the
    /// same event and must not read as one.
    private func pollForToken(device: DeviceAuth) async throws -> String {
        var interval = max(1, device.interval)
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        let minutes = max(1, device.expiresIn / 60)
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            if Date() > deadline {
                throw AccountError.message("Sign-in timed out after \(minutes) minutes without approval. Start again and approve the code in the browser.")
            }
            switch try await Self.pollToken(deviceCode: device.deviceCode) {
            case .pending:
                continue
            case .slowDown:
                interval += 5
            case .denied:
                throw AccountError.message("The sign-in was declined in the browser. Nothing changed here.")
            case .expired:
                throw AccountError.message("The sign-in code expired before it was approved. Start again and approve it within \(minutes) minutes.")
            case .token(let accessToken):
                return accessToken
            }
        }
    }

    // MARK: HTTP (device grant + mint + credits + revoke)

    struct DeviceAuth {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let verificationURIComplete: String?
        let interval: Int
        let expiresIn: Int
    }

    struct MintedKey {
        let apiKey: String
        let email: String?
        let tier: String?
        let creditsRemaining: Double?
    }

    enum PollResult { case pending, slowDown, denied, expired, token(String) }

    enum AccountError: Error {
        case message(String)
        var text: String { if case .message(let m) = self { return m }; return "Sign-in failed." }
    }

    static func requestDeviceCode() async throws -> DeviceAuth {
        let url = URL(string: "\(authBase)/protocol/openid-connect/auth/device")!
        let body = formEncode(["client_id": clientID, "scope": "openid profile email"])
        // Read the body on failure instead of discarding it. Throwing a bare
        // "Request failed (HTTP 401)" here is what made a pure server
        // MISCONFIGURATION look to the person like their account was refused.
        let (data, http) = try await postFormRaw(url: url, body: body, bearer: nil)
        return try parseDeviceAuth(status: http.statusCode, data: data)
    }

    /// Pure: the device-code response. Split from the request so both legs - the
    /// real 200 and the real `unauthorized_client` 401 - can be pinned in tests.
    static func parseDeviceAuth(status: Int, data: Data) throws -> DeviceAuth {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(status) else {
            throw AccountError.message(signInFailureMessage(
                status: status,
                error: obj["error"] as? String,
                description: obj["error_description"] as? String))
        }
        guard let deviceCode = obj["device_code"] as? String,
              let userCode = obj["user_code"] as? String,
              let verificationURI = obj["verification_uri"] as? String else {
            throw AccountError.message("The sign-in service returned an unexpected response.")
        }
        return DeviceAuth(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            verificationURIComplete: obj["verification_uri_complete"] as? String,
            interval: (obj["interval"] as? NSNumber)?.intValue ?? 5,
            expiresIn: (obj["expires_in"] as? NSNumber)?.intValue ?? 600
        )
    }

    static func pollToken(deviceCode: String) async throws -> PollResult {
        let url = URL(string: "\(authBase)/protocol/openid-connect/token")!
        let body = formEncode([
            "client_id": clientID,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode,
        ])
        let (data, http) = try await postFormRaw(url: url, body: body, bearer: nil)
        return try classifyTokenResponse(status: http.statusCode, data: data)
    }

    /// Pure: what one poll of the token endpoint means. Split from the request so
    /// it can be pinned against real captured responses - the pending leg is a
    /// 400 carrying `authorization_pending`, which a status-code-only reading
    /// would mistake for a hard failure.
    static func classifyTokenResponse(status: Int, data: Data) throws -> PollResult {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let token = obj["access_token"] as? String, !token.isEmpty { return .token(token) }
        let err = (obj["error"] as? String) ?? ""
        switch err {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token": return .expired
        default:
            if (200...299).contains(status) { return .pending }
            throw AccountError.message(signInFailureMessage(
                status: status,
                error: err.isEmpty ? nil : err,
                description: obj["error_description"] as? String))
        }
    }

    /// An OAuth error code is a diagnosis, not a verdict on the person. The one
    /// that matters here is `unauthorized_client`: it means this app is not
    /// allowed to use the device grant - a server configuration problem - and
    /// rendering it as a bare 401 tells someone whose account is perfectly fine
    /// that they were refused. Each code gets its own sentence; none of them
    /// collapse into "Sign-in failed".
    static func signInFailureMessage(status: Int, error: String?, description: String?) -> String {
        let detail = (description?.isEmpty == false) ? " (\(description!))" : ""
        switch error {
        case "unauthorized_client", "invalid_client":
            // Deliberately does NOT say "unauthorized" - nothing about the
            // person was checked at this point in the flow.
            return "Sign-in is not enabled for this app on the Unicorn Commander server, so it never got as far as your account. The `\(clientID)` client in the uchub realm has to be a public client with the device-authorization grant turned on. Nothing you can fix from here; the Advanced endpoint below still works.\(detail)"
        case "invalid_request":
            return "The sign-in server rejected the request as malformed. This is an app or server configuration problem, not your account.\(detail)"
        case "invalid_scope":
            return "The sign-in server does not offer the permissions this app asked for. A server configuration problem.\(detail)"
        case "server_error", "temporarily_unavailable":
            return "The sign-in server is having trouble right now. Try again shortly.\(detail)"
        case .some(let code) where !code.isEmpty:
            return "Sign-in failed: \(code).\(detail)"
        default:
            return "Sign-in failed (HTTP \(status)).\(detail)"
        }
    }

    /// The mint request exactly as it goes on the wire.
    ///
    /// Built here rather than inline so a test can read the BODY THAT IS
    /// ACTUALLY SENT. Pinning the body dictionary on its own is not enough: it
    /// would still pass if this call site went back to posting `[:]`, and
    /// posting `[:]` IS the bug.
    static func mintRequest(accessToken: String) throws -> URLRequest {
        let url = URL(string: "\(apiBase)/api/v1/account/uc-api-keys/mint-via-token")!
        return try jsonRequest(url: url, json: mintRequestBody(), bearer: accessToken, timeout: 30)
    }

    static func mintKey(accessToken: String) async throws -> MintedKey {
        let obj = try await send(mintRequest(accessToken: accessToken))
        guard let apiKey = obj["api_key"] as? String else {
            throw AccountError.message("The gateway did not return a key.")
        }
        return MintedKey(
            apiKey: apiKey,
            email: obj["email"] as? String,
            tier: obj["tier"] as? String,
            creditsRemaining: (obj["credits_remaining"] as? NSNumber)?.doubleValue
        )
    }

    static func fetchCredits(key: String) async throws -> (Double?, String?) {
        let url = URL(string: "\(apiBase)/api/v1/llm/credits/me")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((obj["credits_remaining"] as? NSNumber)?.doubleValue, obj["tier"] as? String)
    }

    static func revoke(key: String) async throws {
        let url = URL(string: "\(apiBase)/api/v1/account/uc-api-keys/revoke-self")!
        _ = try? await postJSON(url: url, json: [:], bearer: key, timeout: 12)
    }

    // MARK: request helpers

    static func formEncode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    static func postFormRaw(url: URL, body: Data, bearer: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AccountError.message("No response from the sign-in service.")
        }
        return (data, http)
    }

    /// Build a JSON POST. Split from sending so the composed request - headers
    /// and body both - can be inspected without a network call.
    static func jsonRequest(url: URL, json: [String: Any], bearer: String?, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return request
    }

    static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AccountError.message("Request failed (HTTP \(code)).")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func postJSON(url: URL, json: [String: Any], bearer: String?, timeout: TimeInterval) async throws -> [String: Any] {
        try await send(jsonRequest(url: url, json: json, bearer: bearer, timeout: timeout))
    }
}

// MARK: - Sign-in section (main Settings "Sterling" tab)

struct UnicornSignInSection: View {
    @ObservedObject var account: UnicornAccountModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Unicorn Commander account", systemImage: "person.badge.key")
                .font(.subheadline).fontWeight(.semibold)

            if account.signedIn {
                signedInBody
            } else if account.userCode != nil {
                waitingBody
            } else {
                signedOutBody
            }

            if let error = account.error {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06))
        .cornerRadius(8)
        .task { await account.refreshStatus() }
    }

    private var signedOutBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in to use the Unicorn Commander gateway - the LLM list and (when provisioned) Brigade agents come from your authed account. No key to paste; the manual endpoint below stays available as an Advanced fallback.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                account.startSignIn()
            } label: {
                Label("Sign in with Unicorn Commander", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(account.busy)
        }
    }

    private var waitingBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Approve in your browser, then come back.").font(.caption)
            }
            if let code = account.userCode {
                HStack(spacing: 6) {
                    Text("Code:").font(.caption).foregroundColor(.secondary)
                    Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            HStack(spacing: 12) {
                if let urlString = account.verificationURL, let url = URL(string: urlString) {
                    Button("Open sign-in page") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button("Cancel") { account.cancel() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private var signedInBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text(account.email ?? "Signed in").font(.callout).fontWeight(.medium)
            }
            HStack(spacing: 12) {
                if let tier = account.tier {
                    Text("Tier: \(tier)").font(.caption).foregroundColor(.secondary)
                }
                if let credits = account.credits {
                    Text(String(format: "Credits: $%.2f", credits)).font(.caption).foregroundColor(.secondary)
                }
            }
            if account.manualEndpointOverridesAccount {
                // The exact state that turns a good account into a flat 401.
                VStack(alignment: .leading, spacing: 6) {
                    Label("The Advanced endpoint below is overriding your account.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).fontWeight(.semibold).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Sterling is signed in with a key from your Unicorn Commander account, but it is sending that key to \(SterlingConfig.endpoint) instead of \(UnicornAccountModel.llmEndpoint). Those are different gateways and they take different kinds of key, so the request will be refused.")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Use my account's gateway") { Task { await account.useAccountGateway() } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                Text("Sterling is pointed at \(UnicornAccountModel.llmEndpoint). While you are signed in this is the gateway in force; changing the Advanced endpoint below overrides it.")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Signed in is not the same as working: this gateway serves its own
            // model list, and the model set for Sterling carries over unchanged.
            SterlingModelResolutionView(
                reconciling: account.reconcilingModel,
                resolution: account.modelResolution,
                allModels: account.servedModels,
                onSelect: { id in Task { await account.selectModel(id) } })
            SterlingProbeResultView(probing: account.probing, outcome: account.probeOutcome)
            HStack(spacing: 10) {
                Button("Test connection") { Task { await account.runProbe() } }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(account.probing)
                Button("Sign out") { account.signOut() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

// MARK: - Model reconciliation result + picker

/// The block that turns "your model does not exist here" from a complaint into a
/// choice. Renders what reconciliation decided and, when a decision is still
/// owed, the models the account actually publishes - closest first, one click.
///
/// LAYOUT NOTE: the candidates are a VERTICAL stack and the full catalog is a
/// Menu. A row of model chips in a horizontal ScrollView is the obvious shape
/// for this and is exactly the one that must not be used: on macOS the scroll
/// view swallows the buttons' hit testing and every chip silently stops
/// responding (documented in SettingsView.swift).
struct SterlingModelResolutionView: View {
    let reconciling: Bool
    let resolution: SterlingModelResolution?
    let allModels: [SterlingGatewayModel]
    let onSelect: (String) -> Void

    var body: some View {
        Group {
            if reconciling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking which models your account serves…")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else if let resolution {
                switch resolution {
                case .served:
                    EmptyView()  // nothing to say; the probe speaks for it

                case .adopted(let from, let to):
                    // Changed underneath them - so it is stated, not hidden.
                    Label("Sterling's model was \"\(from)\"; your account serves it as \"\(to)\", so that is what is set now.",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .ambiguous(let configured, let candidates):
                    chooser(
                        headline: "Your account serves \"\(configured)\" on more than one machine.",
                        detail: "They are the same model with different routing, cost, and speed, so Sterling will not pick for you.",
                        candidates: candidates)

                case .notServed(let configured, let candidates):
                    chooser(
                        headline: "Your account does not serve \"\(configured)\".",
                        detail: "Sterling is signed in and the gateway is reachable, but that model id would fail on the first turn. Pick one your account actually offers:",
                        candidates: candidates)

                case .unset(let candidates):
                    chooser(
                        headline: "No model is set for Sterling yet.",
                        detail: "Pick one your account serves:",
                        candidates: candidates)

                case .undetermined(let reason):
                    Label(reason, systemImage: "questionmark.circle")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooser(headline: String, detail: String, candidates: [SterlingGatewayModel]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(headline, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).fontWeight(.semibold).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(candidates) { model in
                Button { onSelect(model.id) } label: {
                    HStack(spacing: 6) {
                        Text(model.id).font(.system(.caption, design: .monospaced))
                        if model.isFree {
                            Text("FREE").font(.caption2).fontWeight(.semibold).foregroundColor(.green)
                        } else if let price = model.priceLabel {
                            Text(price).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !allModels.isEmpty {
                Menu("All \(allModels.count) models on your account") {
                    ForEach(allModels) { model in
                        Button(menuLabel(for: model)) { onSelect(model.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption)
            }
        }
    }

    private func menuLabel(for model: SterlingGatewayModel) -> String {
        let name = model.displayName.isEmpty ? model.id : model.displayName
        if model.isFree { return "\(name) — FREE" }
        if let price = model.priceLabel { return "\(name) — \(price)" }
        return name
    }
}
