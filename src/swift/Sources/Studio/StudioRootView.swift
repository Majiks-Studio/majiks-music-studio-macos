import SwiftUI
import AppKit

// MARK: - Studio root
//
// The DAW shell (01-DESIGN section 4): transport on top, browser left,
// timeline center (headers + canvas), inspector right, mixer dock bottom.
// Every panel collapses; the timeline is always the hero.

struct StudioRootView: View {
    @EnvironmentObject var studioCoordinator: StudioCoordinator
    // I1: the tab runs on the real FFI-backed engine when the app links
    // MajiksEngine.xcframework, and on StudioMockEngine otherwise (see
    // StudioEngineFactory). The view model only knows StudioEngineProtocol.
    @StateObject private var model = StudioViewModel(
        engine: StudioEngineFactory.shared,
        microphonePermission: StudioEngineFactory.engineIsReal
            ? AVFoundationMicrophonePermission()
            : AlwaysAuthorizedMicrophonePermission())

    /// E1: the piano roll, on its own small note seam
    /// (StudioNoteEngineProtocol) rather than on StudioEngineProtocol.
    ///
    /// This used to be `StudioMockNoteEngine.demoSession()` — a fabricated
    /// four-bar clip. The roll rendered it perfectly and nothing it edited
    /// reached the project, the journal or the `.mstudio` package. It now runs
    /// on the REAL engine (the same actor the arrangement uses, so a clip UUID
    /// means the same thing in both), falling back to the mock only when the
    /// framework is absent — and `StudioEngineFactory` logs that fallback,
    /// because a silent one is precisely the bug being fixed.
    @StateObject private var pianoRoll = StudioPianoRollController(
        engine: StudioEngineFactory.sharedNote)

    /// The on-screen keyboard: the no-hardware path to "press a key, hear a
    /// note". A customer with no MIDI gear had no way to play an instrument at
    /// all before this existed — the piano roll's gutter is a row label for a
    /// grid, not an instrument. Shown by default on a project with nothing in it,
    /// because that is exactly the person who needs it (see `.onAppear`).
    @StateObject private var keyboard = StudioKeyboardController()

    /// E5: routing + effects. On the SAME engine as the arrangement, so a bus,
    /// a send and a chain slot are the same objects an agent sees on the command
    /// bus, and undo is the one shared history.
    @StateObject private var routing = StudioRoutingController(
        engine: StudioEngineFactory.shared)

    /// First-run coach marks: shown once the first time the Studio has a
    /// project on screen. v2 because the tips themselves changed (discoverability
    /// rewrite — Back/Fwd, volume, effects, seek) and anyone who dismissed the
    /// old three still needs the new ones once. Remembered so they never nag
    /// again after that.
    @AppStorage("studio.coachMarksSeen.v2") private var coachMarksSeen = false
    @State private var showCoachMarks = false

    /// The keyboard auto-shows once, for a first-run empty project. After that
    /// its visibility is the user's decision and is never overridden.
    @AppStorage("studio.keyboardAutoShown.v1") private var keyboardShownOnce = false

    /// How wide / how tall each pane is, persisted in UserDefaults alongside
    /// the flags above. See StudioPaneSizing.swift for the rules and for why
    /// this is a store rather than seven more `@AppStorage` properties.
    @ObservedObject private var paneSizes = StudioPaneSizes.shared

    /// Whether Sterling's dock is open. The dock owns this flag; the shell
    /// reads the SAME key because the dock's divider must not be drawn beside a
    /// 30 pt reopen strip — there would be nothing there to resize. Reading it
    /// here rather than lifting the state keeps the dock a one-line mount, and
    /// `@AppStorage` on one key from two places stays in sync by construction.
    @AppStorage("studio.copilotOpen") private var copilotOpen = true

    /// The workspace's measured size (everything below the transport and record
    /// rows). Feeds the per-drag ceiling, so no pane can be dragged until the
    /// timeline has no room left. Zero until the first layout pass, which
    /// `StudioPaneSizing.available` reads as "not measured", not as "no room".
    @State private var workspaceSize: CGSize = .zero

    /// Whether the "this is not your project" notice has been shown this
    /// session. `.onAppear` runs again on every tab switch, and repeating a
    /// warning the user has already read is nagging, not information — the
    /// condition it reports cannot change without relaunching anyway.
    @State private var announcedEngineFallback = false

    /// Tab tag for the Studio (DAW) tab; must match ContentView's tag.
    static let tabTag = 5

    private var isFrontmost: Bool {
        studioCoordinator.selectedTab == Self.tabTag
    }

    /// True once any project snapshot has landed. Drives the one-time coach
    /// marks: the four things a non-DAW user could not find (Back/Fwd, seek,
    /// volume, effects) are present whether the session came from Generate or
    /// from a blank project, so gating on "generated audio" left the empty-
    /// project path un-tipped.
    private var sessionIsReady: Bool {
        model.snapshot != nil
    }

    // MARK: - Pane sizing helpers
    //
    // The shell is the only thing that knows which panes are on screen, so it
    // is the only thing that can say how much room a drag has left. That sum is
    // what stops a pane swallowing the window: the ceiling is not a constant,
    // it is the workspace minus every other open pane minus the floor the
    // timeline (or the centre column) is owed.

