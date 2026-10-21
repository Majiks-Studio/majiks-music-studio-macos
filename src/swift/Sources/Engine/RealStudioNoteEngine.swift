import Foundation

// MARK: - The note seam, over the REAL engine
//
// E1-ui built the piano roll against `StudioNoteEngineProtocol` and shipped it
// running on `StudioMockNoteEngine.demoSession()` — a fabricated four-bar demo
// clip. It looked completely finished: 22 notes, velocity lane, grid, tools,
// quantize, undo/redo. None of it reached the project. The tell was on screen
// the whole time: the roll showed a clip while the project pane read
// "Tracks: 0, empty project".
//
// This file is the other half of that seam. Two decisions in it are
// load-bearing:
//
// 1. It is a CONFORMANCE ON `RealStudioEngine`, not a second actor. The roll
//    speaks UUIDs; the engine speaks string ids ("cm1"). A separate note client
//    would keep its own UUID<->id map, so the UUID the arrangement uses for a
//    clip and the UUID the roll uses for the same clip would differ, and
//    "open the roll on the selected clip" would silently open nothing. One
//    actor, one map, one truth.
//
// 2. Every note command rides `client.submit` — the SAME generic
//    `{name, params}` envelope bus the CLI, the MCP tools and the copilot use.
//    No new FFI symbol was needed: the UniFFI surface exposes
//    `command(envelopeJson:)`, and E1 already put `note.*` in the catalog and
//    `notes` + `kind` on the snapshot. (Checked, not assumed — regenerating the
//    bindings after this lane's engine work produced a byte-identical
//    `majiks_engine.swift`.)

extension RealStudioEngine: StudioNoteEngineProtocol {

    // MARK: Read

    /// The note session for one MIDI clip, read out of the real project
    /// snapshot.
    ///
    /// Change-conditional exactly like `snapshot(ifNewerThan:)`: `nil` means
    /// "nothing you do not already have". The transport escape hatch is the same
    /// one and for the same reason — transport verbs do not bump the journal
    /// `seq`, so a purely seq-gated early-out would freeze the play head at the
    /// moment playback stopped.
    func noteSession(clipID: UUID, ifNewerThan revision: UInt64?) async -> StudioNoteSessionSnapshot? {
        guard let engineClip = engineClipID(clipID) else { return nil }
        guard let json = try? noteClient.snapshot(sinceSeq: nil) else { return nil }
        let seq = UInt64(json.int64("seq") ?? 0)

        let transportJSON = EngineJSON(json.dict("transport") ?? [:])
        let playing = transportJSON.bool("playing") ?? false
        let positionTicks = transportJSON.int64("positionTicks") ?? 0
        let transportChanged =
            playing != lastNotePlaying || positionTicks != lastNotePositionTicks
        if let revision, revision >= seq, !playing, !transportChanged { return nil }
        lastNotePlaying = playing
        lastNotePositionTicks = positionTicks

        let project = EngineJSON(json.dict("project") ?? [:])
        guard let clip = midiClip(engineClip, in: project) else { return nil }

        return StudioNoteSessionSnapshot(
            revision: seq,
            clip: clip,
            barGrid: barGrid(project),
            tempoMap: tempoMap(project),
            transport: StudioTransportSnapshot(
                isPlaying: playing,
                positionTicks: positionTicks,
                capturedAtHostTime: ProcessInfo.processInfo.systemUptime,
                loopRegion: loopRegion(transportJSON)),
            undoDepth: Int(project.int64("undoDepth") ?? 0),
            redoDepth: Int(project.int64("redoDepth") ?? 0))
    }

    /// Find a note-backed clip anywhere in the project and decode its notes.
    /// Returns nil for an audio clip: the roll must refuse to open on one rather
    /// than draw an empty grid that looks like a clip with no notes in it.
    private func midiClip(_ engineClip: String, in project: EngineJSON) -> StudioMidiClipSnapshot? {
        for track in project.array("tracks") {
            let tj = EngineJSON(track)
            guard let trackID = tj.string("id", "trackId") else { continue }
            for clip in tj.array("clips") {
                let cj = EngineJSON(clip)
                guard cj.string("id", "clipId") == engineClip else { continue }
                guard cj.string("kind") == "midi" else { return nil }
                let notes: [StudioNote] = (cj["notes"] as? [[String: Any]] ?? []).compactMap {
                    let nj = EngineJSON($0)
                    guard let id = nj.string("id", "noteId") else { return nil }
                    return StudioNote(
                        id: id,
                        startTicks: nj.int64("startTicks", "start_ticks") ?? 0,
                        lengthTicks: nj.int64("lengthTicks", "length_ticks") ?? 1,
                        pitch: UInt8(clamping: nj.int64("pitch") ?? 60),
                        velocity: Int(nj.int64("velocity") ?? 100))
                }
                return StudioMidiClipSnapshot(
                    id: clipUUID(forEngineID: engineClip),
                    trackID: trackUUID(forEngineID: trackID),
                    name: cj.string("name") ?? engineClip,
                    startTicks: cj.int64("startTicks", "start_ticks") ?? 0,
                    lengthTicks: max(1, cj.int64("lengthTicks", "length_ticks") ?? 1),
                    notes: StudioNote.sorted(notes),
                    kind: .other)
            }
        }
        return nil
    }

