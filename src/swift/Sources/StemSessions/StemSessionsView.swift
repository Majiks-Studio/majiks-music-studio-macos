import SwiftUI
import UniformTypeIdentifiers

// MARK: - Stems Tab (S1 — Stem Sessions)

/// Session list + stem mixer editor. Sessions come from StemSessionStore;
/// audio runs through a tab-local StemEngine. The store owns the document
/// (undoable); the engine mirrors it (volumes re-applied on any change,
/// graph rebuilt only when the stem file set changes).
struct StemSessionsView: View {
    @EnvironmentObject var stemSessionStore: StemSessionStore
    @EnvironmentObject var studioCoordinator: StudioCoordinator
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var library: LibraryStore
    @Environment(\.undoManager) private var undoManager

    @StateObject private var engine = StemEngine()

    /// The app-wide separation run. `@ObservedObject` on the shared instance,
    /// not a `@StateObject` of our own: a split started from the Library has to
    /// show its progress HERE, because that is where the person was sent.
    @ObservedObject private var separation = StemSeparationRun.shared

    @State private var selectedSessionID: UUID?
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var deleteTargetID: UUID?
    /// Set when a bounce finishes → offers "Add to Library" (with provenance).
    @State private var completedBounce: CompletedBounce?

    private struct CompletedBounce {
        let sessionID: UUID
        let url: URL
    }

    private var selectedSession: StemSessionDocument? {
        selectedSessionID.flatMap { stemSessionStore.session(id: $0) }
    }

    /// Changes when stems are added/removed/replaced → full engine reload.
    private var stemFileSignature: [String] {
        selectedSession?.stems.map(\.fileName) ?? []
    }

    /// Changes on any gain/mute/solo/pan/master edit → volume-only re-apply.
    private var mixSignature: [String] {
        guard let doc = selectedSession else { return [] }
        var signature = doc.stems.map { "\($0.id.uuidString)|\($0.gainDB)|\($0.muted)|\($0.solo)|\($0.pan)" }
        signature.append("master|\(doc.masterGainDB)")
        return signature
    }

