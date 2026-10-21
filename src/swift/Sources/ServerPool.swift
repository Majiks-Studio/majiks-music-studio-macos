import Foundation

// MARK: - Server Health Status

enum ServerHealthStatus: String, Codable, Sendable {
    case unknown
    case healthy
    case unhealthy
    case checking
}

// MARK: - Remote Server

struct RemoteServer: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var url: String
    var apiKey: String
    var isEnabled: Bool
    var maxConcurrentJobs: Int
    var priority: Int

    // Runtime state (not persisted via CodingKeys)
    var healthStatus: ServerHealthStatus = .unknown
    var activeJobCount: Int = 0
    var lastHealthCheck: Date?
    var lastError: String?
    var averageJobDuration: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case id, name, url, apiKey, isEnabled, maxConcurrentJobs, priority
    }

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        apiKey: String = "",
        isEnabled: Bool = true,
        maxConcurrentJobs: Int = 2,
        priority: Int = 1
    ) {
        self.id = id
        self.name = name
        self.url = url.hasSuffix("/") ? String(url.dropLast()) : url
        self.apiKey = apiKey
        self.isEnabled = isEnabled
        self.maxConcurrentJobs = maxConcurrentJobs
        self.priority = priority
    }

    /// Whether this server has capacity for another job
    var hasCapacity: Bool {
        isEnabled && activeJobCount < maxConcurrentJobs && healthStatus != .unhealthy
    }
}

// MARK: - Routing Strategy

enum RoutingStrategy: String, CaseIterable, Codable, Identifiable, Sendable {
    case roundRobin = "round-robin"
    case leastLoaded = "least-loaded"
    case priority = "priority"
    case manual = "manual"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .roundRobin: return "Round Robin"
        case .leastLoaded: return "Least Loaded"
        case .priority: return "Priority"
        case .manual: return "Manual"
        }
    }

    var description: String {
        switch self {
        case .roundRobin: return "Cycle through enabled servers evenly"
        case .leastLoaded: return "Pick the server with fewest active jobs"
        case .priority: return "Use highest-priority server with capacity"
        case .manual: return "Choose which server to use per job"
        }
    }

    var systemImage: String {
        switch self {
        case .roundRobin: return "arrow.triangle.2.circlepath"
        case .leastLoaded: return "scalemass"
        case .priority: return "flag"
        case .manual: return "hand.tap"
        }
    }
}

// MARK: - Server Pool Manager

@MainActor
final class ServerPoolManager: ObservableObject {
    @Published var servers: [RemoteServer] = []
    @Published var routingStrategy: RoutingStrategy = .leastLoaded

    private let poolKey = "majik_server_pool"
    private let strategyKey = "majik_routing_strategy"
    private let migratedKey = "majik_server_pool_migrated"
    private let keychainService = "com.majik.musicstudio.serverpool"

    /// Round-robin index, not persisted
    private var roundRobinIndex: Int = 0

    /// Tracks job durations for averaging
    private var jobDurations: [UUID: [TimeInterval]] = [:]

    init() {
        loadFromDefaults()
    }

    // MARK: - Persistence

    private func loadFromDefaults() {
        if let data = UserDefaults.standard.data(forKey: poolKey),
           let decoded = try? JSONDecoder().decode([RemoteServer].self, from: data) {
            servers = decoded
            // Load API keys from Keychain for each server
            for i in servers.indices {
                let account = "server_pool_\(servers[i].id.uuidString)"
                if let key = try? KeychainStore.get(account: account, service: keychainService),
                   !key.isEmpty {
                    servers[i].apiKey = key
                }
            }
        }

        if let strategyStr = UserDefaults.standard.string(forKey: strategyKey),
           let strategy = RoutingStrategy(rawValue: strategyStr) {
            routingStrategy = strategy
        }
    }

    private func saveToDefaults() {
        // Zero out API keys before saving to UserDefaults (they go to Keychain)
        var serversForStorage = servers
        for i in serversForStorage.indices {
            serversForStorage[i].apiKey = ""
        }

        if let data = try? JSONEncoder().encode(serversForStorage) {
            UserDefaults.standard.set(data, forKey: poolKey)
        }

        // Save API keys to Keychain
        for server in servers {
            let account = "server_pool_\(server.id.uuidString)"
            try? KeychainStore.set(server.apiKey, account: account, service: keychainService)
        }

        UserDefaults.standard.set(routingStrategy.rawValue, forKey: strategyKey)
    }

    // MARK: - CRUD

    @discardableResult
    func addServer(name: String, url: String, apiKey: String = "") -> RemoteServer {
        let server = RemoteServer(name: name, url: url, apiKey: apiKey)
        servers.append(server)
        saveToDefaults()
        AppLog.info("Server pool: added '\(name)' at \(url)")
        return server
    }

    func removeServer(id: UUID) {
        // Clean up Keychain entry
        let account = "server_pool_\(id.uuidString)"
        try? KeychainStore.set("", account: account, service: keychainService)

        servers.removeAll { $0.id == id }
        jobDurations.removeValue(forKey: id)
        saveToDefaults()
        AppLog.info("Server pool: removed server \(id)")
    }

    func updateServer(_ server: RemoteServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        saveToDefaults()
    }

    // MARK: - Routing

