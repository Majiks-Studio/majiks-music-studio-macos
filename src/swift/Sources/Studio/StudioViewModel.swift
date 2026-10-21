import SwiftUI

// MARK: - Studio view model
//
// AppModel-style engine polling (DJ pattern): 30 Hz, single in-flight by
// construction (one sequential loop), change-conditional adoption (revision
// check), and an edit-guard so a control under drag is never fought by an
// incoming snapshot. Commands go TO the engine; state comes FROM snapshots.

@MainActor
final class StudioViewModel: ObservableObject {

    // MARK: Engine + stores

    let engine: any StudioEngineProtocol
    let tiles = StudioWaveformTileStore()
    /// Notes for the MIDI clips the arrangement draws. A cache off the note
    /// seam, NOT a field on the snapshot — see StudioMidiNoteStore for why
    /// putting notes on the 30 Hz poll would be a cost nothing can measure.
    let midiNotes = StudioMidiNoteStore()
    let frameStats = StudioFrameStats()

    /// The note seam, when this engine has one.
    ///
    /// On a real-engine build this is the very SAME actor as `engine`
    /// (RealStudioEngine conforms to both protocols, deliberately: one actor,
    /// one UUID<->engine-id map, so a clip id means the same thing to the
    /// arrangement and to the piano roll). On a mock build it is nil, and the
    /// arrangement says so by drawing every MIDI clip's pending mark rather
    /// than inventing notes — StudioMockEngine has no note surface and never
    /// produces a MIDI clip in the first place.
    let noteEngine: (any StudioNoteEngineProtocol)?

    // MARK: Snapshot state (engine truth)

    @Published private(set) var snapshot: StudioProjectSnapshot? {
        // EVERY adoption, not the two obvious ones. There are five places that
        // assign a fresh snapshot (the poll, `adoptFresh` twice, the import
        // path, the first load) and a call added to some of them is a message
        // that appears depending on which gesture happened to refresh first.
        // `didSet` is the only wiring a future adoption site cannot forget.
        didSet { announceTracksTheAppMadeItself() }
    }
    @Published private(set) var importProgress: Double = 0
    @Published private(set) var importStatus: String?

    /// Tracks whose "the app made this for you" message has already been said.
    ///
    /// Per view-model, not persisted: the message answers "what just happened",
    /// and reopening a project tomorrow is not that moment. The TRACK HEADER is
    /// the half that keeps answering it forever, and it needs no memory at all
    /// because it is drawn from the snapshot every frame.
    private(set) var announcedAutoCreatedTracks: Set<UUID> = []
    /// Whether any snapshot has been adopted yet. The first one is the project
    /// as it already was, not a thing that just happened to the user.
    private var hasAdoptedASnapshot = false

    // MARK: Selection

    @Published var selection: StudioSelection = .empty
    /// R pressed with a region selected: the Revise placeholder panel arms.
    @Published var reviseArmed = false

    // MARK: View state

    @Published var pxPerTick: CGFloat = 24.0 / CGFloat(StudioTick.ppq)   // ~96 px/bar in 4/4
    @Published var scrollTicks: Int64 = 0
    @Published var scrollY: CGFloat = 0
    @Published var snapMode: StudioSnapMode = .bar
    @Published var followPlayhead = true
    @Published var browserCollapsed = false
    @Published var inspectorCollapsed = false
    @Published var mixerCollapsed = true
    /// The routing + effects pane (E5). Off by default: it is a mixing surface,
    /// not a timeline one, and it is not part of the first-run path.
    @Published var routingShown = false
    @Published var paletteShown = false
    /// A catalog name the palette should open ON, already past the browsing
    /// step, because a MENU sent the user here.
    ///
    /// A menu item cannot ask for a tempo and cannot ask "are you sure", so
    /// the Song / Track / Clip / Transport menus hand those rows to ⌘K with
    /// the question already on screen (`StudioPaletteFlow.seeded`). Consumed
    /// once by `StudioCommandPalette` and cleared, so re-opening the palette by
    /// hand afterwards lands on the ordinary browsing list rather than
    /// re-asking a question nobody asked for.
    @Published var paletteSeed: String?
    /// The export + provenance-manifest dialog (L13).
    @Published var exportSheetShown = false
    @Published var expandedTakeLanes: Set<UUID> = []
    /// Automation lanes the user has toggled visible. A lane also shows when it
    /// already carries points (engine truth), so this only adds empty lanes to
    /// draw into. Non-journaled view state (catalog: autolane.show).
    @Published var visibleAutomationLanes: Set<StudioAutoLaneKey> = []
    @Published private(set) var sweepActive = false
    /// Last known timeline canvas width (set by the canvas geometry) so
    /// palette/keyboard zoom-to-fit works from anywhere.
    var timelineViewportWidth: CGFloat = 1000

    /// Set while any timeline drag is live (edit-guard + draw overrides).
    @Published var drag = StudioDragState()

    private var pollTask: Task<Void, Never>?
    private var lastAdoptedRevision: UInt64 = 0
    /// Optimistic overrides survive until the engine confirms a later revision.
    private var overrides: [UUID: StudioClipSnapshot] = [:]
    private var overridesAwaitRevisionAbove: UInt64 = 0
    /// Guard: only fire one auto-stop per playback session.
    private var didAutoStopAtEnd = false
    private let microphonePermission: any StudioMicrophonePermission
    @Published private(set) var microphoneAccessMessage: String?

    // MARK: Lifecycle