    var body: some View {
        HSplitView {
            sessionSidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            Group {
                if let doc = selectedSession {
                    StemSessionEditorView(
                        document: doc,
                        engine: engine,
                        onAddStems: { addStemsFromFiles(to: doc) },
                        onBounce: { bounceSession(doc) },
                        onOpenInStudio: { stems in openInStudio(stems, from: doc) }
                    )
                } else {
                    noSelectionPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            consumePendingSessionID()
            if selectedSessionID == nil {
                selectedSessionID = stemSessionStore.sessions.first?.id
            }
            reloadEngine()
            // Spacebar (global Play/Pause command) drives the stem transport
            // while this tab is selected; the coordinator gates on the tab.
            studioCoordinator.stemTransportToggle = { [weak engine] in
                guard let engine, engine.loadedStemCount > 0, !engine.isBouncing else { return false }
                if engine.isPlaying {
                    engine.pause()
                } else {
                    engine.play()
                }
                return true
            }
        }
        .onDisappear {
            studioCoordinator.stemTransportToggle = nil
        }
        .onChange(of: studioCoordinator.pendingStemSessionID) { _, _ in
            consumePendingSessionID()
        }
        .onChange(of: selectedSessionID) { _, _ in
            reloadEngine()
        }
        .onChange(of: stemFileSignature) { _, _ in
            reloadEngine()
        }
        .onChange(of: mixSignature) { _, _ in
            // Parameter-only change (incl. undo/redo): re-apply volumes, never
            // rebuild the graph — playback continues glitch-free.
            if let doc = selectedSession {
                engine.applyMix(from: doc)
            }
        }
        .onChange(of: engine.isPlaying) { _, playing in
            // Courtesy: don't fight the app-wide track player.
            if playing && player.isPlaying {
                player.pause()
            }
        }
        .onChange(of: player.isPlaying) { _, playing in
            // Symmetric courtesy: starting the app-wide track player (e.g.
            // spacebar on another tab) pauses the stem transport instead of
            // letting both render at once.
            if playing && engine.isPlaying {
                engine.pause()
            }
        }
        .onChange(of: stemSessionStore.lastError) { _, newError in
            if let error = newError {
                ToastManager.shared.show(error, style: .warning)
                stemSessionStore.clearLastError()
            }
        }
        .alert("Rename Session", isPresented: renameAlertBinding) {
            // help-exempt: alert buttons get no hover tooltip on macOS, and the
            // alert's own title and message are the explanation. Applies to
            // every Button in the three alerts below.
            TextField("Session name", text: $renameText)
            Button("Rename") {
                if let id = renameTargetID {
                    stemSessionStore.renameSession(id: id, to: renameText, undoManager: undoManager)
                }
                renameTargetID = nil
            }
            Button("Cancel", role: .cancel) { renameTargetID = nil }
        }
        .alert("Delete Stem Session?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) {
                if let id = deleteTargetID {
                    if selectedSessionID == id {
                        engine.unload()
                        selectedSessionID = nil
                    }
                    stemSessionStore.deleteSession(id: id)
                }
                deleteTargetID = nil
            }
            Button("Cancel", role: .cancel) { deleteTargetID = nil }
        } message: {
            Text("This deletes the session and its copied stem audio files. This cannot be undone.")
        }
        // A SPLIT THAT REFUSES HAS TO SAY WHY, and it has to still be readable
        // when the person comes back to the tab. Separation legitimately fails
        // — demucs is not installed until the first run fetches it — and the
        // refusal carries the interpreter, the missing package and the pip
        // line. An alert rather than a toast: a toast lives 2.4 s in the far
        // corner of a 4K TV, and this message is four lines the person has to
        // act on.
        .alert("Could not split that song", isPresented: separationAlertBinding) {
            // help-exempt: macOS gives alert buttons no hover tooltip, and the
            // alert's own message is the explanation.
            Button("OK", role: .cancel) { separation.failure = nil }
        } message: {
            Text(separation.failure ?? "")
        }
        .alert("Bounce Complete", isPresented: bounceAlertBinding, presenting: completedBounce) { bounce in
            Button("Add to Library") { addBounceToLibrary(bounce) }
            Button("Done", role: .cancel) { completedBounce = nil }
        } message: { bounce in
            Text("Saved \(bounce.url.lastPathComponent). Add a copy to your Library with the session's full provenance?")
        }
    }

    // MARK: - Sidebar

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Stem Sessions")
                    .font(.headline)
                Spacer()
                Button(action: createSession) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .studioHelp("stems.session.new")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // THE THING THE OWNER CAME HERE FOR.
            //
            //   "We don't have the ability to break out an audio file to
            //    different stems? I don't see that option in the stems section"
            //
            // He was right that it was not here. Separation worked the whole
            // time — htdemucs, real four-part output — but the only way to ask
            // for it was a generation mode in the CREATE tab that acted on a
            // song you had just generated, followed by an "open as stem
            // session" hand-off across two tabs that nobody would guess. This
            // pane's own empty state admitted it and sent you away.
            //
            // A WORD, prominent, full width, above the fold. Not a glyph in the
            // header row beside the +: this codebase has now shipped three
            // features that were reported missing because they were behind an
            // unlabelled icon (the on-screen keyboard, delete-track, add
            // instrument), and this is read from a sofa across a 4K TV.
            //
            // Never inside a horizontal ScrollView: on macOS that silently eats
            // Button clicks, and it has cost this codebase days twice.
            Button(action: separateSongFromFile) {
                Label(StemSeparation.verb, systemImage: "wand.and.rays")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.purple)
            .disabled(separation.isRunning)
            .studioHelp("stems.separate")
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if separation.isRunning {
                separationProgress
            }

            Divider()

            if stemSessionStore.sessions.isEmpty {
                emptySidebarPlaceholder
            } else {
                List(selection: $selectedSessionID) {
                    ForEach(stemSessionStore.sessions) { session in
                        sessionRow(session)
                            .tag(session.id)
                            .contextMenu {
                                // help-exempt: macOS menu items get no hover
                                // tooltip; the teaching for what a session IS
                                // rides `stems.session.new`.
                                Button("Rename…") {
                                    renameText = session.name
                                    renameTargetID = session.id
                                }
                                Divider()
                                Button("Delete…", role: .destructive) {
                                    deleteTargetID = session.id
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func sessionRow(_ session: StemSessionDocument) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption2)
                Text("\(session.stems.count) stem\(session.stems.count == 1 ? "" : "s")")
                    .font(.caption)
                Text("·")
                    .font(.caption)
                Text(session.updatedAt, style: .date)
                    .font(.caption)
            }
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var emptySidebarPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [.blue.opacity(0.6), .purple.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "slider.horizontal.3")
                        .font(.title2)
                        .foregroundColor(.white)
                )
            Text("No Stem Sessions")
                .font(.headline)
            // This sentence used to read "Create one here, or extract stems in
            // the Studio and open them as a session." — a pane apologising and
            // pointing at another tab, for a capability that was two tabs away
            // behind a generation mode called "Extract Stems". It now offers
            // the thing, and says what you will get.
            Text("Pick a song and it comes back as four parts you can hear on their own — the singing, the drums, the bass, and everything else.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
            Button(action: separateSongFromFile) {
                Label(StemSeparation.verb, systemImage: "wand.and.rays")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.purple)
            .disabled(separation.isRunning)
            .studioHelp("stems.separate.empty")
            // Still offered, one rung down: an empty session you fill from
            // files of your own is a different job from splitting a song, and
            // it was the only thing this screen could do before.
            Button("New Empty Session", action: createSession)
                .buttonStyle(.bordered)
                .studioHelp("stems.session.new.empty")
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Shown while a split runs — which is MINUTES, and longer the first time
    /// because the model downloads itself then.
    ///
    /// An indeterminate bar rather than a percentage, deliberately: demucs
    /// reports no progress the app can read, and a fake percentage that jumps
    /// 0 -> 100 is a lie the moment somebody watches it. What the sentence CAN
    /// promise honestly is how long, why the first one is slower, and that the
    /// app still works — which is the difference between waiting and force-
    /// quitting.
    private var separationProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Splitting…")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            Text(separation.status ?? StemSeparationRun.runningLine)
                .font(.caption2)
                .foregroundColor(.secondary)
                // Vertical growth only. An unconstrained Text in a narrow
                // sidebar wraps to one character per line; `fixedSize()` with
                // no axis refuses to shrink and shoves its neighbours off
                // screen. Both have shipped here.
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var noSelectionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 44))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text("Select a stem session")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Every part of the song on its own lane: hear just the vocal, or the song without it, set each part's level, then bounce the result to one file or open the set in the Studio.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Alert Bindings

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTargetID != nil },
            set: { if !$0 { renameTargetID = nil } }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { deleteTargetID != nil },
            set: { if !$0 { deleteTargetID = nil } }
        )
    }

    private var separationAlertBinding: Binding<Bool> {
        Binding(
            get: { separation.failure != nil },
            set: { if !$0 { separation.failure = nil } }
        )
    }

    private var bounceAlertBinding: Binding<Bool> {
        Binding(
            get: { completedBounce != nil },
            set: { if !$0 { completedBounce = nil } }
        )
    }

    // MARK: - Actions

    private func createSession() {
        let doc = stemSessionStore.createSession(name: "New Stem Session")
        selectedSessionID = doc.id
    }

    /// Choose a song and split it, right here.
    ///
    /// The separator itself comes from the coordinator (installed once at
    /// launch from the app's Python backend) rather than from an
    /// `@EnvironmentObject` on this view. That is not fastidiousness:
    /// `BackendViewModel` republishes throughout every generation, and
    /// observing it from a whole tab body would invalidate this pane's layout
    /// on every one of those ticks — the same defect that had `ContentView`
    /// paying a blocking keychain round trip per 100 ms player tick.
    ///
    /// The work runs in a `Task` and the run object publishes the progress, so
    /// nothing here blocks the main actor for the several minutes htdemucs
    /// takes on a full song.
    private func separateSongFromFile() {
        guard let separator = studioCoordinator.stemSeparator else {
            separation.failure = StemSeparationRun.noSeparatorReason
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a song to split into vocals, drums, bass and everything else"
        panel.prompt = "Split"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let title = url.deletingPathExtension().lastPathComponent
        Task {
            let id = await separation.separateIntoSession(
                source: url,
                title: title,
                using: separator,
                store: stemSessionStore,
                coordinator: studioCoordinator,
                outputRoot: FileStore.shared.baseDirectory)
            if let id { selectedSessionID = id }
        }
    }

    /// The route OUT of this tab, which did not exist before.
    ///
    /// The Stems tab and the Studio were two views of the same parts of the
    /// same song with no way to get from one to the other: a balance found
    /// here could not be arranged, and an arrangement could not be re-balanced
    /// here. Each stem lands on its OWN track under its own name via the
    /// journalled `track.add` + `import.audio` pair — no new command, and
    /// undoable in the Studio like any other import.
    ///
    /// Missing files are dropped rather than handed over: importing a path
    /// that is not there produces an empty track and a confusing error two
    /// tabs away from the stem it came from.
    private func openInStudio(_ stems: [SessionStem], from doc: StemSessionDocument) {
        let playable = stems.filter { !engine.missingStemIDs.contains($0.id) }
        guard !playable.isEmpty else {
            ToastManager.shared.show(
                "Those stems' audio files are missing, so there is nothing to open.", style: .warning)
            return
        }
        let request = StudioStemImportRequest(
            sessionName: doc.name,
            stems: playable.map {
                StudioStemImportRequest.Stem(
                    name: $0.displayName,
                    path: stemSessionStore.audioURL(for: $0).path
                )
            }
        )
        if playable.count < stems.count {
            ToastManager.shared.show(
                "Opening \(playable.count) of \(stems.count) stems — the rest are missing their audio.",
                style: .warning)
        }
        studioCoordinator.openStemsInStudio(request)
    }

    private func consumePendingSessionID() {
        guard let pending = studioCoordinator.pendingStemSessionID else { return }
        selectedSessionID = pending
        studioCoordinator.pendingStemSessionID = nil
    }

    private func reloadEngine() {
        guard let doc = selectedSession else {
            engine.unload()
            return
        }
        engine.loadStems(doc.stems.map { (stemID: $0.id, url: stemSessionStore.audioURL(for: $0)) })
        engine.applyMix(from: doc)
    }

    private func addStemsFromFiles(to doc: StemSessionDocument) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose audio files to add as stems"
        panel.prompt = "Add Stems"

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            do {
                let added = try stemSessionStore.addStems(fileURLs: panel.urls, to: doc.id, undoManager: undoManager)
                ToastManager.shared.show("Added \(added.count) stem\(added.count == 1 ? "" : "s")", style: .success)
            } catch {
                ToastManager.shared.show("Could not add stems: \(error.localizedDescription)", style: .error)
                AppLog.error("Add stems failed: \(error)")
            }
        }
    }

    private func bounceSession(_ doc: StemSessionDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav, .mpeg4Audio]
        panel.nameFieldStringValue = "\(doc.name).wav"
        panel.message = "Bounce \"\(doc.name)\" to a mixed audio file (.wav lossless or .m4a AAC)"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await engine.bounce(to: url, mix: doc)
                    stemSessionStore.recordBounce(sessionID: doc.id, destination: url)
                    completedBounce = CompletedBounce(sessionID: doc.id, url: url)
                } catch {
                    ToastManager.shared.show("Bounce failed: \(error.localizedDescription)", style: .error)
                    AppLog.error("Bounce failed: \(error)")
                }
            }
        }
    }

    /// Copies the bounced mix into the Audio library tree and registers it as
    /// a Track carrying the session's provenance (origin-op history + every
    /// stem's mix position and generation parameters). The file copy runs off
    /// the main actor — bounces can be large.
    private func addBounceToLibrary(_ bounce: CompletedBounce) {
        completedBounce = nil
        // Re-read the document so the provenance includes the bounce op itself.
        guard let doc = stemSessionStore.session(id: bounce.sessionID) else {
            ToastManager.shared.show("Could not add to Library: the stem session no longer exists.", style: .error)
            return
        }
        let audioDirectory = FileStore.shared.audioDirectory
        let bounceURL = bounce.url
        Task {
            do {
                let track = try await Task.detached(priority: .userInitiated) {
                    try StemSessionLibraryExport.makeTrack(
                        from: doc,
                        bounceURL: bounceURL,
                        audioDirectory: audioDirectory
                    )
                }.value
                library.addTrack(track)
                stemSessionStore.recordAddedToLibrary(sessionID: doc.id, trackTitle: track.title)
                ToastManager.shared.show("Added \"\(track.title)\" to Library", style: .success)
            } catch {
                ToastManager.shared.show("Could not add to Library: \(error.localizedDescription)", style: .error)
                AppLog.error("Add bounce to library failed: \(error)")
            }
        }
    }
}

