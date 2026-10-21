import SwiftUI

// The chat agent is Sterling, The Producer (SterlingAvatarView renders the
// mascot art from the embedded asset). The old MajikLogo app-icon avatar was
// retired with the Sterling rebrand. The type name below is legacy: it renders
// Sterling, not the separate "The Engineer" technical agent.
struct EngineerLogo: View {
    let size: CGFloat

    private func loadEngineerImage() -> NSImage? {
        // Routed through ArtworkDecodeCache so the view-IO guard can see every
        // file decode and a body re-evaluation does not re-open the PNG.
        if let url = Bundle.main.url(forResource: "the-engineer-128", withExtension: "png"),
           let image = ArtworkDecodeCache.image(at: url) {
            NSLog("[EngineerLogo] Loaded via Bundle.main.url: %@", url.path)
            return image
        }

        if let resourcePath = Bundle.main.resourcePath {
            let directPath = "\(resourcePath)/the-engineer-128.png"
            if FileExistenceProbe.exists(atPath: directPath) {
                if let image = ArtworkDecodeCache.image(atPath: directPath) {
                    NSLog("[EngineerLogo] Loaded via direct path: %@", directPath)
                    return image
                } else {
                    NSLog("[EngineerLogo] File exists but NSImage failed: %@", directPath)
                }
            } else {
                NSLog("[EngineerLogo] File not found: %@", directPath)
            }
        }

        if let resourcePath = Bundle.main.resourcePath {
            let devPath = "\(resourcePath)/../../../../../assets/icons/the-engineer-128.png"
            if FileExistenceProbe.exists(atPath: devPath),
               let image = ArtworkDecodeCache.image(atPath: devPath) {
                NSLog("[EngineerLogo] Loaded via dev path: %@", devPath)
                return image
            }
        }

        NSLog("[EngineerLogo] All paths failed, using fallback. Bundle: %@", Bundle.main.resourcePath ?? "nil")
        return nil
    }

    var body: some View {
        let logo = loadEngineerImage()

        if let nsImage = logo {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            // Fallback to gear icon if engineer icon not found
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundColor(.orange)
                .frame(width: size, height: size)
                .background(Color.orange.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        }
    }
}

struct EnhancedChatView: View {
    @EnvironmentObject var backend: BackendViewModel
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var agentStore: AgentStore
    @EnvironmentObject var conversationStore: ConversationStore
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @EnvironmentObject var studioCoordinator: StudioCoordinator

    @State private var inputText: String = ""
    @State private var isGenerating = false
    @State private var showSidebar = true
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showingOverridePopover = false
    @State private var useConversationTemperatureOverride = false
    @State private var conversationTemperatureOverride = 0.7
    @State private var useConversationPromptOverride = false
    @State private var conversationPromptOverride = ""

    /// False inside the floating "Sterling" window, where a pop-out button
    /// would only re-focus the window it already lives in.
    private let showsPopoutButton: Bool

    init(showsPopoutButton: Bool = true) {
        self.showsPopoutButton = showsPopoutButton
    }

    private var currentConversationAgent: ChatAgent {
        if let agentID = conversationStore.currentConversation?.agentID,
           let agent = agentStore.agent(for: agentID) {
            return agent
        }
        return agentStore.selectedAgent
    }

