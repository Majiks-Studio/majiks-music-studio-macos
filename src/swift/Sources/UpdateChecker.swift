import Foundation
import SwiftUI
import AppKit

/// Version information from update server
struct VersionInfo: Codable {
    let version: String
    let build: String
    let releaseNotes: String
    let downloadURL: String
    let releaseDate: String
    let minimumVersion: String?
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var updateAvailable = false
    @Published var latestVersion: VersionInfo?
    @Published var lastChecked: Date?
    @Published var isChecking = false
    @Published var requiresMandatoryUpdate = false

    // Current app version
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    private var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
    var installedVersion: String { currentVersion }

    // Update server URL (customize for your deployment)
    private let updateURL = URL(string: "https://majiks.studio/api/version.json")!

    // User defaults keys
    private let lastCheckKey = "UpdateChecker.lastCheck"
    private let skipVersionKey = "UpdateChecker.skipVersion"
    static let autoCheckKey = "UpdateChecker.autoCheckOnStartup"

    /// Whether to automatically check for updates on startup (defaults to true)
    @Published var autoCheckOnStartup: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckOnStartup, forKey: Self.autoCheckKey)
        }
    }

    init() {
        if let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date {
            lastChecked = lastCheck
        }
        // Default to true if never set
        if UserDefaults.standard.object(forKey: Self.autoCheckKey) == nil {
            self.autoCheckOnStartup = true
        } else {
            self.autoCheckOnStartup = UserDefaults.standard.bool(forKey: Self.autoCheckKey)
        }
    }

    /// Check for updates automatically (respects user preferences)
    func checkForUpdatesIfNeeded() {
        // Respect user preference
        guard autoCheckOnStartup else {
            AppLog.debug("[UpdateChecker] Auto-check disabled by user preference")
            return
        }

        // Check at most once per 12 hours
        if let lastChecked = lastChecked,
           Date().timeIntervalSince(lastChecked) < 43200 {
            AppLog.debug("[UpdateChecker] Skipping — last checked \(String(format: "%.0f", Date().timeIntervalSince(lastChecked)/3600))h ago (12h cooldown)")
            return
        }

        AppLog.debug("[UpdateChecker] Starting automatic update check")
        Task {
            await checkForUpdates(silent: true)
        }
    }

    /// Manually check for updates (always shows result)
    func checkForUpdates(silent: Bool = false) async {
        guard !isChecking else {
            print("[UpdateChecker] Check already in progress, skipping duplicate request")
            return
        }

        isChecking = true
        defer { isChecking = false }

        AppLog.debug("[UpdateChecker] Fetching \(updateURL.absoluteString)")

        do {
            let (data, response) = try await URLSession.shared.data(from: updateURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLog.error("[UpdateChecker] Server returned HTTP \(code)")
                return
            }

            let versionInfo = try JSONDecoder().decode(VersionInfo.self, from: data)
            AppLog.debug("[UpdateChecker] Remote version: \(versionInfo.version), local: \(currentVersion)")

            // Update state
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: lastCheckKey)

            // Minimum required version enforces a non-dismissable update flow.
            if isBelowMinimumVersion(versionInfo.minimumVersion) {
                latestVersion = versionInfo
                updateAvailable = true
                requiresMandatoryUpdate = true
                return
            }
            requiresMandatoryUpdate = false

            // Check if update is available
            if isNewerVersion(versionInfo.version) {
                // Check if user skipped this version
                let skippedVersion = UserDefaults.standard.string(forKey: skipVersionKey)
                if skippedVersion != versionInfo.version {
                    latestVersion = versionInfo
                    updateAvailable = true
                    AppLog.debug("[UpdateChecker] Update available: \(versionInfo.version)")
                } else {
                    AppLog.debug("[UpdateChecker] Version \(versionInfo.version) skipped by user")
                }
            } else {
                latestVersion = nil
                updateAvailable = false
                AppLog.debug("[UpdateChecker] App is up to date")
            }

        } catch {
            AppLog.error("[UpdateChecker] Failed: \(error.localizedDescription)")
        }
    }

    /// Skip this version (don't notify again)
    func skipVersion() {
        guard !requiresMandatoryUpdate else {
            print("[UpdateChecker] Cannot skip a mandatory update")
            return
        }
        if let version = latestVersion?.version {
            UserDefaults.standard.set(version, forKey: skipVersionKey)
        }
        updateAvailable = false
        latestVersion = nil
    }

    /// Allowed download hosts — only open URLs from these domains
    private static let allowedDownloadHosts: Set<String> = [
        "f005.backblazeb2.com",
        "dl.majiks.studio",
        "majiks.studio",
        "github.com"
    ]

    /// Download and install update
    func downloadUpdate() {
        guard let urlString = latestVersion?.downloadURL else {
            print("[UpdateChecker] Download failed: no latest version or download URL available")
            return
        }
        guard let url = URL(string: urlString) else {
            print("[UpdateChecker] Download failed: invalid URL '\(urlString)'")
            return
        }
        guard let host = url.host, Self.allowedDownloadHosts.contains(host) else {
            print("[UpdateChecker] Download blocked: host '\(url.host ?? "nil")' not in allowlist")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Version Comparison

    private func isNewerVersion(_ newVersion: String) -> Bool {
        compareVersions(currentVersion, newVersion) == .orderedAscending
    }

    private func isBelowMinimumVersion(_ minimumVersion: String?) -> Bool {
        guard let minimumVersion, !minimumVersion.isEmpty else { return false }
        return compareVersions(currentVersion, minimumVersion) == .orderedAscending
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        let count = max(left.count, right.count)
        for i in 0..<count {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private func versionComponents(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .compactMap { Int($0) }
    }
}

// MARK: - Update Notification View

struct UpdateNotificationView: View {
    @ObservedObject var updateChecker: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)

                Text("Update Available")
                    .font(.title2)
                    .fontWeight(.bold)

                if updateChecker.requiresMandatoryUpdate {
                    Text("A required update must be installed to continue using this app.")
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                if let version = updateChecker.latestVersion {
                    Text("Version \(version.version)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Release notes
            if let version = updateChecker.latestVersion {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What's New:")
                        .font(.headline)

                    ScrollView {
                        Text(version.releaseNotes)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                }
            }

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                if updateChecker.requiresMandatoryUpdate {
                    Button("Quit App") {
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Skip This Version") {
                        updateChecker.skipVersion()
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button("Remind Me Later") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }

                Button(updateChecker.requiresMandatoryUpdate ? "Download Required Update" : "Download Update") {
                    updateChecker.downloadUpdate()
                    if !updateChecker.requiresMandatoryUpdate {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 450)
        .interactiveDismissDisabled(updateChecker.requiresMandatoryUpdate)
    }
}

// MARK: - Settings Integration

struct UpdateSettingsView: View {
    @ObservedObject var updateChecker: UpdateChecker

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(.secondary)
                    Text("Software Updates")
                        .font(.headline)
                    Spacer()
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Version: \(updateChecker.installedVersion)")
                            .font(.body)

                        if let lastChecked = updateChecker.lastChecked {
                            Text("Last checked: \(lastChecked, style: .relative) ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Never checked for updates")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Check Now") {
                            Task {
                                await updateChecker.checkForUpdates(silent: false)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Toggle("Check for updates on startup", isOn: $updateChecker.autoCheckOnStartup)
                    .font(.body)

                if updateChecker.updateAvailable,
                   let version = updateChecker.latestVersion {
                    Divider()

                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.blue)
                        Text("Version \(version.version) is available!")
                            .font(.body)
                            .foregroundColor(.blue)
                        Spacer()
                        Button("Download") {
                            updateChecker.downloadUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .padding(8)
        }
    }
}
