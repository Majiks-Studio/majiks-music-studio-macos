import SwiftUI

/// Settings pane to view, download, and remove the models the app uses:
/// the ACE-Step generation models and the htdemucs stem separation model.
/// Wires to the real `DownloadManager.shared` and `GenerationModelStore`; it
/// does not implement its own download stack.
struct ManageModelsView: View {
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @EnvironmentObject var downloadManager: DownloadManager

    // Installed state, refreshed on appear and after each download/remove.
    @State private var genInstalled: [String: Bool] = [:]
    @State private var genSizes: [String: Int64] = [:]
    @State private var stemInstalled = false
    @State private var stemSize: Int64 = 0
    @State private var stemFileCount = 0
    @State private var loaded = false

    // Scan lifecycle. The installed-size walk is multi-gigabyte and now runs
    // off the main thread; `isScanning` guards against stacking overlapping
    // walks, and `scanToken` lets a newer scan supersede a slower older one so
    // a stale result can never overwrite fresh numbers.
    @State private var isScanning = false
    @State private var scanToken = 0

    // Remove confirmation flow.
    @State private var pendingGenRemove: LLMSettingsView.DiTModelInfo?
    @State private var showGenRemoveConfirm = false
    @State private var showStemRemoveConfirm = false

    // Result banner for the last action.
    @State private var actionMessage: String?
    @State private var actionIsError = false

    private var totalManagedBytes: Int64 {
        genSizes.values.reduce(0, +) + stemSize
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if let message = actionMessage {
                    resultBanner(message)
                }

                Divider()

                if loaded {
                    generationSection

                    Divider()

                    stemSection
                } else {
                    calculatingPlaceholder
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refresh() }
        .alert("Remove this model?", isPresented: $showGenRemoveConfirm, presenting: pendingGenRemove) { model in
            Button("Cancel", role: .cancel) { pendingGenRemove = nil }
            Button("Remove", role: .destructive) {
                performGenRemove(model)
                pendingGenRemove = nil
            }
        } message: { model in
            let path = GenerationModelStore.installedModelDir(id: model.id, aceStepPath: llmSettings.aceStepPath)?.path ?? "the model directory"
            let size = GenerationModelStore.formatBytes(genSizes[model.id] ?? 0)
            Text("This deletes the weights for \(model.displayName) from:\n\n\(path)\n\nThis reclaims about \(size). You can download the model again later.")
        }
        .alert("Remove stem model weights?", isPresented: $showStemRemoveConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { performStemRemove() }
        } message: {
            Text("This deletes \(stemFileCount) cached demucs weight file(s) (\(GenerationModelStore.formatBytes(stemSize))) from:\n\n\(GenerationModelStore.stemCheckpointsDir().path)\n\nThe stem model downloads again automatically the next time you separate stems.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Text("Models")
                .font(.title2)
                .fontWeight(.semibold)

            Text("View, download, and remove the models used for music generation and stem separation.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if loaded {
                Text("Using \(GenerationModelStore.formatBytes(totalManagedBytes)) on disk")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top)
    }

    private func resultBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: actionIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(actionIsError ? .red : .green)
            Text(message)
                .font(.caption)
                .foregroundColor(actionIsError ? .red : .primary)
            Spacer()
        }
        .padding(10)
        .background((actionIsError ? Color.red : Color.green).opacity(0.1))
        .cornerRadius(6)
    }

    /// Lightweight stand-in shown while the installed-size walk runs in the
    /// background, so the tab renders instantly and the Settings window stays
    /// responsive instead of freezing until the filesystem walk finishes.
    private var calculatingPlaceholder: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Calculating installed sizes…")
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Generation models

    private var generationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Generation Models (ACE-Step)")
                    .font(.headline)
                Spacer()
                Button {
                    refresh(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh install status")
            }

            Text("Diffusion Transformer models for music generation. Turbo is included with the initial ACE-Step install; the others are optional.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let progress = downloadManager.ditDownloadProgress {
                HStack(spacing: 8) {
                    if downloadManager.downloadingDiTModel != nil {
                        ProgressView().controlSize(.small)
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
                notInstalledCard
            } else {
                VStack(spacing: 8) {
                    ForEach(LLMSettingsView.ditModels) { model in
                        genModelRow(model)
                    }
                }
            }
        }
    }

    private var notInstalledCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text("ACE-Step is not installed. Install it from the LLM and Models tab to download generation models.")
                .font(.caption)
                .foregroundColor(.orange)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
    }

