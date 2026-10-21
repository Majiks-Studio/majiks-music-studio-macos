import SwiftUI

/// The floating "Sterling" chat window: Sterling reachable from any tab.
///
/// This renders the SAME EnhancedChatView over the SAME shared environment
/// objects (ConversationStore, BackendViewModel, AgentStore, …) the Chat tab
/// uses — one conversation state, two views. Sending a message here streams
/// into the Chat tab and vice versa; the window survives tab switches and
/// closes cleanly (the stores live in the App, not in this scene).
///
/// Opened by the "Pop Out" button in the Chat tab toolbar, or
/// Window ▸ Chat with Sterling (⇧⌘S).
struct SterlingChatWindowView: View {
    /// Scene id of the Window declared in Main.swift.
    static let windowID = "sterling-chat-window"

    var body: some View {
        EnhancedChatView(showsPopoutButton: false)
            .frame(minWidth: 560, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
    }
}
