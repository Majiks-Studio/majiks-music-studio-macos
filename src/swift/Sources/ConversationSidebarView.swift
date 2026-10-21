import SwiftUI

struct ConversationSidebarView: View {
    @EnvironmentObject var conversationStore: ConversationStore
    @EnvironmentObject var agentStore: AgentStore

    private var scopedConversations: [Conversation] {
        conversationStore.conversations(for: agentStore.selectedAgentID)
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { conversationStore.currentConversation?.id },
            set: { newValue in
                guard let id = newValue,
                      let conversation = conversationStore.conversations.first(where: { $0.id == id }) else {
                    return
                }
                conversationStore.selectConversation(conversation)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversations")
                        .font(.headline)
                    Text(agentStore.selectedAgent.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                AgentAvatarView(agent: agentStore.selectedAgent, size: 24)
                Spacer()
                Button {
                    conversationStore.createNewConversation(agentID: agentStore.selectedAgentID)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            List(selection: selectionBinding) {
                ForEach(scopedConversations) { conversation in
                    ConversationRowView(conversation: conversation)
                        .tag(conversation.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                conversationStore.deleteConversation(conversation)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 250)
    }
}

struct ConversationRowView: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.body)
                .lineLimit(2)

            HStack {
                Text("\(conversation.messages.count) messages")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