    private func genModelRow(_ model: LLMSettingsView.DiTModelInfo) -> some View {
        let installed = genInstalled[model.id] ?? false
        let downloading = downloadManager.downloadingDiTModel == model.id
        let anyDownloading = downloadManager.downloadingDiTModel != nil
        let dir = GenerationModelStore.installedModelDir(id: model.id, aceStepPath: llmSettings.aceStepPath)

        return HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(installed ? Color.green : (downloading ? Color.yellow : Color.gray.opacity(0.4)))
                .frame(width: 10, height: 10)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
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
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Label(model.sizeEstimate.replacingOccurrences(of: "~", with: "about "), systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if installed, let bytes = genSizes[model.id], bytes > 0 {
                        Text("On disk: \(GenerationModelStore.formatBytes(bytes))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if installed, let dir {
                    locationRow(dir)
                }
            }

            Spacer()

            genActionColumn(model: model, installed: installed, downloading: downloading, anyDownloading: anyDownloading)
        }
        .padding(10)
        .background(installed ? Color.green.opacity(0.04) : Color.gray.opacity(0.04))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func genActionColumn(model: LLMSettingsView.DiTModelInfo, installed: Bool, downloading: Bool, anyDownloading: Bool) -> some View {
        if downloading {
            VStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Downloading...")
                    .font(.caption2)
                    .foregroundColor(.blue)
            }
        } else if installed {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Installed").font(.caption).foregroundColor(.green)
                }
                Button(role: .destructive) {
                    pendingGenRemove = model
                    showGenRemoveConfirm = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(anyDownloading)
            }
        } else {
            Button("Download") {
                actionMessage = nil
                GenerationModelStore.download(
                    model: model,
                    aceStepPath: llmSettings.aceStepPath
                ) {
                    refresh(force: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(anyDownloading)
        }
    }

    // MARK: - Stem model

    /// What the separation model is for, and WHERE TO START ONE.
    ///
    /// ⚠️ THIS SENTENCE IS TESTED AGAINST THE APP, and it is a constant rather
    /// than a literal in the body so that it can be. What was here before read:
    ///
    ///   "The htdemucs model splits a track into vocals, drums, bass, and other
    ///    parts. It is used by the Stems tab."
    ///
    /// The second sentence was false. The Stems tab could not separate
    /// anything — its own empty state told you to go and do it in another tab —
    /// and this page was the only place in the product that said otherwise, so
    /// it read as a confirmation to somebody who had just failed to find the
    /// feature. Same family as the Files pane help that promised drag-and-drop
    /// for rows carrying no gesture.
    ///
    /// `StemSeparationClaimTests` takes every tab name this string mentions,
    /// looks it up in `StemSeparationWiringTests.entryPoints`, and fails unless
    /// that file really calls something that separates. Put the old sentence
    /// back with the Stems button removed and the test fails naming "Stems".
    static let stemModelBlurb =
        "The htdemucs model splits a song into four parts you can hear on their own: "
        + "vocals, drums, bass, and everything else. Start one from the Stems tab "
        + "(Split into Stems), from a song's ••• menu in the Library, or from the "
        + "Track menu in the Studio. It downloads itself the first time you split a "
        + "song, so there is nothing to install here."

    private var stemSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Stem Separation Model")
                    .font(.headline)
                Spacer()
                Button {
                    refresh(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh install status")
            }

            Text(Self.stemModelBlurb)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            stemRow
        }
    }

    private var stemRow: some View {
        let dir = GenerationModelStore.stemCheckpointsDir()

        return HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(stemInstalled ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 10, height: 10)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                Text("htdemucs")
                    .font(.body)
                    .fontWeight(.medium)
                Text("Four-part stem separation (vocals, drums, bass, other).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Label("about 80 MB", systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if stemInstalled, stemSize > 0 {
                        Text("On disk: \(GenerationModelStore.formatBytes(stemSize)) across \(stemFileCount) file(s)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if !stemInstalled {
                    Text("Not installed. Downloads automatically the first time you separate stems.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                locationRow(dir)
            }

            Spacer()

            if stemInstalled {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("Installed").font(.caption).foregroundColor(.green)
                    }
                    Button(role: .destructive) {
                        showStemRemoveConfirm = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Text("Auto")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15))
                    .foregroundColor(.secondary)
                    .cornerRadius(4)
            }
        }
        .padding(10)
        .background(stemInstalled ? Color.green.opacity(0.04) : Color.gray.opacity(0.04))
        .cornerRadius(8)
    }

    // MARK: - Shared row pieces

    private func locationRow(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(url.path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("Reveal") {
                revealInFinder(url)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption2)
        }
        .padding(.top, 2)
    }

    // MARK: - Actions

    /// Refresh installed status and on-disk sizes.
    ///
    /// The heavy work here is `GenerationModelStore.directorySize(at:)`, which
    /// recursively walks each generation model's directory (multi-gigabyte,
    /// many files) plus the demucs stem weights. That walk used to run
    /// synchronously in `.onAppear`, freezing the ENTIRE Settings window — no
    /// tab was clickable — until it finished. It now runs off the main thread
    /// and publishes back on the main actor, so the tab renders immediately.
    ///
    /// Results are cached per ACE-Step path so re-opening the Models tab (a
    /// fresh `ManageModelsView`, since `SettingsView` switches on the tab id)
    /// is instant. `force` — an explicit refresh, or a download/remove —
    /// invalidates the cache and rescans.
    private func refresh(force: Bool = false) {
        let acePath = llmSettings.aceStepPath
        let modelIDs = LLMSettingsView.ditModels.map(\.id)

        if force {
            ModelScanCache.shared.invalidate()
        } else if let cached = ModelScanCache.shared.snapshot(forACEStepPath: acePath) {
            // Instant path: reuse the last scan for this location.
            apply(cached)
            return
        } else if isScanning {
            // A scan is already in flight; let it publish rather than stacking
            // a second filesystem walk.
            return
        }

        // Render immediately with a placeholder, then compute sizes in the
        // background and publish the result on the main actor.
        loaded = false
        isScanning = true
        scanToken &+= 1
        let token = scanToken

        Task.detached(priority: .userInitiated) {
            let snapshot = Self.scanInstalledModels(modelIDs: modelIDs, aceStepPath: acePath)
            await MainActor.run {
                // Drop a superseded (slower, older) scan so it can't overwrite
                // fresher numbers or a fresher cache entry.
                guard token == scanToken else { return }
                ModelScanCache.shared.store(snapshot, forACEStepPath: acePath)
                apply(snapshot)
                isScanning = false
            }
        }
    }

