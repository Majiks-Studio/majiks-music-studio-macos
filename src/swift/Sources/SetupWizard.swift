import SwiftUI

/// Multi-step setup wizard for first-run experience
struct SetupWizardView: View {
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @EnvironmentObject var publisherStore: PublisherStore
    @EnvironmentObject var backend: BackendViewModel
    @EnvironmentObject var downloadManager: DownloadManager
    @Environment(\.dismiss) var dismiss

    /// Called when the user finishes the wizard (clicks "Start Creating Music!")
    var onComplete: (() -> Void)? = nil

    @State private var currentStep = 0

    @State private var aceStepPath = ""
    @State private var aceStepDetected = false
    @State private var isInstallingACEStep = false
    @State private var installationProgress: String?

    @State private var selectedLLMProvider: LLMProvider = .mlxLocal
    @State private var selectedMLXModel: String = ""
    @State private var openRouterAPIKey = ""
    @State private var systemRAM: Int = 0
    @State private var chipModel: String = ""

    @State private var availableACEModels: [String: LLMSettingsView.ModelInfo] = [:]
    @State private var selectedACEModelID: String = ""

    // Sterling copilot endpoint. Same storage as the dock's SterlingSettingsView:
    // endpoint/model persist to the "sterling.endpoint"/"sterling.model" UserDefaults
    // keys, the API key to the Keychain via SterlingKeychain. The wizard step and the
    // dock gear are interchangeable.
    @AppStorage("sterling.endpoint") private var sterlingEndpoint = ""
    @AppStorage("sterling.model") private var sterlingModel = ""
    @State private var sterlingAPIKey = ""
    @State private var sterlingKeyPresent = SterlingKeychain.hasKey
    @State private var sterlingProbing = false
    @State private var sterlingProbeOutcome: SterlingProbeOutcome?

    private let totalSteps = 6

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content area
            ScrollView {
                VStack(spacing: 24) {
                    switch currentStep {
                    case 0:
                        welcomeStep
                    case 1:
                        accountStep
                    case 2:
                        aceStepInstallStep
                    case 3:
                        llmConfigStep
                    case 4:
                        sterlingStep
                    case 5:
                        completeStep
                    default:
                        EmptyView()
                    }
                }
                .padding(32)
            }

            Divider()

