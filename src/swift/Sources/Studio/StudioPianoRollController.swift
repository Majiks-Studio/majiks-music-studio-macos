import SwiftUI

// MARK: - Piano roll controller
//
// Holds the view state, routes every gesture, and turns each finished
// interaction into exactly ONE journaled command on the note bus.
//
// The gesture routing lives HERE, not in the view, on purpose: press / drag /
// release are ordinary method calls taking a point, a modifier set and a layout,
// so an interaction can be driven end-to-end in a unit test and asserted against
// the engine's journal. "The drag emitted one move command and undo put the
// chord back" is then proven behaviour rather than a claim. What a test still
// cannot tell you is whether the drag FEELS right — see the report.

@MainActor
final class StudioPianoRollController: ObservableObject {

    // MARK: Engine truth

    let engine: any StudioNoteEngineProtocol
    @Published private(set) var session: StudioNoteSessionSnapshot?

    // MARK: Selection + tools

    @Published var selection: Set<String> = []
    @Published var grid: StudioNoteGrid = .sixteenth
    @Published var tool: StudioPianoRollTool = .select
    /// Velocity of the next drawn note (last edited velocity, Ableton-style).
    @Published var drawVelocity: Int = 100

    // MARK: Quantize settings
    //
    // ⚠️ Settings, not a mode. Nothing here runs on its own: they are the
    // arguments the Quantize BUTTON (and ⌘U) will use when a person presses it.
    // The owner's own take was recorded with the tempo map fitted to his
    // playing rather than his playing fitted to a tempo, so it sits off the
    // grid on purpose. An automatic quantize — on capture, on open, on any
    // other edit — would not tidy that performance up, it would erase it.
    // `StudioPianoRollInteractionTests.testNothingButTheQuantizeButtonEver…`
    // is the assertion that keeps this true.

    /// How far toward the line, as a percentage. 100 is mechanical; the
    /// default is deliberately below it, because a fully quantized take stops
    /// sounding like a person played it.
    @Published var quantizeStrengthPercent: Int = 80
    /// Whether note ENDS are pulled to the grid too. Off by default: an
    /// ends-quantize chops legato phrasing, and lengths are the half of a
    /// performance people notice least and miss most.
    @Published var quantizeEnds: Bool = false

    // MARK: View state (explicit transforms — there is no ScrollView anywhere)

    @Published var pxPerTick: CGFloat = 96.0 / CGFloat(StudioTick.ppq)   // ~384 px per 4/4 bar
    @Published var rowHeight: CGFloat = StudioPianoRollLayout.defaultRowHeight
    @Published var scrollTicks: Int64 = 0
    @Published var scrollY: CGFloat = 0
    @Published var velocityLaneShown = true
    @Published var isShown = false

    // MARK: Drag

    @Published private(set) var drag = StudioNoteDragState()

    // MARK: Hooks the piano roll does NOT own
    //
    // Transport and audition belong to other lanes. They are closures rather
    // than silent no-ops inside the roll so the wiring is visible at the call
    // site and an unwired hook is obvious.

    /// Called when the ruler is scrubbed. Absolute ticks.
    var onSeek: ((Int64) -> Void)?
    /// Called when a key in the gutter is pressed, or a note is drawn/clicked,
    /// so the instrument can sound it. UNWIRED until E2 lands an instrument —
    /// see the report for the exact call needed.
    var onPreview: ((UInt8, Int) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var lastRevision: UInt64 = 0
    private var clipID: UUID?
    private var didAutoFit = false
    /// The last geometry the view measured. The clip almost always arrives AFTER
    /// the view has appeared — the Instrument button opens the roll on a clip the
    /// engine has not handed back yet — so the fit attempted at `onAppear` has
    /// nothing to frame. Remembering the geometry lets the fit run at the moment
    /// the clip actually lands instead of never running at all.
    private var lastLayout: StudioPianoRollLayout?
    private var pendingDispatch: Task<Void, Never>?

    init(engine: any StudioNoteEngineProtocol) {
        self.engine = engine
    }

    // MARK: Lifecycle

    func open(clipID: UUID) {
        guard self.clipID != clipID else { return }
        reset(to: clipID)
        startPolling()
    }

    /// Open a clip and adopt it now, WITHOUT starting the poll loop. This is the
    /// entry point the interaction tests drive: a 30 Hz background task would
    /// make every assertion a race, and a test that races is a test that lies.
    func attach(clipID: UUID) async {
        reset(to: clipID)
        await adoptFresh()
    }

    /// The clip this roll was editing no longer exists (deleted, or its track
    /// was). Close rather than keep rendering the last-adopted session — a
    /// grid full of notes the project no longer has is a ghost, and edits to
    /// it would all refuse. StudioRootView calls this when
    /// `editableMidiClipID` goes nil; reopening is the same `open` as ever.
    func close() {
        stopPolling()
        clipID = nil
        session = nil
        selection.removeAll()
        isShown = false
    }

    private func reset(to clipID: UUID) {
        self.clipID = clipID
        lastRevision = 0
        session = nil
        selection.removeAll()
        didAutoFit = false
    }

    /// Wait for the last dispatched command to land (tests + evidence hooks).
    func settle() async {
        await pendingDispatch?.value
    }

    func startPolling() {
        guard pollTask == nil, clipID != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 33_000_000)   // 30 Hz, the Studio cadence
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        guard let clipID else { return }
        let since: UInt64? = session == nil ? nil : lastRevision
        guard let fresh = await engine.noteSession(clipID: clipID, ifNewerThan: since) else { return }
        // Edit-guard: never adopt engine truth mid-drag (the DJ/Studio rule) or
        // the note under the cursor fights the poll.
        guard drag.kind == .none else { return }
        lastRevision = fresh.revision
        session = fresh
        // Drop selection entries the engine no longer has (an undone add).
        let live = Set(fresh.clip.notes.map(\.id))
        selection.formIntersection(live)
        autoFitOnArrival()
    }

