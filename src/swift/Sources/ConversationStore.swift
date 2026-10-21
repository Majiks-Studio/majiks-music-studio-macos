import Foundation
import SwiftUI

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published var currentConversation: Conversation?

    private let fileStore = FileStore.shared
    private var fallbackAgentID: UUID = ChatAgent.majikAgentID

    private var conversationsURL: URL {
        fileStore.appSupportDirectory.appendingPathComponent("conversations.json")
    }

    func load(defaultAgentID: UUID = ChatAgent.majikAgentID) {
        fallbackAgentID = defaultAgentID
        do {
            let data = try Data(contentsOf: conversationsURL)
            let decoded = try JSONDecoder().decode([Conversation].self, from: data)
            conversations = decoded.sorted { $0.updatedAt > $1.updatedAt }

            if conversations.isEmpty {
                createNewConversation(agentID: defaultAgentID)
            } else {
                activateAgent(defaultAgentID)
            }
        } catch {
            conversations = []
            let newConversation = Conversation(agentID: defaultAgentID)
            conversations = [newConversation]
            currentConversation = newConversation
            save()
        }
    }

    func createNewConversation(agentID: UUID? = nil) {
        let resolvedAgentID = agentID ?? currentConversation?.agentID ?? fallbackAgentID
        let conversation = Conversation(agentID: resolvedAgentID)
        conversations.insert(conversation, at: 0)
        currentConversation = conversation
        save()
    }

    func activateAgent(_ agentID: UUID) {
        fallbackAgentID = agentID
        if currentConversation?.agentID == agentID {
            return
        }
        if let existing = conversations(for: agentID).first {
            currentConversation = existing
        } else {
            createNewConversation(agentID: agentID)
        }
    }

    func conversations(for agentID: UUID) -> [Conversation] {
        conversations.filter { $0.agentID == agentID }
    }

    func addMessage(_ message: ChatMessage) {
        guard var conversation = currentConversation else {
            createNewConversation(agentID: fallbackAgentID)
            guard var conversation = currentConversation else { return }
            conversation.addMessage(message)
            updateConversation(conversation)
            return
        }

        conversation.addMessage(message)
        updateConversation(conversation)
    }

    func updateMessage(id: UUID, content: String) {
        guard var conversation = currentConversation else { return }
        conversation.updateMessage(id: id, content: content)
        updateConversation(conversation)
    }

    func deleteMessage(id: UUID) {
        guard var conversation = currentConversation else { return }
        conversation.deleteMessage(id: id)
        updateConversation(conversation)
    }

    func updateConversation(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
            if currentConversation?.id == conversation.id {
                currentConversation = conversation
            }
            // Re-sort to move updated conversation to top
            conversations.sort { $0.updatedAt > $1.updatedAt }
            save()
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        if currentConversation?.id == conversation.id {
            if let replacement = conversations(for: conversation.agentID).first {
                currentConversation = replacement
            } else {
                createNewConversation(agentID: conversation.agentID)
                return
            }
        }
        save()
    }

    func selectConversation(_ conversation: Conversation) {
        currentConversation = conversation
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(conversations)
            try data.write(to: conversationsURL, options: .atomic)
        } catch {
            print("Failed to save conversations: \(error)")
        }
    }
}
