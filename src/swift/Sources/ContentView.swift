import SwiftUI

// Shared coordinator for Chat → Studio workflow
@MainActor
class StudioCoordinator: ObservableObject {
    // The tab tags, as the `.tag(...)` calls in `body` actually spell them.
    // The comment that used to sit on `selectedTab` read "0 = Chat, 1 = Studio,
    // 2 = Library, 3 = Publisher, 4 = Stems" and was wrong in two places at
    // once: tag 1 is Create, and the DAW is tag 5. Both of the tab switches
    // below were then commented "// Switch to Studio tab" while one of them
    // went somewhere else entirely. The code was right the whole time; only the
    // prose lied, which is the more dangerous of the two because a reader
    // trusts it and does not check.
    //
    // 0 = Chat · 1 = Create · 2 = Library · 3 = Publisher · 4 = Stems ·
    // 5 = Studio (the DAW — `StudioRootView.tabTag`, which is the name to use
    // rather than the number).
    @Published var selectedTab: Int = 0
    @Published var pendingParameters: BackendViewModel.MusicParameters?

    /// Stem session to select when the Stems tab opens (consumed by StemSessionsView).
    @Published var pendingStemSessionID: UUID?

    /// Installed by StemSessionsView so the global Play/Pause command
    /// (spacebar) drives the stem transport while the Stems tab is selected.
    /// Returns true when it consumed the toggle (a session with loaded
    /// stems); false falls through to the app-wide track player.
    /// Not @Published — nothing renders from it.
    var stemTransportToggle: (() -> Bool)?

    /// Installed by StudioRootView (the DAW tab): the same spacebar
    /// arrangement for the Studio timeline transport while the Studio tab
    /// is selected. Not @Published — nothing renders from it.
    var dawTransportToggle: (@MainActor () -> Bool)?

    /// The thing that can split a song into its parts (the app's Python
    /// backend, which runs htdemucs). Installed once at launch in `Main.swift`,
    /// which is the only place that holds both this and the backend.
    ///
    /// Handed through the coordinator rather than read as an
    /// `@EnvironmentObject` by each surface that needs it, and that is the
    /// point: `BackendViewModel` republishes constantly, so a tab body that
    /// observed it would redraw on every tick of every generation. This is not
    /// `@Published` — nothing renders from it, exactly like the two transport
    /// hooks above.
    ///
    /// nil is a real state (the backend has not started yet), and every caller
    /// refuses with `StemSeparationRun.noSeparatorReason` rather than doing
    /// nothing.
    var stemSeparator: StemSeparating?

    init() {
        // Evidence/automation hook: launch straight into the Studio tab.
        if ProcessInfo.processInfo.arguments.contains("--open-studio-tab") {
            selectedTab = 5
        }
    }

    /// Hand generation parameters to the Create tab and go there.
    ///
    /// There used to be a `source:` parameter here, carrying a
    /// `StudioEntrySource` of `.standard` or `.engineerExtraction`, stored into
    /// an `entrySource` property. Exactly one call site passed anything but the
    /// default (`ChatView`, when the engineer had extracted parameters from the
    /// conversation) and NOTHING anywhere read the property back — so that
    /// entry was byte-for-byte identical to a plain one, and the branch was an
    /// intention with no consequence. Deleted rather than wired: an inert
    /// distinction reads to the next person like a behaviour they must preserve.
    func openStudioWithParameters(_ params: BackendViewModel.MusicParameters) {
        pendingParameters = params
        selectedTab = 1  // the Create tab, which is where the parameters land
    }

    /// A song the user asked to "Open in Studio": consumed by StudioRootView,
    /// which runs the landing pipeline on the engine and shows the session.
    @Published var pendingLanding: StudioLandingRequest?

    /// Open a finished library/generated track in the Studio (DAW) as a
    /// bar-aligned stem session (L8). Stores the request and switches to the
    /// Studio tab; StudioRootView picks it up and runs the landing.
    func openInStudio(track: Track) {
        pendingLanding = StudioLandingRequest(
            sourceAudioPath: track.audioURL.path,
            prompt: track.caption.isEmpty ? (track.originalPrompt ?? track.title) : track.caption,
            declaredBPM: track.bpm,
            key: track.key,
            sectionTags: Self.sectionTags(fromLyrics: track.lyrics),
            seed: nil,
            genModel: nil,
            projectName: track.title.isEmpty ? nil : track.title
        )
        selectedTab = StudioRootView.tabTag  // the DAW tab
    }

