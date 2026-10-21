import Testing
import Foundation
@testable import MajiksMusicStudio

// Contract locks for the Sterling failure mapping and the save-time probe.
//
// Every HTTP fixture below is a body CAPTURED FROM A REAL SERVER on 2026-07-25,
// not a string invented alongside the parser that reads it:
//
//   * litellm401WrongFamily / litellm401NoKey - POST /v1/chat/completions
//     against the configured LiteLLM gateway (http://100.126.207.157:4000/v1),
//     unauthenticated and with a junk bearer. The `Received=` value is shown as
//     the engine delivers it: copilot.rs scrub_secret replaces the key with
//     "•••" before it ever crosses the FFI, so this IS the production input.
//   * ollama404Model - POST /v1/chat/completions against a local Ollama with a
//     model id it does not have.
//   * nginx405 - an HTTP server that answers on the address but is not an
//     OpenAI-compatible base.
//
// The point of the suite: these must NOT collapse into one message. A person who
// pasted the wrong FAMILY of key, a person who pasted no key, a person pointed at
// the wrong model, and a person whose gateway is down need four different
// sentences, because they take four different actions.

@Suite("SterlingDiagnostic")
struct SterlingDiagnosticTests {

    // MARK: real captured bodies

    static let litellm401WrongFamily = #"{"error":{"message":"Authentication Error, LiteLLM Virtual Key expected. Received=•••, expected to start with 'sk-'.","type":"auth_error","param":"None","code":"401"}}"#
    static let litellm401NoKey = #"{"error":{"message":"Authentication Error, No api key passed in.","type":"auth_error","param":"None","code":"401"}}"#
    static let ollama404Model = #"{"error":{"message":"model 'definitely-not-a-model-xyz' not found","type":"not_found_error","param":null,"code":null}}"#
    static let nginx405 = "<html>\n<head><title>405 Not Allowed</title></head>\n<body>\n<center><h1>405 Not Allowed</h1></center>\n</body>\n</html>"

    /// The failing configuration as it actually stands: the LiteLLM gateway with
    /// a `uc_`-family key stored.
    private var wrongFamilyContext: SterlingEndpointContext {
        SterlingEndpointContext(
            endpoint: "http://100.126.207.157:4000/v1",
            model: "qwen3.6-35b",
            keyFamily: "uc_",
            hasKey: true)
    }

    private var noKeyContext: SterlingEndpointContext {
        SterlingEndpointContext(
            endpoint: "http://100.126.207.157:4000/v1",
            model: "qwen3.6-35b",
            keyFamily: nil,
            hasKey: false)
    }

    // MARK: the headline failure

    @Test("a real LiteLLM 401 names the key family, not the JSON envelope")
    func wrongKeyFamily() {
        let message = "endpoint returned 401 Unauthorized: \(Self.litellm401WrongFamily)"
        let diagnostic = SterlingDiagnostic.fromEngineMessage(message, context: wrongFamilyContext)

        #expect(diagnostic.kind == .keyFamilyMismatch(expectedPrefix: "sk-"))
        // What the person is told first must not be the provider's envelope.
        #expect(!diagnostic.headline.contains("{"))
        #expect(!diagnostic.headline.contains("auth_error"))
        // It must say which key shape this endpoint wants, which one is stored,
        // and that sign-in is the other route.
        #expect(diagnostic.guidance.contains("sk-"))
        #expect(diagnostic.guidance.contains("uc_"))
        #expect(diagnostic.guidance.contains("Sign in with Unicorn Commander"))
        // And it must not throw the provider's words away.
        #expect(diagnostic.detail == Self.litellm401WrongFamily)
    }

    @Test("the expected prefix is read from the provider's own wording")
    func expectedPrefixParsed() {
        #expect(SterlingDiagnostic.expectedKeyPrefix(in: Self.litellm401WrongFamily) == "sk-")
        // A different gateway naming a different family still works.
        #expect(SterlingDiagnostic.expectedKeyPrefix(in: #"expected to start with "gw_""#) == "gw_")
        #expect(SterlingDiagnostic.expectedKeyPrefix(in: Self.litellm401NoKey) == nil)
    }

    @Test("no key stored reads as a missing key, not a wrong one")
    func missingKey() {
        let message = "endpoint returned 401 Unauthorized: \(Self.litellm401NoKey)"
        let diagnostic = SterlingDiagnostic.fromEngineMessage(message, context: noKeyContext)

        #expect(diagnostic.kind == .missingKey)
        #expect(diagnostic.detail == Self.litellm401NoKey)
    }

