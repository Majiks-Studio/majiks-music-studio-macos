import Foundation

// MARK: - Sterling failure diagnostics + save-time connection probe
//
// Two jobs, one classifier:
//
//   1. The dock used to render the engine's raw turn_error message. For an auth
//      failure that is the provider's own JSON envelope - a wall of
//      {"error":{"message":"Authentication Error, LiteLLM Virtual Key expected.
//      Received=•••, expected to start with 'sk-'",...}} in red. True, useless.
//      SterlingDiagnostic turns that into a headline, a next step, and a
//      disclosable detail that KEEPS the provider's own words.
//
//   2. Settings > Sterling accepted an endpoint + key and said nothing, so a
//      broken config only surfaced hours later in a different tab. That is the
//      silent-degradation class. SterlingConnectionProbe makes Save do a REAL
//      request against the configured endpoint with the configured model and
//      report what came back - not a regex on the key's prefix, which proves
//      nothing about whether the key works.
//
// Deployment reality this classifier exists for: the two key families in play
// are NOT interchangeable. A LiteLLM proxy (the direct gateway address) accepts
// only `sk-` virtual keys; the Unicorn Commander public API accepts only `uc_`
// keys, and "Sign in with Unicorn Commander" mints a `uc_` key AND repoints the
// endpoint at the API that takes it. Pasting one family at the other's endpoint
// is a 401 before the model is ever reached.
//
// SECRET DISCIPLINE: nothing here ever reads, stores, or renders key material.
// The context carries a key FAMILY LABEL drawn from a fixed allow-list, never a
// substring of the key itself, so no code path can leak one by accident; and
// every provider body is scrubbed before it becomes a detail, because LiteLLM
// echoes the rejected key back in its own error text.

// MARK: - Secret scrubbing (mirrors the engine's scrub_secret)

enum SterlingSecretScrub {
    /// The engine replaces the key with this before it ever crosses the FFI
    /// (copilot.rs scrub_secret); the Swift-side probe talks to the gateway
    /// directly, so it has to do the same thing to the same standard.
    static let mask = "•••"

    static func redact(_ text: String, key: String?) -> String {
        guard let key, key.count >= 6, text.contains(key) else { return text }
        return text.replacingOccurrences(of: key, with: mask)
    }
}

// MARK: - Endpoint context (never carries key material)

/// What the classifier is allowed to know about the current config. `keyFamily`
/// is a label from a fixed set, produced by `keyFamily(for:)` - never a slice of
/// the stored key.
struct SterlingEndpointContext: Equatable {
    let endpoint: String
    let model: String
    /// "sk-" / "uc_" / nil (no key stored, or a family we do not name).
    let keyFamily: String?
    /// True when SOME key is stored, whatever its family.
    let hasKey: Bool

    init(endpoint: String, model: String, keyFamily: String?, hasKey: Bool) {
        self.endpoint = endpoint
        self.model = model
        self.keyFamily = keyFamily
        self.hasKey = hasKey
    }

    /// Build a context from a live key WITHOUT the key escaping: only a label
    /// from the allow-list below can come out.
    init(endpoint: String, model: String, key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let present = !(trimmed ?? "").isEmpty
        self.init(
            endpoint: endpoint,
            model: model,
            keyFamily: present ? Self.keyFamily(for: trimmed) : nil,
            hasKey: present
        )
    }

    /// The known key families. A key matching none of them yields nil ("a format
    /// this endpoint did not recognize"), so an arbitrary prefix can never be
    /// echoed into the UI.
    static let knownFamilies = ["sk-", "uc_"]

    static func keyFamily(for key: String?) -> String? {
        guard let key else { return nil }
        return knownFamilies.first(where: { key.hasPrefix($0) })
    }

