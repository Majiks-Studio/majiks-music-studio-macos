import SwiftUI
import AppKit

struct MessageRowView: View {
    let message: ChatMessage
    let agent: ChatAgent
    let onEdit: (String) -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var editedContent: String = ""
    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 4) {
                if message.isFromUser {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3)
                        .foregroundColor(.blue)
                    Text("You")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                } else {
                    AgentAvatarView(agent: agent, size: 26)
                    Text(agent.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(agent.accentColor)
                        .lineLimit(2)
                }
            }
            .frame(width: 72, alignment: .trailing)

            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    TextEditor(text: $editedContent)
                        .font(.body)
                        .frame(minHeight: 60)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)

                    HStack {
                        Button("Save") {
                            onEdit(editedContent)
                            isEditing = false
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Cancel") {
                            isEditing = false
                            editedContent = message.content
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text(message.content)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(message.isFromUser ? Color.blue.opacity(0.1) : agent.accentColor.opacity(0.12))
                        )

                    HStack(spacing: 8) {
                        Button {
                            editedContent = message.content
                            isEditing = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)

                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            copyMessageToClipboard()
                        } label: {
                            Text(didCopy ? "✓" : "📋")
                                .font(.caption)
                                .foregroundColor(didCopy ? .green : .primary)
                                .scaleEffect(didCopy ? 1.15 : 1.0)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy message")

                        Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .opacity(isHovered ? 1.0 : 0.4)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func copyMessageToClipboard() {
        // Provide quick visual confirmation when a copy succeeds.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            didCopy = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.2)) {
                didCopy = false
            }
        }
    }
}
