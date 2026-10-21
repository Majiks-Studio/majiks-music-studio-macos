import Testing
import Foundation
@testable import MajiksMusicStudio

// Contract locks for "Sign in with Unicorn Commander" (OAuth 2.0 Device
// Authorization Grant, RFC 8628).
//
// Every fixture is a body CAPTURED LIVE from auth.unicorncommander.ai (realm
// uchub) on 2026-07-25:
//
//   * deviceGrantUnauthorizedClient - POST .../auth/device with the client id
//     this app SHIPPED with (`majiks-studio`). HTTP 401. That client is
//     confidential and has the device grant disabled, so the flow could never
//     have worked for anyone; the app then rendered it as a bare "Request failed
//     (HTTP 401)", which reads as "your account was refused" when in fact
//     nothing about the account was ever checked.
//   * deviceGrantOK - the same POST with the dedicated public client
//     (`majiks-music-studio`). HTTP 200. Values are replaced with same-shaped
//     placeholders; the FIELD SET and the numeric interval/expires_in are as the
//     server returned them.
//   * tokenAuthorizationPending - one poll of the token endpoint for an
//     unapproved code. Note it is an HTTP 400: reading the status alone would
//     turn "still waiting for the human" into a hard failure.
//
// The token leg past approval (device_code -> access_token) is NOT covered here
// and has never been exercised by anyone: it cannot be reached without a person
// approving the code in a browser.

@MainActor
@Suite("Unicorn Commander sign-in")
struct UnicornAccountTests {

    static let deviceGrantUnauthorizedClient = #"{"error":"unauthorized_client","error_description":"Invalid client or Invalid client credentials"}"#
    static let deviceGrantOK = #"{"device_code":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","user_code":"ABCD-EFGH","verification_uri":"https://auth.unicorncommander.ai/realms/uchub/device","verification_uri_complete":"https://auth.unicorncommander.ai/realms/uchub/device?user_code=ABCD-EFGH","expires_in":600,"interval":5}"#
    static let tokenAuthorizationPending = #"{"error":"authorization_pending","error_description":"The authorization request is still pending"}"#

    // MARK: the client id

    @Test("the app uses the dedicated public device-grant client")
    func clientID() {
        // `majiks-studio` is confidential with the device grant off; using it is
        // a guaranteed unauthorized_client. Pinned so a revert is loud.
        #expect(UnicornAccountModel.clientID == "majiks-music-studio")
    }

    // MARK: device-code leg

    @Test("the real 200 device-code response parses, cadence included")
    func parsesRealDeviceGrant() throws {
        let auth = try UnicornAccountModel.parseDeviceAuth(
            status: 200, data: Data(Self.deviceGrantOK.utf8))
        #expect(!auth.deviceCode.isEmpty)
        #expect(!auth.userCode.isEmpty)
        #expect(auth.verificationURIComplete != nil)
        // The poll loop's whole cadence comes from these two.
        #expect(auth.interval == 5)
        #expect(auth.expiresIn == 600)
    }

    @Test("unauthorized_client reads as a server misconfiguration, not a refusal")
    func unauthorizedClientIsNotAboutTheUser() {
        var message = ""
        do {
            _ = try UnicornAccountModel.parseDeviceAuth(
                status: 401, data: Data(Self.deviceGrantUnauthorizedClient.utf8))
            Issue.record("a 401 device-code response must not parse as success")
        } catch {
            message = (error as? UnicornAccountModel.AccountError)?.text ?? "\(error)"
        }

        // The bug being fixed: this must not surface as a bare HTTP code, and
        // must not tell a person with a fine account that they were refused.
        #expect(!message.contains("HTTP 401"))
        #expect(!message.lowercased().contains("unauthorized"))
        #expect(!message.lowercased().contains("denied"))
        // It must name the real problem and leave a way forward.
        #expect(message.contains("not enabled"))
        #expect(message.contains(UnicornAccountModel.clientID))
        #expect(message.contains("Advanced"))
    }

    @Test("the OAuth failure codes do not collapse into one sentence")
    func failureCodesStayDistinct() {
        let messages = [
            UnicornAccountModel.signInFailureMessage(status: 401, error: "unauthorized_client", description: nil),
            UnicornAccountModel.signInFailureMessage(status: 400, error: "invalid_request", description: nil),
            UnicornAccountModel.signInFailureMessage(status: 400, error: "invalid_scope", description: nil),
            UnicornAccountModel.signInFailureMessage(status: 503, error: "temporarily_unavailable", description: nil),
            UnicornAccountModel.signInFailureMessage(status: 500, error: nil, description: nil),
        ]
        #expect(Set(messages).count == messages.count)
    }

