import SwiftUI
import Foundation
import Security

// MARK: - Unicorn Brigade agents (Lane 1, Phase 2 - list live, routing stubbed)
//
// Unicorn Brigade is the durable off-laptop agent layer. It exposes an
// OpenAI-compatible surface, so a Swift client can list agents (each agent = one
// "model") and, later, route a turn to one. Contract verified 2026-07-24 against
// the Brigade server + Unicorn Stable's BrigadeAgentPicker:
//
//   List : GET  {base}/models            Bearer <brigade key>  -> {data:[{id,name,description}]}
//   Route: POST {base}/chat/completions  Bearer <brigade key>  -> {model:<agent_id>, messages, stream, user}
//   base = https://brigade.magicunicorn.dev/api/v1/openai/v1
//
// WHAT SHIPS HERE (list): the config + agent-list client, gated behind a Brigade
// key. With no key it shows a "not configured" state, so it is invisible until
// infra provisions the key.
//
// WHAT ALSO SHIPS NOW (routing + registration - both landed after the note
// below was first written; it said "deferred" long after they were live):
//   * Routing Sterling's turns to a Brigade agent: picked in the Copilot dock
//     (StudioCopilotDock), carried as StudioCopilotRoute.brigade, dispatched by
//     RoutedCopilotBackend.send (Engine/SterlingCopilotBackend.swift). It
//     bypasses the LOCAL FFI command bus by design - a Brigade agent runs its
//     own tools/model server-side, so it CHATS but cannot drive this app's
//     timeline. That behavior fork is real and is stated in the dock's own
//     subtitle; it is not a stub.
//   * "Register a Studio-built agent in Brigade" (POST /api/v1/agents, operator
//     key): BrigadeRegistrationService.register (Studio/BrigadeRuntime.swift:262),
//     reached from AgentEditorView's "Register in Brigade". Identity, persona and
//     tools land; the avatar-image column is still not live on the internal
//     Brigade DB (P-00115), so the emoji avatar is what persists.
//
// COORDINATION (infra, not code): Brigade uses its OWN key system, not the `uc_`
// gateway key. Mint a Brigade key named `majiks-studio`, append that name to
// BRIGADE_TRUSTED_KEY_NAMES, and `docker compose up -d unicorn-brigade` (not
// restart) so it reloads .env. Until then any call returns 402/empty.

enum BrigadeConfig {
    static let defaultBase = "https://brigade.magicunicorn.dev/api/v1/openai/v1"
    private static let baseKey = "sterling.brigade.base"

    static var base: String {
        get {
            let stored = UserDefaults.standard.string(forKey: baseKey) ?? ""
            return stored.isEmpty ? defaultBase : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: baseKey) }
    }

    /// Cheap. `StudioCopilotDock` evaluates this on every body pass — it used to
    /// be a blocking XPC round trip to securityd, which is the whole of
    /// `StudioKeychainItem`'s header comment.
    static var isConfigured: Bool { BrigadeKeychain.hasKey }
}

/// Brigade key store, separate from the Sterling/BYO key (Brigade does not accept
/// the `uc_` gateway key - it needs a Brigade-minted key).
enum BrigadeKeychain {
    /// The item, and the test seam. Everything below is a one-line delegate, so
    /// there is exactly one place where a key is read from securityd and exactly
    /// one place where the cache in front of it is invalidated. See
    /// `StudioKeychainItem` for why that mattered enough to write down.
    static let item = StudioKeychainItem(
        service: "com.majik.musicstudio.brigade",
        account: "api_key"
    )

    static func setKey(_ key: String) { item.set(key) }

    /// Costs a securityd round trip once, then nothing. Still a `func`, because
    /// a cold read really can pay and the call site should say so.
    static func key() -> String? { item.value() }

    static var hasKey: Bool { item.hasValue }

    static func deleteKey() { item.delete() }
}

/// One Brigade-hosted agent (an OpenAI "model" row).
struct BrigadeAgent: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
}