// MARK: - Session Editor

/// The BREAKOUT: one song, one lane per part, one time axis.
///
/// Why this is not the Studio timeline, and should not try to be. The Studio
/// arranges arbitrary clips at arbitrary positions across arbitrary tracks, so
/// it needs a ruler, a zoom, a horizontal scroll and a scroll-position
/// negotiation between the lanes and the header column. A stem session is a
/// far tighter thing: N parts of ONE song, every one starting at zero, every
/// one the same length, and the set does not change while you listen to it.
///
/// That constraint buys a much more direct layout, and this view spends it:
///
///   * the WHOLE SONG is always on screen. No zoom, no horizontal scroll, no
///     scroll position to keep in sync — the lane column is the song, end to
///     end, and 0:00 is the left edge in every lane forever.
///   * therefore ONE ruler serves every lane, and one playhead x means the
///     same instant on every row without a per-lane calculation.
///   * therefore the columns can be fixed: header | lane | mix. Every lane
///     uses the same three widths, which is what makes the shared playhead
///     honest rather than approximately aligned.
///   * and the two controls the surface exists for — Solo and Mute — get the
///     top-level position and the size the Studio's per-track toggles cannot
///     afford, because here there are four of them and not forty.
private struct StemSessionEditorView: View {
    let document: StemSessionDocument
    @ObservedObject var engine: StemEngine
    let onAddStems: () -> Void
    let onBounce: () -> Void
    /// Hand these stems to the Studio tab as tracks. Passed in rather than
    /// reached for so the editor does not need the coordinator.
    let onOpenInStudio: ([SessionStem]) -> Void

