import Foundation

extension BrigadeConfig {
    static var chatURL: URL? {
        normalizedURL(suffix: "/chat/completions")
    }

    static var agentsURL: URL? {
        guard var components = URLComponents(string: base) else { return nil }
        let openAISuffix = "/api/v1/openai/v1"
        if components.path.hasSuffix(openAISuffix) {
            components.path.removeLast(openAISuffix.count)
        }
        return components.url?.appending(path: "api/v1/agents")
    }

    private static func normalizedURL(suffix: String) -> URL? {
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + suffix)
    }
}

private struct BrigadeOpenAIMessage {
    let role: String
    let content: String

    var json: [String: Any] { ["role": role, "content": content] }
}

private final class BrigadeTurnState: @unchecked Sendable {
    private let lock = NSLock()
    let id: UInt64
    let agentID: String
    var task: Task<Void, Never>?
    private var phase = "running"
    private var nextSeq = 0
    private var events: [[String: Any]] = []

    init(id: UInt64, agentID: String) {
        self.id = id
        self.agentID = agentID
    }

    func push(_ event: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        var payload = event
        payload["seq"] = nextSeq
        nextSeq += 1
        events.append(payload)
    }

    func finish(_ newPhase: String) {
        lock.lock()
        defer { lock.unlock() }
        if phase == "running" { phase = newPhase }
    }

    func snapshotJSON() throws -> String {
        lock.lock()
        let payload: [String: Any] = ["turn_id": id, "state": phase, "events": events]
        lock.unlock()
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    func cancel() {
        task?.cancel()
    }
}

private struct BrigadeSSEAccumulator {
    var content = ""

    mutating func push(line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let body = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, body != "[DONE]" else { return nil }
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let text = delta["content"] as? String,
              !text.isEmpty
        else { return nil }
        content += text
        return text
    }
}

final class BrigadeCopilotBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var nextTurnID: UInt64 = 1
    private var turns: [UInt64: BrigadeTurnState] = [:]
    private var history: [String: [BrigadeOpenAIMessage]] = [:]

    func send(_ request: StudioCopilotSendRequest) throws -> UInt64 {
        guard case let .brigade(agentID, displayName) = request.route else {
            throw NSError(domain: "Brigade", code: 400, userInfo: [NSLocalizedDescriptionKey: "Brigade routing requires a Brigade agent selection."])
        }
        guard let apiKey = BrigadeKeychain.key(), !apiKey.isEmpty else {
            throw NSError(domain: "Brigade", code: 401, userInfo: [NSLocalizedDescriptionKey: "Add a Brigade key in Sterling settings first."])
        }
        guard let url = BrigadeConfig.chatURL else {
            throw NSError(domain: "Brigade", code: 400, userInfo: [NSLocalizedDescriptionKey: "The Brigade base URL is not valid."])
        }

        lock.lock()
        let turnID = nextTurnID
        nextTurnID += 1
        let turn = BrigadeTurnState(id: turnID, agentID: agentID)
        turns[turnID] = turn
        let prior = history[agentID] ?? []
        lock.unlock()

        turn.task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runTurn(
                turn: turn,
                url: url,
                apiKey: apiKey,
                agentID: agentID,
                agentName: displayName ?? agentID,
                text: request.text,
                prior: prior
            )
        }
        return turnID
    }

    func pollIfKnown(_ turnID: UInt64) throws -> String? {
        lock.lock()
        let turn = turns[turnID]
        lock.unlock()
        return try turn?.snapshotJSON()
    }

    func cancelIfKnown(_ turnID: UInt64) throws -> Bool {
        lock.lock()
        let turn = turns[turnID]
        lock.unlock()
        guard let turn else { return false }
        turn.cancel()
        return true
    }

    func clearHistory() throws {
        lock.lock()
        defer { lock.unlock() }
        history.removeAll()
    }

    private func remember(agentID: String, user: String, assistant: String) {
        lock.lock()
        defer { lock.unlock() }
        var rows = history[agentID] ?? []
        rows.append(.init(role: "user", content: user))
        rows.append(.init(role: "assistant", content: assistant))
        if rows.count > 40 {
            rows.removeFirst(rows.count - 40)
        }
        history[agentID] = rows
    }

    private func runTurn(
        turn: BrigadeTurnState,
        url: URL,
        apiKey: String,
        agentID: String,
        agentName: String,
        text: String,
        prior: [BrigadeOpenAIMessage]
    ) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let messages = prior.map(\.json) + [BrigadeOpenAIMessage(role: "user", content: text).json]
        let body: [String: Any] = [
            "model": agentID,
            "messages": messages,
            "stream": true,
            "user": "majiks-studio"
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                turn.push(["type": "turn_error", "message": "Brigade did not return an HTTP response."])
                turn.finish("failed")
                return
            }

            if !(200...299).contains(http.statusCode) {
                let responseText = try await Self.readBody(bytes)
                let extra = http.statusCode == 402
                    ? " The Brigade key name must be allow-listed in BRIGADE_TRUSTED_KEY_NAMES."
                    : ""
                turn.push(["type": "turn_error", "message": "Brigade \(agentName) returned HTTP \(http.statusCode).\(extra) \(responseText)"])
                turn.finish("failed")
                return
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.hasPrefix("application/json") {
                let data = try await Self.collectBytes(bytes, limit: 2_000_000)
                let content = Self.parseCompletionJSON(data: data)
                if !content.isEmpty {
                    turn.push(["type": "text_delta", "text": content])
                    remember(agentID: agentID, user: text, assistant: content)
                }
                turn.finish("done")
                return
            }

            var accumulator = BrigadeSSEAccumulator()
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if let delta = accumulator.push(line: line) {
                    turn.push(["type": "text_delta", "text": delta])
                }
            }
            remember(agentID: agentID, user: text, assistant: accumulator.content)
            turn.finish("done")
        } catch is CancellationError {
            turn.finish("cancelled")
        } catch {
            turn.push(["type": "turn_error", "message": "Brigade chat failed: \(error.localizedDescription)"])
            turn.finish("failed")
        }
    }

    private static func parseCompletionJSON(data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { return "" }
        return message["content"] as? String ?? ""
    }

    private static func readBody(_ bytes: URLSession.AsyncBytes) async throws -> String {
        let data = try await collectBytes(bytes, limit: 16_384)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func collectBytes(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(limit, 4096))
        for try await byte in bytes {
            if data.count >= limit { break }
            data.append(byte)
        }
        return data
    }
}