@MainActor
final class BrigadeAgentCatalog: ObservableObject {
    @Published private(set) var agents: [BrigadeAgent] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    func refresh() async {
        guard let key = BrigadeKeychain.key(), !key.isEmpty else {
            agents = []
            error = "Add a Brigade key to list agents."
            return
        }
        guard let url = Self.modelsURL(for: BrigadeConfig.base) else {
            agents = []
            error = "The Brigade base URL is not valid."
            return
        }

        loading = true
        error = nil
        defer { loading = false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                agents = []
                error = http.statusCode == 402
                    ? "Brigade billing wall (402): the key name must be in BRIGADE_TRUSTED_KEY_NAMES."
                    : "Brigade returned HTTP \(http.statusCode)."
                return
            }
            agents = Self.parse(data)
            error = agents.isEmpty ? "Brigade returned no agents for this key." : nil
        } catch {
            agents = []
            self.error = "Could not reach Brigade: \(error.localizedDescription)"
        }
    }

    static func modelsURL(for base: String) -> URL? {
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + "/models")
    }

    static func parse(_ data: Data) -> [BrigadeAgent] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [[String: Any]]
        if let dict = obj as? [String: Any], let arr = dict["data"] as? [[String: Any]] {
            rows = arr
        } else if let arr = obj as? [[String: Any]] {
            rows = arr
        } else {
            return []
        }
        var out: [BrigadeAgent] = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            let name = (row["name"] as? String) ?? id
            out.append(BrigadeAgent(id: id, name: name, description: row["description"] as? String))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Brigade section (main Settings "Sterling" tab)

struct BrigadeSettingsSection: View {
    @StateObject private var catalog = BrigadeAgentCatalog()
    @State private var base = BrigadeConfig.base
    @State private var apiKey = ""
    @State private var keyPresent = BrigadeKeychain.hasKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Unicorn Brigade agents (preview)", systemImage: "cloud")
                .font(.subheadline).fontWeight(.semibold)

            Text("Brigade hosts durable, off-laptop agents. Once a Brigade key is provisioned, they appear here. Brigade uses its own key (not your gateway sign-in). Pick one in the Copilot dock to route Sterling's turns to it; a Brigade agent runs its own tools server-side, so it chats but does not drive this app's timeline.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Brigade base URL").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                TextField(BrigadeConfig.defaultBase, text: $base)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { BrigadeConfig.base = base.trimmingCharacters(in: .whitespacesAndNewlines) }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Brigade key").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                SecureField(keyPresent ? "Stored in Keychain (leave blank to keep)" : "Brigade-minted key (name it majiks-studio)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Button("Save key") {
                        BrigadeConfig.base = base.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            BrigadeKeychain.setKey(trimmed)
                            keyPresent = true
                            apiKey = ""
                        }
                        Task { await catalog.refresh() }
                    }
                    if keyPresent {
                        Button("Remove key") {
                            BrigadeKeychain.deleteKey()
                            keyPresent = false
                            apiKey = ""
                            Task { await catalog.refresh() }
                        }
                        .foregroundStyle(.red)
                    }
                    Button("Refresh agents") { Task { await catalog.refresh() } }
                        .disabled(!keyPresent)
                }
                .font(.system(size: 11))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if catalog.loading {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading agents…").font(.caption) }
            } else if !keyPresent {
                Text("Not configured - no Brigade key.").font(.caption).foregroundColor(.secondary)
            } else if let error = catalog.error {
                Text(error).font(.caption).foregroundColor(.orange)
            } else if !catalog.agents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(catalog.agents.count) Brigade agent(s):").font(.caption).foregroundColor(.secondary)
                    ForEach(catalog.agents) { agent in
                        HStack(spacing: 6) {
                            Image(systemName: "cpu").font(.caption2).foregroundColor(.secondary)
                            Text(agent.name).font(.caption)
                            if let description = agent.description, !description.isEmpty {
                                Text("— \(description)").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }
}