    /// Publish a scan snapshot into the view's state. Main actor only.
    private func apply(_ snapshot: ScanSnapshot) {
        genInstalled = snapshot.genInstalled
        genSizes = snapshot.genSizes
        stemInstalled = snapshot.stemInstalled
        stemSize = snapshot.stemSize
        stemFileCount = snapshot.stemFileCount
        loaded = true
    }

    /// The heavy filesystem scan, run OFF the main actor (`nonisolated`, from a
    /// detached task). Resolves each model directory and recursively sums its
    /// size, plus the demucs stem weights. Touches only
    /// `GenerationModelStore`'s non-isolated `FileManager` helpers, so it is
    /// safe to run on a background executor.
    private nonisolated static func scanInstalledModels(modelIDs: [String], aceStepPath: String) -> ScanSnapshot {
        var installed: [String: Bool] = [:]
        var sizes: [String: Int64] = [:]
        for id in modelIDs {
            if let dir = GenerationModelStore.installedModelDir(id: id, aceStepPath: aceStepPath) {
                installed[id] = true
                sizes[id] = GenerationModelStore.directorySize(at: dir)
            } else {
                installed[id] = false
                sizes[id] = 0
            }
        }

        let stemFiles = GenerationModelStore.stemWeightFiles()
        return ScanSnapshot(
            genInstalled: installed,
            genSizes: sizes,
            stemInstalled: !stemFiles.isEmpty,
            stemSize: stemFiles.reduce(0) { $0 + $1.size },
            stemFileCount: stemFiles.count
        )
    }

    private func performGenRemove(_ model: LLMSettingsView.DiTModelInfo) {
        do {
            let freed = try GenerationModelStore.removeGenerationModel(id: model.id, aceStepPath: llmSettings.aceStepPath)
            downloadManager.downloadedDiTModels.remove(model.id)
            actionIsError = false
            actionMessage = "Removed \(model.displayName). Reclaimed \(GenerationModelStore.formatBytes(freed))."
        } catch {
            actionIsError = true
            actionMessage = error.localizedDescription
        }
        refresh(force: true)
    }

    private func performStemRemove() {
        do {
            let freed = try GenerationModelStore.removeStemWeights()
            actionIsError = false
            actionMessage = "Removed stem model weights. Reclaimed \(GenerationModelStore.formatBytes(freed))."
        } catch {
            actionIsError = true
            actionMessage = error.localizedDescription
        }
        refresh(force: true)
    }

    private func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Open the closest existing parent so the button is never a dead end.
            var parent = url.deletingLastPathComponent()
            let fm = FileManager.default
            while parent.path != "/" && !fm.fileExists(atPath: parent.path) {
                parent = parent.deletingLastPathComponent()
            }
            NSWorkspace.shared.open(parent)
        }
    }
}

// MARK: - Scan result + cross-instance cache

/// Immutable result of one installed-model scan. Sendable so it can be handed
/// back from the background scan task to the main actor.
fileprivate struct ScanSnapshot: Sendable {
    var genInstalled: [String: Bool]
    var genSizes: [String: Int64]
    var stemInstalled: Bool
    var stemSize: Int64
    var stemFileCount: Int
}

/// Caches the last installed-model scan across `ManageModelsView` instances.
///
/// The Settings window rebuilds `ManageModelsView` from scratch every time the
/// Models tab is selected (`SettingsView` switches on the tab id, so the view
/// has no identity across visits and its `@State` resets). Without this cache
/// the app re-walked multi-gigabyte model directories on every appearance. The
/// snapshot is keyed by the ACE-Step path it was measured for and is cleared
/// by `refresh(force:)` — an explicit refresh, or after a download/remove.
@MainActor
fileprivate final class ModelScanCache {
    static let shared = ModelScanCache()
    private init() {}

    private var cachedKey: String?
    private var cached: ScanSnapshot?

    func snapshot(forACEStepPath path: String) -> ScanSnapshot? {
        cachedKey == path ? cached : nil
    }

    func store(_ snapshot: ScanSnapshot, forACEStepPath path: String) {
        cachedKey = path
        cached = snapshot
    }

    func invalidate() {
        cachedKey = nil
        cached = nil
    }
}