    /// Force-adopt (used straight after a command so the edit lands without
    /// waiting on the poll — the same trick `adoptFresh` uses in the arrangement).
    func adoptFresh() async {
        guard let clipID else { return }
        if let fresh = await engine.noteSession(clipID: clipID, ifNewerThan: nil) {
            lastRevision = fresh.revision
            session = fresh
            selection.formIntersection(Set(fresh.clip.notes.map(\.id)))
            autoFitOnArrival()
        }
    }

    // MARK: Derived

    var clip: StudioMidiClipSnapshot? { session?.clip }
    var barGrid: StudioBarGrid { session?.barGrid ?? StudioBarGrid() }
    var tempoMap: StudioTempoMap { session?.tempoMap ?? .constant(bpm: 120) }
    var timeSignature: StudioTimeSignature { barGrid.timeSignature }
    var clipOriginTicks: Int64 { clip?.startTicks ?? 0 }
    var clipLengthTicks: Int64 { clip?.lengthTicks ?? 0 }
    var canUndo: Bool { (session?.undoDepth ?? 0) > 0 }
    var canRedo: Bool { (session?.redoDepth ?? 0) > 0 }

    func layout(for size: CGSize) -> StudioPianoRollLayout {
        StudioPianoRollLayout(
            pxPerTick: pxPerTick,
            rowHeight: rowHeight,
            scrollTicks: scrollTicks,
            scrollY: scrollY,
            gutterWidth: StudioPianoRollLayout.gutterWidth,
            rulerHeight: StudioPianoRollLayout.rulerHeight,
            velocityLaneHeight: velocityLaneShown ? StudioPianoRollLayout.velocityLaneHeight : 0,
            size: size)
    }

    /// Play head in absolute ticks, advanced through the TEMPO MAP rather than
    /// by `ticks/ppq * 60/bpm`. On a constant map this is the same number; on a
    /// landed generative song (which drifts 1.2-2.9% off its declared BPM, and
    /// may change tempo mid-song) the naive form walks away from the audio and
    /// the play head stops lining up with what you hear.
    func playheadTicks(now: TimeInterval) -> Int64 {
        guard let transport = session?.transport else { return 0 }
        guard transport.isPlaying else { return transport.positionTicks }
        let elapsed = max(0, now - transport.capturedAtHostTime)
        return tempoMap.advanced(fromTicks: transport.positionTicks, bySeconds: elapsed)
    }

    /// The notes to draw this frame: engine truth with the live drag applied.
    /// Drawing and hit-testing both call this, so what you see is what you grab.
    func displayNotes() -> [StudioNote] {
        guard let clip else { return [] }
        var notes = clip.notes
        switch drag.kind {
        case .move:
            let moved = StudioNoteEdit.applyMove(drag.originals, delta: drag.moveDelta)
            // Alt-drag copies: the originals stay put and the moved set draws on
            // top as the pending copy, so you can see what you are about to get.
            notes = drag.duplicating ? notes + moved : replace(notes, with: moved)
        case .resizeLeading:
            notes = replace(notes, with: StudioNoteEdit.applyResize(drag.originals, edge: .leading, delta: drag.resizeDelta))
        case .resizeTrailing:
            notes = replace(notes, with: StudioNoteEdit.applyResize(drag.originals, edge: .trailing, delta: drag.resizeDelta))
        case .velocity:
            notes = replace(notes, with: StudioNoteEdit.applyVelocity(drag.originals, delta: drag.velocityDelta))
        case .draw:
            if let drawn = drag.drawnNote { notes.append(drawn) }
        case .none, .marquee, .scrub:
            break
        }
        return StudioNote.sorted(notes)
    }

