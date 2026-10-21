import SwiftUI
import Foundation

// MARK: - Sterling agent + model management (Lane 1, Phase 1)
//
// The swappable agent + model layer behind the Sterling dock. Three pieces the
// dock and the main Settings window share:
//
//   1. SterlingConfigForm   - the endpoint/model/key editor, reused by BOTH the
//                             dock's gear sheet and the new main-Settings tab, so
//                             there is one source of truth for the BYO config.
//   2. SterlingModelCatalog - lists chat models from the configured gateway
//                             (GET {endpoint}/models), FFI-free, so the dock footer
//                             can switch the active model for the next turn.
//   3. SterlingAgentBridge  - maps a picked local agent (built-in Sterling or a
//                             custom AgentStore agent) to the native
//                             systemPrompt override the FFI now accepts.
//
// MARK: - Gateway model catalog

/// One chat model offered by the gateway, with a FREE / price hint following the
/// same rule Majik's DJ uses (`:free` slug or both prices explicitly 0).
struct SterlingGatewayModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let isFree: Bool
    let priceLabel: String?
}

/// Lists chat models from an OpenAI-compatible gateway. Pure URLSession, so it
/// works in the mock build and needs no engine. Reads GET {endpoint}/models with
/// the Sterling key as a bearer token when one is stored.
@MainActor
final class SterlingModelCatalog: ObservableObject {
    @Published private(set) var models: [SterlingGatewayModel] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    /// The endpoint the current `models` were fetched for, so refreshIfNeeded can
    /// no-op when nothing changed and refetch when the endpoint does.
    private(set) var loadedEndpoint: String?

    /// Fetch only when we have not already loaded this exact endpoint.
    func refreshIfNeeded(endpoint: String, apiKey: String?) async {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == loadedEndpoint, !models.isEmpty { return }
        await refresh(endpoint: trimmed, apiKey: apiKey)
    }

    func refresh(endpoint: String, apiKey: String?) async {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            models = []
            loadedEndpoint = nil
            error = "Set an endpoint in Sterling settings to list models."
            return
        }
        guard Self.modelsURL(for: trimmed) != nil else {
            models = []
            loadedEndpoint = nil
            error = "That endpoint is not a valid URL."
            return
        }

        loading = true
        error = nil
        defer { loading = false }