    /// The bar grid the roll draws, from the values E1 put on the snapshot.
    /// `phaseAnchorTicks` has existed in the model since E0 but was unreachable
    /// from any client until E1 surfaced it; ignoring it draws every bar line in
    /// the wrong place for a landed generative song with a lead-in.
    private func barGrid(_ project: EngineJSON) -> StudioBarGrid {
        let sig = EngineJSON(project.dict("timeSignature") ?? project.dict("time_sig") ?? [:])
        return StudioBarGrid(
            timeSignature: StudioTimeSignature(
                beatsPerBar: Int(sig.int64("numerator") ?? 4),
                beatUnit: Int(sig.int64("denominator") ?? 4)),
            phaseAnchorTicks: project.int64("phaseAnchorTicks", "phase_anchor_ticks") ?? 0)
    }

    /// The SEGMENTED tempo map, not a single BPM. A landed generative song
    /// drifts off its declared BPM and can change tempo mid-song; a play head
    /// advanced by `ticks/ppq * 60/bpm` walks away from the audio.
    private func tempoMap(_ project: EngineJSON) -> StudioTempoMap {
        let raw = project.array("tempoMap")
        let changes: [(ticks: Int64, bpm: Double)] = raw.compactMap {
            let s = EngineJSON($0)
            guard let bpm = s.double("bpm"), bpm > 0 else { return nil }
            return (s.int64("startTicks") ?? 0, bpm)
        }
        guard !changes.isEmpty else {
            return .constant(bpm: project.double("bpm_wire", "bpmWire") ?? 120)
        }
        return .from(changes: changes)
    }

    private func loopRegion(_ transport: EngineJSON) -> ClosedRange<Int64>? {
        guard let loop = transport.dict("loop") else { return nil }
        let lj = EngineJSON(loop)
        guard let start = lj.int64("startTicks"), let end = lj.int64("endTicks"), end > start else {
            return nil
        }
        return start...end
    }

    // MARK: Write

    /// One gesture -> one journaled catalog command. The batch shape is carried
    /// straight through, so a six-note chord drag stays ONE journal entry and
    /// ONE undo step.
    @discardableResult
    func send(_ command: StudioNoteCommand) async -> StudioCommandResult {
        guard !command.isNoOp else {
            return StudioCommandResult(ok: false, message: "No-op command was not journaled.")
        }
        guard let clip = engineClipID(command.clipID) else {
            return StudioCommandResult(ok: false, message: "Unknown clip.")
        }
        var params: [String: Any] = ["clipId": clip]
        switch command {
        case .add(_, let notes):
            // velocity and pitch go out as INTEGERS. They are journaled as `Num`,
            // whose integer/float shape the blake3 chain depends on: `100.0`
            // would hash differently from `100` and break replay.
            params["notes"] = notes.map { note in
                [
                    "noteId": note.id,
                    "startTicks": Int(note.startTicks),
                    "lengthTicks": Int(note.lengthTicks),
                    "pitch": Int(note.pitch),
                    "velocity": note.velocity,
                ] as [String: Any]
            }
        case .remove(_, let ids):
            params["noteIds"] = ids
        case .move(_, let ids, let deltaTicks, let deltaPitch):
            params["noteIds"] = ids
            params["deltaTicks"] = Int(deltaTicks)
            params["deltaPitch"] = deltaPitch
        case .resize(_, let ids, let edge, let deltaTicks):
            params["noteIds"] = ids
            params["edge"] = edge == .leading ? "leading" : "trailing"
            params["deltaTicks"] = Int(deltaTicks)
        case .setVelocity(_, let ids, let deltaVelocity):
            params["noteIds"] = ids
            params["deltaVelocity"] = deltaVelocity
        case .duplicate(_, let ids, let newIDs, let deltaTicks, let deltaPitch):
            params["noteIds"] = ids
            params["newNoteIds"] = newIDs
            params["deltaTicks"] = Int(deltaTicks)
            params["deltaPitch"] = deltaPitch
        case .setTiming(_, let timings):
            params["notes"] = timings.map { t in
                [
                    "noteId": t.noteID,
                    "startTicks": Int(t.startTicks),
                    "lengthTicks": Int(t.lengthTicks),
                ] as [String: Any]
            }
        case .quantize(_, let ids, let gridTicks, let strengthPercent, let quantizeEnds):
            params["noteIds"] = ids
            params["gridTicks"] = Int(gridTicks)
            // INTEGER percent, not a 0...1 Double. Journaled values are `Num`
            // and the blake3 chain depends on their integer/float shape, so a
            // strength of 0.8 could not be hashed the same way twice.
            params["strengthPercent"] = strengthPercent
            params["quantizeEnds"] = quantizeEnds
        }
        do {
            _ = try noteClient.submit(name: command.catalogName, params: params)
            return StudioCommandResult(ok: true, message: nil)
        } catch let e as FfiError {
            return StudioCommandResult(ok: false, message: "\(command.catalogName): \(noteFfiMessage(e))")
        } catch {
            return StudioCommandResult(ok: false, message: "\(command.catalogName): \(error)")
        }
    }

