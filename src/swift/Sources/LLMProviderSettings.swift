import Foundation

enum LLMProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case mlxLocal = "mlx_local"
    case openrouter = "openrouter"
    case anthropic = "anthropic"
    case openai = "openai"
    case deepseek = "deepseek"
    case gemini = "gemini"
    case ollama = "ollama"
    case lmStudio = "lm_studio"
    case customOpenAI = "openai_v1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mlxLocal: return "MLX Local (Privacy-First)"
        case .openrouter: return "OpenRouter (Multi-Model)"
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI (GPT)"
        case .deepseek: return "DeepSeek (Budget)"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (Local OpenAI v1)"
        case .lmStudio: return "LM Studio (Local OpenAI v1)"
        case .customOpenAI: return "Custom OpenAI v1"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .mlxLocal, .ollama, .lmStudio, .customOpenAI:
            return false
        default:
            return true
        }
    }

    static let lowMemoryMLXModel = "mlx-community/granite-4.0-h-micro-4bit"
    static let fullMemoryMLXModel = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"

    /// Granite fits the 16 GB product floor. The 30B MoE stays the default
    /// once the Mac has 24 GB, matching the ACE-Step LM boundary and leaving
    /// room for the rest of the local generation stack.
    static func defaultMLXModel(forPhysicalMemoryGB physicalMemoryGB: Int) -> String {
        physicalMemoryGB < 24 ? lowMemoryMLXModel : fullMemoryMLXModel
    }

    static var defaultMLXModelForCurrentMac: String {
        defaultMLXModel(forPhysicalMemoryGB: LMModel.physicalMemoryGB)
    }

    var defaultModel: String {
        switch self {
        case .mlxLocal: return Self.defaultMLXModelForCurrentMac
        case .openrouter: return "anthropic/claude-3.5-haiku"
        case .anthropic: return "claude-3-5-haiku-20241022"
        case .openai: return "gpt-4o-mini"
        case .deepseek: return "deepseek-chat"
        case .gemini: return "gemini-2.0-flash-exp"
        case .ollama: return "granite3.3:8b"
        case .lmStudio: return "Current loaded model"
        case .customOpenAI: return "default"
        }
    }

    var models: [String] {
        switch self {
        case .mlxLocal:
            return [
                "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
                "mlx-community/Qwen3.5-4B-4bit",
                "mlx-community/Qwen3.5-9B-4bit",
                "mlx-community/Llama-3.2-3B-Instruct-4bit",
                "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
                "mlx-community/numind-NuExtract-1.5-MLX-4bit",
                "mlx-community/gpt-oss-20b-MXFP4-Q8",
                "mlx-community/granite-4.0-h-micro-4bit",
                "lmstudio-community/granite-4.0-h-small-MLX-4bit",
                "mlx-community/granite-3.3-8b-instruct-4bit",
                "mlx-community/GLM-4.7-Flash-4bit"
            ]
        case .ollama:
            return ["granite3.3:8b", "llama3.3:70b"]
        case .lmStudio:
            return ["Current loaded model"]
        case .customOpenAI:
            return ["default"]
        case .openrouter:
            return [
                "anthropic/claude-opus-4.5",
                "anthropic/claude-3.5-sonnet",
                "anthropic/claude-3.5-haiku",
                "meta-llama/llama-3.3-70b",
                "google/gemini-2.0-flash"
            ]
        case .anthropic:
            return [
                "claude-3-5-haiku-20241022",
                "claude-3-5-sonnet-20241022",
                "claude-opus-4-20250514"
            ]
        case .openai:
            return [
                "gpt-4o-mini",
                "gpt-4o",
                "gpt-4-turbo"
            ]
        case .deepseek:
            return ["deepseek-chat"]
        case .gemini:
            return [
                "gemini-2.0-flash-exp",
                "gemini-pro"
            ]
        }
    }

    var description: String {
        switch self {
        case .mlxLocal:
            return "Run AI models locally on your Mac. Zero cost, maximum privacy."
        case .openrouter:
            return "Access all major models through one API. Pay-as-you-go pricing."
        case .anthropic:
            return "Direct access to Claude models. Potentially lower costs than OpenRouter."
        case .openai:
            return "Direct access to GPT models from OpenAI."
        case .deepseek:
            return "Very low cost AI provider with good quality."
        case .gemini:
            return "Google's AI models. Free tier available."
        case .ollama:
            return "Local OpenAI v1 endpoint for Ollama."
        case .lmStudio:
            return "Local OpenAI v1 endpoint for LM Studio."
        case .customOpenAI:
            return "Custom OpenAI v1 compatible endpoint."
        }
    }

    var costEstimate: String {
        switch self {
        case .mlxLocal: return "$0 (Free)"
        case .openrouter: return "~$2.40/1K chats"
        case .anthropic: return "~$2.00/1K chats"
        case .openai: return "~$0.12/1K chats"
        case .deepseek: return "~$0.82/1K chats"
        case .gemini: return "$0 (Free tier)"
        case .ollama: return "$0 (Local)"
        case .lmStudio: return "$0 (Local)"
        case .customOpenAI: return "Varies"
        }
    }
}

enum GenerationMode: String, CaseIterable, Identifiable {
    case auto = "auto"
    case localOnly = "local_only"
    case remoteOnly = "remote_only"
    case both = "both"
    case cloudOnly = "cloud_only"
    case localAndCloud = "local_and_cloud"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .localOnly: return "Local Only"
        case .remoteOnly: return "Remote Only"
        case .both: return "Both (Parallel)"
        case .cloudOnly: return "Cloud Only"
        case .localAndCloud: return "Local + Cloud"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Remote if server configured, cloud if API key set, otherwise local"
        case .localOnly: return "Generate on this Mac only"
        case .remoteOnly: return "Generate on remote server only"
        case .both: return "Local and remote in parallel"
        case .cloudOnly: return "Generate on ACE Music Cloud only"
        case .localAndCloud: return "Local and cloud in parallel"
        }
    }

    /// Whether this mode involves cloud generation
    var usesCloud: Bool {
        switch self {
        case .cloudOnly, .localAndCloud: return true
        default: return false
        }
    }
}

struct ModelPreset: Identifiable, Hashable {
    let id: String
    let displayName: String
    let description: String
}

struct LLMModelDefaults {
    let temperature: Double
    let maxTokens: Int
    let topP: Double
    let systemPromptAddition: String
}

struct LLMAdvancedChatOverrides {
    let customSystemPrompt: String?
    let temperatureOverride: Double?
    let maxTokensOverride: Int?
    let topPOverride: Double?
}

@MainActor
final class LLMProviderSettings: ObservableObject {
    @Published var primaryProvider: LLMProvider = .mlxLocal
    @Published var primaryModel: String = LLMProvider.mlxLocal.defaultModel
    @Published var primaryEndpointURL: String = ""
    @Published var primaryAPIKey: String = ""

    @Published var fallbackProvider: LLMProvider? = nil
    @Published var fallbackModel: String = "lmstudio-community/granite-4.0-h-small-MLX-4bit"
    @Published var fallbackEndpointURL: String = ""
    @Published var fallbackAPIKey: String = ""

    // API Keys
    @Published var openrouterAPIKey: String = ""
    @Published var anthropicAPIKey: String = ""
    @Published var openaiAPIKey: String = ""
    @Published var deepseekAPIKey: String = ""
    @Published var geminiAPIKey: String = ""

    // Models
    @Published var mlxModel: String = LLMProvider.mlxLocal.defaultModel
    @Published var openrouterModel: String = LLMProvider.openrouter.defaultModel
    @Published var anthropicModel: String = LLMProvider.anthropic.defaultModel
    @Published var openaiModel: String = LLMProvider.openai.defaultModel
    @Published var deepseekModel: String = LLMProvider.deepseek.defaultModel
    @Published var geminiModel: String = LLMProvider.gemini.defaultModel
    @Published var extractionModel: String = "mlx-community/Qwen3.5-4B-4bit"
    @Published var customSystemPrompts: [String: String] = [:]