    @Test("a real model-not-found is its own case, and names the model")
    func modelNotFound() {
        let message = "endpoint returned 404 Not Found: \(Self.ollama404Model)"
        let diagnostic = SterlingDiagnostic.fromEngineMessage(message, context: wrongFamilyContext)

        #expect(diagnostic.kind == .modelNotFound)
        #expect(diagnostic.headline.contains("qwen3.6-35b"))
        #expect(diagnostic.detail == Self.ollama404Model)
    }

    @Test("a 404 that is not about a model is a path problem")
    func pathNotFound() {
        let diagnostic = SterlingDiagnostic.classify(
            status: 404, body: "Not Found", context: wrongFamilyContext)
        #expect(diagnostic.kind == .pathNotFound)
        #expect(diagnostic.guidance.contains("/v1"))
    }

    @Test("the gateway being unreachable is not an auth failure")
    func unreachable() {
        let diagnostic = SterlingDiagnostic.fromEngineMessage(
            "request failed: error sending request for url (http://100.126.207.157:4000/v1/chat/completions): connection refused",
            context: wrongFamilyContext)

        #expect(diagnostic.kind == .unreachable)
        #expect(diagnostic.headline.contains("100.126.207.157:4000"))
        #expect(diagnostic.detail?.contains("connection refused") == true)
    }

    @Test("the four failures a person acts on differently read differently")
    func casesDoNotCollapse() {
        let context = wrongFamilyContext
        let diagnostics = [
            SterlingDiagnostic.fromEngineMessage("endpoint returned 401 Unauthorized: \(Self.litellm401WrongFamily)", context: context),
            SterlingDiagnostic.fromEngineMessage("endpoint returned 401 Unauthorized: \(Self.litellm401NoKey)", context: noKeyContext),
            SterlingDiagnostic.fromEngineMessage("endpoint returned 404 Not Found: \(Self.ollama404Model)", context: context),
            SterlingDiagnostic.fromEngineMessage("request failed: connection refused", context: context),
        ]
        #expect(Set(diagnostics.map(\.headline)).count == 4)
        #expect(Set(diagnostics.map(\.guidance)).count == 4)
    }

    @Test("429 and 402 stay distinct from a rejected key")
    func budgetCases() {
        let limited = SterlingDiagnostic.classify(status: 429, body: "rate limit", context: wrongFamilyContext)
        let billing = SterlingDiagnostic.classify(status: 402, body: "no credit", context: wrongFamilyContext)
        #expect(limited.kind == .rateLimited)
        #expect(billing.kind == .paymentRequired)
        #expect(limited.headline != billing.headline)
    }

    @Test("an unparseable engine message keeps its text instead of losing it")
    func unknownMessage() {
        let diagnostic = SterlingDiagnostic.fromEngineMessage(
            "Sterling's turn ended unexpectedly", context: wrongFamilyContext)
        #expect(diagnostic.kind == .other)
        #expect(diagnostic.detail == "Sterling's turn ended unexpectedly")
    }

    @Test("the status line the engine composes parses back to a code and a body")
    func parseEndpointReturned() {
        let parsed = SterlingDiagnostic.parseEndpointReturned(
            "endpoint returned 401 Unauthorized: \(Self.litellm401WrongFamily)")
        #expect(parsed?.0 == 401)
        #expect(parsed?.1 == Self.litellm401WrongFamily)
        #expect(SterlingDiagnostic.parseEndpointReturned("request failed: nope") == nil)
    }

    // MARK: key handling

    @Test("only an allow-listed family label can leave the key")
    func keyFamilyIsALabelNotASlice() {
        #expect(SterlingEndpointContext.keyFamily(for: "sk-abcdef123456") == "sk-")
        #expect(SterlingEndpointContext.keyFamily(for: "uc_abcdef123456") == "uc_")
        // An unrecognized shape yields NOTHING, so no key material can be echoed.
        #expect(SterlingEndpointContext.keyFamily(for: "zz-abcdef123456") == nil)

        let context = SterlingEndpointContext(
            endpoint: "http://host:4000/v1", model: "m", key: "zz-abcdef123456")
        #expect(context.hasKey)
        #expect(context.keyFamily == nil)
        let diagnostic = SterlingDiagnostic.classify(
            status: 401, body: Self.litellm401WrongFamily, context: context)
        #expect(!diagnostic.guidance.contains("zz-abcdef"))
    }

    @Test("a body echoing the key back is scrubbed before it can be shown")
    func scrubbing() {
        // LiteLLM echoes the rejected key into its own error text; the Swift-side
        // probe talks to the gateway directly, so it has to scrub like the engine.
        let fake = "zz-lane-fixture-not-a-real-key"
        let body = "Authentication Error, Received=\(fake), expected to start with 'sk-'."
        let scrubbed = SterlingSecretScrub.redact(body, key: fake)
        #expect(!scrubbed.contains(fake))
        #expect(scrubbed.contains("•••"))
        // Nothing to scrub when no key is in play.
        #expect(SterlingSecretScrub.redact(body, key: nil) == body)
    }
}