    /// Pick the next server based on the current routing strategy.
    /// Returns nil if no suitable server is available.
    func nextServer(excluding: Set<UUID> = []) -> RemoteServer? {
        let candidates = enabledServers.filter { !excluding.contains($0.id) && $0.hasCapacity }
        guard !candidates.isEmpty else { return nil }

        switch routingStrategy {
        case .roundRobin:
            let server = candidates[roundRobinIndex % candidates.count]
            roundRobinIndex += 1
            return server

        case .leastLoaded:
            return candidates.min(by: { a, b in
                let aRatio = Double(a.activeJobCount) / Double(max(a.maxConcurrentJobs, 1))
                let bRatio = Double(b.activeJobCount) / Double(max(b.maxConcurrentJobs, 1))
                return aRatio < bRatio
            })

        case .priority:
            // Lower priority number = higher priority
            return candidates.min(by: { $0.priority < $1.priority })

        case .manual:
            // In manual mode, caller should use serverFor(jobId:) instead
            // Fall back to first available
            return candidates.first
        }
    }

    /// For manual routing: get the server the user picked for a specific job.
    /// This returns the server at the given index in the enabled list, for UI binding.
    func server(byId serverId: UUID) -> RemoteServer? {
        servers.first { $0.id == serverId }
    }

    // MARK: - Health Checks

    func checkHealth(server: RemoteServer) async {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index].healthStatus = .checking

        let urlString = "\(server.url)/health"
        guard let url = URL(string: urlString) else {
            servers[index].healthStatus = .unhealthy
            servers[index].lastError = "Invalid URL"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !server.apiKey.isEmpty {
            request.setValue("Bearer \(server.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                await updateHealthStatus(serverId: server.id, status: .unhealthy, error: "Not an HTTP response")
                return
            }

            if (200...299).contains(httpResponse.statusCode) {
                await updateHealthStatus(serverId: server.id, status: .healthy, error: nil)
            } else {
                await updateHealthStatus(serverId: server.id, status: .unhealthy, error: "HTTP \(httpResponse.statusCode)")
            }
        } catch {
            await updateHealthStatus(serverId: server.id, status: .unhealthy, error: error.localizedDescription)
        }
    }

    func checkAllHealth() async {
        let serversToCheck = servers
        await withTaskGroup(of: Void.self) { group in
            for server in serversToCheck {
                group.addTask { [weak self] in
                    await self?.checkHealth(server: server)
                }
            }
        }
    }

    private func updateHealthStatus(serverId: UUID, status: ServerHealthStatus, error: String?) async {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        servers[index].healthStatus = status
        servers[index].lastHealthCheck = Date()
        servers[index].lastError = error
    }

    // MARK: - Job Tracking

    func markJobStarted(serverId: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        servers[index].activeJobCount += 1
    }

    func recordJobCompletion(serverId: UUID, duration: TimeInterval) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        servers[index].activeJobCount = max(0, servers[index].activeJobCount - 1)

        // Update rolling average
        var durations = jobDurations[serverId] ?? []
        durations.append(duration)
        // Keep last 10 durations for averaging
        if durations.count > 10 { durations.removeFirst() }
        jobDurations[serverId] = durations
        servers[index].averageJobDuration = durations.reduce(0, +) / Double(durations.count)
    }

    func recordJobFailure(serverId: UUID, error: String) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        servers[index].activeJobCount = max(0, servers[index].activeJobCount - 1)
        servers[index].lastError = error
    }

    // MARK: - Migration

    /// Import the legacy single-server config from LLMProviderSettings into the pool.
    /// Only runs once (guarded by UserDefaults flag).
    func migrateFromLegacySettings(url: String, apiKey: String) {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        guard !url.isEmpty else {
            UserDefaults.standard.set(true, forKey: migratedKey)
            return
        }

        // Check we don't already have this URL
        let normalizedURL = url.hasSuffix("/") ? String(url.dropLast()) : url
        let alreadyExists = servers.contains { $0.url == normalizedURL }
        if !alreadyExists {
            addServer(name: "Remote Server", url: normalizedURL, apiKey: apiKey)
            AppLog.info("Server pool: migrated legacy server \(normalizedURL)")
        }

        UserDefaults.standard.set(true, forKey: migratedKey)
    }

    // MARK: - Computed Properties

    var enabledServers: [RemoteServer] {
        servers.filter { $0.isEnabled }
    }

    var hasServers: Bool {
        !servers.isEmpty
    }

    var hasEnabledServers: Bool {
        !enabledServers.isEmpty
    }

    var hasHealthyServers: Bool {
        enabledServers.contains { $0.healthStatus == .healthy }
    }

    var totalActiveJobs: Int {
        servers.reduce(0) { $0 + $1.activeJobCount }
    }

    var poolStatusSummary: String {
        let total = servers.count
        let enabled = enabledServers.count
        let healthy = enabledServers.filter { $0.healthStatus == .healthy }.count
        let active = totalActiveJobs

        if total == 0 { return "No servers" }

        var parts: [String] = ["\(total) server\(total == 1 ? "" : "s")"]
        if enabled < total { parts.append("\(enabled) enabled") }
        if healthy > 0 { parts.append("\(healthy) healthy") }
        if active > 0 { parts.append("\(active) job\(active == 1 ? "" : "s") running") }
        return parts.joined(separator: ", ")
    }
}