    var body: some View {
        HSplitView {
            if showSidebar {
                ConversationSidebarView()
                    .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)
            }

            VStack(spacing: 0) {
                // Header with toggle button
                HStack {
                    Button(action: { showSidebar.toggle() }) {
                        Image(systemName: showSidebar ? "sidebar.left" : "sidebar.left.badge.plus")
                    }
                    .help(showSidebar ? "Hide Conversations" : "Show Conversations")
                    .buttonStyle(.plain)
                    .padding(.leading, 8)

                    ChatHeaderView(showsPopoutButton: showsPopoutButton)
                }

                Divider()

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let conversation = conversationStore.currentConversation {
                                if conversation.messages.isEmpty {
                                    EmptyStateView(agent: currentConversationAgent) { suggestion in
                                        inputText = suggestion
                                        sendMessage()
                                    }
                                } else {
                                    ForEach(conversation.messages) { message in
                                        let speakerAgent = agentStore.agent(for: message.speakerAgentID ?? conversation.agentID) ?? currentConversationAgent
                                        MessageRowView(
                                            message: message,
                                            agent: speakerAgent,
                                            onEdit: { newContent in
                                                conversationStore.updateMessage(id: message.id, content: newContent)
                                            },
                                            onDelete: {
                                                conversationStore.deleteMessage(id: message.id)
                                            }
                                        )
                                        .id(message.id)
                                    }
                                }
                            }

                            // Streaming partial reply or typing indicator
                            if backend.isThinking {
                                if backend.partialReply.isEmpty {
                                    TypingIndicatorView(agent: currentConversationAgent)
                                        .id("streaming-bottom")
                                } else {
                                    StreamingMessageView(
                                        text: backend.partialReply,
                                        agent: currentConversationAgent
                                    )
                                    .id("streaming-bottom")
                                }
                            }

                            // Invisible scroll anchor at the very bottom
                            Color.clear
                                .frame(height: 1)
                                .id("chat-bottom-anchor")
                        }
                        .padding()
                        .textSelection(.enabled)
                    }
                    .onAppear {
                        scrollProxy = proxy
                        // Scroll to bottom on initial load to show last messages
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            scrollToBottom()
                        }
                    }
                    .onChange(of: conversationStore.currentConversation?.messages.count) { _, _ in
                        scrollToBottom()
                    }
                    .onChange(of: backend.isThinking) { _, _ in
                        scrollToBottom()
                    }
                    .onChange(of: backend.partialReply) { _, _ in
                        scrollToBottom()
                    }
                }

                Divider()

                conversationOverrideBar

                Divider()

                // Input area
                ChatInputView(
                    inputText: $inputText,
                    isGenerating: $isGenerating,
                    onSend: sendMessage,
                    onGenerate: extractAndGenerate,
                    canGenerate: !(conversationStore.currentConversation?.messages.isEmpty ?? true)
                )
            }
        }
        .onAppear {
            conversationStore.activateAgent(agentStore.selectedAgentID)
            resetConversationOverrides()
        }
        .onChange(of: conversationStore.currentConversation?.id) { _, _ in
            resetConversationOverrides()
        }
        .onChange(of: agentStore.selectedAgentID) { _, newAgentID in
            conversationStore.activateAgent(newAgentID)
            resetConversationOverrides()
        }
    }

    private func scrollToBottom() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.15)) {
                scrollProxy?.scrollTo("chat-bottom-anchor", anchor: .bottom)
            }
        }
    }

    private func sendMessage() {
        let message = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        inputText = ""

        // Add user message
        let userMessage = ChatMessage(role: .user, content: message)
        conversationStore.addMessage(userMessage)

        // Capture conversation ID before the async gap so the reply
        // always lands in the conversation the user was viewing when
        // they pressed Send — even if they switch conversations while
        // the backend is thinking.
        let targetConversationId = conversationStore.currentConversation?.id
        let truncatedHistory = Array((conversationStore.currentConversation?.apiMessages ?? []).suffix(20))
        let replyAgent = currentConversationAgent

        Task {
            await backend.sendChatWithHistory(
                message,
                history: truncatedHistory,
                agentConfig: replyAgent.asRPCConfig(using: llmSettings),
                allowAutoGeneration: llmSettings.allowAutoGeneration && replyAgent.allowsToolUsage,
                advancedOverrides: effectiveChatOverrides(for: replyAgent)
            )

            // Add the agent response to the originating conversation
            if !backend.lastReply.isEmpty {
                let majikMessage = ChatMessage(
                    role: .assistant,
                    content: backend.lastReply,
                    speakerAgentID: replyAgent.id
                )
                if let targetId = targetConversationId,
                   targetId != conversationStore.currentConversation?.id,
                   var target = conversationStore.conversations.first(where: { $0.id == targetId }) {
                    // User switched away — write reply to the original conversation
                    target.addMessage(majikMessage)
                    conversationStore.updateConversation(target)
                } else {
                    conversationStore.addMessage(majikMessage)
                }
            }
        }
    }

    private func extractAndGenerate() {
        // Auto-send any unsent draft so the Engineer sees the full conversation
        let draft = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty {
            inputText = ""
            let userMessage = ChatMessage(role: .user, content: draft)
            conversationStore.addMessage(userMessage)
        }

        guard let conversation = conversationStore.currentConversation,
              !conversation.messages.isEmpty else { return }
        isGenerating = true

        Task {
            do {
                // Send full conversation to extraction — the chat model has 128K context
                // and needs the complete history to understand refinements
                let allMessages = conversation.apiMessages
                let recentMessages = allMessages
                AppLog.debug("Extracting parameters from \(recentMessages.count) recent messages (out of \(allMessages.count) total)")

                // Add status message
                let statusMessage = ChatMessage(
                    role: .assistant,
                    content: "Analyzing our conversation to extract music parameters...",
                    speakerAgentID: ChatAgent.engineerAgentID
                )
                conversationStore.addMessage(statusMessage)

                let params = try await backend.extractMusicParameters(from: recentMessages)
                AppLog.debug("Extracted parameters: \(params)")

                // Remove status message
                conversationStore.deleteMessage(id: statusMessage.id)

                // Add success message
                let successMessage = ChatMessage(
                    role: .assistant,
                    content: "Got it! I've loaded those parameters into Studio. Head over there to review and generate!",
                    speakerAgentID: ChatAgent.engineerAgentID
                )
                conversationStore.addMessage(successMessage)

                // Switch to the Create tab with the extracted parameters.
                // This used to pass `source: .engineerExtraction`, which was
                // stored and never read — see `openStudioWithParameters`.
                studioCoordinator.openStudioWithParameters(params)
            } catch {
                AppLog.error("Parameter extraction failed: \(error)")

                var errorText = "I couldn't extract parameters from our conversation."
                if error.localizedDescription.contains("timeout") || error.localizedDescription.contains("timed out") {
                    errorText += "\n\nThis might mean the backend needs to be restarted with your API key. Go to Settings → Restart Backend, then try again."
                } else {
                    errorText += "\n\nError: \(error.localizedDescription)"
                }

                let errorMessage = ChatMessage(
                    role: .assistant,
                    content: errorText,
                    speakerAgentID: ChatAgent.engineerAgentID
                )
                conversationStore.addMessage(errorMessage)
            }
            isGenerating = false
        }
    }

    private var conversationOverridesActive: Bool {
        let hasPrompt = useConversationPromptOverride && !conversationPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasPrompt || useConversationTemperatureOverride
    }

    /// Clean up a model ID into a user-friendly short name for the switcher
    private func friendlyModelName(_ modelId: String) -> String {
        var name = modelId
        for prefix in ["mlx-community/", "lmstudio-community/", "anthropic/", "google/", "meta-llama/"] {
            if name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
        }
        for suffix in ["-4bit", "-8bit", "-Instruct", "-MLX", "-MXFP4-Q8", "-instruct"] {
            name = name.replacingOccurrences(of: suffix, with: "")
        }
        return name
    }

    /// Available models for the current provider
    private var availableModelsForProvider: [String] {
        llmSettings.primaryProvider.models
    }

    private var conversationOverrideBar: some View {
        let provider = currentConversationAgent.resolvedProvider(fallback: llmSettings.primaryProvider)
        let model = currentConversationAgent.resolvedModel(using: llmSettings)
        let defaults = llmSettings.modelDefaults(for: model, provider: provider)

        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                AgentAvatarView(agent: currentConversationAgent, size: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentConversationAgent.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(friendlyModelName(model))
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }

                if currentConversationAgent.provider != nil {
                    statusBadge("Pinned", color: currentConversationAgent.accentColor)
                } else {
                    statusBadge("App Default", color: .secondary)
                }

                if !currentConversationAgent.isMajik {
                    statusBadge("Agent", color: currentConversationAgent.accentColor)
                }

                if llmSettings.chatOverrides(forModel: model, provider: provider).customSystemPrompt != nil && !currentConversationAgent.hasCustomPrompt {
                    statusBadge("Custom", color: .orange)
                }

                if conversationOverridesActive {
                    statusBadge("Override", color: .blue)
                }
            }

            Text("Extraction: \(friendlyModelName(llmSettings.resolvedExtractionModel))")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text("Temp \(String(format: "%.2f", currentConversationAgent.temperature ?? defaults.temperature))")
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()

            Button {
                showingOverridePopover.toggle()
            } label: {
                Label("Override Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $showingOverridePopover, arrowEdge: .bottom) {
                conversationOverridePopover
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.08))
    }

    private var conversationOverridePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversation Overrides")
                .font(.headline)

            Text("Applies only to this chat thread. Resets when you switch conversations.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Override Temperature", isOn: $useConversationTemperatureOverride)
                .toggleStyle(.switch)

            if useConversationTemperatureOverride {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Temperature")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f", conversationTemperatureOverride))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $conversationTemperatureOverride, in: 0...1, step: 0.05)
                    Text("Model default: \(String(format: "%.2f", resolvedModelDefaults(for: currentConversationAgent).temperature))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Toggle("Use custom prompt for this chat", isOn: $useConversationPromptOverride)
                .toggleStyle(.switch)

            if useConversationPromptOverride {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $conversationPromptOverride)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                    if conversationPromptOverride.isEmpty {
                        Text("Temporary system prompt override for this conversation")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                            .allowsHitTesting(false)
                    }
                }
                .padding(6)
                .background(Color(.textBackgroundColor))
                .cornerRadius(8)
            }

            HStack {
                Spacer()
                Button("Reset to Model Defaults") {
                    resetConversationOverrides()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    @ViewBuilder
    private func statusBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private func effectiveChatOverrides() -> LLMAdvancedChatOverrides {
        effectiveChatOverrides(for: currentConversationAgent)
    }

    private func effectiveChatOverrides(for agent: ChatAgent) -> LLMAdvancedChatOverrides {
        let provider = agent.resolvedProvider(fallback: llmSettings.primaryProvider)
        let model = agent.resolvedModel(using: llmSettings)
        let persistent = llmSettings.chatOverrides(forModel: model, provider: provider)
        let promptOverride = useConversationPromptOverride ? conversationPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return LLMAdvancedChatOverrides(
            customSystemPrompt: promptOverride.isEmpty ? (agent.hasCustomPrompt ? nil : persistent.customSystemPrompt) : promptOverride,
            temperatureOverride: useConversationTemperatureOverride ? conversationTemperatureOverride : (agent.temperature ?? persistent.temperatureOverride),
            maxTokensOverride: agent.maxTokens ?? persistent.maxTokensOverride,
            topPOverride: agent.topP ?? persistent.topPOverride
        )
    }

    private func resetConversationOverrides() {
        let defaults = resolvedModelDefaults(for: currentConversationAgent)
        useConversationTemperatureOverride = false
        conversationTemperatureOverride = currentConversationAgent.temperature ?? defaults.temperature
        useConversationPromptOverride = false
        conversationPromptOverride = ""
    }

    private func resolvedModelDefaults(for agent: ChatAgent) -> LLMModelDefaults {
        let provider = agent.resolvedProvider(fallback: llmSettings.primaryProvider)
        let model = agent.resolvedModel(using: llmSettings)
        return llmSettings.modelDefaults(for: model, provider: provider)
    }

}

struct ChatHeaderView: View {
    @EnvironmentObject var agentStore: AgentStore
    @EnvironmentObject var conversationStore: ConversationStore
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @Environment(\.openWindow) private var openWindow

    @State private var editorSeed = ChatAgent.blankTemplate()
    @State private var showingEditor = false

    private let showsPopoutButton: Bool

    init(showsPopoutButton: Bool = true) {
        self.showsPopoutButton = showsPopoutButton
    }

    private var selectedAgent: ChatAgent {
        agentStore.selectedAgent
    }

    private var selectedModelName: String {
        friendlyModelName(selectedAgent.resolvedModel(using: llmSettings))
    }

    var body: some View {
        HStack {
            Menu {
                SwiftUI.Section("Agents") {
                    ForEach(agentStore.agents) { agent in
                        Button {
                            agentStore.selectAgent(agent)
                            conversationStore.activateAgent(agent.id)
                        } label: {
                            HStack {
                                Text(agent.name)
                                if agentStore.selectedAgentID == agent.id {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Divider()

                Button("Create Agent…") {
                    editorSeed = ChatAgent.blankTemplate()
                    showingEditor = true
                }

                Button("Edit Current Agent…") {
                    editorSeed = selectedAgent
                    showingEditor = true
                }
            } label: {
                HStack(spacing: 10) {
                    AgentAvatarView(agent: selectedAgent, size: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedAgent.name)
                            .font(.headline)
                        Text(selectedModelName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .menuStyle(.borderlessButton)

            Spacer()

            if showsPopoutButton {
                Button {
                    openWindow(id: SterlingChatWindowView.windowID)
                } label: {
                    Label("Pop Out", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .help("Chat with Sterling in a floating window (⇧⌘S)")
            }

            Button(action: {
                conversationStore.createNewConversation(agentID: selectedAgent.id)
            }) {
                Label("New Chat", systemImage: "plus.message")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .sheet(isPresented: $showingEditor) {
            AgentEditorView(agent: editorSeed) { saved in
                agentStore.upsert(saved)
                agentStore.selectAgent(saved)
                conversationStore.activateAgent(saved.id)
            }
        }
    }

    /// Clean up a model ID into a user-friendly display name
    private func friendlyModelName(_ modelId: String) -> String {
        var name = modelId
        // Strip common org prefixes
        for prefix in ["mlx-community/", "lmstudio-community/", "anthropic/", "google/", "meta-llama/"] {
            if name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
        }
        // Strip common suffixes
        for suffix in ["-4bit", "-8bit", "-Instruct", "-MLX", "-MXFP4-Q8", "-instruct"] {
            name = name.replacingOccurrences(of: suffix, with: "")
        }
        // Replace hyphens with spaces for readability
        name = name.replacingOccurrences(of: "-", with: " ")
        return name
    }
}

struct EmptyStateView: View {
    let agent: ChatAgent
    let onSuggestionTap: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            AgentAvatarView(agent: agent, size: 100)

            Text("Hi! I'm \(agent.name).")
                .font(.title)
                .fontWeight(.semibold)

            Text(agent.summary.isEmpty ? "What kind of music should we create today?" : agent.summary)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(agent.defaultSuggestions, id: \.self) { suggestion in
                    SuggestionChip(text: suggestion, color: agent.accentColor, onTap: onSuggestionTap)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct SuggestionChip: View {
    let text: String
    let color: Color
    let onTap: (String) -> Void

    var body: some View {
        Button(action: { onTap(text) }) {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(color.opacity(0.12))
                .foregroundColor(color)
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isFromAssistant {
                // Sterling avatar
                SterlingAvatarView(size: 36)
            } else {
                Spacer()
            }

            VStack(alignment: message.isFromAssistant ? .leading : .trailing, spacing: 4) {
                // Message bubble
                Text(message.content)
                    .padding(12)
                    .background(message.isFromAssistant ? Color.gray.opacity(0.1) : Color.accentColor.opacity(0.8))
                    .foregroundColor(message.isFromAssistant ? .primary : .white)
                    .cornerRadius(16)
                    .textSelection(.enabled)

                // Timestamp
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: 500, alignment: message.isFromAssistant ? .leading : .trailing)

            if message.isFromUser {
                // User avatar
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 36, height: 36)
            } else {
                Spacer()
            }
        }
    }
}

struct TypingIndicatorView: View {
    let agent: ChatAgent
    @State private var dotCount = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentAvatarView(agent: agent, size: 36)

            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(agent.accentColor)
                        .frame(width: 8, height: 8)
                        .opacity(dotCount == index ? 1.0 : 0.3)
                }
            }
            .padding(12)
            .background(agent.accentColor.opacity(0.12))
            .cornerRadius(16)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                    dotCount = (dotCount + 1) % 3
                }
            }

            Spacer()
        }
    }
}

struct StreamingMessageView: View {
    let text: String
    let agent: ChatAgent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 4) {
                AgentAvatarView(agent: agent, size: 26)
                Text(agent.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(agent.accentColor)
                    .lineLimit(2)
            }
            .frame(width: 72, alignment: .trailing)

            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(agent.accentColor.opacity(0.08))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(agent.accentColor.opacity(0.15), lineWidth: 1)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ChatInputView: View {
    @Binding var inputText: String
    @Binding var isGenerating: Bool
    let onSend: () -> Void
    let onGenerate: () -> Void
    let canGenerate: Bool

    @FocusState private var isInputFocused: Bool
    @State private var keyboardMonitor: Any?

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                // Text input - use ZStack to add placeholder to TextEditor
                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("Describe the music you want...")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }

                    TextEditor(text: $inputText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 40, maxHeight: 120)
                        .focused($isInputFocused)
                        .onAppear {
                            // Auto-focus on appear
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                isInputFocused = true
                            }
                            // Monitor local keyboard events for Return key
                            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                                // Check if input is focused and Return key pressed without Shift
                                if isInputFocused && event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
                                    if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        onSend()
                                        return nil  // consume the event
                                    }
                                }
                                return event  // pass through
                            }
                        }
                        .onDisappear {
                            if let monitor = keyboardMonitor {
                                NSEvent.removeMonitor(monitor)
                                keyboardMonitor = nil
                            }
                        }
                }
                .background(Color.gray.opacity(0.1))
                .cornerRadius(20)

                // Send button
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(inputText.isEmpty ? .gray : .accentColor)
                }
                .disabled(inputText.isEmpty)
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }

            // Quick actions
            HStack(spacing: 12) {
                Button(action: onGenerate) {
                    HStack(spacing: 8) {
                        EngineerLogo(size: 18)
                        Text(isGenerating ? "Sending..." : "Send to The Engineer")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || !canGenerate)

                Spacer()

                Text("⏎ to send • ⇧⏎ for new line")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}
