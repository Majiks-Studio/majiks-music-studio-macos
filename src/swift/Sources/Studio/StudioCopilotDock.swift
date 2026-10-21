import SwiftUI
import AppKit

// MARK: - Sterling dock (the copilot console)
//
// The right-rail agent interface (01-DESIGN 3.9), toggled with Cmd+Opt+C.
// Chat with Sterling, the Studio's engineer, who drives the whole session
// through the same command bus everything else uses. Every action renders as a
// tier-tinted chip inline in the transcript and in a session action log; click a
// chip to reveal its region on the timeline, and undo the newest one.
//
// Mounted in StudioRootView with one reference; owns its own open state and the
// Cmd+Opt+C shortcut (frontmost-guarded via the coordinator), so the mount stays
// a single line the coordinator can place beside L8's work.

struct StudioCopilotDock: View {
    @ObservedObject var studio: StudioViewModel
    @StateObject private var copilot: StudioCopilotModel
    @EnvironmentObject private var coordinator: StudioCoordinator
    @EnvironmentObject private var agentStore: AgentStore

    @AppStorage("studio.copilotOpen") private var open = true
    @AppStorage("sterling.endpoint") private var endpoint = ""
    @AppStorage("sterling.model") private var model = ""
    /// Which agent drives this Studio session (independent of the Chat tab's
    /// AgentStore.selectedAgentID). Defaults to built-in Sterling.
    @AppStorage("sterling.activeAgentID") private var activeAgentIDRaw = ChatAgent.majikAgentID.uuidString

    /// Gateway model list for the footer LLM picker (FFI-free; GET {endpoint}/models).
    @StateObject private var modelCatalog = SterlingModelCatalog()
    @StateObject private var brigadeCatalog = BrigadeAgentCatalog()
    @State private var lastAppliedSelection = ""

    @State private var showActions = false
    @State private var showSettings = false

    // `nonisolated` so the pure sizing layer (StudioPaneSizing, which has no
    // SwiftUI in it) can take its default from THIS number rather than keeping
    // a second copy that drifts. A `let` of a Sendable type is safe to read off
    // the main actor; the View around it stays isolated.
    nonisolated static let width: CGFloat = 320

    /// The dock's width when open. Owned by the shell (StudioRootView), because
    /// that is where the divider the user drags lives; `Self.width` stays the
    /// default so every other call site is unchanged.
    var panelWidth: CGFloat = StudioCopilotDock.width

    init(studio: StudioViewModel, panelWidth: CGFloat = StudioCopilotDock.width) {
        self.studio = studio
        self.panelWidth = panelWidth
        let backend = StudioCopilotBackendFactory.make(for: studio.engine)
        _copilot = StateObject(wrappedValue: StudioCopilotModel(backend: backend, viewModel: studio))
    }

    private var activeBrigadeAgent: BrigadeAgent? {
        guard activeAgentIDRaw.hasPrefix("brigade:") else { return nil }
        let id = String(activeAgentIDRaw.dropFirst("brigade:".count))
        return brigadeCatalog.agents.first(where: { $0.id == id }) ?? BrigadeAgent(id: id, name: id, description: nil)
    }

    private var activeAgent: ChatAgent {
        if let id = UUID(uuidString: activeAgentIDRaw), let agent = agentStore.agent(for: id) {
            return agent
        }
        return ChatAgent.builtIns.first ?? ChatAgent.blankTemplate()
    }

    private var activeRoute: StudioCopilotRoute {
        if let brigade = activeBrigadeAgent {
            return .brigade(agentID: brigade.id, displayName: brigade.name)
        }
        return .local
    }

