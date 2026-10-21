import Foundation

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [ChatAgent] = []
    @Published var selectedAgentID: UUID = ChatAgent.majikAgentID

    private let agentsKey = "majik_chat_agents_v1"
    private let selectedAgentKey = "majik_selected_agent_id_v1"

    var selectedAgent: ChatAgent {
        agent(for: selectedAgentID) ?? ChatAgent.builtIns[0]
    }

    func load() {
        let defaults = UserDefaults.standard
        let decodedAgents: [ChatAgent]

        if let data = defaults.data(forKey: agentsKey),
           let stored = try? JSONDecoder().decode([ChatAgent].self, from: data) {
            decodedAgents = stored
        } else {
            decodedAgents = ChatAgent.builtIns
        }

        agents = normalize(decodedAgents)

        if let selectedAgentRaw = defaults.string(forKey: selectedAgentKey),
           let selectedAgentID = UUID(uuidString: selectedAgentRaw),
           agent(for: selectedAgentID) != nil {
            self.selectedAgentID = selectedAgentID
        } else {
            selectedAgentID = ChatAgent.majikAgentID
        }

        save()
    }

    func selectAgent(_ agent: ChatAgent) {
        selectedAgentID = agent.id
        saveSelection()
    }

    func agent(for id: UUID?) -> ChatAgent? {
        guard let id else { return nil }
        return agents.first(where: { $0.id == id })
    }

    func upsert(_ agent: ChatAgent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = sanitized(agent)
        } else {
            agents.append(sanitized(agent))
        }
        agents = normalize(agents)
        save()
    }

    @discardableResult
    func duplicate(_ agent: ChatAgent) -> ChatAgent {
        let duplicated = agent.copyForDuplicate()
        agents.append(duplicated)
        agents = normalize(agents)
        save()
        return duplicated
    }

    func delete(_ agent: ChatAgent) {
        guard !agent.isBuiltIn else { return }
        agents.removeAll { $0.id == agent.id }
        if selectedAgentID == agent.id {
            selectedAgentID = ChatAgent.majikAgentID
        }
        agents = normalize(agents)
        save()
    }

    /// Internal (not private) so the naming/migration tests can drive it with a
    /// synthetic stored payload instead of writing to UserDefaults.standard.
    func normalize(_ rawAgents: [ChatAgent]) -> [ChatAgent] {
        let builtInIDs = Set(ChatAgent.builtIns.map(\.id))
        var indexed = Dictionary(uniqueKeysWithValues: rawAgents.map { ($0.id, sanitized($0)) })

        let builtIns = ChatAgent.builtIns.map { builtIn -> ChatAgent in
            guard var existing = indexed.removeValue(forKey: builtIn.id) else {
                return builtIn
            }
            existing.isBuiltIn = true
            if builtIn.id == ChatAgent.majikAgentID {
                // Sterling rebrand (2026-07): the default agent used to present
                // as "Majik". A stored copy still carrying the untouched legacy
                // name migrates to the Sterling identity; user renames are
                // respected.
                if existing.name == "Majik" {
                    existing.name = builtIn.name
                    existing.iconSystemName = builtIn.iconSystemName
                }
                // Producer rename (2026-07): Sterling's subtitle used to read
                // "The Engineer", which collided with the separate built-in
                // technical agent of that name. This has to run independently
                // of the name check above — a user who already migrated to
                // "Sterling" still has the colliding subtitle stored, and
                // leaving it would keep two "The Engineer" rows in Settings ▸
                // Agents forever. User-edited subtitles are respected.
                if ChatAgent.legacyMajikSummaries.contains(existing.summary) {
                    existing.summary = builtIn.summary
                }
            }
            return existing
        }

        let customs = rawAgents
            .filter { !builtInIDs.contains($0.id) }
            .map(sanitized)

        return builtIns + customs
    }

    private func sanitized(_ agent: ChatAgent) -> ChatAgent {
        var sanitizedAgent = agent
        sanitizedAgent.name = sanitizedAgent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitizedAgent.name.isEmpty {
            sanitizedAgent.name = "Untitled Agent"
        }
        sanitizedAgent.summary = sanitizedAgent.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitizedAgent.systemPrompt = sanitizedAgent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitizedAgent.customInstructions = sanitizedAgent.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitizedAgent.modelID = sanitizedAgent.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitizedAgent.brigadeAgentID = sanitizedAgent.brigadeAgentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitizedAgent.brigadeAgentID?.isEmpty == true {
            sanitizedAgent.brigadeAgentID = nil
        }
        sanitizedAgent.enabledToolIDs = Array(Set(sanitizedAgent.enabledToolIDs)).sorted()
        return sanitizedAgent
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(agents) {
            UserDefaults.standard.set(encoded, forKey: agentsKey)
        }
        saveSelection()
    }

    private func saveSelection() {
        UserDefaults.standard.set(selectedAgentID.uuidString, forKey: selectedAgentKey)
    }
}