    private func replace(_ notes: [StudioNote], with edited: [StudioNote]) -> [StudioNote] {
        let byID = Dictionary(edited.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return notes.map { byID[$0.id] ?? $0 }
    }

    /// The notes a drag would commit — used by the tests and by the readout.
    var draggedNoteIDs: [String] { drag.originals.map(\.id) }

    // MARK: - Gesture routing
    //
    // press -> dragged* -> released. One entry point per phase; the view does no
    // decision-making of its own.

    func press(at point: CGPoint, modifiers: StudioNoteModifiers, layout: StudioPianoRollLayout) {
        guard let clip else { return }
        var state = StudioNoteDragState()
        state.startPoint = point
        state.currentPoint = point
        state.shift = modifiers.shift
        state.bypassSnap = modifiers.command
        state.duplicating = modifiers.option

        // 1. Ruler: scrub the play head.
        if point.y < layout.rulerHeight, point.x >= layout.gutterWidth {
            state.kind = .scrub
            drag = state
            onSeek?(max(0, layout.ticks(forX: point.x)))
            return
        }
        // 2. Gutter: audition the key. Never a mutation.
        if let pitch = StudioPianoRollGeometry.gutterKey(layout: layout, at: point) {
            onPreview?(pitch, drawVelocity)
            return
        }
        // 3. Velocity lane.
        if layout.velocityLaneHeight > 0, layout.velocityRect.insetBy(dx: 0, dy: -2).contains(point) {
            guard let id = StudioPianoRollGeometry.velocityHit(
                clip.notes, selected: selection, layout: layout,
                clipOriginTicks: clip.startTicks, at: point) else { return }
            if !selection.contains(id) { selection = [id] }
            state.kind = .velocity
            state.anchorID = id
            state.originals = clip.notes.filter { selection.contains($0.id) }
            drag = state
            return
        }
        // 4. Note area.
        guard layout.noteRect.insetBy(dx: 0, dy: -1).contains(point) else { return }

        if let hit = StudioPianoRollGeometry.hitTest(
            clip.notes, selected: selection, layout: layout,
            clipOriginTicks: clip.startTicks, at: point) {

            if !selection.contains(hit.noteID) {
                selection = modifiers.shift ? selection.union([hit.noteID]) : [hit.noteID]
            } else if modifiers.shift {
                selection.remove(hit.noteID)
                return   // shift-click on a selected note deselects it; no drag
            }
            state.anchorID = hit.noteID
            state.originals = clip.notes.filter { selection.contains($0.id) }
            switch hit.zone {
            case .body:
                state.kind = .move
                if let anchor = clip.note(hit.noteID) {
                    state.grabOffsetTicks = layout.ticks(forX: point.x) - (clip.startTicks + anchor.startTicks)
                    onPreview?(anchor.pitch, anchor.velocity)
                }
            case .leadingEdge:
                state.kind = .resizeLeading
            case .trailingEdge:
                state.kind = .resizeTrailing
            }
            drag = state
            return
        }

        // Empty grid.
        if tool == .draw {
            beginDraw(at: point, state: &state, layout: layout, clip: clip)
        } else {
            state.kind = .marquee
            if !modifiers.shift { selection.removeAll() }
            state.originals = []
            state.marqueeBase = selection
        }
        drag = state
    }

    private func beginDraw(
        at point: CGPoint,
        state: inout StudioNoteDragState,
        layout: StudioPianoRollLayout,
        clip: StudioMidiClipSnapshot
    ) {
        guard let pitch = layout.pitch(forY: point.y) else { return }
        let raw = layout.ticks(forX: point.x) - clip.startTicks
        // Draw snaps DOWN to the grid line at or before the cursor: clicking
        // anywhere inside a beat starts the note on that beat, which is what a
        // musician expects. Nearest-snap would jump the note backwards whenever
        // you clicked in the right half of a cell.
        let anchor = state.bypassSnap ? raw : floorSnap(raw)
        state.kind = .draw
        state.drawAnchorTicks = max(0, anchor)
        state.drawnNote = StudioNoteEdit.drawnNote(
            id: StudioNoteIDMinter.mint(),
            pitch: pitch,
            fromTicks: state.drawAnchorTicks,
            toTicks: state.drawAnchorTicks,
            defaultLengthTicks: grid.defaultNoteLengthTicks(timeSignature),
            clipLengthTicks: clip.lengthTicks,
            velocity: drawVelocity)
        onPreview?(pitch, drawVelocity)
    }

    /// Write one note at a point with the current grid length (the double-click
    /// path). Goes through the same command bus as every other edit.
    func drawNote(at point: CGPoint, layout: StudioPianoRollLayout, modifiers: StudioNoteModifiers) {
        guard let clip, let pitch = layout.pitch(forY: point.y) else { return }
        let raw = layout.ticks(forX: point.x) - clip.startTicks
        let start = max(0, modifiers.command ? raw : floorSnap(raw))
        let note = StudioNoteEdit.drawnNote(
            id: StudioNoteIDMinter.mint(), pitch: pitch,
            fromTicks: start, toTicks: start,
            defaultLengthTicks: grid.defaultNoteLengthTicks(timeSignature),
            clipLengthTicks: clip.lengthTicks,
            velocity: drawVelocity)
        onPreview?(pitch, drawVelocity)
        dispatch(.add(clipID: clip.id, notes: [note]), select: [note.id])
    }

    /// Snap toward the start of the cell (used for drawing).
    private func floorSnap(_ clipRelativeTicks: Int64) -> Int64 {
        let absolute = clipRelativeTicks + clipOriginTicks
        let nearest = barGrid.snap(absolute, division: grid)
        let step = grid.ticks(timeSignature) ?? 0
        let floored = nearest > absolute && step > 0 ? nearest - step : nearest
        return floored - clipOriginTicks
    }

    func dragged(to point: CGPoint, modifiers: StudioNoteModifiers, layout: StudioPianoRollLayout) {
        guard drag.kind != .none, let clip else { return }
        var state = drag
        state.currentPoint = point
        state.bypassSnap = modifiers.command
        if hypot(point.x - state.startPoint.x, point.y - state.startPoint.y) > 2 { state.didMove = true }

        let rawTick = layout.ticks(forX: point.x)

        switch state.kind {
        case .scrub:
            onSeek?(max(0, rawTick))

        case .move:
            guard let anchor = clip.note(state.anchorID) else { break }
            let wantedStartAbs = rawTick - state.grabOffsetTicks
            let snapped = barGrid.snap(wantedStartAbs, division: grid, bypass: state.bypassSnap)
            state.moveDelta = StudioNoteEdit.moveDelta(
                notes: state.originals,
                anchorID: state.anchorID,
                proposedAnchorStart: snapped - clip.startTicks,
                proposedAnchorPitch: layout.clampedPitch(forY: point.y),
                clipLengthTicks: clip.lengthTicks)
            // Audition the pitch as it changes, the way Ableton does.
            let newPitch = StudioNote.clampPitch(Int(anchor.pitch) + state.moveDelta.pitch)
            if newPitch != state.lastPreviewedPitch {
                state.lastPreviewedPitch = newPitch
                onPreview?(newPitch, anchor.velocity)
            }

        case .resizeLeading, .resizeTrailing:
            let edge: StudioNoteEdit.Edge = state.kind == .resizeLeading ? .leading : .trailing
            let snapped = barGrid.snap(rawTick, division: grid, bypass: state.bypassSnap)
            state.resizeDelta = StudioNoteEdit.resizeDelta(
                notes: state.originals,
                anchorID: state.anchorID,
                edge: edge,
                proposedAnchorEdge: snapped - clip.startTicks,
                clipLengthTicks: clip.lengthTicks)

        case .velocity:
            state.velocityDelta = StudioNoteEdit.velocityDelta(
                notes: state.originals,
                proposedAnchorVelocity: layout.velocity(forY: point.y),
                anchorID: state.anchorID)

        case .draw:
            guard var drawn = state.drawnNote else { break }
            let to = state.bypassSnap
                ? rawTick - clip.startTicks
                : barGrid.snap(rawTick, division: grid) - clip.startTicks
            drawn = StudioNoteEdit.drawnNote(
                id: drawn.id, pitch: drawn.pitch,
                fromTicks: state.drawAnchorTicks, toTicks: to,
                defaultLengthTicks: grid.defaultNoteLengthTicks(timeSignature),
                clipLengthTicks: clip.lengthTicks,
                velocity: drawVelocity)
            state.drawnNote = drawn

        case .marquee:
            let rect = StudioPianoRollGeometry.marqueeRect(from: state.startPoint, to: point)
            let hits = StudioPianoRollGeometry.marqueeHits(
                clip.notes, layout: layout, clipOriginTicks: clip.startTicks, rect: rect)
            selection = state.shift ? state.marqueeBase.union(hits) : hits

        case .none:
            break
        }
        drag = state
    }

    func released(at point: CGPoint, modifiers: StudioNoteModifiers, layout: StudioPianoRollLayout) {
        let finished = drag
        drag = StudioNoteDragState()
        guard let clip else { return }

        switch finished.kind {
        case .move:
            let delta = finished.moveDelta
            if finished.duplicating {
                let ids = finished.originals.map(\.id)
                let newIDs = ids.map { _ in StudioNoteIDMinter.mint() }
                dispatch(.duplicate(
                    clipID: clip.id, noteIDs: ids, newIDs: newIDs,
                    deltaTicks: delta.ticks, deltaPitch: delta.pitch), select: Set(newIDs))
            } else {
                dispatch(.move(
                    clipID: clip.id, noteIDs: finished.originals.map(\.id),
                    deltaTicks: delta.ticks, deltaPitch: delta.pitch))
            }

        case .resizeLeading, .resizeTrailing:
            let edge: StudioNoteEdit.Edge = finished.kind == .resizeLeading ? .leading : .trailing
            dispatch(.resize(
                clipID: clip.id, noteIDs: finished.originals.map(\.id),
                edge: edge, deltaTicks: finished.resizeDelta))

        case .velocity:
            dispatch(.setVelocity(
                clipID: clip.id, noteIDs: finished.originals.map(\.id),
                deltaVelocity: finished.velocityDelta))
            if let anchor = finished.originals.first(where: { $0.id == finished.anchorID }) {
                drawVelocity = StudioNote.clampVelocity(anchor.velocity + finished.velocityDelta)
            }

        case .draw:
            guard let drawn = finished.drawnNote else { break }
            dispatch(.add(clipID: clip.id, notes: [drawn]), select: [drawn.id])

        case .marquee:
            // A click on empty space with no drag clears the selection.
            if !finished.didMove, !finished.shift { selection.removeAll() }

        case .scrub, .none:
            break
        }
    }

    /// Escape: abandon the live drag with nothing journaled.
    func cancelDrag() {
        drag = StudioNoteDragState()
    }

    // MARK: - Command dispatch
    //
    // The ONLY place a note edit leaves the UI. Every path above funnels here,
    // which is why undo works uniformly and why an agent driving the same
    // catalog commands produces identical results.

    private func dispatch(_ command: StudioNoteCommand, select: Set<String>? = nil) {
        guard !command.isNoOp else { return }
        pendingDispatch = Task { [weak self] in
            guard let self else { return }
            let result = await engine.send(command)
            guard result.ok else { return }
            if let select { selection = select }
            await adoptFresh()
        }
    }

    // MARK: - Menu / keyboard actions

    func selectAll() {
        selection = Set(clip?.notes.map(\.id) ?? [])
    }

    func deleteSelection() {
        guard let clip, !selection.isEmpty else { return }
        dispatch(.remove(clipID: clip.id, noteIDs: Array(selection)), select: [])
    }

    func duplicateSelection() {
        guard let clip, !selection.isEmpty else { return }
        let notes = clip.notes.filter { selection.contains($0.id) }
        let offset = StudioNoteEdit.duplicateOffsetTicks(
            notes, grid: grid, timeSignature: timeSignature)
        guard offset > 0 else { return }
        let ids = notes.map(\.id)
        let newIDs = ids.map { _ in StudioNoteIDMinter.mint() }
        dispatch(.duplicate(
            clipID: clip.id, noteIDs: ids, newIDs: newIDs,
            deltaTicks: offset, deltaPitch: 0), select: Set(newIDs))
    }

    /// Arrow-key nudge. Horizontal moves by one grid step, vertical by a
    /// semitone (or an octave with shift) — with the same group clamp a mouse
    /// drag gets, so a chord never collapses on itself at the edges.
    func nudgeSelection(gridSteps: Int, semitones: Int) {
        guard let clip, !selection.isEmpty else { return }
        let notes = clip.notes.filter { selection.contains($0.id) }
        let delta = StudioNoteEdit.nudge(
            notes, byGridSteps: gridSteps, semitones: semitones,
            grid: grid, timeSignature: timeSignature, clipLengthTicks: clip.lengthTicks)
        dispatch(.move(
            clipID: clip.id, noteIDs: notes.map(\.id),
            deltaTicks: delta.ticks, deltaPitch: delta.pitch))
        if semitones != 0, let first = notes.first {
            onPreview?(StudioNote.clampPitch(Int(first.pitch) + delta.pitch), first.velocity)
        }
    }

    /// Make the selected notes longer or shorter by whole grid steps.
    ///
    /// WHY THIS EXISTS. `note.resize` was implemented, journaled and invertible,
    /// and could be invoked by exactly ONE gesture: grabbing the few points at
    /// the edge of a drawn note and dragging them. `handleKey` covered the
    /// arrows, Cmd-U, `b`, `[`, `]` and `v` — not this — and there was no menu
    /// item and no palette row either. That is fine at a desk with a mouse. The
    /// owner drives this app on a 4K television from a couch, where a fine-motor
    /// grab on a 3 pt edge is not a gesture that exists. A command nobody can
    /// invoke is the same defect as a control that does nothing.
    ///
    /// The TRAILING edge, always. The leading edge moves a note's start, and
    /// moving a note is what the plain arrows already do — a keyboard command
    /// that did both depending on a modifier would be two verbs on one key.
    ///
    /// The delta goes through the SAME `StudioNoteEdit.resizeDelta` the mouse
    /// drag uses, rather than being applied per note here. That is what keeps a
    /// chord from being pulled apart at the ends and stops the keyboard
    /// squeezing a note below the minimum length the mouse refuses to pass, and
    /// it means there is one clamp for both routes instead of two that can drift.
    func resizeSelection(gridSteps: Int) {
        guard let clip, !selection.isEmpty, gridSteps != 0 else { return }
        // Grid Off has no step to move by, and inventing one would be the roll
        // guessing at a length the user never asked for. `note.quantize` refuses
        // in the same state for the same reason.
        guard let step = grid.ticks(timeSignature), step > 0 else { return }
        let notes = clip.notes.filter { selection.contains($0.id) }
        // `clip.notes` is sorted, so `filter` preserves that order and the same
        // gesture on the same notes picks the same anchor every time.
        guard let anchor = notes.first else { return }
        let delta = StudioNoteEdit.resizeDelta(
            notes: notes,
            anchorID: anchor.id,
            edge: .trailing,
            proposedAnchorEdge: anchor.endTicks + Int64(gridSteps) * step,
            clipLengthTicks: clip.lengthTicks)
        // The selection is left exactly as it was: this is an edit, not a
        // navigation, and having the selection move underneath you is how the
        // next keystroke lands on the wrong notes.
        dispatch(.resize(
            clipID: clip.id, noteIDs: notes.map(\.id),
            edge: .trailing, deltaTicks: delta))
    }

    // MARK: Quantize
    //
    // Two entry points, both of them a deliberate act by a person on a named
    // set of notes. There is no third one: nothing polls, nothing runs at
    // capture time, and nothing "cleans up" a take on the way in.

    /// The grid step quantize would use, or nil when the grid is Off (in which
    /// case there is nothing to pull toward and the control disables).
    var quantizeGridTicks: Int64? {
        guard let step = grid.ticks(timeSignature), step > 0 else { return nil }
        return step
    }

    var canQuantizeSelection: Bool { quantizeGridTicks != nil && !selection.isEmpty }
    var canQuantizeClip: Bool { quantizeGridTicks != nil && !(clip?.notes.isEmpty ?? true) }

    /// ⌘U and the menu's first item. Does nothing when nothing is selected —
    /// deliberately, so a stray keystroke can never reach a take the user was
    /// not pointing at.
    func quantizeSelection() {
        quantize(noteIDs: Array(selection))
    }

    /// The explicit "everything in this clip" spelling. Separate from the
    /// selection path, and separately labelled, because it is the one that can
    /// move a whole performance.
    func quantizeAllNotesInClip() {
        quantize(noteIDs: clip?.notes.map(\.id) ?? [])
    }

    private func quantize(noteIDs: [String]) {
        guard let clip, !noteIDs.isEmpty, let step = quantizeGridTicks else { return }
        // The selection is left exactly as it was: a quantize is a correction,
        // not a navigation, and having the selection jump underneath you is how
        // the next edit lands on the wrong notes.
        dispatch(.quantize(
            clipID: clip.id,
            // Sorted so the same gesture on the same notes produces the same
            // journal entry every time, whatever order the Set iterated in.
            noteIDs: noteIDs.sorted(),
            gridTicks: step,
            strengthPercent: quantizeStrengthPercent,
            quantizeEnds: quantizeEnds))
    }

    func nudgeVelocity(by amount: Int) {
        guard let clip, !selection.isEmpty else { return }
        let notes = clip.notes.filter { selection.contains($0.id) }
        guard let anchor = notes.first else { return }
        let delta = StudioNoteEdit.velocityDelta(
            notes: notes, proposedAnchorVelocity: anchor.velocity + amount, anchorID: anchor.id)
        dispatch(.setVelocity(clipID: clip.id, noteIDs: notes.map(\.id), deltaVelocity: delta))
    }

    func undo() {
        pendingDispatch = Task { [weak self] in
            guard let self else { return }
            _ = await engine.undo()
            await adoptFresh()
        }
    }

    func redo() {
        pendingDispatch = Task { [weak self] in
            guard let self else { return }
            _ = await engine.redo()
            await adoptFresh()
        }
    }

    // MARK: - Zoom / scroll
    //
    // Explicit transforms over the canvas. There is no ScrollView in this
    // surface at any level; see StudioPianoRollView's header for why.

    func zoomHorizontal(by factor: CGFloat, anchorPx: CGFloat, layout: StudioPianoRollLayout) {
        let old = pxPerTick
        let new = StudioPianoRollLayout.clampPxPerTick(old * factor)
        guard new != old else { return }
        let anchor = anchorPx - layout.noteRect.minX
        scrollTicks = StudioTimelineMath.scrollPreservingAnchor(
            anchorPx: anchor, oldPxPerTick: old, newPxPerTick: new, oldScrollTicks: scrollTicks)
        pxPerTick = new
    }

    func zoomVertical(by factor: CGFloat, anchorPy: CGFloat, layout: StudioPianoRollLayout) {
        let old = rowHeight
        let new = StudioPianoRollLayout.clampRowHeight(old * factor)
        guard new != old else { return }
        // Keep the pitch under the cursor stationary.
        let anchor = max(0, anchorPy - layout.noteRect.minY)
        let contentY = (anchor + scrollY) / old * new
        rowHeight = new
        var next = layout
        next.rowHeight = new
        scrollY = min(max(0, contentY - anchor), next.maxScrollY)
    }

    func pan(dxPx: CGFloat, dyPx: CGFloat, layout: StudioPianoRollLayout) {
        if dxPx != 0, pxPerTick > 0 {
            let deltaTicks = Int64((dxPx / pxPerTick).rounded())
            let leftBound = clipOriginTicks - timeSignature.ticksPerBar
            scrollTicks = max(leftBound, scrollTicks + deltaTicks)
        }
        if dyPx != 0 {
            scrollY = min(max(0, scrollY + dyPx), layout.maxScrollY)
        }
    }

    /// Frame the clip's notes: vertical zoom + scroll so the whole pitch span is
    /// on screen with a little air, and the horizontal window starts at the clip.
    /// Runs once when a clip is opened, because a piano roll that opens on an
    /// empty stretch of C-1 is the single most common "it's broken" report.
    func fitToContent(layout: StudioPianoRollLayout) {
        guard let clip, !clip.notes.isEmpty else {
            // Nothing to frame, so the roll picks the playable middle of the
            // keyboard rather than an edge of it. Middle C in the CENTRE of the
            // window, not at its top: the first note drawn on a fresh clip should
            // be one a person would actually play.
            scrollY = centeredScrollY(onPitch: 60, layout: layout)
            return
        }
        let low = Int(clip.notes.map(\.pitch).min() ?? 48)
        let high = Int(clip.notes.map(\.pitch).max() ?? 72)
        let span = max(12, high - low + 4)              // 2 semitones of air each side
        let viewHeight = layout.noteRect.height
        if viewHeight > 0 {
            rowHeight = StudioPianoRollLayout.clampRowHeight(viewHeight / CGFloat(span))
        }
        // Centre the span rather than hanging it from `high + 2`: the 12-row floor
        // on `span` and `clampRowHeight` both leave the window taller than the
        // notes need, and top-aligning puts all of that slack underneath them.
        scrollY = centeredScrollY(onPitch: (low + high) / 2, layout: layout)
        scrollTicks = clip.startTicks
        if clip.lengthTicks > 0, layout.noteRect.width > 0 {
            pxPerTick = StudioPianoRollLayout.clampPxPerTick(
                layout.noteRect.width / CGFloat(clip.lengthTicks))
        }
    }

    /// The `scrollY` that puts `pitch`'s row in the middle of the note area.
    /// `scrollY` measures DOWN from the top of pitch 127, so this is that row's
    /// offset less half a window, plus half a row to centre the row itself.
    /// Clamped to the scrollable range, so a short window lands as close as it
    /// can instead of scrolling into blank air.
    private func centeredScrollY(onPitch pitch: Int, layout: StudioPianoRollLayout) -> CGFloat {
        var fitted = layout
        fitted.rowHeight = rowHeight
        let rowTop = CGFloat(127 - Int(StudioNote.clampPitch(pitch))) * rowHeight
        let centered = rowTop - fitted.noteRect.height / 2 + rowHeight / 2
        return min(max(0, centered), fitted.maxScrollY)
    }

    /// Called by the view once it knows its real size.
    func autoFitIfNeeded(layout: StudioPianoRollLayout) {
        // Remember the geometry even when there is nothing to fit yet: this call
        // is usually the one that arrives BEFORE the clip does.
        if layout.noteRect.height > 0 { lastLayout = layout }
        guard !didAutoFit, clip != nil, layout.noteRect.height > 0 else { return }
        didAutoFit = true
        fitToContent(layout: layout)
    }

    /// Run the still-pending auto-fit now that a clip has been adopted. No-op
    /// once the fit has run, or before the view has measured itself.
    private func autoFitOnArrival() {
        guard !didAutoFit, let lastLayout else { return }
        autoFitIfNeeded(layout: lastLayout)
    }

    // MARK: Keyboard

    /// Returns true when the key was consumed.
    @discardableResult
    func handleKey(_ characters: String, arrow: StudioPianoRollArrow?, shift: Bool, command: Bool) -> Bool {
        if let arrow {
            switch arrow {
            // Shift + left/right changes a note's LENGTH; the bare arrow moves
            // it. This is where the resize became reachable from a keyboard —
            // see `resizeSelection` for why it had to be.
            //
            // Shift was free on this axis: it was passed in and IGNORED, so
            // Shift-Left was a second, indistinguishable way to nudge left. No
            // binding was taken from anything. It is also what Cubase and FL
            // Studio use for note length, so it is not a private convention.
            // (Shift on up/down still means an octave rather than a semitone,
            // which is a different axis and unchanged.)
            case .left:
                if shift { resizeSelection(gridSteps: -1) } else { nudgeSelection(gridSteps: -1, semitones: 0) }
            case .right:
                if shift { resizeSelection(gridSteps: 1) } else { nudgeSelection(gridSteps: 1, semitones: 0) }
            case .up: nudgeSelection(gridSteps: 0, semitones: shift ? 12 : 1)
            case .down: nudgeSelection(gridSteps: 0, semitones: shift ? -12 : -1)
            }
            return true
        }
        switch characters.lowercased() {
        // ⌘U, the shortcut every DAW in the field uses for quantize. Guarded on
        // the modifier so a bare "u" while typing stays a bare "u", and routed
        // through `quantizeSelection`, which is a no-op on an empty selection.
        case "u" where command:
            quantizeSelection()
            return true
        case "b":
            tool = tool == .draw ? .select : .draw
            return true
        case "[":
            grid = grid.coarser()
            return true
        case "]":
            grid = grid.finer()
            return true
        case "v":
            velocityLaneShown.toggle()
            return true
        default:
            return false
        }
    }
}

// MARK: - Supporting value types

enum StudioPianoRollTool: String, CaseIterable, Sendable {
    case select
    case draw