    // Behavior Settings
    @Published var allowAutoGeneration: Bool = false  // Default: Manual mode
    @Published var generationMode: GenerationMode = .auto

    // Advanced per-model settings
    @Published var advancedSettingsExpanded: Bool = false
    @Published var useCustomSystemPrompt: Bool = false
    @Published var customSystemPrompt: String = ""
    @Published var advancedTemperature: Double = 0.7
    @Published var advancedMaxTokens: Int = 600
    @Published var advancedTopP: Double = 0.9

    // Local ACE-Step installation path (used for auto-detection)
    @Published var aceStepPath: String = ""

    // Remote ACE-Step server (optional — leave empty to use local)
    @Published var aceStepServerURL: String = ""   // e.g. "http://192.168.1.50:8000"
    @Published var aceStepServerAPIKey: String = ""

    // ACE Music Cloud API key (free cloud generation via acemusic.ai)
    @Published var aceCloudAPIKey: String = ""

    // Publishing server (defaults to majiks.online when empty)
    @Published var publishServerURL: String = ""   // e.g. "https://my-music-platform.com"
    @Published var publishServerAPIKey: String = ""

    private let service = "com.majik.musicstudio.llm"

    private let defaultModelConfigs: [String: LLMModelDefaults] = [
        "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 2600,
            topP: 0.9,
            systemPromptAddition: "Strong reasoning and creative writing for production-grade songwriting and tool use."
        ),
        "mlx-community/Qwen3.5-4B-4bit": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 1800,
            topP: 0.9,
            systemPromptAddition: "Strong instruction following for chat and songwriting."
        ),
        "mlx-community/Qwen3.5-9B-4bit": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 2200,
            topP: 0.8,
            systemPromptAddition: "Powerful reasoning and creative writing for music production."
        ),
        "mlx-community/gpt-oss-20b-MXFP4-Q8": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 2048,
            topP: 0.9,
            systemPromptAddition: "OpenAI Harmony response format with explicit analysis/final channels."
        ),
        "mlx-community/Llama-3.2-3B-Instruct-4bit": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 1800,
            topP: 0.9,
            systemPromptAddition: "Best creative quality for chat and songwriting."
        ),
        "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 2200,
            topP: 0.9,
            systemPromptAddition: "Stronger reasoning with richer composition support."
        ),
        "mlx-community/granite-4.0-h-micro-4bit": LLMModelDefaults(
            temperature: 0.65,
            maxTokens: 1200,
            topP: 0.85,
            systemPromptAddition: "Fast concise responses with proactive tool usage."
        ),
        "lmstudio-community/granite-4.0-h-small-MLX-4bit": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 1500,
            topP: 0.9,
            systemPromptAddition: "Creative writing strength with balanced detail."
        ),
        "mlx-community/granite-3.3-8b-instruct-4bit": LLMModelDefaults(
            temperature: 0.6,
            maxTokens: 4000,
            topP: 0.85,
            systemPromptAddition: "Practical action-oriented guidance with function calling."
        ),
        "mlx-community/GLM-4.7-Flash-4bit": LLMModelDefaults(
            temperature: 0.9,
            maxTokens: 2500,
            topP: 0.92,
            systemPromptAddition: "Multilingual fast responses with creative flair."
        ),
        "mistral-large-latest": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 2200,
            topP: 0.9,
            systemPromptAddition: "Strong reasoning for nuanced genre blending and polished songwriting."
        ),
        "mistral-medium-latest": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 1800,
            topP: 0.9,
            systemPromptAddition: "Balanced creativity and concise execution for practical music production."
        ),
        "mistral-small-latest": LLMModelDefaults(
            temperature: 0.65,
            maxTokens: 1400,
            topP: 0.9,
            systemPromptAddition: "Direct action-first assistance with short, concrete outputs."
        ),
        "deepseek-chat": LLMModelDefaults(
            temperature: 0.65,
            maxTokens: 2000,
            topP: 0.9,
            systemPromptAddition: "Concise practical production copilot with structured lyric delivery."
        ),
        "deepseek-coder": LLMModelDefaults(
            temperature: 0.55,
            maxTokens: 1800,
            topP: 0.9,
            systemPromptAddition: "Technical precision for structured arrangement and workflow guidance."
        ),
        "gpt-4o": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 2000,
            topP: 0.9,
            systemPromptAddition: "High-quality producer-songwriter mode with coherent end-to-end guidance."
        ),
        "gpt-4-turbo": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 1800,
            topP: 0.9,
            systemPromptAddition: "Fast complete outputs with strong long-context consistency."
        ),
        "gpt-3.5-turbo": LLMModelDefaults(
            temperature: 0.75,
            maxTokens: 1400,
            topP: 0.9,
            systemPromptAddition: "Concise high-utility music assistance with direct lyric output."
        ),
        "claude-3-5-sonnet-20241022": LLMModelDefaults(
            temperature: 0.65,
            maxTokens: 2200,
            topP: 0.9,
            systemPromptAddition: "Strong writing and reasoning for production-ready results."
        ),
        "claude-3-opus-20240229": LLMModelDefaults(
            temperature: 0.7,
            maxTokens: 2400,
            topP: 0.9,
            systemPromptAddition: "Nuanced storytelling and polished song structure support."
        ),
        "claude-3-haiku-20240307": LLMModelDefaults(
            temperature: 0.65,
            maxTokens: 1600,
            topP: 0.9,
            systemPromptAddition: "Fast practical responses with concise concrete direction."
        )
    ]

    /// Sterling's per-model default system prompts. `static` so tests can
    /// enumerate every one without constructing the settings object (whose
    /// init auto-detects models and writes UserDefaults).
    static let defaultSystemPrompts: [String: String] = [
        "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit": """
        You are Sterling, The Producer — a powerful local music production assistant.
        Write complete, polished lyrics immediately when requested with strong narrative structure.
        Provide detailed production guidance (BPM, key, arrangement, instrumentation) with technical and emotional depth.
        Recommend generate_music when the user's intent is clear, and use tools when they help.
        Balance creativity with precision.
        """,
        "mlx-community/Qwen3.5-4B-4bit": """
        You are Sterling, The Producer — a music producer assistant.
        When asked for lyrics, write complete lyrics immediately (verse/chorus/bridge as requested).
        Give concrete production guidance (BPM, key, arrangement, instrumentation).
        Suggest generate_music when the user asks to create tracks.
        """,
        "mlx-community/Qwen3.5-9B-4bit": """
        You are Sterling, The Producer — a powerful music production assistant.
        Write complete, polished lyrics immediately when requested with strong narrative structure.
        Provide detailed production guidance with technical and emotional depth.
        Recommend generate_music when user intent is clear.
        Balance creativity with precision.
        """,
        "mlx-community/Llama-3.2-3B-Instruct-4bit": """
        You are Sterling, The Producer — a music producer assistant.
        When asked for lyrics, write complete lyrics immediately (verse/chorus/bridge as requested).
        Give concrete production guidance (BPM, key, arrangement, instrumentation).
        Suggest generate_music when the user asks to create tracks.
        """,
        "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit": """
        You are Sterling, The Producer — a detailed music producer assistant.
        Deliver complete lyrical outputs immediately when requested.
        Provide structured, high-quality production guidance and arrangement detail.
        Suggest generate_music when users want final audio generation.
        """,
        "mlx-community/granite-4.0-h-micro-4bit": """
        **GRANITE H-MICRO EXECUTION MODE (CRITICAL):**
        When asked to write lyrics, write them immediately. Do NOT announce intent first.
        BAD: "I'm going to write a verse..."
        GOOD: Output the verse directly.
        Prioritize concrete production details and action over meta commentary.
        """,
        "lmstudio-community/granite-4.0-h-small-MLX-4bit": """
        You are a creative music assistant focused on complete outputs.
        Deliver full lyric sections, practical arrangement details, and actionable production guidance.
        Use generate_music recommendations when user intent is generation.
        """,
        "gpt-4o": """
        Act as an expert producer-songwriter.
        Write complete lyrics immediately when asked and provide practical production detail.
        When users ask to create music, suggest generate_music with explicit parameters.
        """,
        "gpt-4-turbo": """
        Prioritize complete delivery and consistency across long conversations.
        Give full lyrics and actionable production direction.
        Suggest generate_music when user intent is direct generation.
        """,
        "gpt-3.5-turbo": """
        Be concise and action-first.
        Provide complete lyrics when requested and concrete production suggestions.
        Suggest generate_music when users ask to create tracks.
        """,
        "deepseek-chat": """
        You are a music production copilot.
        Deliver complete lyrical outputs and specific BPM/key/instrumentation recommendations.
        Suggest generate_music when users want to generate tracks.
        """,
        "deepseek-coder": """
        Use technical precision for structured music workflows.
        Provide complete lyric output when requested and explicit parameter recommendations.
        Suggest generate_music with concrete settings when generation is requested.
        """,
        "claude-3-5-sonnet-20241022": """
        Use strong writing and reasoning for production-ready outputs.
        Write complete lyrics immediately and provide clear, practical musical direction.
        Suggest generate_music when user intent is creation.
        """,
        "claude-3-opus-20240229": """
        Deliver high-quality, fully formed creative outputs.
        Provide complete lyrical sections, arrangement strategy, and polished production guidance.
        Suggest generate_music for actionable generation steps.
        """,
        "claude-3-haiku-20240307": """
        Be fast, direct, and practical.
        Output complete lyrics immediately when requested and keep guidance concise.
        Suggest generate_music when intent is generation.
        """
    ]

    init() {
        load()

        // Avoid overriding explicit environment config.
        let hasEnvProvider = ProcessInfo.processInfo.environment["LLM_PROVIDER"] != nil

        if !hasEnvProvider {
            // Priority 1: ALWAYS check for bundled MLX models first (Ultra Complete edition)
            // This ensures zero-setup experience even if user has previous settings
            if autoDetectBundledMLXModel() {
                print("[LLMSettings] Auto-configured for bundled MLX model (zero setup!)")
            }
            // Priority 2: Check for ACE-Step installation
            else if autoDetectACEStep() {
                print("[LLMSettings] Auto-configured for local MLX models")
            }
            // Priority 3: Keep stored settings if they exist
            else if UserDefaults.standard.string(forKey: "majik_primary_provider") != nil {
                print("[LLMSettings] Using stored provider settings")
            }
            // Priority 4: Default to OpenRouter
            else {
                primaryProvider = .openrouter
                primaryModel = LLMProvider.openrouter.defaultModel
                save()
                print("[LLMSettings] No local models found, defaulting to OpenRouter")
            }
        }
    }

    func load() {
        // First, check environment variables (takes precedence)
        let env = ProcessInfo.processInfo.environment

        // Load provider from environment or UserDefaults
        if let envProvider = env["LLM_PROVIDER"],
           let provider = LLMProvider(rawValue: envProvider) {
            primaryProvider = provider
            print("[LLMSettings] Using provider from environment: \(envProvider)")
        } else if let providerStr = UserDefaults.standard.string(forKey: "majik_primary_provider"),
                  let provider = LLMProvider(rawValue: providerStr) {
            primaryProvider = provider
        }

        if let envFallback = env["LLM_FALLBACK_PROVIDER"] {
            fallbackProvider = LLMProvider(rawValue: envFallback)
        } else if let fallbackStr = UserDefaults.standard.string(forKey: "majik_fallback_provider") {
            fallbackProvider = LLMProvider(rawValue: fallbackStr)
        }

        do {
            // Load API keys (environment takes precedence over keychain) - SECURE
            if let envKey = env["OPENROUTER_API_KEY"], !envKey.isEmpty {
                openrouterAPIKey = envKey
                print("[LLMSettings] Using OpenRouter API key from environment")
            } else if let key = try KeychainStore.get(account: "openrouter_key", service: service) {
                openrouterAPIKey = key
            }

            if let envKey = env["ANTHROPIC_API_KEY"], !envKey.isEmpty {
                anthropicAPIKey = envKey
            } else if let key = try KeychainStore.get(account: "anthropic_key", service: service) {
                anthropicAPIKey = key
            }

            if let envKey = env["OPENAI_API_KEY"], !envKey.isEmpty {
                openaiAPIKey = envKey
            } else if let key = try KeychainStore.get(account: "openai_key", service: service) {
                openaiAPIKey = key
            }

            if let envKey = env["DEEPSEEK_API_KEY"], !envKey.isEmpty {
                deepseekAPIKey = envKey
            } else if let key = try KeychainStore.get(account: "deepseek_key", service: service) {
                deepseekAPIKey = key
            }

            if let envKey = env["GEMINI_API_KEY"], !envKey.isEmpty {
                geminiAPIKey = envKey
            } else if let key = try KeychainStore.get(account: "gemini_key", service: service) {
                geminiAPIKey = key
            }

            if let envKey = env["LLM_API_KEY"], !envKey.isEmpty {
                primaryAPIKey = envKey
            } else if let key = try KeychainStore.get(account: "openai_v1_key", service: service) {
                primaryAPIKey = key
            }

            if let envKey = env["LLM_FALLBACK_API_KEY"], !envKey.isEmpty {
                fallbackAPIKey = envKey
            }
        } catch {
            print("Error loading API keys from keychain: \(error)")
        }

        // Load models from environment or UserDefaults (not sensitive, no keychain prompts)
        if let envModel = env["MLX_MODEL"], !envModel.isEmpty {
            mlxModel = envModel
        } else {
            mlxModel = UserDefaults.standard.string(forKey: "majik_mlx_model") ?? LLMProvider.mlxLocal.defaultModel
        }

        if let envModel = env["OPENROUTER_MODEL"], !envModel.isEmpty {
            openrouterModel = envModel
            print("[LLMSettings] Using OpenRouter model from environment: \(envModel)")
        } else {
            openrouterModel = UserDefaults.standard.string(forKey: "majik_openrouter_model") ?? LLMProvider.openrouter.defaultModel
        }

        if let envModel = env["ANTHROPIC_MODEL"], !envModel.isEmpty {
            anthropicModel = envModel
        } else {
            anthropicModel = UserDefaults.standard.string(forKey: "majik_anthropic_model") ?? LLMProvider.anthropic.defaultModel
        }

        if let envModel = env["OPENAI_MODEL"], !envModel.isEmpty {
            openaiModel = envModel
        } else {
            openaiModel = UserDefaults.standard.string(forKey: "majik_openai_model") ?? LLMProvider.openai.defaultModel
        }

        if let envModel = env["DEEPSEEK_MODEL"], !envModel.isEmpty {
            deepseekModel = envModel
        } else {
            deepseekModel = UserDefaults.standard.string(forKey: "majik_deepseek_model") ?? LLMProvider.deepseek.defaultModel
        }

        if let envModel = env["GEMINI_MODEL"], !envModel.isEmpty {
            geminiModel = envModel
        } else {
            geminiModel = UserDefaults.standard.string(forKey: "majik_gemini_model") ?? LLMProvider.gemini.defaultModel
        }

        aceStepPath = UserDefaults.standard.string(forKey: "majik_ace_step_path") ?? ""
        aceStepServerURL = UserDefaults.standard.string(forKey: "majik_ace_step_server_url") ?? ""
        do {
            if let serverKey = try KeychainStore.get(account: "ace_step_server_api_key", service: service) {
                aceStepServerAPIKey = serverKey
            }
        } catch {
            print("Error loading ACE-Step server API key from keychain: \(error)")
        }
        do {
            if let cloudKey = try KeychainStore.get(account: "ace_cloud_api_key", service: service) {
                aceCloudAPIKey = cloudKey
            }
        } catch {
            print("Error loading ACE Cloud API key from keychain: \(error)")
        }

        publishServerURL = UserDefaults.standard.string(forKey: "majik_publish_server_url") ?? ""
        do {
            if let pubKey = try KeychainStore.get(account: "publish_server_api_key", service: service) {
                publishServerAPIKey = pubKey
            }
        } catch {
            print("Error loading publish server API key from keychain: \(error)")
        }

        // One-time migration: clean up legacy appTier from UserDefaults
        UserDefaults.standard.removeObject(forKey: "majik_app_tier")

        // The chat/extraction model migrations, including the recovery for the
        // v3.5 one that spent its flag on a no-op. They live in
        // `MajikChatModelMigrations` so they can be driven against a throwaway
        // UserDefaults suite; see that file for why `.deferred` exists at all.
        let migrations = MajikChatModelMigrations.apply(
            MajikChatModelMigrationInputs(
                defaults: UserDefaults.standard,
                downloadedLocalModels: SterlingLocalModelInventory.routableDownloads(
                    includingSelected: UserDefaults.standard.string(forKey: "majik_mlx_model") ?? ""
                ),
                copilotEndpointConfigured: SterlingConfig.isConfigured
            )
        )
        for (flag, outcome) in migrations.outcomes.sorted(by: { $0.key < $1.key }) {
            print("[LLMSettings] Migration \(flag): \(outcome)")
        }
        if let migratedChatModel = migrations.chatModel {
            mlxModel = migratedChatModel
            if primaryProvider == .mlxLocal {
                primaryModel = mlxModel
                UserDefaults.standard.set(primaryModel, forKey: "majik_primary_model")
            }
        }

        // Primary model + endpoint (new flexible config)
        if let envModel = env["LLM_MODEL"], !envModel.isEmpty {
            primaryModel = envModel
        } else if let storedModel = UserDefaults.standard.string(forKey: "majik_primary_model"),
                  !storedModel.isEmpty {
            primaryModel = storedModel
        } else {
            primaryModel = modelForProvider(primaryProvider)
        }

        if let envEndpoint = env["LLM_ENDPOINT_URL"], !envEndpoint.isEmpty {
            primaryEndpointURL = envEndpoint
        } else {
            primaryEndpointURL = UserDefaults.standard.string(forKey: "majik_primary_endpoint_url") ?? defaultEndpointURL(for: primaryProvider)
        }

        // Fallback model + endpoint
        if let envModel = env["LLM_FALLBACK_MODEL"], !envModel.isEmpty {
            fallbackModel = envModel
        } else if let storedModel = UserDefaults.standard.string(forKey: "majik_fallback_model"),
                  !storedModel.isEmpty {
            fallbackModel = storedModel
        } else if let fallback = fallbackProvider, fallbackModel.isEmpty {
            fallbackModel = modelForProvider(fallback)
        }

        if let envEndpoint = env["LLM_FALLBACK_ENDPOINT_URL"], !envEndpoint.isEmpty {
            fallbackEndpointURL = envEndpoint
        } else if fallbackProvider != nil {
            fallbackEndpointURL = UserDefaults.standard.string(forKey: "majik_fallback_endpoint_url") ?? defaultEndpointURL(for: fallbackProvider ?? .openrouter)
        }

        if primaryAPIKey.isEmpty {
            primaryAPIKey = apiKeyForProvider(primaryProvider)
        }

        if fallbackAPIKey.isEmpty, let fallback = fallbackProvider {
            fallbackAPIKey = apiKeyForProvider(fallback)
        }

        // Load behavior settings from UserDefaults
        allowAutoGeneration = UserDefaults.standard.bool(forKey: "majik_allow_auto_generation")
        if let modeStr = UserDefaults.standard.string(forKey: "majik_generation_mode"),
           let mode = GenerationMode(rawValue: modeStr) {
            generationMode = mode
        }
        let savedExtraction = UserDefaults.standard.string(forKey: "majik_extraction_model") ?? "mlx-community/Qwen3.5-4B-4bit"
        // Migrate removed models (NuExtract) to Qwen 3.5 4B default
        if savedExtraction.lowercased().contains("nuextract") {
            extractionModel = "mlx-community/Qwen3.5-4B-4bit"
        } else {
            extractionModel = savedExtraction
        }
        if let promptData = UserDefaults.standard.data(forKey: "majik_custom_system_prompts"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: promptData) {
            customSystemPrompts = decoded
        } else {
            customSystemPrompts = [:]
        }

        advancedSettingsExpanded = UserDefaults.standard.bool(forKey: "majik_advanced_settings_expanded")
        loadAdvancedSettings(forModel: primaryModel)
    }

    func save() {
        // Save provider selection to UserDefaults (not sensitive)
        UserDefaults.standard.set(primaryProvider.rawValue, forKey: "majik_primary_provider")
        if let fallback = fallbackProvider {
            UserDefaults.standard.set(fallback.rawValue, forKey: "majik_fallback_provider")
        } else {
            UserDefaults.standard.removeObject(forKey: "majik_fallback_provider")
        }

        // Sync primary model/API key to provider-specific storage
        applyPrimaryToProviderStorage()
        applyFallbackToProviderStorage()

        // Save API keys to Keychain (secure)
        do {
            try KeychainStore.set(openrouterAPIKey, account: "openrouter_key", service: service)
            try KeychainStore.set(anthropicAPIKey, account: "anthropic_key", service: service)
            try KeychainStore.set(openaiAPIKey, account: "openai_key", service: service)
            try KeychainStore.set(deepseekAPIKey, account: "deepseek_key", service: service)
            try KeychainStore.set(geminiAPIKey, account: "gemini_key", service: service)
            if !primaryAPIKey.isEmpty {
                try KeychainStore.set(primaryAPIKey, account: "openai_v1_key", service: service)
            }
        } catch {
            print("Error saving API keys to keychain: \(error)")
        }

        // Save models to UserDefaults (not sensitive, no password prompts!)
        UserDefaults.standard.set(mlxModel, forKey: "majik_mlx_model")
        UserDefaults.standard.set(openrouterModel, forKey: "majik_openrouter_model")
        UserDefaults.standard.set(anthropicModel, forKey: "majik_anthropic_model")
        UserDefaults.standard.set(openaiModel, forKey: "majik_openai_model")
        UserDefaults.standard.set(deepseekModel, forKey: "majik_deepseek_model")
        UserDefaults.standard.set(geminiModel, forKey: "majik_gemini_model")
        UserDefaults.standard.set(aceStepPath, forKey: "majik_ace_step_path")
        UserDefaults.standard.set(aceStepServerURL, forKey: "majik_ace_step_server_url")
        do {
            try KeychainStore.set(aceStepServerAPIKey, account: "ace_step_server_api_key", service: service)
        } catch {
            print("Error saving ACE-Step server API key to keychain: \(error)")
        }
        do {
            try KeychainStore.set(aceCloudAPIKey, account: "ace_cloud_api_key", service: service)
        } catch {
            print("Error saving ACE Cloud API key to keychain: \(error)")
        }
        UserDefaults.standard.set(publishServerURL, forKey: "majik_publish_server_url")
        do {
            try KeychainStore.set(publishServerAPIKey, account: "publish_server_api_key", service: service)
        } catch {
            print("Error saving publish server API key to keychain: \(error)")
        }
        UserDefaults.standard.set(primaryModel, forKey: "majik_primary_model")
        UserDefaults.standard.set(fallbackModel, forKey: "majik_fallback_model")
        UserDefaults.standard.set(primaryEndpointURL, forKey: "majik_primary_endpoint_url")
        UserDefaults.standard.set(fallbackEndpointURL, forKey: "majik_fallback_endpoint_url")
        UserDefaults.standard.set(extractionModel, forKey: "majik_extraction_model")
        if let encodedPrompts = try? JSONEncoder().encode(customSystemPrompts) {
            UserDefaults.standard.set(encodedPrompts, forKey: "majik_custom_system_prompts")
        }

        // Save behavior settings to UserDefaults
        UserDefaults.standard.set(allowAutoGeneration, forKey: "majik_allow_auto_generation")
        UserDefaults.standard.set(generationMode.rawValue, forKey: "majik_generation_mode")
        UserDefaults.standard.set(advancedSettingsExpanded, forKey: "majik_advanced_settings_expanded")
        saveAdvancedSettings(forModel: primaryModel)
    }

    var currentModelDefaults: LLMModelDefaults {
        defaultsForModel(primaryModel, provider: primaryProvider)
    }

    var isCustomTemperature: Bool {
        abs(advancedTemperature - currentModelDefaults.temperature) > 0.0001
    }

    var isCustomMaxTokens: Bool {
        advancedMaxTokens != currentModelDefaults.maxTokens
    }

    var isCustomTopP: Bool {
        abs(advancedTopP - currentModelDefaults.topP) > 0.0001
    }

    var hasActiveCustomPrompt: Bool {
        useCustomSystemPrompt && !customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCustomAdvancedSettings: Bool {
        hasActiveCustomPrompt || isCustomTemperature || isCustomMaxTokens || isCustomTopP
    }

    var extractionModelOptions: [String] {
        [
            "mlx-community/Qwen3.5-4B-4bit",
            "mlx-community/granite-3.3-2b-instruct-8bit",
            "chat",
            "mlx-community/granite-4.0-h-micro-4bit",
            "lmstudio-community/granite-4.0-h-small-MLX-4bit",
        ]
    }

    var resolvedExtractionModel: String {
        extractionModel
    }

    var extractionModelDisplayLabel: String {
        switch extractionModel {
        case "mlx-community/Qwen3.5-4B-4bit":
            return "Qwen 3.5 4B (Default)"
        case "mlx-community/granite-3.3-2b-instruct-8bit":
            return "Granite 3.3 2B"
        case "chat":
            return "Chat Model"
        default:
            return extractionModel
        }
    }

    func chatOverridesForCurrentModel() -> LLMAdvancedChatOverrides {
        LLMAdvancedChatOverrides(
            customSystemPrompt: hasActiveCustomPrompt ? customSystemPrompt : nil,
            temperatureOverride: isCustomTemperature ? advancedTemperature : nil,
            maxTokensOverride: isCustomMaxTokens ? advancedMaxTokens : nil,
            topPOverride: isCustomTopP ? advancedTopP : nil
        )
    }

    func getSystemPromptFor(model: String, isExtraction: Bool = false) -> String {
        let key = promptStorageKey(model: model, isExtraction: isExtraction)
        if let custom = customSystemPrompts[key], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        if isExtraction {
            return Self.defaultEngineerPrompt
        }
        if let basePrompt = Self.defaultSystemPrompts[model], !basePrompt.isEmpty {
            return basePrompt
        }
        if let defaults = defaultModelConfigs[model], !defaults.systemPromptAddition.isEmpty {
            return defaults.systemPromptAddition
        }
        return "Use the default system prompt for this model."
    }

    func saveCustomPrompt(for model: String, prompt: String, isExtraction: Bool = false) {
        let key = promptStorageKey(model: model, isExtraction: isExtraction)
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customSystemPrompts.removeValue(forKey: key)
        } else {
            customSystemPrompts[key] = prompt
        }
        save()
    }

    func resetPromptToDefault(for model: String, isExtraction: Bool = false) {
        customSystemPrompts.removeValue(forKey: promptStorageKey(model: model, isExtraction: isExtraction))
        save()
    }

    func loadAdvancedSettings(forModel model: String) {
        let defaults = defaultsForModel(model, provider: primaryProvider)
        let userDefaults = UserDefaults.standard

        useCustomSystemPrompt = userDefaults.bool(forKey: modelScopedKey(prefix: "use_custom_system_prompt", model: model))
        customSystemPrompt = userDefaults.string(forKey: modelScopedKey(prefix: "custom_prompt", model: model)) ?? ""

        if let temp = userDefaults.object(forKey: modelScopedKey(prefix: "temperature", model: model)) as? Double {
            advancedTemperature = clamp(temp, min: 0.0, max: 1.0)
        } else {
            advancedTemperature = defaults.temperature
        }

        if let tokens = userDefaults.object(forKey: modelScopedKey(prefix: "max_tokens", model: model)) as? Int {
            advancedMaxTokens = clamp(tokens, min: 100, max: 4000)
        } else {
            advancedMaxTokens = defaults.maxTokens
        }

        if let topP = userDefaults.object(forKey: modelScopedKey(prefix: "top_p", model: model)) as? Double {
            advancedTopP = clamp(topP, min: 0.0, max: 1.0)
        } else {
            advancedTopP = defaults.topP
        }
    }

    func saveAdvancedSettingsForCurrentModel() {
        saveAdvancedSettings(forModel: primaryModel)
    }

    func resetAdvancedSettingsToDefaults() {
        let defaults = defaultsForModel(primaryModel, provider: primaryProvider)
        useCustomSystemPrompt = false
        customSystemPrompt = ""
        advancedTemperature = defaults.temperature
        advancedMaxTokens = defaults.maxTokens
        advancedTopP = defaults.topP
        saveAdvancedSettings(forModel: primaryModel)
    }

    /// Auto-detects ACE-Step installation and configures local MLX if found.
    /// Checks bundled ACE-Step in app bundle FIRST, then falls back to home directory.
    @discardableResult
    func autoDetectACEStep() -> Bool {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser

        // FIRST: Check for bundled ACE-Step in app bundle (Complete/Standard editions)
        if let bundlePath = Bundle.main.resourcePath {
            let bundledACEStepPath = URL(fileURLWithPath: bundlePath).appendingPathComponent("ACE-Step")
            let bundledCheckpointsPath = bundledACEStepPath.appendingPathComponent("checkpoints")

            if fileManager.fileExists(atPath: bundledCheckpointsPath.path) {
                print("[LLMSettings] ✅ Found BUNDLED ACE-Step at: \(bundledACEStepPath.path)")
                aceStepPath = bundledACEStepPath.path

                // Auto-configure to use local MLX. Seed the chat model with the
                // recommended local default ONLY when the user has not already
                // chosen one, so a deliberate selection (or the migrated default)
                // survives this every-launch auto-detect instead of being reset
                // back to the tiny 4B. (This runs before "keep stored settings".)
                primaryProvider = .mlxLocal
                let hasExplicitMLXModel = ProcessInfo.processInfo.environment["MLX_MODEL"]?.isEmpty == false
                    || UserDefaults.standard.string(forKey: "majik_mlx_model") != nil
                if !hasExplicitMLXModel {
                    mlxModel = LLMProvider.mlxLocal.defaultModel
                }
                primaryModel = mlxModel
                save()

                return true
            }
        }

        // SECOND: Fall back to external installations in home directory
        let possiblePaths = [
            homeDir.appendingPathComponent("ACE-Step-1.5"),
            homeDir.appendingPathComponent("ACE-Step"),
            homeDir.appendingPathComponent("Projects/ACE-Step-1.5"),
            homeDir.appendingPathComponent("Developer/ACE-Step-1.5")
        ]

        for path in possiblePaths {
            // Check for model weight directories (HuggingFace download structure)
            let vaePath = path.appendingPathComponent("vae")
            let turboPath = path.appendingPathComponent("acestep-v15-turbo")
            // Also check legacy structures
            let checkpointsPath = path.appendingPathComponent("checkpoints")
            let venvPath = path.appendingPathComponent(".venv/bin/python")

            if fileManager.fileExists(atPath: vaePath.path) ||
               fileManager.fileExists(atPath: turboPath.path) ||
               fileManager.fileExists(atPath: checkpointsPath.path) ||
               fileManager.fileExists(atPath: venvPath.path) {
                print("[LLMSettings] Found external ACE-Step at: \(path.path)")
                aceStepPath = path.path

                // Auto-configure to use local MLX. Seed the chat model with the
                // recommended local default ONLY when the user has not already
                // chosen one, so a deliberate selection (or the migrated default)
                // survives this every-launch auto-detect instead of being reset
                // back to the tiny 4B. (This runs before "keep stored settings".)
                primaryProvider = .mlxLocal
                let hasExplicitMLXModel = ProcessInfo.processInfo.environment["MLX_MODEL"]?.isEmpty == false
                    || UserDefaults.standard.string(forKey: "majik_mlx_model") != nil
                if !hasExplicitMLXModel {
                    mlxModel = LLMProvider.mlxLocal.defaultModel
                }
                primaryModel = mlxModel
                save()

                return true
            }
        }

        print("[LLMSettings] ACE-Step not found in bundle or common locations")
        return false
    }

    /// Auto-detects bundled MLX models in the app bundle (Ultra Complete edition)
    @discardableResult
    func autoDetectBundledMLXModel() -> Bool {
        guard let bundlePath = Bundle.main.resourcePath else {
            print("[LLMSettings] Could not find app bundle resource path")
            return false
        }

        let fileManager = FileManager.default
        let mlxModelsPath = "\(bundlePath)/mlx_models"

        // Check if MLX models directory exists
        guard fileManager.fileExists(atPath: mlxModelsPath) else {
            print("[LLMSettings] No bundled MLX models found")
            return false
        }

        // Verify it contains actual model files and detect which model
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: mlxModelsPath)
            let hasModelFiles = contents.contains {
                $0.hasSuffix(".safetensors") ||
                $0.hasSuffix(".npz") ||
                $0 == "config.json"
            }

            if hasModelFiles {
                print("[LLMSettings] ✅ Found bundled MLX model at: \(mlxModelsPath)")

                // Detect which model by checking MODEL_INFO.txt
                let modelInfoPath = "\(mlxModelsPath)/MODEL_INFO.txt"
                var detectedModel = "mlx-community/gpt-oss-20b-MXFP4-Q8"  // Default

                if fileManager.fileExists(atPath: modelInfoPath),
                   let modelInfo = try? String(contentsOfFile: modelInfoPath) {
                    if modelInfo.contains("Granite 4.0 H-Micro") || modelInfo.contains("granite-4.0-h-micro") {
                        detectedModel = "mlx-community/granite-4.0-h-micro-4bit"
                        print("[LLMSettings] Detected bundled model: Granite 4.0 H-Micro (fast!)")
                    } else if modelInfo.contains("GPT-OSS-20B") || modelInfo.contains("gpt-oss-20b") {
                        detectedModel = "mlx-community/gpt-oss-20b-MXFP4-Q8"
                        print("[LLMSettings] Detected bundled model: GPT-OSS-20B (best quality)")
                    }
                }

                // Auto-configure to use bundled local MLX model
                primaryProvider = .mlxLocal
                let hasExplicitMLXModel = ProcessInfo.processInfo.environment["MLX_MODEL"]?.isEmpty == false
                    || UserDefaults.standard.string(forKey: "majik_mlx_model") != nil
                if !hasExplicitMLXModel {
                    mlxModel = detectedModel
                }
                primaryModel = mlxModel

                // Set environment variable for MLX to find bundled models
                setenv("MLX_MODELS_PATH", mlxModelsPath, 1)

                save()

                print("[LLMSettings] 🤖 Configured for bundled \(detectedModel) - Zero setup required!")
                return true
            } else {
                print("[LLMSettings] MLX models directory exists but contains no model files")
                return false
            }
        } catch {
            print("[LLMSettings] Error checking bundled MLX models: \(error)")
            return false
        }
    }

    func getAPIKey(for provider: LLMProvider) -> String {
        switch provider {
        case .mlxLocal: return ""
        case .openrouter: return openrouterAPIKey
        case .anthropic: return anthropicAPIKey
        case .openai: return openaiAPIKey
        case .deepseek: return deepseekAPIKey
        case .gemini: return geminiAPIKey
        case .ollama, .lmStudio, .customOpenAI:
            return primaryAPIKey
        }
    }

    func getModel(for provider: LLMProvider) -> String {
        switch provider {
        case .mlxLocal: return mlxModel
        case .openrouter: return openrouterModel
        case .anthropic: return anthropicModel
        case .openai: return openaiModel
        case .deepseek: return deepseekModel
        case .gemini: return geminiModel
        case .ollama, .lmStudio, .customOpenAI:
            return primaryModel
        }
    }

    func getEnvironmentVariables() -> [String: String] {
        var env: [String: String] = [:]

        env["LLM_PROVIDER"] = primaryProvider.rawValue
        env["LLM_MODEL"] = primaryModel
        env["MAJIK_EXTRACTION_MODEL"] = resolvedExtractionModel
        if let encodedPrompts = try? JSONEncoder().encode(customSystemPrompts),
           let json = String(data: encodedPrompts, encoding: .utf8) {
            env["MAJIK_CUSTOM_SYSTEM_PROMPTS_JSON"] = json
        }
        if !primaryEndpointURL.isEmpty {
            env["LLM_ENDPOINT_URL"] = primaryEndpointURL
        }
        if !primaryAPIKey.isEmpty {
            env["LLM_API_KEY"] = primaryAPIKey
        }

        if let fallback = fallbackProvider {
            env["LLM_FALLBACK_PROVIDER"] = fallback.rawValue
            if !fallbackModel.isEmpty {
                env["LLM_FALLBACK_MODEL"] = fallbackModel
            }
            if !fallbackEndpointURL.isEmpty {
                env["LLM_FALLBACK_ENDPOINT_URL"] = fallbackEndpointURL
            }
            if !fallbackAPIKey.isEmpty {
                env["LLM_FALLBACK_API_KEY"] = fallbackAPIKey
            }
        }

        // Generation mode
        env["GENERATION_MODE"] = generationMode.rawValue

        // Remote ACE-Step server
        if !aceStepServerURL.isEmpty {
            env["ACE_STEP_SERVER_URL"] = aceStepServerURL
        }
        if !aceStepServerAPIKey.isEmpty {
            env["ACE_STEP_SERVER_API_KEY"] = aceStepServerAPIKey
        }
        if !aceCloudAPIKey.isEmpty {
            env["ACE_CLOUD_API_KEY"] = aceCloudAPIKey
        }

        // Publishing server
        if !publishServerURL.isEmpty {
            env["PUBLISH_SERVER_URL"] = publishServerURL
        }
        if !publishServerAPIKey.isEmpty {
            env["PUBLISH_SERVER_API_KEY"] = publishServerAPIKey
        }

        // Provider-specific environment variables (backward compatibility)
        applyEnv(for: primaryProvider, model: primaryModel, apiKey: primaryAPIKey, into: &env, allowOverride: true)
        if let fallback = fallbackProvider {
            applyEnv(for: fallback, model: fallbackModel, apiKey: fallbackAPIKey, into: &env, allowOverride: false)
        }

        // Export all configured provider credentials/models so per-agent routing can
        // switch providers without requiring a backend restart.
        env["MLX_MODEL"] = mlxModel
        if !openrouterAPIKey.isEmpty {
            env["OPENROUTER_API_KEY"] = openrouterAPIKey
        }
        if !openrouterModel.isEmpty {
            env["OPENROUTER_MODEL"] = openrouterModel
        }
        if !anthropicAPIKey.isEmpty {
            env["ANTHROPIC_API_KEY"] = anthropicAPIKey
        }
        if !anthropicModel.isEmpty {
            env["ANTHROPIC_MODEL"] = anthropicModel
        }
        if !openaiAPIKey.isEmpty {
            env["OPENAI_API_KEY"] = openaiAPIKey
        }
        if !openaiModel.isEmpty {
            env["OPENAI_MODEL"] = openaiModel
        }
        if !deepseekAPIKey.isEmpty {
            env["DEEPSEEK_API_KEY"] = deepseekAPIKey
        }
        if !deepseekModel.isEmpty {
            env["DEEPSEEK_MODEL"] = deepseekModel
        }
        if !geminiAPIKey.isEmpty {
            env["GEMINI_API_KEY"] = geminiAPIKey
        }
        if !geminiModel.isEmpty {
            env["GEMINI_MODEL"] = geminiModel
        }

        return env
    }

    func modelDefaults(for model: String, provider: LLMProvider) -> LLMModelDefaults {
        defaultsForModel(model, provider: provider)
    }

    func chatOverrides(forModel model: String, provider: LLMProvider) -> LLMAdvancedChatOverrides {
        let defaults = defaultsForModel(model, provider: provider)
        let userDefaults = UserDefaults.standard

        let useStoredCustomPrompt = userDefaults.bool(forKey: modelScopedKey(prefix: "use_custom_system_prompt", model: model))
        let storedPrompt = userDefaults.string(forKey: modelScopedKey(prefix: "custom_prompt", model: model))
        let trimmedPrompt = storedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customPrompt = useStoredCustomPrompt ? trimmedPrompt : nil

        let storedTemperature = (userDefaults.object(forKey: modelScopedKey(prefix: "temperature", model: model)) as? Double)
            .map { clamp($0, min: 0.0, max: 1.0) }
        let storedMaxTokens = (userDefaults.object(forKey: modelScopedKey(prefix: "max_tokens", model: model)) as? Int)
            .map { clamp($0, min: 100, max: 4000) }
        let storedTopP = (userDefaults.object(forKey: modelScopedKey(prefix: "top_p", model: model)) as? Double)
            .map { clamp($0, min: 0.0, max: 1.0) }

        let temperatureOverride = storedTemperature.flatMap {
            abs($0 - defaults.temperature) > 0.0001 ? $0 : nil
        }
        let maxTokensOverride = storedMaxTokens.flatMap {
            $0 != defaults.maxTokens ? $0 : nil
        }
        let topPOverride = storedTopP.flatMap {
            abs($0 - defaults.topP) > 0.0001 ? $0 : nil
        }

        return LLMAdvancedChatOverrides(
            customSystemPrompt: (customPrompt?.isEmpty == false) ? customPrompt : nil,
            temperatureOverride: temperatureOverride,
            maxTokensOverride: maxTokensOverride,
            topPOverride: topPOverride
        )
    }

    func presetsForProvider(_ provider: LLMProvider) -> [ModelPreset] {
        switch provider {
        case .mlxLocal:
            return [
                ModelPreset(
                    id: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
                    displayName: "Qwen3 30B A3B (Recommended)",
                    description: "Strong local MoE (30B total / ~3B active) — Sterling's default: best local chat, reasoning, and tool use (~17GB, 32GB+ RAM)"
                ),
                ModelPreset(
                    id: "mlx-community/Qwen3.5-4B-4bit",
                    displayName: "Qwen 3.5 4B (Lightweight)",
                    description: "Same model as extraction — one download, strong chat + instruction following on modest hardware"
                ),
                ModelPreset(
                    id: "mlx-community/Qwen3.5-9B-4bit",
                    displayName: "Qwen 3.5 9B",
                    description: "Powerful reasoning and creative writing, thinking disabled for speed"
                ),
                ModelPreset(
                    id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                    displayName: "Llama 3.2 3B",
                    description: "Creative chat quality for songwriting and ideation"
                ),
                ModelPreset(
                    id: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
                    displayName: "Llama 3.1 8B",
                    description: "Stronger reasoning with larger capacity"
                ),
                ModelPreset(
                    id: "mlx-community/gpt-oss-20b-MXFP4-Q8",
                    displayName: "GPT-OSS-20B (Best Quality)",
                    description: "20B params, detailed responses, excellent reasoning"
                ),
                ModelPreset(
                    id: "lmstudio-community/granite-4.0-h-small-MLX-4bit",
                    displayName: "Granite 4.0 H-Small (9B Active)",
                    description: "IBM's workhorse, excellent for function calling"
                ),
                ModelPreset(
                    id: "mlx-community/granite-4.0-h-micro-4bit",
                    displayName: "Granite 4.0 H-Micro (Fastest)",
                    description: "3B hybrid, blazing fast (1.1s), great quality"
                ),
                ModelPreset(
                    id: "mlx-community/granite-3.3-8b-instruct-4bit",
                    displayName: "Granite 3.3 8B",
                    description: "8B params, solid quality, no tool calling"
                ),
                ModelPreset(
                    id: "mlx-community/GLM-4.7-Flash-4bit",
                    displayName: "GLM-4.7 Flash",
                    description: "Multilingual, fast"
                )
            ]
        case .ollama:
            return [
                ModelPreset(id: "granite3.3:8b", displayName: "granite3.3:8b", description: "Ollama model"),
                ModelPreset(id: "llama3.3:70b", displayName: "llama3.3:70b", description: "Ollama model")
            ]
        case .lmStudio:
            return [
                ModelPreset(id: "Current loaded model", displayName: "Current loaded model", description: "Uses the model currently loaded in LM Studio")
            ]
        case .openrouter:
            return [
                ModelPreset(id: "anthropic/claude-3.5-haiku", displayName: "Claude 3.5 Haiku", description: "Fast and cost-effective"),
                ModelPreset(id: "anthropic/claude-opus-4.5", displayName: "Claude Opus 4.5", description: "Highest quality")
            ]
        case .anthropic:
            return [
                ModelPreset(id: "claude-3-5-haiku-20241022", displayName: "Claude 3.5 Haiku", description: "Fast and cost-effective"),
                ModelPreset(id: "claude-3-5-sonnet-20241022", displayName: "Claude 3.5 Sonnet", description: "Balanced premium")
            ]
        case .openai:
            return [
                ModelPreset(id: "gpt-4o-mini", displayName: "GPT-4o mini", description: "Fast and affordable"),
                ModelPreset(id: "gpt-4o", displayName: "GPT-4o", description: "High quality")
            ]
        case .deepseek:
            return [
                ModelPreset(id: "deepseek-chat", displayName: "DeepSeek Chat", description: "Budget-friendly")
            ]
        case .gemini:
            return [
                ModelPreset(id: "gemini-2.0-flash-exp", displayName: "Gemini 2.0 Flash", description: "Fast, large context"),
                ModelPreset(id: "gemini-pro", displayName: "Gemini Pro", description: "General purpose")
            ]
        case .customOpenAI:
            return [
                ModelPreset(id: "default", displayName: "default", description: "Custom OpenAI v1 model")
            ]
        }
    }

    func presetDescription(for provider: LLMProvider, modelId: String) -> String {
        presetsForProvider(provider).first(where: { $0.id == modelId })?.description ?? ""
    }

    /// Sterling's one-line verdict on a model, or `nil` when there is nothing
    /// honest to say. Remote providers return `nil` on purpose: the app cannot
    /// know what an arbitrary gateway serves, and the person who chose it has
    /// already made that call — see `SterlingCapabilities.isRemote`.
    ///
    /// Kept here rather than baked into each `ModelPreset.description` so the
    /// capability table stays the only place that decides, and a model added to
    /// the preset list cannot quietly describe itself as capable.
    func capabilityNote(for model: String, provider: LLMProvider) -> String? {
        SterlingCapabilities.note(for: model, provider: provider)
    }

    private func modelForProvider(_ provider: LLMProvider) -> String {
        switch provider {
        case .mlxLocal: return mlxModel
        case .openrouter: return openrouterModel
        case .anthropic: return anthropicModel
        case .openai: return openaiModel
        case .deepseek: return deepseekModel
        case .gemini: return geminiModel
        case .ollama, .lmStudio, .customOpenAI:
            return provider.defaultModel
        }
    }

    private func apiKeyForProvider(_ provider: LLMProvider) -> String {
        switch provider {
        case .openrouter: return openrouterAPIKey
        case .anthropic: return anthropicAPIKey
        case .openai: return openaiAPIKey
        case .deepseek: return deepseekAPIKey
        case .gemini: return geminiAPIKey
        case .mlxLocal, .ollama, .lmStudio, .customOpenAI:
            return ""
        }
    }

    private func defaultEndpointURL(for provider: LLMProvider) -> String {
        switch provider {
        case .ollama:
            return "http://localhost:11434"
        case .lmStudio:
            return "http://localhost:1234"
        case .customOpenAI:
            return ""
        default:
            return ""
        }
    }

    private func applyEnv(for provider: LLMProvider, model: String, apiKey: String, into env: inout [String: String], allowOverride: Bool) {
        switch provider {
        case .mlxLocal:
            if allowOverride || env["MLX_MODEL"] == nil {
                env["MLX_MODEL"] = model
            }
        case .openrouter:
            if allowOverride || env["OPENROUTER_API_KEY"] == nil {
                env["OPENROUTER_API_KEY"] = apiKey
            }
            if allowOverride || env["OPENROUTER_MODEL"] == nil {
                env["OPENROUTER_MODEL"] = model
            }
        case .anthropic:
            if allowOverride || env["ANTHROPIC_API_KEY"] == nil {
                env["ANTHROPIC_API_KEY"] = apiKey
            }
            if allowOverride || env["ANTHROPIC_MODEL"] == nil {
                env["ANTHROPIC_MODEL"] = model
            }
        case .openai:
            if allowOverride || env["OPENAI_API_KEY"] == nil {
                env["OPENAI_API_KEY"] = apiKey
            }
            if allowOverride || env["OPENAI_MODEL"] == nil {
                env["OPENAI_MODEL"] = model
            }
        case .deepseek:
            if allowOverride || env["DEEPSEEK_API_KEY"] == nil {
                env["DEEPSEEK_API_KEY"] = apiKey
            }
            if allowOverride || env["DEEPSEEK_MODEL"] == nil {
                env["DEEPSEEK_MODEL"] = model
            }
        case .gemini:
            if allowOverride || env["GEMINI_API_KEY"] == nil {
                env["GEMINI_API_KEY"] = apiKey
            }
            if allowOverride || env["GEMINI_MODEL"] == nil {
                env["GEMINI_MODEL"] = model
            }
        case .ollama, .lmStudio, .customOpenAI:
            break
        }
    }

    private func applyPrimaryToProviderStorage() {
        switch primaryProvider {
        case .mlxLocal:
            mlxModel = primaryModel
        case .openrouter:
            openrouterModel = primaryModel
            if !primaryAPIKey.isEmpty {
                openrouterAPIKey = primaryAPIKey
            }
        case .anthropic:
            anthropicModel = primaryModel
            if !primaryAPIKey.isEmpty {
                anthropicAPIKey = primaryAPIKey
            }
        case .openai:
            openaiModel = primaryModel
            if !primaryAPIKey.isEmpty {
                openaiAPIKey = primaryAPIKey
            }
        case .deepseek:
            deepseekModel = primaryModel
            if !primaryAPIKey.isEmpty {
                deepseekAPIKey = primaryAPIKey
            }
        case .gemini:
            geminiModel = primaryModel
            if !primaryAPIKey.isEmpty {
                geminiAPIKey = primaryAPIKey
            }
        case .ollama, .lmStudio, .customOpenAI:
            break
        }
    }

    private func applyFallbackToProviderStorage() {
        guard let fallback = fallbackProvider else { return }
        switch fallback {
        case .mlxLocal:
            mlxModel = fallbackModel
        case .openrouter:
            openrouterModel = fallbackModel
            if !fallbackAPIKey.isEmpty {
                openrouterAPIKey = fallbackAPIKey
            }
        case .anthropic:
            anthropicModel = fallbackModel
            if !fallbackAPIKey.isEmpty {
                anthropicAPIKey = fallbackAPIKey
            }
        case .openai:
            openaiModel = fallbackModel
            if !fallbackAPIKey.isEmpty {
                openaiAPIKey = fallbackAPIKey
            }
        case .deepseek:
            deepseekModel = fallbackModel
            if !fallbackAPIKey.isEmpty {
                deepseekAPIKey = fallbackAPIKey
            }
        case .gemini:
            geminiModel = fallbackModel
            if !fallbackAPIKey.isEmpty {
                geminiAPIKey = fallbackAPIKey
            }
        case .ollama, .lmStudio, .customOpenAI:
            break
        }
    }

    private func saveAdvancedSettings(forModel model: String) {
        let userDefaults = UserDefaults.standard
        userDefaults.set(useCustomSystemPrompt, forKey: modelScopedKey(prefix: "use_custom_system_prompt", model: model))
        userDefaults.set(customSystemPrompt, forKey: modelScopedKey(prefix: "custom_prompt", model: model))
        userDefaults.set(clamp(advancedTemperature, min: 0.0, max: 1.0), forKey: modelScopedKey(prefix: "temperature", model: model))
        userDefaults.set(clamp(advancedMaxTokens, min: 100, max: 4000), forKey: modelScopedKey(prefix: "max_tokens", model: model))
        userDefaults.set(clamp(advancedTopP, min: 0.0, max: 1.0), forKey: modelScopedKey(prefix: "top_p", model: model))
    }

    private func defaultsForModel(_ model: String, provider: LLMProvider) -> LLMModelDefaults {
        if let config = defaultModelConfigs[model] {
            return config
        }

        let providerDefaults: (Double, Int) = {
            switch provider {
            case .mlxLocal:
                return (0.75, 1500)
            case .openrouter:
                return (0.7, 600)
            case .anthropic:
                return (0.7, 600)
            case .openai:
                return (0.7, 600)
            case .deepseek:
                return (0.7, 700)
            case .gemini:
                return (0.7, 800)
            case .ollama, .lmStudio, .customOpenAI:
                return (0.7, 600)
            }
        }()

        return LLMModelDefaults(
            temperature: providerDefaults.0,
            maxTokens: providerDefaults.1,
            topP: 0.9,
            systemPromptAddition: ""
        )
    }

    private func modelScopedKey(prefix: String, model: String) -> String {
        "\(prefix)_\(model)"
    }

    private func promptStorageKey(model: String, isExtraction: Bool) -> String {
        isExtraction ? "engineer::\(model)" : model
    }

    static var defaultEngineerPrompt: String {
        """
        **THE ENGINEER - Parameter Extraction Specialist**

        You are "The Engineer" - Majik's Music Studio's technical specialist for extracting music parameters.
        Your ONLY job: convert conversation into valid JSON with exact parameters.
        Output ONLY valid JSON with exact values from the conversation.
        Never add markdown, explanation, or extra text.
        """
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }

    private func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.max(min, Swift.min(max, value))
    }
}
