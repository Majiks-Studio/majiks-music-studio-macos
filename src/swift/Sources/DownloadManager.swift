import SwiftUI

/// Global download manager to track model downloads across all screens
@MainActor
class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    // ACE-Step model downloads
    @Published var downloadingACEModel: String?
    @Published var aceDownloadProgress: String?
    @Published var aceDownloadError: String?
    /// Which ACE models finished downloading THIS session.
    ///
    /// Write-only and staying that way, deliberately: nothing reads it, and the
    /// reason nothing can is that `checkExistingDownloads` only ever populates
    /// the MLX set, so this one would answer "no" for a model already sitting
    /// on disk from last week. Wiring a view to it would put a WRONG answer on
    /// screen, which is worse than the current nothing. Removing it is the
    /// other honest option and is not this lane's call — `downloadedDiTModels`
    /// next to it IS read (ManageModelsView, LLMSettingsView) off the same
    /// half-populated init, so the fix is one scan that covers all three
    /// caches, not three deletions.
    @Published var downloadedACEModels: Set<String> = []

    // DiT model downloads
    @Published var downloadingDiTModel: String?
    @Published var ditDownloadProgress: String?
    @Published var ditDownloadError: String?
    @Published var downloadedDiTModels: Set<String> = []

    // MLX model downloads
    @Published var downloadingMLXModel: String?
    @Published var mlxDownloadProgress: String?
    @Published var mlxDownloadError: String?
    @Published var downloadedMLXModels: Set<String> = []

    private init() {
        // Check what's already downloaded on init
        checkExistingDownloads()
    }

    var isDownloading: Bool {
        downloadingACEModel != nil || downloadingDiTModel != nil || downloadingMLXModel != nil
    }

    var currentDownloadStatus: String? {
        if let aceProgress = aceDownloadProgress {
            return aceProgress
        }
        if let mlxProgress = mlxDownloadProgress {
            return mlxProgress
        }
        return nil
    }

    func startACEDownload(modelId: String) {
        downloadingACEModel = modelId
        aceDownloadProgress = "Starting download..."
        aceDownloadError = nil
    }

    func updateACEProgress(_ progress: String) {
        aceDownloadProgress = progress
    }

    func completeACEDownload(modelId: String, success: Bool, error: String? = nil) {
        if success {
            downloadedACEModels.insert(modelId)
            aceDownloadProgress = "✅ \(modelId) downloaded successfully!"
        } else {
            aceDownloadError = error
            // WHY it failed, not just THAT it failed. This line used to read a
            // bare "❌ Download failed" with `error` dropped on the floor, while
            // the DiT and MLX paths eleven lines apart both interpolate it. A
            // user whose download died on a disk-full or a 403 was shown the
            // one sentence that could not help them, and the sentence that
            // could was three lines away in the same function.
            aceDownloadProgress = "❌ Download failed: \(error ?? "Unknown error")"
        }
        downloadingACEModel = nil

        // Clear messages after delay
        Task {
            try? await Task.sleep(for: .seconds(3))
            if aceDownloadProgress?.contains("✅") == true || aceDownloadProgress?.contains("❌") == true {
                aceDownloadProgress = nil
                aceDownloadError = nil
            }
        }
    }

    func startDiTDownload(modelId: String) {
        downloadingDiTModel = modelId
        ditDownloadProgress = "Starting download..."
        ditDownloadError = nil
    }

    func updateDiTProgress(_ progress: String) {
        ditDownloadProgress = progress
    }

    func completeDiTDownload(modelId: String, success: Bool, error: String? = nil) {
        if success {
            downloadedDiTModels.insert(modelId)
            ditDownloadProgress = "\(modelId) downloaded successfully!"
        } else {
            ditDownloadError = error
            ditDownloadProgress = "Download failed: \(error ?? "Unknown error")"
        }
        downloadingDiTModel = nil

        // Clear messages after delay
        Task {
            try? await Task.sleep(for: .seconds(5))
            if ditDownloadProgress != nil {
                ditDownloadProgress = nil
                ditDownloadError = nil
            }
        }
    }

    func startMLXDownload(model: String) {
        downloadingMLXModel = model
        mlxDownloadProgress = "Downloading \(modelDisplayName(model))..."
        mlxDownloadError = nil
    }

    func updateMLXProgress(_ progress: String) {
        mlxDownloadProgress = progress
    }

    func completeMLXDownload(model: String, success: Bool, error: String? = nil) {
        if success {
            downloadedMLXModels.insert(model)
            mlxDownloadProgress = "✅ \(modelDisplayName(model)) downloaded successfully!"
        } else {
            mlxDownloadError = error
            mlxDownloadProgress = "❌ Download failed: \(error ?? "Unknown error")"
        }
        downloadingMLXModel = nil

        // Clear messages after delay
        Task {
            try? await Task.sleep(for: .seconds(3))
            if mlxDownloadProgress?.contains("✅") == true || mlxDownloadProgress?.contains("❌") == true {
                mlxDownloadProgress = nil
                mlxDownloadError = nil
            }
        }
    }

    private func checkExistingDownloads() {
        // Check MLX models in HuggingFace cache
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")

        for model in LLMProvider.mlxLocal.models {
            let modelPath = model.replacingOccurrences(of: "/", with: "--")
            let modelDir = cacheDir.appendingPathComponent("models--\(modelPath)")
            if FileManager.default.fileExists(atPath: modelDir.path) {
                downloadedMLXModels.insert(model)
            }
        }
    }

    private func modelDisplayName(_ model: String) -> String {
        let name = model.replacingOccurrences(of: "mlx-community/", with: "")
        if name.contains("gpt-oss-20b") {
            return "GPT OSS 20B"
        } else if name.contains("granite-3.3-8b") {
            return "Granite 3.3 8B"
        } else if name.contains("granite-4.0-h-micro") {
            return "Granite 4.0 Micro"
        } else if name.contains("GLM-4.7") {
            return "GLM 4.7 Flash"
        }
        return name
    }
}