    init(engine: any StudioEngineProtocol = StudioMockEngine(),
         microphonePermission: any StudioMicrophonePermission = AlwaysAuthorizedMicrophonePermission()) {
        self.engine = engine
        self.noteEngine = engine as? any StudioNoteEngineProtocol
        self.microphonePermission = microphonePermission
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 33_000_000)   // 30 Hz
            }
        }
    }

    /// Load a song onto the timeline (Library double-click / drag, the Import
    /// button, and the timeline file-drop all land here).
    ///
    /// Default (`newTrack: true`): each import lands on its OWN new track, minted
    /// via `track.add` and named from the song, so double-clicking three songs
    /// builds three tracks instead of piling three clips onto track 1 — that is
    /// how a multitrack session is built up. `newTrack: false` (⌘-double-click)
    /// deliberately overdubs onto an existing track instead: `ontoTrackID` when
    /// given, else the first track. A fresh (0-track) project always gets a track
    /// created either way, so the empty-project case keeps working.
    ///
    /// Respects the engine's `max_tracks`: if `track.add` is refused (the engine
    /// is at capacity) the import reports the engine's message rather than
    /// silently falling back to piling the clip onto an existing track.
    func importAudio(path: String, ontoTrackID: UUID? = nil, newTrack: Bool = true, named: String? = nil) {
        // The no-project refusal stays SYNCHRONOUS. `performImport` re-checks
        // it, but only after an await hop, and a caller that asks whether the
        // import was refused right after calling this — which is exactly what
        // "import with no project open" does — would read `importStatus` before
        // the hop landed and see nothing at all.
        guard snapshot != nil else {
            importStatus = "Create or open a project before importing audio."
            importProgress = 0
            return
        }
        Task { @MainActor in
            await performImport(path: path, ontoTrackID: ontoTrackID, newTrack: newTrack, named: named)
        }
    }

    /// The body of `importAudio`, awaitable.
    ///
    /// Split out so a BATCH of imports can be sequenced. Each import mints a
    /// track and then re-polls to learn the id the engine gave it ("the id that
    /// wasn't there before"), so two imports running concurrently would each
    /// see the other's new track and could adopt the wrong one. Callers
    /// importing more than one file must await these one at a time.
    ///
    /// - Parameter named: track name override. Without it the track is named
    ///   from the FILE, which is right for a song dragged in and wrong for a
    ///   stem, whose file is `1a2b3c4d_vocals.wav` but whose name is "Vocals".
    /// - Returns: whether the audio landed.
    @discardableResult
    func performImport(
        path: String,
        ontoTrackID: UUID? = nil,
        newTrack: Bool = true,
        named: String? = nil
    ) async -> Bool {
        // No snapshot adopted yet: we genuinely do not know the project state, so
        // report rather than fabricate a track (an already-loaded project the view
        // model simply has not polled yet must not gain a stray empty track). Once
        // Studio is open it always has a snapshot; a truly empty project (0 tracks)
        // is handled inside the task by auto-creating a track.
        guard snapshot != nil else {
            importStatus = "Create or open a project before importing audio."
            return false
        }
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let songName = named ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        importProgress = 0.05
        importStatus = "Analyzing \(fileName)…"

        // Only overdub onto an existing track when explicitly asked AND a
        // target exists; otherwise (the default, and any empty project) mint a
        // fresh track so the session builds up rather than stacking onto track 1.
        let existingTarget: UUID?
        if newTrack {
            existingTarget = nil
        } else if let id = ontoTrackID, snapshot?.tracks.contains(where: { $0.id == id }) == true {
            existingTarget = id
        } else {
            existingTarget = snapshot?.tracks.first?.id   // nil when empty -> create below
        }

        // An overdub onto a track that already exists is ONE journaled command
        // and needs no bracket.
        if let existingTarget {
            let result = await engine.importAudio(path: path, trackID: existingTarget, startTicks: 0)
            importProgress = result.ok ? 1 : 0
            importStatus = result.ok ? "Imported \(fileName)" : result.message
            return result.ok
        }

        // ONE GESTURE, ONE UNDO STEP.
        //
        // Building a new row and putting the audio on it is TWO journaled
        // operations — `track.add`, then the engine's own import transaction —
        // so one drag used to cost two presses of Cmd-Z: the first took the
        // clip off and left the user staring at an empty row they never asked
        // for, the second took the row away. The house rule everywhere else in
        // this app is that one gesture is one step, and a MIDI take already
        // honours it.
        //
        // The bracket rides the generic catalog bus both engines already
        // implement, so this needed no new command and no new FFI. What it
        // needed was the ENGINE's import transaction to JOIN this one instead
        // of opening a second — `timeline_core::session::OpenTxn` is re-entrant
        // now, and before it was, wrapping this pair made the import fail
        // outright ("v1 transactions do not nest") rather than group.
        let txnID = "import_\(UUID().uuidString.prefix(12))"
        _ = await engine.send(.catalog(name: "txn.begin", params: [
            "txnId": txnID, "reason": Self.importNewTrackReason,
        ]))
        let landed = await importOntoAFreshTrack(path: path, fileName: fileName, songName: songName)
        // EVERY exit of the call above is followed by this commit. An early
        // `return` that skipped it would leave the engine's transaction open,
        // and an open transaction refuses undo, redo and every later gesture
        // for the rest of the session — which is why the body is a method and
        // not four `return false`s inline.
        //
        // The result is deliberately not read: on the failure path the engine
        // has already rolled the whole bracket back and REFUSES this commit,
        // which is the correct answer and not one the user needs told twice —
        // `importStatus` already carries what went wrong.
        _ = await engine.send(.catalog(name: "txn.commit", params: ["txnId": txnID]))
        return landed
    }

    /// The `txn.begin` reason a new-track import brackets itself with. Named
    /// once because it is journaled, and a journaled string that is spelled in
    /// two places is one that quietly stops matching.
    ///
    /// Deliberately NOT one of the reasons `StudioHost::track_origins` decodes:
    /// this `track.add` rides the app's own actor and the row it makes is the
    /// one the user just dragged a file onto, so it is not a track "nobody
    /// asked for" and owes no provenance sentence.
    static let importNewTrackReason = "import onto a new track"

    /// Mint a track named from the song and import onto it, inside the caller's
    /// open transaction. Split out of `performImport` so that all three of its
    /// exits are followed by the commit; see the call site.
    private func importOntoAFreshTrack(path: String, fileName: String, songName: String) async -> Bool {
        // Create a new track named from the song, appended after the last
        // track, then import onto it. track.add rides the generic command
        // bus (no new FFI). The real engine mints its OWN id, so identify
        // the new track as "the id that wasn't there before" rather than by
        // the UUID minted here (which only the mock echoes back).
        let existingIDs = Set(snapshot?.tracks.map(\.id) ?? [])
        let index = snapshot?.tracks.count ?? 0
        let name = songName.isEmpty ? "Audio \(index + 1)" : songName
        let added = await engine.send(
            .trackAdd(trackID: UUID().uuidString, name: name, index: index))
        guard added.ok else {
            importProgress = 0
            // Engine refused (e.g. at max_tracks): surface it; do NOT pile
            // the clip onto an existing track behind the user's back.
            importStatus = added.message ?? "Could not create a track to import onto."
            return false
        }
        // Re-poll so the engine has minted the new track's id map (the real
        // engine builds its UUID<->engine-id map when it snapshots), then
        // target the newly-added track.
        guard let fresh = await engine.snapshot(ifNewerThan: nil),
              let created = fresh.tracks.first(where: { !existingIDs.contains($0.id) })
                            ?? fresh.tracks.last else {
            importProgress = 0
            importStatus = "Created a track but could not read it back."
            return false
        }
        lastAdoptedRevision = fresh.revision
        snapshot = fresh
        let madeTrack = created.name.isEmpty ? name : created.name

        let result = await engine.importAudio(path: path, trackID: created.id, startTicks: 0)
        importProgress = result.ok ? 1 : 0
        // SAY THAT A TRACK WAS MADE. This path mints one, and this line used to
        // read "Imported song.wav" — a row appeared in the arrangement and the
        // word "track" never came up. The right wording already existed twelve
        // lines below, in `importStemSession` ("on their own tracks"); the
        // single-file path simply never got it.
        //
        // On the FAILURE branch it says only what went wrong, because the
        // engine has by then taken the row back too: claiming a track was made
        // while the arrangement shows none is the same class of lie this
        // sentence was added to end.
        importStatus = result.ok
            ? "Imported \(fileName) onto a new track called \(madeTrack)."
            : result.message
        return result.ok
    }

    /// Import a whole stem session — the Stems tab's "Open in Studio".
    ///
    /// SEQUENTIAL, deliberately. `performImport` identifies the track it just
    /// created as "the id that wasn't there before"; run four of these
    /// concurrently and each sees the others' new tracks and can adopt the
    /// wrong one, which would silently import the vocal onto the drum track.
    ///
    /// Each stem lands on its own track under its own name, which is exactly
    /// what the four parts of one song should be in an arrangement — and
    /// because every step is `track.add` + `import.audio` on the journalled
    /// bus, the whole thing is undoable in the Studio like anything else.
    func importStemSession(_ request: StudioStemImportRequest) async {
        guard !request.stems.isEmpty else { return }
        var landed = 0
        for stem in request.stems {
            if await performImport(path: stem.path, newTrack: true, named: stem.name) {
                landed += 1
            }
        }
        importProgress = landed == request.stems.count ? 1 : 0
        importStatus = landed == request.stems.count
            ? "Opened \(request.sessionName) — \(landed) stem\(landed == 1 ? "" : "s") on their own tracks"
            : "Opened \(landed) of \(request.stems.count) stems from \(request.sessionName)"
    }

    // MARK: Splitting a song into stem tracks
    //
    // The Studio's half of the same capability the Stems tab offers, and it
    // lands a DIFFERENT shape on purpose: four tracks on the timeline, which is
    // what you want when the next thing you do is cut the drums up. The Stems
    // tab's version lands a stem session, which is what you want when the next
    // thing you do is mute the vocal. Neither is a wrapper around the other and
    // both reach the same separator.
    //
    // Reachable from ⌘K and from Track ▸ Split a Song into Stems, through the
    // palette's `studio.separate` view row. It is a view row rather than a
    // catalog command because there is no catalog command that does this:
    // `gen.separate` RECORDS a request and calls no backend (its own catalog
    // description says so), and `import.audio`'s `separate` flag is declared
    // and implemented by nothing. Pointing a menu item at either would be a
    // button onto nothing.

    /// What can separate, installed by `StudioRootView` from the coordinator.
    /// Not `@Published`: it is read at the moment of the gesture and nothing
    /// renders from it.
    var stemSeparator: StemSeparating?

    /// How the Studio asks which song to split.
    ///
    /// Injected rather than opening an `NSOpenPanel` inline, and that is
    /// load-bearing for the tests as much as for the design: a modal panel in a
    /// test run hangs the whole bundle with no output, so a gesture that could
    /// only be driven through one is a gesture nothing can prove. With this
    /// seam the ⌘K row and the Track menu item can be pressed in a test and
    /// followed all the way to the separator.
    var songChooser: (@MainActor () -> URL?)?

    /// True while a split runs.
    @Published private(set) var separating = false
    /// Why the last split refused, or nil. Presented as an alert by the Studio.
    @Published var separationError: String?
    /// What is happening, while it happens.
    @Published private(set) var separationStatus: String?

    /// The `txn.begin` reason the split brackets itself with. Named once
    /// because it is journaled, and a journaled string spelled in two places is
    /// one that quietly stops matching.
    static let separateReason = "split a song into stem tracks"

    static let noSeparatorReason = StemSeparationRun.noSeparatorReason
    static let noChooserReason =
        "The Studio cannot open a file chooser right now. Switch to the Studio tab and try again."
    static let noProjectReason =
        "Create or open a project first — the parts have to land in an arrangement."

    /// The whole gesture, from the ⌘K row / the Track menu.
    func chooseSongAndSeparate() {
        guard let chooser = songChooser else {
            separationError = Self.noChooserReason
            return
        }
        // Cancelling the chooser is a real answer and not an error: no message,
        // nothing happens, nothing is left running.
        guard let url = chooser() else { return }
        let named = url.deletingPathExtension().lastPathComponent
        Task { @MainActor in
            await separateIntoStemTracks(
                path: url.path, named: named, outputRoot: FileStore.shared.baseDirectory)
        }
    }

    /// Split `path` and land each part on its own track — as ONE undo step.
    ///
    /// ⚠️ ONE GESTURE, ONE UNDO STEP, for four tracks and four clips.
    /// `importStemSession` runs four `performImport`s, and each of those is
    /// already bracketed (`track.add` + `import.audio`). Four brackets is four
    /// presses of Cmd-Z, watching the song come apart a row at a time. One more
    /// bracket around the lot makes it one unit, because
    /// `timeline_core::session::OpenTxn` is RE-ENTRANT: an inner `txn.begin`
    /// pushes an id and journals nothing, and only the outermost commit closes
    /// the `UndoUnit`. Nothing new was needed for this — no command, no FFI.
    ///
    /// ⚠️ THE REFUSAL RETURNS BEFORE THE BRACKET IS OPENED. A bracket opened
    /// and never closed refuses undo, redo and every later gesture for the rest
    /// of the session, so the one thing this must never do is fail between
    /// `txn.begin` and `txn.commit` — which is why the separation, the part
    /// that genuinely fails, happens first and returns on its own.
    func separateIntoStemTracks(path: String, named: String, outputRoot: URL) async {
        guard !separating else {
            separationError = StemSeparationRun.alreadyRunningRefusal
            return
        }
        guard let separator = stemSeparator else {
            separationError = Self.noSeparatorReason
            return
        }
        guard snapshot != nil else {
            separationError = Self.noProjectReason
            return
        }
        separating = true
        separationError = nil
        separationStatus = StemSeparationRun.runningLine
        defer {
            separating = false
            separationStatus = nil
        }

        let outputDir = outputRoot
            .appendingPathComponent("stems_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let stems: [String: String]
        do {
            stems = try await separator.separateIntoStems(
                sourceAudioPath: path, outputDir: outputDir.path)
        } catch {
            // NOTHING was sent to the engine, so there is nothing half-landed
            // and no bracket to close. The person gets the separator's own
            // words, which name the interpreter and the missing package.
            separationError = StemSeparationRefusal.message(for: error)
            return
        }
        let parts = StemSeparation.orderedInputs(stems)
        guard !parts.isEmpty else {
            separationError = "The separator finished but produced no parts, so nothing was added to the arrangement."
            return
        }

        let txnID = "separate_\(UUID().uuidString.prefix(12))"
        _ = await engine.send(.catalog(name: "txn.begin", params: [
            "txnId": txnID, "reason": Self.separateReason,
        ]))
        await importStemSession(StudioStemImportRequest(
            sessionName: named,
            stems: parts.map { .init(name: $0.displayName, path: $0.url.path) }))
        // EVERY exit above this line is a `return` that happened BEFORE the
        // begin, so this commit is unconditional and always paired.
        _ = await engine.send(.catalog(name: "txn.commit", params: ["txnId": txnID]))
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        let since: UInt64? = snapshot == nil ? nil : lastAdoptedRevision
        guard let fresh = await engine.snapshot(ifNewerThan: since) else { return }
        // Edit-guard: never adopt while a drag is live.
        guard drag.kind == .none else { return }
        if fresh.revision > overridesAwaitRevisionAbove {
            overrides.removeAll()
        }
        // First adoption expands take lanes so mock takes are visible, and loads
        // the Takes browser once (it refreshes again after any take mutation).
        if snapshot == nil {
            expandedTakeLanes = Set(fresh.tracks.compactMap { $0.takeLane != nil ? $0.id : nil })
            await refreshTakes()
        }
        lastAdoptedRevision = fresh.revision
        snapshot = fresh
        // Dirtiness is derived from ENGINE truth, not from the UI guessing which
        // of its own gestures mutated something. The saver decides what to do
        // with it; the view model just reports what the engine said.
        StudioProjectSaver.shared.noteRevision(fresh.revision)
    }

    // MARK: Derived

    var timeSignature: StudioTimeSignature {
        snapshot?.timeSignature ?? .fourFour
    }

    /// Where bar 1 begins. Everything the arrangement snaps or labels measures
    /// from here, not from tick 0.
    var phaseAnchorTicks: Int64 {
        snapshot?.phaseAnchorTicks ?? 0
    }

    /// The single bar grid the arrangement draws, snaps and labels from.
    var barGrid: StudioBarGrid {
        snapshot?.barGrid ?? StudioBarGrid(timeSignature: .fourFour)
    }

    var tempoConfidenceIsLow: Bool { (snapshot?.tempoConfidence ?? 1) <= 0 }

    var projectLengthTicks: Int64 {
        snapshot?.lengthTicks ?? 0
    }

    /// A clip with any live drag override applied (draw + hit-test truth).
    func effectiveClip(_ clip: StudioClipSnapshot) -> StudioClipSnapshot {
        overrides[clip.id] ?? clip
    }

    func playheadTicks(now: TimeInterval) -> Int64 {
        guard let snapshot else { return 0 }
        let raw = snapshot.transport.isPlaying
            ? snapshot.tempoMap.advanced(
                fromTicks: snapshot.transport.positionTicks,
                bySeconds: max(0, now - snapshot.transport.capturedAtHostTime))
            : snapshot.transport.positionTicks
        // Auto-stop when the playhead reaches end of content and no loop is
        // active. Without this the real engine keeps advancing (rt.rs position
        // never stops at clip end) and the UI playhead freezes at lengthTicks
        // while the engine renders silence underneath. The mock engine already
        // does this; the real one needs the app to tell it to stop.
        if raw >= snapshot.lengthTicks, !didAutoStopAtEnd,
           snapshot.transport.loopRegion == nil,
           snapshot.transport.isPlaying {
            didAutoStopAtEnd = true
            pause()
        }
        return min(raw, snapshot.lengthTicks)
    }

    /// Scroll for drawing. While playing with follow on, the playhead locks
    /// near mid-viewport and the timeline scrolls under it (01-DESIGN 5);
    /// computed per frame so follow is as smooth as the display.
    func effectiveScrollTicks(now: TimeInterval, viewportWidth: CGFloat) -> Int64 {
        guard let snapshot, snapshot.transport.isPlaying, followPlayhead,
              pxPerTick > 0 else { return scrollTicks }
        let viewportTicks = Int64(viewportWidth / pxPerTick)
        let lockTicks = scrollTicks + viewportTicks / 2
        let playhead = playheadTicks(now: now)
        guard playhead > lockTicks else { return scrollTicks }
        return playhead - viewportTicks / 2
    }

    /// Called when playback stops so the stored scroll matches what is on
    /// screen (the follow computation above is display-only).
    private func commitFollowScroll(viewportWidth: CGFloat) {
        scrollTicks = effectiveScrollTicks(
            now: ProcessInfo.processInfo.systemUptime, viewportWidth: viewportWidth)
    }

    // MARK: Commands

    /// Send one command and, if the engine refuses it, SAY SO.
    ///
    /// This used to be `Task { await engine.send(command) }` — the result
    /// dropped on the floor. Every gesture routed through here was therefore
    /// fire-and-forget, and a refusal was indistinguishable from success: the
    /// user right-clicked a track, chose Rename, typed a name, and nothing
    /// happened, silently. Eleven shipping gestures were in that state for the
    /// whole life of the feature and left no evidence anywhere — not on screen,
    /// not in a log, not in a test.
    ///
    /// SPEAKING IS THE DEFAULT, which is the part that closes the class rather
    /// than the instances. A gesture added tomorrow that never thinks about its
    /// error path still says something when the engine turns it down, and
    /// silence is no longer reachable by omission — it would take deleting this.
    /// `StudioRefusal.generic` is a floor, not a target: a gesture that can name
    /// what it was doing always should, and all eleven below do.
    private func send(_ command: StudioEngineCommand,
                      refusalSays refusal: String = StudioRefusal.generic) {
        overridesAwaitRevisionAbove = lastAdoptedRevision
        Task { @MainActor in
            let result = await engine.send(command)
            guard !result.ok else { return }
            StudioRefusal.say(refusal, engineDetail: result.message, command: command)
        }
    }

    /// The command palette's one door onto the bus.
    ///
    /// Every other caller of `send` in this file is a NAMED gesture —
    /// `setTempo`, `splitAtPlayhead` — and that is right: a gesture carries the
    /// geometry and the clamping its verb needs. The palette is different in
    /// kind. It reaches verbs that have no gesture anywhere in the app
    /// (`record.rotate`, `project.setPhaseAnchor`, `midi.reload`), and writing
    /// a one-line wrapper for each would be one more place for the palette to
    /// drift from the catalog. It goes through the SAME `send`, so undo stays
    /// one shared history and an agent, a MIDI binding and Cmd-K cannot
    /// disagree about what a verb means.
    func sendFromPalette(_ command: StudioEngineCommand) { send(command) }

    /// Send one command and then RE-READ THE TAKE LIST.
    ///
    /// THE TAKE LIST IS NOT PART OF THE SNAPSHOT. `takesBrowserItems` comes
    /// from a separate `studio_takes` read, and `refreshTakes()` had exactly
    /// two callers: `pollOnce`, guarded by `snapshot == nil` — the FIRST
    /// adoption of a session, once — and `adoptFresh()`. So the 30 Hz poll
    /// cannot bring a new take into Browser ▸ Takes, whatever the engine did.
    ///
    /// Every other workflow that makes a take knows this and calls
    /// `adoptFresh()`: revise, extend, add-a-layer, keep, place, purge — 19
    /// call sites. Recording was the one that did not. So you recorded a pass,
    /// watched the clip appear on the timeline (that IS in the snapshot),
    /// opened Takes, and it was not there — until something else happened to
    /// force a fresh adoption, at which point it appeared with no explanation.
    ///
    /// This is `send`'s body plus that read, rather than a call to `send`,
    /// because `send` discards the result on success and there is no way to
    /// wait for it from outside.
    private func sendAndRefreshTakes(_ command: StudioEngineCommand,
                                     refusalSays refusal: String = StudioRefusal.generic) {
        overridesAwaitRevisionAbove = lastAdoptedRevision
        Task { @MainActor in
            let result = await engine.send(command)
            await adoptFresh()
            guard !result.ok else { return }
            StudioRefusal.say(refusal, engineDetail: result.message, command: command)
        }
    }

    var isPlaying: Bool { snapshot?.transport.isPlaying ?? false }

    /// Space / the Play·Pause button. Returns true so the app-wide player keeps
    /// its hands off while Studio is frontmost (StudioCoordinator hook). Playing
    /// -> pause in place; stopped/paused -> play (resume from the play head).
    @discardableResult
    func togglePlayback(viewportWidth: CGFloat = 0) -> Bool {
        if isPlaying {
            pause(viewportWidth: viewportWidth)
        } else {
            play()
        }
        return true
    }

    /// Start (or resume from the current play head).
    func play() {
        didAutoStopAtEnd = false
        send(.transportPlay)
    }

    /// Pause IN PLACE: halt and hold the play head where it is; a later `play()`
    /// resumes from here. The engine's `transport.stop` freezes the position (the
    /// render core ramps to silence and stops advancing but does NOT rewind), so
    /// pause is `transport.stop` with no reset — the reset is what makes `stop()`
    /// different. `viewportWidth > 0` commits the follow-scroll so the timeline
    /// holds where it visually is rather than snapping back.
    func pause(viewportWidth: CGFloat = 0) {
        guard isPlaying else { return }
        didAutoStopAtEnd = false
        if viewportWidth > 0 { commitFollowScroll(viewportWidth: viewportWidth) }
        send(.transportStop)
    }

    /// Stop: halt AND rewind to the start. The seek and the halt go out as ONE
    /// ordered task, seek(0) FIRST and stop SECOND — the order is load-bearing on
    /// the live engine. The render core treats a seek WHILE PLAYING as "jump and
    /// keep playing" (it re-arms the transport gain), so seeking first zeroes the
    /// transport gain and repositions to 0, and the stop that immediately follows
    /// lands the transport halted at ~0. The reverse order (stop, then seek) lets
    /// the trailing seek re-arm playback mid-stop, so Stop would silently RESUME
    /// from the start — the "Stop does nothing" bug. Two fire-and-forget sends
    /// could also race into that reverse order, so we sequence them here.
    func stop() {
        didAutoStopAtEnd = false
        overridesAwaitRevisionAbove = lastAdoptedRevision
        let engine = self.engine
        Task {
            await engine.send(.transportSeek(ticks: 0))
            await engine.send(.transportStop)
        }
    }

    func returnToStart() { send(.transportSeek(ticks: 0)) }

    func seek(toTicks ticks: Int64) { send(.transportSeek(ticks: ticks)) }

    // MARK: Play-head navigation
    //
    // Moving the play head is TRANSPORT class, exactly like the loop: the
    // engine's `Command::is_undoable()` is `!is_transport()`, so `transport.seek`
    // is validated on the bus, journaled as an unjournaled no-op, and pushes no
    // undo step. Cmd-Z after scrubbing takes back whatever EDIT you made before
    // it, which is what anyone who has moved a play head expects.
    //
    // ⚠️ THE DRAG SENDS ONE COMMAND, ON RELEASE. It used to send a
    // `transport.seek` per mouse-move, which is a command storm at pointer rate
    // — and on the audio thread each seek is a transport discontinuity, so the
    // stream of them was audible as a buzz rather than as a scrub. The drag now
    // moves `playheadDraft` only (local, no engine round trip, so the line
    // tracks the cursor at display rate instead of at snapshot-poll rate), and
    // `endDrag` commits exactly one seek. Same idiom as `loopDraft` above and
    // as `StudioFaderControl`'s gain drag.

    /// Provisional play head under an active scrub drag. Drawn instead of the
    /// engine's position so the line follows the cursor without a command per
    /// mouse-move; cleared when the drag commits or is cancelled.
    @Published var playheadDraft: Int64?

    /// What the timeline should draw: the scrub in progress if there is one,
    /// else engine truth (interpolated between snapshot polls).
    func effectivePlayheadTicks(now: TimeInterval) -> Int64 {
        playheadDraft ?? playheadTicks(now: now)
    }

    /// Clamp a proposed play-head position into the project. Shared by the
    /// scrub drag and the nudge buttons so a drag past the end and a
    /// fast-forward past the end land on the same tick.
    func clampedPlayhead(_ ticks: Int64) -> Int64 {
        let end = projectLengthTicks
        return max(0, end > 0 ? min(ticks, end) : ticks)
    }

    /// Move the play head by whole BARS, and seek there.
    ///
    /// Rewind and fast-forward are a BAR NUDGE rather than a tape-style
    /// continuous shuttle, and that is a deliberate choice for this transport,
    /// not a shortcut. Everything else here is bar-addressed — the ruler is
    /// numbered in bars, the loop and the section selection are bar-snapped,
    /// the position readout reads bars.beats.divisions — so "one bar back" is
    /// the unit a person here is already thinking in, and it lands on the grid
    /// the music is on. A held shuttle would also have to stream seeks at key
    /// repeat rate, which is precisely the command storm the scrub drag exists
    /// to avoid: one press, one bar, one command.
    func nudgePlayhead(bars: Int) {
        let tpb = Int64(max(1, timeSignature.ticksPerBar))
        let now = ProcessInfo.processInfo.systemUptime
        // Snap to the bar line FIRST, so repeated presses walk the grid instead
        // of carrying an arbitrary offset along with them.
        let here = playheadTicks(now: now)
        let bar = here / tpb
        // Going back from mid-bar lands on the bar you are IN, which is what a
        // rewind button does everywhere else; going forward always advances.
        let target = bars < 0 && here % tpb != 0
            ? (bar + Int64(bars) + 1) * tpb
            : (bar + Int64(bars)) * tpb
        seek(toTicks: clampedPlayhead(target))
    }

    // MARK: Loop (transport-class)
    //
    // `transport.loop.set` / `transport.loop.clear` were wired end to end and
    // sample-exact long before anything could reach them: the only callers
    // were the Revise audition's own internal setup, so a person could not set
    // a loop at all — while the export dialog told them to. This is the user
    // half of that pair.
    //
    // Loop is TRANSPORT class, not a document edit. The engine says so itself:
    // `Command::is_undoable()` is `!is_transport()`, and `apply.rs` handles
    // `TransportLoopSet` as an `unjournaled_noop` after validating
    // `start < end`. So a loop does not push an undo step, exactly like
    // scrubbing the play head does not — Cmd-Z after setting a loop takes back
    // whatever EDIT you made before it, which is the behaviour anyone who has
    // moved a play head expects. What the "one gesture, one step" rule buys
    // here is that a loop drag sends exactly ONE command on release (the drag
    // itself only moves a local draft), and that the inverse is a real,
    // reachable control rather than an undo you cannot perform.

    /// The loop the engine is holding, or nil when there is none.
    var loopRegion: ClosedRange<Int64>? { snapshot?.transport.loopRegion }

    /// Provisional loop under an active ruler drag. Drawn instead of
    /// `loopRegion` so the brace tracks the cursor without a command per
    /// mouse-move; cleared when the drag commits or is cancelled.
    @Published var loopDraft: ClosedRange<Int64>?

    /// What the ruler should draw: the drag in progress if there is one, else
    /// engine truth.
    var effectiveLoopRegion: ClosedRange<Int64>? { loopDraft ?? loopRegion }

    /// Human copy for the loop, e.g. "bars 5 to 8". nil when no loop is set.
    func loopDescription(timeSignature: StudioTimeSignature) -> String? {
        guard let r = loopRegion,
              let region = StudioRegionSelection(rawStart: r.lowerBound, rawEnd: r.upperBound)
        else { return nil }
        let bars = region.barRange(grid: barGrid)
        return bars.lowerBound == bars.upperBound
            ? "bar \(bars.lowerBound)"
            : "bars \(bars.lowerBound) to \(bars.upperBound)"
    }

    /// Set the loop. Bar-snapped by the caller; clamped and floored to one bar
    /// here so a command that the engine would refuse (`start >= end`) never
    /// leaves the UI.
    func setLoop(startTicks: Int64, endTicks: Int64) {
        let tpb = max(1, timeSignature.ticksPerBar)
        let lo = max(0, min(startTicks, endTicks))
        var hi = max(startTicks, endTicks)
        if hi <= lo { hi = lo + tpb }
        loopDraft = nil
        send(.transportLoopSet(start: lo, end: hi))
    }

    func clearLoop() {
        loopDraft = nil
        send(.transportLoopClear)
    }

    /// The Loop button. On -> off is a clear. Off -> on picks a region in a
    /// fixed, explainable order, so the button always does something and a
    /// newcomer can predict which something:
    ///   1. the time selection, if there is one (you asked for those bars);
    ///   2. the section under the play head (you are sitting in the chorus);
    ///   3. four bars from the bar under the play head (nothing else to go on).
    func toggleLoop() {
        if loopRegion != nil {
            clearLoop()
            return
        }
        let tpb = max(1, timeSignature.ticksPerBar)
        if let region = selection.region {
            setLoop(startTicks: region.startTicks, endTicks: region.endTicks)
            return
        }
        let head = playheadTicks(now: ProcessInfo.processInfo.systemUptime)
        if let section = snapshot?.sections.first(where: {
            head >= Int64($0.startBar) * tpb && head < Int64($0.startBar + $0.lengthBars) * tpb
        }) {
            setLoop(startTicks: Int64(section.startBar) * tpb,
                    endTicks: Int64(section.startBar + section.lengthBars) * tpb)
            return
        }
        let bar = max(0, head / tpb)
        setLoop(startTicks: bar * tpb, endTicks: (bar + 4) * tpb)
    }

    // MARK: Instrument tracks (E1/E2)

    /// The MIDI clip the piano roll should be editing: the selected one when a
    /// note-backed clip is selected, otherwise the first one in the project.
    /// nil when the project has no MIDI clip at all, which is the state a new
    /// user starts in.
    var editableMidiClipID: UUID? {
        guard let snapshot else { return nil }
        let midi = snapshot.tracks.flatMap(\.clips).filter(\.isMidi)
        if let selected = midi.first(where: { selection.clipIDs.contains($0.id) }) {
            return selected.id
        }
        return midi.first?.id
    }

    /// Set when an instrument track has just been created, so the roll can open
    /// onto its clip. Cleared once consumed.
    @Published var newlyCreatedMidiClipID: UUID?

    /// Create an instrument track: a track, a synth on it, and an empty MIDI
    /// clip to write into. Selects the clip and hands it to the piano roll.
    ///
    /// Before this there was no path from an empty project to a MIDI clip
    /// anywhere in the GUI, so the piano roll had nothing it could ever edit.
    func addInstrumentTrack(bars: Int = 4) {
        Task { @MainActor in
            let index = (snapshot?.tracks.count ?? 0) + 1
            let ticks = Int64(max(1, bars)) * timeSignature.ticksPerBar
            let outcome = await engine.addInstrumentTrack(
                name: "Instrument \(index)", lengthTicks: ticks)
            guard outcome.ok, let clipID = outcome.clipID else {
                ToastManager.shared.show(
                    outcome.message ?? "Could not add an instrument track.", style: .warning)
                return
            }
            await adoptFresh()
            selection.clipIDs = [clipID]
            selection.region = nil
            newlyCreatedMidiClipID = clipID
            ToastManager.shared.show("Instrument track added. Draw notes in the piano roll.", style: .success)
        }
    }

    /// Add a playable sample instrument beside an existing generated song.
    /// The song's audio stems remain audio-only. Track creation and the first
    /// device/zone bind share one transaction, so Cmd-Z removes both.
    @discardableResult
    func addSamplerTrack(path: String) -> Task<Void, Never> {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return addSampleTrack(
            name: name.isEmpty ? "Sampler" : "Sampler · \(name)",
            request: StudioSampleBindRequest(
                trackID: UUID(), deviceID: nil, kind: "sampler",
                bindings: [.acrossTheKeyboard(path)], reason: "Add a sampler track"))
    }

    /// Add a new track and bind one sound per drum pad, reusing the same
    /// journaled batch as an existing rack.
    @discardableResult
    func addDrumRackTrack(paths: [String]) -> Task<Void, Never> {
        let bindings = Array(paths.prefix(StudioDrumRack.padCount)).enumerated().map { index, path in
            StudioSampleBinding.pad(path, key: StudioDrumRack.defaultBaseKey + index)
        }
        return addSampleTrack(
            name: "Drum Rack",
            request: StudioSampleBindRequest(
                trackID: UUID(), deviceID: nil, kind: "drum", bindings: bindings,
                reason: "Add a drum rack track"))
    }

    /// Add a track and its first sample instrument as one undoable gesture.
    /// `bindSamples` owns source ingest and therefore opens its own inner
    /// bracket; both engines merge that bracket into this outer unit. If the
    /// bind refuses before opening it, committing and undoing the outer unit
    /// prevents an empty orphan track from surviving the failed gesture.
    private func addSampleTrack(name: String, request: StudioSampleBindRequest) -> Task<Void, Never> {
        overridesAwaitRevisionAbove = lastAdoptedRevision
        return Task { @MainActor in
            let index = snapshot?.tracks.count ?? 0
            let txnID = "ui_\(UUID().uuidString.prefix(12))"
            let trackID = request.trackID
            let begin = await engine.send(.catalog(name: "txn.begin", params: [
                "txnId": txnID, "reason": name,
            ]))
            guard begin.ok else {
                ToastManager.shared.show(begin.message ?? "Could not add that instrument track.", style: .warning)
                return
            }
            let added = await engine.send(.trackAdd(
                trackID: trackID.uuidString, name: name, index: index))
            guard added.ok else {
                _ = await engine.send(.catalog(name: "txn.commit", params: ["txnId": txnID]))
                ToastManager.shared.show(added.message ?? "Could not add that instrument track.", style: .warning)
                return
            }
            let outcome = await engine.bindSamples(request)
            let committed = await engine.send(.catalog(name: "txn.commit", params: ["txnId": txnID]))
            guard outcome.ok, committed.ok else {
                if committed.ok { _ = await engine.undo() }
                ToastManager.shared.show(
                    outcome.message ?? committed.message ?? "Could not load that instrument sound.",
                    style: .warning)
                return
            }
            await adoptFresh()
            ToastManager.shared.show("\(name) added. Cmd-Z removes the track and its sound.", style: .success)
        }
    }

    // MARK: - Saying so when the app did something nobody asked for
    //
    // Playing a key on a project with no instrument CREATES A TRACK
    // (`ensure_instrument_target`). That is right, and it is the thing that lets
    // someone who does not know what a track is sit down and play. What was
    // wrong is that a row appeared in the arrangement and the app never
    // mentioned it — the provenance was in the journal the whole time and
    // nothing put it in front of the person it happened to.
    //
    // A TOAST, and specifically not a sheet, an alert or anything with a button
    // on it: this fires with the user's hands on the keys, and an interruption
    // at the exact moment the app finally works is worse than the silence it
    // replaces. It fades on its own; the track header keeps the same fact
    // permanently for whenever they look down.

    /// Say it, once per track, when a track the app made itself appears.
    ///
    /// Driven off `track.origin`, which the engine derives from the journal's
    /// `actor` field — so this cannot fire for a track the user made by hand,
    /// and it cannot be left firing by a flag someone forgot to clear. Undo
    /// removes the track, which removes it from the snapshot, which is all the
    /// cleanup there is.
    /// This runs on EVERY adoption — 30 Hz — so it allocates nothing on the
    /// overwhelmingly common path where there is nothing to say. `insert(_:)`
    /// both records and tests in one step, which is also why "already said" can
    /// never disagree with "was said".
    private func announceTracksTheAppMadeItself() {
        guard let tracks = snapshot?.tracks else { return }
        // OPENING A PROJECT IS NOT AN EVENT. `origin` is journal truth and lives
        // as long as the project does, so the first snapshot only ever TEACHES
        // this set — otherwise a project saved after a played take would
        // announce the same track every time it was reopened, which is not
        // "here is what just happened", it is nagging.
        let sayIt = hasAdoptedASnapshot
        hasAdoptedASnapshot = true

        // COLLECTED, then said — not said one at a time.
        //
        // One played note makes one track, so the original of this loop could
        // announce as it went. A stem import makes four in a SINGLE adoption,
        // and four toasts for one gesture is worse than none: they queue, the
        // last one is the only one still on screen when the reader looks up,
        // and the three underneath it were pure interruption. One sentence
        // naming four rows is the same information and one glance.
        //
        // `nil` — the overwhelmingly common case, every ordinary track on every
        // 30 Hz poll — allocates nothing: the dictionary is only built when
        // something has an origin at all.
        var fresh: [StudioTrackOrigin: [String]] = [:]
        for track in tracks {
            guard let origin = track.origin else { continue }
            // `insert(_:)` both records and tests in one step, which is why
            // "already said" can never disagree with "was said".
            guard announcedAutoCreatedTracks.insert(track.id).inserted, sayIt else { continue }
            fresh[origin, default: []].append(track.name)
        }
        guard !fresh.isEmpty else { return }
        // `allCases` rather than the dictionary's own order, so two origins
        // arriving together produce the same two sentences in the same order
        // every time. A Dictionary's iteration order is not stable across runs
        // and a toast that changes with the wind is untestable.
        for origin in StudioTrackOrigin.allCases {
            guard let names = fresh[origin], !names.isEmpty else { continue }
            ToastManager.shared.show(origin.announcement(namingTracks: names),
                                     style: .success, seconds: ToastDuration.actionable)
        }
    }

    /// KEEP what was just played.
    ///
    /// The retro-capture buffer is what removes "arm" from the path to keeping
    /// something: everything played is held whether or not anything was armed,
    /// and this lands it. One undoable step, so a keep the player did not mean
    /// costs them one Cmd-Z rather than a cleanup.
    func keepPerformance() async {
        #if REAL_ENGINE
        guard let real = engine as? RealStudioEngine else {
            ToastManager.shared.show(
                "This build is running on the mock engine, so there is nothing to keep.",
                style: .warning)
            return
        }
        let outcome = await real.keepPerformance()
        guard outcome.kept else {
            ToastManager.shared.show("Nothing has been played yet.", style: .warning)
            return
        }
        await adoptFresh()
        // Open the roll onto what was just kept, so "I played that" and "there it
        // is" are one move rather than a hunt.
        if let clipID = editableMidiClipID {
            selection.clipIDs = [clipID]
            newlyCreatedMidiClipID = clipID
        }
        // AND PUT IT ON SCREEN. The roll opening is not enough on its own: the
        // arrangement is where a person looks to see that their playing became
        // a clip, and a clip 1,075 bars off screen is indistinguishable from
        // nothing having happened. This is the half of the bar-1076 bug the
        // engine's anchor cannot fix, because "where the timeline is scrolled"
        // is not something the engine knows.
        reveal(ticks: outcome.startTicks)
        let n = outcome.noteCount
        if outcome.snapped {
            ToastManager.shared.show(
                "Kept \(n) note\(n == 1 ? "" : "s") at \(barLabel(outcome.startTicks)). " +
                "The transport had run a long way past your music, so this went after the " +
                "last thing in the project instead. Cmd-Z takes it back.",
                style: .success, seconds: ToastDuration.actionable)
        } else {
            ToastManager.shared.show(
                "Kept \(n) note\(n == 1 ? "" : "s") at \(barLabel(outcome.startTicks)). " +
                "Cmd-Z takes it back.",
                style: .success)
        }
        #else
        ToastManager.shared.show(
            "Keeping a performance needs the on-device engine.", style: .warning)
        #endif
    }

    /// THROW AWAY what was just played, without putting any of it in the
    /// project.
    ///
    /// Keep shipped without a counterpart, which left "how do I not keep
    /// notes?" with no answer: the buffer is a rolling 128 beats, so a bad pass
    /// and a good pass sat in the same count and the only exits were to keep
    /// everything and undo it, or to stop playing and wait a minute.
    ///
    /// Destructive-but-safe, and the toast says which: it can only reach notes
    /// that were HEARD and never written, so nothing already in the project can
    /// be lost — and equally, there is nothing for Cmd-Z to bring back, which
    /// is the one thing a person must not have to discover by trying it.
    func discardPerformance() async {
        #if REAL_ENGINE
        guard let real = engine as? RealStudioEngine else {
            ToastManager.shared.show(
                "This build is running on the mock engine, so there is nothing to throw away.",
                style: .warning)
            return
        }
        let discarded = await real.discardPerformance()
        await adoptFresh()
        guard discarded > 0 else {
            ToastManager.shared.show("Nothing has been played yet.", style: .warning)
            return
        }
        ToastManager.shared.show(
            "Threw away \(discarded) note\(discarded == 1 ? "" : "s"). Nothing in your project " +
            "changed, so there is nothing to undo — just play again.",
            style: .success, seconds: ToastDuration.actionable)
        #else
        ToastManager.shared.show(
            "Throwing away a performance needs the on-device engine.", style: .warning)
        #endif
    }

    /// Scroll the timeline so `ticks` is on screen, one bar in from the left.
    ///
    /// The idiom was already here twice, inline, in `previewTake` and
    /// `rerollFromTake`; it is a named method now because Keep is the third
    /// caller and the third copy of a one-liner is where they start to differ.
    /// Also turns playhead-following OFF: a follow that is still on would drag
    /// the view straight back to wherever the transport has got to, which on the
    /// day this was written was bar 1,076.
    func reveal(ticks: Int64) {
        followPlayhead = false
        scrollTicks = max(0, ticks - Int64(timeSignature.ticksPerBar))
    }

    /// "bar 12" for a tick position, for a sentence a person can act on. Bars
    /// are 1-based on screen everywhere else, so they are here too.
    func barLabel(_ ticks: Int64) -> String {
        let perBar = max(1, Int64(timeSignature.ticksPerBar))
        return "bar \(ticks / perBar + 1)"
    }

    func setTrackMute(_ trackID: UUID, muted: Bool) {
        send(.trackMute(trackID: trackID, muted: muted))
    }

    func setTrackSolo(_ trackID: UUID, soloed: Bool) {
        send(.trackSolo(trackID: trackID, soloed: soloed))
    }

    // MARK: Recording (L19)
    //
    // Arm a track, then Record: record.start opens an input-only capture onto the
    // armed track; record.stop lands it as a take + clip with human-origin
    // lineage. The input meter (snapshot.inputMeter) is the gain-staging surface.
    // Monitoring (hearing yourself) is deliberately NOT wired here: it is
    // double-gated behind MAJIKS_TEST_AUDIBLE in the engine, so nothing the UI
    // does can make live monitors sound. (Audible-by-default applies to Play/
    // playback output, not to record monitoring.) The COUNT-IN, however, is
    // now audible: `beginCountIn` asks the engine for real clicks, which is
    // the point of a count-in. A count-in you cannot hear tells you nothing
    // about when to come in — it was a number counting down in silence.

    /// Device the picker chose; nil = the system default input.
    @Published var selectedInputDevice: String?
    /// Count-in length in beats before capture begins (0 = none).
    @Published var countInBeats: Int = 4
    /// Beats remaining in an active count-in (0 = not counting in).
    @Published private(set) var countInRemaining: Int = 0
    private var countInTask: Task<Void, Never>?

    /// Loop-record: keep capturing passes over the punch region until stopped;
    /// each pass stacks as a comp take (the engine's take-only session).
    @Published var loopRecord = false
    @Published private(set) var loopPass = 0

    var isRecording: Bool { snapshot?.transport.recording ?? false }
    /// Privacy: true when the engine has an input stream open (recording or
    /// opt-in listen). Arming alone leaves this false.
    var inputOpen: Bool { snapshot?.transport.inputOpen ?? false }
    var inputListening: Bool { snapshot?.transport.inputListening ?? false }
    /// How many discrete input channels the open (or last-known) device has.
    /// Falls back to 4 so a Zoom AMS-44 style interface is selectable before
    /// the stream opens and reports its real count.
    var inputChannelCount: Int {
        let fromMeter = snapshot?.inputMeter?.channels.count ?? 0
        if fromMeter > 0 { return fromMeter }
        return 4
    }
    /// ENGINE TRUTH, like `isPlaying`. The transport bar never keeps its own
    /// copy, so the button, an agent and a MIDI binding cannot disagree.
    var metronomeEnabled: Bool { snapshot?.transport.metronomeEnabled ?? false }

    /// Click level in dB relative to the engine default. Monitor state, so it
    /// is a UI preference rather than anything journaled — the project is
    /// identical whichever way this is set, and an export never contains the
    /// click at all.
    @Published var metronomeLevelDB: Double = 0 {
        didSet {
            guard metronomeLevelDB != oldValue else { return }
            let db = metronomeLevelDB
            Task { await engine.setMetronome(enabled: nil, levelDB: db, countInBeats: nil) }
        }
    }

    /// Turn the click on or off. Goes through the catalog command so every
    /// surface drives one verb.
    func toggleMetronome() {
        send(.transportMetronome(enabled: !metronomeEnabled))
    }
    var isCountingIn: Bool { countInRemaining > 0 }
    var armedTracks: [StudioTrackSnapshot] { snapshot?.tracks.filter(\.armed) ?? [] }
    var firstArmedTrack: StudioTrackSnapshot? { snapshot?.tracks.first(where: \.armed) }
    var canRecord: Bool { firstArmedTrack != nil && !isRecording }
    var inputMeter: StudioInputMeter? { snapshot?.inputMeter }
    var inputDevices: [String] { snapshot?.inputDevices ?? [] }
    /// The track currently being captured onto (for the live record waveform).
    var recordingTrack: StudioTrackSnapshot? {
        guard let id = snapshot?.transport.recordingTrackID else { return nil }
        return snapshot?.tracks.first(where: { $0.id == id })
    }

    func setTrackArm(_ trackID: UUID, armed: Bool) {
        send(.trackArm(trackID: trackID, armed: armed))
    }

    /// Which hardware input channel this track records from (0-based).
    func setInputChannel(trackID: UUID, channel: Int) {
        send(.trackSetInputChannel(trackID: trackID, channel: max(0, channel)))
    }

    /// Opt-in open the mic for metering without recording. Arming never does this.
    func toggleInputListen() {
        let enable = !inputListening && !isRecording
        guard enable else {
            send(.recordInputListen(enabled: false, deviceID: selectedInputDevice))
            return
        }
        Task { [weak self] in
            guard let self, await microphonePermission.requestIfNeeded() else {
                await MainActor.run { self?.microphoneAccessMessage = "Microphone access is off for Majik's Music Studio" }
                return
            }
            await MainActor.run { self.microphoneAccessMessage = nil }
            self.send(.recordInputListen(enabled: true, deviceID: self.selectedInputDevice))
        }
    }

    func toggleArm(_ trackID: UUID) {
        let armed = snapshot?.tracks.first(where: { $0.id == trackID })?.armed ?? false
        setTrackArm(trackID, armed: !armed)
    }

    /// Local truth for a live or pending capture: set when record.start is sent,
    /// cleared on stop/cancel. The record decision reads THIS, not the ~30 Hz
    /// snapshot's `isRecording`, so a rapid Cmd+R or double-click cannot see a
    /// stale "not recording" and double-fire record.start (or a spurious stop).
    private var captureLive = false
    private var recordStartedTransport = false
    private var recordOpenedListen = false
    private var recordListenWasAlreadyOpen = false
    private var recordPermissionPending = false

    /// Record button: stop if capturing, cancel if counting in, else start (after
    /// an optional visual count-in) onto the first armed track. If a region is
    /// selected it becomes the PUNCH region: capture starts at its start and
    /// auto-lands at its end. Otherwise a free capture starts at the playhead.
    func toggleRecord() {
        if recordPermissionPending {
            recordPermissionPending = false
            return
        }
        if captureLive { stopRecording(); return }
        if isCountingIn { cancelCountIn(); return }
        guard let track = firstArmedTrack else { return }
        if !isRecording {
            recordPermissionPending = true
            Task { [weak self] in
                guard let self, await microphonePermission.requestIfNeeded() else {
                    await MainActor.run {
                        self?.recordPermissionPending = false
                        self?.microphoneAccessMessage = "Microphone access is off for Majik's Music Studio"
                    }
                    return
                }
                await MainActor.run {
                    guard self.recordPermissionPending else { return }
                    self.recordPermissionPending = false
                    self.microphoneAccessMessage = nil
                    self.beginRecordToggle(track: track)
                }
            }
            return
        }
        beginRecordToggle(track: track)
    }

    private func beginRecordToggle(track: StudioTrackSnapshot) {
        let device = selectedInputDevice
        let punch = selection.region
        let wasRolling = isPlaying
        let beats = countInBeats
        let bpm = snapshot?.tempoBPM ?? 120
        let startTicks = punch?.startTicks
        captureLive = true
        recordStartedTransport = !wasRolling
        recordOpenedListen = !inputListening
        recordListenWasAlreadyOpen = inputListening
        countInTask?.cancel()
        countInTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            if !wasRolling, !self.loopRecord, let startTicks {
                _ = await engine.send(.transportSeek(ticks: startTicks))
            }
            guard !Task.isCancelled else { return }
            if !wasRolling, !self.loopRecord, beats > 0, bpm > 0 {
                self.recordOpenedListen = !self.inputListening
                _ = await engine.send(.recordInputListen(enabled: true, deviceID: device))
                await MainActor.run { self.countInRemaining = beats }
                await engine.setMetronome(enabled: nil, levelDB: nil, countInBeats: beats)
                let beatSeconds = 60.0 / bpm
                for remaining in stride(from: beats, through: 1, by: -1) {
                    if Task.isCancelled { return }
                    await MainActor.run { self.countInRemaining = remaining }
                    try? await Task.sleep(nanoseconds: UInt64(beatSeconds * 1_000_000_000))
                }
                await MainActor.run { self.countInRemaining = 0 }
            }
            if Task.isCancelled { return }
            if !wasRolling, !self.loopRecord { _ = await engine.send(.transportPlay) }
            guard !Task.isCancelled else { return }
            let current = self.playheadTicks(now: ProcessInfo.processInfo.systemUptime)
            let activePunch: StudioRegionSelection? = {
                guard let punch else { return nil }
                if wasRolling && current >= punch.endTicks { return nil }
                return punch
            }()
            let result = await engine.send(.recordStart(trackID: track.id, deviceID: device,
                                                         startTicks: activePunch?.startTicks,
                                                         punchOutTicks: activePunch?.endTicks))
            if Task.isCancelled, result.ok {
                _ = await engine.send(.recordCancel)
                return
            }
            guard result.ok else {
                await MainActor.run { self.captureLive = false }
                return
            }
            if let punch = activePunch {
                let current = wasRolling ? self.playheadTicks(now: ProcessInfo.processInfo.systemUptime) : punch.startTicks
                self.schedulePunchOut(lengthTicks: max(1, punch.endTicks - current), extraSeconds: 0.1)
            }
        }
    }

    /// Stop the active capture (or count-in / loop) and land the take.
    ///
    /// Lands the capture, refreshes the take list, restores transport/listen
    /// ownership, and reports an engine refusal.
    func stopRecording() {
        cancelCountIn()
        cancelPunchOut()
        loopPass = 0
        guard captureLive else { return }
        let stopTransport = recordStartedTransport
        captureLive = false
        Task { [weak self] in
            guard let self else { return }
            let result = await engine.send(.recordStop)
            await adoptFresh()
            if stopTransport { _ = await engine.send(.transportStop) }
            if recordOpenedListen || recordListenWasAlreadyOpen { _ = await engine.send(.recordInputListen(enabled: recordListenWasAlreadyOpen, deviceID: selectedInputDevice)) }
            if !result.ok { StudioRefusal.say(StudioRefusal.generic, engineDetail: result.message, command: .recordStop) }
            recordOpenedListen = false
            recordListenWasAlreadyOpen = false
        }
    }

    /// Discard the active capture without landing anything.
    ///
    /// Also refreshes: a cancel after one or more loop passes leaves the
    /// EARLIER passes standing as takes, so the list it leaves behind is a
    /// different list from the one before.
    func cancelRecording() {
        cancelCountIn()
        cancelPunchOut()
        loopPass = 0
        guard captureLive else { return }
        let stopTransport = recordStartedTransport
        captureLive = false
        Task { [weak self] in
            guard let self else { return }
            let result = await engine.send(.recordCancel)
            await adoptFresh()
            if stopTransport { _ = await engine.send(.transportStop) }
            if recordOpenedListen || recordListenWasAlreadyOpen { _ = await engine.send(.recordInputListen(enabled: recordListenWasAlreadyOpen, deviceID: selectedInputDevice)) }
            if !result.ok { StudioRefusal.say(StudioRefusal.generic, engineDetail: result.message, command: .recordCancel) }
            recordOpenedListen = false
            recordListenWasAlreadyOpen = false
        }
    }

    private var punchOutTask: Task<Void, Never>?

    /// Punch-out: auto-stop after the region's musical length elapses. Timer-based
    /// so it is precise (not bound to the snapshot poll). Silent: it issues a
    /// boundary rotation for loop passes, or record.stop for the final pass.
    private func schedulePunchOut(lengthTicks: Int64, extraSeconds: Double = 0) {
        cancelPunchOut()
        guard let bpm = snapshot?.tempoBPM, bpm > 0, lengthTicks > 0 else { return }
        let seconds = Double(lengthTicks) / Double(StudioTick.ppq) * 60.0 / bpm
        punchOutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds + extraSeconds) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.captureLive else { return }
            // Loop-record: rotate at the boundary so passes stack as comp takes
            // until the user stops. Await the ordered command; no arbitrary
            // settle sleep. captureLive stays true across passes.
            if self.loopRecord, let region = self.selection.region {
                // Rotate the engine-owned accumulator. The same input stream
                // remains open, the next pass starts immediately, and the
                // completed pass prepares its media asynchronously.
                await self.engine.send(.recordRotate)
                guard !Task.isCancelled, self.loopRecord, self.captureLive else { return }
                self.loopPass += 1
                self.schedulePunchOut(lengthTicks: region.lengthTicks)
            } else {
                self.stopRecording()
            }
        }
    }

    private func cancelPunchOut() {
        punchOutTask?.cancel()
        punchOutTask = nil
    }

    /// The punch region for the record button: a selected region while a track is
    /// armed and not yet recording (records only within it).
    var punchRegion: StudioRegionSelection? {
        (firstArmedTrack != nil && !isRecording) ? selection.region : nil
    }

    private func beginCountIn(beats: Int, tempoBPM: Double, then: @escaping () -> Void) {
        // `silenceClicks: false` on purpose. The engine command below REPLACES
        // the count-in state outright, so there is nothing to silence — and
        // sending a cancel first would put two unstructured Tasks in flight
        // with no ordering between them, which can land the cancel AFTER the
        // arm and leave a count-in that never clicks.
        cancelCountIn(silenceClicks: false)
        countInRemaining = beats
        let beatSeconds = 60.0 / tempoBPM
        // MAKE IT AUDIBLE. The engine clocks the clicks itself, per FRAME off
        // its own counter, so the beats are sample-accurate rather than
        // Task.sleep-accurate — and they sound whether or not the metronome is
        // switched on and whether or not the transport is rolling. The
        // countdown below stays the VISUAL half of the same event; both start
        // from this instant and use the same tempo.
        Task { [engine] in
            await engine.setMetronome(enabled: nil, levelDB: nil, countInBeats: beats)
        }
        // Task inherits this @MainActor context, so the countdown + `then` run on
        // the main actor.
        countInTask = Task { [weak self] in
            for remaining in stride(from: beats, through: 1, by: -1) {
                self?.countInRemaining = remaining
                try? await Task.sleep(nanoseconds: UInt64(beatSeconds * 1_000_000_000))
                // Do NOT write countInRemaining here: cancelCountIn already zeroed
                // it, and a later beginCountIn may have started a fresh count-in
                // this cancelled task must not clobber.
                if Task.isCancelled { return }
            }
            self?.countInRemaining = 0
            then()
        }
    }

    private func cancelCountIn(silenceClicks: Bool = true) {
        let wasCounting = countInRemaining > 0
        countInTask?.cancel()
        countInTask = nil
        countInRemaining = 0
        // Silence the engine's clicks as well, or a cancelled count-in keeps
        // clicking after the number on screen has gone — the optimistic-UI
        // failure in reverse.
        if silenceClicks && wasCounting {
            Task { [engine] in
                await engine.setMetronome(enabled: nil, levelDB: nil, countInBeats: 0)
            }
        }
    }

    /// AI-native: after a performance lands, select its clip + region so you can
    /// tell the engineer (or press Revise) to build the arrangement around what
    /// you just played. This is the thing no incumbent DAW does.
    func buildAround(clipID: UUID) {
        guard let clip = snapshot?.tracks.flatMap({ $0.clips }).first(where: { $0.id == clipID }) else { return }
        selection.clipIDs = [clipID]
        selection.region = StudioRegionSelection(rawStart: clip.startTicks, rawEnd: clip.endTicks)
        reviseArmed = true
    }

    // MARK: Mixer commands (L12)
    //
    // Every control drives the command bus, so a move is journaled, undoable,
    // and identical whether a person or an agent made it. The dock's controls
    // read engine truth from the snapshot and hold their own value only while
    // under drag (the DJ edit-guard), so the 30 Hz poll never fights a drag.

    func setTrackGain(_ trackID: UUID, gainDB: Double) {
        send(.mixGain(trackID: trackID, gainDB: clampGainDB(gainDB)))
    }

    func setTrackPan(_ trackID: UUID, pan: Double) {
        send(.mixPan(trackID: trackID, pan: max(-1, min(1, pan))))
    }

    func setTrackEq(_ trackID: UUID, band: Int, freqHz: Double, gainDB: Double, q: Double) {
        send(.mixEq(trackID: trackID, band: band,
                    freqHz: max(20, min(20_000, freqHz)),
                    gainDB: max(-24, min(24, gainDB)),
                    q: max(0.1, min(10, q))))
    }

    func setTrackSend(_ trackID: UUID, bus: StudioSendBus, amount: Double) {
        send(.mixSend(trackID: trackID, bus: bus, amount: max(0, min(1, amount))))
    }

    func setMasterGain(_ gainDB: Double) {
        send(.mixMasterGain(gainDB: clampGainDB(gainDB)))
    }

    func setLimiter(enabled: Bool, ceilingDB: Double, releaseMs: Double) {
        send(.mixLimiterSet(enabled: enabled,
                            ceilingDB: max(-6, min(0, ceilingDB)),
                            releaseMs: max(1, min(1000, releaseMs))))
    }

    private func clampGainDB(_ db: Double) -> Double { max(-60, min(12, db)) }

    // MARK: Project commands

    /// The tempo the engine will accept, NAMED rather than inlined in the clamp
    /// below. The transport's BPM field has to show the clamp — type 900 and
    /// read back 300.0 — and a second copy of those two numbers in the view is
    /// exactly how a field and the command it sends come to disagree.
    nonisolated static let tempoRangeBPM: ClosedRange<Double> = 20...300

    func setTempo(bpm: Double) {
        send(.projectSetTempo(bpm: max(Self.tempoRangeBPM.lowerBound,
                                       min(Self.tempoRangeBPM.upperBound, bpm))))
    }

    func setTimeSig(numerator: Int, denominator: Int) {
        send(.projectSetTimeSig(numerator: numerator, denominator: denominator))
    }

    func setKey(_ key: String) {
        guard !key.isEmpty else { return }
        send(.projectSetKey(key: key))
    }

    // MARK: Marker + section commands
    //
    // THE ELEVEN GESTURES THAT DID NOTHING. Every envelope below used to carry
    // `StudioMockEngine`'s parameter names rather than the catalog's — `gain`
    // for `gainDb`, `height` for `heightPx`, `index` for `newIndex`, and
    // `marker.set` / `section.set` did not send the contract's parameters at
    // all. `session.rs` validates against `command-catalog.v2.json` with
    // `additionalProperties: false` BEFORE apply, so the engine refused every
    // one of them, correctly, and the app threw the refusal away.
    //
    // They stayed green for the whole life of the feature because the MOCK read
    // the same wrong keys, so the test double agreed with the bug. What stops
    // the twelfth is not this comment: it is `StudioCatalogSchema`, which the
    // mock now validates through, so a wrong key fails under
    // `MAJIKS_ENGINE=mock` too.

    /// Mint a journal-stable id for an object the UI is about to create.
    ///
    /// Same shape and same reason as `mintAutoPointID` and
    /// `RealStudioEngine.mintClipId`: the engine never mints an id at apply
    /// time, because a minted id would make replay diverge from the live model.
    /// So the thing that does not exist yet gets its name here.
    private func mintTimelineID(_ prefix: String) -> String {
        autoPointCounter += 1
        return "\(prefix)_\(UInt64(Date().timeIntervalSince1970 * 1000) & 0xFFFFFFF)_\(autoPointCounter)"
    }

    /// Drop a marker at a bar, or move/rename the one already there.
    ///
    /// `marker.set` is an UPSERT keyed on `markerId`, so re-using the id of a
    /// marker already at this bar edits it instead of stacking a second one on
    /// top — which is what "Add Marker Here" twice in the same place should do.
    func setMarker(name: String, bar: Int) {
        guard !name.isEmpty else { return }
        let existing = snapshot?.markers.first(where: { $0.bar == bar })?.id
        send(.catalog(name: "marker.set", params: [
            "markerId": existing ?? mintTimelineID("mk"),
            "positionTicks": Int64(max(0, bar)) * timeSignature.ticksPerBar,
            "label": name,
        ]), refusalSays: "Could not add that marker. Nothing was altered.")
    }

    func removeMarker(markerID: String) {
        guard !markerID.isEmpty else { return }
        send(.catalog(name: "marker.remove", params: ["markerId": markerID]),
             refusalSays: "Could not remove that marker. It may already be gone.")
    }

    /// Mark a section of the arrangement, or rename/move the one starting here.
    ///
    /// NO LENGTH, and that is the contract rather than an omission: the engine
    /// models a section as a START (`Section { id, name, start_ticks, color }`)
    /// and derives its length from the next section's start. The old signature
    /// took `lengthBars` and a `role` and sent both, and `section.set`'s schema
    /// declares neither — two `additionalProperties: false` violations in one
    /// envelope, on top of the missing `sectionId`. The length the ruler draws
    /// and the role that colours it are both derived on the read side, where
    /// the neighbouring sections are known.
    func setSection(name: String, startBar: Int) {
        guard !name.isEmpty else { return }
        let existing = snapshot?.sections.first(where: { $0.startBar == startBar })?.id
        send(.catalog(name: "section.set", params: [
            "sectionId": existing ?? mintTimelineID("sec"),
            "name": name,
            "startTicks": Int64(max(0, startBar)) * timeSignature.ticksPerBar,
        ]), refusalSays: "Could not add that section. Nothing was altered.")
    }

    func removeSection(sectionID: String) {
        guard !sectionID.isEmpty else { return }
        send(.catalog(name: "section.remove", params: ["sectionId": sectionID]),
             refusalSays: "Could not remove that section. It may already be gone.")
    }

    // MARK: Track property commands

    func renameTrack(_ trackID: UUID, name: String) {
        guard !name.isEmpty else { return }
        send(.catalog(name: "track.rename", params: [
            "trackId": trackID.uuidString,
            "name": name,
        ]), refusalSays: "Could not rename that track. It still has its old name.")
    }

    func reorderTrack(_ trackID: UUID, to index: Int) {
        send(.catalog(name: "track.reorder", params: [
            "trackId": trackID.uuidString,
            "newIndex": max(0, index),
        ]), refusalSays: "Could not move that track. It stayed where it was.")
    }

    /// Colour a track from the eight-swatch menu.
    ///
    /// Takes a `StudioTrackColor` and not a `String`: the contract's pattern is
    /// `^#[0-9A-Fa-f]{6}$` and the menu was passing `"blue"`. The names were
    /// right, the value was refused, and nothing said so.
    func setTrackColor(_ trackID: UUID, color: StudioTrackColor) {
        send(.catalog(name: "track.setColor", params: [
            "trackId": trackID.uuidString,
            "color": color.hex,
        ]), refusalSays: "Could not recolour that track. It kept its old colour.")
    }

    /// Set a track's lane height.
    ///
    /// Clamped to 40…400 rather than the schema's own 24…400: 40 is the
    /// narrowest row the header can draw its controls in, and staying inside
    /// the contract's range is the point, not matching it exactly.
    func setTrackHeight(_ trackID: UUID, height: Int) {
        send(.catalog(name: "track.setHeight", params: [
            "trackId": trackID.uuidString,
            "heightPx": max(40, min(400, height)),
        ]), refusalSays: "Could not resize that track. It kept its old height.")
    }

    // MARK: Clip property commands

    func renameClip(_ clipID: UUID, name: String) {
        guard !name.isEmpty else { return }
        send(.catalog(name: "clip.rename", params: [
            "clipId": clipID.uuidString,
            "name": name,
        ]), refusalSays: "Could not rename that clip. It still has its old name.")
    }

    /// Trim a clip's gain, independent of its track fader.
    ///
    /// Clamped to the contract's own -60…+12 dB. It used to clamp to +24, so
    /// the clamp itself could hand the engine a value the schema rejects —
    /// a refusal produced by the code whose job was to prevent one.
    func setClipGain(_ clipID: UUID, gainDB: Double) {
        send(.catalog(name: "clip.setGain", params: [
            "clipId": clipID.uuidString,
            "gainDb": clampGainDB(gainDB),
        ]), refusalSays: "Could not change that clip's level. It stayed as it was.")
    }

    func setClipMute(_ clipID: UUID, muted: Bool) {
        send(.catalog(name: "clip.mute", params: [
            "clipId": clipID.uuidString,
            "muted": muted,
        ]), refusalSays: muted ? "Could not mute that clip." : "Could not unmute that clip.")
    }

    // MARK: Automation commands (L12)

    private var autoPointCounter = 0

    /// Mint a fresh, journal-stable automation point id.
    func mintAutoPointID() -> String { mintTimelineID("ap") }

    func addAutoPoint(_ trackID: UUID, target: StudioAutoTarget, id: String, positionTicks: Int64, value: Double) {
        send(.autopointAdd(trackID: trackID, target: target, pointID: id,
                           positionTicks: max(0, positionTicks), value: value))
    }

    func moveAutoPoint(_ trackID: UUID, target: StudioAutoTarget, id: String, positionTicks: Int64, value: Double) {
        send(.autopointMove(trackID: trackID, target: target, pointID: id,
                            positionTicks: max(0, positionTicks), value: value))
    }

    func removeAutoPoint(_ trackID: UUID, target: StudioAutoTarget, id: String) {
        send(.autopointRemove(trackID: trackID, target: target, pointID: id))
    }

    func clearAutoLane(_ trackID: UUID, target: StudioAutoTarget) {
        send(.autolaneClear(trackID: trackID, target: target))
    }

    /// Show or hide an automation lane. Tracks view state locally AND mirrors it
    /// onto the bus so an agent watching gets the same view toggle (parity).
    func setAutoLaneVisible(_ trackID: UUID, target: StudioAutoTarget, visible: Bool) {
        let key = StudioAutoLaneKey(trackID: trackID, target: target)
        if visible { visibleAutomationLanes.insert(key) } else { visibleAutomationLanes.remove(key) }
        send(.autolaneShow(trackID: trackID, target: target, visible: visible))
    }

    /// Whether a lane should render: user-toggled visible, or it carries points.
    func isAutoLaneShown(_ track: StudioTrackSnapshot, target: StudioAutoTarget) -> Bool {
        if visibleAutomationLanes.contains(StudioAutoLaneKey(trackID: track.id, target: target)) {
            return true
        }
        return !track.automation(target).isEmpty
    }

    // MARK: Undo / redo (works on mixer + automation moves)

    func undo() {
        overridesAwaitRevisionAbove = lastAdoptedRevision
        Task { await engine.undo() }
    }

    func redo() {
        overridesAwaitRevisionAbove = lastAdoptedRevision
        Task { await engine.redo() }
    }

    /// Cmd+E: split at the playhead. Targets selected clips under the
    /// playhead, or every clip under it when nothing is selected.
    func splitAtPlayhead() {
        guard let snapshot else { return }
        let ticks = playheadTicks(now: ProcessInfo.processInfo.systemUptime)
        let targets = StudioSelectionOps.splitTargets(
            atTicks: ticks, selection: selection, tracks: snapshot.tracks)
        for clipID in targets {
            send(.clipSplit(clipID: clipID, atTicks: ticks))
        }
    }

    /// Cmd+D: duplicate the selected clips in place (each lands after itself).
    func duplicateSelection() {
        for clipID in selection.clipIDs {
            send(.clipDuplicate(clipID: clipID))
        }
    }

    /// Delete the selected clips as ONE undo step. A single clip is one bare
    /// `clip.remove`; several ride a txn.begin/txn.commit bracket so Cmd-Z
    /// takes the whole gesture back at once. Sends are awaited IN ORDER (the
    /// fire-and-forget `send` would let a txn marker overtake its contents).
    /// The selection is cleared on success, not optimistically — a refused
    /// remove must not leave a clip deselected but still on the timeline.
    @discardableResult
    func deleteSelection() -> Task<Void, Never>? {
        let clipIDs = Array(selection.clipIDs)
        guard !clipIDs.isEmpty else { return nil }
        overridesAwaitRevisionAbove = lastAdoptedRevision
        return Task { @MainActor in
            let result: StudioCommandResult
            if clipIDs.count == 1 {
                result = await engine.send(.clipRemove(clipID: clipIDs[0]))
            } else {
                result = await transacted(
                    reason: "delete \(clipIDs.count) clips",
                    clipIDs.map { StudioEngineCommand.clipRemove(clipID: $0) })
            }
            guard result.ok else {
                ToastManager.shared.show(result.message ?? "Could not delete the clip.",
                                         style: .warning, seconds: ToastDuration.actionable)
                return
            }
            selection.clipIDs.subtract(clipIDs)
            await adoptFresh()
        }
    }

    // MARK: Deleting tracks + instruments (the missing destructive affordances)
    //
    // Both are context-menu actions on the track header. No confirmation
    // dialog: every step is journaled and undo truthfully restores devices,
    // zones, fx and automation (apply.rs's track_restore_sequence), so Cmd-Z
    // is the safety net. A refusal (e.g. the stranded-lane guard on
    // track.remove) surfaces the engine's own message, which names the remedy.

    /// Delete a track and everything on it as ONE undo step.
    ///
    /// The engine refuses `track.remove` while the track still has clips
    /// (track_not_empty), so a populated track deletes as txn.begin →
    /// clip.remove × N → track.remove → txn.commit. If any step refuses, the
    /// already-applied steps are rolled back (see `transacted`) and the
    /// engine's message is surfaced instead of leaving a half-deleted track.
    @discardableResult
    func deleteTrack(_ trackID: UUID) -> Task<Void, Never>? {
        guard let track = snapshot?.tracks.first(where: { $0.id == trackID }) else { return nil }
        guard snapshot?.transport.recordingTrackID != trackID else {
            ToastManager.shared.show(
                "Stop recording before deleting the track it is capturing onto.", style: .warning)
            return nil
        }
        let clips = track.clips
        overridesAwaitRevisionAbove = lastAdoptedRevision
        return Task { @MainActor in
            let result: StudioCommandResult
            if clips.isEmpty {
                result = await engine.send(.trackRemove(trackID: trackID))
            } else {
                result = await transacted(
                    reason: "delete track \(track.name)",
                    clips.map { StudioEngineCommand.clipRemove(clipID: $0.id) }
                        + [.trackRemove(trackID: trackID)])
            }
            guard result.ok else {
                ToastManager.shared.show(result.message ?? "Could not delete the track.",
                                         style: .warning, seconds: ToastDuration.actionable)
                return
            }
            // Aftermath: nothing may keep pointing at the dead track. The piano
            // roll follows editableMidiClipID (StudioRootView closes it when
            // that goes nil), so clearing the selection here is what moves it.
            selection.clipIDs.subtract(clips.map(\.id))
            expandedTakeLanes.remove(trackID)
            visibleAutomationLanes = visibleAutomationLanes.filter { $0.trackID != trackID }
            await adoptFresh()
            ToastManager.shared.show("Deleted \(track.name). Cmd-Z brings it back.",
                                     style: .success, seconds: ToastDuration.actionable)
        }
    }

    /// Remove an instrument from a track: one journaled `device.remove`, whose
    /// multi-inverse restores the device and its zones on undo.
    ///
    /// The result is now visible in THREE places, because a toast alone was not
    /// enough: the header's instrument chip disappears (the state itself
    /// changed on screen), a `+ Instrument` button takes its place (the way
    /// back is where the thing used to be), and the toast — in the Studio's own
    /// frame, for `ToastDuration.actionable` — names both routes back.
    @discardableResult
    func removeInstrument(trackID: UUID, deviceID: String) -> Task<Void, Never> {
        let kindLabel = snapshot?.tracks.first(where: { $0.id == trackID })?
            .devices.first(where: { $0.id == deviceID })?.instrumentLabel ?? "instrument"
        overridesAwaitRevisionAbove = lastAdoptedRevision
        return Task { @MainActor in
            let result = await engine.send(.deviceRemove(trackID: trackID, deviceID: deviceID))
            guard result.ok else {
                ToastManager.shared.show(result.message ?? "Could not remove the instrument.",
                                         style: .warning, seconds: ToastDuration.actionable)
                return
            }
            await adoptFresh()
            ToastManager.shared.show(
                "Removed the \(kindLabel). Press + Instrument on the track to put one back, or Cmd-Z.",
                style: .success, seconds: ToastDuration.actionable)
        }
    }

    /// The track whose instrument panel is open, or nil. Drives a sheet in
    /// StudioRootView; nil-ing it closes the panel.
    @Published var instrumentPanelTrackID: UUID?

    /// The file name behind a bound `sourceID`, or nil when this build cannot
    /// know it — see `StudioProjectSnapshot.sourceName`. Nil is the honest
    /// answer for an asset the engine could not load, and the pad grid prints
    /// "sound not found" for it rather than looking bound.
    func soundName(_ sourceID: String) -> String? {
        snapshot?.sourceName(sourceID)
    }

    /// Open the instrument panel for a track, but only when there is something
    /// in it to edit.
    ///
    /// This used to demand `playsSamples`, on the reasoning that "a Synth has no
    /// sound to load, so offering the panel for one would be a door onto an
    /// empty room". The room is no longer empty: `device.param.set` put the
    /// synth's waveform and envelope in it. Until that landed, a synth track had
    /// NO route into this panel from anywhere — the chip was not a button and
    /// the context menu had no "Edit Synth…" item — so the four waveforms sat
    /// behind a door with no handle.
    func openInstrumentPanel(trackID: UUID) {
        guard snapshot?.tracks.first(where: { $0.id == trackID })?
            .devices.first?.hasAnEditablePanel == true else { return }
        instrumentPanelTrackID = trackID
    }

    // MARK: - What the instrument sounds like
    //
    // One gesture, one undo step, always: a preset writes eight parameters and
    // they land inside ONE txn bracket, so Cmd-Z takes the whole sound back
    // rather than peeling it apart one slider at a time. That is the same rule
    // the piano roll's chord drag follows and for the same reason.

    /// Apply a named sound to a track's instrument.
    @discardableResult
    func applyInstrumentPreset(trackID: UUID, deviceID: String,
                               _ preset: StudioInstrumentPreset) -> Task<Void, Never> {
        overridesAwaitRevisionAbove = lastAdoptedRevision
        return Task { @MainActor in
            let result = await transacted(
                reason: "Sound: \(preset.name)",
                preset.commands(trackID: trackID, deviceID: deviceID))
            guard result.ok else {
                let detail = result.message ?? "the engine refused one of the eight synth parameters"
                ToastManager.shared.show(
                    "Could not change \(preset.name): \(detail) Make sure this track still has a " +
                    "Synth instrument, then try again.",
                    style: .warning, seconds: ToastDuration.actionable)
                return
            }
            await adoptFresh()
            ToastManager.shared.show(
                "\(preset.name). Play a key to hear it — Cmd-Z puts the old sound back.",
                style: .success)
        }
    }

    /// Set ONE instrument parameter — the raw controls underneath the presets.
    ///
    /// A single `device.param.set`, so it is its own undo step: someone nudging
    /// a filter expects one Cmd-Z to undo one nudge, not the whole patch.
    @discardableResult
    func setInstrumentParam(trackID: UUID, deviceID: String,
                            key: String, value: Double) -> Task<Void, Never> {
        overridesAwaitRevisionAbove = lastAdoptedRevision
        return Task { @MainActor in
            let result = await engine.send(.catalog(name: "device.param.set", params: [
                "trackId": trackID.uuidString,
                "deviceId": deviceID,
                "key": key,
                "value": value,
            ]))
            guard result.ok else {
                ToastManager.shared.show(result.message ?? "Could not change that.",
                                         style: .warning, seconds: ToastDuration.actionable)
                return
            }
            await adoptFresh()
        }
    }

    // MARK: - Loading a sound: what makes the sampler and the drum rack real
    //
    // The multi-zone sampler and the sixteen-pad rack were finished, RT-safe
    // and tested long before this, and completely unreachable: `device.add`
    // could make one, and NOTHING in the app could put a sound into it. So the
    // only instrument a person could create was a synth, and 13,971 recordings
    // in the sounds vault were not playable from a keyboard at all.
    //
    // Every gesture below is one call to `engine.bindSamples`, which is one
    // transaction on the engine's journal, which is one Cmd-Z. Creating the
    // instrument and giving it its first sound are deliberately the SAME
    // gesture: an instrument with no zones is a hard compile error by design,
    // so a two-step version would put the project into a state that cannot
    // render between the two steps.

    /// Load one sound across the whole keyboard, creating a Sampler on `track`.
    ///
    /// THE easy path, and the common one for the vault: pick a file, play the
    /// keys. Zone mapping — different sounds on different key ranges — is the
    /// advanced case and lives in the instrument panel.
    @discardableResult
    func loadSamplerSound(trackID: UUID, path: String,
                          rootPitch: Int = StudioSampler.defaultRootPitch) -> Task<Void, Never> {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let onTrack = trackLabel(trackID)
        return bind(
            StudioSampleBindRequest(
                trackID: trackID, deviceID: nil, kind: "sampler",
                bindings: [.acrossTheKeyboard(path, rootPitch: rootPitch)],
                reason: "Load \(name) into a sampler"),
            success: "Loaded \(name) across the keyboard. Play any key to hear it — " +
                     "\(StudioPitchName.name(rootPitch)) plays it at its original speed. Cmd-Z undoes it.",
            successCreating:
                     "\(onTrack) had nothing to play sounds with, so a Sampler — an instrument " +
                     "that plays a recording back at whatever key you press — was made on it, " +
                     "with \(name) loaded across the keyboard. Play any key to hear it; " +
                     "\(StudioPitchName.name(rootPitch)) plays it at its original speed. " +
                     "Cmd-Z takes the instrument and the sound back together.",
            failure: "Could not load that sound.")
    }

    /// "Track 3" for the header's name, or a neutral phrase when the snapshot
    /// has not caught up. Never an empty string dropped mid-sentence.
    private func trackLabel(_ trackID: UUID) -> String {
        let name = snapshot?.tracks.first(where: { $0.id == trackID })?.name ?? ""
        return name.isEmpty ? "That track" : name
    }

    /// Build a Drum Rack from a set of files, one per pad, starting at the
    /// General MIDI kick.
    ///
    /// Files past the sixteenth are DROPPED rather than sent: the engine
    /// refuses a kit wider than the rack outright, and a refusal for "you
    /// picked 20 files" is not something a person can act on, whereas "the
    /// first 16 landed" is.
    @discardableResult
    func loadDrumRack(trackID: UUID, paths: [String]) -> Task<Void, Never> {
        let usable = Array(paths.prefix(StudioDrumRack.padCount))
        let dropped = paths.count - usable.count
        let bindings = usable.enumerated().map { index, path in
            StudioSampleBinding.pad(path, key: StudioDrumRack.defaultBaseKey + index)
        }
        let padWord = usable.count == 1 ? "pad" : "pads"
        let onTrack = trackLabel(trackID)
        var message = "Built a drum rack with \(usable.count) \(padWord), starting at " +
            "\(StudioPitchName.name(StudioDrumRack.defaultBaseKey)). Cmd-Z undoes the whole thing."
        // The instrument itself is the thing that appeared, so it leads.
        var creating = "\(onTrack) had nothing to play sounds with, so a Drum Rack — an " +
            "instrument that puts one sound on each key — was made on it, with \(usable.count) " +
            "\(padWord) starting at \(StudioPitchName.name(StudioDrumRack.defaultBaseKey)). " +
            "Cmd-Z takes the instrument and every pad back together."
        if dropped > 0 {
            let tail = " \(dropped) file\(dropped == 1 ? "" : "s") did not fit: a rack holds " +
                "\(StudioDrumRack.padCount)."
            message += tail
            creating += tail
        }
        return bind(
            StudioSampleBindRequest(
                trackID: trackID, deviceID: nil, kind: "drum",
                bindings: bindings, reason: "Build a drum rack"),
            success: message,
            successCreating: creating,
            failure: "Could not build that drum rack.")
    }

    /// Put a sound on ONE pad of an existing rack, or replace what is on it.
    /// `replacing` is the zone already on that key, removed inside the same
    /// undo unit so the key never briefly holds two sounds.
    @discardableResult
    func loadDrumPad(trackID: UUID, deviceID: String, key: Int, path: String,
                     replacing zoneID: String? = nil) -> Task<Void, Never> {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let keyName = StudioPitchName.name(key)
        return bind(
            StudioSampleBindRequest(
                trackID: trackID, deviceID: deviceID, kind: nil,
                removeZoneIDs: zoneID.map { [$0] } ?? [],
                bindings: [.pad(path, key: key)],
                reason: zoneID == nil ? "Load a drum pad" : "Change a drum pad's sound"),
            success: "\(keyName) now plays \(name). Cmd-Z undoes it.",
            failure: "Could not load that sound onto \(keyName).")
    }

    /// Replace the sound a sampler zone plays, keeping its key range and root.
    @discardableResult
    func replaceSamplerSound(trackID: UUID, deviceID: String,
                             zone: StudioZoneSnapshot, path: String) -> Task<Void, Never> {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return bind(
            StudioSampleBindRequest(
                trackID: trackID, deviceID: deviceID, kind: nil,
                removeZoneIDs: [zone.id],
                bindings: [StudioSampleBinding(
                    sourcePath: path, rootPitch: zone.rootPitch,
                    loPitch: zone.loPitch, hiPitch: zone.hiPitch,
                    gainDB: zone.gainDB, pan: zone.pan)],
                reason: "Change the sound"),
            success: "Now playing \(name). Cmd-Z puts the old sound back.",
            failure: "Could not swap that sound.")
    }

    /// Retune a zone: same sound, different "the recording sounds at this key".
    ///
    /// There is deliberately no `device.zone.set` in the catalog — an edit is
    /// remove + add, which keeps every inverse EXACT rather than inventing
    /// per-field defaults the model would then have to guarantee forever. So
    /// this needs the zone's CURRENT source, which means the asset has to still
    /// be loaded; it refuses honestly when it is not, rather than binding a
    /// path it guessed.
    @discardableResult
    func setZoneRootPitch(trackID: UUID, deviceID: String,
                          zone: StudioZoneSnapshot, rootPitch: Int) -> Task<Void, Never>? {
        guard (0...127).contains(rootPitch), rootPitch != zone.rootPitch else { return nil }
        guard let path = snapshot?.loadedSources[zone.sourceID], !path.isEmpty else {
            ToastManager.shared.show(
                "This sound's file is not loaded, so its root key cannot be changed here.",
                style: .warning, seconds: ToastDuration.actionable)
            return nil
        }
        return bind(
            StudioSampleBindRequest(
                trackID: trackID, deviceID: deviceID, kind: nil,
                removeZoneIDs: [zone.id],
                bindings: [StudioSampleBinding(
                    sourcePath: path, rootPitch: rootPitch,
                    loPitch: zone.loPitch, hiPitch: zone.hiPitch,
                    gainDB: zone.gainDB, pan: zone.pan)],
                reason: "Set the root key"),
            success: "This sound now plays at its original speed on " +
                     "\(StudioPitchName.name(rootPitch)). Cmd-Z undoes it.",
            failure: "Could not change the root key.")
    }

    /// Clear one drum pad. Refused by the engine when it is the LAST sound in
    /// the instrument — an instrument with nothing to play cannot render — and
    /// that refusal names the remedy, so it is surfaced verbatim.
    @discardableResult
    func clearDrumPad(trackID: UUID, deviceID: String, zone: StudioZoneSnapshot) -> Task<Void, Never> {
        let keyName = StudioPitchName.name(zone.loPitch)
        return bind(
            StudioSampleBindRequest(
                trackID: trackID, deviceID: deviceID, kind: nil,
                removeZoneIDs: [zone.id], bindings: [],
                reason: "Clear a drum pad"),
            success: "\(keyName) is empty again. Cmd-Z puts the sound back.",
            failure: "Could not clear \(keyName).")
    }

    /// The one place a bind result is turned into UI. Every gesture above
    /// routes through here so the refusal path is identical: the ENGINE's own
    /// sentence, which names the remedy, rather than a paraphrase that would
    /// drift from what the engine actually enforces.
    ///
    /// # Why there are two success sentences
    ///
    /// Loading a sound onto a track that has no instrument CREATES ONE —
    /// `bind_samples` journals `device.add` in the same transaction — and the
    /// app used to say only "Loaded kick.wav across the keyboard". A Sampler
    /// appeared on the track and the word never came up, which is the same
    /// defect as a track appearing unannounced, one object down.
    ///
    /// `successCreating` is chosen by `outcome.createdDevice`, which the ENGINE
    /// computes from whether it actually journaled the `device.add` — not from
    /// `request.deviceID == nil`, which is only what the app ASKED for. Those
    /// two disagree the moment the engine takes any path the caller did not
    /// predict, and a sentence derived from the request would then describe a
    /// thing that did not happen.
    ///
    /// There is no permanent half here to go with it, on purpose: the track
    /// header's instrument chip already shows "Sampler" for as long as the
    /// device exists, and it is drawn from the same snapshot. This is the "what
    /// just happened" half only.
    /// WHICH of the two sentences a successful bind reports.
    ///
    /// A free function rather than an expression inside `bind`, and the reason
    /// is a hole a mutation check found: end-to-end, this branch cannot be
    /// exercised in both directions. `loadSamplerSound` and `loadDrumRack` are
    /// the only gestures that supply `successCreating`, and both mint the
    /// instrument — the engine refuses a SECOND instrument on a track outright
    /// (`bind_samples`: "track … already plays a …"), so there is no way to
    /// call them and get `createdDevice == false`. The gestures that do get
    /// `false` (swap a zone's sound, load one pad) pass no `successCreating` at
    /// all, so both branches collapse to the same string and a mutation that
    /// always took the creating branch changed nothing observable and PASSED
    /// the whole suite.
    ///
    /// Pulled out here, the decision is testable directly, which is the only
    /// place it can be tested at all.
    static func bindMessage(createdDevice: Bool,
                            success: String,
                            successCreating: String?) -> String {
        createdDevice ? (successCreating ?? success) : success
    }

    @discardableResult
    private func bind(_ request: StudioSampleBindRequest,
                      success: String,
                      successCreating: String? = nil,
                      failure: String) -> Task<Void, Never> {
        overridesAwaitRevisionAbove = lastAdoptedRevision
        return Task { @MainActor in
            let outcome = await engine.bindSamples(request)
            guard outcome.ok else {
                ToastManager.shared.show(outcome.message ?? failure,
                                         style: .warning, seconds: ToastDuration.actionable)
                return
            }
            await adoptFresh()
            let said = Self.bindMessage(createdDevice: outcome.createdDevice,
                                        success: success, successCreating: successCreating)
            ToastManager.shared.show(said, style: .success, seconds: ToastDuration.actionable)
        }
    }

    /// Put an instrument back on a track that has none: one journaled
    /// `device.add`, undoable like every other mutation.
    ///
    /// Synth ONLY, and that is still right. A sampler or drum device without a
    /// bound source is a hard compile error by design, so its creation cannot
    /// be a bare `device.add` — it is `loadSamplerSound` / `loadDrumRack`
    /// above, where picking the sound and creating the instrument are the same
    /// gesture. This is the no-sound-needed case.
    @discardableResult
    func addInstrument(trackID: UUID) -> Task<Void, Never>? {
        guard let track = snapshot?.tracks.first(where: { $0.id == trackID }) else { return nil }
        guard track.devices.isEmpty else {
            // Not a refusal worth a toast: the affordance is only offered on an
            // empty track, so this is a stale click, not a user error.
            return nil
        }
        let deviceID = "inst_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
        overridesAwaitRevisionAbove = lastAdoptedRevision
        return Task { @MainActor in
            let result = await engine.send(
                .deviceAdd(trackID: trackID, deviceID: deviceID, kind: "synth"))
            guard result.ok else {
                ToastManager.shared.show(result.message ?? "Could not add an instrument.",
                                         style: .warning, seconds: ToastDuration.actionable)
                return
            }
            await adoptFresh()
            ToastManager.shared.show(
                "Added a Synth to \(track.name). Play the keys to hear it. Cmd-Z undoes it.",
                style: .success, seconds: ToastDuration.actionable)
        }
    }

    /// Send `commands` inside a txn.begin/txn.commit bracket so they land as
    /// ONE undo unit. Ordered: every send is awaited (the fire-and-forget
    /// `send` would let a marker overtake its contents). On a refusal partway
    /// through, the bracket is still committed — closing the PARTIAL unit —
    /// and then undone, so nothing the user did not ask for stays half-done;
    /// the refusing command's own message is returned for surfacing. The undo
    /// only runs when something actually applied: an empty committed unit
    /// pushes nothing, and a blind undo would take back the user's PREVIOUS
    /// gesture instead.
    private func transacted(
        reason: String,
        _ commands: [StudioEngineCommand]
    ) async -> StudioCommandResult {
        let txnID = "ui_\(UUID().uuidString.prefix(12))"
        let begin = await engine.send(.catalog(name: "txn.begin", params: ["txnId": txnID, "reason": reason]))
        guard begin.ok else { return begin }
        var applied = 0
        var failure: StudioCommandResult?
        for command in commands {
            let r = await engine.send(command)
            guard r.ok else { failure = r; break }
            applied += 1
        }
        let commit = await engine.send(.catalog(name: "txn.commit", params: ["txnId": txnID]))
        guard let failure else {
            return commit.ok ? StudioCommandResult(ok: true, message: nil) : commit
        }
        if commit.ok, applied > 0 { _ = await engine.undo() }   // roll the partial unit back
        if !commit.ok, applied > 0 { _ = await engine.undo() }   // do not strand a partial unit
        return failure
    }

    /// Z: fit the whole project into the viewport.
    func zoomToFit(viewportWidth: CGFloat) {
        guard projectLengthTicks > 0, viewportWidth > 0 else { return }
        pxPerTick = StudioTimelineMath.zoomToFit(
            projectLengthTicks: projectLengthTicks, viewportWidth: viewportWidth)
        scrollTicks = 0
    }

    func zoomToFitViewport() {
        zoomToFit(viewportWidth: timelineViewportWidth)
    }

    func zoom(by factor: CGFloat, anchorPx: CGFloat) {
        let old = pxPerTick
        let new = StudioTimelineMath.clampZoom(old * factor)
        guard new != old else { return }
        scrollTicks = StudioTimelineMath.scrollPreservingAnchor(
            anchorPx: anchorPx, oldPxPerTick: old, newPxPerTick: new,
            oldScrollTicks: scrollTicks)
        pxPerTick = new
    }

    func pan(byPx dx: CGFloat, dyPx dy: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
        if dx != 0, pxPerTick > 0 {
            let dTicks = Int64((dx / pxPerTick).rounded())
            let maxScroll = max(0, projectLengthTicks - Int64(50 / pxPerTick))
            scrollTicks = min(max(0, scrollTicks + dTicks), maxScroll)
            if isPlaying { followPlayhead = false }   // manual pan wins
        }
        if dy != 0 {
            let maxY = max(0, contentHeight - viewportHeight)
            scrollY = min(max(0, scrollY + dy), maxY)
        }
    }

    /// R: arm the Revise panel for the selected region.
    func armReviseForSelection() {
        guard selection.region != nil else { return }
        reviseArmed = true
        inspectorCollapsed = false
    }

    func clearSelection() {
        selection = .empty
        reviseArmed = false
    }

    // MARK: - Revise / Extend / Add-a-Layer (L9): the killer feature

    /// Panel controls (bound by StudioInspectorView's Revise panel).
    @Published var reviseInstruction: String = ""
    @Published var reviseScope: Set<StudioStemKind> = [.drums, .other]
    @Published var reviseVariantCount: Int = 3
    @Published var reviseKeepLyrics: Bool = true
    @Published var reviseCrossfadeMs: Double = 20
    @Published var reviseSeedText: String = ""
    @Published private(set) var revising = false
    /// The live audition (nil = no revise in flight). Keys 1-9 pick a variant,
    /// A returns to the original, Return commits, Esc discards.
    @Published var audition: StudioAuditionState?
    @Published private(set) var finalizing = false

    private var parsedSeed: UInt64? {
        let t = reviseSeedText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : UInt64(t)
    }

    /// Which clips + stems a region-scope selection resolves to. A region that
    /// covers exactly one clip is an all-stems revise of that single mix clip;
    /// otherwise one clip per scoped stem (the unscoped stems are null-preserved
    /// by the engine).
    func reviseTargets(region: StudioRegionSelection) -> (clipIDs: [UUID], scope: [StudioStemKind], allStems: Bool) {
        guard let snapshot else { return ([], [], false) }
        var firstByKind: [StudioStemKind: UUID] = [:]
        var covering: [UUID] = []
        for track in snapshot.tracks {
            for clip in track.clips where clip.startTicks < region.endTicks && region.startTicks < clip.endTicks {
                covering.append(clip.id)
                if firstByKind[track.kind] == nil { firstByKind[track.kind] = clip.id }
            }
        }
        if covering.count == 1 { return ([covering[0]], [], true) }
        let order: [StudioStemKind] = [.vocals, .drums, .bass, .other]
        let kinds = order.filter { reviseScope.contains($0) && firstByKind[$0] != nil }
        let clips = kinds.compactMap { firstByKind[$0] }
        return (clips, kinds, false)
    }

    /// Generate the draft variants for the selected region (the "Generate N
    /// takes" button, or R after arming). Non-blocking: take lanes fill in and
    /// audition begins as soon as the engine returns.
    func generateRevise() {
        guard let region = selection.region, !revising, audition == nil else { return }
        let (clipIDs, scope, allStems) = reviseTargets(region: region)
        guard !clipIDs.isEmpty else {
            ToastManager.shared.show("Select bars over some audio first.", style: .info)
            return
        }
        revising = true
        reviseArmed = true
        perStemMix.removeAll()
        let keepLyrics = reviseKeepLyrics && (allStems || scope.contains(.vocals))
        let req = StudioReviseRequest(
            clipIDs: clipIDs, regionStartTicks: region.startTicks, regionEndTicks: region.endTicks,
            scope: scope, allStems: allStems, instruction: reviseInstruction,
            variants: max(1, min(reviseVariantCount, 8)), keepLyrics: keepLyrics,
            crossfadeMs: reviseCrossfadeMs, seed: parsedSeed)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await engine.revise(req)
            revising = false
            guard outcome.ok, !outcome.variants.isEmpty else {
                ToastManager.shared.show(outcome.message ?? "Revise failed.", style: .warning)
                return
            }
            await adoptFresh()
            expandedTakeLanes = Set(snapshot?.tracks.compactMap { $0.takeLane != nil ? $0.id : nil } ?? [])
            let lo = outcome.auditionLoopStart
            let hi = max(lo + 1, outcome.auditionLoopEnd)
            audition = StudioAuditionState(
                variants: outcome.variants, draftTakeIDsByVariant: outcome.draftTakeIDsByVariant,
                loop: lo...hi, region: region, auditioningVariant: outcome.variants.first?.index)
            send(.transportLoopSet(start: lo, end: hi))
        }
    }

    /// Audition variant `index` (keys 1-9). No commit; just changes what plays.
    func auditionVariant(_ index: Int) {
        guard var a = audition, a.variants.contains(where: { $0.index == index }) else { return }
        a.auditioningVariant = index
        audition = a
        send(.transportLoopSet(start: a.loop.lowerBound, end: a.loop.upperBound))
    }

    /// Audition by number key (1-9); ignored when out of range.
    func auditionKey(_ number: Int) {
        if let a = audition, let idx = a.variantForKey(number) { auditionVariant(idx) }
    }

    /// A: return to the original take while auditioning.
    func auditionOriginal() {
        guard var a = audition else { return }
        a.auditioningVariant = nil
        audition = a
    }

    /// Return: commit the auditioned variant (one undo transaction), then kick
    /// the background finalize (draft/commit two-phase). Honors the per-stem mix
    /// (drums from take 2, other from take 3) when the user set one.
    func commitAudition() {
        guard let a = audition else { return }
        guard let proms = effectivePromotions(a) else {
            ToastManager.shared.show("Pick a take (1-9), or press A for the original.", style: .info)
            return
        }
        let bars = a.region.barRange(grid: barGrid)
        let drafts = proms.map(\.takeID)
        Task { [weak self] in
            guard let self else { return }
            let result = await engine.commitRevise(proms, reason: "revise bars \(bars.lowerBound)-\(bars.upperBound)")
            guard result.ok else {
                ToastManager.shared.show(result.message ?? "Commit failed.", style: .warning)
                return
            }
            finishAudition()
            await adoptFresh()
            ToastManager.shared.show("Committed. Revised bars \(bars.lowerBound)-\(bars.upperBound).", style: .success)
            // Background finalize: re-render the committed take at full quality
            // and swap seamlessly (the UI never blocks on the slow path).
            guard !drafts.isEmpty else { return }
            finalizing = true
            let swap = await engine.finalizeRevise(draftTakeIDs: drafts)
            finalizing = false
            if swap.ok { await adoptFresh() }
        }
    }

    /// Esc / Discard: drop the audition. Takes stay in the Takes history.
    func discardAudition() {
        guard let a = audition else { return }
        let ids = a.variants.flatMap { $0.promotions.map(\.takeID) }
        Task { [weak self] in
            guard let self else { return }
            _ = await engine.discardRevise(takeIDs: ids)
            finishAudition()
            await adoptFresh()
        }
    }

    private func finishAudition() {
        audition = nil
        perStemMix.removeAll()
        send(.transportLoopClear)
        clearSelection()
    }

    /// E: extend the clip under the selection (or the first selected clip) by a
    /// bar's worth of audio and commit the first tail (quick path; the full
    /// audition UI is the revise flagship).
    func extendSelection() {
        guard let snapshot else { return }
        let clipID = selection.clipIDs.first
            ?? selection.region.flatMap { region in
                snapshot.tracks.flatMap { $0.clips }.first { $0.startTicks < region.endTicks && region.startTicks < $0.endTicks }?.id
            }
        guard let clipID else {
            ToastManager.shared.show("Select a clip or a region, then press E to extend.", style: .info)
            return
        }
        let seconds = 60.0 / max(1, snapshot.tempoBPM) * 4.0 // one bar
        Task { [weak self] in
            guard let self else { return }
            let out = await engine.extendClip(clipID: clipID, addedSeconds: seconds, instruction: reviseInstruction, variants: 1)
            guard out.ok, let take = out.takes.first else {
                ToastManager.shared.show(out.message ?? "Extend failed.", style: .warning); return
            }
            let r = await engine.commitExtend(takeID: take.takeID, clipID: clipID)
            await adoptFresh()
            ToastManager.shared.show(r.ok ? "Extended." : (r.message ?? "Extend commit failed."), style: r.ok ? .success : .warning)
        }
    }

    /// Shift+R: add a new instrument layer that fits the selected region (lands
    /// on a new track), committing the first take (quick path).
    ///
    /// # It makes a TRACK, and it used to say "Added a layer."
    ///
    /// `revise::dispatch_layer` journals `track.add` before it generates
    /// anything — the layer lands on a row of its own so it can be muted, moved
    /// or deleted without disturbing what was already there — and the word
    /// "track" never appeared anywhere in what the app said. Someone who pressed
    /// Shift+R got a new row in the arrangement and a three-word sentence that
    /// did not mention it. Exactly the defect `originNote` was written for, one
    /// gesture over.
    ///
    /// TWO surfaces, as with a played track, and for different questions. The
    /// track header carries `originNote` forever, because "what is this row
    /// called Layer?" is asked ten minutes later. This sentence answers "what
    /// just happened?" and fades. It names the track it made, and it is honest
    /// about the undo shape — the engine prepares the track in one unit and
    /// commits the clip in another, so this genuinely IS two Cmd-Z presses and
    /// saying "one" would be a lie a user discovers the hard way.
    func addLayerForSelection() {
        guard let region = selection.region else {
            ToastManager.shared.show("Select bars, then Shift+R to add a layer.", style: .info)
            return
        }
        let instruction = reviseInstruction.isEmpty ? "new layer" : reviseInstruction
        Task { [weak self] in
            guard let self else { return }
            // "The id that wasn't there before" — the same identification
            // `performImport` uses, and for the same reason: the real engine
            // mints its own ids and `targetTrackID` is an engine id, not the
            // snapshot UUID the arrangement is keyed by.
            let before = Set(snapshot?.tracks.map(\.id) ?? [])
            let out = await engine.addLayer(
                instruction: instruction, regionStartTicks: region.startTicks, regionEndTicks: region.endTicks,
                contextClipID: nil, stem: .other, variants: max(1, min(reviseVariantCount, 8)))
            await adoptFresh()
            guard out.ok, let take = out.takes.first, let track = out.targetTrackID else {
                ToastManager.shared.show(out.message ?? "Add a Layer failed.", style: .warning); return
            }
            let r = await engine.commitLayer(takeID: take.takeID, targetTrackID: track, regionStartTicks: region.startTicks)
            await adoptFresh()
            guard r.ok else {
                ToastManager.shared.show(r.message ?? "Layer commit failed.", style: .warning); return
            }
            let made = snapshot?.tracks.first { !before.contains($0.id) }
            ToastManager.shared.show(
                made.map { track in
                    "Added a layer, on a new track called \(track.name). It has its own row in " +
                    "the arrangement, so you can mute it or delete it without touching what was " +
                    "already there. Cmd-Z takes the layer off; Cmd-Z again takes the track back."
                } ?? "Added a layer to the track that was already prepared for it. Cmd-Z takes it off.",
                style: .success, seconds: ToastDuration.actionable)
        }
    }

    /// Force-adopt the latest snapshot (used right after a workflow mutation so
    /// the take lanes / committed clips appear without waiting on the 30 Hz poll).
    private func adoptFresh() async {
        if let fresh = await engine.snapshot(ifNewerThan: nil) {
            lastAdoptedRevision = fresh.revision
            snapshot = fresh
        }
        await refreshTakes()
    }

    // MARK: Open in Studio (L8 landing)

    /// True while a landing is running (drives a lightweight progress state).
    @Published private(set) var landing = false
    /// Set when a landing fails, so the UI can surface why.
    @Published var landingError: String?

    /// Run the "Open in Studio" bridge for `request`: the engine analyzes,
    /// separates, and places the stems, then the next snapshot is the new
    /// session. Selection resets so the fresh session reads clean.
    func land(_ request: StudioLandingRequest) async {
        guard !landing else { return }
        landing = true
        landingError = nil
        clearSelection()
        let result = await engine.openInStudio(request)
        landing = false
        if !result.ok {
            landingError = result.message ?? "Open in Studio failed."
        } else {
            // Adopt the landed session immediately (do not wait for the poll).
            if let fresh = await engine.snapshot(ifNewerThan: nil) {
                lastAdoptedRevision = fresh.revision
                snapshot = fresh
                scrollTicks = 0
            }
        }
    }

    func toggleTakeLane(_ trackID: UUID) {
        if expandedTakeLanes.contains(trackID) {
            expandedTakeLanes.remove(trackID)
        } else {
            expandedTakeLanes.insert(trackID)
        }
    }

    // MARK: - Takes browser + per-stem mixing (L10)
    //
    // The browser reads `takes.list` (engine.takes) and drives take.promote /
    // take.auditionMix / purge, the SAME commands an agent uses. Per-stem mixing
    // composes ONE take per stem across the audition's variants (drums from take
    // 2, other from take 3) and commits it as one undo step (building on L9).

    /// Every generative take in the project (loaded from the engine).
    @Published private(set) var takesBrowserItems: [StudioTakeBrowserItem] = []
    /// The browser's interactive filter (search / region / kind / auditionable).
    @Published var takesFilter = StudioTakesFilter()
    /// The Takes tab's confirm-before-purge sheet.
    @Published var purgeConfirmShown = false
    /// Per-stem audition override: stem -> variant index. Empty = the globally
    /// auditioned variant applies to every stem.
    @Published var perStemMix: [StudioStemKind: Int] = [:]

    /// Load the take list from the engine (the browser's source of truth).
    func refreshTakes() async {
        takesBrowserItems = await engine.takes(query: .all)
    }

    /// The list the browser renders: engine takes through the interactive filter.
    func filteredTakes() -> [StudioTakeBrowserItem] {
        takesFilter.apply(takesBrowserItems)
    }

    /// The stems the current audition spans (in canonical order), for the
    /// per-stem mix control.
    func auditionStems() -> [StudioStemKind] {
        guard let a = audition, let base = a.variants.first else { return [] }
        let present = Set(base.promotions.map(\.stem))
        return [.vocals, .drums, .bass, .other].filter { present.contains($0) }
    }

    /// The variant index currently chosen FOR a stem (its override, else the
    /// globally auditioned variant).
    func stemMixVariant(_ stem: StudioStemKind) -> Int? {
        perStemMix[stem] ?? audition?.auditioningVariant
    }

    /// Choose which take (variant) a single stem uses while auditioning, and
    /// tell the engine which stem of that take is audible (take.auditionMix).
    func auditionStemVariant(_ stem: StudioStemKind, variant: Int) {
        guard let a = audition, a.variants.contains(where: { $0.index == variant }) else { return }
        perStemMix[stem] = variant
        // Keep the global pointer sensible so the audition list highlights too.
        if audition?.auditioningVariant == nil {
            var updated = a
            updated.auditioningVariant = variant
            audition = updated
        }
        if let v = a.variants.first(where: { $0.index == variant }),
           let p = v.promotions.first(where: { $0.stem == stem }) {
            let takeID = p.takeID
            Task { await engine.auditionMix(takeID: takeID, stems: [stem.rawValue]) }
        }
    }

    /// The promotions a commit should apply: one take PER stem, using the
    /// per-stem override where the user set one, else the auditioned variant.
    private func effectivePromotions(_ a: StudioAuditionState) -> [StudioPromotion]? {
        guard let base = a.auditioningVariant,
              let baseVariant = a.variants.first(where: { $0.index == base }) else { return nil }
        var out: [StudioPromotion] = []
        for prom in baseVariant.promotions {
            let chosen = perStemMix[prom.stem] ?? base
            if let v = a.variants.first(where: { $0.index == chosen }),
               let p = v.promotions.first(where: { $0.stem == prom.stem }) {
                out.append(p)
            } else {
                out.append(prom)
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Preview a take in place: navigate the timeline to its region (and select
    /// the clip it landed in, if committed) so its lineage shows in the inspector.
    func previewTake(_ item: StudioTakeBrowserItem) {
        guard let start = item.lineage.regionStartTicks, let end = item.lineage.regionEndTicks,
              end > start else {
            ToastManager.shared.show("This take has no region to preview.", style: .info)
            return
        }
        selection.clipIDs.removeAll()
        selection.region = StudioRegionSelection(rawStart: start, rawEnd: end)
        scrollTicks = max(0, start - timeSignature.ticksPerBar)
        // If this take is one of the live audition's variants, audition it.
        if let a = audition, let v = a.variants.first(where: {
            $0.promotions.contains(where: { $0.takeID == item.takeID })
        }) {
            auditionVariant(v.index)
        }
    }

    /// "More like this": prefill the Revise panel from a take's lineage (prompt +
    /// seed + region), so a re-roll is one edit away (design 3.4).
    func rerollFromTake(_ item: StudioTakeBrowserItem) {
        if let p = item.lineage.prompt { reviseInstruction = p }
        if let seed = item.lineage.seed { reviseSeedText = String(seed) }
        if let s = item.lineage.regionStartTicks, let e = item.lineage.regionEndTicks, e > s {
            selection.clipIDs.removeAll()
            selection.region = StudioRegionSelection(rawStart: s, rawEnd: e)
            scrollTicks = max(0, s - timeSignature.ticksPerBar)
        }
        reviseArmed = true
        inspectorCollapsed = false
        ToastManager.shared.show("Prefilled Revise from this take. Edit and Generate.", style: .info)
    }

    /// Drag-to-timeline: a take was dropped on the timeline at (trackID, ticks).
    /// Promote it into the clip under the drop (use this take here).
    func dropTake(takeID: String, trackID: UUID, atTicks: Int64) {
        guard let snapshot else { return }
        guard let track = snapshot.tracks.first(where: { $0.id == trackID }),
              let clip = track.clips.first(where: { $0.startTicks <= atTicks && atTicks < $0.endTicks })
                ?? track.clips.first(where: { $0.startTicks <= atTicks && atTicks < $0.endTicks + timeSignature.ticksPerBar }) else {
            ToastManager.shared.show("Drop a take onto a clip to use it there.", style: .info)
            return
        }
        placeTakeOnClip(takeID: takeID, clipID: clip.id)
    }

    /// Promote a take into a clip (drag-to-timeline / "Place" action).
    func placeTakeOnClip(takeID: String, clipID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            let r = await engine.placeTake(takeID: takeID, ontoClipID: clipID)
            await adoptFresh()
            ToastManager.shared.show(
                r.ok ? "Placed the take on the timeline." : (r.message ?? "Could not place the take."),
                style: r.ok ? .success : .warning)
        }
    }

    /// Purge take audio to reclaim space (confirmed by the browser's sheet).
    func purgeTakes(scope: StudioPurgeScope = .all) {
        Task { [weak self] in
            guard let self else { return }
            let r = await engine.purgeTakes(scope: scope)
            await adoptFresh()
            guard r.ok else {
                ToastManager.shared.show(r.message ?? "Purge failed.", style: .warning); return
            }
            let mb = Double(r.bytesReclaimed) / 1_048_576.0
            let space = r.bytesReclaimed > 0 ? String(format: " (%.1f MB)", mb) : ""
            ToastManager.shared.show(
                r.purgedCount == 0 ? "No purgeable takes." : "Purged \(r.purgedCount) take\(r.purgedCount == 1 ? "" : "s")\(space).",
                style: .success)
        }
    }

    // MARK: Drag transactions (edit-guard endpoints)

    func beginDrag(_ state: StudioDragState) {
        drag = state
    }

    /// Live drag update: stores an optimistic override so the canvas renders
    /// the provisional clip without waiting on the engine.
    func updateDragOverride(_ clip: StudioClipSnapshot) {
        overrides[clip.id] = clip
    }

    func endDrag() {
        let finished = drag
        drag = StudioDragState()
        switch finished.kind {
        case .clipMove:
            guard let clip = finished.provisionalClip, let track = finished.targetTrackID else { break }
            send(.clipMove(clipID: clip.id, toTrackID: track, toStartTicks: clip.startTicks))
        case .clipTrimLeading, .clipTrimTrailing:
            guard let clip = finished.provisionalClip else { break }
            send(.clipTrim(clipID: clip.id, newStartTicks: clip.startTicks,
                           newLengthTicks: clip.lengthTicks))
        case .fadeIn, .fadeOut:
            guard let clip = finished.provisionalClip else { break }
            send(.clipFadeSet(clipID: clip.id, fadeInTicks: clip.fadeInTicks,
                              fadeOutTicks: clip.fadeOutTicks))
        case .automationPoint:
            guard let trackID = finished.autoTrackID, let target = finished.autoTarget,
                  let point = finished.autoProvisional else { break }
            if finished.autoIsNew {
                addAutoPoint(trackID, target: target, id: point.id,
                             positionTicks: point.positionTicks, value: point.value)
            } else {
                moveAutoPoint(trackID, target: target, id: point.id,
                              positionTicks: point.positionTicks, value: point.value)
            }
        case .loopRegion:
            // ONE command on release, not one per mouse-move: the drag only
            // moved `loopDraft`. `setLoop` clears the draft, so the brace
            // hands over to engine truth on the next snapshot.
            guard let draft = loopDraft else { break }
            setLoop(startTicks: draft.lowerBound, endTicks: draft.upperBound)
        case .playheadScrub:
            // ONE seek on release, not one per mouse-move — see the note on
            // `playheadDraft`. Clearing the draft here hands the line back to
            // engine truth on the next snapshot; until then the draft and the
            // seek agree, so it does not jump backwards while the round trip
            // is in flight.
            guard let draft = playheadDraft else { break }
            playheadDraft = nil
            seek(toTicks: draft)
        case .none, .rubberBand, .rulerRegion:
            break
        }
    }

    /// Live automation-point drag: store the provisional so the canvas draws it
    /// under the cursor without waiting on the engine (edit-guard is active
    /// because `drag.kind != .none`).
    func updateAutoDragProvisional(_ point: StudioAutoPoint) {
        drag.autoProvisional = point
    }

    func cancelDrag() {
        overrides.removeAll()
        loopDraft = nil
        playheadDraft = nil
        drag = StudioDragState()
    }

    // MARK: Performance sweep (evidence for the 60 fps gate)

    /// Scripted pan + zoom oscillation over the fixture for `seconds`,
    /// driven at display rate; the canvas records real frame times.
    func runPerfSweep(viewportWidth: CGFloat, seconds: Double = 8.0) {
        guard !sweepActive, projectLengthTicks > 0 else { return }
        sweepActive = true
        frameStats.reset()
        frameStats.hudVisible = true
        let panSpan = Double(max(0, projectLengthTicks - Int64(viewportWidth / pxPerTick)))
        Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < seconds {
                guard let self else { return }
                let t = ProcessInfo.processInfo.systemUptime - start
                // Two pan passes and two zoom cycles across the sweep.
                let panPhase = 0.5 - 0.5 * cos(t / seconds * 2 * .pi * 2)
                self.scrollTicks = Int64(panSpan * panPhase)
                let zoomPhase = sin(t / seconds * 2 * .pi * 2)
                let base = 24.0 / CGFloat(StudioTick.ppq)
                self.pxPerTick = StudioTimelineMath.clampZoom(
                    base * pow(3.0, zoomPhase))
                try? await Task.sleep(nanoseconds: 8_000_000)   // ~120 Hz driver
            }
            guard let self else { return }
            self.sweepActive = false
            self.scrollTicks = 0
            self.pxPerTick = 24.0 / CGFloat(StudioTick.ppq)
            self.frameStats.finishSweep()
            self.frameStats.writeSweepResultsIfRequested(
                context: "100-clip/8-track mock fixture, scripted pan+zoom sweep")
        }
    }
}

// MARK: - Drag state

enum StudioDragKind: Equatable, Sendable {
    case none
    case clipMove
    case clipTrimLeading
    case clipTrimTrailing
    case fadeIn
    case fadeOut
    case rubberBand
    case rulerRegion
    case playheadScrub
    /// Dragging a loop brace in the ruler's own loop strip. Its own kind, and
    /// its own band of the ruler, so it can never be confused with the section
    /// drag (`rulerRegion`, a SELECTION) or with a scrub.
    case loopRegion
    /// Dragging (or drawing) an automation breakpoint in a lane under a track.
    case automationPoint
}

struct StudioDragState: Equatable, Sendable {
    var kind: StudioDragKind = .none
    var startPoint: CGPoint = .zero
    var currentPoint: CGPoint = .zero
    var shift = false
    /// Tick offset between the grab point and the clip start (move drags).
    var grabOffsetTicks: Int64 = 0
    var originalClip: StudioClipSnapshot?
    var provisionalClip: StudioClipSnapshot?
    var targetTrackID: UUID?
    /// Ruler drags: anchor tick of the region selection.
    var anchorTicks: Int64 = 0

    // Automation-point drag (kind == .automationPoint).
    var autoTrackID: UUID?
    var autoTarget: StudioAutoTarget?
    /// The point under the cursor, updated live; committed on drag end.
    var autoProvisional: StudioAutoPoint?
    /// True when this drag is drawing a brand-new point (commit = add, not move).
    var autoIsNew = false
}
