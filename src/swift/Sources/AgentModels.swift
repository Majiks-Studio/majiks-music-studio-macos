import Foundation
import SwiftUI

struct AgentToolDefinition: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let description: String

    static let builtIn: [AgentToolDefinition] = [
        AgentToolDefinition(
            id: "generate_music",
            title: "Generate Music",
            description: "Allow the agent to trigger music generation when auto-generation is enabled."
        ),
        AgentToolDefinition(
            id: "import_audio",
            title: "Import Audio",
            description: "Allow the agent to import existing reference audio."
        ),
        AgentToolDefinition(
            id: "export_track",
            title: "Export Track",
            description: "Allow the agent to export generated tracks."
        ),
        AgentToolDefinition(
            id: "list_available_models",
            title: "List Models",
            description: "Allow the agent to inspect available music-generation models."
        )
    ]

    static var allBuiltInIDs: [String] {
        builtIn.map(\.id)
    }
}

struct AgentPaletteColor: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let hex: String

    var color: Color {
        Color(hex: hex)
    }

    static let defaults: [AgentPaletteColor] = [
        AgentPaletteColor(id: "ocean", label: "Ocean", hex: "#2563EB"),
        AgentPaletteColor(id: "mint", label: "Mint", hex: "#059669"),
        AgentPaletteColor(id: "sunset", label: "Sunset", hex: "#EA580C"),
        AgentPaletteColor(id: "rose", label: "Rose", hex: "#E11D48"),
        AgentPaletteColor(id: "violet", label: "Violet", hex: "#7C3AED"),
        AgentPaletteColor(id: "gold", label: "Gold", hex: "#CA8A04"),
        AgentPaletteColor(id: "slate", label: "Slate", hex: "#475569"),
        AgentPaletteColor(id: "teal", label: "Teal", hex: "#0F766E")
    ]
}

struct AgentIconOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String

    static let defaults: [AgentIconOption] = [
        AgentIconOption(id: "music.mic", label: "Music Mic"),
        AgentIconOption(id: "music.note", label: "Music Note"),
        AgentIconOption(id: "text.book.closed", label: "Lyric Book"),
        AgentIconOption(id: "pianokeys", label: "Keys"),
        AgentIconOption(id: "slider.horizontal.3", label: "Mixer"),
        AgentIconOption(id: "gearshape.2", label: "Engineer"),
        AgentIconOption(id: "waveform.path.ecg", label: "Waveform"),
        AgentIconOption(id: "metronome", label: "Tempo"),
        AgentIconOption(id: "sparkles", label: "Creative"),
        AgentIconOption(id: "music.quarternote.3", label: "Producer")
    ]
}

struct ChatAgent: Identifiable, Codable, Equatable, Sendable {
    /// The app's default agent. Presents as "Sterling — The Producer" since the
    /// 2026-07 rebrand; the ID keeps its legacy "majik" name because persisted
    /// conversations and UserDefaults reference this UUID. The subtitle used to
    /// read "The Engineer", which collided with the separate technical agent of
    /// that name (`engineerAgentID`); the producer owns creative direction and
    /// arrangement, the engineer owns capture, levels, EQ and mixing.
    static let majikAgentID = UUID(uuidString: "7C701E35-39C2-4A03-84E7-E7A8D8F3B201")!
    static let lyricistAgentID = UUID(uuidString: "CFC3E36C-D1CB-467F-B77C-E697D61A0102")!
    static let engineerAgentID = UUID(uuidString: "5927DAA4-0808-4922-BC1D-A588FA8A4A03")!
    static let producerAgentID = UUID(uuidString: "D78066FC-1A3E-4FEA-AFC0-F8A5D16DA404")!

    /// Subtitles the default agent shipped with before the current one. A
    /// stored copy carrying any of these is untouched by the user, so it may be
    /// migrated forward; anything else is a user edit and is left alone.
    /// Ordered oldest first. The second entry is the one that collided with the
    /// technical "The Engineer" agent.
    static let legacyMajikSummaries: Set<String> = [
        "Your AI music production assistant — lyrics, arrangement, generation, and everything creative",
        "The Engineer — your AI music production partner: lyrics, arrangement, generation, and everything creative"
    ]