struct BrigadeRegistrationService {
    @MainActor
    func register(agent: ChatAgent, settings: LLMProviderSettings) async throws -> ChatAgent {
        guard let key = BrigadeKeychain.key(), !key.isEmpty else {
            throw NSError(domain: "Brigade", code: 401, userInfo: [NSLocalizedDescriptionKey: "Add a Brigade key in Sterling settings first."])
        }
        guard let url = BrigadeConfig.agentsURL else {
            throw NSError(domain: "Brigade", code: 400, userInfo: [NSLocalizedDescriptionKey: "The Brigade base URL is not valid."])
        }

        let brigadeID = agent.brigadeAgentID ?? stableAgentID(for: agent)
        let instructions = [agent.systemPrompt, agent.customInstructions]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let payload: [String: Any] = [
            "name": brigadeID,
            "displayName": agent.name,
            "title": "Majik's Music Studio agent",
            "avatar": "🎛️",
            "bio": agent.summary,
            "persona": agent.summary,
            "systemPrompt": instructions.isEmpty ? "You are \(agent.name), a Majik's Music Studio agent." : instructions,
            "domain": "music",
            "subdomain": "majiks-studio",
            "status": "active",
            "type": "individual",
            "agentType": "analysis",
            "capabilities": agent.enabledToolIDs,
            "model": agent.resolvedModel(using: settings),
            "temperature": agent.resolvedTemperature(fallback: settings.currentModelDefaults.temperature),
            "maxTokens": agent.resolvedMaxTokens(fallback: settings.currentModelDefaults.maxTokens),
            "tools": []
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Brigade", code: 500, userInfo: [NSLocalizedDescriptionKey: "Brigade did not return an HTTP response."])
        }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = text.isEmpty ? "HTTP \(http.statusCode)" : text
            throw NSError(domain: "Brigade", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Brigade registration failed: \(detail)"])
        }

        var saved = agent
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            saved.brigadeAgentID = (obj["id"] as? String) ?? (obj["name"] as? String) ?? brigadeID
        } else {
            saved.brigadeAgentID = brigadeID
        }
        return saved
    }

    private func stableAgentID(for agent: ChatAgent) -> String {
        let slug = agent.name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let prefix = slug.isEmpty ? "agent" : slug
        return "majiks-\(prefix)-\(agent.id.uuidString.prefix(8).lowercased())"
    }
}
