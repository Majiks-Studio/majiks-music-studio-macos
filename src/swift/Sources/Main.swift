import SwiftUI
import AppKit

@main
struct MajiksMusicStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    // UI Zoom level (0-6, default 3 = .large / system default)
    @AppStorage("majik_ui_zoom") private var uiZoomLevel: Int = 3

    private var dynamicTypeSize: DynamicTypeSize {
        switch uiZoomLevel {
        case 0: return .xSmall
        case 1: return .small
        case 2: return .medium
        case 3: return .large
        case 4: return .xLarge
        case 5: return .xxLarge
        case 6: return .xxxLarge
        default: return .large
        }
    }

    // Shared environment objects for all scenes
    @StateObject private var backend = BackendViewModel()
    @StateObject private var llmSettings = LLMProviderSettings()
    @StateObject private var library = LibraryStore()
    @StateObject private var player = AudioPlayer()
    @StateObject private var playbackQueue = PlaybackQueue()
    @StateObject private var agentStore = AgentStore()
    @StateObject private var conversationStore = ConversationStore()
    @StateObject private var sessionStore = SessionStore()
    @StateObject private var stemSessionStore = StemSessionStore()
    @StateObject private var studioCoordinator = StudioCoordinator()
    @StateObject private var generationQueue = GenerationQueue()
    @StateObject private var serverPool = ServerPoolManager()
    @StateObject private var modelAvailability = ModelAvailabilityManager()
    @StateObject private var publisherStore = PublisherStore()
    @StateObject private var windowManager = WindowManager.shared
    @StateObject private var licenseManager = LicenseManager()
    @StateObject private var updateChecker = UpdateChecker()

    // Global download manager (singleton, shared across all views)
    @ObservedObject private var downloadManager = DownloadManager.shared
    // The Studio's half of the menu bar. `@ObservedObject` rather than
    // `@StateObject` because the bridge's lifetime is the process's, not this
    // scene's: `StudioRootView` installs into it and the menus must keep
    // working while the user is on another tab.
    @ObservedObject private var menuBridge = StudioMenuBridge.shared
    @State private var showFirstRunSetup = false
    @State private var showUpdateNotification = false
    @State private var showLibraryPathMissing = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(backend)
                .environmentObject(llmSettings)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(agentStore)
                .environmentObject(conversationStore)
                .environmentObject(sessionStore)
                .environmentObject(stemSessionStore)
                .environmentObject(studioCoordinator)
                .environmentObject(generationQueue)
                .environmentObject(serverPool)
                .environmentObject(publisherStore)
                .environmentObject(windowManager)
                .environmentObject(licenseManager)
                .environmentObject(updateChecker)
                .environmentObject(downloadManager)
                .environmentObject(playbackQueue)
                .environmentObject(modelAvailability)
                .onAppear {
                    // Wire playback queue to audio player
                    playbackQueue.configure(player: player)

                    // Load settings and start backend
                    llmSettings.load()
                    licenseManager.load()
                    agentStore.load()

                    // Connect AppDelegate to stores for quit warning
                    appDelegate.backend = backend
                    appDelegate.licenseManager = licenseManager
                    appDelegate.sessionStore = sessionStore
                    appDelegate.library = library

                    // ... and for the menu bar (status item) dropdown:
                    // Now Playing line, tab jumps, and Check for Updates.
                    appDelegate.player = player
                    appDelegate.updateChecker = updateChecker
                    appDelegate.studioCoordinator = studioCoordinator

                    // Splitting a song into stems runs on the Python backend
                    // (htdemucs). This is the one place in the app that holds
                    // both the backend and the coordinator, so it is where the
                    // wire goes — and doing it here rather than from a tab body
                    // keeps `BackendViewModel` out of every view that offers
                    // the gesture, which would otherwise redraw those tabs on
                    // every publish the backend makes during a generation.
                    studioCoordinator.stemSeparator = backend

                    let isFirstRun = !UserDefaults.standard.bool(forKey: "HasLaunchedBefore")

                    // Check for disconnected external library drive
                    if FileStore.shared.customPathMissing {
                        showLibraryPathMissing = true
                    }

                    backend.start(environment: llmSettings.getEnvironmentVariables())
                    library.load()
                    conversationStore.load(defaultAgentID: agentStore.selectedAgentID)
                    publisherStore.loadAuthState()

                    // Defer non-critical chores until after the first paint so
                    // the window comes up snappier. These all hop back to the
                    // main actor when they touch @Published state, but they
                    // run in a Task that yields after onAppear returns.
                    Task {
                        library.cleanupMissingFiles()  // Remove phantom entries
                        await library.scanAndImportMissingTracks()  // Auto-import any generated files
                        sessionStore.cleanupOldStagingFiles()  // Remove staging files older than 30 days
                    }

                    // Check for updates after 2 seconds (non-blocking)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        updateChecker.checkForUpdatesIfNeeded()
                    }

                    // Ensure window comes to front, sits fully on a visible
                    // screen, and accepts input.
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        if let window = NSApp.windows.first {
                            window.level = .normal
                            WindowManager.clampToVisibleFrame(window)
                            window.makeKeyAndOrderFront(nil)
                            window.makeFirstResponder(nil)
                        }
                    }

                    // Show first-run wizard after UI is loaded
                    if isFirstRun {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showFirstRunSetup = true
                        }
                    }
                }
                .onChange(of: updateChecker.updateAvailable) { _, available in
                    if available {
                        showUpdateNotification = true
                    }
                }
                .onOpenURL { url in
                    publisherStore.handleAuthCallback(url: url)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettings"))) { _ in
                    // Open Settings from the setup wizard using the new Window approach
                    openWindow(id: "settings-window")
                }
                .sheet(isPresented: $showFirstRunSetup) {
                    SetupWizardView(onComplete: {
                        UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
                    })
                        .environmentObject(llmSettings)
                        .environmentObject(backend)
                        .environmentObject(downloadManager)
                        .environmentObject(publisherStore)
                }
                .sheet(isPresented: $showUpdateNotification) {
                    UpdateNotificationView(updateChecker: updateChecker)
                        .interactiveDismissDisabled(updateChecker.requiresMandatoryUpdate)
                }
                .alert("Library Drive Not Found", isPresented: $showLibraryPathMissing) {
                    Button("Use Default Location") {
                        FileStore.shared.resetToDefaultLocation()
                        library.load()
                        Task { await library.scanAndImportMissingTracks() }
                    }
                    Button("Open Settings") {
                        NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsToLibraryLocation"), object: nil)
                        openWindow(id: "settings-window")
                    }
                    Button("Continue Anyway", role: .cancel) { }
                } message: {
                    Text("Your library is configured to use:\n\n\(FileStore.shared.missingCustomPath ?? "an external location")\n\nbut that path doesn't exist. The drive may be disconnected.\n\nNew tracks will be saved to the default location until this is resolved.")
                }
                .dynamicTypeSize(dynamicTypeSize)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task {
                        await updateChecker.checkForUpdates(silent: false)
                    }
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    openWindow(id: "settings-window")
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    conversationStore.createNewConversation(agentID: agentStore.selectedAgentID)
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                // ⌘S for the Studio project. Before this there was NO save
                // affordance at all -- `project.save` shipped in the catalog
                // with zero call sites in the app, and ⌘S did nothing while a
                // day's work sat in RAM.
                //
                // It is deliberately not disabled when the project is already
                // current: a user who presses ⌘S out of habit should get the
                // reassurance, not a greyed-out menu item that reads like the
                // app cannot save.
                Button("Save Project") {
                    Task { @MainActor in
                        await StudioProjectSaver.shared.save(force: true)
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            // ---- The Studio's four object menus: Song, Track, Clip, Transport ----
            //
            // ⚠️ EVERY ITEM IN THESE FOUR IS GENERATED. There is no list of
            // commands here or in StudioMenuCommands.swift, and there must
            // never be one: `StudioMenuPlan` derives them from
            // `StudioPaletteCommands.all`, the same table ⌘K reads, and
            // `StudioMenuTests.testTheMenuFilesNameNoCatalogCommandOfTheirOwn`
            // fails the build if a catalog command name appears as a literal in
            // either file. Two hand-maintained lists of the same 119 commands
            // is exactly how the palette rotted to 11.
            //
            // One `Commands` conformance rather than four inline CommandMenus
            // because `CommandsBuilder` takes at most ten children and this
            // block already had nine.
            StudioCommandMenus(bridge: menuBridge)

            CommandMenu("Library") {
                Button("Import Audio...") {
                    NotificationCenter.default.post(name: NSNotification.Name("ImportAudioToLibrary"), object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Divider()

                Button("Find in Library") {
                    NotificationCenter.default.post(name: NSNotification.Name("FocusLibrarySearch"), object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button("New Artist...") {
                    // Post notification to show new artist sheet
                    NotificationCenter.default.post(name: NSNotification.Name("ShowNewArtist"), object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("New Album...") {
                    NotificationCenter.default.post(name: NSNotification.Name("ShowNewAlbum"), object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Button("Organize All Files") {
                    library.organizeAllTracks()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Show Audio Folder in Finder") {
                    NSWorkspace.shared.selectFile(
                        nil,
                        inFileViewerRootedAtPath: FileStore.shared.audioDirectory.path
                    )
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            CommandMenu("Playback") {
                Button("Play/Pause") {
                    // The Stems tab owns the spacebar while it is selected and
                    // a session with loaded stems is open; otherwise the
                    // app-wide track player keeps its binding.
                    if studioCoordinator.selectedTab == 4,
                       studioCoordinator.stemTransportToggle?() == true {
                        return
                    }
                    // The Studio (DAW) tab owns the spacebar the same way
                    // while it is selected (hook installed by StudioRootView).
                    if studioCoordinator.selectedTab == 5,
                       studioCoordinator.dawTransportToggle?() == true {
                        return
                    }
                    if player.isPlaying {
                        player.pause()
                    } else {
                        player.play()
                    }
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Stop") {
                    player.stop()
                }
                .keyboardShortcut(".", modifiers: .command)

                Divider()

                Button("Next Track") {
                    playbackQueue.skipToNext()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!playbackQueue.hasNext)

                Button("Previous Track") {
                    playbackQueue.skipToPrevious()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!playbackQueue.hasPrevious)

                Divider()

                // ⇧⌘S moved to Window ▸ Chat with Sterling; Shuffle keeps the
                // S mnemonic on ⌃⌘S.
                Button("Shuffle") {
                    playbackQueue.toggleShuffle()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])

                Button("Repeat") {
                    playbackQueue.cycleRepeatMode()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            CommandMenu("Publisher") {
                Button("Publish Selected") {
                    NotificationCenter.default.post(name: NSNotification.Name("PublishSelected"), object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Refresh") {
                    NotificationCenter.default.post(name: NSNotification.Name("RefreshPublisherSection"), object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Find in Catalogue") {
                    NotificationCenter.default.post(name: NSNotification.Name("FocusCatalogueSearch"), object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }

            // ---- View: the menu macOS ALREADY MADE, extended rather than shadowed ----
            //
            // ⚠️ `CommandMenu` ALWAYS CREATES A NEW TOP-LEVEL MENU. It has no
            // merge behaviour and never has had. macOS/SwiftUI auto-creates a
            // View menu (Show Sidebar, Enter Full Screen) for any
            // WindowGroup-based app, so the `CommandMenu("View")` that stood
            // here from v1.7.0 until this lane produced a SECOND menu carrying
            // the same word. The owner's menu bar read
            //
            //     … Publisher · View · Window · Window · Help
            //
            // with ⌘1…⌘6 in one View and Show Sidebar in the other and no way
            // to tell them apart except by opening both. It was never a
            // regression — both duplicates predate the ⌘1…⌘6 lane — but putting
            // navigation into the app's copy is what made it conspicuous, since
            // that is the copy a person naturally reaches for.
            //
            // `CommandGroup` is the ONLY thing that puts items into a menu the
            // system owns. `.sidebar` is the anchor rather than `.toolbar`
            // because the sidebar group is the one that also carries Enter Full
            // Screen, which every resizable window has; the toolbar group can be
            // empty in a window that has no toolbar, and an anchor that might not
            // be there is not an anchor.
            //
            // ⚠️ IF YOU ARE HERE TO ADD A VIEW ITEM, ADD IT TO THIS GROUP.
            // Writing `CommandMenu("View")` again re-creates the exact duplicate
            // this lane removed, and it will compile, and it will look fine in
            // every test that does not read the menu titles.
            // `StudioMenuTests.testNoAppDeclaredMenuShadowsOneMacOSMakesItself`
            // is the one that will stop you.
            CommandGroup(before: .sidebar) {
                // The OTHER half of "menus for all the sections". Until this
                // existed there was no way to reach a pane from the menu bar at
                // all — the tab strip was the only route, and on a 4K TV at
                // couch distance a row of six small tab labels is not a route.
                //
                // ⚠️ THIS DID NOT MOVE MENUS — it moved which View menu it is
                // in, and the View menu itself is now where macOS puts it
                // (third, right after Edit) instead of eleventh. Same word, same
                // items, same ⌘1…⌘6. Nothing here was relocated to another menu:
                // "Go to Stems" was under View before this lane and is under
                // View after it.
                //
                // ⌘1…⌘6 in the order the tabs are DECLARED, so the number
                // matches what the eye counts along the strip rather than the
                // internal tag (Studio is tag 5 and the third tab; the tags are
                // historical and `StudioCoordinator`'s own comment records the
                // prose about them being wrong for a while).
                ForEach(StudioSection.inTabStripOrder) { section in
                    Button("Go to \(section.title)") {
                        studioCoordinator.selectedTab = section.tag
                    }
                    .keyboardShortcut(
                        KeyEquivalent(section.shortcutKey ?? "1"), modifiers: .command)
                }

                Divider()

                Button("Zoom In") {
                    if uiZoomLevel < 6 { uiZoomLevel += 1 }
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Zoom Out") {
                    if uiZoomLevel > 0 { uiZoomLevel -= 1 }
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    uiZoomLevel = 3
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                // The Studio's own panes — browser, mixer, effects, inspector,
                // the frame readout, fit-to-window. Generated from the same
                // palette table as everything else (`studio.*` view rows), so a
                // panel that becomes toggleable from ⌘K becomes toggleable from
                // here with no edit at either site.
                StudioViewMenuItemsView(bridge: menuBridge)
            }

            // ---- Window: the same defect, and it had been shipping since v1.0 ----
            //
            // macOS builds a Window menu for every app (Minimize, Zoom, Bring
            // All to Front) and SwiftUI adds one item to it per `Window` scene
            // declared below. `CommandMenu("Window")` stood beside all of that
            // as a second menu of the same name. Read the `CommandMenu` warning
            // in the View block above — it is the whole reason both existed.
            //
            // ⚠️ AND THE KEYS WERE ALREADY DOUBLE-BOOKED, which is the part that
            // is easy to miss and is why this block is a merge rather than a
            // rename. `.keyboardShortcut` applied to a `Window` SCENE is the key
            // equivalent of the Window-menu item SwiftUI generates for it — that
            // is exactly why the Help window below has to call
            // `.commandsRemoved()` to stay out of the menu bar at all. So
            // `Window("Library")` was binding ⌥⌘L and `Window("Studio")` ⌥⌘S,
            // the same two keys the toggles below bind. Two items, two menus,
            // one key each, resolved by menu-bar ORDER — invisible from either
            // site. Merging the menus would have set both pairs an inch apart on
            // screen with the same shortcut printed twice.
            //
            // The scene-level shortcuts are the ones that went (see the `Window`
            // scenes below); the toggles here keep the keys, because a toggle
            // that also CLOSES the window is strictly the more useful of the two
            // and the scene item can still open it by name.
            //
            // `.windowList` anchors this above the list of the app's own
            // windows. Which exact row macOS lands it on is macOS's decision and
            // cannot be asserted from source — see the report's "what the guard
            // cannot see".
            CommandGroup(before: .windowList) {
                Button("Chat with Sterling") {
                    openWindow(id: SterlingChatWindowView.windowID)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button(windowManager.isLibraryWindowOpen ? "Close Library Window" : "Pop Out Library") {
                    windowManager.toggleLibraryWindow()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])

                Button(windowManager.isStudioWindowOpen ? "Close Studio Window" : "Pop Out Studio") {
                    windowManager.toggleStudioWindow()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .help) {
                Button("Majik's Music Studio Help") {
                    openWindow(id: "help-window")
                }
                .keyboardShortcut("?", modifiers: .command)

                Divider()

                // The front door to ⌘K, for the person who does not know ⌘K
                // exists. The palette can be opened only while the Studio tab
                // is frontmost (its shortcut lives on StudioRootView's hidden
                // buttons), so this goes there FIRST and then opens it —
                // otherwise the item would appear to do nothing from the Chat
                // tab, which is the class of dead affordance these menus exist
                // to remove.
                Button("Search All Studio Commands…") {
                    studioCoordinator.selectedTab = StudioRootView.tabTag
                    StudioMenuBridge.shared.openPalette()
                }
            }
        }

        // Settings Window (using Window instead of Settings for resizability)
        Window("Settings", id: "settings-window") {
            SettingsView()
                .environmentObject(backend)
                .environmentObject(llmSettings)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(agentStore)
                .environmentObject(conversationStore)
                .environmentObject(sessionStore)
                .environmentObject(studioCoordinator)
                .environmentObject(windowManager)
                .environmentObject(licenseManager)
                .environmentObject(publisherStore)
                .environmentObject(updateChecker)
                .environmentObject(downloadManager)
                .environmentObject(serverPool)
                .environmentObject(modelAvailability)
                .dynamicTypeSize(dynamicTypeSize)
        }
        .defaultSize(width: 1000, height: 900)
        .windowStyle(.automatic)
        .windowResizability(.contentSize)

        // Pop-out Library Window
        Window("Library", id: "library-window") {
            LibraryWindowView()
                .environmentObject(backend)
                .environmentObject(llmSettings)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(agentStore)
                .environmentObject(conversationStore)
                .environmentObject(sessionStore)
                .environmentObject(studioCoordinator)
                .environmentObject(windowManager)
                .environmentObject(publisherStore)
                .environmentObject(playbackQueue)
                .dynamicTypeSize(dynamicTypeSize)
        }
        .defaultSize(width: 1000, height: 700)
        // ⚠️ NO `.keyboardShortcut` here on purpose. A shortcut on a `Window`
        // scene is the key equivalent of the Window-menu item SwiftUI generates
        // for that scene, and ⌥⌘L is already bound by Window ▸ Pop Out Library,
        // which TOGGLES. Both existed for the whole life of this file, in two
        // different Window menus, so which one ⌥⌘L reached was decided by
        // menu-bar order. The scene item is still there and still opens the
        // window by name; it just no longer claims a key another item owns.
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)

        // Pop-out Studio Window
        Window("Studio", id: "studio-window") {
            StudioWindowView()
                .environmentObject(backend)
                .environmentObject(llmSettings)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(conversationStore)
                .environmentObject(sessionStore)
                .environmentObject(stemSessionStore)
                .environmentObject(studioCoordinator)
                .environmentObject(generationQueue)
                .environmentObject(windowManager)
                .environmentObject(licenseManager)
                .environmentObject(serverPool)
                .environmentObject(modelAvailability)
                .dynamicTypeSize(dynamicTypeSize)
        }
        .defaultSize(width: 1200, height: 800)
        // ⚠️ NO `.keyboardShortcut` here, for the reason written on the Library
        // window above: ⌥⌘S belongs to Window ▸ Pop Out Studio, which toggles.
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)

        // Floating Sterling chat window — the same conversation the Chat tab
        // shows, backed by the same shared stores (not copies), so both views
        // stay in sync and the window is reachable from any tab.
        Window("Sterling", id: SterlingChatWindowView.windowID) {
            SterlingChatWindowView()
                .environmentObject(backend)
                .environmentObject(llmSettings)
                .environmentObject(library)
                .environmentObject(agentStore)
                .environmentObject(conversationStore)
                .environmentObject(studioCoordinator)
                .dynamicTypeSize(dynamicTypeSize)
        }
        .defaultSize(width: 640, height: 720)
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)

        // Help Window
        Window("Majik's Music Studio Help", id: "help-window") {
            HelpView()
                .environmentObject(updateChecker)
                .dynamicTypeSize(dynamicTypeSize)
        }
        .defaultSize(width: 900, height: 700)
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("?", modifiers: .command)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var backend: BackendViewModel?
    var licenseManager: LicenseManager?
    var sessionStore: SessionStore?
    var library: LibraryStore?
    var player: AudioPlayer?
    var updateChecker: UpdateChecker?
    var studioCoordinator: StudioCoordinator?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bring app to front on launch
        NSApp.activate(ignoringOtherApps: true)
        NSApp.setActivationPolicy(.regular)

        // The MCP host. Belongs here, not in a view or the engine factory: the
        // server has to be reachable from the moment the app is up, whether or
        // not anyone ever opens the Studio tab. Fail-closed by construction —
        // with no `--studio-mcp-pat` and the Settings toggle off it returns
        // immediately without even materializing the engine.
        StudioMCPServerModel.shared.bootstrapAtLaunch()

        // Create menu bar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.toolTip = "Majik's Music Studio"
            // Full-color unicorn avatar, downscaled for the menu bar. The
            // source PNG/icns reps are 128px+, so an 18x18pt logical size
            // keeps it crisp on Retina (2x draws from the 36px+ backing).
            if let logo = loadMenuBarIcon() {
                logo.size = NSSize(width: 18, height: 18)
                logo.isTemplate = false  // keep the brand colors, not a mono glyph
                button.image = logo
            } else {
                button.image = NSImage(systemSymbolName: "music.quarternote.3", accessibilityDescription: "Majik's Music Studio")
            }
        }
        // The menu is rebuilt each time it opens (menuNeedsUpdate) so the
        // Now Playing section reflects the live player state. Every action
        // item carries an explicit target: with target/action left nil the
        // responder chain is consulted, which dead-ends when the app has no
        // key window (main window closed) - exactly when the status item
        // matters most.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem?.menu = menu  // click anywhere on the item opens the menu

        // Make sure main window is key and visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let window = self.mainAppWindow() {
                window.level = .normal
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    // MARK: - Status item menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()

        menu.addItem(makeItem("Open Majik's Music Studio", action: #selector(openMainWindowAction)))
        menu.addItem(makeItem("New Track / Generate…", action: #selector(newTrackAction)))
        menu.addItem(makeItem("Chat with Sterling", action: #selector(chatWithSterlingAction)))

        // Now Playing section - only when the player actually has a track.
        if let player, player.currentURL != nil {
            menu.addItem(NSMenuItem.separator())

            let title = player.nowPlaying?.title
                ?? player.currentURL?.deletingPathExtension().lastPathComponent
                ?? "Unknown Track"
            let nowPlayingItem = NSMenuItem(title: "Now Playing: \(title)", action: nil, keyEquivalent: "")
            nowPlayingItem.isEnabled = false
            menu.addItem(nowPlayingItem)

            menu.addItem(makeItem(player.isPlaying ? "Pause" : "Play", action: #selector(togglePlayPauseAction)))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Check for Updates…", action: #selector(checkForUpdatesAction)))
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Majik's Music Studio",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @MainActor @objc private func openMainWindowAction() {
        showMainWindow()
    }

    @MainActor @objc private func newTrackAction() {
        showMainWindow()
        studioCoordinator?.selectedTab = 1  // Create tab
    }

    @MainActor @objc private func chatWithSterlingAction() {
        showMainWindow()
        studioCoordinator?.selectedTab = 0  // Chat tab; the floating popout stays on ⌘⇧S / Pop Out
    }

    @MainActor @objc private func togglePlayPauseAction() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    @MainActor @objc private func checkForUpdatesAction() {
        guard let updateChecker else { return }
        Task { @MainActor in
            await updateChecker.checkForUpdates(silent: false)
        }
    }

    // MARK: - Main window plumbing

    /// The primary WindowGroup window, if AppKit still has it. Filters out
    /// the status-bar item's own window, panels, and the auxiliary SwiftUI
    /// Window scenes (settings/library/studio/help) so "open the app" never
    /// fronts the wrong window.
    private func mainAppWindow() -> NSWindow? {
        let auxiliaryIDs: Set<String> = ["settings-window", "library-window", "studio-window", "help-window", SterlingChatWindowView.windowID]
        return NSApp.windows.first { window in
            guard window.canBecomeMain, !(window is NSPanel) else { return false }
            guard !window.className.contains("NSStatusBarWindow") else { return false }
            if let id = window.identifier?.rawValue,
               auxiliaryIDs.contains(where: { id.hasPrefix($0) }) {
                return false
            }
            return true
        }
    }

    @MainActor @objc func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainAppWindow() {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            // The main window was closed and its scene torn down. Send our
            // own process a "reopen" Apple event - the same thing a Dock
            // click delivers - so SwiftUI recreates the primary WindowGroup
            // window through the normal reopen path.
            let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEReopenApplication),
                targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            _ = try? event.sendEvent(options: [.noReply], timeout: 1.0)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                // Order front the real main window if it survives; otherwise
                // return control to SwiftUI (returning true lets it recreate
                // the primary WindowGroup window).
                self.mainAppWindow()?.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // NOTE ON THE DAW: there is deliberately no "save your project?" prompt
        // here. The Studio project cannot be lost by quitting -- every command
        // is journaled to disk as it is issued -- so a modal asking the user to
        // choose would be teaching a false model and adding a decision they
        // cannot get wrong. The checkpoint is written unattended in
        // `applicationWillTerminate`. The prompt below is about GENERATED
        // TRACKS staged in the Create tab, which genuinely are only in memory.
        guard let sessionStore = sessionStore,
              let library = library else {
            return .terminateNow
        }

        // Check for unsaved tracks (marked for keep but not saved to library)
        guard let session = sessionStore.currentSession else {
            return .terminateNow
        }

        let unsavedTracks = session.stagingTracks.filter { $0.isMarkedForKeep }
        guard !unsavedTracks.isEmpty else {
            return .terminateNow
        }

        let count = unsavedTracks.count
        let alert = NSAlert()
        alert.alertStyle = .warning

        alert.messageText = "Save Tracks Before Quitting?"
        alert.informativeText = """
        You have \(count) track\(count == 1 ? "" : "s") marked to keep that haven't been saved to your library.

        Do you want to save \(count == 1 ? "it" : "them") before quitting?
        """
        alert.addButton(withTitle: "Save & Quit")
        alert.addButton(withTitle: "Quit Without Saving")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:  // Save & Quit
            // The previous implementation blocked the main thread on a
            // semaphore while spawning a Task that awaited a @MainActor
            // method (cancelGeneration). That can deadlock until the 1s
            // timeout fires and still miss the cancel RPC.
            //
            // Use the deferred-reply pattern instead: return .terminateLater
            // and finish the work on the main actor, then call
            // NSApp.reply(toApplicationShouldTerminate:).
            Task { @MainActor in
                if let backend {
                    await backend.cancelGeneration()
                    // Brief settle so the cancel RPC has a chance to land
                    // before we tear down the subprocess.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }

                let libraryTracks = sessionStore.keepSelectedTracks()
                for track in libraryTracks {
                    library.addTrack(track)
                    library.organizeTrack(track)
                }
                // Note: LRC generation is skipped during quit since the process is terminating.
                // LRC files will be generated the next time tracks are saved via the studio UI.
                sessionStore.clearCurrentSession()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater

        case .alertSecondButtonReturn:  // Quit Without Saving
            sessionStore.clearCurrentSession()
            return .terminateNow

        case .alertThirdButtonReturn:  // Cancel
            return .terminateCancel

        default:
            return .terminateCancel
        }
    }

    /// Load the color app icon for the menu bar, trying bundle resources then
    /// development paths. Prefers the 128px PNG (plenty of backing pixels for
    /// an 18pt Retina draw), falls back to the .icns and the asset catalog.
    private func loadMenuBarIcon() -> NSImage? {
        if let resourcePath = Bundle.main.resourcePath {
            let candidates = [
                // Production: bundle resources (copied by build scripts)
                "\(resourcePath)/app-icon-128.png",
                "\(resourcePath)/AppIcon.icns",
                // Development: relative path from bundle to project assets
                "\(resourcePath)/../../../../../assets/icons/app-icon-128.png",
                "\(resourcePath)/../../../../../assets/icons/AppIcon.icns",
            ]
            for path in candidates {
                if let image = ArtworkDecodeCache.image(atPath: path), image.isValid {
                    return image
                }
            }
        }
        // Try named AppIcon from asset catalog
        if let appIcon = NSImage(named: "AppIcon") {
            return appIcon
        }
        return nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Checkpoint the Studio project before the process goes away.
        //
        // The user's WORK is already safe without this -- every command is
        // written through to journal.jsonl at submit time -- so this is not a
        // last-chance rescue and it must never be able to block or fail a quit.
        // What it buys is a current project.json, so the next launch opens from
        // the checkpoint instead of replaying the whole journal.
        //
        // Bounded and synchronous: `applicationWillTerminate` is the last
        // runloop turn there is, so an async Task posted here would never run.
        MainActor.assumeIsolated {
            _ = StudioProjectSaver.shared.saveSynchronouslyForQuit()

            // Flush the LIBRARY too. Unlike the Studio project above, this IS a
            // last-chance rescue: `LibraryStore.updateTrack`, `setRating`,
            // `updateTrackISRC` and `setTrackArtwork` all go through the
            // DEBOUNCED `save()`, which waits 0.5 s of quiet before touching
            // disk. Quitting inside that window silently discarded the edit.
            //
            // `saveImmediately()`'s own doc comment already claimed it was
            // "called from destructive operations (remove, cleanup) and app
            // termination" — the termination half had no caller anywhere in the
            // app. This is that caller.
            //
            // Deliberately here and not as a `willTerminateNotification`
            // observer inside `LibraryStore`: a store constructed by a test
            // would then register too, and on process exit would write its EMPTY
            // track list over the developer's real library.
            library?.saveImmediately()
        }
        backend?.stop()
        // Remove the status item explicitly so the menu bar slot is released
        // immediately (deallocation alone is not guaranteed to do this).
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Stay alive in menu bar; user can reopen via Dock or status item
    }
}
