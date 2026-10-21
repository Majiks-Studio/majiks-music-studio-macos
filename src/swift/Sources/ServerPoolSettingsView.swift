import SwiftUI

struct ServerPoolSettingsView: View {
    @EnvironmentObject var serverPool: ServerPoolManager
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @State private var showAddSheet = false
    @State private var editingServer: RemoteServer?
    @State private var isCheckingHealth = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Text("Server Pool")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Manage remote ACE-Step servers for distributed generation")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top)

                Divider()

                // Migration notice
                if !llmSettings.aceStepServerURL.isEmpty && !UserDefaults.standard.bool(forKey: "majik_server_pool_migrated") {
                    migrationNotice
                }

                // Routing strategy
                routingStrategySection

                Divider()

                // Server list
                serverListSection

                // Pool status
                if serverPool.hasServers {
                    poolStatusSection
                }
            }
            .padding()
        }
        .sheet(isPresented: $showAddSheet) {
            ServerEditSheet(server: nil) { name, url, apiKey, maxJobs, priority in
                serverPool.addServer(name: name, url: url, apiKey: apiKey)
                if var last = serverPool.servers.last {
                    last.maxConcurrentJobs = maxJobs
                    last.priority = priority
                    serverPool.updateServer(last)
                }
            }
        }
        .sheet(item: $editingServer) { server in
            ServerEditSheet(server: server) { name, url, apiKey, maxJobs, priority in
                var updated = server
                updated.name = name
                updated.url = url
                updated.apiKey = apiKey
                updated.maxConcurrentJobs = maxJobs
                updated.priority = priority
                serverPool.updateServer(updated)
            }
        }
    }

    // MARK: - Migration Notice

    private var migrationNotice: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundColor(.orange)
                Text("Legacy Server Detected")
                    .fontWeight(.medium)
                Spacer()
            }

            Text("You have a single remote server configured in the old format. Import it into the server pool to use multi-server features.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Import Legacy Server") {
                serverPool.migrateFromLegacySettings(
                    url: llmSettings.aceStepServerURL,
                    apiKey: llmSettings.aceStepServerAPIKey
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Routing Strategy

    private var routingStrategySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Routing Strategy")
                .font(.subheadline)
                .fontWeight(.medium)

            Picker("Strategy", selection: $serverPool.routingStrategy) {
                ForEach(RoutingStrategy.allCases) { strategy in
                    Text(strategy.displayName).tag(strategy)
                }
            }
            .pickerStyle(.segmented)

            Text(serverPool.routingStrategy.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Server List

    private var serverListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Servers")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Button(action: {
                    isCheckingHealth = true
                    Task {
                        await serverPool.checkAllHealth()
                        isCheckingHealth = false
                    }
                }) {
                    HStack(spacing: 4) {
                        if isCheckingHealth {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "heart.text.square")
                        }
                        Text("Check All")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(serverPool.servers.isEmpty || isCheckingHealth)

                Button(action: { showAddSheet = true }) {
                    Label("Add Server", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                // ACE Music Cloud uses different endpoints (/release_task, /query_result)
                // and has its own dedicated stream in GenerationQueue. Configure it in
                // LLM Settings > ACE Music Cloud, not here in the Server Pool.
            }

            if serverPool.servers.isEmpty {
                emptyState
            } else {
                ForEach(serverPool.servers) { server in
                    ServerRow(server: server, onEdit: {
                        editingServer = server
                    }, onRemove: {
                        serverPool.removeServer(id: server.id)
                    }, onToggle: { enabled in
                        var updated = server
                        updated.isEnabled = enabled
                        serverPool.updateServer(updated)
                    }, onCheckHealth: {
                        Task {
                            await serverPool.checkHealth(server: server)
                        }
                    })
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundColor(.secondary)

            Text("No servers configured")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Add a remote ACE-Step server for distributed generation, or use ACE Music's free cloud service.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button { showAddSheet = true } label: {
                    Label("Add Custom Server", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            Text("ACE Music Cloud uses a different API and has its own dedicated stream. Configure it in LLM Settings.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Get a free API key at acemusic.ai/playground/api-key")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Pool Status

    private var poolStatusSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar")
                .foregroundColor(.blue)
                .font(.caption)
            Text(serverPool.poolStatusSummary)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Server Row

private struct ServerRow: View {
    let server: RemoteServer
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onToggle: (Bool) -> Void
    let onCheckHealth: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Health status dot
            healthDot

            // Server info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .fontWeight(.medium)
                    if !server.isEnabled {
                        Text("Disabled")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(4)
                    }
                }

                Text(server.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Label("Max: \(server.maxConcurrentJobs)", systemImage: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Label("Priority: \(server.priority)", systemImage: "flag")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if server.activeJobCount > 0 {
                        Label("\(server.activeJobCount) active", systemImage: "bolt.fill")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }

                    if let avg = server.averageJobDuration {
                        Label(formatDuration(avg), systemImage: "clock")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Actions
            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            Button(action: onCheckHealth) {
                Image(systemName: "heart.text.square")
            }
            .buttonStyle(.borderless)
            .help("Check health")

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit server")

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove server")
        }
        .padding(12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    private var healthDot: some View {
        Circle()
            .fill(healthColor)
            .frame(width: 10, height: 10)
            .help(healthTooltip)
    }

    private var healthColor: Color {
        switch server.healthStatus {
        case .healthy: return .green
        case .unhealthy: return .red
        case .checking: return .yellow
        case .unknown: return .gray
        }
    }

    private var healthTooltip: String {
        switch server.healthStatus {
        case .healthy: return "Healthy"
        case .unhealthy: return "Unhealthy: \(server.lastError ?? "unknown error")"
        case .checking: return "Checking..."
        case .unknown: return "Not checked yet"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.0fs avg", seconds)
        } else {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m\(secs)s avg"
        }
    }
}

// MARK: - Server Edit Sheet

private struct ServerEditSheet: View {
    let server: RemoteServer?
    let onSave: (String, String, String, Int, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var apiKey: String = ""
    @State private var maxConcurrentJobs: Int = 2
    @State private var priority: Int = 1

    init(server: RemoteServer?, onSave: @escaping (String, String, String, Int, Int) -> Void) {
        self.server = server
        self.onSave = onSave
        if let s = server {
            _name = State(initialValue: s.name)
            _url = State(initialValue: s.url)
            _apiKey = State(initialValue: s.apiKey)
            _maxConcurrentJobs = State(initialValue: s.maxConcurrentJobs)
            _priority = State(initialValue: s.priority)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(server == nil ? "Add Server" : "Edit Server")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g. Studio GPU, Cloud A100", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("http://192.168.1.100:8001", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key (optional)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Bearer token", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Max Concurrent Jobs")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Stepper("\(maxConcurrentJobs)", value: $maxConcurrentJobs, in: 1...10)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Priority (1 = highest)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Stepper("\(priority)", value: $priority, in: 1...10)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(server == nil ? "Add" : "Save") {
                    onSave(
                        name.isEmpty ? "Server" : name,
                        url,
                        apiKey,
                        maxConcurrentJobs,
                        priority
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 450)
    }
}