    /// Host:port for the human-readable sentence, so the guidance names the
    /// machine without pasting a whole URL into a 200-point-wide dock.
    var endpointLabel: String {
        guard let url = URL(string: endpoint), let host = url.host else { return endpoint }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}

// MARK: - The diagnostic

/// A failure rendered for a person: what happened, what to do, and the
/// provider's own text kept behind a disclosure rather than thrown away.
struct SterlingDiagnostic: Equatable {
    enum Kind: Equatable {
        /// The endpoint named a key prefix it requires and the stored key is not
        /// of that family (the LiteLLM-vs-`uc_` case).
        case keyFamilyMismatch(expectedPrefix: String)
        /// The endpoint requires a key and none was sent.
        case missingKey
        /// A key was sent and refused for some other reason (expired, revoked).
        case keyRejected
        /// The endpoint has no such model.
        case modelNotFound
        /// The endpoint answered, but nothing lives at this path (usually a base
        /// URL missing its /v1).
        case pathNotFound
        case rateLimited
        case paymentRequired
        /// Nothing answered at all: DNS, refused connection, timeout, TLS.
        case unreachable
        /// The endpoint is not a URL we can build a request from.
        case badEndpointURL
        /// HTTP 200 that was not a chat completion (a login page, an HTML error).
        case notACompletion
        /// Anything else - headline stays honest, detail carries the truth.
        case other
    }

    let kind: Kind
    /// One line: what is actually wrong.
    let headline: String
    /// One line: what the person does about it.
    let guidance: String
    /// The provider's own message, already scrubbed. Shown behind a disclosure.
    let detail: String?

    // MARK: entry points

    /// Classify the engine's `turn_error` message. The engine composes these in
    /// copilot.rs: `endpoint returned {status}: {body}` for an HTTP failure,
    /// `request failed: {e}` when the request never landed.
    static func fromEngineMessage(_ message: String, context: SterlingEndpointContext) -> SterlingDiagnostic {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if let (status, body) = parseEndpointReturned(trimmed) {
            return classify(status: status, body: body, context: context)
        }

        // Transport-level failures the engine words itself. These must NOT
        // collapse into the auth message: nothing was rejected, nothing
        // answered.
        for prefix in ["request failed:", "http client:", "stream read failed:"] where trimmed.hasPrefix(prefix) {
            return SterlingDiagnostic(
                kind: .unreachable,
                headline: "Sterling could not reach \(context.endpointLabel).",
                guidance: "Check that the endpoint is running and reachable from this Mac, then try again. Settings › Sterling has a Test connection button.",
                detail: trimmed
            )
        }

        return SterlingDiagnostic(
            kind: .other,
            headline: "Sterling's turn failed.",
            guidance: "The endpoint reported the problem below.",
            detail: trimmed.isEmpty ? nil : trimmed
        )
    }

    /// Classify a response the Swift-side probe made itself.
    static func fromHTTP(status: Int, body: String, context: SterlingEndpointContext) -> SterlingDiagnostic {
        classify(status: status, body: body, context: context)
    }

    /// Classify a URLSession transport failure (nothing answered).
    static func fromTransport(_ error: Error, context: SterlingEndpointContext) -> SterlingDiagnostic {
        SterlingDiagnostic(
            kind: .unreachable,
            headline: "Sterling could not reach \(context.endpointLabel).",
            guidance: "Check that the endpoint is running and reachable from this Mac, then try again.",
            detail: error.localizedDescription
        )
    }

    // MARK: core classification