    // `undo()` / `redo()` already satisfy StudioNoteEngineProtocol: the note
    // commands are on the SAME journal as every other edit, which is the whole
    // point of routing them through the bus. A separate note undo stack would
    // let Cmd-Z mean two different things depending on which pane had focus.

    // MARK: Creating the thing the roll edits

    /// track.add -> device.add(synth) -> clip.placeMidi, all on the journaled
    /// bus, then read the ids back out of a fresh snapshot.
    ///
    /// The ids are read BACK rather than assumed: `track.add` carries a UI-minted
    /// id, but the engine is free to mint its own, and the arrangement lane
    /// already learned that the hard way (see StudioViewModel's import path,
    /// which identifies a new track as "the id that was not there before").
    func addInstrumentTrack(name: String, lengthTicks: Int64) async -> StudioInstrumentTrackOutcome {
        let before = Set(engineTrackIDs())
        let index = before.count
        do {
            _ = try noteClient.submit(name: "track.add", params: [
                "trackId": "t_\(UUID().uuidString.prefix(8))",
                "name": name.isEmpty ? "Instrument \(index + 1)" : name,
                "index": index,
            ])
        } catch {
            return StudioInstrumentTrackOutcome(
                ok: false, trackID: nil, clipID: nil,
                message: "Could not add a track: \(error)")
        }
        guard let track = engineTrackIDs().first(where: { !before.contains($0) }) else {
            return StudioInstrumentTrackOutcome(
                ok: false, trackID: nil, clipID: nil,
                message: "Added a track but could not read it back.")
        }

        // device.add's id must not contain '.', or the ParamRef path
        // `track.device.<deviceId>.<paramKey>` stops being parseable — the
        // catalog enforces it, and a UUID string is already safe.
        let deviceID = "inst_\(UUID().uuidString.prefix(8))"
        let clipEngineID = "cm_\(UUID().uuidString.prefix(8))"
        do {
            _ = try noteClient.submit(name: "device.add", params: [
                "trackId": track, "deviceId": deviceID, "kind": "synth",
            ])
            _ = try noteClient.submit(name: "clip.placeMidi", params: [
                "clipId": clipEngineID,
                "trackId": track,
                "startTicks": 0,
                "lengthTicks": Int(max(1, lengthTicks)),
            ])
        } catch {
            return StudioInstrumentTrackOutcome(
                ok: false,
                trackID: trackUUID(forEngineID: track),
                clipID: nil,
                message: "Added the track but could not finish it: \(error)")
        }
        return StudioInstrumentTrackOutcome(
            ok: true,
            trackID: trackUUID(forEngineID: track),
            clipID: clipUUID(forEngineID: clipEngineID),
            message: nil)
    }

    private func engineTrackIDs() -> [String] {
        guard let json = try? noteClient.snapshot(sinceSeq: nil) else { return [] }
        return EngineJSON(json.dict("project") ?? [:])
            .array("tracks")
            .compactMap { EngineJSON($0).string("id", "trackId") }
    }

    // MARK: Audition