    private var configured: Bool {
        if activeBrigadeAgent != nil {
            return BrigadeConfig.isConfigured
        }
        return copilot.available
            && !endpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var activeRole: String {
        if activeBrigadeAgent != nil { return "Brigade agent" }
        if activeAgent.id == ChatAgent.majikAgentID { return SterlingPersona.role }
        return activeAgent.isBuiltIn ? "Built-in agent" : "Custom agent"
    }

    private func applyAgentSelection() {
        guard lastAppliedSelection != activeAgentIDRaw else { return }
        lastAppliedSelection = activeAgentIDRaw
        copilot.route = activeRoute
        if activeBrigadeAgent != nil {
            copilot.systemPromptOverride = nil
        } else {
            copilot.systemPromptOverride = SterlingAgentBridge.systemPromptOverride(for: activeAgent)
            let agentModel = activeAgent.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !agentModel.isEmpty {
                model = agentModel
            }
        }
    }

    private var greetingText: String {
        if let brigade = activeBrigadeAgent {
            return brigade.description ?? "This Brigade agent runs server-side. Chat here stays in Brigade unless that agent exposes its own tools there."
        }
        if activeAgent.id == ChatAgent.majikAgentID { return SterlingPersona.greeting }
        return activeAgent.summary.isEmpty ? SterlingPersona.greeting : activeAgent.summary
    }

    private var examplePrompts: [String] {
        if activeBrigadeAgent != nil {
            return [
                "Summarize what you can help with in Brigade",
                "What tools do you have on the server side?",
                "What context do you need from me?"
            ]
        }
        if activeAgent.id == ChatAgent.majikAgentID { return SterlingPersona.examples }
        return activeAgent.defaultSuggestions
    }

    var body: some View {
        Group {
            if open {
                panel.frame(width: panelWidth)
            } else {
                reopenStrip
            }
        }
        .background(shortcutButton)
        .task { await copilot.runMidiTriggerDrain() }
        .task(id: endpoint) {
            await modelCatalog.refreshIfNeeded(endpoint: endpoint, apiKey: SterlingKeychain.key())
        }
        .task(id: BrigadeConfig.isConfigured) {
            if BrigadeConfig.isConfigured {
                await brigadeCatalog.refresh()
            }
        }
        .onAppear { applyAgentSelection() }
        .onChange(of: activeAgentIDRaw) { applyAgentSelection() }
        .sheet(isPresented: $showSettings) { SterlingSettingsView() }
    }

    // MARK: panel

    private var panel: some View {
        VStack(spacing: 8) {
            header
            if !configured { setupHint }
            if showActions {
                actionLogList
            } else {
                transcript
            }
            if let diagnostic = copilot.statusDiagnostic {
                SterlingDockDiagnostic(diagnostic: diagnostic)
            } else if let status = copilot.statusText {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTokens.warn)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if activeBrigadeAgent != nil {
                Text("Brigade mode: this is remote chat, not the local Studio command bus. Timeline edits and undo chips appear only if the Brigade agent exposes its own tools server-side.")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTokens.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            dockFooterControls
            inputRow
        }
        .padding(10)
        .background(StudioTokens.panel)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(StudioTokens.stroke), alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if activeBrigadeAgent != nil {
                Image(systemName: "cloud")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudioTokens.cyan)
                    .frame(width: 24, height: 24)
                    .background(StudioTokens.panelHi)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                AgentAvatarView(agent: activeAgent, size: 24)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text((activeBrigadeAgent?.name ?? activeAgent.name).uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(StudioTokens.text)
                    .lineLimit(1)
                Text(activeRole)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(StudioTokens.dim)
            }
            Circle()
                .fill(copilot.running ? StudioTokens.good : (configured ? StudioTokens.dim : StudioTokens.warn))
                .frame(width: 5, height: 5)

            Spacer()

            headerButton(
                label: "ACTIONS\(copilot.actionLog.isEmpty ? "" : " \(copilot.actionLog.count)")",
                active: showActions,
                help: "Session action log: every command Sterling ran"
            ) { showActions.toggle() }

            iconButton("gearshape", help: "Sterling settings") { showSettings = true }
            iconButton("trash", help: "Clear chat (the action log stays)", disabled: copilot.running) {
                copilot.clear()
            }
            iconButton("xmark", help: "Close Sterling (Cmd+Opt+C)") {
                withAnimation(.easeInOut(duration: 0.15)) { open = false }
            }
        }
    }

    private var setupHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !copilot.available {
                Label("Preview build", systemImage: "info.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTokens.dim)
                Text("Sterling runs in the packaged app on the real engine. This build shows the console only.")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTokens.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(activeBrigadeAgent != nil ? "No Brigade key" : "No endpoint set", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTokens.warn)
                Text(activeBrigadeAgent != nil
                     ? "This selection routes to Unicorn Brigade. Add a Brigade key in Sterling settings to list and chat with Brigade agents."
                     : "Point Sterling at any OpenAI-compatible endpoint: your Unicorn Commander gateway (direct, not through Cloudflare), llama.cpp, Ollama, LM Studio, or a cloud key.")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTokens.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open settings") { showSettings = true }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTokens.cyan)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioTokens.panelHi))
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if copilot.entries.isEmpty { emptyState }
                    ForEach(copilot.entries) { entry in
                        switch entry {
                        case .message(let message):
                            SterlingMessageBubble(message: message)
                        case .tool(let row):
                            SterlingToolRow(
                                row: row,
                                showTime: false,
                                undoable: row.id == copilot.undoableChipID,
                                undone: copilot.undoneChipIDs.contains(row.id),
                                onReveal: { copilot.reveal(row) },
                                onUndo: { copilot.undo(row) }
                            )
                        }
                    }
                    Color.clear.frame(height: 1).id("sterling-bottom")
                }
                .padding(.vertical, 2)
            }
            .onChange(of: copilot.entries.count) {
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("sterling-bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(greetingText)
                .font(.system(size: 10.5))
                .foregroundStyle(StudioTokens.dim)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(examplePrompts, id: \.self) { example in
                Button { copilot.draft = example } label: {
                    Text("\u{201C}\(example)\u{201D}")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTokens.cyan)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    // MARK: action log

    private var actionLogList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if copilot.actionLog.isEmpty {
                    Text("No actions yet this session.")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTokens.dim)
                        .padding(.top, 6)
                }
                ForEach(copilot.actionLog) { row in
                    SterlingToolRow(
                        row: row,
                        showTime: true,
                        undoable: row.id == copilot.undoableChipID,
                        undone: copilot.undoneChipIDs.contains(row.id),
                        onReveal: { copilot.reveal(row) },
                        onUndo: { copilot.undo(row) }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: footer controls (on-the-fly agent + LLM pickers)

    private var dockFooterControls: some View {
        HStack(spacing: 6) {
            SterlingDockAgentPicker(
                localAgents: agentStore.agents,
                brigadeAgents: brigadeCatalog.agents,
                activeSelection: activeAgentIDRaw,
                onSelectLocal: { activeAgentIDRaw = $0.id.uuidString },
                onSelectBrigade: { activeAgentIDRaw = "brigade:\($0.id)" }
            )
            if activeBrigadeAgent == nil {
                SterlingDockModelPicker(
                    catalog: modelCatalog,
                    model: $model,
                    endpoint: endpoint
                )
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: input

    private var inputRow: some View {
        HStack(spacing: 6) {
            TextField("Tell Sterling what to do", text: $copilot.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(StudioTokens.panelHi))
                .onSubmit { copilot.send() }
                .disabled(copilot.running || !configured)

            if copilot.running {
                Button { copilot.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(StudioTokens.warn.opacity(0.25)))
                        .foregroundStyle(StudioTokens.warn)
                }
                .buttonStyle(.plain)
                .help("Stop this turn")
            } else {
                Button { copilot.send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(canSend ? StudioTokens.purple : StudioTokens.panelHi))
                        .foregroundStyle(canSend ? .white : StudioTokens.dim)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (Return)")
            }
        }
    }

    private var canSend: Bool {
        !copilot.draft.trimmingCharacters(in: .whitespaces).isEmpty && configured
    }

    // MARK: reopen strip (when closed)

    private var reopenStrip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { open = true }
        } label: {
            VStack(spacing: 8) {
                SterlingAvatarView(size: 22)
                Text("STERLING")
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(1)
                    .foregroundStyle(StudioTokens.dim)
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(height: 70)
                Spacer()
            }
            .padding(.top, 10)
            .frame(width: 30)
            .frame(maxHeight: .infinity)
            .background(StudioTokens.panel)
            .overlay(Rectangle().frame(width: 1).foregroundStyle(StudioTokens.stroke), alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("Open Sterling (Cmd+Opt+C)")
    }

    // MARK: shortcut

    private var shortcutButton: some View {
        Button("") {
            guard coordinator.selectedTab == StudioRootView.tabTag else { return }
            withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
        }
        .keyboardShortcut("c", modifiers: [.command, .option])
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: small header controls

    private func headerButton(label: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 8, weight: .heavy))
                .padding(.horizontal, 7).frame(height: 16)
                .background(Capsule().fill(active ? StudioTokens.cyan.opacity(0.22) : StudioTokens.panelHi))
                .foregroundStyle(active ? StudioTokens.cyan : StudioTokens.dim)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(_ systemName: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(StudioTokens.dim)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

// MARK: - Sterling avatar

struct SterlingAvatarView: View {
    var size: CGFloat

    var body: some View {
        Group {
            if let image = SterlingPersona.avatar {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "waveform.circle.fill")
                    .resizable().scaledToFit()
                    .foregroundStyle(StudioTokens.purple)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(StudioTokens.stroke, lineWidth: 1)
        )
    }
}

// MARK: - Message bubble

private struct SterlingMessageBubble: View {
    let message: StudioCopilotModel.ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if message.role == .user {
                Spacer(minLength: 28)
            } else {
                SterlingAvatarView(size: 16).padding(.top, 1)
            }
            Text(message.text)
                .font(.system(size: 11.5))
                .foregroundStyle(StudioTokens.text)
                .textSelection(.enabled)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(message.role == .user ? StudioTokens.purple.opacity(0.20) : StudioTokens.panelHi)
                )
                .fixedSize(horizontal: false, vertical: true)
            if message.role == .assistant { Spacer(minLength: 28) }
        }
    }
}

// MARK: - Tool row (the trust surface)
//
// One agent action, rendered distinctly from chat: a tier-tinted rail + badge,
// tool name, compact args, then the result line. Refusals (blocked, over-budget,
// confirm-gated, engine errors) stay visible in warn color. Click reveals the
// affected region on the timeline; the newest landed edit offers undo.

private struct SterlingToolRow: View {
    let row: StudioCopilotModel.ToolRow
    let showTime: Bool
    let undoable: Bool
    let undone: Bool
    let onReveal: () -> Void
    let onUndo: () -> Void

    private var tint: Color {
        switch row.tier {
        case "read": return StudioTokens.dim
        case "perform": return StudioTokens.cyan
        case "manage": return StudioTokens.warn
        default: return StudioTokens.dim
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1).fill(tint).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(tint)
                    Text(row.tool)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(StudioTokens.text)
                    Text(row.tier.uppercased())
                        .font(.system(size: 7, weight: .heavy))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.18)))
                        .foregroundStyle(tint)
                    statusIcon
                    if row.hasRegion {
                        Image(systemName: "scope")
                            .font(.system(size: 8))
                            .foregroundStyle(StudioTokens.dim)
                            .help("Reveal on the timeline")
                    }
                    Spacer(minLength: 0)
                    if showTime {
                        Text(row.at, format: .dateTime.hour().minute().second())
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(StudioTokens.dim)
                    }
                }
                if !row.argsSummary.isEmpty, row.argsSummary != "{}" {
                    Text(row.argsSummary)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(StudioTokens.dim)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if let result = row.resultSummary, !result.isEmpty {
                    Text("\u{2192} \(result)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(row.ok == true ? StudioTokens.dim : StudioTokens.warn)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if undoable || undone {
                    Button(action: onUndo) {
                        Label(undone ? "Undone" : "Undo", systemImage: undone ? "checkmark" : "arrow.uturn.backward")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(undone ? StudioTokens.dim : StudioTokens.cyan)
                    }
                    .buttonStyle(.plain)
                    .disabled(undone)
                    .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(StudioTokens.bg.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTokens.stroke, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if row.hasRegion { onReveal() } }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch row.ok {
        case .none:
            ProgressView().controlSize(.mini).scaleEffect(0.55).frame(width: 10, height: 10)
        case .some(true):
            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTokens.good)
        case .some(false):
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTokens.warn)
        }
    }
}

// MARK: - Failure banner (dark dock chrome)

/// A turn failure as a person can act on it. The provider's own message is NOT
/// discarded - it moves behind "Show details", which is where diagnostic text
/// belongs. Leading with it (a raw {"error":{...}} envelope in red) was the bug
/// this replaces.
private struct SterlingDockDiagnostic: View {
    let diagnostic: SterlingDiagnostic
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTokens.warn)
                Text(diagnostic.headline)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StudioTokens.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(diagnostic.guidance)
                .font(.system(size: 10))
                .foregroundStyle(StudioTokens.dim)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = diagnostic.detail, !detail.isEmpty {
                Button(showDetail ? "Hide details" : "Show details") { showDetail.toggle() }
                    .font(.system(size: 9, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTokens.faint)
                if showDetail {
                    Text(detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(StudioTokens.faint)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(5)
                        .background(StudioTokens.panelHi)
                        .cornerRadius(4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Settings (BYO endpoint + model + key)

private struct SterlingSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SterlingAvatarView(size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sterling").font(.system(size: 14, weight: .bold))
                    Text(SterlingPersona.role).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // The same editor the main Settings "Sterling" tab shows, so the dock
            // gear and the Settings window edit exactly one BYO config.
            SterlingConfigForm()

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
