import SwiftUI

struct AgentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var llmSettings: LLMProviderSettings

    let originalAgentID: UUID?
    let onSave: (ChatAgent) -> Void

    @State private var draft: ChatAgent

    init(agent: ChatAgent? = nil, onSave: @escaping (ChatAgent) -> Void) {
        self.originalAgentID = agent?.id
        self.onSave = onSave
        _draft = State(initialValue: agent ?? ChatAgent.blankTemplate())
    }

    private var isUsingAppDefaultProvider: Bool {
        draft.provider == nil
    }

    private var isUsingAppDefaultParameters: Bool {
        draft.temperature == nil && draft.topP == nil && draft.maxTokens == nil
    }

    private var resolvedProvider: LLMProvider {
        draft.provider ?? llmSettings.primaryProvider
    }

    private var resolvedModel: String {
        let trimmed = draft.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return draft.provider?.defaultModel ?? llmSettings.primaryModel
    }

    private var modelDefaults: LLMModelDefaults {
        llmSettings.modelDefaults(for: resolvedModel, provider: resolvedProvider)
    }

    private var nameIsEmpty: Bool {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isEditingBuiltIn: Bool {
        if let originalAgentID {
            return ChatAgent.builtIns.contains(where: { $0.id == originalAgentID })
        }
        return false
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Agent preview header
            agentPreview
                .padding()
                .background(.ultraThinMaterial)

            Divider()

            ScrollView {
                SwiftUI.Form {
                    profileSection
                    promptingSection
                    modelSection
                    inferenceSection
                    toolsSection
                }
                .formStyle(.grouped)
            }

            Divider()

            // Toolbar
            HStack {
                if isEditingBuiltIn {
                    Label("Built-in agent", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if nameIsEmpty {
                    Label("Name is required", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave(cleanedDraft())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(nameIsEmpty)
            }
            .padding()
        }
        .frame(minWidth: 720, idealHeight: 700)
        .onChange(of: draft.provider) { _, newProvider in
            if let newProvider {
                if draft.modelID.isEmpty || !newProvider.models.contains(draft.modelID) {
                    draft.modelID = newProvider.defaultModel
                }
            } else {
                draft.modelID = ""
            }
        }
    }

    // MARK: - Preview Header

    private var agentPreview: some View {
        HStack(spacing: 14) {
            AgentAvatarView(agent: draft, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.name.isEmpty ? "New Agent" : draft.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(draft.summary.isEmpty ? "No description" : draft.summary)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Live model badge
            VStack(alignment: .trailing, spacing: 2) {
                Text(isUsingAppDefaultProvider ? "App Default" : (draft.provider?.displayName ?? ""))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(isUsingAppDefaultProvider ? llmSettings.primaryModel : resolvedModel)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var profileSection: some View {
        SwiftUI.Section {
            TextField("Agent name", text: $draft.name)
            TextField("Short description of what this agent does", text: $draft.summary)

            VStack(alignment: .leading, spacing: 10) {
                Text("Icon")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 10) {
                    ForEach(AgentIconOption.defaults) { option in
                        Button {
                            draft.iconSystemName = option.id
                        } label: {
                            Image(systemName: option.id)
                                .font(.title3)
                                .foregroundColor(draft.iconSystemName == option.id ? .white : draft.accentColor)
                                .frame(width: 42, height: 42)
                                .background(draft.iconSystemName == option.id ? draft.accentColor : draft.accentColor.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .help(option.label)
                    }
                }

                TextField("Custom SF Symbol", text: $draft.iconSystemName)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Accent Color")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 10) {
                    ForEach(AgentPaletteColor.defaults) { option in
                        Button {
                            draft.accentColorHex = option.hex
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 28, height: 28)
                                .padding(8)
                                .overlay {
                                    Circle()
                                        .stroke(draft.accentColorHex == option.hex ? Color.primary : Color.clear, lineWidth: 2)
                                        .padding(2)
                                }
                        }
                        .buttonStyle(.plain)
                        .help(option.label)
                    }
                }

                TextField("Hex Color", text: $draft.accentColorHex)
                    .font(.system(.body, design: .monospaced))
            }
        } header: {
            Label("Profile", systemImage: "person.crop.circle")
        }
    }

    @ViewBuilder
    private var promptingSection: some View {
        SwiftUI.Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("System Prompt")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Defines the agent's personality and expertise")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextEditor(text: $draft.systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Additional Instructions")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Appended to every conversation with this agent")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextEditor(text: $draft.customInstructions)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }
        } header: {
            Label("Prompting", systemImage: "text.quote")
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        SwiftUI.Section {
            Toggle("Use app default provider and model", isOn: useAppDefaultProviderBinding)

            if !isUsingAppDefaultProvider {
                Picker("Provider", selection: $draft.provider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(Optional(provider))
                    }
                }

                Picker("Model", selection: $draft.modelID) {
                    ForEach(resolvedProvider.models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            } else {
                LabeledContent("Current App Model", value: llmSettings.primaryModel)
            }

            capabilityNote
        } header: {
            Label("Model", systemImage: "cpu")
        }
    }

    /// Whether the model this agent will actually run on can drive the app.
    ///
    /// Asked of the AGENT (`needsAnOperatorModel`), not of Sterling's id, so an
    /// agent with its tools switched off is never nagged and a second operator
    /// is covered for free. Text only — the two routes it names are reached
    /// through controls that already exist elsewhere in Settings.
    @ViewBuilder
    private var capabilityNote: some View {
        if let route = draft.operatorRoute(SterlingRouter.inputs(for: draft, settings: llmSettings)) {
            switch route {
            case .remote, .local:
                Label("Operates the app on \(route.summary)", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .refused(refusal):
                VStack(alignment: .leading, spacing: 4) {
                    Label(refusal.headline, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(refusal.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(refusal.offers.enumerated()), id: \.offset) { _, offer in
                        Text("\(offer.title). \(offer.detail)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var inferenceSection: some View {
        SwiftUI.Section {
            Toggle("Use app default inference settings", isOn: useAppDefaultParametersBinding)

            if !isUsingAppDefaultParameters {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.2f", draft.temperature ?? modelDefaults.temperature))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: temperatureBinding, in: 0...1, step: 0.05)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Top P")
                        Spacer()
                        Text(String(format: "%.2f", draft.topP ?? modelDefaults.topP))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: topPBinding, in: 0...1, step: 0.05)
                }

                Stepper(value: maxTokensBinding, in: 100...4000, step: 100) {
                    HStack {
                        Text("Max Tokens")
                        Spacer()
                        Text("\(draft.maxTokens ?? modelDefaults.maxTokens)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Label("Inference", systemImage: "slider.horizontal.3")
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        SwiftUI.Section {
            ForEach(AgentToolDefinition.builtIn) { tool in
                Toggle(isOn: binding(for: tool.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.title)
                        Text(tool.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
    }

    // MARK: - Bindings

    private var useAppDefaultProviderBinding: Binding<Bool> {
        Binding(
            get: { isUsingAppDefaultProvider },
            set: { useDefaults in
                if useDefaults {
                    draft.provider = nil
                    draft.modelID = ""
                } else {
                    let provider = draft.provider ?? llmSettings.primaryProvider
                    draft.provider = provider
                    draft.modelID = draft.modelID.isEmpty ? provider.defaultModel : draft.modelID
                }
            }
        )
    }

    private var useAppDefaultParametersBinding: Binding<Bool> {
        Binding(
            get: { isUsingAppDefaultParameters },
            set: { useDefaults in
                if useDefaults {
                    draft.temperature = nil
                    draft.topP = nil
                    draft.maxTokens = nil
                } else {
                    draft.temperature = draft.temperature ?? modelDefaults.temperature
                    draft.topP = draft.topP ?? modelDefaults.topP
                    draft.maxTokens = draft.maxTokens ?? modelDefaults.maxTokens
                }
            }
        )
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { draft.temperature ?? modelDefaults.temperature },
            set: { draft.temperature = $0 }
        )
    }

    private var topPBinding: Binding<Double> {
        Binding(
            get: { draft.topP ?? modelDefaults.topP },
            set: { draft.topP = $0 }
        )
    }

    private var maxTokensBinding: Binding<Int> {
        Binding(
            get: { draft.maxTokens ?? modelDefaults.maxTokens },
            set: { draft.maxTokens = $0 }
        )
    }

    private func binding(for toolID: String) -> Binding<Bool> {
        Binding(
            get: { draft.enabledToolIDs.contains(toolID) },
            set: { isEnabled in
                if isEnabled {
                    if !draft.enabledToolIDs.contains(toolID) {
                        draft.enabledToolIDs.append(toolID)
                    }
                } else {
                    draft.enabledToolIDs.removeAll { $0 == toolID }
                }
            }
        )
    }

    private func cleanedDraft() -> ChatAgent {
        var cleaned = draft
        cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.summary = cleaned.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.systemPrompt = cleaned.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.customInstructions = cleaned.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.accentColorHex = cleaned.accentColorHex.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.modelID = isUsingAppDefaultProvider ? "" : resolvedModel
        cleaned.enabledToolIDs = cleaned.enabledToolIDs.sorted()
        return cleaned
    }
}

// MARK: - Agent Settings View

struct AgentSettingsView: View {
    @EnvironmentObject var agentStore: AgentStore
    @EnvironmentObject var conversationStore: ConversationStore
    @EnvironmentObject var llmSettings: LLMProviderSettings

    @State private var editorSeed = ChatAgent.blankTemplate()
    @State private var showingEditor = false
    @State private var agentToDelete: ChatAgent?
    @State private var brigadeNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agents")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Create and manage specialized chat assistants")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    editorSeed = ChatAgent.blankTemplate()
                    showingEditor = true
                } label: {
                    Label("Create Agent", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            List {
                ForEach(agentStore.agents) { agent in
                    AgentSettingsRow(
                        agent: agent,
                        isSelected: agentStore.selectedAgentID == agent.id,
                        onSelect: {
                            agentStore.selectAgent(agent)
                            conversationStore.activateAgent(agent.id)
                        },
                        onEdit: {
                            editorSeed = agent
                            showingEditor = true
                        },
                        onDuplicate: {
                            let duplicated = agentStore.duplicate(agent)
                            editorSeed = duplicated
                            showingEditor = true
                        },
                        onRegisterInBrigade: agent.isBuiltIn ? nil : {
                            Task {
                                do {
                                    let saved = try await BrigadeRegistrationService().register(agent: agent, settings: llmSettings)
                                    await MainActor.run {
                                        agentStore.upsert(saved)
                                        brigadeNotice = "\"\(saved.name)\" registered in Brigade as \(saved.brigadeAgentID ?? "unknown")."
                                    }
                                } catch {
                                    await MainActor.run {
                                        brigadeNotice = error.localizedDescription
                                    }
                                }
                            }
                        },
                        onReset: agent.isBuiltIn ? {
                            if let original = ChatAgent.builtIns.first(where: { $0.id == agent.id }) {
                                agentStore.upsert(original)
                            }
                        } : nil,
                        onDelete: agent.isBuiltIn ? nil : {
                            agentToDelete = agent
                        }
                    )
                }
            }
            .listStyle(.inset)
            if let brigadeNotice {
                Text(brigadeNotice)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding([.horizontal, .bottom])
            }
        }
        .sheet(isPresented: $showingEditor) {
            AgentEditorView(agent: editorSeed) { saved in
                agentStore.upsert(saved)
                agentStore.selectAgent(saved)
                conversationStore.activateAgent(saved.id)
            }
        }
        .alert("Delete Agent?", isPresented: Binding(
            get: { agentToDelete != nil },
            set: { if !$0 { agentToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let agent = agentToDelete {
                    agentStore.delete(agent)
                    conversationStore.activateAgent(agentStore.selectedAgentID)
                }
                agentToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                agentToDelete = nil
            }
        } message: {
            if let agent = agentToDelete {
                Text("Are you sure you want to delete \"\(agent.name)\"? This cannot be undone.")
            }
        }
    }
}

// MARK: - Agent Settings Row

private struct AgentSettingsRow: View {
    let agent: ChatAgent
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onRegisterInBrigade: (() -> Void)?
    let onReset: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatarView(agent: agent, size: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(agent.name)
                        .font(.headline)
                    if agent.isBuiltIn {
                        Text("Built-in")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(agent.accentColor.opacity(0.14))
                            .foregroundColor(agent.accentColor)
                            .cornerRadius(4)
                    }
                    if isSelected {
                        Text("Active")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.14))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                    if let brigadeAgentID = agent.brigadeAgentID, !brigadeAgentID.isEmpty {
                        Text("Brigade")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.14))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }

                Text(agent.summary.isEmpty ? "No description" : agent.summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if !isSelected {
                Button("Use") { onSelect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button("Edit") { onEdit() }
                .buttonStyle(.bordered)
                .controlSize(.small)

            Menu {
                Button { onDuplicate() } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                if let onRegisterInBrigade {
                    Button { onRegisterInBrigade() } label: {
                        Label(agent.brigadeAgentID == nil ? "Register in Brigade" : "Update in Brigade", systemImage: "cloud.badge.plus")
                    }
                }
                if let onReset {
                    Button { onReset() } label: {
                        Label("Reset to Default", systemImage: "arrow.counterclockwise")
                    }
                }
                if let onDelete {
                    Divider()
                    Button(role: .destructive) { onDelete() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 4)
    }
}
