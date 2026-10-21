import SwiftUI

struct LLMSettingsView: View {
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @EnvironmentObject var backend: BackendViewModel
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var publisherStore: PublisherStore
    @EnvironmentObject var updateChecker: UpdateChecker
    @State private var showingSaveAlert = false
    @State private var testingConnection = false
    @State private var testResult: String?
    @State private var systemInfo: SystemInfo?
    @State private var testingAceStep = false
    @State private var installingAceStep = false
    @State private var aceStepStatusMessage: String?
    @State private var aceStepStatus = (isInstalled: false, version: "")
    @State private var availableModels: [String: ModelInfo] = [:]
    @State private var loadingModels = false
    @State private var modelLoadError: String?
    @State private var selectedPromptTarget: PromptTarget = .chatModel
    @State private var editedSystemPrompt: String = ""
    @State private var testingRemoteServer = false
    @State private var remoteServerTestResult: String?
    @State private var testingPublishServer = false
    @State private var publishServerTestResult: String?
    @State private var ditModelStatuses: [String: Bool] = [:]
    @State private var ditModelStatusesLoaded = false

    enum PromptTarget: String, CaseIterable, Identifiable {
        case chatModel = "chat"
        case engineerModel = "engineer"

        var id: String { rawValue }
    }

    struct ModelInfo: Codable {
        let name: String
        let size_gb: Double
        let description: String
        let installed: Bool
        let path: String?
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("LLM Provider Settings")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Configure AI models for Sterling's music production assistance")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(backend.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(backend.isConnected ? "Backend Connected" : "Backend Disconnected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top)

                // System Info Section
                if let systemInfo = systemInfo {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 16) {
                            HStack {
                                Image(systemName: "memorychip")
                                Text("\(String(format: "%.1f", systemInfo.totalRAM))GB RAM")
                                    .font(.caption)
                            }
                            HStack {
                                Image(systemName: "internaldrive")
                                Text("\(String(format: "%.1f", systemInfo.availableDisk))GB Free")
                                    .font(.caption)
                                    .foregroundColor(systemInfo.availableDisk < 10 ? .red : .secondary)
                            }
                            HStack {
                                Image(systemName: "cpu")
                                Text(systemInfo.architecture)
                                    .font(.caption)
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 8)
                }

                Divider()

