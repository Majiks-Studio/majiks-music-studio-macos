import SwiftUI

/// Standalone Library window for pop-out
struct LibraryWindowView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var playbackQueue: PlaybackQueue
    @EnvironmentObject var backend: BackendViewModel
    @EnvironmentObject var conversationStore: ConversationStore
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var studioCoordinator: StudioCoordinator
    @EnvironmentObject var publisherStore: PublisherStore
    @Environment(\.dismissWindow) var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            // Window toolbar
            HStack {
                Text("Library")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button(action: {
                    dismissWindow(id: "library-window")
                    WindowManager.shared.closeLibraryWindow()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Library Window")
            }
            .padding()

            Divider()

            // Reuse the existing LibraryView content
            LibraryView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(playbackQueue)
                .environmentObject(backend)
                .environmentObject(studioCoordinator)
                .environmentObject(conversationStore)
                .environmentObject(sessionStore)
                .environmentObject(publisherStore)
        }
        .frame(minWidth: 700, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
    }
}

/// Standalone Studio window for pop-out
struct StudioWindowView: View {
    @EnvironmentObject var backend: BackendViewModel
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var conversationStore: ConversationStore
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var stemSessionStore: StemSessionStore
    @EnvironmentObject var studioCoordinator: StudioCoordinator
    @EnvironmentObject var generationQueue: GenerationQueue
    @EnvironmentObject var licenseManager: LicenseManager
    @EnvironmentObject var serverPool: ServerPoolManager
    @EnvironmentObject var modelAvailability: ModelAvailabilityManager
    @Environment(\.dismissWindow) var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            // Window toolbar
            HStack {
                Text("Studio")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button(action: {
                    dismissWindow(id: "studio-window")
                    WindowManager.shared.closeStudioWindow()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Studio Window")
            }
            .padding()

            Divider()

            // Reuse the existing EnhancedStudioView
            EnhancedStudioView()
                .environmentObject(backend)
                .environmentObject(llmSettings)
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(conversationStore)
                .environmentObject(sessionStore)
                .environmentObject(stemSessionStore)
                .environmentObject(studioCoordinator)
                .environmentObject(generationQueue)
                .environmentObject(licenseManager)
                .environmentObject(serverPool)
                .environmentObject(modelAvailability)
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
    }
}