    /// Parse ordered section names from lyric section tags like `[verse]`,
    /// `[Chorus 2]`, `[intro]`. Returns them Title-cased in order of appearance.
    static func sectionTags(fromLyrics lyrics: String?) -> [String] {
        guard let lyrics, !lyrics.isEmpty else { return [] }
        var tags: [String] = []
        var i = lyrics.startIndex
        while let open = lyrics[i...].firstIndex(of: "[") {
            guard let close = lyrics[open...].firstIndex(of: "]") else { break }
            let inner = lyrics[lyrics.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty && inner.count <= 24 {
                tags.append(inner.capitalized)
            }
            i = lyrics.index(after: close)
        }
        return tags
    }

    /// Switches to the Stems tab, optionally selecting a specific session.
    func openStemSessions(sessionID: UUID? = nil) {
        pendingStemSessionID = sessionID
        selectedTab = 4  // Switch to Stems tab
    }

    // MARK: Stems -> Studio

    /// Stems handed from the Stems tab to the Studio (DAW) tab. Consumed by
    /// StudioRootView, which imports each one onto its own track through the
    /// journalled `track.add` + `import.audio` pair — the same bus a drag onto
    /// the timeline uses. Mirrors `pendingLanding` exactly, including being
    /// cleared by the consumer.
    @Published var pendingStemImport: StudioStemImportRequest?

    /// Open a stem — or a whole stem session — in the Studio.
    ///
    /// This direction did not exist. The Stems tab and the Studio were two
    /// views of the same four parts of the same song with no way to get from
    /// one to the other, so a mix balanced in the Stems tab could not be
    /// arranged, and an arrangement could not be re-balanced.
    func openStemsInStudio(_ request: StudioStemImportRequest) {
        guard !request.stems.isEmpty else { return }
        pendingStemImport = request
        selectedTab = StudioRootView.tabTag
    }
}

// The bar is the ONLY thing in `ContentView` that ever cared about the player,
// and `AudioPlayer` republishes its clock every 100 ms for as long as a track is
// playing. Observing it from `ContentView` meant each of those ticks invalidated
// the whole `TabView` body — including the Studio DAW's, which then paid a
// blocking securityd round trip per pass (`StudioKeychainItem`). Sampling the
// owner's 3.4.13 session found exactly that: `SecItemCopyMatching` about every
// 110 ms for eight hours, from a person who was doing nothing but listening.
//
// Giving the bar its own observing leaf keeps the dependency where the data is
// used. `ContentView` no longer names AudioPlayer at all, so a playing track
// invalidates ~30 pt of chrome instead of every tab in the app.
private struct PersistentPlayerBarSlot: View {
    @EnvironmentObject private var player: AudioPlayer
    let selectedTab: Int

    var body: some View {
        // Persistent player bar across all tabs EXCEPT Studio: the DAW owns its
        // own transport, and two transports reading different clocks side by
        // side would lie to the user.
        if player.currentURL != nil, selectedTab != 5 {
            PersistentPlayerBar()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var studioCoordinator: StudioCoordinator
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @EnvironmentObject var playbackQueue: PlaybackQueue
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $studioCoordinator.selectedTab) {
                EnhancedChatView()
                    .tabItem { Label("Chat", systemImage: "message") }
                    .tag(0)

                // Label renamed "Studio" -> "Create" when the DAW landed as
                // the new Studio tab (L5). View + tag untouched.
                EnhancedStudioView()
                    .tabItem { Label("Create", systemImage: "waveform") }
                    .tag(1)

                // The Studio DAW tab (timeline shell, lane L5). Tag 5: tags
                // 0-4 belong to Chat/Create/Library/Publisher/Stems above.
                StudioRootView()
                    .tabItem { Label("Studio", systemImage: "square.grid.3x1.below.line.grid.1x2") }
                    .tag(5)

                // Stems keeps tag 4 (Publisher's tag 3 is referenced elsewhere);
                // tab order comes from declaration order, not tag values.
                StemSessionsView()
                    .tabItem { Label("Stems", systemImage: "slider.horizontal.3") }
                    .tag(4)

                LibraryView()
                    .tabItem { Label("Library", systemImage: "music.note.list") }
                    .tag(2)

                // Publishing gates on Keycloak sign-in (handled inside
                // PublisherView), not on a license — the app is free.
                PublisherView()
                    .tabItem { Label("Publisher", systemImage: "arrow.up.circle") }
                    .tag(3)
            }

            PersistentPlayerBarSlot(selectedTab: studioCoordinator.selectedTab)
        }
        .overlay { ToastOverlay() }
        .onChange(of: library.lastSaveError) { _, newError in
            if let error = newError {
                ToastManager.shared.show(error, style: .warning)
                library.clearLastSaveError()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .environmentObject(studioCoordinator)
    }
}