                // ACE-Step Configuration Section
                VStack(alignment: .leading, spacing: 16) {
                    Text("ACE-Step Configuration")
                        .font(.headline)

                    // Status display
                    HStack {
                        Image(systemName: aceStepStatus.isInstalled ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(aceStepStatus.isInstalled ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(aceStepStatus.isInstalled ? "Installed" : "Not Installed")
                                .font(.body)
                            if !llmSettings.aceStepPath.isEmpty {
                                Text("Location: \(llmSettings.aceStepPath)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(aceStepStatus.isInstalled ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                    .cornerRadius(8)

                    // Action buttons
                    HStack(spacing: 8) {
                        Button("Test Installation") {
                            testAceStep()
                        }
                        .disabled(testingAceStep || llmSettings.aceStepPath.isEmpty)
                        .buttonStyle(.bordered)

                        if !aceStepStatus.isInstalled {
                            Button("Install ACE-Step") {
                                installAceStep()
                            }
                            .disabled(installingAceStep)
                            .buttonStyle(.borderedProminent)
                        }

                        Button("Auto-Detect") {
                            llmSettings.autoDetectACEStep()
                            checkAceStepStatus()
                        }
                        .buttonStyle(.bordered)
                    }

                    // Status message
                    if let message = aceStepStatusMessage {
                        HStack {
                            Image(systemName: message.contains("✓") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(message.contains("✓") ? .green : .red)
                            Text(message)
                                .font(.caption)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }

                    // Remote Server (Optional)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Remote Server (Optional)")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        TextField("Server URL", text: $llmSettings.aceStepServerURL, prompt: Text("http://192.168.1.50:8000"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        SecureField("API Key (optional)", text: $llmSettings.aceStepServerAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text("Connect to ACE-Step running on another machine. Leave empty to use local.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button(action: testRemoteServer) {
                            HStack {
                                if testingRemoteServer {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "network")
                                }
                                Text(testingRemoteServer ? "Testing..." : "Test Connection")
                            }
                        }
                        .disabled(testingRemoteServer || llmSettings.aceStepServerURL.isEmpty)
                        .buttonStyle(.bordered)

                        if let result = remoteServerTestResult {
                            HStack {
                                Image(systemName: result.contains("✓") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(result.contains("✓") ? .green : .red)
                                Text(result)
                                    .font(.caption)
                            }
                            .padding(8)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(6)
                        }
                    }
                    .padding(12)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(8)

                    // ACE Music Cloud
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ACE Music Cloud (Free)")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        SecureField("API Key", text: $llmSettings.aceCloudAPIKey, prompt: Text("Enter your acemusic.ai API key"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: llmSettings.aceCloudAPIKey) { _, _ in
                                llmSettings.save()
                            }

                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Free cloud-based music generation via acemusic.ai. No local GPU required.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Get a free API key at acemusic.ai/playground/api-key")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                        }

                        if !llmSettings.aceCloudAPIKey.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("API key configured")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(8)

                    // Generation Mode
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Generation Mode")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Picker("Mode", selection: $llmSettings.generationMode) {
                            Text("Auto").tag(GenerationMode.auto)
                            Text("Local Only").tag(GenerationMode.localOnly)
                            Text("Remote Only").tag(GenerationMode.remoteOnly)
                            Text("Both (Parallel)").tag(GenerationMode.both)
                            if !llmSettings.aceCloudAPIKey.isEmpty {
                                Divider()
                                Text("Cloud Only").tag(GenerationMode.cloudOnly)
                                Text("Local + Cloud").tag(GenerationMode.localAndCloud)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: llmSettings.generationMode) { _, _ in
                            llmSettings.save()
                        }

                        Text(llmSettings.generationMode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if llmSettings.generationMode.usesCloud && llmSettings.aceCloudAPIKey.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text("Cloud mode selected but no API key configured. Generation will fail.")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(8)

                    // DiT Models subsection
                    ditModelsSection
                }

                // MCP Integration
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("MCP Integration")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Use with Claude Code, Claude Desktop, or any MCP client to automate the music pipeline.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Copy MCP Config") {
                        let config = """
                        {
                          "mcpServers": {
                            "majiks-music-studio": {
                              "command": "python",
                              "args": ["-m", "majik_backend.mcp_server"],
                              "env": {
                                "LLM_PROVIDER": "\(llmSettings.primaryProvider.rawValue)",
                                "ACE_STEP_SERVER_URL": "\(llmSettings.aceStepServerURL)",
                                "ACE_STEP_SERVER_API_KEY": "\(llmSettings.aceStepServerAPIKey)"
                              }
                            }
                          }
                        }
                        """
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(config, forType: .string)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(Color(.windowBackgroundColor))
                .cornerRadius(8)

                Divider()

                // ACE-Step Model Downloads Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("ACE-Step Language Models")
                            .font(.headline)
                        Spacer()
                        if loadingModels {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }

                    Text("Download additional language models for music generation")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let progress = downloadManager.aceDownloadProgress {
                        HStack(spacing: 8) {
                            if downloadManager.downloadingACEModel != nil {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(progress)
                                .font(.caption)
                                .foregroundColor(progress.contains("✅") ? .green : (progress.contains("❌") ? .red : .blue))
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                    }

                    if let error = modelLoadError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)

                        Button("Retry") {
                            loadAvailableModels()
                        }
                        .buttonStyle(.borderedProminent)
                    } else if availableModels.isEmpty {
                        Button("Load Available Models") {
                            loadAvailableModels()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(availableModels.sorted(by: { $0.key < $1.key }), id: \.key) { modelId, info in
                                ModelDownloadRow(
                                    modelId: modelId,
                                    info: info,
                                    isDownloading: downloadManager.downloadingACEModel == modelId,
                                    onDownload: {
                                        downloadModel(modelId: modelId)
                                    }
                                )
                            }
                        }
                    }
                }

                Divider()

                // MLX Model Downloads Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("MLX Models (Apple Silicon)")
                            .font(.headline)
                        Spacer()
                        if downloadManager.downloadingMLXModel != nil {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }

                    Text("Download chat models for local AI assistance")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let progress = downloadManager.mlxDownloadProgress {
                        HStack(spacing: 8) {
                            if downloadManager.downloadingMLXModel != nil {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(progress)
                                .font(.caption)
                                .foregroundColor(progress.contains("✅") ? .green : (progress.contains("❌") ? .red : .secondary))
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                    }

                    VStack(spacing: 12) {
                        ForEach(LLMProvider.mlxLocal.models, id: \.self) { model in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(mlxModelDisplayName(model))
                                            .font(.body)
                                            .fontWeight(.medium)
                                        // Was hardcoded to Llama 3.2 3B, which stopped
                                        // being the recommendation three defaults ago
                                        // and was still saying so here. Read the one
                                        // place that decides instead.
                                        if model == LLMProvider.mlxLocal.defaultModel {
                                            Text("Recommended")
                                                .font(.caption2)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(Color.green.opacity(0.2))
                                                .cornerRadius(3)
                                        }
                                    }
                                    Text(mlxModelDescription(model))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(mlxModelSize(model))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if let note = llmSettings.capabilityNote(for: model, provider: .mlxLocal) {
                                        Text(note)
                                            .font(.caption2)
                                            .foregroundColor(
                                                SterlingCapabilities.capability(ofLocalModel: model) == .operatesTheApp
                                                    ? .secondary : .orange)
                                    }
                                }

                                Spacer()

                                if checkMLXModelDownloaded(model) || downloadManager.downloadedMLXModels.contains(model) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text("Downloaded")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    }
                                } else if downloadManager.downloadingMLXModel == model {
                                    VStack(spacing: 4) {
                                        ProgressView()
                                            .controlSize(.small)
                                        if let progress = downloadManager.mlxDownloadProgress, !progress.contains("✅"), !progress.contains("❌") {
                                            Text(progress)
                                                .font(.caption2)
                                                .foregroundColor(.blue)
                                        } else {
                                            Text("Downloading...")
                                                .font(.caption)
                                        }
                                    }
                                } else {
                                    Button("Download") {
                                        downloadMLXModel(model)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                            .padding(10)
                            .background(Color(.windowBackgroundColor))
                            .cornerRadius(8)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Models download from Hugging Face (~3-11GB each, 5-10 min)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Download now or models will auto-download on first chat (may cause delay)")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }

                        if downloadManager.downloadingMLXModel != nil {
                            HStack(spacing: 8) {
                                Image(systemName: "hourglass")
                                    .foregroundColor(.orange)
                                Text("Large downloads may take several minutes. Keep this window open.")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }

                Divider()

                // Primary Provider Section
                VStack(alignment: .leading, spacing: 16) {
                    Text("Primary Model")
                        .font(.headline)

                    Picker("Provider", selection: $llmSettings.primaryProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: llmSettings.primaryProvider) { oldProvider, newProvider in
                        // Unload models from previous provider to free memory
                        if oldProvider != newProvider {
                            Task {
                                do {
                                    let message = try await backend.unloadModels()
                                    print("[LLMSettings] Unloaded models: \(message)")
                                } catch {
                                    print("[LLMSettings] Failed to unload models: \(error)")
                                }
                            }
                        }

                        let presetIds = llmSettings.presetsForProvider(newProvider).map(\.id)
                        if llmSettings.primaryModel.isEmpty || !presetIds.contains(llmSettings.primaryModel) {
                            llmSettings.primaryModel = llmSettings.presetsForProvider(newProvider).first?.id ?? newProvider.defaultModel
                        }
                        if isEndpointProvider(newProvider) && llmSettings.primaryEndpointURL.isEmpty {
                            llmSettings.primaryEndpointURL = defaultEndpointURL(for: newProvider)
                        }
                        if newProvider.requiresAPIKey {
                            llmSettings.primaryAPIKey = llmSettings.getAPIKey(for: newProvider)
                        }
                        llmSettings.loadAdvancedSettings(forModel: llmSettings.primaryModel)
                    }

                    // Provider info
                    HStack(spacing: 12) {
                        Image(systemName: providerIcon(llmSettings.primaryProvider))
                            .foregroundColor(providerColor(llmSettings.primaryProvider))
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(llmSettings.primaryProvider.description)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("Cost: \(llmSettings.primaryProvider.costEstimate)")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)

                    if isEndpointProvider(llmSettings.primaryProvider) {
                        TextField("Endpoint URL", text: $llmSettings.primaryEndpointURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        if llmSettings.primaryProvider == .customOpenAI {
                            SecureField("API Key (optional)", text: $llmSettings.primaryAPIKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                    } else if llmSettings.primaryProvider.requiresAPIKey {
                        apiKeyField(isPrimary: true)
                    }

                    modelPicker(
                        provider: llmSettings.primaryProvider,
                        selection: $llmSettings.primaryModel,
                        allowCustom: llmSettings.primaryProvider == .customOpenAI
                    )

                    if !llmSettings.primaryModel.isEmpty {
                        let description = llmSettings.presetDescription(for: llmSettings.primaryProvider, modelId: llmSettings.primaryModel)
                        if !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let note = llmSettings.capabilityNote(for: llmSettings.primaryModel, provider: llmSettings.primaryProvider) {
                            Text(note)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    sterlingRouteCard
                }

                Divider()

                // Parameter Extraction Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .foregroundColor(.purple)
                            .font(.title3)
                        Text("Parameter Extraction")
                            .font(.headline)
                    }

                    Text("The extraction model (\"The Engineer\") analyzes your conversation to identify lyrics, style, BPM, key, and other music parameters before sending them to the ACE-Step generator. A good extraction model means more accurate music from your descriptions.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker("Extraction Model", selection: $llmSettings.extractionModel) {
                        Text("Qwen 3.5 4B (Default)")
                            .tag("mlx-community/Qwen3.5-4B-4bit")
                        Text("Granite 3.3 2B")
                            .tag("mlx-community/granite-3.3-2b-instruct-8bit")
                        Text("Chat Model (Uses your chat LLM)")
                            .tag("chat")
                        Text("Granite 4.0 H-Micro")
                            .tag("mlx-community/granite-4.0-h-micro-4bit")
                        Text("Granite 4.0 H-Small")
                            .tag("lmstudio-community/granite-4.0-h-small-MLX-4bit")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: llmSettings.extractionModel) {
                        llmSettings.save()
                        if selectedPromptTarget == .engineerModel {
                            refreshPromptEditorText()
                        }
                        // Auto-restart backend so the new extraction model takes effect
                        restartBackend()
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Defaults to your chat model. A dedicated extraction model (~1-2GB) can improve accuracy and free your chat model for conversation.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // Fallback Provider Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Fallback Model (Optional)")
                            .font(.headline)

                        Spacer()

                        Toggle("Enable", isOn: Binding(
                            get: { llmSettings.fallbackProvider != nil },
                            set: { enabled in
                                if enabled {
                                    llmSettings.fallbackProvider = .openrouter
                                    if llmSettings.fallbackModel.isEmpty {
                                        llmSettings.fallbackModel = llmSettings.presetsForProvider(.openrouter).first?.id ?? LLMProvider.openrouter.defaultModel
                                    }
                                } else {
                                    llmSettings.fallbackProvider = nil
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                    }

                    if llmSettings.fallbackProvider != nil {
                        Picker("Provider", selection: Binding(
                            get: { llmSettings.fallbackProvider ?? .openrouter },
                            set: { llmSettings.fallbackProvider = $0 }
                        )) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: llmSettings.fallbackProvider ?? .openrouter) { _, newProvider in
                            let presetIds = llmSettings.presetsForProvider(newProvider).map(\.id)
                            if llmSettings.fallbackModel.isEmpty || !presetIds.contains(llmSettings.fallbackModel) {
                                llmSettings.fallbackModel = llmSettings.presetsForProvider(newProvider).first?.id ?? newProvider.defaultModel
                            }
                            if isEndpointProvider(newProvider) && llmSettings.fallbackEndpointURL.isEmpty {
                                llmSettings.fallbackEndpointURL = defaultEndpointURL(for: newProvider)
                            }
                            if newProvider.requiresAPIKey {
                                llmSettings.fallbackAPIKey = llmSettings.getAPIKey(for: newProvider)
                            }
                        }

                        Text("The Engineer guarantees extraction reliability. Fallback is only for chat failures.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let fallback = llmSettings.fallbackProvider {
                            if isEndpointProvider(fallback) {
                                TextField("Endpoint URL", text: $llmSettings.fallbackEndpointURL)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))

                                if fallback == .customOpenAI {
                                    SecureField("API Key (optional)", text: $llmSettings.fallbackAPIKey)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.body, design: .monospaced))
                                }
                            } else if fallback.requiresAPIKey {
                                apiKeyField(isPrimary: false)
                            }

                            modelPicker(
                                provider: fallback,
                                selection: $llmSettings.fallbackModel,
                                allowCustom: fallback == .customOpenAI
                            )

                            if !llmSettings.fallbackModel.isEmpty {
                                let description = llmSettings.presetDescription(for: fallback, modelId: llmSettings.fallbackModel)
                                if !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                Divider()

                // Advanced Settings Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Advanced")
                            .font(.headline)
                        Spacer()
                        settingBadge(isCustom: llmSettings.hasCustomAdvancedSettings)
                    }

                    DisclosureGroup(isExpanded: $llmSettings.advancedSettingsExpanded) {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("System Prompt Customization")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                Picker("Edit Prompt For", selection: $selectedPromptTarget) {
                                    Text("Chat Model (\(llmSettings.primaryModel))").tag(PromptTarget.chatModel)
                                    Text("The Engineer (\(llmSettings.extractionModelDisplayLabel))").tag(PromptTarget.engineerModel)
                                }
                                .pickerStyle(.menu)
                                .onChange(of: selectedPromptTarget) {
                                    refreshPromptEditorText()
                                }

                                TextEditor(text: $editedSystemPrompt)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minHeight: 200)
                                    .padding(6)
                                    .background(Color(.textBackgroundColor))
                                    .cornerRadius(8)

                                HStack(spacing: 10) {
                                    Button("Load Default") {
                                        let target = promptEditorTargetModel()
                                        llmSettings.resetPromptToDefault(for: target.model, isExtraction: target.isExtraction)
                                        editedSystemPrompt = llmSettings.getSystemPromptFor(model: target.model, isExtraction: target.isExtraction)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Save Custom Prompt") {
                                        let target = promptEditorTargetModel()
                                        llmSettings.saveCustomPrompt(for: target.model, prompt: editedSystemPrompt, isExtraction: target.isExtraction)
                                        refreshPromptEditorText()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }

                            Divider()

                            Text("⚠️ Custom settings may affect model behavior. Reset to defaults if you experience issues.")
                                .font(.caption)
                                .foregroundColor(.orange)

                            Toggle("Use Custom System Prompt", isOn: $llmSettings.useCustomSystemPrompt)
                                .toggleStyle(.switch)
                                .onChange(of: llmSettings.useCustomSystemPrompt) {
                                    llmSettings.saveAdvancedSettingsForCurrentModel()
                                }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Custom System Prompt")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    settingBadge(isCustom: llmSettings.hasActiveCustomPrompt)
                                }
                                ZStack(alignment: .topLeading) {
                                    TextEditor(text: $llmSettings.customSystemPrompt)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(minHeight: 220)
                                        .disabled(!llmSettings.useCustomSystemPrompt)
                                        .opacity(llmSettings.useCustomSystemPrompt ? 1.0 : 0.7)
                                        .onChange(of: llmSettings.customSystemPrompt) {
                                            llmSettings.saveAdvancedSettingsForCurrentModel()
                                        }

                                    if llmSettings.customSystemPrompt.isEmpty {
                                        Text(llmSettings.currentModelDefaults.systemPromptAddition.isEmpty
                                             ? "Default prompt from model_configs.py + Sterling base system prompt."
                                             : llmSettings.currentModelDefaults.systemPromptAddition)
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

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Temperature")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    settingBadge(isCustom: llmSettings.isCustomTemperature)
                                    Spacer()
                                    Text(String(format: "%.2f", llmSettings.advancedTemperature))
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: $llmSettings.advancedTemperature, in: 0...1, step: 0.05)
                                    .onChange(of: llmSettings.advancedTemperature) {
                                        llmSettings.saveAdvancedSettingsForCurrentModel()
                                    }
                                Text("Default: \(String(format: "%.2f", llmSettings.currentModelDefaults.temperature))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Max Tokens")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    settingBadge(isCustom: llmSettings.isCustomMaxTokens)
                                    Spacer()
                                    Text("\(llmSettings.advancedMaxTokens)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                                HStack {
                                    TextField("100-4000",
                                              value: $llmSettings.advancedMaxTokens,
                                              format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                                    .onChange(of: llmSettings.advancedMaxTokens) {
                                        llmSettings.advancedMaxTokens = max(100, min(4000, llmSettings.advancedMaxTokens))
                                        llmSettings.saveAdvancedSettingsForCurrentModel()
                                    }

                                    Stepper("", value: $llmSettings.advancedMaxTokens, in: 100...4000, step: 50)
                                        .labelsHidden()
                                        .onChange(of: llmSettings.advancedMaxTokens) {
                                            llmSettings.saveAdvancedSettingsForCurrentModel()
                                        }
                                }
                                Text("Default: \(llmSettings.currentModelDefaults.maxTokens)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Top P")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    settingBadge(isCustom: llmSettings.isCustomTopP)
                                    Spacer()
                                    Text(String(format: "%.2f", llmSettings.advancedTopP))
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: $llmSettings.advancedTopP, in: 0...1, step: 0.05)
                                    .onChange(of: llmSettings.advancedTopP) {
                                        llmSettings.saveAdvancedSettingsForCurrentModel()
                                    }
                                Text("Default: \(String(format: "%.2f", llmSettings.currentModelDefaults.topP))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Button("Reset to Defaults") {
                                llmSettings.resetAdvancedSettingsToDefaults()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Advanced Settings")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .onChange(of: llmSettings.advancedSettingsExpanded) {
                        UserDefaults.standard.set(llmSettings.advancedSettingsExpanded, forKey: "majik_advanced_settings_expanded")
                    }
                }

                Divider()

                // Behavior Settings Section
                VStack(alignment: .leading, spacing: 16) {
                    Text("Behavior Settings")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $llmSettings.allowAutoGeneration) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Allow Automatic Music Generation (Experimental)")
                                    .font(.body)
                                Text("When enabled, Sterling can automatically generate music during conversation. When disabled, use \"Generate from Chat\" button for full control.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("When enabled, the AI can automatically generate music during chat. Works best with Qwen 3.5 9B. May not work reliably with smaller models.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .onChange(of: llmSettings.allowAutoGeneration) {
                            llmSettings.save()
                        }

                        HStack(spacing: 8) {
                            Image(systemName: llmSettings.allowAutoGeneration ? "bolt.fill" : "hand.raised.fill")
                                .foregroundColor(llmSettings.allowAutoGeneration ? .orange : .blue)
                            Text(llmSettings.allowAutoGeneration ? "Automatic Mode: Sterling generates music when appropriate" : "Manual Mode: You control when to generate (Recommended)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                }

                Divider()

                // Action Buttons
                HStack(spacing: 16) {
                    Button("Save Settings") {
                        llmSettings.save()
                        showingSaveAlert = true
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Restart Backend") {
                        restartBackend()
                    }
                    .buttonStyle(.bordered)

                    Button(action: testConnection) {
                        HStack {
                            if testingConnection {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                            }
                            Text(testingConnection ? "Testing..." : "Test Connection")
                        }
                    }
                    .disabled(testingConnection || !hasRequiredKeys())
                    .buttonStyle(.bordered)
                }

                // Test result
                if let result = testResult {
                    HStack {
                        Image(systemName: result.contains("✓") ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result.contains("✓") ? .green : .red)
                        Text(result)
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }

                Divider()

                // Account Section — the app is free and open-source; the
                // license-key era is over. Publishing gates on signing in
                // with Unicorn Commander (Keycloak), not on a license.
                VStack(alignment: .leading, spacing: 12) {
                    Text("Account")
                        .font(.headline)

                    if case .authenticated = publisherStore.authState {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundColor(.green)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Signed in as \(publisherStore.accountName ?? publisherStore.accountEmail ?? "Unicorn Commander user")")
                                    .font(.body)
                                    .fontWeight(.medium)

                                if let email = publisherStore.accountEmail, publisherStore.accountName != nil {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Button("Sign Out") {
                                publisherStore.clearAuth()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(12)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle")
                                .foregroundColor(.secondary)
                            Text("Not signed in")
                                .font(.body)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)

                        UnicornSignInButton {
                            publisherStore.startLogin()
                        }
                    }

                    Text("Publishing to majiks.online requires signing in with your Unicorn Commander account.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Publishing Server Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Publishing Server")
                        .font(.headline)

                    Text("Configure which server to publish tracks to. Leave empty to use majiks.online.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Server URL") {
                        TextField("https://majiks.online", text: $llmSettings.publishServerURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    LabeledContent("API Key") {
                        SecureField("Optional", text: $llmSettings.publishServerAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button("Test Connection") {
                            testPublishServer()
                        }
                        .disabled(testingPublishServer)

                        if testingPublishServer {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let result = publishServerTestResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                        }

                        Spacer()
                    }
                }

                Divider()

                // Update Checker Section
                UpdateSettingsView(updateChecker: updateChecker)

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            fetchSystemInfo()
            checkAceStepStatus()
            checkDiTModelStatuses()
            loadAvailableModels()
            checkDownloadedMLXModels()
            llmSettings.loadAdvancedSettings(forModel: llmSettings.primaryModel)
            refreshPromptEditorText()
        }
        .onChange(of: llmSettings.primaryModel) { _, newModel in
            llmSettings.loadAdvancedSettings(forModel: newModel)
            if selectedPromptTarget == .chatModel {
                refreshPromptEditorText()
            }
        }
        .alert("Settings Saved", isPresented: $showingSaveAlert) {
            Button("OK") { }
        } message: {
            Text("Your LLM settings have been saved. Click 'Restart Backend' to apply changes, then 'Test Connection' to verify.")
        }
    }

    @ViewBuilder
    private func apiKeyField(isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key")
                .font(.subheadline)
                .fontWeight(.medium)

            SecureField("Enter your API key", text: isPrimary ? $llmSettings.primaryAPIKey : $llmSettings.fallbackAPIKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                    .font(.caption)
                Text(apiKeyHelpText(for: isPrimary ? llmSettings.primaryProvider : (llmSettings.fallbackProvider ?? .openrouter)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func modelPicker(provider: LLMProvider, selection: Binding<String>, allowCustom: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.subheadline)
                .fontWeight(.medium)

            if allowCustom {
                TextField("Model name", text: selection)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                Picker("", selection: selection) {
                    ForEach(llmSettings.presetsForProvider(provider)) { preset in
                        Text(preset.displayName)
                            .help(preset.description)
                            .tag(preset.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selection.wrappedValue) { oldModel, newModel in
                    // Unload models when switching between MLX models
                    if provider == .mlxLocal && oldModel != newModel && !oldModel.isEmpty {
                        Task {
                            do {
                                let message = try await backend.unloadModels()
                                print("[LLMSettings] Unloaded MLX model: \(message)")
                            } catch {
                                print("[LLMSettings] Failed to unload MLX model: \(error)")
                            }
                        }
                    }
                }
            }

            if provider == .mlxLocal {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                        .font(.caption)
                    Text("Models run locally on your Mac. First use may take time to download.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func settingBadge(isCustom: Bool) -> some View {
        Text(isCustom ? "Custom" : "Default")
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isCustom ? Color.orange.opacity(0.2) : Color.gray.opacity(0.2))
            .foregroundColor(isCustom ? .orange : .secondary)
            .cornerRadius(4)
    }

    private func promptEditorTargetModel() -> (model: String, isExtraction: Bool) {
        switch selectedPromptTarget {
        case .chatModel:
            return (llmSettings.primaryModel, false)
        case .engineerModel:
            return (llmSettings.resolvedExtractionModel, true)
        }
    }

    private func refreshPromptEditorText() {
        let target = promptEditorTargetModel()
        editedSystemPrompt = llmSettings.getSystemPromptFor(model: target.model, isExtraction: target.isExtraction)
    }

    private func providerIcon(_ provider: LLMProvider) -> String {
        switch provider {
        case .mlxLocal: return "computermouse.fill"
        case .openrouter: return "globe"
        case .anthropic: return "brain"
        case .openai: return "sparkles"
        case .deepseek: return "dollarsign.circle"
        case .gemini: return "star.fill"
        case .ollama: return "terminal"
        case .lmStudio: return "desktopcomputer"
        case .customOpenAI: return "link"
        }
    }

    private func providerColor(_ provider: LLMProvider) -> Color {
        switch provider {
        case .mlxLocal: return .green
        case .openrouter: return .blue
        case .anthropic: return .purple
        case .openai: return .orange
        case .deepseek: return .indigo
        case .gemini: return .yellow
        case .ollama: return .green
        case .lmStudio: return .teal
        case .customOpenAI: return .gray
        }
    }

    private func apiKeyHelpText(for provider: LLMProvider) -> String {
        switch provider {
        case .openrouter: return "Get your key at openrouter.ai/keys"
        case .anthropic: return "Get your key at console.anthropic.com"
        case .openai: return "Get your key at platform.openai.com/api-keys"
        case .deepseek: return "Get your key at platform.deepseek.com"
        case .gemini: return "Get your key at ai.google.dev"
        case .mlxLocal: return ""
        case .ollama, .lmStudio, .customOpenAI:
            return "API key is optional for local endpoints"
        }
    }

    private func hasRequiredKeys() -> Bool {
        if llmSettings.primaryProvider.requiresAPIKey && llmSettings.primaryAPIKey.isEmpty {
            return false
        }
        if let fallback = llmSettings.fallbackProvider, fallback.requiresAPIKey, llmSettings.fallbackAPIKey.isEmpty {
            return false
        }
        return true
    }

    private func isEndpointProvider(_ provider: LLMProvider) -> Bool {
        switch provider {
        case .ollama, .lmStudio, .customOpenAI:
            return true
        default:
            return false
        }
    }

    private func defaultEndpointURL(for provider: LLMProvider) -> String {
        switch provider {
        case .ollama:
            return "http://localhost:11434"
        case .lmStudio:
            return "http://localhost:1234"
        default:
            return ""
        }
    }

    private func testConnection() {
        testingConnection = true
        testResult = nil

        Task {
            do {
                let info = try await backend.listLLMProviders()
                await MainActor.run {
                    testResult = "✓ Connected! Using \(info.current) with \(info.available.count) provider(s) available"
                    testingConnection = false
                }
            } catch {
                await MainActor.run {
                    testResult = "✗ Connection failed: \(error.localizedDescription). Try saving and restarting the backend first."
                    testingConnection = false
                }
            }
        }
    }

    private func restartBackend() {
        testResult = "Restarting backend..."

        // Get environment variables from settings
        let env = llmSettings.getEnvironmentVariables()

        // Reset crash counter so previous crashes don't block this restart
        backend.resetRestartCount()

        // Restart backend with new environment
        backend.stop()

        // Small delay to ensure clean shutdown
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            backend.start(environment: env)

            // Check status after a moment
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if backend.statusMessage.contains("failed") {
                    testResult = "✗ Backend restart failed: \(backend.statusMessage)"
                } else {
                    testResult = "✓ Backend restarted successfully: \(backend.statusMessage)"
                }
            }
        }
    }

    private func fetchSystemInfo() {
        Task {
            do {
                let info = try await backend.getSystemInfo()
                await MainActor.run {
                    systemInfo = info
                }
            } catch {
                print("Failed to fetch system info: \(error)")
            }
        }
    }

    private func checkAceStepStatus() {
        aceStepStatus.isInstalled = !llmSettings.aceStepPath.isEmpty
    }

    private func testRemoteServer() {
        testingRemoteServer = true
        remoteServerTestResult = nil

        Task {
            do {
                let result = try await backend.testRemoteACEStep(serverURL: llmSettings.aceStepServerURL)
                await MainActor.run {
                    remoteServerTestResult = result.success
                        ? "✓ Remote server is reachable"
                        : "✗ Connection failed: \(result.message)"
                    testingRemoteServer = false
                }
            } catch {
                await MainActor.run {
                    remoteServerTestResult = "✗ Connection failed: \(error.localizedDescription)"
                    testingRemoteServer = false
                }
            }
        }
    }

    private func testPublishServer() {
        testingPublishServer = true
        publishServerTestResult = nil

        let serverURL = llmSettings.publishServerURL.isEmpty
            ? "https://majiks.online"
            : llmSettings.publishServerURL

        Task {
            do {
                // Hit the unauthenticated health endpoint instead of the
                // bridge API. The old test sent the hardcoded shared bridge
                // token to /catalogue?keycloak_id=test which always returned
                // 404 (user "test" doesn't exist), giving a false negative.
                let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let url = URL(string: "\(base)/api/health")!
                let request = URLRequest(url: url, timeoutInterval: 10)

                let (data, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse

                await MainActor.run {
                    if let status = httpResponse?.statusCode, (200..<300).contains(status) {
                        // Optionally show the service name from the health response
                        var detail = ""
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let service = json["service"] as? String {
                            detail = " (\(service))"
                        }
                        publishServerTestResult = "✓ Publishing server is reachable\(detail)"
                    } else {
                        publishServerTestResult = "✗ Server returned HTTP \(httpResponse?.statusCode ?? 0)"
                    }
                    testingPublishServer = false
                }
            } catch {
                await MainActor.run {
                    publishServerTestResult = "✗ Connection failed: \(error.localizedDescription)"
                    testingPublishServer = false
                }
            }
        }
    }

    private func testAceStep() {
        testingAceStep = true
        aceStepStatusMessage = nil

        Task {
            do {
                let result = try await backend.testAceStepInstallation()
                await MainActor.run {
                    aceStepStatus = (isInstalled: result.isWorking, version: "")
                    aceStepStatusMessage = result.isWorking
                        ? "✓ ACE-Step is working at: \(result.path ?? "configured path")"
                        : "✗ ACE-Step test failed: \(result.message ?? "Unknown error")"
                    testingAceStep = false
                }
            } catch {
                await MainActor.run {
                    aceStepStatusMessage = "✗ Test failed: \(error.localizedDescription)"
                    testingAceStep = false
                }
            }
        }
    }

    private func installAceStep() {
        installingAceStep = true
        aceStepStatusMessage = "Installing ACE-Step..."

        Task {
            do {
                let result = try await backend.installAceStep()
                await MainActor.run {
                    if result.success {
                        let statusDetail = result.status ?? "installed"
                        aceStepStatusMessage = "✓ ACE-Step \(statusDetail) successfully!"
                        llmSettings.autoDetectACEStep()
                        aceStepStatus = (isInstalled: true, version: "")
                    } else {
                        aceStepStatusMessage = "✗ Installation failed: \(result.error ?? "Unknown error")"
                    }
                    installingAceStep = false
                }
            } catch {
                await MainActor.run {
                    aceStepStatusMessage = "✗ Installation failed: \(error.localizedDescription)"
                    installingAceStep = false
                }
            }
        }
    }

    private func loadAvailableModels() {
        loadingModels = true
        modelLoadError = nil
        Task {
            do {
                let models = try await backend.listAvailableModels()
                await MainActor.run {
                    availableModels = models
                    modelLoadError = nil
                    loadingModels = false
                }
            } catch {
                await MainActor.run {
                    print("[Settings] Failed to load models: \(error)")
                    modelLoadError = "Failed to load models: \(error.localizedDescription)"
                    loadingModels = false
                }
            }
        }
    }

    private func downloadModel(modelId: String) {
        downloadManager.startACEDownload(modelId: modelId)
        Task {
            do {
                let result = try await backend.downloadModel(modelId: modelId)
                await MainActor.run {
                    print("[Settings] Download result: \(result)")
                    downloadManager.completeACEDownload(modelId: modelId, success: true)
                    // Reload model list to update installed status
                    loadAvailableModels()
                }
            } catch {
                await MainActor.run {
                    print("[Settings] Download failed: \(error)")
                    downloadManager.completeACEDownload(modelId: modelId, success: false, error: error.localizedDescription)
                    modelLoadError = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Sterling routing
    //
    // Sterling drives 148 MCP tools and 119 journalled commands, so "which model
    // is selected" and "can Sterling operate the app" are different questions.
    // This card answers the second one out loud, in all three cases, rather than
    // letting a chat model be handed the tool surface and look like a broken app.
    //
    // No new controls: the two routes it names are reached by controls that
    // already exist (the Sterling settings tab, and the model downloader), so
    // this stays text and the help-coverage counts do not move.

    @ViewBuilder
    private var sterlingRouteCard: some View {
        let route = SterlingRouter.route(for: llmSettings)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: route.canOperateTheApp ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundColor(route.canOperateTheApp ? .green : .orange)
                Text("Sterling")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }

            switch route {
            case let .remote(model, source):
                Text("Runs on \(model.isEmpty ? "the configured endpoint" : model), from \(source.settingsLocation). It uses no memory on this Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case let .local(model):
                Text("Runs on \(SterlingRouter.shortName(model)) on this Mac. It needs roughly 20 GB of memory while it is loaded.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case let .refused(refusal):
                Text(refusal.headline)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
                Text(refusal.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(refusal.offers.enumerated()), id: \.offset) { _, offer in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(offer.title)
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(offer.detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((route.canOperateTheApp ? Color.green : Color.orange).opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - MLX Model Helpers

    private func checkDownloadedMLXModels() {
        // DownloadManager already checks on init, but we can trigger a refresh if needed
        // No-op since DownloadManager handles this globally
    }

    private func mlxModelDisplayName(_ model: String) -> String {
        let name = model.replacingOccurrences(of: "mlx-community/", with: "")
        if name.contains("Qwen3-30B-A3B") {
            return "Qwen3 30B A3B"
        } else if name.contains("Llama-3.2-3B") {
            return "Llama 3.2 3B"
        } else if name.contains("Meta-Llama-3.1-8B") {
            return "Llama 3.1 8B"
        } else if name.contains("NuExtract") || name.contains("numind") {
            return "NuExtract 1.5"
        } else if name.contains("gpt-oss-20b") {
            return "GPT OSS 20B"
        } else if name.contains("granite-3.3-8b") {
            return "Granite 3.3 8B"
        } else if name.contains("granite-4.0-h-micro") {
            return "Granite 4.0 Micro"
        } else if name.contains("granite-4.0-h-small") {
            return "Granite 4.0 H-Small"
        } else if name.contains("GLM-4.7") {
            return "GLM 4.7 Flash"
        }
        return name
    }

    private func mlxModelDescription(_ model: String) -> String {
        if model.contains("Qwen3-30B-A3B") {
            return "Strong local MoE (30B/~3B active): best local chat, reasoning & tool use"
        } else if model.contains("Llama-3.2-3B") {
            return "Best creative quality for chat (recommended)"
        } else if model.contains("Meta-Llama-3.1-8B") {
            return "Balanced quality and speed with stronger reasoning"
        } else if model.contains("NuExtract") || model.contains("numind") {
            return "The Engineer default: 100% accurate structured extraction"
        } else if model.contains("gpt-oss-20b") {
            return "20B params, high quality, best for complex tasks"
        } else if model.contains("granite-3.3-8b") {
            return "8B params, balanced quality and speed"
        } else if model.contains("granite-4.0-h-micro") {
            return "Fast hybrid model, good for chat"
        } else if model.contains("granite-4.0-h-small") {
            return "Larger capacity hybrid model"
        } else if model.contains("GLM-4.7") {
            return "Multilingual, fast generation"
        }
        return "MLX-optimized model"
    }

    private func mlxModelSize(_ model: String) -> String {
        if model.contains("Qwen3-30B-A3B") {
            return "~17GB download"
        } else if model.contains("Llama-3.2-3B") {
            return "~2GB download"
        } else if model.contains("Meta-Llama-3.1-8B") {
            return "~5GB download"
        } else if model.contains("gpt-oss-20b") {
            return "~11GB download"
        } else if model.contains("granite-3.3-8b") {
            return "~4GB download"
        } else if model.contains("granite-4.0-h-micro") {
            return "~2GB download"
        } else if model.contains("granite-4.0-h-small") {
            return "~5GB download"
        } else if model.contains("GLM-4.7") {
            return "~16GB download"
        } else if model.contains("NuExtract") || model.contains("numind") {
            return "~1GB download"
        }
        return "Size varies"
    }

    private func checkMLXModelDownloaded(_ model: String) -> Bool {
        // Check if model exists in HuggingFace cache
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")

        let modelPath = model.replacingOccurrences(of: "/", with: "--")
        let modelDir = cacheDir.appendingPathComponent("models--\(modelPath)")

        return FileExistenceProbe.exists(atPath: modelDir.path)
    }

    private func downloadMLXModel(_ model: String) {
        downloadManager.startMLXDownload(model: model)

        Task {
            do {
                // Use dedicated download method with progress tracking
                _ = try await backend.downloadMLXModel(model: model)

                await MainActor.run {
                    downloadManager.completeMLXDownload(model: model, success: true)
                }
            } catch {
                await MainActor.run {
                    downloadManager.completeMLXDownload(model: model, success: false, error: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - DiT Model Definitions

    struct DiTModelInfo: Identifiable {
        let id: String          // e.g. "acestep-v15-turbo"
        let displayName: String
        let description: String
        let sizeEstimate: String
        let huggingFaceRepo: String
        let isIncludedInMain: Bool  // Comes with the main ACE-Step download
    }

    static let ditModels: [DiTModelInfo] = [
        DiTModelInfo(
            id: "acestep-v15-turbo",
            displayName: "Turbo",
            description: "Fastest generation (8 steps). Default model for quick iteration.",
            sizeEstimate: "~1.5 GB",
            huggingFaceRepo: "ACE-Step/Ace-Step1.5",
            isIncludedInMain: true
        ),
        DiTModelInfo(
            id: "acestep-v15-base",
            displayName: "Base",
            description: "Required for repaint, extract, lego, and complete modes.",
            sizeEstimate: "~1.5 GB",
            huggingFaceRepo: "ACE-Step/acestep-v15-base",
            isIncludedInMain: false
        ),
        DiTModelInfo(
            id: "acestep-v15-sft",
            displayName: "SFT (Highest Quality 2B)",
            description: "Supervised fine-tuned for maximum quality. 32+ inference steps.",
            sizeEstimate: "~1.5 GB",
            huggingFaceRepo: "ACE-Step/acestep-v15-sft",
            isIncludedInMain: false
        ),
        DiTModelInfo(
            id: "acestep-v15-xl-turbo",
            displayName: "XL Turbo (4B)",
            description: "4B parameter turbo model. Higher quality than 2B, 8 steps. Requires 12+ GB RAM.",
            sizeEstimate: "~3 GB",
            huggingFaceRepo: "ACE-Step/acestep-v15-xl-turbo",
            isIncludedInMain: false
        ),
        DiTModelInfo(
            id: "acestep-v15-xl-base",
            displayName: "XL Base (4B)",
            description: "4B parameter base model. Required for XL repaint/extract/lego/complete modes. 50 steps.",
            sizeEstimate: "~3 GB",
            huggingFaceRepo: "ACE-Step/acestep-v15-xl-base",
            isIncludedInMain: false
        ),
        DiTModelInfo(
            id: "acestep-v15-xl-sft",
            displayName: "XL SFT (4B, Highest Quality)",
            description: "4B parameter supervised fine-tuned. Best quality available. 50 steps, 12+ GB RAM.",
            sizeEstimate: "~3 GB",
            huggingFaceRepo: "ACE-Step/acestep-v15-xl-sft",
            isIncludedInMain: false
        ),
    ]

    // MARK: - DiT Models Section View

    @ViewBuilder
    private var ditModelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DiT Models")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Button {
                    checkDiTModelStatuses()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh download status")
            }

            Text("Diffusion Transformer models for music generation. Turbo is included with the initial install.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let progress = downloadManager.ditDownloadProgress {
                HStack(spacing: 8) {
                    if downloadManager.downloadingDiTModel != nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(progress)
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .padding(8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }

            if llmSettings.aceStepPath.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("ACE-Step not installed. Install ACE-Step first to manage DiT models.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            } else {
                VStack(spacing: 8) {
                    ForEach(Self.ditModels) { model in
                        ditModelRow(model: model)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.windowBackgroundColor))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func ditModelRow(model: DiTModelInfo) -> some View {
        let isDownloaded = ditModelStatuses[model.id] == true || downloadManager.downloadedDiTModels.contains(model.id)
        let isDownloading = downloadManager.downloadingDiTModel == model.id

        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(isDownloaded ? Color.green : (isDownloading ? Color.yellow : Color.gray.opacity(0.4)))
                .frame(width: 10, height: 10)

            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                    if model.isIncludedInMain {
                        Text("Default")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(3)
                    }
                }
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Text(model.sizeEstimate)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status / action
            if isDownloaded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Downloaded")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            } else if isDownloading {
                VStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading...")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            } else {
                Button("Download") {
                    downloadDiTModel(model)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(downloadManager.downloadingDiTModel != nil)
            }
        }
        .padding(10)
        .background(isDownloaded ? Color.green.opacity(0.03) : Color.gray.opacity(0.03))
        .cornerRadius(8)
    }

    // MARK: - DiT Model Detection & Download

    private func checkDiTModelStatuses() {
        var statuses: [String: Bool] = [:]
        let fm = FileManager.default

        // Determine the checkpoints directory
        // For bundled installs: <aceStepPath>/checkpoints/
        // For external installs: models may be at <aceStepPath>/ directly or <aceStepPath>/checkpoints/
        let aceStepPath = llmSettings.aceStepPath
        guard !aceStepPath.isEmpty else {
            ditModelStatuses = statuses
            ditModelStatusesLoaded = true
            return
        }

        let basePath = URL(fileURLWithPath: aceStepPath)
        let checkpointsPath = basePath.appendingPathComponent("checkpoints")

        for model in Self.ditModels {
            // Check both locations: directly in aceStepPath and in checkpoints subdirectory
            let directPath = basePath.appendingPathComponent(model.id)
            let nestedPath = checkpointsPath.appendingPathComponent(model.id)

            let directExists = fm.fileExists(atPath: directPath.path)
            let nestedExists = fm.fileExists(atPath: nestedPath.path)

            statuses[model.id] = directExists || nestedExists
        }

        ditModelStatuses = statuses
        ditModelStatusesLoaded = true
    }

    private func downloadDiTModel(_ model: DiTModelInfo) {
        // Route downloads through the shared GenerationModelStore so the
        // LLM & Models tab and the Models tab use one download mechanism and
        // one huggingface-cli lookup (see GenerationModelStore.download).
        GenerationModelStore.download(model: model, aceStepPath: llmSettings.aceStepPath) {
            checkDiTModelStatuses()
        }
    }
}

// Model Download Row Component
struct ModelDownloadRow: View {
    let modelId: String
    let info: LLMSettingsView.ModelInfo
    let isDownloading: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: info.installed ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundColor(info.installed ? .green : .blue)
                .font(.title3)

            // Model info
            VStack(alignment: .leading, spacing: 4) {
                Text(info.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text(info.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Label("\(String(format: "%.1f", info.size_gb))GB", systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if info.installed {
                        Text("✓ Installed")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }

            Spacer()

            // Action button
            if info.installed {
                Image(systemName: "checkmark")
                    .foregroundColor(.green)
            } else if isDownloading {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Downloading...")
                    .font(.caption)
            } else {
                Button("Download") {
                    onDownload()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(info.installed ? Color.green.opacity(0.05) : Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
}
