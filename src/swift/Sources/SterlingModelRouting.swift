import Foundation

// MARK: - Capability
//
// Sterling drives 148 MCP tools and 119 journalled commands. A model that
// cannot hold that surface does not fail the way a "wrong model" fails: it
// invents tool names and malformed arguments, and what the user sees is not
// "bad answer", it is "the app is broken". The wrong model is therefore not a
// quality question, it is a correctness one, and it is decided BEFORE any
// agentic work starts rather than discovered in the middle of a turn.
//
// This file is deliberately pure. Every input is passed in, so the decision can
// be tested without a real UserDefaults, a real home directory, or a real
// gateway — see `SterlingModelRoutingTests`.

/// What a model is fit to DO, as distinct from how large it is.
enum SterlingModelCapability: String, Equatable, Sendable {
    /// Strong enough to be handed the whole tool surface.
    case operatesTheApp
    /// Fine to talk to. Will not be given the app to drive.
    case chatOnly
}

enum SterlingCapabilities {
    /// The one local model Sterling is allowed to operate the app with.
    ///
    /// ~17 GB on disk and roughly 18-20 GB resident while it runs. On a base
    /// MacBook Air that is not slow, it is impossible — which is why a remote
    /// endpoint is the product default and why nothing here ever downloads this
    /// on the app's own initiative.
    static let localOperatorModel = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"

    /// Rounded down from the real 17.5 GB so the number we show a user is never
    /// smaller than the download they get.
    static let localOperatorModelApproximateGigabytes = 17

    /// The model that has been this app's default chat model since v1.9.1, is
    /// still the dedicated extraction model, and is still fully selectable for
    /// chat. It is named here only so the capability table and the recovery
    /// migration agree on which string they mean.
    static let legacyDefaultChatModel = "mlx-community/Qwen3.5-4B-4bit"

    /// Deliberately an ALLOW-list of one rather than a deny-list of the small
    /// models. A deny-list defaults every model added later to "capable", which
    /// is the silent-degradation direction; an allow-list defaults them to
    /// "refuse", which is loud, visible, and a one-line fix. Widening this is a
    /// measurement, not an opinion: run the tool surface against the candidate
    /// and count the invented tool names first.
    static let operatorCapableLocalModels: Set<String> = [localOperatorModel]

    static func capability(ofLocalModel model: String) -> SterlingModelCapability {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return operatorCapableLocalModels.contains(trimmed) ? .operatesTheApp : .chatOnly
    }

    /// Remote providers are trusted, and the asymmetry is deliberate: the app
    /// cannot enumerate what an arbitrary gateway serves, and the person who
    /// typed the endpoint and picked the model there has already made the
    /// capability call themselves. Second-guessing their own choice would be a
    /// different lie, and a more annoying one.
    /// Sterling's one-line verdict on a model, or `nil` when there is nothing
    /// honest to say (see `isRemote`). Static so it can be tested without
    /// constructing `LLMProviderSettings`, whose `init` writes to the real
    /// UserDefaults and auto-detects models on the real disk.
    static func note(for model: String, provider: LLMProvider) -> String? {
        guard !isRemote(provider) else { return nil }
        switch capability(ofLocalModel: model) {
        case .operatesTheApp:
            return "Operates the Studio"
        case .chatOnly:
            return "Chat only — cannot operate the Studio"
        }
    }

    static func isRemote(_ provider: LLMProvider) -> Bool {
        switch provider {
        case .mlxLocal:
            return false
        case .openrouter, .anthropic, .openai, .deepseek, .gemini,
             .ollama, .lmStudio, .customOpenAI:
            return true
        }
    }
}

// MARK: - Inputs

/// Everything the routing decision reads. Defaults describe a machine with
/// nothing configured, which is the case that must refuse.
struct SterlingRoutingInputs: Equatable, Sendable {
    /// `SterlingConfig.isConfigured` — the Studio copilot dock's own endpoint.
    var copilotEndpointConfigured: Bool = false
    /// `SterlingConfig.model`, shown so the user can see what they are on.
    var copilotModel: String = ""
    /// The Chat tab's provider (`LLMProviderSettings.primaryProvider`).
    var chatProvider: LLMProvider = .mlxLocal
    /// The Chat tab's model (`LLMProviderSettings.primaryModel`).
    var chatModel: String = ""
    /// An API key for a key-taking provider, or an endpoint URL for one that
    /// takes none. Without it the "provider" is a menu selection, not a route.
    var chatProviderHasCredential: Bool = false
    /// Local model ids actually present in the Hugging Face cache. Only what is
    /// already on disk counts; a model we would have to fetch is an OFFER.
    var downloadedLocalModels: Set<String> = []

