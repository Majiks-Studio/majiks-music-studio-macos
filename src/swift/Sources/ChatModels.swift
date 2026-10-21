import Foundation

/// Represents a single message in the chat
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    var content: String  // var to allow editing
    let timestamp: Date
    var speakerAgentID: UUID?

    enum Role: String, Codable {
        case user
        case assistant // Sterling (The Producer)
        case system
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        speakerAgentID: UUID? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.speakerAgentID = speakerAgentID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case timestamp
        case speakerAgentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        speakerAgentID = try container.decodeIfPresent(UUID.self, forKey: .speakerAgentID)
    }

    var isFromAssistant: Bool {
        role == .assistant
    }

    var isFromUser: Bool {
        role == .user
    }
}

/// Represents a conversation with Sterling (or another chat agent)
struct Conversation: Identifiable, Codable {
    let id: UUID
    var agentID: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        agentID: UUID = ChatAgent.majikAgentID,
        title: String = "New Conversation",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case agentID
        case title
        case messages
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        agentID = try container.decodeIfPresent(UUID.self, forKey: .agentID) ?? ChatAgent.majikAgentID
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New Conversation"
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    mutating func addMessage(_ message: ChatMessage) {
        messages.append(message)
        updatedAt = Date()

        // Auto-generate title from first user message
        if title == "New Conversation", message.isFromUser, messages.count <= 2 {
            title = String(message.content.prefix(50))
        }
    }

    mutating func updateMessage(id: UUID, content: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].content = content
            updatedAt = Date()
        }
    }

    mutating func deleteMessage(id: UUID) {
        messages.removeAll { $0.id == id }
        updatedAt = Date()
    }

    /// Get messages in OpenRouter API format (for history)
    var apiMessages: [[String: String]] {
        messages.filter { $0.role != .system }.map { message in
            ["role": message.role.rawValue, "content": message.content]
        }
    }
}