    /// One place decides what a (status, body) pair means, so the dock and the
    /// settings pane cannot drift apart in what they tell a person.
    static func classify(status: Int, body: String, context: SterlingEndpointContext) -> SterlingDiagnostic {
        let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = detail.lowercased()

        switch status {
        case 401, 403:
            // The strongest signal: the provider itself names the prefix it
            // wants. Read it out of the body rather than hardcoding "sk-", so a
            // different gateway's wording still produces the right sentence.
            if let expected = expectedKeyPrefix(in: detail) {
                return SterlingDiagnostic(
                    kind: .keyFamilyMismatch(expectedPrefix: expected),
                    headline: "\(context.endpointLabel) rejected Sterling's key: it is the wrong kind of key.",
                    guidance: keyFamilyGuidance(expected: expected, context: context),
                    detail: detail
                )
            }
            if !context.hasKey || lowered.contains("no api key passed") || lowered.contains("missing api key") {
                return SterlingDiagnostic(
                    kind: .missingKey,
                    headline: "\(context.endpointLabel) requires an API key and Sterling is not sending one.",
                    guidance: "Paste a key for this endpoint in Settings › Sterling, or use Sign in with Unicorn Commander, which supplies one for you.",
                    detail: detail
                )
            }
            return SterlingDiagnostic(
                kind: .keyRejected,
                headline: "\(context.endpointLabel) refused Sterling's stored key.",
                guidance: "The key may be expired, revoked, or minted for a different gateway. Replace it in Settings › Sterling, or use Sign in with Unicorn Commander.",
                detail: detail
            )

        case 402:
            return SterlingDiagnostic(
                kind: .paymentRequired,
                headline: "\(context.endpointLabel) refused the request on billing.",
                guidance: "The account behind this key is out of credit or not entitled to this gateway.",
                detail: detail
            )

        case 429:
            return SterlingDiagnostic(
                kind: .rateLimited,
                headline: "\(context.endpointLabel) is rate-limiting Sterling.",
                guidance: "Wait and try again, or check whether this key has hit its budget cap.",
                detail: detail
            )

        case 404 where !mentionsMissingModel(lowered):
            return SterlingDiagnostic(
                kind: .pathNotFound,
                headline: "\(context.endpointLabel) answered, but nothing is served at that path.",
                guidance: "The endpoint should be the OpenAI-compatible base, usually ending in /v1 - Sterling appends /chat/completions itself. Fix it in Settings › Sterling.",
                detail: detail
            )

        default:
            if mentionsMissingModel(lowered) {
                let named = context.model.isEmpty ? "the configured model" : "\"\(context.model)\""
                return SterlingDiagnostic(
                    kind: .modelNotFound,
                    headline: "\(context.endpointLabel) does not serve \(named).",
                    guidance: "Pick a model from the dock's model picker (it lists what this gateway actually offers), or correct it in Settings › Sterling.",
                    detail: detail
                )
            }
            return SterlingDiagnostic(
                kind: .other,
                headline: "\(context.endpointLabel) returned HTTP \(status).",
                guidance: "The endpoint reported the problem below.",
                detail: detail.isEmpty ? nil : detail
            )
        }
    }

    // MARK: parsing helpers

    /// `endpoint returned 401 Unauthorized: {"error":...}` -> (401, body).
    /// The status is reqwest's `StatusCode` Display, so "<code> <reason>".
    static func parseEndpointReturned(_ message: String) -> (Int, String)? {
        let marker = "endpoint returned "
        guard message.hasPrefix(marker) else { return nil }
        let rest = message.dropFirst(marker.count)
        guard let separator = rest.range(of: ": ") else { return nil }
        let statusToken = rest[rest.startIndex..<separator.lowerBound]
        guard let code = Int(statusToken.prefix(3)) else { return nil }
        return (code, String(rest[separator.upperBound...]))
    }

    /// Pull the prefix a provider says it expects out of its own error text.
    /// LiteLLM: "... expected to start with 'sk-'." Quoted with ' or ".
    static func expectedKeyPrefix(in body: String) -> String? {
        let marker = "expected to start with "
        guard let range = body.range(of: marker, options: .caseInsensitive) else { return nil }
        let rest = body[range.upperBound...]
        guard let opening = rest.first, opening == "'" || opening == "\"" else { return nil }
        let afterQuote = rest.dropFirst()
        guard let closing = afterQuote.firstIndex(of: opening) else { return nil }
        let prefix = String(afterQuote[afterQuote.startIndex..<closing])
        return prefix.isEmpty ? nil : prefix
    }

    /// "no such model" in the several wordings gateways actually use. Requires
    /// the word "model" so a generic 404 body cannot masquerade as one.
    static func mentionsMissingModel(_ lowered: String) -> Bool {
        guard lowered.contains("model") else { return false }
        return lowered.contains("not found")
            || lowered.contains("does not exist")
            || lowered.contains("invalid model")
            || lowered.contains("unknown model")
            || lowered.contains("no such model")
    }