    init(
        copilotEndpointConfigured: Bool = false,
        copilotModel: String = "",
        chatProvider: LLMProvider = .mlxLocal,
        chatModel: String = "",
        chatProviderHasCredential: Bool = false,
        downloadedLocalModels: Set<String> = []
    ) {
        self.copilotEndpointConfigured = copilotEndpointConfigured
        self.copilotModel = copilotModel
        self.chatProvider = chatProvider
        self.chatModel = chatModel
        self.chatProviderHasCredential = chatProviderHasCredential
        self.downloadedLocalModels = downloadedLocalModels
    }
}

// MARK: - Outcome

enum SterlingRouteSource: Equatable, Sendable {
    /// Settings › Sterling — the endpoint the Studio copilot dock already uses.
    case copilotEndpoint
    /// Settings › LLM & Models — the Chat tab's provider.
    case chatProvider(LLMProvider)

    /// Where the user would go to change it. A location, not an explanation.
    var settingsLocation: String {
        switch self {
        case .copilotEndpoint: return "Settings › Sterling"
        case .chatProvider: return "Settings › LLM & Models"
        }
    }
}

/// One of the two things a user can do about a refusal. Titles are NAMES; the
/// reason each one exists is said once, in `detail`.
enum SterlingOperatorOffer: Equatable, Sendable {
    case connectARemoteEndpoint
    case downloadTheLocalModel(id: String, approximateGigabytes: Int)

    var title: String {
        switch self {
        case .connectARemoteEndpoint:
            return "Connect a remote endpoint"
        case .downloadTheLocalModel:
            return "Download Qwen3 30B A3B"
        }
    }

    var detail: String {
        switch self {
        case .connectARemoteEndpoint:
            return "Settings › Sterling. Any OpenAI-compatible endpoint works: your own server, a gateway, or a cloud key. It uses no memory on this Mac."
        case let .downloadTheLocalModel(_, gigabytes):
            return "Settings › LLM & Models, under MLX Models. About \(gigabytes) GB to download and roughly 20 GB of memory while it runs, so it needs a Mac with room for it. Nothing is fetched until you press it."
        }
    }
}

/// Why Sterling will not drive the app, and what to do instead.
struct SterlingOperatorRefusal: Equatable, Sendable {
    var headline: String
    var detail: String
    var offers: [SterlingOperatorOffer]
}

enum SterlingOperatorRoute: Equatable, Sendable {
    case remote(model: String, source: SterlingRouteSource)
    case local(model: String)
    case refused(SterlingOperatorRefusal)

    var canOperateTheApp: Bool {
        if case .refused = self { return false }
        return true
    }

    /// One line for a status row. Never says "ready" when it is not.
    var summary: String {
        switch self {
        case let .remote(model, source):
            return "\(model) — \(source.settingsLocation)"
        case let .local(model):
            return "\(model) — on this Mac"
        case let .refused(refusal):
            return refusal.headline
        }
    }
}

// MARK: - The decision

enum SterlingRouter {
    /// Route Sterling by CAPABILITY, in the owner's order:
    ///
    /// 1. a configured remote endpoint — preferred whenever present, because it
    ///    costs no local memory and works on hardware the 30B cannot;
    /// 2. the local 30B MoE, but only if it is already downloaded;
    /// 3. neither — refuse, out loud, and name both routes.
    ///
    /// Step 3 is the whole point. Falling back to a small model here would be
    /// another instance of this codebase's single largest bug class, and the
    /// one whose symptom is least legible: the app just looks broken.
    static func route(_ inputs: SterlingRoutingInputs) -> SterlingOperatorRoute {
        // 1. The copilot dock's own endpoint. It is the only route the Studio
        //    dock has at all, so when it is set it is also the truthful answer.
        if inputs.copilotEndpointConfigured {
            return .remote(model: inputs.copilotModel, source: .copilotEndpoint)
        }

        // 1b. A remote chat provider with a credential is the same kind of
        //     route: someone else's hardware, chosen by this user.
        if SterlingCapabilities.isRemote(inputs.chatProvider), inputs.chatProviderHasCredential {
            return .remote(model: inputs.chatModel, source: .chatProvider(inputs.chatProvider))
        }

        // 2. Local, and only what is already on disk. The selected chat model
        //    wins when it is capable; otherwise the operator model still counts
        //    if it is downloaded, because chat and operating the app are two
        //    jobs and a user is allowed to keep a small model for the first.
        if SterlingCapabilities.capability(ofLocalModel: inputs.chatModel) == .operatesTheApp,
           inputs.downloadedLocalModels.contains(inputs.chatModel) {
            return .local(model: inputs.chatModel)
        }
        if inputs.downloadedLocalModels.contains(SterlingCapabilities.localOperatorModel) {
            return .local(model: SterlingCapabilities.localOperatorModel)
        }

        // 3. Neither.
        return .refused(refusal(for: inputs))
    }