    /// Sound a note NOW: a gutter key press, an on-screen key, a drawn note.
    ///
    /// # Why this no longer names a track when it does not have to
    ///
    /// It used to resolve a track itself and give up (`return false`) when the
    /// project had no instrument — which is every brand-new project. So the
    /// on-screen and gutter keys were silent until the user found the Instrument
    /// button. Omitting `trackId` hands the same decision to the engine, which is
    /// where a MIDI key's decision already lived, so hardware keys and screen
    /// keys reach the same instrument by the same rule and an empty project
    /// answers by creating one.
    ///
    /// # AUDIO SAFETY
    ///
    /// The engine opens the output device on a played note only on a host that
    /// opted into audible output — which is this app, at launch, and nothing
    /// else. `swift test` constructs the engine with `audible: false`
    /// (`StudioEngineFactory.audibleByDefault`), so a test run still makes no
    /// sound. Live MICROPHONE monitoring is a separate rule about a separate
    /// hazard and remains refused in the engine.
    ///
    /// Returns whether the note was actually AUDIBLE. Not "the call worked":
    /// there is nothing useful to a musician in "we sent the message".
    ///
    /// # Why this returns the REASON and not just a Bool
    ///
    /// It used to return a bare `Bool`. The engine answers
    /// `{audible, reason}` — "the track has no instrument device" — and that
    /// sentence was dropped on this line, by this function, every time. So the
    /// surface a beginner is most likely to be sitting on when the sound stops
    /// (a gutter key on a device-less track) went quiet with the diagnosis
    /// already computed and thrown away. Widening the return is the whole fix;
    /// `StudioSilentPreview` decides when to show it.
    @discardableResult
    func previewNote(
        trackID: UUID?,
        pitch: UInt8,
        velocity: Int,
        gate: StudioNoteAuditionGate = .oneShot
    ) async -> StudioNotePreviewOutcome {
        var args: [String: Any] = [
            "pitch": Int(pitch),
            "velocity": max(0, min(127, velocity)),
            "gate": gate.wire,
        ]
        // Only pin a track when the caller genuinely meant a specific one (the
        // roll, editing a clip on a known track). Otherwise let the engine pick.
        if let trackID, let track = engineTrackID(trackID) {
            args["trackId"] = track
        }
        do {
            let json = try noteClient.tool(name: "studio_note_preview", args: args)
            return StudioNotePreviewOutcome(
                audible: json.bool("audible") ?? false,
                // `reason` is JSON null on the audible path, which `string`
                // already reads as nil — so an audible note carries no text and
                // cannot trip the notice.
                reason: json.string("reason"))
        } catch let error as FfiError {
            // A thrown refusal (a bad pitch, a track that vanished) still has
            // the engine's message on it. Same rule as the command bus: surface
            // what the engine said rather than a Swift-authored substitute.
            return StudioNotePreviewOutcome(audible: false, reason: noteFfiMessage(error))
        } catch {
            return .unreachable
        }
    }

    /// KEEP what was just played. Lands the engine's retro-capture buffer as
    /// real notes in one undoable step, without the user having armed anything.
    ///
    /// Returns WHERE it landed as well as how much, because "how many" alone is
    /// what let a 56-note take go to bar 1,076 with nothing on screen saying so.
    /// The caller scrolls to `startTicks`.
    @discardableResult
    func keepPerformance() async -> StudioKeepOutcome {
        guard let json = try? noteClient.tool(name: "studio_performance_keep", args: [:]) else {
            return StudioKeepOutcome(noteCount: 0)
        }
        guard json.bool("kept") == true else { return StudioKeepOutcome(noteCount: 0) }
        return StudioKeepOutcome(
            noteCount: Int(json.int64("noteCount") ?? 0),
            startTicks: json.int64("startTicks") ?? 0,
            lengthTicks: json.int64("lengthTicks") ?? 0,
            // The engine moved the take back to the music when the clock had run
            // away from it. Reported so the UI can SAY so — silently relocating
            // someone's work is the other half of the same bug.
            snapped: json.bool("snapped") ?? false,
            playedAtTicks: json.int64("playedAtTicks"))
    }

    /// THROW AWAY what was just played. Empties the retro-capture buffer and
    /// touches nothing that is in the project, so there is nothing to undo.
    /// Returns how many notes were discarded.
    @discardableResult
    func discardPerformance() async -> Int {
        guard let json = try? noteClient.tool(name: "studio_performance_discard", args: [:]) else {
            return 0
        }
        guard json.bool("discarded") == true else { return 0 }
        return Int(json.int64("noteCount") ?? 0)
    }

    // `firstInstrumentTrackID()` used to live here: a Swift-side copy of the
    // engine's "which track do the keys play" rule, used when `previewNote` was
    // handed no track. Two copies of that rule is one too many — the engine's
    // (`StudioHost::midi_instrument_target`, armed-first then first-instrument)
    // is what a hardware MIDI key already followed, and the copy could only ever
    // drift away from it. It also could not do the thing that matters most on a
    // new project: create an instrument when there is none. Deleted; the engine
    // decides, for every surface.

    private func noteFfiMessage(_ e: FfiError) -> String {
        switch e {
        case .NotInitialized(let m), .InvalidArgument(let m), .Io(let m), .Audio(let m),
             .Gen(let m), .RateLimited(let m), .ConfirmationRequired(let m), .Unsupported(let m):
            return m
        case .Command(_, let m):
            return m
        }
    }
}