    let id: UUID
    var name: String
    var iconSystemName: String
    var summary: String
    var accentColorHex: String
    var systemPrompt: String
    var customInstructions: String
    var provider: LLMProvider?
    var modelID: String
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var enabledToolIDs: [String]
    var brigadeAgentID: String?
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        iconSystemName: String,
        summary: String,
        accentColorHex: String,
        systemPrompt: String = "",
        customInstructions: String = "",
        provider: LLMProvider? = nil,
        modelID: String = "",
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        enabledToolIDs: [String] = AgentToolDefinition.allBuiltInIDs,
        brigadeAgentID: String? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.summary = summary
        self.accentColorHex = accentColorHex
        self.systemPrompt = systemPrompt
        self.customInstructions = customInstructions
        self.provider = provider
        self.modelID = modelID
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.enabledToolIDs = enabledToolIDs
        self.brigadeAgentID = brigadeAgentID
        self.isBuiltIn = isBuiltIn
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case iconSystemName
        case summary
        case accentColorHex
        case systemPrompt
        case customInstructions
        case provider
        case modelID
        case temperature
        case topP
        case maxTokens
        case enabledToolIDs
        case brigadeAgentID
        case isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "New Agent"
        iconSystemName = try container.decodeIfPresent(String.self, forKey: .iconSystemName) ?? "sparkles"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        accentColorHex = try container.decodeIfPresent(String.self, forKey: .accentColorHex) ?? "#2563EB"
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        customInstructions = try container.decodeIfPresent(String.self, forKey: .customInstructions) ?? ""
        provider = try container.decodeIfPresent(LLMProvider.self, forKey: .provider)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        enabledToolIDs = try container.decodeIfPresent([String].self, forKey: .enabledToolIDs) ?? AgentToolDefinition.allBuiltInIDs
        brigadeAgentID = try container.decodeIfPresent(String.self, forKey: .brigadeAgentID)
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    var accentColor: Color {
        Color(hex: accentColorHex)
    }

    var usesAppDefaults: Bool {
        provider == nil
    }

    var hasCustomPrompt: Bool {
        !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var allowsToolUsage: Bool {
        !enabledToolIDs.isEmpty
    }

    var isMajik: Bool {
        id == Self.majikAgentID
    }

    var isEngineer: Bool {
        id == Self.engineerAgentID
    }

    func resolvedProvider(fallback: LLMProvider) -> LLMProvider {
        provider ?? fallback
    }

    @MainActor
    func resolvedModel(using settings: LLMProviderSettings) -> String {
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            return trimmedModel
        }
        if let provider {
            return provider.defaultModel
        }
        return settings.primaryModel
    }

    /// Whether this agent needs a model that can operate the app.
    ///
    /// Deliberately a property of the AGENT rather than a check for Sterling's
    /// id: the answer stays right when someone builds a second operator, and it
    /// stays right when Sterling's tools are switched off and it becomes a
    /// writer. An agent with no tools enabled asks nothing of the model that a
    /// chat model cannot do.
    ///
    /// This is the seam a model-policy-by-ROLE system would hang from. It is
    /// not that system, and this lane does not build it.
    var needsAnOperatorModel: Bool {
        !enabledToolIDs.isEmpty
    }

    /// The routing verdict for THIS agent: an agent with no tools is never
    /// refused, whatever the model is.
    func operatorRoute(_ inputs: SterlingRoutingInputs) -> SterlingOperatorRoute? {
        guard needsAnOperatorModel else { return nil }
        return SterlingRouter.route(inputs)
    }

    func resolvedTemperature(fallback: Double) -> Double {
        temperature ?? fallback
    }

    func resolvedTopP(fallback: Double) -> Double {
        topP ?? fallback
    }

    func resolvedMaxTokens(fallback: Int) -> Int {
        maxTokens ?? fallback
    }

    func copyForDuplicate() -> ChatAgent {
        ChatAgent(
            name: "\(name) Copy",
            iconSystemName: iconSystemName,
            summary: summary,
            accentColorHex: accentColorHex,
            systemPrompt: systemPrompt,
            customInstructions: customInstructions,
            provider: provider,
            modelID: modelID,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            enabledToolIDs: enabledToolIDs,
            brigadeAgentID: brigadeAgentID,
            isBuiltIn: false
        )
    }