    /// The side rails that are on screen right now.
    private var visibleSidePanes: [StudioPaneSizeSpec] {
        var out: [StudioPaneSizeSpec] = []
        if !model.browserCollapsed { out.append(StudioPaneSizing.browser) }
        if !model.inspectorCollapsed { out.append(StudioPaneSizing.inspector) }
        if copilotOpen { out.append(StudioPaneSizing.copilot) }
        return out
    }

    /// The bottom panes that are on screen right now.
    private var visibleBottomPanes: [StudioPaneSizeSpec] {
        var out: [StudioPaneSizeSpec] = []
        if pianoRoll.isShown { out.append(StudioPaneSizing.pianoRoll) }
        if model.routingShown { out.append(StudioPaneSizing.routing) }
        if !model.mixerCollapsed { out.append(StudioPaneSizing.mixer) }
        if keyboard.isShown { out.append(StudioPaneSizing.keyboard) }
        return out
    }

    /// The most `spec` may be right now, given everything else on screen.
    private func available(for spec: StudioPaneSizeSpec) -> CGFloat {
        let siblings = (spec.axis == .horizontal ? visibleSidePanes : visibleBottomPanes)
            .filter { $0.id != spec.id }
            .reduce(CGFloat.zero) { total, other in
                // Each open sibling costs its own size PLUS the divider band
                // beside it, or the ceiling drifts by a few points per pane.
                total + paneSizes.size(of: other) + StudioTokens.dividerHit
            }
        return StudioPaneSizing.available(
            for: spec, workspace: workspaceSize, otherVisible: siblings)
    }

    /// This pane's size to draw with, clamped by both its own rules and the
    /// room the window has left.
    private func paneSize(_ spec: StudioPaneSizeSpec) -> CGFloat {
        paneSizes.size(of: spec, available: available(for: spec))
    }