    @EnvironmentObject var stemSessionStore: StemSessionStore
    @Environment(\.undoManager) private var undoManager

    @State private var editedName = ""
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0
    @State private var masterDragDB: Double?
    @State private var showHistory = false

    private var playheadTime: Double {
        isSeeking ? seekPosition : engine.currentTime
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            transportBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.gray.opacity(0.05))

            Divider()

            if document.stems.isEmpty {
                emptyStemsPlaceholder
            } else {
                breakout
            }

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .onAppear { editedName = document.name }
        .onChange(of: document.id) { _, _ in editedName = document.name }
        .onChange(of: document.name) { _, newName in editedName = newName }
    }

    // MARK: Header

    private var editorHeader: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(
                    colors: [.blue.opacity(0.6), .purple.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                TextField("Session name", text: $editedName)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .onSubmit {
                        stemSessionStore.renameSession(id: document.id, to: editedName, undoManager: undoManager)
                    }

                HStack(spacing: 4) {
                    if let origin = document.originOps.first {
                        Text(originSummary(origin))
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        Text("Stem session")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text("·").lineLimit(1).fixedSize()
                    Text(StemEngine.formatTimecode(engine.duration))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    Text("·").lineLimit(1).fixedSize()
                    Text(partsSummary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    /// "Vocals, Drums, Bass, Other" — the parts this song is made of, which is
    /// the one-line answer to "what am I looking at".
    private var partsSummary: String {
        let kinds = document.stems.map {
            StemKindInference.label(StemKindInference.kind(displayName: $0.displayName, fileName: $0.fileName))
        }
        var seen = Set<String>()
        let unique = kinds.filter { seen.insert($0).inserted }
        return unique.joined(separator: ", ")
    }

    private func originSummary(_ op: StemOriginOp) -> String {
        switch op.action {
        case StemOriginOp.actionCreatedFromExtract:
            return "Created from extracted stems"
        default:
            return "Created \(op.timestamp.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    // MARK: Transport

    private var transportBar: some View {
        HStack(spacing: 12) {
            // Back to start
            Button(action: { engine.seek(to: 0) }) {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.bordered)
            .disabled(document.stems.isEmpty || engine.isBouncing)
            .studioHelp("stems.transport.returnToStart")

            // Play / Pause
            if engine.isPlaying {
                Button(action: { engine.pause() }) {
                    Image(systemName: "pause.fill")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .studioHelp("stems.transport.pause")
            } else {
                Button(action: { engine.play() }) {
                    Image(systemName: "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(document.stems.isEmpty || engine.isBouncing)
                .studioHelp("stems.transport.play")
            }

            Button(action: { engine.stop() }) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.bordered)
            .disabled(document.stems.isEmpty || engine.isBouncing)
            .studioHelp("stems.transport.stop")

            // Timecode
            Text("\(StemEngine.formatTimecode(playheadTime)) / \(StemEngine.formatTimecode(engine.duration))")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 130, alignment: .leading)

            // Seek
            Slider(
                value: Binding(
                    get: { isSeeking ? seekPosition : min(engine.currentTime, engine.duration) },
                    set: { newValue in
                        seekPosition = newValue
                        isSeeking = true
                    }
                ),
                in: 0...max(engine.duration, 0.001),
                onEditingChanged: { editing in
                    if !editing {
                        engine.seek(to: seekPosition)
                        isSeeking = false
                    }
                }
            )
            .disabled(document.stems.isEmpty || engine.isBouncing)
            .studioHelp("stems.transport.seek")

            // Master gain + master-bus level meter
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                VStack(spacing: 3) {
                    Slider(
                        value: Binding(
                            get: { masterDragDB ?? document.masterGainDB },
                            set: { newValue in
                                masterDragDB = newValue
                                engine.previewMasterGain(gainDB: newValue)
                            }
                        ),
                        in: StemMix.minGainDB...StemMix.maxGainDB,
                        onEditingChanged: { editing in
                            if !editing, let final = masterDragDB {
                                stemSessionStore.setMasterGain(in: document.id, gainDB: final, undoManager: undoManager)
                                masterDragDB = nil
                            }
                        }
                    )
                    .studioHelp("stems.master.gain")

                    LevelMeterBar(levels: engine.masterLevels)
                        .frame(height: 5)
                        .studioHelp("stems.master.meter")
                }
                .frame(width: 100)
                Text(StemMix.formatDB(masterDragDB ?? document.masterGainDB))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 62, alignment: .trailing)
                    // .frame() sizes the layout, not the hit region: without
                    // contentShape the advertised "double-click label to reset"
                    // only lands on the digits themselves and the rest of the
                    // 62 pt column is dead.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        stemSessionStore.setMasterGain(in: document.id, gainDB: 0, undoManager: undoManager)
                    }
                    .studioHelp("stems.master.reset")
            }

            // Bounce
            if engine.isBouncing {
                HStack(spacing: 6) {
                    ProgressView(value: engine.bounceProgress)
                        .frame(width: 80)
                    Text("\(Int(engine.bounceProgress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(.secondary)
                }
            } else {
                Button(action: onBounce) {
                    Label("Bounce", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(document.stems.isEmpty || engine.loadedStemCount == 0)
                .studioHelp("stems.bounce")
            }
        }
    }

    // MARK: The breakout

    private var breakout: some View {
        VStack(spacing: 0) {
            timeRuler
                .padding(.horizontal, 12)
                .padding(.top, 8)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(document.stems) { stem in
                        StemLaneRow(
                            stem: stem,
                            sessionID: document.id,
                            allStems: document.stems,
                            anySolo: document.hasSolo,
                            isMissing: engine.missingStemIDs.contains(stem.id),
                            engine: engine,
                            isSeeking: $isSeeking,
                            seekPosition: $seekPosition,
                            onOpenInStudio: { onOpenInStudio([stem]) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)

                sessionHistorySection
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
        }
    }

    /// ONE ruler for the whole set — the affordance the fixed-length,
    /// everything-starts-at-zero constraint buys. It is inset by exactly the
    /// header and mix column widths so a label at x sits above the same instant
    /// in every lane below it.
    private var timeRuler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: StemBreakoutLayout.headerWidth)
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let duration = engine.duration
                let step = StemBreakoutLayout.rulerStep(duration: duration)
                ZStack(alignment: .topLeading) {
                    if duration > 0 {
                        ForEach(Array(stride(from: 0.0, through: duration, by: step)), id: \.self) { mark in
                            let x = StemBreakoutLayout.playheadX(
                                time: mark, duration: duration, width: width)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(StemLaneRow.rulerLabel(mark))
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(width: 1, height: 4)
                            }
                            .offset(x: min(x, width - 26))
                        }

                        Rectangle()
                            .fill(Color.primary.opacity(0.55))
                            .frame(width: 1.5)
                            .offset(x: StemBreakoutLayout.playheadX(
                                time: playheadTime, duration: duration, width: width))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(seekGesture(width: width, duration: duration))
            }
            .frame(height: StemBreakoutLayout.rulerHeight)
            .studioHelp("stems.ruler")
            Color.clear.frame(width: StemBreakoutLayout.mixWidth)
        }
        .frame(height: StemBreakoutLayout.rulerHeight)
    }

    /// The one seek gesture, shared by the ruler and every lane, so a scrub
    /// anywhere previews the same position everywhere and the playheads cannot
    /// diverge mid-drag.
    private func seekGesture(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0, !engine.isBouncing else { return }
                isSeeking = true
                seekPosition = StemBreakoutLayout.time(
                    atX: value.location.x, duration: duration, width: width)
            }
            .onEnded { _ in
                guard isSeeking else { return }
                engine.seek(to: seekPosition)
                isSeeking = false
            }
    }

    // MARK: Footer / empty / history

    private var footer: some View {
        HStack {
            Button(action: onAddStems) {
                Label("Add Stems from Files…", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .studioHelp("stems.add")

            Button {
                onOpenInStudio(document.stems)
            } label: {
                Label("Open All in Studio", systemImage: "square.grid.3x1.below.line.grid.1x2")
            }
            .buttonStyle(.bordered)
            .disabled(document.stems.isEmpty)
            .studioHelp("stems.openAll")

            Spacer()

            Text("\(document.stems.count) stem\(document.stems.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var emptyStemsPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text("No stems in this session")
                .font(.headline)
            Text("Add audio files here, or split a song into its parts in the Create tab — vocals, drums, bass and the rest arrive as their own lanes, each with its own solo, mute and level.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button(action: onAddStems) {
                Label("Add Stems from Files…", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .studioHelp("stems.add.empty")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionHistorySection: some View {
        DisclosureGroup(isExpanded: $showHistory) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(document.originOps.suffix(50).reversed()) { op in
                    HStack(alignment: .top, spacing: 8) {
                        Text(op.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: 130, alignment: .leading)
                        Text(op.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Session History (\(document.originOps.count))", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Level Meter

/// Compact peak/RMS meter on a −60…0 dBFS axis: gradient RMS fill in the
/// app's blue→purple→pink language plus a floating max-hold peak tick that
/// turns red at 0 dBFS (clipping). Renders empty when the transport is
/// stopped (the engine clears levels with its taps).
///
/// Fed by `StemEngine.stemLevels` / `masterLevels`, which the engine's single
/// 20 Hz tick publishes. This view NEVER polls: `StemLevelAccumulator.read()`
/// is read-and-reset, so a second poller would drain the same hold and the two
/// would each show about half the peaks.
private struct LevelMeterBar: View {
    let levels: StemLevels

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let rmsWidth = width * CGFloat(StemMix.meterFraction(fromLinear: levels.rms))
            let peakX = width * CGFloat(StemMix.meterFraction(fromLinear: levels.peak))
            let clipping = levels.peak >= 1.0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.15))

                Capsule()
                    .fill(LinearGradient(
                        colors: [.blue.opacity(0.85), .purple, .pink],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: rmsWidth)
                    }

                if levels.peak > 0 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(clipping ? Color.red : Color.primary.opacity(0.55))
                        .frame(width: 2)
                        .offset(x: min(max(peakX - 1, 0), width - 2))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Stem Lane

/// One part of the song: header | waveform lane | mix, at fixed widths.
private struct StemLaneRow: View {
    let stem: SessionStem
    let sessionID: UUID
    /// The whole set — the solo policy is a property of the SET, not of one
    /// stem, so the row cannot compute it from `stem` alone.
    let allStems: [SessionStem]
    let anySolo: Bool
    let isMissing: Bool
    @ObservedObject var engine: StemEngine

    @EnvironmentObject var stemSessionStore: StemSessionStore
    @Environment(\.undoManager) private var undoManager

    /// Shared with the editor (and its ruler/transport) so a scrub on ANY lane
    /// previews the same position on EVERY row — the playheads never diverge
    /// mid-drag.
    @Binding var isSeeking: Bool
    @Binding var seekPosition: Double

    /// Hand THIS stem to the Studio tab as a track.
    let onOpenInStudio: () -> Void

    @State private var dragGainDB: Double?
    @State private var dragPan: Double?
    @State private var editedName = ""

    /// SUITE-WIDE stem colour, not a per-row palette entry.
    ///
    /// This row used to pick from a rotating eight-colour list by ROW INDEX, so
    /// the same vocal was purple in a four-stem session and pink in a
    /// five-stem one, and neither matched the Studio — which has always drawn
    /// vocals #FF5FA2 because the stem colours are constants shared with
    /// Majik's DJ. The same four parts of the same song were two different
    /// colour schemes one tab apart.
    private var kind: StudioStemKind {
        StemKindInference.kind(displayName: stem.displayName, fileName: stem.fileName)
    }

    private var laneColor: Color { StudioTokens.stemColor(kind) }

    private var effectivelyMuted: Bool {
        StemMix.isEffectivelyMuted(muted: stem.muted, solo: stem.solo, anySolo: anySolo)
    }

    var body: some View {
        HStack(spacing: 0) {
            header
                .frame(width: StemBreakoutLayout.headerWidth, alignment: .leading)
                .padding(.leading, 10)

            waveformLane
                .frame(maxWidth: .infinity)

            mixColumn
                .frame(width: StemBreakoutLayout.mixWidth)
                .padding(.horizontal, 10)
        }
        .frame(height: StemBreakoutLayout.laneHeight)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(effectivelyMuted ? 0.04 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(stem.solo ? Color.yellow.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
        .onAppear { editedName = stem.displayName }
        .onChange(of: stem.displayName) { _, newName in editedName = newName }
    }

    // MARK: Header column

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                // Colour key: a bar rather than a dot. A 10 pt dot is the
                // Studio's per-track key at desk distance; this is the same
                // colour at a size that still reads across a room.
                RoundedRectangle(cornerRadius: 2)
                    .fill(laneColor.opacity(effectivelyMuted ? 0.35 : 1))
                    .frame(width: 4, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    TextField("Stem name", text: $editedName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .onSubmit {
                            stemSessionStore.renameStem(
                                id: stem.id, in: sessionID, to: editedName, undoManager: undoManager)
                        }

                    HStack(spacing: 4) {
                        Text(StemKindInference.label(kind))
                            .font(.system(size: 9, weight: .semibold))
                            .kerning(0.6)
                            .foregroundColor(laneColor.opacity(effectivelyMuted ? 0.5 : 0.95))
                            .lineLimit(1)
                            .fixedSize()
                        if stem.generationParams != nil {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8))
                                .foregroundColor(.purple)
                        }
                        if isMissing {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .help(provenanceHint)

            HStack(spacing: 6) {
                soloButton
                muteButton
                Spacer(minLength: 0)
                rowMenu
            }
        }
    }

    /// Solo: EXCLUSIVE on a plain click, additive on ⌥-click. See
    /// `StemSoloPlan` for why round that way here and not in the Studio.
    ///
    /// Whole word, not "S". This surface's readers are assumed never to have
    /// opened a DAW, and a bold letter S is a guess; the tooltip explains the
    /// concept and the button says the word.
    private var soloButton: some View {
        Button {
            applySolo(additive: NSEvent.modifierFlags.contains(.option))
        } label: {
            Text("SOLO")
                .font(.system(size: 10, weight: .heavy))
                .kerning(0.5)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 52, height: StemBreakoutLayout.toggleHeight)
        }
        .buttonStyle(.bordered)
        .tint(stem.solo ? .yellow : nil)
        .disabled(isMissing)
        .studioHelp(stem.solo ? "stems.solo.off" : "stems.solo")
        .accessibilityLabel(stem.solo ? "Stop soloing \(stem.displayName)" : "Hear only \(stem.displayName)")
    }

    private var muteButton: some View {
        Button {
            stemSessionStore.setStemMuted(
                id: stem.id, in: sessionID, muted: !stem.muted, undoManager: undoManager)
        } label: {
            Text("MUTE")
                .font(.system(size: 10, weight: .heavy))
                .kerning(0.5)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 52, height: StemBreakoutLayout.toggleHeight)
        }
        .buttonStyle(.bordered)
        .tint(stem.muted ? .red : nil)
        .disabled(isMissing)
        .studioHelp(stem.muted ? "stems.mute.off" : "stems.mute")
        .accessibilityLabel(stem.muted ? "Unmute \(stem.displayName)" : "Silence \(stem.displayName)")
    }

    /// The row's other actions, as ONE visible control rather than a
    /// right-click-only menu. This codebase has a documented failure mode where
    /// a feature that existed only in a context menu was reported missing;
    /// "Remove" also moved in here off a bare ✕, which was a mis-click waiting
    /// to happen beside the controls people actually reach for.
    private var rowMenu: some View {
        Menu {
            // help-exempt: macOS menu items get no hover tooltip. The teaching
            // for the whole menu is on the button that opens it
            // (`stems.row.menu`), which is the hover that leads a person here.
            Button("Open in Studio") { onOpenInStudio() }
            Divider()
            Button("Reset Level to 0 dB") {
                stemSessionStore.setStemGain(id: stem.id, in: sessionID, gainDB: 0, undoManager: undoManager)
            }
            Button("Centre Pan") {
                stemSessionStore.setStemPan(id: stem.id, in: sessionID, pan: 0, undoManager: undoManager)
            }
            Divider()
            Button("Remove from Session", role: .destructive) {
                stemSessionStore.removeStem(id: stem.id, from: sessionID, undoManager: undoManager)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: StemBreakoutLayout.toggleHeight)
        .studioHelp("stems.row.menu")
    }

    /// The Solo button's whole action. It is one call on purpose: the planning
    /// and the one-undo-step commit are joined in `StemSoloAction`, which is
    /// testable, rather than here, which is not. See that type's comment for
    /// the mutation that proved the difference matters.
    private func applySolo(additive: Bool) {
        StemSoloAction.apply(
            tapped: stem,
            in: allStems,
            sessionID: sessionID,
            additive: additive,
            store: stemSessionStore,
            undoManager: undoManager
        )
    }

    // MARK: Waveform lane

    /// The stem's audio across the session timeline. Leading-aligned and scaled
    /// by stemDuration/duration so a playhead x is the same instant on every
    /// lane; click or drag anywhere in it to seek.
    private var waveformLane: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let sessionDuration = engine.duration
            let stemDuration = engine.stemDuration(for: stem.id) ?? 0
            let widthFraction: Double = (sessionDuration > 0 && stemDuration > 0)
                ? min(stemDuration / sessionDuration, 1)
                : 1
            let playheadTime = isSeeking ? seekPosition : engine.currentTime
            let stemProgress = stemDuration > 0 ? min(playheadTime / stemDuration, 1) : 0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.1))

                if isMissing {
                    Text("Audio file missing — this stem will not play or bounce")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 8)
                } else {
                    StemLaneWaveform(
                        url: stemSessionStore.audioURL(for: stem),
                        color: laneColor,
                        widthFraction: widthFraction,
                        progress: stemProgress,
                        dimmed: effectivelyMuted
                    )
                }

                if sessionDuration > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1.5)
                        .offset(x: StemBreakoutLayout.playheadX(
                            time: playheadTime, duration: sessionDuration, width: width))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard sessionDuration > 0, !engine.isBouncing else { return }
                        isSeeking = true
                        seekPosition = StemBreakoutLayout.time(
                            atX: value.location.x, duration: sessionDuration, width: width)
                    }
                    .onEnded { _ in
                        guard isSeeking else { return }
                        engine.seek(to: seekPosition)
                        isSeeking = false
                    }
            )
            .studioHelp("stems.lane")
        }
        .padding(.vertical, 8)
    }

    // MARK: Mix column

    private var mixColumn: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { dragGainDB ?? stem.gainDB },
                        set: { newValue in
                            dragGainDB = newValue
                            engine.previewStemGain(
                                stemID: stem.id,
                                gainDB: newValue,
                                effectivelyMuted: effectivelyMuted
                            )
                        }
                    ),
                    in: StemMix.minGainDB...StemMix.maxGainDB,
                    onEditingChanged: { editing in
                        if !editing, let final = dragGainDB {
                            stemSessionStore.setStemGain(
                                id: stem.id, in: sessionID, gainDB: final, undoManager: undoManager)
                            dragGainDB = nil
                        }
                    }
                )
                .studioHelp("stems.gain")

                Text(StemMix.formatDB(dragGainDB ?? stem.gainDB))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(effectivelyMuted ? .secondary.opacity(0.5) : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 56, alignment: .trailing)
                    // The frame is layout only, so the advertised
                    // double-click-to-reset needs an explicit content shape or
                    // it only lands on the digits themselves.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        stemSessionStore.setStemGain(
                            id: stem.id, in: sessionID, gainDB: 0, undoManager: undoManager)
                    }
                    .studioHelp("stems.gain.reset")
            }

            LevelMeterBar(levels: engine.stemLevels[stem.id] ?? .zero)
                .frame(height: StemBreakoutLayout.meterHeight)
                .studioHelp("stems.meter")

            HStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { dragPan ?? stem.pan },
                        set: { newValue in
                            dragPan = newValue
                            engine.previewStemPan(stemID: stem.id, pan: newValue)
                        }
                    ),
                    in: StemMix.minPan...StemMix.maxPan,
                    onEditingChanged: { editing in
                        if !editing, let final = dragPan {
                            stemSessionStore.setStemPan(
                                id: stem.id, in: sessionID, pan: final, undoManager: undoManager)
                            dragPan = nil
                        }
                    }
                )
                .controlSize(.mini)
                .studioHelp("stems.pan")

                Text(StemMix.formatPan(dragPan ?? stem.pan))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(effectivelyMuted ? .secondary.opacity(0.5) : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 34, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        stemSessionStore.setStemPan(
                            id: stem.id, in: sessionID, pan: 0, undoManager: undoManager)
                    }
                    .studioHelp("stems.pan.center")
            }
        }
    }

    private var provenanceHint: String {
        var parts: [String] = []
        if let params = stem.generationParams {
            if let model = params.model { parts.append("Model: \(model)") }
            if let style = params.style, !style.isEmpty { parts.append("Style: \(style)") }
        }
        if stem.sourceTrackId != nil {
            parts.append("Derived from a library track")
        }
        return parts.isEmpty ? stem.displayName : parts.joined(separator: "\n")
    }

    /// "0:00", "1:30" — ruler labels. Seconds only; a stem session is one song
    /// long, so hours never appear and centiseconds are noise at this size.
    static func rulerLabel(_ seconds: Double) -> String {
        let safe = max(0, seconds)
        return String(format: "%d:%02d", Int(safe) / 60, Int(safe) % 60)
    }
}