@Suite("SterlingConnectionProbe")
struct SterlingConnectionProbeTests {

    private var context: SterlingEndpointContext {
        SterlingEndpointContext(
            endpoint: "http://100.126.207.157:4000/v1",
            model: "qwen3.6-35b",
            keyFamily: "uc_",
            hasKey: true)
    }

    @Test("the completions URL is the base plus the path, with no double slash")
    func url() {
        #expect(SterlingConnectionProbe.completionsURL(for: "http://h:4000/v1")?.absoluteString
                == "http://h:4000/v1/chat/completions")
        #expect(SterlingConnectionProbe.completionsURL(for: "http://h:4000/v1/")?.absoluteString
                == "http://h:4000/v1/chat/completions")
        #expect(SterlingConnectionProbe.completionsURL(for: "   ") == nil)
    }

    @Test("a real 401 body fails the probe with the same diagnostic the dock shows")
    func probeMapsRealAuthFailure() {
        let outcome = SterlingConnectionProbe.outcome(
            status: 401,
            body: SterlingDiagnosticTests.litellm401WrongFamily,
            context: context)
        guard case .failed(let diagnostic) = outcome else {
            Issue.record("a 401 must not read as a pass")
            return
        }
        #expect(diagnostic.kind == .keyFamilyMismatch(expectedPrefix: "sk-"))
    }

    @Test("only an actual completion counts as a pass")
    func onlyACompletionPasses() {
        // A real completion shape.
        let ok = SterlingConnectionProbe.outcome(
            status: 200,
            body: #"{"id":"chatcmpl-1","choices":[{"index":0,"message":{"role":"assistant","content":"pong"}}]}"#,
            context: context)
        #expect(ok.succeeded)

        // 200 is the endpoint answering, not the check passing: a proxy or a
        // sign-in page answers 200 too.
        let html = SterlingConnectionProbe.outcome(
            status: 200, body: "<html><body>Sign in</body></html>", context: context)
        #expect(!html.succeeded)
        if case .failed(let diagnostic) = html { #expect(diagnostic.kind == .notACompletion) }

        // Some gateways answer 200 with an error envelope.
        let envelope = SterlingConnectionProbe.outcome(
            status: 200, body: #"{"error":{"message":"upstream is down"}}"#, context: context)
        #expect(!envelope.succeeded)
    }

    @Test("an empty endpoint or model fails before any request is made")
    func refusesIncompleteConfig() async {
        let noEndpoint = await SterlingConnectionProbe.run(endpoint: "  ", model: "m", key: nil)
        #expect(!noEndpoint.succeeded)
        if case .failed(let diagnostic) = noEndpoint { #expect(diagnostic.kind == .badEndpointURL) }

        let noModel = await SterlingConnectionProbe.run(
            endpoint: "http://127.0.0.1:1/v1", model: "", key: nil)
        #expect(!noModel.succeeded)
    }

    /// Drives the REAL network path (URLSession -> transport failure ->
    /// diagnostic) with no external dependency: nothing listens on this port, so
    /// the connection is refused locally and immediately.
    @Test("the live probe reports an unreachable endpoint as unreachable")
    func liveProbeAgainstAClosedPort() async {
        let outcome = await SterlingConnectionProbe.run(
            endpoint: "http://127.0.0.1:59999/v1", model: "qwen3.6-35b", key: nil)
        guard case .failed(let diagnostic) = outcome else {
            Issue.record("a refused connection must not read as a pass")
            return
        }
        #expect(diagnostic.kind == .unreachable)
    }

    /// Opt-in live check against a real gateway, run with:
    ///   STERLING_LIVE_ENDPOINT=http://host:4000/v1 swift test
    /// It sends NO key on purpose - it proves the endpoint is an authenticating
    /// OpenAI-compatible gateway and that the probe classifies its real answer,
    /// without any credential being involved. Skipped by default so the suite
    /// stays hermetic.
    @Test("live: a real gateway's unauthenticated answer classifies as an auth failure")
    func liveProbeAgainstRealGateway() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["STERLING_LIVE_ENDPOINT"],
              !endpoint.isEmpty else { return }
        let outcome = await SterlingConnectionProbe.run(
            endpoint: endpoint, model: "qwen3.6-35b", key: nil)
        guard case .failed(let diagnostic) = outcome else {
            Issue.record("an unauthenticated call to a gated gateway must not pass")
            return
        }
        #expect(diagnostic.kind == .missingKey || diagnostic.kind == .keyRejected)
    }
}