    private static func refusal(for inputs: SterlingRoutingInputs) -> SterlingOperatorRefusal {
        let named = inputs.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = named.isEmpty ? "No model is selected" : "\(shortName(named)) is a chat model"

        return SterlingOperatorRefusal(
            headline: "Sterling cannot operate the Studio",
            detail: """
            Sterling drives every tool and every undoable action in this app. \
            \(subject), and a chat model handed that surface invents tool names \
            instead of running them — so the Studio would look broken rather \
            than tell you why. Either route below fixes it.
            """,
            offers: [
                .connectARemoteEndpoint,
                .downloadTheLocalModel(
                    id: SterlingCapabilities.localOperatorModel,
                    approximateGigabytes: SterlingCapabilities.localOperatorModelApproximateGigabytes
                )
            ]
        )
    }

    /// Hugging Face ids are long and the vendor prefix carries no information
    /// in a sentence the user is reading about their own machine.
    static func shortName(_ model: String) -> String {
        guard let slash = model.lastIndex(of: "/") else { return model }
        return String(model[model.index(after: slash)...])
    }
}

// MARK: - Reading the real machine
//
// Kept apart from the decision above so tests never touch the owner's real
// UserDefaults or his real Hugging Face cache.

enum SterlingLocalModelInventory {
    /// Same probe and same cache layout the Setup Wizard uses. `FileExistenceProbe`
    /// exists because a bare `fileExists` on this path is not free when it is
    /// called from a View body.
    static func isDownloaded(_ model: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheName = "models--" + model.replacingOccurrences(of: "/", with: "--")
        let path = home
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent(cacheName)
        return FileExistenceProbe.exists(atPath: path.path)
    }

    /// Only the ids routing can act on. Enumerating the whole cache would cost a
    /// directory listing on every read for information nothing uses.
    static func routableDownloads(includingSelected selected: String) -> Set<String> {
        var found: Set<String> = []
        if isDownloaded(SterlingCapabilities.localOperatorModel) {
            found.insert(SterlingCapabilities.localOperatorModel)
        }
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, isDownloaded(trimmed) {
            found.insert(trimmed)
        }
        return found
    }
}

@MainActor
extension SterlingRouter {
    static func inputs(
        from settings: LLMProviderSettings,
        copilotEndpointConfigured: Bool = SterlingConfig.isConfigured,
        copilotModel: String = SterlingConfig.model
    ) -> SterlingRoutingInputs {
        let provider = settings.primaryProvider
        let hasCredential: Bool = {
            if provider.requiresAPIKey {
                return !settings.getAPIKey(for: provider).isEmpty
            }
            // Ollama, LM Studio and a custom OpenAI v1 host take no key; what
            // makes them a route is somewhere to send.
            return !settings.primaryEndpointURL.trimmingCharacters(in: .whitespaces).isEmpty
        }()

        return SterlingRoutingInputs(
            copilotEndpointConfigured: copilotEndpointConfigured,
            copilotModel: copilotModel,
            chatProvider: provider,
            chatModel: settings.primaryModel,
            chatProviderHasCredential: hasCredential,
            downloadedLocalModels: provider == .mlxLocal
                ? SterlingLocalModelInventory.routableDownloads(includingSelected: settings.primaryModel)
                : []
        )
    }

    static func route(for settings: LLMProviderSettings) -> SterlingOperatorRoute {
        route(inputs(from: settings))
    }

    /// The same inputs, but with the agent's own provider/model override applied
    /// where it has one. An agent that pins a provider is routed on THAT, not on
    /// whatever the Chat tab happens to be set to.
    static func inputs(for agent: ChatAgent, settings: LLMProviderSettings) -> SterlingRoutingInputs {
        var inputs = inputs(from: settings)
        guard let pinned = agent.provider else {
            // No override: the agent runs on the app default, which `inputs`
            // already describes. Only the model can still differ.
            let model = agent.resolvedModel(using: settings)
            if model != inputs.chatModel {
                inputs.chatModel = model
                if inputs.chatProvider == .mlxLocal {
                    inputs.downloadedLocalModels = SterlingLocalModelInventory
                        .routableDownloads(includingSelected: model)
                }
            }
            return inputs
        }

        inputs.chatProvider = pinned
        inputs.chatModel = agent.resolvedModel(using: settings)
        inputs.chatProviderHasCredential = pinned.requiresAPIKey
            ? !settings.getAPIKey(for: pinned).isEmpty
            : !settings.primaryEndpointURL.trimmingCharacters(in: .whitespaces).isEmpty
        inputs.downloadedLocalModels = pinned == .mlxLocal
            ? SterlingLocalModelInventory.routableDownloads(includingSelected: inputs.chatModel)
            : []
        return inputs
    }
}