    @Test("an error_description is kept, not dropped")
    func descriptionSurvives() {
        let message = UnicornAccountModel.signInFailureMessage(
            status: 401,
            error: "unauthorized_client",
            description: "Invalid client or Invalid client credentials")
        #expect(message.contains("Invalid client or Invalid client credentials"))
    }

    // MARK: polling leg

    @Test("a real authorization_pending 400 is 'still waiting', not a failure")
    func pendingIsNotAFailure() throws {
        let result = try UnicornAccountModel.classifyTokenResponse(
            status: 400, data: Data(Self.tokenAuthorizationPending.utf8))
        guard case .pending = result else {
            Issue.record("an unapproved poll must read as pending")
            return
        }
    }

    @Test("the four poll states stay four states")
    func pollStatesStayDistinct() throws {
        func classify(_ code: String) throws -> UnicornAccountModel.PollResult {
            try UnicornAccountModel.classifyTokenResponse(
                status: 400, data: Data(#"{"error":"\#(code)"}"#.utf8))
        }
        guard case .pending = try classify("authorization_pending") else {
            Issue.record("authorization_pending"); return
        }
        guard case .slowDown = try classify("slow_down") else {
            Issue.record("slow_down"); return
        }
        guard case .denied = try classify("access_denied") else {
            Issue.record("access_denied"); return
        }
        guard case .expired = try classify("expired_token") else {
            Issue.record("expired_token"); return
        }
    }

    @Test("an access_token ends the poll")
    func tokenWins() throws {
        let result = try UnicornAccountModel.classifyTokenResponse(
            status: 200, data: Data(#"{"access_token":"header.payload.signature"}"#.utf8))
        guard case .token(let value) = result else {
            Issue.record("an access_token must end the poll")
            return
        }
        #expect(!value.isEmpty)
    }

    @Test("an unknown OAuth error is raised, not swallowed as pending")
    func unknownErrorRaises() {
        #expect(throws: UnicornAccountModel.AccountError.self) {
            _ = try UnicornAccountModel.classifyTokenResponse(
                status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
    }

    // MARK: endpoint precedence

    @Test("the account gateway is recognized regardless of trailing slash or case")
    func gatewayRecognition() {
        #expect(UnicornAccountModel.isSignedInGateway(UnicornAccountModel.llmEndpoint))
        #expect(UnicornAccountModel.isSignedInGateway(UnicornAccountModel.llmEndpoint + "/"))
        #expect(UnicornAccountModel.isSignedInGateway("  \(UnicornAccountModel.llmEndpoint)  "))
        // The endpoint that was actually configured when Sterling died: a
        // LiteLLM proxy, a different provider with a different key family.
        #expect(!UnicornAccountModel.isSignedInGateway("http://100.126.207.157:4000/v1"))
        #expect(!UnicornAccountModel.isSignedInGateway(""))
    }

    @Test("signing in points Sterling at a gateway that takes the key it mints")
    func mintedKeyMatchesTheGateway() {
        // The mint asserts a `uc_` key (runFlow), and `uc_` is the family the
        // account gateway accepts - so the pair is coherent. A LiteLLM endpoint
        // is not, which is what the precedence warning exists to catch.
        #expect(SterlingEndpointContext.keyFamily(for: "uc_example_key_value") == "uc_")
        #expect(UnicornAccountModel.llmEndpoint.contains("api.unicorncommander.ai"))
    }

    // MARK: the mint body
    //
    // Pinned against the PUBLISHED MintViaTokenRequest schema, read from
    // https://api.unicorncommander.ai/openapi.json on 2026-07-25 (public, no
    // auth). Reproduced exactly:
    //
    //   name            string  1..255   default "majiks-dj"
    //                   "App key name (one live key per name)"
    //   expires_in_days integer 1..3650  default 90     (nullable)
    //   permissions     [string]         default ["llm:inference","llm:models"]
    //
    // and the endpoint's own description: "One live key per app name: any active
    // keys with the same `name` owned by the caller are revoked in the same
    // transaction". The mint posted an EMPTY body, inherited `majiks-dj`, and so
    // revoked Majik's DJ's live key every time someone signed into Music Studio.

    /// The schema's default, quoted here so the test that rejects it is reading
    /// the real value rather than a remembered one.
    static let mintNameServerDefault = "majiks-dj"

    @Test("the mint names THIS app, not the schema's default")
    func mintNamesThisApp() throws {
        let body = UnicornAccountModel.mintRequestBody()
        let name = try #require(body["name"] as? String)

        // The whole defect in one line: inheriting the default mints Music
        // Studio's key under the DJ's name and revokes the DJ's key with it.
        #expect(name != Self.mintNameServerDefault)
        #expect(name == "majiks-music-studio")
        // And it must match the client this app authenticates as, so the two
        // apps own two separate rows.
        #expect(name == UnicornAccountModel.clientID)
    }

    @Test("the mint body is not empty - a name really is sent")
    func mintBodySerializesWithAName() throws {
        // The bug was `json: [:]`. Assert on the bytes that go on the wire, so a
        // revert to an empty body fails here even if the constant survives.
        let data = try JSONSerialization.data(withJSONObject: UnicornAccountModel.mintRequestBody())
        let round = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(!round.isEmpty)
        #expect(round["name"] as? String == "majiks-music-studio")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(Self.mintNameServerDefault))
    }

    @Test("the request that goes on the wire names this app")
    func mintRequestBodyOnTheWireNamesThisApp() throws {
        // The defect was at the CALL SITE (`json: [:]`), not in a constant, so
        // this reads the composed URLRequest's own body. Not a credential: the
        // bearer below is a placeholder string.
        let request = try UnicornAccountModel.mintRequest(accessToken: "placeholder.access.token")

        let body = try #require(request.httpBody)
        #expect(!body.isEmpty)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["name"] as? String == "majiks-music-studio")
        #expect(sent["name"] as? String != Self.mintNameServerDefault)
        #expect(sent["expires_in_days"] as? Int == UnicornAccountModel.keyExpiresInDays)
        #expect(sent["permissions"] as? [String] == UnicornAccountModel.keyPermissions)

        // And it is the mint endpoint, posted as JSON.
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/account/uc-api-keys/mint-via-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("every field the schema defaults is sent explicitly and in range")
    func mintBodyPinsTheSchemaDefaults() throws {
        let body = UnicornAccountModel.mintRequestBody()

        // Relying on a remote default is the root cause; there must not be a
        // second instance of it. All three settable fields are stated.
        #expect(Set(body.keys) == ["name", "expires_in_days", "permissions"])

        let name = try #require(body["name"] as? String)
        #expect((1...255).contains(name.count))

        let days = try #require(body["expires_in_days"] as? Int)
        #expect((1...3650).contains(days))

        let permissions = try #require(body["permissions"] as? [String])
        #expect(!permissions.isEmpty)
        // The two the gateway needs: run a turn, and list models for the picker.
        #expect(permissions.contains("llm:inference"))
        #expect(permissions.contains("llm:models"))
    }

    // MARK: model reconciliation
    //
    // Fixtures CAPTURED LIVE from GET https://api.unicorncommander.ai/api/v1/llm/
    // models on 2026-07-25. That surface needs no auth to read, so these rows are
    // the server's own, not written alongside the matcher.
    //
    // What the capture established, and what it corrects: the account API does
    // NOT publish `qwen3.6-35b` (the id that was configured and 400'd), and it
    // does not publish the `local/…`-prefixed LiteLLM groups either - on this
    // surface the local Qwen 3.6 35B is `uc/chat-default`. 350 models are served
    // in total; the endpoint's default `limit=100` was quietly returning the
    // first 100 of them.

    static let accountModelsFixture = #"""
    {"object":"list","data":[
    {"id":"qwen/qwen3-30b-a3b:free","display_name":"Qwen: Qwen3 30B A3B (free) (OpenRouter)","provider":"OpenRouter","pricing":{"input":0.0,"output":0.0},"context_length":40960},
    {"id":"uc/chat-default","display_name":"Majik Local — Qwen 3.6 35B MoE (Unicorn GPUs)","provider":"UC Gateway Local","pricing":{"input":0.0,"output":0.0},"context_length":65536},
    {"id":"microsoft/phi-4","display_name":"Microsoft: Phi 4 (OpenRouter)","provider":"OpenRouter","pricing":{"input":0.06,"output":0.14},"context_length":16384},
    {"id":"qwen/qwen3.6-flash","display_name":"Qwen 3.6 Flash (cloud)","provider":"OpenRouter","pricing":{"input":0.1875,"output":1.125},"context_length":1000000}
    ]}
    """#

    /// The model id that was actually configured when sign-in ended in a 400.
    static let brokenModel = "qwen3.6-35b"

    private func accountPage(truncated: Bool = false) -> SterlingCatalogPage {
        SterlingCatalogPage(
            models: SterlingModelCatalog.parse(Data(Self.accountModelsFixture.utf8)),
            possiblyTruncated: truncated)
    }

    /// The direct LiteLLM proxy's shape: one model published once per machine.
    /// These group names are the router's, as reported in the gateway's
    /// `No fallback model group found` error - not captured over HTTP here.
    private func litellmPage(ids: [String]) -> SterlingCatalogPage {
        let rows = ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
        return SterlingCatalogPage(
            models: SterlingModelCatalog.parse(Data(#"{"data":[\#(rows)]}"#.utf8)),
            possiblyTruncated: false)
    }

    @Test("the model that 400'd is reported unserved, with real alternatives")
    func brokenModelIsNotServed() throws {
        let resolution = SterlingModelReconciler.resolve(
            configured: Self.brokenModel, page: accountPage())

        guard case .notServed(let configured, let candidates) = resolution else {
            Issue.record("\(Self.brokenModel) is served by nothing on this account: \(resolution)")
            return
        }
        #expect(configured == Self.brokenModel)
        // "Accurate complaint" was the old behaviour. There must be a way out.
        #expect(!candidates.isEmpty)
        #expect(candidates.contains { $0.id == "uc/chat-default" })
        // Closest first, free ahead of paid on a tie: the local 35B MoE leads
        // the hosted flash model.
        #expect(candidates.first?.id == "uc/chat-default")
        // And an unrelated model is not padded into the shortlist.
        #expect(!candidates.contains { $0.id == "microsoft/phi-4" })
    }

    @Test("nothing is silently substituted for the broken model")
    func brokenModelIsNeverRewrittenBehindYourBack() {
        let resolution = SterlingModelReconciler.resolve(
            configured: Self.brokenModel, page: accountPage())
        // The fix must not become "quietly pick one". A choice is owed, and
        // reconciliation must not answer it.
        #expect(resolution.resolvedModel == nil)
        #expect(resolution.needsChoice)
    }

    @Test("a model the account does serve is left completely alone")
    func servedModelIsUntouched() {
        let resolution = SterlingModelReconciler.resolve(
            configured: "uc/chat-default", page: accountPage())
        #expect(resolution == .served("uc/chat-default"))
        #expect(!resolution.needsChoice)
        #expect(resolution.resolvedModel == "uc/chat-default")
    }

    @Test("a routing prefix is adopted only when exactly one machine serves it")
    func uniqueRoutingPrefixIsAdopted() {
        let resolution = SterlingModelReconciler.resolve(
            configured: "qwen3.6-35b-a3b",
            page: litellmPage(ids: ["local/qwen3.6-35b-a3b", "midboy1/other-model"]))
        #expect(resolution == .adopted(from: "qwen3.6-35b-a3b", to: "local/qwen3.6-35b-a3b"))
        #expect(!resolution.needsChoice)
    }

    @Test("the same model on several machines is a choice, not a guess")
    func ambiguousRoutingIsNotGuessed() {
        let resolution = SterlingModelReconciler.resolve(
            configured: "qwen3.6-35b-a3b",
            page: litellmPage(ids: [
                "local/qwen3.6-35b-a3b", "gpu1/qwen3.6-35b-a3b", "midboy1/qwen3.6-35b-a3b",
            ]))
        guard case .ambiguous(_, let candidates) = resolution else {
            Issue.record("three machines serving one model must not resolve to one: \(resolution)")
            return
        }
        #expect(candidates.count == 3)
        #expect(resolution.resolvedModel == nil)
    }

    @Test("a truncated list never claims a model is unserved")
    func truncationIsNotEvidence() {
        // The account serves 350 models and the endpoint defaults to 100. If a
        // page might be cut off, absence proves nothing - and telling someone
        // their model does not exist on that basis would be the same
        // wrong-axis error as reading a 200 as a passing check.
        let resolution = SterlingModelReconciler.resolve(
            configured: "some-model-past-the-cutoff", page: accountPage(truncated: true))
        guard case .undetermined = resolution else {
            Issue.record("a possibly-truncated page must not yield a verdict: \(resolution)")
            return
        }
        #expect(!resolution.needsChoice)
    }

    @Test("no configured model asks, instead of inventing a default")
    func emptyModelAsks() {
        // What replaced the hardcoded `qwen3.6-35b` fallback: that constant
        // handed every first-time user a model this gateway does not serve.
        let resolution = SterlingModelReconciler.resolve(configured: "", page: accountPage())
        guard case .unset(let candidates) = resolution else {
            Issue.record("an unset model must offer the account's list: \(resolution)")
            return
        }
        #expect(!candidates.isEmpty)
        #expect(resolution.resolvedModel == nil)
    }

    @Test("the catalog is requested with a limit that clears the real list")
    func catalogIsNotTruncatedByDefault() throws {
        // 350 served, 100 by default. Without an explicit limit the picker
        // showed a third of the account and the reconciler judged against it.
        let url = try #require(SterlingModelCatalog.modelsURL(for: UnicornAccountModel.llmEndpoint))
        #expect(url.absoluteString.hasPrefix("\(UnicornAccountModel.llmEndpoint)/models"))
        #expect(url.query?.contains("limit=") == true)
        #expect(SterlingModelCatalog.catalogPageLimit >= 350)
        #expect(SterlingModelCatalog.catalogPageLimit <= 1000)  // schema maximum
    }
}