    @MainActor
    func asRPCConfig(using settings: LLMProviderSettings) -> JSONValue {
        let resolvedProvider = resolvedProvider(fallback: settings.primaryProvider)
        let resolvedModel = resolvedModel(using: settings)
        var payload: [String: JSONValue] = [
            "id": .string(id.uuidString),
            "name": .string(name),
            "system_prompt": .string(systemPrompt),
            "custom_instructions": .string(customInstructions),
            "provider": .string(resolvedProvider.rawValue),
            "model": .string(resolvedModel),
            "uses_app_defaults": .bool(usesAppDefaults),
            "enabled_tool_ids": .array(enabledToolIDs.map(JSONValue.string))
        ]
        if let temperature {
            payload["temperature"] = .number(temperature)
        }
        if let topP {
            payload["top_p"] = .number(topP)
        }
        if let maxTokens {
            payload["max_tokens"] = .number(Double(maxTokens))
        }
        return .object(payload)
    }

    static var builtIns: [ChatAgent] {
        [
            ChatAgent(
                id: majikAgentID,
                name: "Sterling",
                iconSystemName: "gearshape.2",
                summary: "The Producer — your AI music production partner: lyrics, arrangement, generation, and everything creative",
                accentColorHex: "#2563EB",
                systemPrompt: "",  // Uses default system prompt from model_configs.py
                enabledToolIDs: AgentToolDefinition.allBuiltInIDs,
                isBuiltIn: true
            ),
            ChatAgent(
                id: engineerAgentID,
                name: "The Engineer",
                iconSystemName: "waveform.and.magnifyingglass",
                summary: "Technical audio analysis — BPM/key detection, mixing advice, parameter extraction",
                accentColorHex: "#F97316",
                systemPrompt: """
                You are The Engineer, the technical audio specialist inside Majik's Music Studio.

                Focus on:
                - BPM, key, groove, arrangement diagnostics
                - mixing, mastering, EQ, compression, stereo field, and gain staging
                - analyzing audio files and extracting musical parameters
                - practical engineering advice with concise technical reasoning

                Be precise, grounded, and low-drama. Prefer measurements, ranges, and actionable next steps.
                When analyzing a conversation for music parameters, extract BPM, key, duration, genre, mood, and style with confidence.
                """,
                customInstructions: "Keep answers structured and technical. When extracting parameters, be decisive about values.",
                temperature: 0.3,
                topP: 0.8,
                maxTokens: 1400,
                enabledToolIDs: AgentToolDefinition.allBuiltInIDs,
                isBuiltIn: true
            )
        ]
    }

    static func blankTemplate() -> ChatAgent {
        ChatAgent(
            name: "New Agent",
            iconSystemName: "sparkles",
            summary: "Custom assistant",
            accentColorHex: AgentPaletteColor.defaults[0].hex,
            systemPrompt: "",
            customInstructions: "",
            provider: nil,
            modelID: "",
            temperature: 0.7,
            topP: 0.9,
            maxTokens: 1200,
            enabledToolIDs: ["generate_music", "list_available_models"],
            isBuiltIn: false
        )
    }

    var defaultSuggestions: [String] {
        switch id {
        case Self.engineerAgentID:
            return [
                "How should I EQ muddy guitars and vocals?",
                "What BPM and key fit an energetic synthwave track?",
                "Help me tighten my low end and kick/bass balance"
            ]
        default:
            return [
                "Upbeat electronic dance music",
                "Chill lo-fi beats for studying",
                "Epic cinematic orchestral track"
            ]
        }
    }
}

struct AgentAvatarView: View {
    let agent: ChatAgent
    let size: CGFloat

    var body: some View {
        if agent.isMajik {
            // The default agent IS Sterling, The Producer (the app's AI
            // persona); the embedded mascot art works in every build without
            // bundling. The technical-analysis specialist ("The Engineer")
            // keeps its icon avatar so the two are distinguishable in the
            // picker.
            SterlingAvatarView(size: size)
        } else {
            Image(systemName: agent.iconSystemName)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(agent.accentColor)
                .frame(width: size, height: size)
                .background(agent.accentColor.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        }
    }
}

extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double

        switch sanitized.count {
        case 6:
            red = Double((value >> 16) & 0xFF) / 255.0
            green = Double((value >> 8) & 0xFF) / 255.0
            blue = Double(value & 0xFF) / 255.0
        default:
            red = 0.145
            green = 0.388
            blue = 0.922
        }

        self.init(red: red, green: green, blue: blue)
    }
}