            // Footer with navigation buttons
            footerView
        }
        .frame(minWidth: 800, idealWidth: 900, maxWidth: 1000, minHeight: 700, idealHeight: 800, maxHeight: 900)
        .onChange(of: currentStep) { _, newStep in
            // Check for ACE-Step when entering the install step
            let aceStepStep = 2
            if newStep == aceStepStep {
                checkForACEStep()
            }
        }
        .onAppear {
            let aceStepStep = 2
            if currentStep == aceStepStep {
                checkForACEStep()
            }
            // Detect hardware
            detectHardware()
            // Keep a saved chat choice; only an unset choice follows the Mac's
            // memory-aware default.
            selectedMLXModel = llmSettings.mlxModel.isEmpty ? recommendedMLXModel() : llmSettings.mlxModel
            selectedACEModelID = LMModel.recommended(forPhysicalMemoryGB: LMModel.physicalMemoryGB).rawValue
            // Check which models are already downloaded
            checkDownloadedModels()
        }
    }

    private func checkDownloadedModels() {
        for model in LLMProvider.mlxLocal.models {
            if checkModelDownloaded(model) {
                downloadManager.downloadedMLXModels.insert(model)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 12) {
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Text("Setup Wizard")
                .font(.title2)
                .bold()

            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            Text("Step \(currentStep + 1) of \(totalSteps)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 64))
                .foregroundColor(.blue)

            Text("Welcome to Majik's Music Studio!")
                .font(.title)
                .bold()

            Text("Let's get you set up in just a few steps. This wizard will help you:")
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "person.crop.circle", text: "Sign in to publish on majiks.online (optional)")
                FeatureRow(icon: "cpu", text: "Install ACE-Step music generation engine")
                FeatureRow(icon: "brain", text: "Configure AI language model")
                FeatureRow(icon: "checkmark.circle", text: "Start creating music!")
            }
            .padding()
            .background(Color(.windowBackgroundColor))
            .cornerRadius(12)

            Text("Estimated time: 5-10 minutes")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Step 1: Account

    private var accountStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("Your Account (Optional)")
                .font(.title2)
                .bold()

            Text("Publishing to majiks.online requires signing in with your Unicorn Commander account. You can also do this later from Settings or the Publisher tab.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if case .authenticated = publisherStore.authState {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Signed in as \(publisherStore.accountName ?? publisherStore.accountEmail ?? "Unicorn Commander user")")
                        .font(.body)
                }
                .padding()
                .background(Color(.windowBackgroundColor))
                .cornerRadius(12)
            } else {
                UnicornSignInButton {
                    publisherStore.startLogin()
                }
            }
        }
    }

    // MARK: - Step 2: ACE-Step Installation

    private var aceStepInstallStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "cpu")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("Install ACE-Step 1.5")
                .font(.title2)
                .bold()

            Text("ACE-Step is the AI music generation engine. Installation has two parts:")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            // Flow explanation
            HStack(spacing: 8) {
                VStack(spacing: 4) {
                    Image(systemName: "1.circle.fill")
                        .foregroundColor(aceStepDetected ? .green : .blue)
                    Text("Install")
                        .font(.caption2)
                }
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                VStack(spacing: 4) {
                    Image(systemName: "2.circle.fill")
                        .foregroundColor(aceStepDetected && availableACEModels.values.contains(where: { $0.installed }) ? .green : .secondary)
                    Text("Download Model")
                        .font(.caption2)
                }
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(aceStepDetected && availableACEModels.values.contains(where: { $0.installed }) ? .green : .secondary)
                    Text("Ready!")
                        .font(.caption2)
                }
            }
            .padding(.vertical, 8)

            // Auto-detection
            if aceStepDetected {
                // Check if ACE-Step is bundled (path contains app bundle)
                let isBundled = llmSettings.aceStepPath.contains(".app/Contents/Resources")

                VStack(spacing: 16) {
                    // Detection success
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(isBundled ? "ACE-Step is bundled!" : "ACE-Step detected!")
                                .font(.headline)
                        }

                        if isBundled {
                            Text("Pre-installed with this edition - ready to use!")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Text("Found at: \(llmSettings.aceStepPath)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)

                    // Language Model downloads
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Download Language Models")
                                .font(.headline)
                            Spacer()
                            if downloadManager.downloadingACEModel != nil {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                        }

                        Text("ACE-Step needs a language model. Choose one to download:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("Recommended download: \(recommendedLMModel.displayName) (\(recommendedLMModel.minimumRAMLabel)).")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if memoryForDefaultsGB < 24 {
                            Text("0.6B is selected by default because this Mac has less than 24 GB of physical RAM.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let selectedInfo = availableACEModels[selectedACEModelID], !selectedInfo.installed {
                            Button("Download Selected Model") {
                                downloadACEModel(modelId: selectedACEModelID)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(downloadManager.downloadingACEModel != nil)
                        }

                        if let error = downloadManager.aceDownloadError {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(error)
                                    .font(.caption)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(6)
                        }

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

                        if !availableACEModels.isEmpty {
                            ForEach(availableACEModels.sorted(by: { first, second in
                                if first.key == recommendedLMModelID { return true }
                                if second.key == recommendedLMModelID { return false }
                                return first.key < second.key
                            }), id: \.key) { modelId, info in
                                HStack(spacing: 12) {
                                    Button {
                                        selectedACEModelID = modelId
                                    } label: {
                                        Image(systemName: selectedACEModelID == modelId ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(selectedACEModelID == modelId ? .blue : .gray)
                                    }
                                    .buttonStyle(.plain)

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(info.name)
                                                .font(.body)
                                                .fontWeight(.medium)
                                            if modelId == recommendedLMModelID {
                                                Text("Recommended")
                                                    .font(.caption2)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 2)
                                                    .background(Color.green.opacity(0.2))
                                                    .cornerRadius(3)
                                            }
                                        }
                                        Text(info.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        if let lmModel = LMModel(rawValue: modelId) {
                                            Text(lmModel.minimumRAMLabel)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Label("\(String(format: "%.1f", info.size_gb))GB", systemImage: "internaldrive")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if info.installed {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                            Text("Installed")
                                                .font(.caption)
                                        }
                                    } else if downloadManager.downloadingACEModel == modelId {
                                        VStack(spacing: 4) {
                                            ProgressView()
                                                .controlSize(.small)
                                            if let progress = downloadManager.aceDownloadProgress, !progress.contains("✅"), !progress.contains("❌") {
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
                                            downloadACEModel(modelId: modelId)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(downloadManager.downloadingACEModel != nil)
                                    }
                                }
                                .padding(10)
                                .background(Color(.windowBackgroundColor))
                                .cornerRadius(8)
                            }
                        } else {
                            Button("Load Available Models") {
                                loadACEModels()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(12)

                    if !availableACEModels.isEmpty && availableACEModels.values.contains(where: { $0.installed }) {
                        Text("✅ ACE-Step ready! Click Next to configure your chat LLM.")
                            .font(.body)
                            .foregroundColor(.green)
                    } else if !availableACEModels.isEmpty {
                        // Models available but none downloaded yet
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundColor(.orange)
                            Text("Download at least one model above to enable music generation.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    } else {
                        // No models loaded yet
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            Text("Click 'Load Available Models' to see download options.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                // Installation options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose an installation method:")
                        .font(.headline)

                    // Option 1: Automatic (recommended)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundColor(.blue)
                                Text("Automatic Installation")
                                    .font(.headline)
                                Spacer()
                                Text("Recommended")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(4)
                            }

                            Text("We'll download and install ACE-Step for you (~2GB download).")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if isInstallingACEStep {
                                VStack(alignment: .leading, spacing: 8) {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text(installationProgress ?? "Installing...")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    }
                                    Text("Please wait -- this may take a few minutes. Do not close this window.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(10)
                                .background(Color.blue.opacity(0.08))
                                .cornerRadius(8)
                            } else if let progress = installationProgress {
                                HStack {
                                    if progress.contains("installed") || progress.contains("Restarting") {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                    Text(progress)
                                        .font(.caption)
                                        .foregroundColor(progress.contains("failed") || progress.contains("error") ? .red : .green)
                                }
                            }

                            Button("Install Automatically") {
                                installACEStepAutomatically()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isInstallingACEStep)
                        }
                    }

                    // Option 2: Manual
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "terminal")
                                    .foregroundColor(.secondary)
                                Text("Manual Installation")
                                    .font(.headline)
                            }

                            Text("Run this command in Terminal:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("pip3 install -q huggingface_hub 'git+https://github.com/ace-step/ACE-Step.git' && huggingface-cli download ACE-Step/Ace-Step1.5 --local-dir ~/ACE-Step-1.5 --local-dir-use-symlinks False")
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .background(Color(.textBackgroundColor))
                                .cornerRadius(4)
                                .textSelection(.enabled)

                            Button("Copy Command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("pip3 install -q huggingface_hub 'git+https://github.com/ace-step/ACE-Step.git' && huggingface-cli download ACE-Step/Ace-Step1.5 --local-dir ~/ACE-Step-1.5 --local-dir-use-symlinks False", forType: .string)
                            }
                            .buttonStyle(.bordered)

                            Button("I've Installed It - Check Again") {
                                checkForACEStep()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    if aceStepDetected {
                                        installationProgress = "ACE-Step detected!"
                                    } else {
                                        installationProgress = "Still not found. Make sure it's at ~/ACE-Step-1.5"
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Option 3: Skip (not recommended)
                    Text("You can skip this step, but you won't be able to generate music until ACE-Step is installed.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(4)
                }
            }
        }
    }

    // MARK: - Step 3: LLM Configuration

    private var llmConfigStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("Configure AI Language Model")
                .font(.title2)
                .bold()

            Text("Choose how you want to power the AI chat and music descriptions.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                Text("Select LLM Provider:")
                    .font(.headline)

                // Option 1: Local MLX (recommended)
                Button {
                    selectedLLMProvider = .mlxLocal
                } label: {
                    HStack {
                        Image(systemName: selectedLLMProvider == .mlxLocal ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedLLMProvider == .mlxLocal ? .blue : .gray)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Local MLX (Apple Silicon)")
                                    .font(.headline)
                                Text("Recommended")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(4)
                            }
                            Text("Free, private, runs on your Mac (M1/M2/M3)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if systemRAM > 0 {
                                Text("Detected: \(systemRAM)GB RAM")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()
                    }
                    .padding()
                    .background(selectedLLMProvider == .mlxLocal ? Color.blue.opacity(0.1) : Color(.windowBackgroundColor))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // MLX Model Selection (shown when MLX is selected)
                if selectedLLMProvider == .mlxLocal {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Select Model")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        ForEach(LLMProvider.mlxLocal.models, id: \.self) { model in
                            HStack(spacing: 8) {
                                Button {
                                    selectedMLXModel = model
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selectedMLXModel == model ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(selectedMLXModel == model ? .blue : .gray)

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(modelDisplayName(model))
                                                    .font(.body)
                                                if model == recommendedMLXModel() {
                                                    Text("Recommended")
                                                        .font(.caption2)
                                                        .padding(.horizontal, 4)
                                                        .padding(.vertical, 2)
                                                        .background(Color.green.opacity(0.2))
                                                        .cornerRadius(3)
                                                }
                                            }
                                            Text(modelRAMRequirement(model))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            // Said at the point of choice, because this
                                            // is where most people pick once and never
                                            // look again — and a chat model handed
                                            // Sterling's 148 tools looks like a broken
                                            // app rather than a wrong setting.
                                            if let note = llmSettings.capabilityNote(for: model, provider: .mlxLocal) {
                                                Text(note)
                                                    .font(.caption2)
                                                    .foregroundColor(
                                                        SterlingCapabilities.capability(ofLocalModel: model) == .operatesTheApp
                                                            ? .secondary : .orange)
                                            }
                                        }

                                        Spacer()
                                    }
                                    .padding(10)
                                    .background(selectedMLXModel == model ? Color.blue.opacity(0.1) : Color(.windowBackgroundColor))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)

                                // Download status and button
                                if checkModelDownloaded(model) || downloadManager.downloadedMLXModels.contains(model) {
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
                                        Text("Downloading...")
                                            .font(.caption2)
                                    }
                                } else {
                                    Button(action: {
                                        downloadMLXModel(model)
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.down.circle")
                                            Text("Download")
                                                .font(.caption)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(downloadManager.downloadingMLXModel != nil)
                                }
                            }
                        }

                        // Download info and progress
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Download now or skip - models can be downloaded later from Settings")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("⚠️ If skipped, models will auto-download on first chat (5-10 min delay)")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                        .fontWeight(.medium)
                                }
                            }

                            if downloadManager.downloadingMLXModel != nil {
                                HStack(spacing: 8) {
                                    Image(systemName: "hourglass")
                                        .foregroundColor(.orange)
                                    Text("Large downloads take 5-10 minutes. Keep this window open.")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }

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
                                .padding(.top, 4)
                            }
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                        .padding(.top, 8)
                    }
                    .padding()
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(8)

                    // Extraction Model (auto-download alongside chat model)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "wand.and.stars")
                                .foregroundColor(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Extraction Model (Qwen 3.5 4B)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text("Used by The Engineer to extract BPM, key, lyrics, and style from your conversation. Compact (2.9 GB) with strong instruction following.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()

                            if checkModelDownloaded("mlx-community/Qwen3.5-4B-4bit") || downloadManager.downloadedMLXModels.contains("mlx-community/Qwen3.5-4B-4bit") {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Ready")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            } else if downloadManager.downloadingMLXModel == "mlx-community/Qwen3.5-4B-4bit" {
                                VStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Downloading...")
                                        .font(.caption2)
                                }
                            } else {
                                Button(action: {
                                    downloadMLXModel("mlx-community/Qwen3.5-4B-4bit")
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.down.circle")
                                        Text("Download")
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(downloadManager.downloadingMLXModel != nil)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.purple.opacity(0.05))
                    .cornerRadius(8)
                }

                // Option 2: OpenRouter
                Button {
                    selectedLLMProvider = .openrouter
                } label: {
                    HStack {
                        Image(systemName: selectedLLMProvider == .openrouter ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedLLMProvider == .openrouter ? .blue : .gray)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("OpenRouter API")
                                .font(.headline)
                            Text("Cloud-based, requires API key (pay-per-use)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding()
                    .background(selectedLLMProvider == .openrouter ? Color.blue.opacity(0.1) : Color(.windowBackgroundColor))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                if selectedLLMProvider == .openrouter {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OpenRouter API Key")
                            .font(.subheadline)

                        TextField("sk-or-v1-...", text: $openRouterAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        Link("Get API Key from OpenRouter", destination: URL(string: "https://openrouter.ai/keys")!)
                            .font(.caption)
                    }
                    .padding()
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(8)
                }
            }
        }
    }

    // MARK: - Step 4: Connect Sterling

    private var sterlingStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("Connect the Studio Copilot")
                .font(.title2)
                .bold()

            Text("This endpoint powers Sterling inside the Studio tab (the DAW copilot dock). Point it at an OpenAI-compatible endpoint now, or skip this and set it up later from the copilot dock gear. Chat-tab conversations use the AI model from the previous step.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                Text("Point Sterling at any OpenAI-compatible endpoint. For the Unicorn Commander gateway, use the direct address, not the Cloudflare host, so long runs are not cut off at 120 seconds. The key is stored in your Keychain and is never sent to the model, only as the request's authorization.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Endpoint")
                        .font(.headline)
                    TextField("http://gateway.internal:4000/v1", text: $sterlingEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .disableAutocorrection(true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Model")
                        .font(.headline)
                    TextField("qwen3.6-35b", text: $sterlingModel)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .disableAutocorrection(true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key (Optional)")
                        .font(.headline)
                    SecureField(sterlingKeyPresent ? "Stored in Keychain (leave blank to keep)" : "Optional for local gateways", text: $sterlingAPIKey)
                        .textFieldStyle(.roundedBorder)
                    if sterlingKeyPresent {
                        Button("Remove stored key") {
                            SterlingKeychain.deleteKey()
                            sterlingKeyPresent = false
                            sterlingAPIKey = ""
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                    }
                }

                // Prove it here rather than at first use in the Studio tab. Same
                // probe the Settings pane runs: one real completion against the
                // endpoint above with the model above.
                HStack(spacing: 10) {
                    Button("Test connection") { testSterling() }
                        .disabled(sterlingProbing)
                    Spacer()
                }
                SterlingProbeResultView(probing: sterlingProbing, outcome: sterlingProbeOutcome)
            }
            .padding()
            .background(Color(.windowBackgroundColor))
            .cornerRadius(12)

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("Optional. You can connect Sterling later from the copilot dock gear.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Step 5: Complete

    private var completeStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("Setup Complete!")
                .font(.title)
                .bold()

            Text("You're all set up and ready to create music!")
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                CompletionRow(
                    icon: "checkmark.circle.fill",
                    title: "majiks.online Account",
                    detail: publisherStore.authState.isAuthenticated ? "Signed in" : "Not signed in — publish later after signing in",
                    color: publisherStore.authState.isAuthenticated ? .green : .blue
                )

                CompletionRow(
                    icon: "checkmark.circle.fill",
                    title: "ACE-Step Installed",
                    detail: aceStepDetected ? "Ready" : "Needs setup",
                    color: aceStepDetected ? .green : .orange
                )

                CompletionRow(
                    icon: "checkmark.circle.fill",
                    title: "LLM Configured",
                    detail: selectedLLMProvider == .mlxLocal ? "Local MLX" : "Cloud Provider",
                    color: .green
                )

                CompletionRow(
                    icon: "checkmark.circle.fill",
                    title: "Studio Copilot",
                    detail: SterlingConfig.isConfigured ? "Connected" : "Set up later",
                    color: SterlingConfig.isConfigured ? .green : .blue
                )
            }
            .padding()
            .background(Color(.windowBackgroundColor))
            .cornerRadius(12)

            Divider()

            VStack(spacing: 8) {
                Text("Next Steps:")
                    .font(.headline)

                Text("1. Click 'Start Creating' to begin\n2. Try the Chat tab to talk with Sterling\n3. Use the Studio tab to generate music\n4. Check Settings if you need to change anything")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if currentStep > 0 {
                Button("Back") {
                    withAnimation {
                        currentStep -= 1
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if currentStep < totalSteps {
                Button(nextButtonLabel) {
                    handleNext()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProceed)
            } else {
                Button("Start Creating Music!") {
                    applySettings()
                    onComplete?()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - Helper Views

    private struct FeatureRow: View {
        let icon: String
        let text: String

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                    .frame(width: 24)
                Text(text)
                Spacer()
            }
        }
    }

    private struct CompletionRow: View {
        let icon: String
        let title: String
        let detail: String
        let color: Color

        var body: some View {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Logic

    private var nextButtonLabel: String {
        if currentStep == 1 {
            // Account step — signing in is optional
            return publisherStore.authState.isAuthenticated ? "Next" : "Skip for Now"
        } else if currentStep == 2 && isInstallingACEStep {
            return "Installing..."
        } else if currentStep == 4 {
            // Connect Sterling is optional; label reflects whether anything was entered.
            let hasEntry = !sterlingEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
                || !sterlingModel.trimmingCharacters(in: .whitespaces).isEmpty
                || !sterlingAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
            return hasEntry ? "Save and Continue" : "Skip for Now"
        } else {
            return "Next"
        }
    }

    private var canProceed: Bool {
        switch currentStep {
        case 1: // Account step - can skip
            return true
        case 2: // ACE-Step - block while pip install is running
            return !isInstallingACEStep
        case 3: // LLM - always allowed
            return true
        case 4: // Connect Sterling - optional, can skip
            return true
        default:
            return true
        }
    }

    private func handleNext() {
        switch currentStep {
        case 4: // Connect Sterling: persist what was entered, then advance
            saveSterling()
            withAnimation {
                currentStep += 1
            }
        default:
            withAnimation {
                currentStep += 1
            }
        }
    }

    private func detectHardware() {
        // Get RAM
        systemRAM = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))

        // Get chip model
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", "machdep.cpu.brand_string"]

        let pipe = Pipe()
        process.standardOutput = pipe

        try? process.run()
        process.waitUntilExit()

        if let data = try? pipe.fileHandleForReading.readToEnd(),
           let output = String(data: data, encoding: .utf8) {
            chipModel = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var memoryForDefaultsGB: Int {
        systemRAM > 0 ? systemRAM : LMModel.physicalMemoryGB
    }

    private var recommendedLMModel: LMModel {
        LMModel.recommended(forPhysicalMemoryGB: memoryForDefaultsGB)
    }

    private var recommendedLMModelID: String {
        recommendedLMModel.rawValue
    }

    private func recommendedMLXModel() -> String {
        LLMProvider.defaultMLXModel(forPhysicalMemoryGB: memoryForDefaultsGB)
    }

    private func modelDisplayName(_ model: String) -> String {
        // Extract readable name from model path
        let name = model.replacingOccurrences(of: "mlx-community/", with: "")

        if name.contains("Qwen3.5-9B") {
            return "Qwen 3.5 9B (Best Chat)"
        } else if name.contains("Qwen3.5-4B") {
            return "Qwen 3.5 4B (Chat + Extraction)"
        } else if name.contains("Qwen3-30B-A3B") {
            return "Qwen3 30B A3B (Best Local)"
        } else if name.contains("Qwen3") {
            return "Qwen 3 Coder 30B (Best Quality)"
        } else if name.contains("granite-3.3") {
            return "Granite 3.3 8B (Balanced)"
        } else if name.contains("granite-4.0-h-micro") {
            return "Granite Micro (Fast & Light)"
        } else if name.contains("gpt-oss-20b") {
            return "GPT OSS 20B (Large)"
        } else if name.contains("Qwen2.5-7B") {
            return "Qwen 2.5 7B"
        } else if name.contains("GLM-4.7") {
            return "GLM 4.7 Flash"
        }

        return name
    }

    private func modelRAMRequirement(_ model: String) -> String {
        // Updated for 4-bit quantized models
        if model.contains("Qwen3.5-9B") {
            return "~6GB VRAM (4-bit) • 16GB+ RAM recommended"
        } else if model.contains("Qwen3.5-4B") {
            return "~2.9GB VRAM (4-bit) • 8GB+ RAM recommended"
        } else if model.contains("30B") {
            return "~17.5GB VRAM (4-bit) • 32GB+ RAM recommended"
        } else if model.contains("20b") {
            return "~12GB VRAM (4-bit) • 16GB+ RAM recommended"
        } else if model.contains("8b") || model.contains("7B") {
            return "~5GB VRAM (4-bit/8-bit) • 16GB+ RAM recommended"
        } else if model.contains("4.7") {
            return "~3GB VRAM (4-bit) • 8GB+ RAM recommended"
        } else if model.contains("micro") {
            return "~2GB VRAM (4-bit) • 8GB RAM minimum"
        }
        return "RAM requirement varies"
    }

    private func checkModelDownloaded(_ model: String) -> Bool {
        // Check if model exists in HF cache
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let hfCache = homeDir.appendingPathComponent(".cache/huggingface/hub")

        // Convert model name to cache format (e.g., "models--mlx-community--Qwen3-Coder-30B-A3B-Instruct-4bit")
        let cacheModelName = "models--" + model.replacingOccurrences(of: "/", with: "--")
        let modelPath = hfCache.appendingPathComponent(cacheModelName)

        return FileExistenceProbe.exists(atPath: modelPath.path)
    }

    private func checkForACEStep() {
        Task {
            let detected = llmSettings.autoDetectACEStep()
            aceStepDetected = detected
            if detected {
                aceStepPath = llmSettings.aceStepPath
                // Auto-load ACE models after detection
                loadACEModels()
            }
        }
    }

    private func loadACEModels() {
        Task {
            do {
                let models = try await backend.listAvailableModels()
                await MainActor.run {
                    availableACEModels = models
                    if !models.keys.contains(selectedACEModelID) {
                        selectedACEModelID = recommendedLMModelID
                    }
                }
            } catch {
                print("Failed to load ACE models: \(error.localizedDescription)")
            }
        }
    }

    private func downloadACEModel(modelId: String) {
        downloadManager.startACEDownload(modelId: modelId)

        Task {
            do {
                let result = try await backend.downloadModel(modelId: modelId)
                await MainActor.run {
                    print("[SetupWizard] Downloaded \(modelId): \(result)")
                    downloadManager.completeACEDownload(modelId: modelId, success: true)
                    // Reload to update installed status
                    loadACEModels()
                }
            } catch {
                await MainActor.run {
                    print("[SetupWizard] Download failed: \(error)")
                    downloadManager.completeACEDownload(modelId: modelId, success: false, error: error.localizedDescription)
                }
            }
        }
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

    private func installACEStepAutomatically() {
        isInstallingACEStep = true
        installationProgress = "Installing required packages..."

        Task {
            do {
                let result = try await backend.installAceStep()
                if result.success {
                    installationProgress = "Packages installed! Restarting backend..."

                    // Auto-restart the backend so new packages are available
                    await backend.restartForGeneration()

                    installationProgress = "Installation complete! Backend restarted."
                    checkForACEStep()
                    isInstallingACEStep = false
                } else {
                    installationProgress = "Installation failed: \(result.error ?? "Unknown error")"
                    isInstallingACEStep = false
                }
            } catch {
                installationProgress = "Installation error: \(error.localizedDescription)"
                isInstallingACEStep = false
            }
        }
    }

    private func saveSterling() {
        // Mirror SterlingSettingsView.save(): trim endpoint/model, store the key in
        // the Keychain only when one was entered. endpoint/model already persist via
        // @AppStorage to the shared "sterling.endpoint"/"sterling.model" keys.
        sterlingEndpoint = sterlingEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        sterlingModel = sterlingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = sterlingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            SterlingKeychain.setKey(key)
            sterlingKeyPresent = true
            sterlingAPIKey = ""
        }
    }

    /// Commit what was typed, then check it for real. Non-blocking: the wizard
    /// still advances, but a wrong endpoint/key/model says so HERE.
    private func testSterling() {
        guard !sterlingProbing else { return }
        saveSterling()
        sterlingProbing = true
        sterlingProbeOutcome = nil
        let endpoint = sterlingEndpoint
        let model = sterlingModel
        Task {
            let outcome = await SterlingConnectionProbe.run(
                endpoint: endpoint, model: model, key: SterlingKeychain.key())
            await MainActor.run {
                sterlingProbeOutcome = outcome
                sterlingProbing = false
            }
        }
    }

    private func applySettings() {
        // Apply LLM settings
        llmSettings.primaryProvider = selectedLLMProvider

        if selectedLLMProvider == .mlxLocal && !selectedMLXModel.isEmpty {
            llmSettings.mlxModel = selectedMLXModel
        }

        if selectedLLMProvider == .openrouter && !openRouterAPIKey.isEmpty {
            llmSettings.openrouterAPIKey = openRouterAPIKey
        }

        llmSettings.save()
    }
}