    var label: String { self == .select ? "Select" : "Draw" }
    var systemImage: String { self == .select ? "cursorarrow" : "pencil" }
}

enum StudioPianoRollArrow: Sendable { case left, right, up, down }

struct StudioNoteModifiers: Equatable, Sendable {
    var shift = false
    /// Command bypasses the grid (Ableton parity: ⌘ toggles snap).
    var command = false
    /// Option turns a move into a copy.
    var option = false

    static let none = StudioNoteModifiers()
}

enum StudioNoteDragKind: Equatable, Sendable {
    case none
    case draw
    case move
    case resizeLeading
    case resizeTrailing
    case marquee
    case velocity
    case scrub
}

struct StudioNoteDragState: Equatable, Sendable {
    var kind: StudioNoteDragKind = .none
    var startPoint: CGPoint = .zero
    var currentPoint: CGPoint = .zero
    var shift = false
    var bypassSnap = false
    var duplicating = false
    var didMove = false

    /// The note the gesture grabbed; every delta is computed from it and applied
    /// to the whole selection.
    var anchorID: String = ""
    /// The selection as it stood when the drag began (never mutated mid-drag).
    var originals: [StudioNote] = []
    /// Selection to union with while shift-marqueeing.
    var marqueeBase: Set<String> = []

    var grabOffsetTicks: Int64 = 0
    var moveDelta = StudioNoteEdit.MoveDelta(ticks: 0, pitch: 0)
    var resizeDelta: Int64 = 0
    var velocityDelta: Int = 0

    var drawAnchorTicks: Int64 = 0
    var drawnNote: StudioNote?
    var lastPreviewedPitch: UInt8?
}

// MARK: - Layout constants

extension StudioPianoRollLayout {
    static let gutterWidth: CGFloat = 54
    static let rulerHeight: CGFloat = 20
    static let velocityLaneHeight: CGFloat = 66
}