        do {
            let page = try await Self.fetchPage(endpoint: trimmed, apiKey: apiKey)
            models = page.models
            loadedEndpoint = trimmed
            error = page.models.isEmpty ? "No models returned by the gateway." : nil
        } catch let CatalogError.http(status) {
            models = []
            loadedEndpoint = nil
            error = "Gateway returned HTTP \(status)."
        } catch {
            models = []
            loadedEndpoint = nil
            self.error = "Could not reach the gateway: \(error.localizedDescription)"
        }
    }

    enum CatalogError: Error {
        case badURL
        case http(Int)
    }

    /// How many rows to ask for. The Unicorn Commander API defaults to
    /// `limit=100` and actually serves 350 (both verified live against
    /// api.unicorncommander.ai/api/v1/llm/models, 2026-07-25), so taking the
    /// default silently cut the catalog to its first 100 - and a model absent
    /// from a truncated page is indistinguishable from a model the gateway does
    /// not serve, which is exactly the wrong verdict for the reconciler below to
    /// reach. 1000 is the documented schema maximum. Gateways that have never
    /// heard of the parameter ignore it.
    static let catalogPageLimit = 1000

    /// {endpoint}/models with no double slash, per the brief's list surface.
    static func modelsURL(for endpoint: String) -> URL? {
        var base = endpoint
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        return URL(string: base + "/models?limit=\(catalogPageLimit)")
    }

    /// One catalog read. Both the dock picker's refresh and the post-sign-in
    /// reconciliation go through this single HTTP path, so the list a person is
    /// offered and the list their model is judged against cannot drift apart.
    static func fetchPage(endpoint: String, apiKey: String?) async throws -> SterlingCatalogPage {
        guard let url = modelsURL(for: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CatalogError.badURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }
        // Truncation is judged on what the server SENT, not on what survived
        // de-duplication, so a full page carrying a duplicate id cannot read as
        // a complete catalog.
        return SterlingCatalogPage(
            models: parse(data),
            possiblyTruncated: rows(data).count >= catalogPageLimit)
    }

    /// The raw `{data:[…]}` (or bare array) rows, before de-duplication.
    static func rows(_ data: Data) -> [[String: Any]] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let dict = obj as? [String: Any], let arr = dict["data"] as? [[String: Any]] {
            return arr
        }
        return (obj as? [[String: Any]]) ?? []
    }

    /// Parse an OpenAI-compatible `{data:[{id}]}` (or a bare array) into rows.
    static func parse(_ data: Data) -> [SterlingGatewayModel] {
        let rows = Self.rows(data)
        var out: [SterlingGatewayModel] = []
        var seen = Set<String>()
        for row in rows {
            guard let id = (row["id"] as? String) ?? (row["model"] as? String),
                  !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            let displayName = (row["display_name"] as? String) ?? (row["name"] as? String) ?? id
            let (isFree, price) = Self.pricing(id: id, row: row)
            out.append(SterlingGatewayModel(id: id, displayName: displayName, isFree: isFree, priceLabel: price))
        }
        // Free first, then cheapest, then name - the DJ picker's order.
        return out.sorted { a, b in
            if a.isFree != b.isFree { return a.isFree }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    /// FREE / price read matching Majik's DJ (`uc_account.rs` model_row_to_json):
    /// `free = id ends with ":free" OR (input == 0 AND output == 0)`. Missing
    /// pricing means "unknown cost", NOT free - the badge is what users spend
    /// against, so it needs positive evidence. Prices are USD per 1M tokens
    /// (the gateway's `pricing.input` / `pricing.output`).
    static func pricing(id: String, row: [String: Any]) -> (Bool, String?) {
        let pricing = row["pricing"] as? [String: Any]
        let inputM = numeric(row["price_input_per_m"]) ?? numeric(pricing?["input"]) ?? numeric(pricing?["prompt"])
        let outputM = numeric(row["price_output_per_m"]) ?? numeric(pricing?["output"]) ?? numeric(pricing?["completion"])

        if id.hasSuffix(":free") { return (true, "FREE") }
        if let i = inputM, let o = outputM {
            if i == 0.0 && o == 0.0 { return (true, "FREE") }
            return (false, "\(money(i)) in / \(money(o)) out /1M")
        }
        return (false, nil)  // unknown cost
    }

    /// Honest formatting for sub-cent models (the DJ's rule): $X.XX at or above a
    /// cent, four decimals below, so a real cost never renders as "$0.00".
    static func money(_ value: Double) -> String {
        value >= 0.01 ? String(format: "$%.2f", value) : String(format: "$%.4f", value)
    }

    static func numeric(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - Model reconciliation (what the account actually serves)

/// One catalog read: the rows, plus whether the gateway may have held some back.
struct SterlingCatalogPage: Equatable {
    let models: [SterlingGatewayModel]
    /// True when the gateway returned as many rows as we asked for, so there may
    /// be more we never saw. Absence from a truncated page is NOT evidence that a
    /// model is unserved, and the reconciler refuses to treat it as such.
    let possiblyTruncated: Bool
}

/// What comparing the configured model against the gateway's real catalog found.
///
/// Signing in repoints Sterling at the account gateway but carries the existing
/// model id across unchanged, and the two do not have to agree: the model that
/// was configured (`qwen3.6-35b`) is served by NO group on the account API -
/// verified live 2026-07-25, where the local Qwen 3.6 35B is published as
/// `uc/chat-default` and the `local/…`-prefixed groups belong to the direct
/// LiteLLM proxy instead. So the id has to be reconciled against the list rather
/// than assumed, and no replacement id may be hardcoded here: which id is right
/// is a server-side fact that changes without us, which is the same root cause
/// that let the mint default to another app's key name.
enum SterlingModelResolution: Equatable {
    /// The configured model is served. Nothing to change.
    case served(String)
    /// The configured id named exactly one served model that differs only by the
    /// routing prefix this gateway requires. Adopted - and the UI says so, because
    /// a config that changed underneath someone must never do it silently.
    case adopted(from: String, to: String)
    /// Several served models are that same id behind different prefixes. Which
    /// one runs it is a real routing choice, so it stays the person's to make.
    case ambiguous(configured: String, candidates: [SterlingGatewayModel])
    /// Nothing here is that model. Closest offers first, whole list one click away.
    case notServed(configured: String, candidates: [SterlingGatewayModel])
    /// No model was configured at all.
    case unset(candidates: [SterlingGatewayModel])
    /// The catalog could not be read, or came back possibly truncated. Absence is
    /// not evidence, so nothing is claimed and the probe stays the only verdict.
    case undetermined(reason: String)

    /// True when the person still has a choice to make before Sterling will run.
    var needsChoice: Bool {
        switch self {
        case .ambiguous, .notServed, .unset: return true
        case .served, .adopted, .undetermined: return false
        }
    }

    /// The id Sterling should be configured with, when reconciliation settled it.
    var resolvedModel: String? {
        switch self {
        case .served(let id): return id
        case .adopted(_, let to): return to
        default: return nil
        }
    }
}

/// Pure matching between a configured model id and a gateway's catalog.
///
/// Deliberately conservative: it ADOPTS only on an unambiguous identity match,
/// and otherwise offers a shortlist for a person to pick from. Fuzzy similarity
/// is used ONLY to order suggestions, never to change the configuration - a
/// wrong silent substitution is a worse bug than the broken id it replaced.
enum SterlingModelReconciler {

    static func normalize(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The id with its leading routing segment dropped: LiteLLM publishes model
    /// groups as `local/x` or `gpu1/x`, and OpenRouter ids are `vendor/model`.
    /// A bare configured id matching this tail is good evidence - but only when
    /// exactly one served model matches, since `local/x` and `gpu1/x` are the
    /// same model on different machines.
    static func routedTail(_ id: String) -> String {
        guard let slash = id.firstIndex(of: "/") else { return id }
        return String(id[id.index(after: slash)...])
    }

    /// Alphanumeric tokens, for ordering suggestions only.
    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty })
    }

    /// How many tokens a candidate shares with the configured id. Ties break
    /// free-first then by name, so the cheapest plausible option leads.
    static func suggestions(for configured: String,
                            from models: [SterlingGatewayModel],
                            limit: Int = 6) -> [SterlingGatewayModel] {
        let wanted = tokens(configured)
        guard !wanted.isEmpty else { return Array(models.prefix(limit)) }
        let scored = models.map { model -> (SterlingGatewayModel, Int) in
            (model, tokens("\(model.id) \(model.displayName)").intersection(wanted).count)
        }
        return scored
            .filter { $0.1 > 0 }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.isFree != b.0.isFree { return a.0.isFree }
                return a.0.displayName.localizedCaseInsensitiveCompare(b.0.displayName) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    /// Reconcile. `page` is what the gateway actually published.
    static func resolve(configured: String, page: SterlingCatalogPage) -> SterlingModelResolution {
        let wanted = normalize(configured)
        let models = page.models

        guard !models.isEmpty else {
            return .undetermined(reason: "The gateway did not return a model list.")
        }
        guard !wanted.isEmpty else {
            return .unset(candidates: Array(models.prefix(6)))
        }

        // 1. Served under exactly the id that is configured.
        if let exact = models.first(where: { normalize($0.id) == wanted }) {
            return .served(exact.id)
        }

        // 2. Served under a routing prefix. Unique -> adopt; several -> ask.
        let byTail = models.filter { normalize(routedTail($0.id)) == wanted }
        if byTail.count == 1 {
            return .adopted(from: configured, to: byTail[0].id)
        }
        if byTail.count > 1 {
            return .ambiguous(configured: configured, candidates: byTail)
        }

        // 3. Not here. A truncated page is not proof of that, so say nothing.
        if page.possiblyTruncated {
            return .undetermined(reason: "The gateway's model list came back truncated, so Sterling cannot tell whether it serves \"\(configured)\".")
        }
        return .notServed(configured: configured,
                          candidates: suggestions(for: configured, from: models))
    }
}

// MARK: - Agent -> persona bridge (FFI-free persona swap)

enum SterlingAgentBridge {
    /// Native FFI system-prompt override for a local custom agent. Built-in
    /// Sterling returns nil so the engine's committed persona stays in force.
    static func systemPromptOverride(for agent: ChatAgent) -> String? {
        if agent.id == ChatAgent.majikAgentID { return nil }
        let persona = [agent.systemPrompt, agent.customInstructions]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        if persona.isEmpty {
            return "You are \"\(agent.name)\" inside Majik's Music Studio. Keep using the Studio tools and command bus exactly as Sterling would."
        }
        return "You are \"\(agent.name)\" inside Majik's Music Studio. Adopt this persona and follow these instructions while continuing to use the Studio tools and command bus exactly as Sterling would:\n\n\(persona)"
    }
}

// MARK: - Shared BYO config form (dock sheet + main Settings tab)

/// The endpoint / model / API-key editor. Endpoint and model persist live through
/// @AppStorage (the same keys SterlingConfig and the dock read); the key is
/// committed to the Keychain with Save. Reused by the dock gear sheet and the
/// main-Settings "Sterling" tab so both edit exactly one config.
///
/// Save PROBES. This pane used to accept any endpoint + key silently and the
/// configuration only failed later, in the Studio tab, as a wall of provider
/// JSON. Save now sends one real minimal completion to the endpoint you typed
/// with the model you typed and reports what came back, so a broken config is
/// caught here rather than hours later somewhere else.
struct SterlingConfigForm: View {
    @AppStorage("sterling.endpoint") private var endpoint = ""
    @AppStorage("sterling.model") private var model = ""
    @State private var apiKey = ""
    @State private var keyPresent = SterlingKeychain.hasKey
    @State private var savedFlash = false
    @State private var probing = false
    @State private var probeOutcome: SterlingProbeOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Point Sterling at any OpenAI-compatible endpoint: your Unicorn Commander gateway (the direct address, not the Cloudflare host, so long runs are not cut off at 120 seconds), llama.cpp, Ollama, LM Studio, or a cloud key. The key is stored in your Keychain and sent only as the request's authorization, never to the model.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            field("Endpoint", text: $endpoint, prompt: "http://100.126.207.157:4000/v1")
            // The model placeholder has to be a group that endpoint really
            // serves. It used to read `qwen3.6-35b`, which no gateway in this
            // deployment publishes under that name - so the hint itself taught
            // people the id that fails.
            field("Model", text: $model, prompt: "local/qwen3.6-35b-a3b")

            VStack(alignment: .leading, spacing: 3) {
                Text("API key").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                SecureField(keyPresent ? "Stored in Keychain (leave blank to keep)" : "Optional for local gateways", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                if keyPresent {
                    Button("Remove stored key") {
                        SterlingKeychain.deleteKey()
                        keyPresent = false
                        apiKey = ""
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }

            HStack(spacing: 10) {
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                Button("Test connection") { runProbe() }
                    .disabled(probing)
                if savedFlash {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Spacer()
            }

            SterlingProbeResultView(probing: probing, outcome: probeOutcome)
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }

    private func commit() {
        endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            SterlingKeychain.setKey(trimmedKey)
            keyPresent = true
            apiKey = ""
        }
        withAnimation { savedFlash = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation { savedFlash = false }
        }
        // "Saved" only means persisted. Whether it WORKS is the probe's answer.
        runProbe()
    }

    /// One real request against the configured endpoint. The key goes straight
    /// from the Keychain into the Authorization header and is never held here.
    private func runProbe() {
        guard !probing else { return }
        probing = true
        probeOutcome = nil
        let endpoint = self.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = self.model.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let outcome = await SterlingConnectionProbe.run(
                endpoint: endpoint, model: model, key: SterlingKeychain.key())
            await MainActor.run {
                probeOutcome = outcome
                probing = false
            }
        }
    }
}

// MARK: - Probe result (shared by the settings pane and the first-run wizard)

/// Renders a probe outcome the way the dock renders a turn failure: headline,
/// next step, and the provider's own words kept behind a disclosure instead of
/// led with.
struct SterlingProbeResultView: View {
    let probing: Bool
    let outcome: SterlingProbeOutcome?
    @State private var showDetail = false

    var body: some View {
        Group {
            if probing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking the endpoint…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if case .ok(let summary)? = outcome {
                Label(summary, systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .failed(let diagnostic)? = outcome {
                SterlingDiagnosticView(diagnostic: diagnostic, showDetail: $showDetail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The light-chrome diagnostic block. The dock has its own dark-themed twin
/// (StudioCopilotDock) that reads the same SterlingDiagnostic.
struct SterlingDiagnosticView: View {
    let diagnostic: SterlingDiagnostic
    @Binding var showDetail: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(diagnostic.headline, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(diagnostic.guidance)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = diagnostic.detail, !detail.isEmpty {
                Button(showDetail ? "Hide details" : "Show details") { showDetail.toggle() }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                if showDetail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .background(Color.gray.opacity(0.10))
                        .cornerRadius(4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Main Settings "Sterling" tab

/// The Sterling config as a first-class main-Settings pane, so the endpoint/model/
/// key are reachable without opening the Studio tab and the copilot dock gear.
/// Reuses SterlingConfigForm (and thus SterlingConfig / SterlingKeychain).
struct SterlingSettingsPane: View {
    @StateObject private var account = UnicornAccountModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    SterlingAvatarView(size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sterling").font(.title2).fontWeight(.semibold)
                        Text("\(SterlingPersona.role) - your in-app studio agent")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.top)

                Divider()

                // Phase 2 - sign in with Unicorn Commander (authed gateway).
                UnicornSignInSection(account: account)

                // Advanced fallback: point Sterling at any endpoint by hand.
                VStack(alignment: .leading, spacing: 8) {
                    Label("Advanced - bring your own endpoint", systemImage: "slider.horizontal.3")
                        .font(.subheadline).fontWeight(.semibold)
                    SterlingConfigForm()
                }

                Divider()

                // Phase 2 - Unicorn Brigade agents (list live; routing a follow-up).
                BrigadeSettingsSection()

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Label("Switching agent and model", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline).fontWeight(.semibold)
                    Text("In the Studio tab, open Sterling with Cmd+Opt+C. The dock footer has an agent picker and a model picker: switch the LLM or the agent driving the session on the fly - built-in Sterling or any custom agent you build in the Agents tab. The choice persists and takes effect on the next turn.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(8)

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Dock footer pickers (dark Studio theme)

/// The compact model dropdown in the Sterling dock footer. Lists gateway models
/// with FREE badges, checks the active one, switches it for the next turn.
struct SterlingDockModelPicker: View {
    @ObservedObject var catalog: SterlingModelCatalog
    @Binding var model: String
    let endpoint: String

    var body: some View {
        Menu {
            if catalog.loading {
                Text("Loading models…")
            }
            if let error = catalog.error {
                Text(error)
            }
            Button {
                Task { await catalog.refresh(endpoint: endpoint, apiKey: SterlingKeychain.key()) }
            } label: {
                Label("Refresh models", systemImage: "arrow.clockwise")
            }

            if !catalog.models.isEmpty {
                Divider()
                ForEach(catalog.models) { entry in
                    Button {
                        model = entry.id
                    } label: {
                        // A menu row: check + id + FREE/price. Text-only so it
                        // renders in the AppKit menu.
                        Text(menuLabel(for: entry))
                    }
                }
            }

            // Keep the current model selectable even if the gateway did not list
            // it (a hand-typed model in settings).
            if !model.isEmpty, !catalog.models.contains(where: { $0.id == model }) {
                Divider()
                Text("Current: \(model)")
            }
        } label: {
            SterlingDockPill(icon: "cpu", text: model.isEmpty ? "Model" : model)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch the LLM driving Sterling (takes effect next turn)")
    }

    private func menuLabel(for entry: SterlingGatewayModel) -> String {
        let check = entry.id == model ? "\u{2713} " : "   "
        let name = entry.displayName.isEmpty ? entry.id : entry.displayName
        if entry.isFree {
            return "\(check)\(name) — FREE"
        } else if let price = entry.priceLabel {
            return "\(check)\(name) — \(price)"
        }
        return "\(check)\(name)"
    }
}

/// The compact agent dropdown in the Sterling dock footer. Lists built-in Sterling
/// plus every custom agent from the AgentStore; selecting one swaps the persona +
/// optional default model for the session.
struct SterlingDockAgentPicker: View {
    let localAgents: [ChatAgent]
    let brigadeAgents: [BrigadeAgent]
    let activeSelection: String
    let onSelectLocal: (ChatAgent) -> Void
    let onSelectBrigade: (BrigadeAgent) -> Void

    private var activeName: String {
        if activeSelection.hasPrefix("brigade:") {
            let id = String(activeSelection.dropFirst("brigade:".count))
            return brigadeAgents.first(where: { $0.id == id })?.name ?? id
        }
        return localAgents.first(where: { $0.id.uuidString == activeSelection })?.name ?? SterlingPersona.name
    }

    var body: some View {
        Menu {
            Text("Studio agents")
                .font(.caption)
            ForEach(localAgents) { agent in
                Button {
                    onSelectLocal(agent)
                } label: {
                    Text(localMenuLabel(for: agent))
                }
            }
            if !brigadeAgents.isEmpty {
                Divider()
                Text("Brigade agents")
                    .font(.caption)
                ForEach(brigadeAgents) { agent in
                    Button {
                        onSelectBrigade(agent)
                    } label: {
                        Text(brigadeMenuLabel(for: agent))
                    }
                }
            }
        } label: {
            SterlingDockPill(icon: "person.crop.rectangle.stack", text: activeName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which agent drives the session")
    }

    private func localMenuLabel(for agent: ChatAgent) -> String {
        var label = agent.id.uuidString == activeSelection ? "\u{2713} \(agent.name)" : "   \(agent.name)"
        label += agent.isBuiltIn ? " · studio" : ""
        return label
    }

    private func brigadeMenuLabel(for agent: BrigadeAgent) -> String {
        let raw = "brigade:\(agent.id)"
        var label = raw == activeSelection ? "\u{2713} \(agent.name)" : "   \(agent.name)"
        label += " · Brigade"
        return label
    }
}

/// A small capsule control matched to the dock's dense dark aesthetic.
struct SterlingDockPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(StudioTokens.dim)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: 150)
        .background(Capsule().fill(StudioTokens.panelHi))
        .overlay(Capsule().stroke(StudioTokens.stroke, lineWidth: 1))
        .contentShape(Capsule())
    }
}