    /// The grab handle on one pane's edge.
    private func divider(_ spec: StudioPaneSizeSpec) -> some View {
        StudioPaneDivider(spec: spec, sizes: paneSizes, available: available(for: spec))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                panelToggle(
                    systemImage: "sidebar.left",
                    label: model.browserCollapsed ? "Show browser" : "Hide browser",
                    helpID: model.browserCollapsed ? "toolbar.browser.show" : "toolbar.browser.hide",
                    on: !model.browserCollapsed
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { model.browserCollapsed.toggle() }
                }
                StudioTransportBar(model: model)
                Menu {
                    Button("Audio File…") { chooseAudioFile() }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .studioHelp("toolbar.import")
                // The missing front door. Until this existed there was no way,
                // anywhere in the GUI, to get from an empty project to a MIDI
                // clip: no Track menu, and right-clicking the track area did
                // nothing. The piano roll had nothing it could ever edit.
                //
                // A plain Button, NOT wrapped in a horizontal ScrollView: on
                // macOS that silently eats Button clicks (see SettingsView.swift
                // — it cost this codebase days on the Settings tab strip).
                Menu {
                    Button("Synth") { model.addInstrumentTrack() }
                        .studioHelp("toolbar.instrument.synth")
                    Button("Sampler…") { chooseSamplerTrackSound() }
                        .studioHelp("toolbar.instrument.sampler")
                    Button("Drum Rack…") { chooseDrumRackTrackSounds() }
                        .studioHelp("toolbar.instrument.drumRack")
                } label: {
                    Label("Instrument", systemImage: "pianokeys.inverse")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 38)
                }
                .buttonStyle(.plain)
                .studioHelp("toolbar.instrument")
                .accessibilityLabel("Add instrument track")
                panelToggle(
                    systemImage: "pianokeys",
                    label: pianoRoll.isShown ? "Hide piano roll" : "Show piano roll",
                    helpID: pianoRoll.isShown ? "toolbar.pianoRoll.hide" : "toolbar.pianoRoll.show",
                    on: pianoRoll.isShown
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { pianoRoll.isShown.toggle() }
                }
                // E5: buses, sends, and the effect chain on any track, bus or
                // master. A WORD label, deliberately, not the connected-dots
                // glyph that used to live here. The owner who this app is for
                // opened 3.4.12, used it happily, and still asked "is there an
                // easy way to add other effects or plugins?" — the nine effects
                // were a click away behind an unlabelled glyph. "Keys" in this
                // same strip is the one control he found immediately; words
                // disambiguate where a third network-graph icon cannot. Same
                // styling as Keys and Instrument, so text in this strip is an
                // established idiom. A plain Button, never inside a horizontal
                // ScrollView (that silently eats clicks on macOS).
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.routingShown.toggle() }
                } label: {
                    Text("Effects")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.routingShown ? StudioTokens.text : StudioTokens.faint)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(height: 38)
                }
                .buttonStyle(.plain)
                .studioHelp(model.routingShown ? "toolbar.routing.hide" : "toolbar.routing.show")
                .accessibilityLabel(model.routingShown ? "Hide routing and effects" : "Show routing and effects")
                // The on-screen keyboard toggle: a TEXT label, deliberately,
                // between glyph toggles. SF Symbols has exactly two piano
                // glyphs and both are already in this strip (Instrument =
                // pianokeys.inverse, piano roll = pianokeys); the old glyph
                // here — "keyboard" — is a QWERTY keyboard, which from a couch
                // read as "the piano was removed". Words disambiguate where a
                // third piano icon cannot. Same styling as the Instrument
                // button, so text in this strip is an established idiom.
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { keyboard.toggleShownByUser() }
                } label: {
                    Text("Keys")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(keyboard.isShown ? StudioTokens.text : StudioTokens.faint)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(height: 38)
                }
                .buttonStyle(.plain)
                .studioHelp(keyboard.isShown ? "toolbar.keys.hide" : "toolbar.keys.show")
                .accessibilityLabel(keyboard.isShown ? "Hide the on-screen keyboard" : "Show the on-screen keyboard")
                panelToggle(
                    systemImage: "sidebar.right",
                    label: model.inspectorCollapsed ? "Show inspector" : "Hide inspector",
                    helpID: model.inspectorCollapsed ? "toolbar.inspector.show" : "toolbar.inspector.hide",
                    on: !model.inspectorCollapsed
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { model.inspectorCollapsed.toggle() }
                }
                // How much every control in here explains itself. In the
                // toolbar, not in Settings: a help control nobody can find is
                // the bug this lane exists to fix.
                StudioHelpMenu()
            }
            .frame(height: StudioTransportBar.rowHeight)
            .background(StudioTokens.panel)

            // Record cockpit (L19): slides in below the transport when a track
            // is armed. Zero height otherwise.
            StudioRecordBar(model: model)
                .animation(.easeOut(duration: 0.18), value: model.armedTracks.count)

            // THE WORKSPACE, AND WHO ABSORBS THE SLACK.
            //
            // Every pane in here is now the user's to size, because the right
            // split on a 4K TV at sofa distance is not the right split on a
            // laptop. Two axes, and on each one exactly one view is allowed to
            // be flexible:
            //
            //   HORIZONTAL — browser | centre | inspector | Sterling. The side
            //     rails carry the widths the user drags; the CENTRE column is
            //     the one that absorbs whatever is left, and says so with an
            //     explicit `maxWidth: .infinity`.
            //   VERTICAL — timeline, then the bottom panes that are open. The
            //     bottom panes carry the heights the user drags; the TIMELINE
            //     absorbs the slack, with an explicit `maxHeight: .infinity`.
            //
            // Explicit on both counts because of what happened one commit ago
            // in the row directly above this one: a child left flexible on an
            // axis takes space from its siblings silently, and the symptom is
            // never at the fault (see StudioTransportBar.readout(value:caption:),
            // where flexible `Text` grew the toolbar to ~475 pt and squashed
            // everything down here into the bottom third of the window).
            HStack(spacing: 0) {
                if !model.browserCollapsed {
                    StudioBrowserView(model: model, width: paneSize(StudioPaneSizing.browser))
                    divider(StudioPaneSizing.browser)
                }
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        StudioTrackHeaderColumn(model: model)
                        StudioTimelineCanvas(model: model)
                    }
                    // The vertical slack absorber. Everything below is an
                    // explicit height.
                    .frame(maxHeight: .infinity)
                    if pianoRoll.isShown {
                        divider(StudioPaneSizing.pianoRoll)
                        StudioPianoRollPane(
                            controller: pianoRoll, frameStats: model.frameStats,
                            height: paneSize(StudioPaneSizing.pianoRoll))
                    }
                    if model.routingShown {
                        divider(StudioPaneSizing.routing)
                        StudioRoutingPane(
                            controller: routing,
                            height: paneSize(StudioPaneSizing.routing))
                    }
                    // Only when the mixer is expanded: collapsed, the dock is a
                    // header strip with nothing in it to resize, and a divider
                    // that moves nothing is worse than none.
                    if !model.mixerCollapsed {
                        divider(StudioPaneSizing.mixer)
                    }
                    StudioMixerDock(model: model, stripsHeight: paneSize(StudioPaneSizing.mixer))
                    // Bottom of the stack on purpose: a keyboard belongs at the
                    // near edge, and putting Keep on its rail means "what I am
                    // playing" and "keep it" are in one eyeline.
                    if keyboard.isShown {
                        divider(StudioPaneSizing.keyboard)
                        StudioOnScreenKeyboardPane(
                            controller: keyboard, model: model,
                            height: paneSize(StudioPaneSizing.keyboard))
                    }
                }
                // The horizontal slack absorber. Everything beside it is an
                // explicit width.
                .frame(maxWidth: .infinity)
                if !model.inspectorCollapsed {
                    divider(StudioPaneSizing.inspector)
                    StudioInspectorView(model: model, width: paneSize(StudioPaneSizing.inspector))
                }
                if copilotOpen {
                    divider(StudioPaneSizing.copilot)
                }
                // L14: Sterling console (Cmd+Opt+C)
                StudioCopilotDock(studio: model, panelWidth: paneSize(StudioPaneSizing.copilot))
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: StudioWorkspaceSizeKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(StudioWorkspaceSizeKey.self) { workspaceSize = $0 }
        }
        .background(StudioTokens.bg)
        .overlay(alignment: .top) {
            if model.paletteShown {
                StudioCommandPalette(model: model, pianoRoll: pianoRoll, routing: routing)
                    .padding(.top, 60)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.frameStats.hudVisible {
                StudioFrameHUDView(model: model)
                    .padding(.top, 52)
                    // Follows the inspector's LIVE width, not the token it used
                    // to be pinned to: a widened inspector would otherwise
                    // slide underneath the HUD.
                    .padding(.trailing, model.inspectorCollapsed
                             ? 16
                             : paneSize(StudioPaneSizing.inspector) + StudioTokens.dividerHit + 16)
            }
        }
        .overlay(alignment: .bottom) {
            if showCoachMarks {
                StudioCoachMarksView(isPresented: $showCoachMarks)
            }
        }
        // THE RESULT OF A STUDIO GESTURE, IN THE STUDIO.
        //
        // Toasts had exactly one presenter — ContentView's whole-window overlay
        // — pinned to the TOP CENTRE of the app window, over the tab strip. A
        // right-click on a track header happens at the opposite corner of that
        // window: bottom-left of the timeline area, below the transport and the
        // record bar. On a 1200x900+ window filling a 4K TV that is the better
        // part of a metre away, and the toast lived ~2.4 s at full opacity. It
        // rendered. Nobody could see it. "Remove Instrument did nothing" is what
        // that looks like from the couch.
        //
        // Anchored top-LEADING and offset below the transport strip, which puts
        // it directly above the track header column the gesture came from.
        .overlay(alignment: .topLeading) {
            ToastOverlay(surface: .studio)
                .padding(.leading, 10)
                .padding(.top, 46)
        }
        .overlay {
            if model.landing {
                landingOverlay
            }
        }
        // Splitting takes MINUTES on a full song and downloads the model the
        // first time; and when it refuses it has to say why. Both live in ONE
        // `ViewModifier` rather than as two more clauses here: this body is
        // already at the type-checker's budget and adding them inline tipped it
        // straight into "unable to type-check this expression in reasonable
        // time". Same reason `StudioMenuFreshness` and `StudioCoordinatorBridge`
        // exist.
        .modifier(StudioSeparationSurface(model: model))
        // A landing that fails has to SAY so. The engine refuses honestly when
        // it cannot separate (and its message carries the fix), but nothing
        // read `landingError`, so the overlay just vanished and the arrangement
        // sat unchanged -- indistinguishable from a landing that never ran.
        .alert(
            "Open in Studio failed",
            isPresented: Binding(
                get: { model.landingError != nil },
                set: { if !$0 { model.landingError = nil } }
            )
        ) {
            // help-exempt: macOS gives alert buttons no hover tooltip, and the
            // alert's own message is the explanation.
            Button("OK", role: .cancel) { model.landingError = nil }
        } message: {
            Text(model.landingError ?? "")
        }
        .sheet(isPresented: $model.exportSheetShown) {
            StudioExportDialog(model: model, isPresented: $model.exportSheetShown)
        }
        // The instrument panel: where a sound gets loaded into a sampler or a
        // drum pad. Opened from the track header's instrument chip or its
        // right-click menu, never automatically.
        .sheet(isPresented: Binding(
            get: { model.instrumentPanelTrackID != nil },
            set: { if !$0 { model.instrumentPanelTrackID = nil } }
        )) {
            if let trackID = model.instrumentPanelTrackID {
                StudioInstrumentView(
                    model: model,
                    trackID: trackID,
                    isPresented: Binding(
                        get: { model.instrumentPanelTrackID != nil },
                        set: { if !$0 { model.instrumentPanelTrackID = nil } }))
            }
        }
        .background(shortcutButtons)
        .onChange(of: sessionIsReady) { _, ready in
            // Arm the coach marks the first time ANY project is on screen in
            // the Studio. The discoverability rewrite (Back/Fwd, seek, volume,
            // effects) is for the non-DAW owner, who arrives here with or
            // without generated audio.
            if ready && !coachMarksSeen && isFrontmost {
                showCoachMarks = true
            }
        }
        .onChange(of: showCoachMarks) { _, shown in
            if !shown { coachMarksSeen = true }   // dismissed or skipped: remember
        }
        .modifier(StudioCoordinatorBridge(coordinator: studioCoordinator, model: model))
        .onChange(of: model.newlyCreatedMidiClipID) { _, clipID in
            // A freshly created instrument track opens straight into the roll:
            // "add an instrument" and "now write something on it" are one move.
            guard let clipID else { return }
            model.newlyCreatedMidiClipID = nil
            pianoRoll.open(clipID: clipID)
            withAnimation(.easeOut(duration: 0.15)) { pianoRoll.isShown = true }
        }
        .onChange(of: model.editableMidiClipID) { _, clipID in
            // Selecting a different MIDI clip re-points the roll at it. When
            // it goes nil the clip the roll was editing was deleted (with its
            // track, or alone) and no MIDI clip remains: close the pane
            // rather than render a ghost of notes the project no longer has.
            if let clipID { pianoRoll.open(clipID: clipID) } else { pianoRoll.close() }
        }
        .onChange(of: model.snapshot?.midi?.lastEvent?.seq) { _, _ in
            // A fresh hardware MIDI event. A noteOn while the keyboard pane
            // is hidden SHOWS it (the pane cannot watch for this itself — it
            // is not in the hierarchy while hidden). Auto-show only, never
            // hide; disarmed for the session once the user hides the pane
            // manually. See StudioKeyboardController.observeHardwareEvent.
            keyboard.observeHardwareEvent(model.snapshot?.midi?.lastEvent)
        }
        // Presentation follows the frontmost tab: the Studio draws its own
        // toasts while it is on screen and hands the job straight back when the
        // user leaves, so a toast can never be drawn twice or into a pane
        // nobody is looking at.
        .onChange(of: isFrontmost) { _, front in
            if front {
                ToastManager.shared.claimSurface(.studio)
            } else {
                ToastManager.shared.releaseSurface(.studio)
                // Leaving the Studio is walking away from it. Checkpoint now
                // rather than waiting out the autosave interval.
                StudioProjectSaver.shared.saveOnResignActive()
            }
        }
        // Keep the menu bar's greyed-out states honest. FOUR `.onChange`es in
        // ONE modifier, for the reason `StudioCoordinatorBridge` below records:
        // this body is already at the type-checker's budget, and chaining them
        // here tipped it into "unable to type-check this expression in
        // reasonable time" — measured, not guessed.
        .modifier(StudioMenuFreshness(model: model, pianoRoll: pianoRoll, routing: routing))
        .onChange(of: model.routingShown) { _, shown in
            // Only poll the routing graph while its pane is open: it changes at
            // gesture rate, not at meter rate, and a background poll on a closed
            // pane is a cost with no reader.
            if shown { routing.startPolling() } else { routing.stopPolling() }
        }
        .onAppear {
            model.startPolling()
            // Bind the saver to the engine the tab is ALREADY running on. It
            // never constructs one, so a launch that never opens the Studio
            // still does not touch the .mstudio package.
            StudioProjectSaver.shared.attach(model.engine)
            if isFrontmost { ToastManager.shared.claimSurface(.studio) }
            // If this project had to be REBUILT to open, say so. Reported from
            // the engine the tab is already running on (never by constructing
            // one), one-shot, and silent for an ordinary reopen — see
            // StudioProjectRecovery for the rule and why it exists.
            #if REAL_ENGINE
            StudioProjectRecoveryReporter.shared.report((model.engine as? RealStudioEngine)?.openRecovery)
            #endif
            if model.routingShown { routing.startPolling() }
            // Open on a REAL clip when the project has one. There is deliberately
            // no fallback to a demo clip: an empty project must LOOK empty, or
            // the roll goes back to showing work that does not exist.
            if let clipID = model.editableMidiClipID {
                pianoRoll.open(clipID: clipID)
            }
            pianoRoll.onSeek = { [weak model] ticks in model?.seek(toTicks: ticks) }
            installPreviewHook()
            installTransportHook()
            installMenuBridge()
            installSeparation()
            openAudioForStudio()
            announceEngineFallbackIfNeeded()
            // Show the keyboard unasked on a project with nothing in it. That is
            // exactly the person who cannot otherwise play a note at all, and a
            // playable instrument sitting in front of them is a better answer to
            // "what do I do now" than an empty grid. Once they hide it, it stays
            // hidden.
            if !keyboardShownOnce {
                keyboardShownOnce = true
                keyboard.isShown = (model.snapshot?.tracks.isEmpty ?? true)
            }
            // Baseline the current hardware event WITHOUT acting on it, so a
            // note that arrived before this tab was on screen cannot pop the
            // pane open now; only notes played from here on auto-show it.
            keyboard.seedHardwareEvent(model.snapshot?.midi?.lastEvent)
            handleLaunchArguments()
            if sessionIsReady && !coachMarksSeen && isFrontmost {
                showCoachMarks = true
            }
            // A landing requested from the Library before this tab appeared.
            if let request = studioCoordinator.pendingLanding {
                studioCoordinator.pendingLanding = nil
                Task { await model.land(request) }
            }
            // Same for stems opened from the Stems tab before this tab existed:
            // the .onChange above never fires on the very first appearance.
            if let request = studioCoordinator.pendingStemImport {
                studioCoordinator.pendingStemImport = nil
                Task { await model.importStemSession(request) }
            }
        }
        .onDisappear {
            // The Studio is off screen: it cannot draw a toast, so it must not
            // be the one holding the claim.
            ToastManager.shared.releaseSurface(.studio)
            if isFrontmost == false {
                // Keep polling cheap but alive across tab switches; the
                // 30 Hz loop no-ops on unchanged revisions.
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Studio")
    }

    private func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importAudio(path: url.path) }
    }

    private func chooseSamplerTrackSound() {
        guard let path = StudioSoundPicker.pickOne(
            prompt: "Pick a recording to play across the keyboard.") else { return }
        model.addSamplerTrack(path: path)
    }

    private func chooseDrumRackTrackSounds() {
        let paths = StudioSoundPicker.pickMany(
            prompt: "Pick up to \(StudioDrumRack.padCount) sounds, one per pad.")
        guard !paths.isEmpty else { return }
        model.addDrumRackTrack(paths: paths)
    }

    /// Shown while the landing pipeline runs (analysis + separation + placement).
    private var landingOverlay: some View {
        ZStack {
            StudioTokens.bg.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(StudioTokens.cyan)
                Text("Opening in Studio")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StudioTokens.text)
                Text("Finding the beat, splitting the stems, laying out the bars.")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTokens.dim)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 16).fill(StudioTokens.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioTokens.stroke, lineWidth: 1))
        }
        .transition(.opacity)
    }

    private func panelToggle(
        systemImage: String,
        label: String,
        helpID: String,
        on: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? StudioTokens.text : StudioTokens.faint)
                .frame(width: 30, height: 38)
        }
        .buttonStyle(.plain)
        // Every icon-only toggle earns a tooltip: a bare 11 pt glyph is
        // guesswork from any distance. The catalog entry says what the pane is
        // FOR, which "Show browser" never did.
        .studioHelp(helpID)
        .accessibilityLabel(label)
    }

    /// Cmd shortcuts live on real (invisible) buttons so they work whatever
    /// has focus, but only act while Studio is the frontmost tab. The Revise
    /// audition keys (1-9, A, Return) exist ONLY while auditioning, when no text
    /// field is on screen, so they never fight the instruction field.
    private var shortcutButtons: some View {
        Group {
            Group {
                Button("") { guard isFrontmost else { return }; model.splitAtPlayhead() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("") { guard isFrontmost else { return }; model.duplicateSelection() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("") { guard isFrontmost else { return }; model.paletteShown.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                // Cmd+R: record. Toggles start / stop / cancel-count-in; a no-op
                // unless a track is armed. Available whenever Studio is frontmost.
                Button("") { guard isFrontmost else { return }; model.toggleRecord() }
                    .keyboardShortcut("r", modifiers: .command)
                // Esc: discard an audition, else clear the selection.
                Button("") {
                    guard isFrontmost else { return }
                    if model.audition != nil { model.discardAudition() } else { model.clearSelection() }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            // Revise / extend / layer starters (only before an audition begins).
            if model.audition == nil {
                Group {
                    Button("") {
                        guard isFrontmost, model.selection.region != nil else { return }
                        model.armReviseForSelection()
                    }
                    .keyboardShortcut("r", modifiers: [])
                    Button("") {
                        guard isFrontmost, !model.reviseArmed else { return }
                        model.extendSelection()
                    }
                    .keyboardShortcut("e", modifiers: [])
                    Button("") {
                        guard isFrontmost else { return }
                        model.addLayerForSelection()
                    }
                    .keyboardShortcut("r", modifiers: .shift)
                }
            }
            // Audition keys: live only while a revise is auditioning.
            if model.audition != nil {
                Group {
                    ForEach(1...9, id: \.self) { n in
                        Button("") { guard isFrontmost else { return }; model.auditionKey(n) }
                            .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
                    }
                    Button("") { guard isFrontmost else { return }; model.auditionOriginal() }
                        .keyboardShortcut("a", modifiers: [])
                    Button("") { guard isFrontmost else { return }; model.commitAudition() }
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Wire the roll's audition hook to the real instrument, so pressing a
    /// gutter key or drawing a note MAKES A SOUND. It shipped as `nil`, which
    /// meant the piano roll had no audible feedback at all — for a piano roll
    /// that is not a nice-to-have, it is the primary feedback loop.
    ///
    /// AUDIO SAFETY (house rule, absolute): this never opens the output device.
    /// The engine's audition verb reports "not audible, and here is why" when no
    /// live session is running, and refuses to start one; opening the device
    /// stays an explicit user action (transport play). So drawing notes in a
    /// freshly launched app is silent by design, not by accident.
    private func installPreviewHook() {
        #if REAL_ENGINE
        guard let engine = StudioEngineFactory.sharedNote as? RealStudioEngine else { return }
        let controller = pianoRoll
        controller.onPreview = { [weak controller] pitch, velocity in
            let trackID = controller?.clip?.trackID
            Task {
                let outcome = await engine.previewNote(
                    trackID: trackID, pitch: pitch, velocity: velocity)
                // THE surface this fix is for. The gutter names a track — the
                // clip's — so unlike the on-screen keyboard it can land on one
                // with no instrument device, and the engine's "the track has no
                // instrument device" is exactly what used to go nowhere.
                await StudioSilentPreviewReporter.shared.report(outcome, gate: .oneShot)
            }
        }
        // ONE note path. The on-screen keyboard reaches the instrument through
        // exactly the call the roll's gutter and the hardware MIDI pump use, so
        // a screen key and a cable key sound the same, are buffered by the same
        // retro-capture buffer, and are kept by the same Keep. A second parallel
        // path is how the two halves of E1 drifted apart.
        //
        // `trackID: nil` deliberately: the engine picks the instrument (the armed
        // one, else the first, else a newly created one), which is the same rule
        // a MIDI key already followed. The on-screen keyboard is not editing a
        // particular clip, so it has no business naming a track.
        keyboard.onNote = { pitch, velocity, gate in
            Task {
                let outcome = await engine.previewNote(
                    trackID: nil, pitch: pitch, velocity: velocity, gate: gate)
                // The keyboard shares the path, so it shares the fix — but not
                // the same reasons. `trackID: nil` sends the engine down
                // `midi_instrument_target`, which only ever returns a track
                // that HAS a device, so "the track has no instrument device"
                // cannot arise here; what can is the auto-create hold-off
                // ("you just undid the instrument that was created for you"),
                // which was being swallowed on exactly the same line. Same
                // reporter, so a chord played from here is still one message,
                // and playing the same silent track from the keys and then the
                // gutter does not say it twice.
                await StudioSilentPreviewReporter.shared.report(outcome, gate: gate)
            }
        }
        #endif
    }

    /// Tell the user when the project on screen is NOT theirs.
    ///
    /// When `RealStudioEngine` cannot open the package — corrupt checkpoint,
    /// broken hash chain, permissions — `StudioEngineFactory` falls back to
    /// `StudioMockEngine`, and that is not an empty stand-in: its own header
    /// calls it "the L5 performance-gate fixture: exactly 8 tracks and 100
    /// clips". So the failure mode was a fully populated, fully interactive
    /// project that belonged to nobody, presented as the user's work, with the
    /// only trace an `NSLog` in Console.app. Every edit made in it then reaches
    /// no package at all.
    ///
    /// A TOAST rather than an alert, and `.actionable` rather than the default
    /// lifetime: it is the same judgement `announceTracksTheAppMadeItself` makes
    /// — the user is looking at the arrangement, and a modal at launch is worse
    /// than a sentence they can read and act on. It is deliberately the WARNING
    /// style: this is not a success and must not look like one.
    ///
    /// Reading `engineFallbackReason` materializes `shared`, which the view model
    /// already did when it was constructed, so this adds no work and cannot be
    /// the thing that decides which engine runs.
    private func announceEngineFallbackIfNeeded() {
        guard !announcedEngineFallback,
              let reason = StudioEngineFactory.engineFallbackReason else { return }
        announcedEngineFallback = true
        ToastManager.shared.show(
            StudioEngineFactory.fallbackNotice(reason: reason),
            style: .warning, seconds: ToastDuration.actionable)
    }

    /// Bring the audio output up because the user opened the DAW.
    ///
    /// This is the deliberate moment. Opening the Studio tab is a person saying
    /// "I am here to make music", and every DAW opens its audio device when a
    /// project opens. Doing it here rather than on the first key press means the
    /// FIRST note is instant instead of waiting on a ~50-200 ms device open; the
    /// engine still opens the device on a played note as a backstop, for a key
    /// that arrives before this tab was ever visited.
    ///
    /// AUDIO SAFETY: this opens an OUTPUT stream and nothing else. An idle output
    /// stream renders silence — it is not a monitor path, there is no microphone
    /// in it, and no feedback loop can form. `swift test` constructs the engine
    /// with `audible: false` (`StudioEngineFactory.audibleByDefault`), so a test
    /// run stays silent. Live MICROPHONE monitoring remains refused in the engine
    /// (`render::recording::monitoring_allowed`), untouched.
    private func openAudioForStudio() {
        #if REAL_ENGINE
        guard let engine = StudioEngineFactory.shared as? RealStudioEngine else { return }
        Task { await engine.ensureLive() }
        #endif
    }

    /// Space is owned by the app-wide Play/Pause menu command; while the
    /// Studio tab is frontmost this hook lets Studio's transport take it
    /// (same pattern the Stems tab uses via stemTransportToggle).
    private func installTransportHook() {
        studioCoordinator.dawTransportToggle = { [weak model, weak studioCoordinator] in
            guard let model, let studioCoordinator,
                  studioCoordinator.selectedTab == Self.tabTag else { return false }
            model.togglePlayback(viewportWidth: model.timelineViewportWidth)
            return true
        }
    }

    /// Hand the macOS menu bar a way to see and drive this Studio.
    ///
    /// The Song / Track / Clip / Transport menus are declared at App scope in
    /// `Main.swift`, four levels above these `@StateObject`s, so there is no way
    /// for a `CommandMenu` to reach them by reading the view tree. The Studio
    /// pushes UP instead — the same arrangement `installTransportHook` already
    /// uses for the spacebar, one step larger: a closure that vends the live
    /// `StudioPaletteContext`, which is the one object the menus need in order
    /// to know both whether an item can run and what to send.
    ///
    /// Deliberately NOT `[weak self]`: this is a struct view. The closure holds
    /// the three `@StateObject`s, whose lifetime is the tab's, and the bridge is
    /// a singleton that outlives one appearance — which is correct here, because
    /// the menus must keep working while the user is on another tab.
    private func installMenuBridge() {
        StudioMenuBridge.shared.install {
            StudioPaletteContext(model: model, pianoRoll: pianoRoll, routing: routing)
        }
    }

    /// Give the Studio the two things "Split a Song into Stems" needs: what
    /// separates, and how to ask which song.
    ///
    /// Both are handed IN rather than reached for, and for different reasons.
    /// The separator comes through the coordinator because observing
    /// `BackendViewModel` from this view would republish the whole DAW body on
    /// every backend tick. The chooser is a closure because an `NSOpenPanel`
    /// opened from inside the view model would make the gesture undriveable
    /// from a test — a modal panel in a test run hangs the bundle — and this
    /// gesture is one where "the menu item did nothing" has to be provable.
    ///
    /// Re-run on every appearance, so a Studio tab opened before the backend
    /// finished starting picks the separator up the next time it comes forward
    /// rather than staying refused for the session.
    private func installSeparation() {
        model.stemSeparator = studioCoordinator.stemSeparator
        model.songChooser = {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.audio]
            panel.message = "Choose a song to split into vocals, drums, bass and everything else"
            panel.prompt = "Split"
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    /// Debug and evidence hooks. Inert unless the matching argument is passed.
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--studio-hud") {
            model.frameStats.hudVisible = true
        }
        if args.contains("--studio-perf-sweep") {
            Task { @MainActor in
                // Let the first snapshot + window layout land first.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                model.runPerfSweep(viewportWidth: model.timelineViewportWidth)
            }
        }
        if args.contains("--studio-open-mixer") {
            model.mixerCollapsed = false
        }
        // I1 proof hook: drive the transport against the real engine hands-free.
        // On the real engine this opens the (silence-gated) live audio session
        // and plays, so the play head advances against the real clock.
        if args.contains("--studio-autoplay") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                model.togglePlayback(viewportWidth: model.timelineViewportWidth)
            }
        }
        // Evidence hook: preselect a bar region (1-based, inclusive), e.g.
        // --studio-select-bars 33 48. Same result as dragging the ruler.
        if let flagIndex = args.firstIndex(of: "--studio-select-bars"),
           args.count > flagIndex + 2,
           let firstBar = Int(args[flagIndex + 1]),
           let lastBar = Int(args[flagIndex + 2]),
           firstBar >= 1, lastBar >= firstBar {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                let grid = model.barGrid
                model.selection.clipIDs.removeAll()
                model.selection.region = StudioRegionSelection(
                    rawStart: grid.tickForBarIndex(Int64(firstBar - 1)),
                    rawEnd: grid.tickForBarIndex(Int64(lastBar)))
                model.scrollTicks = max(0, grid.tickForBarIndex(Int64(firstBar - 3)))
                model.armReviseForSelection()
            }
        }
    }
}


// MARK: - Frame-time HUD (debug evidence for the 60 fps gate)

struct StudioFrameHUDView: View {
    @ObservedObject var model: StudioViewModel
    @ObservedObject private var stats: StudioFrameStats

    init(model: StudioViewModel) {
        self.model = model
        self.stats = model.frameStats
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(alignment: .leading, spacing: 4) {
                Text("FRAME TIME (FULL-RATE SAMPLES)")
                    .font(.system(size: 8, weight: .heavy))
                    .kerning(1)
                    .foregroundStyle(StudioTokens.faint)
                Text(stats.summary()?.display ?? "play, drag, or sweep to sample")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StudioTokens.text)
                if let summary = stats.summary() {
                    Text(summary.drawCostDisplay)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(StudioTokens.dim)
                }
                if model.sweepActive {
                    Text("sweep running")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StudioTokens.warn)
                } else if let sweep = stats.lastSweepSummary {
                    Text("sweep: \(sweep.display)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(StudioTokens.good)
                    Text("sweep " + sweep.drawCostDisplay)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(StudioTokens.good)
                }
            }
            .padding(8)
            .background(StudioTokens.panel.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTokens.stroke, lineWidth: 1))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Coordinator bridge

/// The two "another tab asked the Studio for something" hand-offs, in ONE
/// modifier.
///
/// One modifier rather than two `.onChange`es because `StudioRootView.body` is
/// already at the type-checker's budget — adding a second chained modifier tips
/// it into "unable to type-check this expression in reasonable time". Both
/// bridges are the same shape anyway: read a `@Published` request off the
/// coordinator, clear it, run it.
///
/// Clearing before running matters. These are one-shot requests, and a request
/// left in place is re-consumed by the `.onAppear` path the next time this tab
/// is shown — which is how "Open in Studio" would import the same four stems
/// twice.
private struct StudioCoordinatorBridge: ViewModifier {
    @ObservedObject var coordinator: StudioCoordinator
    @ObservedObject var model: StudioViewModel

    func body(content: Content) -> some View {
        content
            .onChange(of: coordinator.pendingLanding) { _, request in
                // The user chose "Open in Studio" on a song: run the landing
                // here, then the fresh session appears and the coach marks arm.
                guard let request else { return }
                coordinator.pendingLanding = nil
                Task { await model.land(request) }
            }
            .onChange(of: coordinator.pendingStemImport) { _, request in
                // "Open in Studio" from the STEMS tab. Deliberately not a
                // landing: these files are already separated parts, so they go
                // straight onto tracks rather than back through analysis and
                // separation. Running htdemucs over a vocal stem to obtain a
                // vocal stem would be minutes of GPU time for nothing.
                guard let request else { return }
                coordinator.pendingStemImport = nil
                Task { await model.importStemSession(request) }
            }
    }
}
// MARK: - Splitting a song, as the Studio shows it
//
// Progress and refusal for `StudioViewModel.separateIntoStemTracks`, in one
// `ViewModifier` rather than as two more clauses on `StudioRootView.body` —
// that body is already at the type-checker's budget and adding them inline
// produced "unable to type-check this expression in reasonable time", which is
// a compile error that names no line you wrote.

/// The two things a split owes the person: that it is happening, and why it
/// could not.
struct StudioSeparationSurface: ViewModifier {
    @ObservedObject var model: StudioViewModel

    func body(content: Content) -> some View {
        content
            .overlay {
                if model.separating { overlay }
            }
            .alert("Could not split that song", isPresented: alertShown) {
                // help-exempt: macOS gives alert buttons no hover tooltip, and
                // the alert's own message IS the explanation — here the
                // separator's verbatim refusal, which names the interpreter and
                // the package that is missing.
                Button("OK", role: .cancel) { model.separationError = nil }
            } message: {
                Text(model.separationError ?? "")
            }
    }

    private var alertShown: Binding<Bool> {
        Binding(
            get: { model.separationError != nil },
            set: { if !$0 { model.separationError = nil } })
    }

    /// Says how long AND why the first one is slower, because "a few minutes"
    /// is the difference between waiting and force-quitting.
    private var overlay: some View {
        ZStack {
            StudioTokens.bg.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(StudioTokens.cyan)
                Text("Splitting the song into its parts")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StudioTokens.text)
                Text(model.separationStatus ?? StemSeparationRun.runningLine)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTokens.dim)
                    .multilineTextAlignment(.center)
                    // Vertical growth only: a bare `fixedSize()` here would
                    // refuse to shrink and shove the panel past the window.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 16).fill(StudioTokens.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioTokens.stroke, lineWidth: 1))
        }
        .transition(.opacity)
    }
}