    /// The sentence that actually resolves the two-key-families confusion.
    static func keyFamilyGuidance(expected: String, context: SterlingEndpointContext) -> String {
        let stored: String
        if let family = context.keyFamily {
            stored = "The key stored for Sterling begins `\(family)`, not `\(expected)`."
        } else if context.hasKey {
            stored = "The key stored for Sterling does not begin `\(expected)`."
        } else {
            stored = "No key of that shape is stored for Sterling."
        }
        // The alternative is not "find a different key" - it is a different
        // endpoint. Sign-in mints a `uc_` key AND repoints Sterling at the
        // Unicorn Commander API that accepts it.
        return "\(stored) Paste a key that starts `\(expected)` in Settings › Sterling, or use Sign in with Unicorn Commander, which sets up its own endpoint and key for you."
    }
}

// MARK: - Save-time connection probe

/// What a probe found. `.ok` only for a response that was genuinely a chat
/// completion - a 200 carrying anything else is a failure, not a green light.
enum SterlingProbeOutcome: Equatable {
    case ok(summary: String)
    case failed(SterlingDiagnostic)

    var succeeded: Bool {
        if case .ok = self { return true }
        return false
    }
}

/// Sends one real, minimal completion to the configured endpoint with the
/// configured model and the stored key. This is the only check that proves all
/// three at once; a prefix regex proves none of them.
enum SterlingConnectionProbe {

    static func completionsURL(for endpoint: String) -> URL? {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        return URL(string: base + "/chat/completions")
    }

    /// Run the probe. `key` is used as the bearer and to scrub the response; it
    /// is never logged, stored, or returned.
    static func run(endpoint: String, model: String, key: String?) async -> SterlingProbeOutcome {
        let context = SterlingEndpointContext(endpoint: endpoint, model: model, key: key)

        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(SterlingDiagnostic(
                kind: .badEndpointURL,
                headline: "No endpoint is set.",
                guidance: "Enter an OpenAI-compatible endpoint (usually ending in /v1), or use Sign in with Unicorn Commander.",
                detail: nil))
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(SterlingDiagnostic(
                kind: .other,
                headline: "No model is set.",
                guidance: "Enter the model id this endpoint serves, then test again.",
                detail: nil))
        }
        guard let url = completionsURL(for: endpoint) else {
            return .failed(SterlingDiagnostic(
                kind: .badEndpointURL,
                headline: "That endpoint is not a valid URL.",
                guidance: "Use the full base URL, for example http://host:4000/v1.",
                detail: nil))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        // The smallest turn that still exercises auth AND the model route.
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
            "stream": false,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let body = SterlingSecretScrub.redact(String(decoding: data, as: UTF8.self), key: key)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return outcome(status: status, body: body, context: context)
        } catch {
            return .failed(.fromTransport(error, context: context))
        }
    }

    /// Pure: decide what a (status, body) pair means. Split out so the mapping
    /// is tested against response bodies captured from real gateways rather than
    /// strings written by the same hand that wrote the parser.
    static func outcome(status: Int, body: String, context: SterlingEndpointContext) -> SterlingProbeOutcome {
        guard (200...299).contains(status) else {
            return .failed(.fromHTTP(status: status, body: body, context: context))
        }

        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]

        // Some gateways answer 200 with an error envelope. A 200 is not the
        // check passing; the completion is.
        if let json, json["error"] != nil {
            return .failed(SterlingDiagnostic(
                kind: .other,
                headline: "\(context.endpointLabel) answered 200 but reported an error.",
                guidance: "The endpoint reported the problem below.",
                detail: body))
        }
        guard let json, json["choices"] is [Any] else {
            return .failed(SterlingDiagnostic(
                kind: .notACompletion,
                headline: "\(context.endpointLabel) answered, but not with a chat completion.",
                guidance: "That address is probably not the OpenAI-compatible base (a proxy or sign-in page can answer 200). Check the endpoint in Settings › Sterling.",
                detail: body.isEmpty ? nil : String(body.prefix(400))))
        }

        let named = context.model.isEmpty ? "the model" : "\"\(context.model)\""
        return .ok(summary: "Reached \(context.endpointLabel) and \(named) answered.")
    }
}
