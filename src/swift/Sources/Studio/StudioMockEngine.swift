import Foundation

// MARK: - Mock engine
//
// Implements StudioEngineProtocol until L6's FFI-backed client lands. It is
// SILENT BY DEFINITION: no audio framework imports, no audio output ever.
// Transport "playback" advances a tick counter from the wall clock.
//
// The synthetic project is the L5 performance-gate fixture: exactly 8 tracks
// and 100 clips (brief: 60 fps pan/zoom on Apple Silicon).

actor StudioMockEngine: StudioEngineProtocol {

    // MARK: State

    private var revision: UInt64 = 1
    private var name: String
    private var tempoBPM: Double
    private var timeSignature: StudioTimeSignature
    private var key: String
    private var lengthBars: Int
    private var sections: [StudioSectionSnapshot]
    private var tracks: [StudioTrackSnapshot]
    private var master = StudioMasterSnapshot(volumeDB: 0, lufsIntegrated: -14.2)
    /// Mock marker storage (marker.set / marker.remove).
    private var markers: [StudioMarker] = []
    /// Track color overrides (track.setColor), keyed by track UUID string.
    private var trackColors: [UUID: String] = [:]
    /// Track height overrides (track.setHeight), keyed by track UUID string.
    private var trackHeights: [UUID: Int] = [:]
    private var provenanceSummary: String
    /// Every generative take in the project (the Takes browser list, L10). The
    /// preview engine maintains this the way the real engine maintains
    /// project.takes: revise/extend/layer ADD candidates, commit promotes them,
    /// purge marks the un-promoted ones offline (their audio reclaimed).
    private var takeRecords: [StudioTakeBrowserItem]
    private var takeSeqCounter: Int

    private var isPlaying = false
    private var anchorTicks: Int64 = 0
    private var anchorHostTime: TimeInterval = 0
    private var loopRegion: ClosedRange<Int64>?
    /// Metronome monitor flag. The mock never makes sound; it holds the state
    /// so the toggle sticks and the snapshot round-trips in mock builds.
    private var metronomeEnabled = false

    /// Metronome monitor state in the mock. Silent by definition — it records
    /// the enable flag so the UI reads back what it set, and ignores level and
    /// count-in, which are audio-only.
    func setMetronome(enabled: Bool?, levelDB: Double?, countInBeats: Int?) async {
        if let enabled { metronomeEnabled = enabled }
    }

    // Recording simulation (L19): the mock opens no device and no stream; it
    // flips state and animates an input meter so the record UI is fully
    // demoable without a microphone.
    private var recording = false
    private var recordingTrackID: UUID?
    /// Opt-in listen flag (privacy surface). Arming never sets this.
    private var inputListening = false
    private var recordStartTicks: Int64 = 0
    private var recordRolling = false
    private var recordPunchOutTicks: Int64?
    private var recordStartHostTime: TimeInterval = 0
    /// The open comp session (loop-record): repeated captures over the same
    /// region stack as take-lane passes rather than overlapping clips.
    private struct CompKey: Equatable { let track: UUID; let start: Int64; let punch: Int64? }
    private var compSession: CompKey?
    /// The take lane this recording created; a pass only stacks into it, never
    /// into a pre-existing (e.g. generative) lane on the same track.
    private var compLaneID: UUID?
    private let mockInputDevices = ["Built-in Microphone", "Scarlett 2i2 USB", "Aggregate Device"]

    /// The closed set of instrument parameter keys, mirrored from
    /// `timeline_core::model::DEVICE_PARAM_KEYS`. Closed for the reason the
    /// engine's is closed: a typo'd key the mock accepted would let the tone
    /// panel wire a control to a parameter the real engine refuses.
    static let deviceParamKeys: Set<String> = [
        "waveform", "cutoff", "resonance", "attack",
        "decay", "sustain", "release", "gain", "transpose", "fine",
    ]

    /// One reversing step. Most are plain commands (the mock mirrors the real
    /// bus's self-inverse pairs), but the delete-class commands restore a VALUE
    /// snapshot instead: the catalog restores a removed track/clip through a
    /// SEQUENCE of adds the preview model cannot express one-for-one (kind,
    /// waveform seed, origin…), and a lossy restore here would make the preview
    /// app's undo lie about what the real engine's undo preserves.
    private enum MockRestore {
        case command(StudioEngineCommand)
        case track(StudioTrackSnapshot, at: Int)
        case clip(StudioClipSnapshot, trackID: UUID, at: Int)
        case device(StudioDeviceSnapshot, trackID: UUID)
    }

    /// Journaled undo/redo units. `forwards` and `inverseGroups` stay
    /// index-aligned (one group per forward); undo applies the groups
    /// last-first, each group's own steps in order — the same shape
    /// timeline-core's txn undo uses. A unit holds ONE command normally, or
    /// every command of a txn.begin/txn.commit bracket, so "one gesture = one
    /// undo step" is measurable against the preview engine too.
    private struct UndoUnit {
        var forwards: [StudioEngineCommand]
        var inverseGroups: [[MockRestore]]
    }
    private var undoStack: [UndoUnit] = []
    private var redoStack: [UndoUnit] = []
    /// The open transaction, when a txn.begin bracket is accumulating.
    private struct OpenTxn { var id: String; var unit: UndoUnit }
    private var openTxn: OpenTxn?

    /// Every ACCEPTED command, in order. This is what an interaction test
    /// asserts against, so "one gesture emitted exactly one journaled command"
    /// is a measured property rather than a convention: an edit path that poked
    /// state directly would leave this empty.
    private(set) var journal: [StudioEngineCommand] = []

    /// Faked asset registry: mock source id -> the path it came from, so the
    /// pad grid and the sampler card can NAME a bound sound in the preview
    /// build exactly as they do against the real engine's `loadedSources`.
    private var loadedSources: [String: String] = [:]

    /// How many times `project.save` was submitted. The mock cannot checkpoint
    /// anything, so this is the only honest thing it can report -- and it is
    /// what lets a test prove ⌘S actually reaches the command bus rather than
    /// merely toggling a label.
    private(set) var savesRequested = 0

    /// Make `project.save` fail, so the failure path can be proven rather than
    /// assumed. Without this the "a refused save is reported" case would be
    /// untestable and the optimistic-confirm bug could return unnoticed.
    private var refuseSave = false

    func setRefuseSave(_ refuse: Bool) { refuseSave = refuse }

    /// Report a track the way the real engine reports one that the APP made
    /// itself — `ensure_instrument_target` creating an instrument because a key
    /// was pressed on an empty project.
    ///
    /// Modelled here rather than skipped, for the same reason `device.param.set`
    /// and `device.zone.add` are: the preview build is where a UI test can drive
    /// this at all. The mock has no note surface, so it cannot auto-create a
    /// track for real; what it CAN carry is the FIELD the snapshot carries, and
    /// the header line and the "here is what just happened" message are both
    /// read off that field. A mock that could not produce it would leave the
    /// whole say-so path provable only by a human looking at a window.
    ///
    /// The engine's own derivation (journal `actor` -> `origin`) is proven where
    /// it lives: `agent-surface/tests/play_a_note.rs`.
    func setTrackOrigin(_ trackID: UUID, _ origin: StudioTrackOrigin?) {
        setTrackOrigins([trackID], origin)
    }

    /// Several at once, in ONE revision.
    ///
    /// Not a convenience: a stem import makes every one of its tracks inside a
    /// single engine mutation, so the app sees them all in one snapshot. Setting
    /// them one at a time bumps `revision` per call, the 30 Hz poll picks each
    /// up separately, and the app's AGGREGATION — one sentence naming four rows
    /// instead of four toasts — never gets exercised. A test that cannot
    /// reproduce the arrival shape cannot test the thing that arrival shape
    /// caused.
    func setTrackOrigins(_ trackIDs: [UUID], _ origin: StudioTrackOrigin?) {
        var touched = false
        for id in trackIDs {
            guard let i = tracks.firstIndex(where: { $0.id == id }) else { continue }
            tracks[i].origin = origin
            touched = true
        }
        if touched { revision += 1 }
    }

    /// The routing DAG and every insert chain (track / bus / master).
    private var routing = StudioRoutingState()

    private let minClipLengthTicks = StudioTick.ppq / 4   // one 16th at 4/4

    /// Tracks currently showing a revise audition take lane (cleared on
    /// commit/discard). Lets the preview engine drive the whole hands-on flow.
    private var reviseTrackIDs: Set<UUID> = []

    // MARK: MIDI state (spec 7.5)

    private var mockMidiEnabled = true
    private let mockMidiPorts = ["SX-KC211 Keyboard (USB MIDI Interface)"]
    private var mockMidiMaps: [StudioMidiMap] = StudioMockEngine.seededMaps()
    private var mockMidiBindings: [StudioMidiBinding] = StudioMockEngine.seededBindings()
    private var mockMidiLearn = StudioMidiLearnState(active: false, device: nil, ageSeconds: nil, captured: nil, current: nil)
    private var mockMidiLastEvent: StudioMidiLastEvent?
    private var mockMidiSterlingRing: [StudioMidiSterlingItem] = []
    private var mockMidiNextSeq: Int = 0
    /// Timestamp for fake learn capture delay.
    private var mockLearnStartHostTime: TimeInterval = 0
    private var mockLearnCaptured = false

    init(project: SyntheticProject = .standard) {
        let built = Self.buildProject(project)
        self.name = built.name
        self.tempoBPM = built.tempoBPM
        self.timeSignature = built.timeSignature
        self.key = built.key
        self.lengthBars = built.lengthBars
        self.sections = built.sections
        self.tracks = built.tracks
        self.provenanceSummary = built.provenanceSummary
        self.takeRecords = built.takeRecords
        self.takeSeqCounter = built.takeRecords.count
    }

    // MARK: StudioEngineProtocol

    func snapshot(ifNewerThan clientRevision: UInt64?) async -> StudioProjectSnapshot? {
        // While playing, position changes continuously; report a fresh
        // transport anchor but only bump revision on real state changes.
        if let clientRevision, clientRevision >= revision, !isPlaying, !recording {
            return nil
        }
        return currentSnapshot()
    }

    @discardableResult
    func send(_ command: StudioEngineCommand) async -> StudioCommandResult {
        // THE SAME SCHEMA CHECK THE REAL ENGINE RUNS, in the test double.
        //
        // This is the whole reason eleven shipping gestures could send the
        // wrong parameter names for the life of the feature. `session.rs`
        // validates params against `command-catalog.v2.json` with
        // `additionalProperties: false` before apply and refuses anything that
        // does not fit — and `applyCatalog` below used to read the SAME wrong
        // keys the app was sending (`gain`, `height`, `index`), so every test
        // of every one of those gestures passed while the real engine refused
        // them. The test double agreed with the bug, which is the one place a
        // bug can hide from every gate at once.
        //
        // So the mock refuses what the engine refuses, from the same contract,
        // and a wrong key now fails under `MAJIKS_ENGINE=mock` too. This is a
        // guard for the class, not for the eleven: the twelfth command written
        // against the mock cannot inherit the defect.
        //
        // TYPED cases are deliberately not checked here. They carry Swift
        // types, not wire params — `RealStudioEngine.route` is what turns them
        // into an envelope, and that is where their contract lives. `.catalog`
        // is the escape hatch with no type safety at all, which is exactly why
        // it is the one that needs the check.
        if case .catalog(let name, let params) = command,
           let refusal = StudioCatalogSchema.refusal(name: name, params: params) {
            return StudioCommandResult(ok: false, message: refusal)
        }
        // Transaction markers bracket ONE undo unit (mirrors session.rs): begin
        // opens an accumulator, commit pushes the merged unit. Both are
        // journaled like any accepted command so a test can assert the bracket;
        // neither is stored in the unit (undo/redo never replay them).
        if case .catalog(let name, let params) = command {
            if name == "txn.begin" {
                guard let id = params["txnId"] as? String, !id.isEmpty else {
                    return StudioCommandResult(ok: false, message: "txn.begin: txnId required")
                }
                guard openTxn == nil else {
                    return StudioCommandResult(ok: false, message: "txn.begin: v1 transactions do not nest")
                }
                openTxn = OpenTxn(id: id, unit: UndoUnit(forwards: [], inverseGroups: []))
                revision += 1
                journal.append(command)
                return StudioCommandResult(ok: true, message: nil)
            }
            if name == "txn.commit" {
                guard let open = openTxn, (params["txnId"] as? String) == open.id else {
                    return StudioCommandResult(ok: false, message: "txn.commit: no matching open txn")
                }
                openTxn = nil
                if !open.unit.forwards.isEmpty {
                    undoStack.append(open.unit)
                    redoStack.removeAll()
                }
                revision += 1
                journal.append(command)
                return StudioCommandResult(ok: true, message: nil)
            }
        }
        // Capture the reversing step(s) from CURRENT state before mutating.
        let inverse = inverse(of: command)
        let ok = apply(command)
        if ok {
            revision += 1
            // The journal is what a test asserts against. Only accepted commands
            // are recorded, and `undo`/`redo` call `apply` directly so a reversal
            // never re-records — the same rule the real bus follows.
            journal.append(command)
            if openTxn != nil {
                // Inside a bracket: accumulate (groups stay index-aligned with
                // forwards, empty group included) instead of pushing a unit.
                openTxn?.unit.forwards.append(command)
                openTxn?.unit.inverseGroups.append(inverse)
            } else if !inverse.isEmpty {
                undoStack.append(UndoUnit(forwards: [command], inverseGroups: [inverse]))
                redoStack.removeAll()
            }
        }
        return StudioCommandResult(
            ok: ok,
            message: ok ? nil : "\(command.catalogName): rejected"
        )
    }

    @discardableResult
    func undo() async -> Bool {
        guard let unit = undoStack.popLast() else { return false }
        // Groups last-first, steps within a group in order (session.rs shape);
        // restores mutate directly and never re-record.
        for group in unit.inverseGroups.reversed() {
            for step in group { applyRestore(step) }
        }
        redoStack.append(unit)
        revision += 1
        return true
    }

    @discardableResult
    func redo() async -> Bool {
        guard let unit = redoStack.popLast() else { return false }
        for forward in unit.forwards { _ = apply(forward) }
        undoStack.append(unit)
        revision += 1
        return true
    }

    /// Apply one reversing step (undo only — forward replay is `apply`).
    private func applyRestore(_ step: MockRestore) {
        switch step {
        case .command(let command):
            _ = apply(command)
        case .track(let track, let index):
            guard !tracks.contains(where: { $0.id == track.id }) else { return }
            tracks.insert(track, at: min(max(0, index), tracks.count))
        case .clip(let clip, let trackID, let index):
            guard let i = trackIndex(trackID),
                  !tracks[i].clips.contains(where: { $0.id == clip.id }) else { return }
            tracks[i].clips.insert(clip, at: min(max(0, index), tracks[i].clips.count))
        case .device(let device, let trackID):
            guard let i = trackIndex(trackID),
                  !tracks[i].devices.contains(where: { $0.id == device.id }) else { return }
            tracks[i].devices.append(device)
        }
    }

    func waveformTile(_ key: StudioTileKey) async -> StudioWaveformTile? {
        // Prove the async path honestly (tiles arrive a beat after the ask)
        // without ever blocking the UI thread.
        try? await Task.sleep(nanoseconds: 1_500_000)
        return Self.generateTile(key)
    }

    func openInStudio(_ request: StudioLandingRequest) async -> StudioCommandResult {
        // The mock has no analysis/separation engine; the real landing runs on
        // the FFI-backed engine (RealStudioEngine). The mock already shows a
        // demo session, so this is a no-op that reports honestly.
        StudioCommandResult(
            ok: false,
            message: "Open in Studio runs on the on-device engine (this is the preview engine)."
        )
    }

    /// Mock import: place a clip with a fresh waveform seed on the target track,
    /// so the dev / no-framework build demonstrates "load a song onto the
    /// timeline" end to end (double-click or drag a Library song -> a clip you
    /// can see, scrub, and audition). The real file read + analysis runs on
    /// RealStudioEngine; the mock is SILENT — it reads no audio and plays
    /// nothing, it only grows the arrangement model. `waveformTile` already
    /// vends a deterministic tile for any seed, so the clip draws a waveform.
    func importAudio(path: String, trackID: UUID?, startTicks: Int64) async -> StudioCommandResult {
        let targetIndex: Int
        if let trackID, let i = tracks.firstIndex(where: { $0.id == trackID }) {
            targetIndex = i
        } else if !tracks.isEmpty {
            targetIndex = 0
        } else {
            return StudioCommandResult(ok: false, message: "No track to import onto.")
        }
        // Through `send`, NOT by mutating `tracks` here.
        //
        // This used to place the clip directly and bump `revision`. The
        // arrangement looked right and everything downstream of it worked, and
        // TWO things were quietly untrue in the preview build: the import never
        // appeared in `journal`, and it pushed no undo unit — so undo after
        // importing a song reversed whatever the user had done BEFORE it, and
        // the clip stayed. The catalog has said `import.audio` is
        // `journaled: true, undoable: true, inverse: clip.remove` the whole
        // time; the mock simply was not modelling it, which is the same shape
        // as `take.auditionMix` being an `unjournaled_noop()` behind a real
        // listening decision.
        //
        // The clip id is minted HERE and passed as the catalog's optional
        // `clipId` so the inverse can name the exact clip to remove — the same
        // reason `bindSamples` mints its zone ids before sending.
        let clipID = UUID()
        return await send(.catalog(name: "import.audio", params: [
            "sourcePath": path,
            "targetTrackId": tracks[targetIndex].id.uuidString,
            "startTicks": NSNumber(value: max(0, startTicks)),
            "clipId": clipID.uuidString,
        ]))
    }

    /// Mock source binding: the preview engine's version of "load a sound into
    /// a sampler / drum pad".
    ///
    /// It reads NO audio — the mock is silent by construction — so the ingest
    /// is faked by content-addressing the PATH instead of the bytes. Everything
    /// downstream of that is real: the same catalog commands, in the same
    /// order, inside a real `txn.begin`/`txn.commit` bracket, so the journal a
    /// test asserts against and the undo it exercises have the shape the FFI
    /// engine produces. What the mock cannot prove is that a note makes a
    /// sound; the real-engine tests own that, and no test here pretends
    /// otherwise.
    func bindSamples(_ request: StudioSampleBindRequest) async -> StudioSampleBindOutcome {
        guard let i = trackIndex(request.trackID) else {
            return .failed("That track is no longer in the project.")
        }
        let existing = request.deviceID.flatMap { id in
            tracks[i].devices.first(where: { $0.id == id })
        }
        let deviceID: String
        let kind: String
        let creating: Bool
        if let requested = request.deviceID {
            guard let existing else { return .failed("Unknown instrument \(requested).") }
            guard existing.playsSamples else {
                return .failed("A Synth synthesizes its sound and reads no audio file; " +
                               "a sound can only be loaded into a Sampler or a Drum Rack.")
            }
            deviceID = existing.id
            kind = existing.kind
            creating = false
        } else {
            if let already = tracks[i].devices.first {
                return .failed("This track already plays a \(already.instrumentLabel). " +
                               "Remove it first, then load a different instrument.")
            }
            guard let requested = request.kind, requested == "sampler" || requested == "drum" else {
                return .failed("Choose Sampler or Drum Rack.")
            }
            deviceID = "inst_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
            kind = requested
            creating = true
        }

        // The same shape checks the engine makes, so the preview build refuses
        // the same gestures rather than accepting one the real build rejects.
        var surviving = (existing?.zones ?? [])
            .filter { !request.removeZoneIDs.contains($0.id) }
            .map(\.loPitch)
        for b in request.bindings {
            guard (0...127).contains(b.loPitch), (0...127).contains(b.hiPitch),
                  b.hiPitch >= b.loPitch else {
                return .failed("A key has to be a note between 0 and 127.")
            }
            if kind == "drum" && b.hiPitch != b.loPitch {
                return .failed("A drum pad covers exactly one key.")
            }
            surviving.append(b.loPitch)
        }
        if surviving.isEmpty {
            return .failed("That would leave the instrument with no sounds at all, and an " +
                           "instrument with nothing to play cannot render; remove the " +
                           "instrument instead.")
        }
        if kind == "drum" {
            let sorted = surviving.sorted()
            if sorted.count != Set(sorted).count {
                return .failed("Two pads would land on the same key; replace the pad instead.")
            }
            if let lo = sorted.first, let hi = sorted.last, hi - lo >= StudioDrumRack.padCount {
                return .failed("Those pads span keys \(lo)–\(hi), wider than the " +
                               "\(StudioDrumRack.padCount)-pad rack.")
            }
        }

        let txnID = "ui_\(UUID().uuidString.prefix(12))"
        let trackKey = request.trackID.uuidString
        let ownsTransaction = openTxn == nil
        if ownsTransaction {
            _ = await send(.catalog(name: "txn.begin",
                                    params: ["txnId": txnID, "reason": request.reason]))
        }
        if creating {
            _ = await send(.catalog(name: "device.add", params: [
                "trackId": trackKey, "deviceId": deviceID, "kind": kind,
            ]))
        }
        for zoneID in request.removeZoneIDs {
            _ = await send(.catalog(name: "device.zone.remove", params: [
                "trackId": trackKey, "deviceId": deviceID, "zoneId": zoneID,
            ]))
        }
        var zoneIDs: [String] = []
        for b in request.bindings {
            let sourceID = Self.mockSourceID(for: b.sourcePath)
            let zoneID = "zone_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
            loadedSources[sourceID] = b.sourcePath
            _ = await send(.catalog(name: "device.zone.add", params: [
                "trackId": trackKey, "deviceId": deviceID, "zoneId": zoneID,
                "sourceId": sourceID,
                "rootPitch": NSNumber(value: b.rootPitch),
                "loPitch": NSNumber(value: b.loPitch),
                "hiPitch": NSNumber(value: b.hiPitch),
            ]))
            zoneIDs.append(zoneID)
        }
        if ownsTransaction {
            _ = await send(.catalog(name: "txn.commit", params: ["txnId": txnID]))
        }
        return StudioSampleBindOutcome(
            ok: true, message: nil, deviceID: deviceID, kind: kind,
            createdDevice: creating, zoneIDs: zoneIDs)
    }

    /// A stand-in for the engine's blake3-of-the-file-bytes. Content-addressed
    /// on the PATH, which is the one thing the mock has: the same file picked
    /// twice is the same id, which is the property the pad grid depends on.
    /// Deliberately not 64 hex characters — nothing should mistake it for a
    /// real asset hash.
    static func mockSourceID(for path: String) -> String {
        "mock-\(abs(path.hashValue))"
    }

    // MARK: Revise / Extend / Add-a-Layer (L9) - the preview engine drives the
    // whole hands-on flow so `MAJIKS_ENGINE=mock` exercises it. The real engine
    // does the generation + splice + commit txn; here the takes "render"
    // instantly and commit folds them into the timeline.

    func revise(_ request: StudioReviseRequest) async -> StudioReviseOutcome {
        let n = max(1, min(request.variants, 8))
        // The scoped stem clips and their tracks.
        var scoped: [(trackIndex: Int, clipID: UUID, stem: StudioStemKind)] = []
        for clipID in request.clipIDs {
            if let loc = findClip(clipID) {
                scoped.append((loc.trackIndex, clipID, tracks[loc.trackIndex].kind))
            }
        }
        guard !scoped.isEmpty else { return .failed("No clip under the selection.") }

        let regionLen = max(timeSignature.ticksPerBar, request.regionEndTicks - request.regionStartTicks)
        var variants: [StudioReviseVariant] = []
        var drafts: [Int: [String]] = [:]
        for v in 0..<n {
            var proms: [StudioPromotion] = []
            var draftIDs: [String] = []
            for sc in scoped {
                let handle = "mocktake_\(sc.clipID.uuidString.prefix(6))_v\(v)"
                proms.append(StudioPromotion(takeID: handle, clipID: sc.clipID, stem: sc.stem))
                draftIDs.append(handle)
            }
            variants.append(StudioReviseVariant(index: v, seed: 0xA11CE &+ UInt64(v), promotions: proms))
            drafts[v] = draftIDs
        }
        // Materialize take lanes on the scoped tracks (renders land instantly).
        reviseTrackIDs.removeAll()
        for sc in scoped {
            let takes = (0..<n).map { i in
                StudioTakeSnapshot(id: UUID(), name: "Take \(i + 1)", state: .rendered(seed: 0xA11CE &+ UInt64(i)), picked: false)
            }
            tracks[sc.trackIndex].takeLane = StudioTakeLaneSnapshot(
                id: UUID(), regionStartTicks: request.regionStartTicks, regionLengthTicks: regionLen, takes: takes)
            reviseTrackIDs.insert(tracks[sc.trackIndex].id)
        }
        // Record each variant's takes as candidates for the Takes browser, with
        // joined lineage (prompt + seed + region), keyed by the SAME take handle
        // the audition/commit path uses.
        let promptText = request.instruction.trimmingCharacters(in: .whitespaces)
        for variant in variants {
            for prom in variant.promotions {
                takeSeqCounter += 1
                takeRecords.append(StudioTakeBrowserItem(
                    takeID: prom.takeID,
                    requestID: "req_\(prom.stem.rawValue)_\(request.regionStartTicks)",
                    kind: .revise, stemName: prom.stem.rawValue, status: .candidate,
                    promotedInto: nil, assetHash: "mock_\(prom.takeID)", auditionable: true,
                    provenance: false, offline: false, createdTs: nil, createdSeq: takeSeqCounter,
                    lineage: StudioTakeLineage(
                        prompt: promptText.isEmpty ? "revise region" : promptText,
                        seed: variant.seed, model: "acestep-v15-turbo", steps: 8, device: "cpu",
                        regionStartTicks: request.regionStartTicks, regionEndTicks: request.regionEndTicks)))
            }
        }
        revision += 1
        let preRoll = 2 * timeSignature.ticksPerBar
        return StudioReviseOutcome(
            ok: true, message: nil, variants: variants,
            auditionLoopStart: max(0, request.regionStartTicks - preRoll),
            auditionLoopEnd: request.regionEndTicks, draftTakeIDsByVariant: drafts)
    }

    func commitRevise(_ promotions: [StudioPromotion], reason: String) async -> StudioCommandResult {
        for p in promotions {
            guard let loc = findClip(p.clipID) else { continue }
            // Fold the take in: the clip is now generated audio (shimmer badge),
            // with a fresh waveform seed (new material), take lane cleared.
            tracks[loc.trackIndex].clips[loc.clipIndex].generative = true
            tracks[loc.trackIndex].clips[loc.clipIndex].waveformSeed ^= 0x9E37_79B1
            tracks[loc.trackIndex].takeLane = nil
            reviseTrackIDs.remove(tracks[loc.trackIndex].id)
            // The chosen take (per-stem: this is exactly the take picked for this
            // stem) is now promoted into its clip; the record stays as lineage.
            markPromoted(takeID: p.takeID, clipID: p.clipID)
        }
        clearRemainingReviseLanes()
        revision += 1
        return StudioCommandResult(ok: true, message: nil)
    }

    /// Mark a take record promoted into a clip (the browser reads it back as
    /// committed lineage, not an auditionable alternative).
    private func markPromoted(takeID: String, clipID: UUID) {
        guard let i = takeRecords.firstIndex(where: { $0.takeID == takeID }) else { return }
        takeRecords[i].status = .promoted
        takeRecords[i].auditionable = false
        takeRecords[i].promotedInto = clipID.uuidString
    }

    func discardRevise(takeIDs: [String]) async -> StudioCommandResult {
        clearRemainingReviseLanes()
        revision += 1
        return StudioCommandResult(ok: true, message: nil)
    }

    private func clearRemainingReviseLanes() {
        for id in reviseTrackIDs {
            if let i = tracks.firstIndex(where: { $0.id == id }) {
                tracks[i].takeLane = nil
            }
        }
        reviseTrackIDs.removeAll()
    }

    func extendClip(clipID: UUID, addedSeconds: Double, instruction: String, variants: Int) async -> StudioGenOutcome {
        guard findClip(clipID) != nil else { return .failed("Unknown clip.") }
        let n = max(1, min(variants, 8))
        let takes = (0..<n).map { i in
            StudioGenTake(takeID: "mockext_\(clipID.uuidString.prefix(6))_v\(i)", seed: 0xE47E &+ UInt64(i), label: "Tail \(i + 1)")
        }
        return StudioGenOutcome(ok: true, message: nil, takes: takes, targetTrackID: nil)
    }

    func commitExtend(takeID: String, clipID: UUID) async -> StudioCommandResult {
        guard let loc = findClip(clipID) else { return StudioCommandResult(ok: false, message: "Unknown clip.") }
        let anchor = tracks[loc.trackIndex].clips[loc.clipIndex]
        var tail = anchor
        tail.id = UUID()
        tail.startTicks = anchor.endTicks
        tail.lengthTicks = max(timeSignature.ticksPerBar, anchor.lengthTicks / 2)
        tail.generative = true
        tail.waveformSeed ^= 0x51ED
        tail.fadeInTicks = StudioTick.ppq / 8
        tracks[loc.trackIndex].clips.insert(tail, at: loc.clipIndex + 1)
        lengthBars = max(lengthBars, Int((tail.endTicks + timeSignature.ticksPerBar - 1) / timeSignature.ticksPerBar))
        revision += 1
        return StudioCommandResult(ok: true, message: nil)
    }

    func addLayer(instruction: String, regionStartTicks: Int64, regionEndTicks: Int64, contextClipID: UUID?, stem: StudioStemKind, variants: Int) async -> StudioGenOutcome {
        // Prepare a NEW track (01-DESIGN 3.3b) with a take lane.
        let n = max(1, min(variants, 8))
        let trackID = UUID()
        let takes = (0..<n).map { i in
            StudioTakeSnapshot(id: UUID(), name: "Take \(i + 1)", state: .rendered(seed: 0x1E60 &+ UInt64(i)), picked: false)
        }
        let lane = StudioTakeLaneSnapshot(id: UUID(), regionStartTicks: regionStartTicks,
            regionLengthTicks: max(timeSignature.ticksPerBar, regionEndTicks - regionStartTicks), takes: takes)
        tracks.append(StudioTrackSnapshot(
            id: trackID, name: instruction.isEmpty ? "Layer" : String(instruction.prefix(18)),
            kind: stem, volumeDB: -4, pan: 0, clips: [], takeLane: lane, hasVolumeAutomation: false))
        reviseTrackIDs.insert(trackID)
        revision += 1
        let genTakes = (0..<n).map { i in
            StudioGenTake(takeID: "mocklayer_\(trackID.uuidString.prefix(6))_v\(i)", seed: 0x1E60 &+ UInt64(i), label: "Take \(i + 1)")
        }
        return StudioGenOutcome(ok: true, message: nil, takes: genTakes, targetTrackID: trackID.uuidString)
    }

    func commitLayer(takeID: String, targetTrackID: String, regionStartTicks: Int64) async -> StudioCommandResult {
        guard let uuid = UUID(uuidString: targetTrackID),
              let i = tracks.firstIndex(where: { $0.id == uuid }) else {
            return StudioCommandResult(ok: false, message: "Unknown layer track.")
        }
        let regionLen = tracks[i].takeLane?.regionLengthTicks ?? (2 * timeSignature.ticksPerBar)
        let clip = StudioClipSnapshot(
            id: UUID(), name: tracks[i].name.lowercased(), startTicks: regionStartTicks,
            lengthTicks: regionLen, sourceOffsetTicks: 0,
            fadeInTicks: StudioTick.ppq / 8, fadeOutTicks: StudioTick.ppq / 8,
            generative: true, waveformSeed: 0x1E60 | 1)
        tracks[i].clips = [clip]
        tracks[i].takeLane = nil
        reviseTrackIDs.remove(uuid)
        revision += 1
        return StudioCommandResult(ok: true, message: nil)
    }

    // MARK: Takes browser (L10)

    func takes(query: StudioTakesQuery) async -> [StudioTakeBrowserItem] {
        takeRecords.filter { t in
            if let c = query.clipID, t.promotedInto != c { return false }
            if let r = query.requestID, t.requestID != r { return false }
            if let k = query.kind, t.kind != k { return false }
            if query.auditionableOnly && !t.auditionable { return false }
            if !query.includePurged && t.offline { return false }
            return true
        }
    }

    func auditionMix(takeID: String, stems: [String]) async -> StudioCommandResult {
        // Preview signal (which stems of a take are audible). The preview engine
        // is silent, so this validates the take exists and reports honestly.
        guard takeRecords.contains(where: { $0.takeID == takeID }) else {
            return StudioCommandResult(ok: false, message: "Unknown take.")
        }
        return StudioCommandResult(ok: true, message: nil)
    }

    func purgeTakes(scope: StudioPurgeScope) async -> StudioPurgeResult {
        var purged = 0
        for i in takeRecords.indices {
            let t = takeRecords[i]
            guard t.status == .candidate, t.kind != .landing, !t.offline else { continue }
            let inScope: Bool
            switch scope {
            case .all: inScope = true
            case .take(let id): inScope = t.takeID == id
            case .request(let r): inScope = t.requestID == r
            }
            guard inScope else { continue }
            // Reclaim the audio: the record stays as lineage but reads offline.
            takeRecords[i].offline = true
            takeRecords[i].auditionable = false
            purged += 1
        }
        if purged > 0 { revision += 1 }
        return StudioPurgeResult(
            ok: true, purgedCount: purged, assetsDeleted: purged, bytesReclaimed: 0,
            message: purged == 0 ? "No purgeable candidate takes." : nil)
    }

    func placeTake(takeID: String, ontoClipID: UUID) async -> StudioCommandResult {
        guard takeRecords.contains(where: { $0.takeID == takeID }) else {
            return StudioCommandResult(ok: false, message: "Unknown take.")
        }
        guard let loc = findClip(ontoClipID) else {
            return StudioCommandResult(ok: false, message: "Drop a take onto a clip to use it there.")
        }
        // Use the take here: the clip becomes this take's generated audio.
        tracks[loc.trackIndex].clips[loc.clipIndex].generative = true
        tracks[loc.trackIndex].clips[loc.clipIndex].waveformSeed ^= 0x7A4E
        markPromoted(takeID: takeID, clipID: ontoClipID)
        revision += 1
        return StudioCommandResult(ok: true, message: nil)
    }

    // MARK: Command application

    private func apply(_ command: StudioEngineCommand) -> Bool {
        switch command {
        case .transportPlay:
            guard !isPlaying else { return true }
            anchorTicks = currentPositionTicks(now: hostNow())
            anchorHostTime = hostNow()
            isPlaying = true
            return true

        case .transportStop:
            anchorTicks = currentPositionTicks(now: hostNow())
            isPlaying = false
            return true

        case .transportSeek(let ticks):
            anchorTicks = max(0, min(ticks, projectLengthTicks))
            anchorHostTime = hostNow()
            return true

        case .transportLoopSet(let start, let end):
            guard end > start else { return false }
            loopRegion = max(0, start)...end
            return true

        case .transportLoopClear:
            loopRegion = nil
            return true

        case .transportMetronome(let enabled):
            // The mock is SILENT BY DEFINITION, so it stores the flag and makes
            // no sound. It must still return true: the mock refusing a command
            // the real engine accepts would put a failure toast in front of
            // every UI test, and the toggle would appear not to stick.
            metronomeEnabled = enabled
            return true

        case .clipMove(let clipID, let toTrackID, let toStartTicks):
            guard var clip = removeClip(clipID) else { return false }
            guard let targetIndex = tracks.firstIndex(where: { $0.id == toTrackID }) else {
                return false
            }
            clip.startTicks = StudioTimelineMath.clampedMoveStart(
                proposedStartTicks: toStartTicks,
                lengthTicks: clip.lengthTicks,
                projectLengthTicks: projectLengthTicks
            )
            tracks[targetIndex].clips.append(clip)
            tracks[targetIndex].clips.sort { $0.startTicks < $1.startTicks }
            return true

        case .clipTrim(let clipID, let newStartTicks, let newLengthTicks):
            return mutateClip(clipID) { clip in
                guard newLengthTicks >= self.minClipLengthTicks, newStartTicks >= 0 else {
                    return false
                }
                let delta = newStartTicks - clip.startTicks
                clip.sourceOffsetTicks = max(0, clip.sourceOffsetTicks + delta)
                clip.startTicks = newStartTicks
                clip.lengthTicks = newLengthTicks
                return true
            }

        case .clipSplit(let clipID, let atTicks):
            guard let location = findClip(clipID) else { return false }
            let clip = tracks[location.trackIndex].clips[location.clipIndex]
            guard let lengths = StudioTimelineMath.splitLengths(
                start: clip.startTicks, length: clip.lengthTicks, atTicks: atTicks
            ) else { return false }
            var left = clip
            left.lengthTicks = lengths.left
            left.fadeOutTicks = 0
            var right = clip
            right.id = UUID()
            right.startTicks = atTicks
            right.lengthTicks = lengths.right
            right.sourceOffsetTicks = clip.sourceOffsetTicks + lengths.left
            right.fadeInTicks = 0
            tracks[location.trackIndex].clips[location.clipIndex] = left
            tracks[location.trackIndex].clips.insert(right, at: location.clipIndex + 1)
            return true

        case .clipDuplicate(let clipID):
            guard let location = findClip(clipID) else { return false }
            var copy = tracks[location.trackIndex].clips[location.clipIndex]
            copy.id = UUID()
            copy.startTicks = copy.endTicks
            tracks[location.trackIndex].clips.insert(copy, at: location.clipIndex + 1)
            return true

        case .clipRemove(let clipID):
            return removeClip(clipID) != nil

        case .clipFadeSet(let clipID, let fadeIn, let fadeOut):
            return mutateClip(clipID) { clip in
                let maxFade = clip.lengthTicks
                clip.fadeInTicks = min(max(0, fadeIn), maxFade)
                clip.fadeOutTicks = min(max(0, fadeOut), maxFade - clip.fadeInTicks)
                return true
            }

        case .trackMute(let trackID, let muted):
            guard let i = tracks.firstIndex(where: { $0.id == trackID }) else { return false }
            tracks[i].muted = muted
            return true

        case .trackSolo(let trackID, let soloed):
            guard let i = tracks.firstIndex(where: { $0.id == trackID }) else { return false }
            tracks[i].soloed = soloed
            return true

        case .trackArm(let trackID, let armed):
            guard let i = tracks.firstIndex(where: { $0.id == trackID }) else { return false }
            tracks[i].armed = armed
            return true

        case .trackSetInputChannel(let trackID, let channel):
            guard let i = tracks.firstIndex(where: { $0.id == trackID }) else { return false }
            tracks[i].inputChannel = max(0, channel)
            return true

        case .trackAdd(let trackID, let name, let index):
            // Mirror the real engine: create an empty track so the preview build
            // demonstrates auto-create -> import onto a fresh (0-track) project.
            // The id is parsed from the UI-minted string when it is a UUID (so it
            // is stable/inspectable), else a fresh one; the view model reads the
            // created track's id back from the next snapshot regardless.
            let id = UUID(uuidString: trackID) ?? UUID()
            guard !tracks.contains(where: { $0.id == id }) else { return false }
            let at = max(0, min(index, tracks.count))
            tracks.insert(StudioTrackSnapshot(
                id: id, name: name.isEmpty ? "Audio 1" : name, kind: .imported,
                clips: [], takeLane: nil), at: at)
            return true

        case .trackRemove(let trackID):
            // Mirror the engine's guard: a track still carrying clips refuses
            // (track_not_empty) — the delete gesture removes the clips first,
            // inside the same txn, so the whole thing is one undo unit.
            guard let i = trackIndex(trackID), tracks[i].clips.isEmpty else { return false }
            tracks.remove(at: i)
            return true

        case .deviceRemove(let trackID, let deviceID):
            guard let i = trackIndex(trackID),
                  let d = tracks[i].devices.firstIndex(where: { $0.id == deviceID }) else { return false }
            tracks[i].devices.remove(at: d)
            return true

        case .deviceAdd(let trackID, let deviceID, let kind):
            guard let i = trackIndex(trackID), !deviceID.isEmpty,
                  !tracks[i].devices.contains(where: { $0.id == deviceID }) else { return false }
            tracks[i].devices.append(StudioDeviceSnapshot(id: deviceID, kind: kind))
            return true

        // ---- recording (L19): simulated capture; no device or stream opened ----
        case .recordStart(let trackID, _, let startTicks, let punchOutTicks):
            guard let i = tracks.firstIndex(where: { $0.id == trackID }), tracks[i].armed else { return false }
            recording = true
            recordingTrackID = trackID
            let now = hostNow()
            let current = currentPositionTicks(now: now)
            recordRolling = isPlaying
            recordStartTicks = max(0, recordRolling ? (punchOutTicks != nil ? (startTicks ?? current) : current) : (startTicks ?? current))
            recordPunchOutTicks = punchOutTicks
            recordStartHostTime = now
            return true
        case .recordRotate:
            return landMockRecording(continueCapture: true)
        case .recordStop:
            return landMockRecording(continueCapture: false)
        case .recordCancel:
            let was = recording
            recording = false
            recordingTrackID = nil
            recordPunchOutTicks = nil
            inputListening = false
            return was
        case .recordInputListen(let enabled, _):
            // Mock has no device; still flips the privacy indicator so UI tests
            // can prove arm ≠ open and listen does.
            inputListening = enabled && !recording
            return true

        case .projectSetTempo(let bpm):
            guard bpm >= 20, bpm <= 300 else { return false }
            anchorTicks = currentPositionTicks(now: hostNow())
            anchorHostTime = hostNow()
            tempoBPM = bpm
            return true

        case .projectSetTimeSig(let num, let den):
            guard num >= 1, num <= 32, den == 2 || den == 4 || den == 8 else { return false }
            timeSignature = StudioTimeSignature(beatsPerBar: num, beatUnit: den)
            return true

        case .projectSetKey(let key):
            guard !key.isEmpty else { return false }
            self.key = key
            return true

        // ---- mixer (L12) ----
        case .mixGain(let trackID, let gainDB):
            guard let i = trackIndex(trackID) else { return false }
            tracks[i].volumeDB = clampGain(gainDB)
            return true

        case .mixPan(let trackID, let pan):
            guard let i = trackIndex(trackID) else { return false }
            tracks[i].pan = max(-1, min(1, pan))
            return true

        case .mixEq(let trackID, let band, let freqHz, let gainDB, let q):
            guard let i = trackIndex(trackID), band >= 0, band < tracks[i].eq.count else { return false }
            tracks[i].eq[band] = StudioEqBand(
                index: band,
                freqHz: max(20, min(20_000, freqHz)),
                gainDB: max(-24, min(24, gainDB)),
                q: max(0.05, min(10, q)))
            return true

        case .mixSend(let trackID, let bus, let amount):
            guard let i = trackIndex(trackID) else { return false }
            let a = max(0, min(1, amount))
            if bus == .a { tracks[i].sendA = a } else { tracks[i].sendB = a }
            return true

        case .mixMasterGain(let gainDB):
            master.volumeDB = clampGain(gainDB)
            return true

        case .mixLimiterSet(let enabled, let ceilingDB, let releaseMs):
            master.limiterEnabled = enabled
            master.limiterCeilingDBTP = max(-6, min(0, ceilingDB))
            master.limiterReleaseMs = max(1, min(1000, releaseMs))
            return true

        // ---- automation (L12) ----
        case .autolaneShow:
            // View-state toggle; lane visibility lives in the view model (the
            // catalog marks autolane.show non-journaled). Accept as a no-op so
            // agent-driven show/hide does not error.
            return true

        case .autopointAdd(let trackID, let target, let pointID, let positionTicks, let value):
            guard let i = trackIndex(trackID) else { return false }
            guard !tracks[i].automation(target).contains(where: { $0.id == pointID }) else { return false }
            setLane(&tracks[i], target,
                    sorted(tracks[i].automation(target) + [
                        StudioAutoPoint(id: pointID, positionTicks: max(0, positionTicks), value: value)
                    ]))
            return true

        case .autopointMove(let trackID, let target, let pointID, let positionTicks, let value):
            guard let i = trackIndex(trackID) else { return false }
            var pts = tracks[i].automation(target)
            guard let p = pts.firstIndex(where: { $0.id == pointID }) else { return false }
            pts[p].positionTicks = max(0, positionTicks)
            pts[p].value = value
            setLane(&tracks[i], target, sorted(pts))
            return true

        case .autopointRemove(let trackID, let target, let pointID):
            guard let i = trackIndex(trackID) else { return false }
            var pts = tracks[i].automation(target)
            guard let p = pts.firstIndex(where: { $0.id == pointID }) else { return false }
            pts.remove(at: p)
            setLane(&tracks[i], target, pts)
            return true

        case .autolaneClear(let trackID, let target):
            guard let i = trackIndex(trackID) else { return false }
            setLane(&tracks[i], target, [])
            return true

        case .catalog(let name, let params):
            return applyCatalog(name, params)
        }
    }

    // MARK: Catalog dispatch (midi.* verbs, spec 7.5)

    /// What a track's colour and height are before anyone sets them.
    ///
    /// Mirrors `DEFAULT_TRACK_COLOR` / `DEFAULT_TRACK_HEIGHT_PX` in
    /// `timeline-core/src/model.rs`, because the inverse of a first-ever
    /// `track.setColor` is "put it back to the default" and that value has to
    /// be a colour the contract's `^#[0-9A-Fa-f]{6}$` accepts.
    static let defaultTrackColor = "#FFFFFF"
    static let defaultTrackHeightPx = 90

    /// A section's role, read off its name — the same derivation
    /// `RealStudioEngine.sectionRole` uses. Not a wire field: `section.set`'s
    /// schema has no `role`, and sending one was refused.
    static func sectionRole(_ name: String) -> StudioSectionRole {
        let n = name.lowercased()
        if n.contains("verse") { return .verse }
        if n.contains("chorus") || n.contains("drop") { return .chorus }
        if n.contains("bridge") { return .bridge }
        return .neutral
    }

    /// Recompute every section's length from its neighbours.
    ///
    /// The engine stores a START only; length is the distance to the next
    /// section, or to the end of the project for the last one. The mock used to
    /// store whatever `lengthBars` the caller sent, which is how a parameter
    /// the contract does not have came to look like it worked.
    private func resolveSectionLengths() {
        sections.sort { $0.startBar < $1.startBar }
        for i in sections.indices {
            let next = i + 1 < sections.count ? sections[i + 1].startBar : lengthBars
            sections[i].lengthBars = max(1, next - sections[i].startBar)
        }
    }

    private func applyCatalog(_ name: String, _ params: [String: AnyHashable]) -> Bool {
        func str(_ k: String) -> String? { params[k] as? String }
        func num(_ k: String) -> Double? { (params[k] as? NSNumber)?.doubleValue }
        func int(_ k: String) -> Int? { (params[k] as? NSNumber)?.intValue }
        func bool(_ k: String) -> Bool? { (params[k] as? NSNumber)?.boolValue ?? (params[k] as? Bool) }

        switch name {
        // Lifecycle, not a mutation. The mock has no package to checkpoint, so
        // it ACKNOWLEDGES rather than refusing: a mock build must not report a
        // save failure the real engine would not produce, and the save
        // affordance has to be exercisable in every build the UI tests run in.
        // `savesRequested` is what a test asserts on.
        case "project.save":
            if refuseSave { return false }
            savesRequested += 1
            return true

        // The import. Placed here rather than in `importAudio` so it rides the
        // journaled bus like every other mutation — see the comment there.
        //
        // The mock reads NO audio (it is silent by construction), so the clip
        // gets a deterministic waveform seed and a four-bar placeholder length
        // instead of the file's real duration. What it DOES model exactly is
        // the arrangement change, its journal entry, and its inverse, which is
        // what a UI test can actually assert on.
        case "import.audio":
            guard let source = str("sourcePath"), !source.isEmpty,
                  let tid = str("targetTrackId").flatMap(UUID.init(uuidString:)),
                  let i = trackIndex(tid),
                  let clipID = str("clipId").flatMap(UUID.init(uuidString:)) else { return false }
            let barTicks = timeSignature.ticksPerBar
            let start = Int64(max(0, int("startTicks") ?? 0))
            let length = barTicks > 0 ? barTicks * 4 : StudioTick.ppq * 4   // 4-bar placeholder
            let stem = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
            tracks[i].clips.append(StudioClipSnapshot(
                id: clipID, name: stem.isEmpty ? "Imported" : stem,
                startTicks: start, lengthTicks: length,
                generative: false, waveformSeed: 0x1A11_0000 &+ UInt64(tracks[i].clips.count)))
            if barTicks > 0 {
                lengthBars = max(lengthBars, Int((start + length + barTicks - 1) / barTicks))
            }
            return true

        // E1/E2 instrument registry, enough of it for the preview app + the
        // interaction tests to build a track that HAS an instrument (the real
        // addInstrumentTrack path is FFI-only). trackId is the mock track's
        // UUID string, deviceId/kind ride the catalog shapes verbatim.
        case "device.add":
            guard let tid = (params["trackId"] as? String).flatMap(UUID.init(uuidString:)),
                  let deviceID = params["deviceId"] as? String, !deviceID.isEmpty,
                  let i = trackIndex(tid),
                  !tracks[i].devices.contains(where: { $0.id == deviceID }) else { return false }
            tracks[i].devices.append(StudioDeviceSnapshot(
                id: deviceID, kind: params["kind"] as? String ?? "synth"))
            return true

        // The SOURCE BINDING. Modelled here rather than skipped, because the
        // preview build is where a UI test can drive the sampler gestures at
        // all — and a mock that accepted the gesture without recording the zone
        // would let the pad grid pass a test while showing nothing.
        //
        // The engine's own refusals are mirrored (one key per pad on a drum,
        // no two pads on one key, no zone on a synth); the mock is SILENT, so
        // what it cannot mirror is the audio, and the real-engine tests own
        // that half.
        case "device.zone.add":
            guard let tid = (params["trackId"] as? String).flatMap(UUID.init(uuidString:)),
                  let deviceID = params["deviceId"] as? String,
                  let zoneID = params["zoneId"] as? String, !zoneID.isEmpty,
                  let sourceID = params["sourceId"] as? String, !sourceID.isEmpty,
                  let i = trackIndex(tid),
                  let d = tracks[i].devices.firstIndex(where: { $0.id == deviceID }),
                  tracks[i].devices[d].kind != "synth",
                  !tracks[i].devices[d].zones.contains(where: { $0.id == zoneID })
            else { return false }
            let lo = int("loPitch") ?? 0
            let hi = int("hiPitch") ?? 127
            guard (0...127).contains(lo), (0...127).contains(hi), hi >= lo else { return false }
            if tracks[i].devices[d].kind == "drum" && hi != lo { return false }
            if tracks[i].devices[d].zones.contains(where: { $0.loPitch == lo && $0.hiPitch == hi }) {
                return false
            }
            tracks[i].devices[d].zones.append(StudioZoneSnapshot(
                id: zoneID, sourceID: sourceID,
                rootPitch: int("rootPitch") ?? 60, loPitch: lo, hiPitch: hi,
                gainDB: num("gainDb") ?? 0, pan: num("pan") ?? 0))
            // The engine sorts by (loPitch, id) so overlapping zones resolve
            // deterministically. The pad grid reads this order straight out, so
            // the mock has to sort the same way or the grid differs by build.
            tracks[i].devices[d].zones.sort { ($0.loPitch, $0.id) < ($1.loPitch, $1.id) }
            return true

        case "device.zone.remove":
            guard let tid = (params["trackId"] as? String).flatMap(UUID.init(uuidString:)),
                  let deviceID = params["deviceId"] as? String,
                  let zoneID = params["zoneId"] as? String,
                  let i = trackIndex(tid),
                  let d = tracks[i].devices.firstIndex(where: { $0.id == deviceID }),
                  let z = tracks[i].devices[d].zones.firstIndex(where: { $0.id == zoneID })
            else { return false }
            tracks[i].devices[d].zones.remove(at: z)
            return true

        // What the instrument SOUNDS like. Modelled here — not skipped — for
        // the same reason `device.zone.add` is: a mock that accepted the
        // gesture without recording the parameter would let the tone panel pass
        // a test while the preset buttons lit nothing and changed nothing.
        //
        // SPARSITY IS THE BEHAVIOUR UNDER TEST, so it is mirrored exactly: an
        // absent key means the DSP default, `set` on an absent key inverts to
        // `clear`, and `clear` on an absent key is a REFUSAL rather than a
        // silent no-op (a no-op has no exact inverse to journal). The mock is
        // silent, so what it cannot mirror is the audio; the Rust proof
        // (`agent-surface/tests/instrument_tone.rs`) owns that half.
        case "device.param.set":
            guard let tid = (params["trackId"] as? String).flatMap(UUID.init(uuidString:)),
                  let deviceID = params["deviceId"] as? String,
                  let key = str("key"), StudioMockEngine.deviceParamKeys.contains(key),
                  let value = num("value"), value.isFinite,
                  let i = trackIndex(tid),
                  let d = tracks[i].devices.firstIndex(where: { $0.id == deviceID })
            else { return false }
            tracks[i].devices[d].params[key] = value
            return true

        case "device.param.clear":
            guard let tid = (params["trackId"] as? String).flatMap(UUID.init(uuidString:)),
                  let deviceID = params["deviceId"] as? String,
                  let key = str("key"),
                  let i = trackIndex(tid),
                  let d = tracks[i].devices.firstIndex(where: { $0.id == deviceID }),
                  tracks[i].devices[d].params[key] != nil
            else { return false }
            tracks[i].devices[d].params.removeValue(forKey: key)
            return true

        case "midi.learn.start":
            mockMidiLearn = StudioMidiLearnState(active: true, device: params["device"] as? String, ageSeconds: 0, captured: nil, current: nil)
            mockLearnStartHostTime = hostNow()
            mockLearnCaptured = false
            return true

        case "midi.learn.stop":
            mockMidiLearn = StudioMidiLearnState(active: false, device: nil, ageSeconds: nil, captured: nil, current: nil)
            return true

        case "midi.binding.set":
            let bId = params["label"] as? String ?? UUID().uuidString
            let matchRaw = params["control"] as? [String: AnyHashable] ?? [:]
            let targetRaw = params["target"] as? [String: AnyHashable] ?? [:]
            let tk = StudioMidiTargetKind(rawValue: targetRaw["kind"] as? String ?? "") ?? .command
            let control = StudioMidiControl(
                type: matchRaw["type"] as? String ?? "noteOn",
                channel: (matchRaw["channel"] as? Int) ?? 0,
                number: matchRaw["number"] as? Int)
            let target = StudioMidiTarget(
                kind: tk, name: targetRaw["name"] as? String,
                params: targetRaw["params"] as? [String: AnyHashable],
                instruction: targetRaw["instruction"] as? String)
            let label = params["label"] as? String ?? ""
            if let existing = mockMidiBindings.firstIndex(where: { $0.match == control }) {
                mockMidiBindings[existing] = StudioMidiBinding(
                    id: mockMidiBindings[existing].id, label: label,
                    match: control, target: target,
                    targetSummary: targetSummary(target), enabled: params["enabled"] as? Bool ?? true)
            } else {
                mockMidiBindings.append(StudioMidiBinding(
                    id: bId, label: label, match: control, target: target,
                    targetSummary: targetSummary(target), enabled: params["enabled"] as? Bool ?? true))
            }
            return true

        case "midi.binding.clear":
            guard let ctrl = params["control"] as? [String: AnyHashable] else { return false }
            let control = StudioMidiControl(
                type: ctrl["type"] as? String ?? "",
                channel: (ctrl["channel"] as? Int) ?? 0,
                number: ctrl["number"] as? Int)
            mockMidiBindings.removeAll { $0.match == control }
            return true

        case "midi.device.select":
            // Ack the eighth verb (spec 7.5). Like import/export/reload this is
            // a preview stub: the real engine persists + re-resolves the port map.
            return true

        case "midi.map.import":
            return true

        case "midi.map.export":
            return true

        case "midi.reload":
            return true

        // THE CONTRACT'S KEYS, not the ones this file used to invent.
        //
        // `marker.set` read `name` + `bar`; the contract is `markerId` +
        // `positionTicks` + `label`. `section.set` read `name` + `startBar` +
        // `lengthBars` + `role`; the contract is `sectionId` + `name` +
        // `startTicks`, and the other two are not wire fields at all — a
        // section's LENGTH is the distance to the next one, and its ROLE is
        // read off its name. This file agreeing with the app's wrong spelling
        // is what kept the app's wrong spelling green.

        case "marker.set":
            // An UPSERT keyed on markerId, matching apply.rs: setting an id
            // that already exists edits it in place rather than stacking.
            guard let markerID = str("markerId"), let label = str("label"),
                  let ticks = int("positionTicks") else { return false }
            let markerBar = Int(Int64(ticks) / max(1, timeSignature.ticksPerBar))
            if let i = markers.firstIndex(where: { $0.id == markerID }) {
                markers[i] = StudioMarker(id: markerID, name: label, bar: markerBar)
            } else {
                markers.append(StudioMarker(id: markerID, name: label, bar: markerBar))
            }
            return true

        case "marker.remove":
            // Refuses an id it does not hold, like `CommandError::UnknownMarker`.
            // `removeAll` returning silently would report a removal that never
            // happened, which is the shape of bug this whole seam is about.
            guard let markerID = str("markerId"),
                  markers.contains(where: { $0.id == markerID }) else { return false }
            markers.removeAll(where: { $0.id == markerID })
            return true

        case "section.set":
            guard let sectionID = str("sectionId"), let name = str("name"),
                  let ticks = int("startTicks") else { return false }
            let startBar = Int(Int64(ticks) / max(1, timeSignature.ticksPerBar))
            if let i = sections.firstIndex(where: { $0.id == sectionID }) {
                sections[i] = StudioSectionSnapshot(
                    id: sectionID, name: name.uppercased(), startBar: startBar,
                    lengthBars: sections[i].lengthBars, role: Self.sectionRole(name))
            } else {
                sections.append(StudioSectionSnapshot(
                    id: sectionID, name: name.uppercased(), startBar: startBar,
                    lengthBars: 1, role: Self.sectionRole(name)))
            }
            resolveSectionLengths()
            return true

        case "section.remove":
            guard let sectionID = str("sectionId"),
                  sections.contains(where: { $0.id == sectionID }) else { return false }
            sections.removeAll(where: { $0.id == sectionID })
            resolveSectionLengths()
            return true

        case "track.rename":
            guard let trackID = str("trackId").flatMap(UUID.init(uuidString:)),
                  let name = str("name"), !name.isEmpty,
                  let i = trackIndex(trackID) else { return false }
            tracks[i].name = name
            return true

        case "track.reorder":
            guard let trackID = str("trackId").flatMap(UUID.init(uuidString:)),
                  let index = int("newIndex"), index >= 0, index < tracks.count,
                  let from = trackIndex(trackID) else { return false }
            let t = tracks.remove(at: from)
            tracks.insert(t, at: index)
            return true

        case "track.setColor":
            guard let trackID = str("trackId").flatMap(UUID.init(uuidString:)),
                  let color = str("color"), trackIndex(trackID) != nil else { return false }
            trackColors[trackID] = color
            return true

        case "track.setHeight":
            guard let trackID = str("trackId").flatMap(UUID.init(uuidString:)),
                  let height = num("heightPx") else { return false }
            trackHeights[trackID] = max(24, min(400, Int(height)))
            return true

        case "clip.rename":
            guard let clipID = str("clipId").flatMap(UUID.init(uuidString:)),
                  let name = str("name"), !name.isEmpty,
                  let loc = findClip(clipID) else { return false }
            tracks[loc.trackIndex].clips[loc.clipIndex].name = name
            return true

        case "clip.setGain":
            guard let clipID = str("clipId").flatMap(UUID.init(uuidString:)),
                  let gain = num("gainDb"),
                  let loc = findClip(clipID) else { return false }
            // -60…+12 is the contract's own range. Clamping to +24 here let the
            // mock store a gain the engine would never accept.
            tracks[loc.trackIndex].clips[loc.clipIndex].gainDB = max(-60, min(12, gain))
            return true

        case "clip.mute":
            guard let clipID = str("clipId").flatMap(UUID.init(uuidString:)),
                  let muted = bool("muted"),
                  let loc = findClip(clipID) else { return false }
            tracks[loc.trackIndex].clips[loc.clipIndex].muted = muted
            return true

        default:
            return applyRouting(name, params)
        }
    }

    // MARK: - Routing + effects (E5)
    //
    // The preview engine really applies the routing DAG and the insert chains,
    // and really reverses them, because a routing surface tested against an
    // engine that only says "ok" proves nothing about undo. The apply arms and
    // the inverses below mirror `timeline-core`'s `apply.rs` deliberately,
    // including the three that are easy to get subtly wrong:
    //
    //  - `fx.param.set` on an ABSENT key inverts to `fx.param.clear`, not to a
    //    written default. Params are sparse; undoing to a default would look
    //    identical and be a different fact.
    //  - `route.node.remove` inverts to a SEQUENCE: the node, its whole insert
    //    chain with every stored param and link, every incident edge, and every
    //    sidechain link that named it as a key source.
    //  - `fx.remove` restores the fx's CHAIN INDEX, not just the fx.
    //
    // No audio is produced anywhere in this PREVIEW engine (the real engine
    // renders the graph audibly since E5-graph); like the mixer's preview
    // meters, the node meters below are derived from state, not measured.

    /// Stable engine-side id for a track, by position. The mock only ever
    /// appends tracks, so position is stable, and a positional id keeps the
    /// journal readable (`track.t1`) instead of carrying a UUID into every
    /// NodeRef and ParamRef path.
    private func engineID(forTrackAt index: Int) -> String { "t\(index + 1)" }

    private func trackIndex(engineID: String) -> Int? {
        guard engineID.hasPrefix("t"), let n = Int(engineID.dropFirst()),
              n >= 1, n <= tracks.count else { return nil }
        return n - 1
    }

    func routingTrackID(_ id: UUID) async -> String? {
        guard let i = trackIndex(id) else { return nil }
        return engineID(forTrackAt: i)
    }

    func routingState() async -> StudioRoutingState? { routing }

    /// True when `ref` names something that exists right now.
    private func routingHostExists(_ ref: StudioNodeRef) -> Bool {
        switch ref {
        case .master: return true
        case .bus(let id): return routing.node(id) != nil
        case .track(let id): return trackIndex(engineID: id) != nil
        }
    }

    private func routingChain(_ ref: StudioNodeRef) -> [StudioFx]? {
        guard routingHostExists(ref) else { return nil }
        return routing.chain(for: ref)
    }

    private func setRoutingChain(_ ref: StudioNodeRef, _ chain: [StudioFx]) {
        switch ref {
        case .master:
            routing.masterFx = chain
        case .track(let id):
            if chain.isEmpty { routing.trackFx[id] = nil } else { routing.trackFx[id] = chain }
        case .bus(let id):
            guard let i = routing.nodes.firstIndex(where: { $0.id == id }) else { return }
            routing.nodes[i].fx = chain
        }
    }

    /// Would `from -> to` close a loop? Walks audio edges AND sidechain links,
    /// because a link is an ordering constraint over the same graph.
    private func routingWouldCycle(from: StudioNodeRef, to: StudioNodeRef) -> Bool {
        if from == to { return true }
        var adjacency: [StudioNodeRef: [StudioNodeRef]] = [:]
        for e in routing.edges { adjacency[e.from, default: []].append(e.to) }
        for (src, host) in routing.sidechainLinks { adjacency[src, default: []].append(host) }
        var stack: [StudioNodeRef] = [to]
        var seen: Set<StudioNodeRef> = [to]
        while let cur = stack.popLast() {
            for next in adjacency[cur] ?? [] {
                if next == from { return true }
                if seen.insert(next).inserted { stack.append(next) }
            }
        }
        return false
    }

    /// Drop every sidechain link naming `gone` as its key source, returning the
    /// commands that put them back.
    private func clearRoutingLinks(to gone: StudioNodeRef) -> [StudioEngineCommand] {
        var restore: [StudioEngineCommand] = []
        func sweep(_ host: StudioNodeRef, _ chain: inout [StudioFx]) {
            for i in chain.indices where chain[i].sidechain == gone {
                chain[i].sidechain = nil
                restore.append(
                    StudioRoutingCommand.sidechainSet(target: host, fxID: chain[i].id, source: gone)
                        .engineCommand)
            }
        }
        for key in routing.trackFx.keys.sorted() {
            var chain = routing.trackFx[key] ?? []
            sweep(.track(key), &chain)
            routing.trackFx[key] = chain.isEmpty ? nil : chain
        }
        for i in routing.nodes.indices {
            var chain = routing.nodes[i].fx
            sweep(.bus(routing.nodes[i].id), &chain)
            routing.nodes[i].fx = chain
        }
        sweep(.master, &routing.masterFx)
        return restore
    }

    /// The command sequence that rebuilds `chain` on `host` in order, with every
    /// stored parameter and sidechain link. Mirrors `apply.rs::fx_restore_sequence`.
    private func fxRestoreSequence(_ host: StudioNodeRef, _ chain: [StudioFx]) -> [StudioEngineCommand] {
        var out: [StudioEngineCommand] = []
        for f in chain {
            out.append(StudioRoutingCommand.fxAdd(target: host, fxID: f.id, kind: f.kind).engineCommand)
            for key in f.params.keys.sorted() {
                out.append(StudioRoutingCommand
                    .fxParamSet(target: host, fxID: f.id, key: key, value: f.params[key]!)
                    .engineCommand)
            }
            if let src = f.sidechain {
                out.append(StudioRoutingCommand
                    .sidechainSet(target: host, fxID: f.id, source: src).engineCommand)
            }
        }
        return out
    }

    private func applyRouting(_ name: String, _ params: [String: AnyHashable]) -> Bool {
        func str(_ k: String) -> String? { params[k] as? String }
        func num(_ k: String) -> Double? { (params[k] as? NSNumber)?.doubleValue }
        func int(_ k: String) -> Int? { (params[k] as? NSNumber)?.intValue }
        func ref(_ k: String) -> StudioNodeRef? { str(k).flatMap(StudioNodeRef.parse) }

        switch name {
        case "route.node.add":
            guard let id = str("nodeId"), StudioNodeRef.isValidID(id),
                  let kind = str("kind").flatMap(StudioRouteNodeKind.init(rawValue:)),
                  let display = str("name"), !display.isEmpty,
                  routing.node(id) == nil,
                  routing.nodes.count < StudioRoutingCaps.maxNodes else { return false }
            routing.nodes.append(StudioRouteNode(id: id, kind: kind, name: display))
            return true

        case "route.node.remove":
            guard let id = str("nodeId"),
                  let i = routing.nodes.firstIndex(where: { $0.id == id }) else { return false }
            let me = StudioNodeRef.bus(id)
            routing.nodes.remove(at: i)
            routing.edges.removeAll { $0.from == me || $0.to == me }
            _ = clearRoutingLinks(to: me)
            return true

        case "route.node.set":
            // The node fader (catalog v2 #113). Range mirrors the command's
            // own gainDb schema; outside it the real engine refuses.
            guard let id = str("nodeId"), let gain = num("gainDb"),
                  (StudioRoutingCaps.nodeGainMinDB...StudioRoutingCaps.nodeGainMaxDB).contains(gain),
                  let i = routing.nodes.firstIndex(where: { $0.id == id }) else { return false }
            routing.nodes[i].gainDB = gain
            return true

        case "route.connect":
            guard let id = str("edgeId"), StudioNodeRef.isValidID(id),
                  routing.edges.allSatisfy({ $0.id != id }),
                  let from = ref("from"), let to = ref("to"),
                  let level = num("level"), (0...4).contains(level),
                  let tap = str("tap").flatMap(StudioTap.init(rawValue:)),
                  !from.isMaster, from != to,
                  routingHostExists(from), routingHostExists(to),
                  routing.edges.count < StudioRoutingCaps.maxEdges,
                  !routingWouldCycle(from: from, to: to) else { return false }
            routing.edges.append(StudioRouteEdge(id: id, from: from, to: to, level: level, tap: tap))
            return true

        case "route.disconnect":
            guard let id = str("edgeId"),
                  let i = routing.edges.firstIndex(where: { $0.id == id }) else { return false }
            routing.edges.remove(at: i)
            return true

        case "route.edge.set":
            guard let id = str("edgeId"),
                  let i = routing.edges.firstIndex(where: { $0.id == id }),
                  let level = num("level"), (0...4).contains(level),
                  let tap = str("tap").flatMap(StudioTap.init(rawValue:)) else { return false }
            routing.edges[i].level = level
            routing.edges[i].tap = tap
            return true

        case "fx.add":
            guard let target = ref("target"), var chain = routingChain(target),
                  let fxID = str("fxId"), StudioNodeRef.isValidID(fxID),
                  !chain.contains(where: { $0.id == fxID }),
                  let kind = str("kind").flatMap(StudioFxKind.init(rawValue:)),
                  chain.count < StudioRoutingCaps.maxFxPerChain,
                  routing.totalFxCount < StudioRoutingCaps.maxFxTotal else { return false }
            chain.append(StudioFx(id: fxID, kind: kind))
            setRoutingChain(target, chain)
            return true

        case "fx.remove":
            guard let target = ref("target"), var chain = routingChain(target),
                  let fxID = str("fxId"),
                  let i = chain.firstIndex(where: { $0.id == fxID }) else { return false }
            chain.remove(at: i)
            setRoutingChain(target, chain)
            return true

        case "fx.move":
            guard let target = ref("target"), var chain = routingChain(target),
                  let fxID = str("fxId"), let index = int("index"),
                  let from = chain.firstIndex(where: { $0.id == fxID }),
                  index >= 0, index < chain.count else { return false }
            let fx = chain.remove(at: from)
            chain.insert(fx, at: index)
            setRoutingChain(target, chain)
            return true

        case "fx.param.set":
            guard let target = ref("target"), var chain = routingChain(target),
                  let fxID = str("fxId"), let key = str("key"), let value = num("value"),
                  let i = chain.firstIndex(where: { $0.id == fxID }) else { return false }
            // `bypass` is a wire key with no DSP parameter slot, so it is the one
            // key accepted without a spec. Every other key must belong to the
            // kind, exactly as `FX_PARAM_KEYS` + the kind's own table decide.
            guard key == studioFxBypassKey || chain[i].kind.spec(for: key) != nil else { return false }
            chain[i].params[key] = value
            setRoutingChain(target, chain)
            return true

        case "fx.param.clear":
            guard let target = ref("target"), var chain = routingChain(target),
                  let fxID = str("fxId"), let key = str("key"),
                  let i = chain.firstIndex(where: { $0.id == fxID }),
                  chain[i].params[key] != nil else { return false }
            chain[i].params[key] = nil
            setRoutingChain(target, chain)
            return true

        case "fx.sidechain.set":
            guard let target = ref("target"), var chain = routingChain(target),
                  let fxID = str("fxId"), let source = ref("source"),
                  let i = chain.firstIndex(where: { $0.id == fxID }),
                  !source.isMaster, source != target,
                  routingHostExists(source),
                  !routingWouldCycle(from: source, to: target) else { return false }
            chain[i].sidechain = source
            setRoutingChain(target, chain)
            return true

        case "fx.sidechain.clear":
            guard let target = ref("target"), var chain = routingChain(target),
                  let fxID = str("fxId"),
                  let i = chain.firstIndex(where: { $0.id == fxID }),
                  chain[i].sidechain != nil else { return false }
            chain[i].sidechain = nil
            setRoutingChain(target, chain)
            return true

        default:
            return false
        }
    }

    /// The reversing command(s), read from CURRENT state before the mutation.
    private func inverseRouting(_ name: String, _ params: [String: AnyHashable]) -> [StudioEngineCommand] {
        func str(_ k: String) -> String? { params[k] as? String }
        func ref(_ k: String) -> StudioNodeRef? { str(k).flatMap(StudioNodeRef.parse) }
        func cmd(_ c: StudioRoutingCommand) -> StudioEngineCommand { c.engineCommand }

        switch name {
        case "route.node.add":
            guard let id = str("nodeId") else { return [] }
            return [cmd(.nodeRemove(nodeID: id))]

        case "route.node.remove":
            guard let id = str("nodeId"), let node = routing.node(id) else { return [] }
            let me = StudioNodeRef.bus(id)
            var out: [StudioEngineCommand] = [
                cmd(.nodeAdd(nodeID: node.id, kind: node.kind, name: node.name))
            ]
            out.append(contentsOf: fxRestoreSequence(me, node.fx))
            for e in routing.edges where e.from == me || e.to == me {
                out.append(cmd(.connect(edgeID: e.id, from: e.from, to: e.to,
                                        level: e.level, tap: e.tap)))
            }
            // Links KEYED OFF this node dangle exactly as its edges would, so
            // they are cleared by the removal and restored by the undo.
            for (src, host) in routing.sidechainLinks where src == me {
                for f in routing.chain(for: host) where f.sidechain == me {
                    out.append(cmd(.sidechainSet(target: host, fxID: f.id, source: me)))
                }
            }
            return out

        case "route.node.set":
            // Self-inverse, exactly like the real command: carry the PRIOR gain.
            guard let id = str("nodeId"), let node = routing.node(id) else { return [] }
            return [cmd(.nodeSet(nodeID: id, gainDB: node.gainDB))]

        case "route.connect":
            guard let id = str("edgeId") else { return [] }
            return [cmd(.disconnect(edgeID: id))]

        case "route.disconnect":
            guard let id = str("edgeId"),
                  let e = routing.edges.first(where: { $0.id == id }) else { return [] }
            return [cmd(.connect(edgeID: e.id, from: e.from, to: e.to, level: e.level, tap: e.tap))]

        case "route.edge.set":
            guard let id = str("edgeId"),
                  let e = routing.edges.first(where: { $0.id == id }) else { return [] }
            return [cmd(.edgeSet(edgeID: e.id, level: e.level, tap: e.tap))]

        case "fx.add":
            guard let target = ref("target"), let fxID = str("fxId") else { return [] }
            return [cmd(.fxRemove(target: target, fxID: fxID))]

        case "fx.remove":
            guard let target = ref("target"), let fxID = str("fxId") else { return [] }
            let chain = routing.chain(for: target)
            guard let index = chain.firstIndex(where: { $0.id == fxID }) else { return [] }
            let fx = chain[index]
            var out: [StudioEngineCommand] = [cmd(.fxAdd(target: target, fxID: fx.id, kind: fx.kind))]
            // `fx.add` appends, so a non-terminal fx needs its index back.
            if index != chain.count - 1 {
                out.append(cmd(.fxMove(target: target, fxID: fx.id, index: index)))
            }
            for key in fx.params.keys.sorted() {
                out.append(cmd(.fxParamSet(target: target, fxID: fx.id, key: key, value: fx.params[key]!)))
            }
            if let src = fx.sidechain {
                out.append(cmd(.sidechainSet(target: target, fxID: fx.id, source: src)))
            }
            return out

        case "fx.move":
            guard let target = ref("target"), let fxID = str("fxId"),
                  let index = routing.chain(for: target).firstIndex(where: { $0.id == fxID })
            else { return [] }
            return [cmd(.fxMove(target: target, fxID: fxID, index: index))]

        case "fx.param.set":
            guard let target = ref("target"), let fxID = str("fxId"), let key = str("key"),
                  let fx = routing.fx(on: target, id: fxID) else { return [] }
            // The one that is easy to get wrong: undoing a FIRST-TIME set has to
            // return the key to ABSENT, because sparsity is the contract.
            if let prior = fx.params[key] {
                return [cmd(.fxParamSet(target: target, fxID: fxID, key: key, value: prior))]
            }
            return [cmd(.fxParamClear(target: target, fxID: fxID, key: key))]

        case "fx.param.clear":
            guard let target = ref("target"), let fxID = str("fxId"), let key = str("key"),
                  let prior = routing.fx(on: target, id: fxID)?.params[key] else { return [] }
            return [cmd(.fxParamSet(target: target, fxID: fxID, key: key, value: prior))]

        case "fx.sidechain.set":
            guard let target = ref("target"), let fxID = str("fxId"),
                  let fx = routing.fx(on: target, id: fxID) else { return [] }
            if let prior = fx.sidechain {
                return [cmd(.sidechainSet(target: target, fxID: fxID, source: prior))]
            }
            return [cmd(.sidechainClear(target: target, fxID: fxID))]

        case "fx.sidechain.clear":
            guard let target = ref("target"), let fxID = str("fxId"),
                  let prior = routing.fx(on: target, id: fxID)?.sidechain else { return [] }
            return [cmd(.sidechainSet(target: target, fxID: fxID, source: prior))]

        // The inverses ride the SAME envelopes the forwards do, so they are
        // held to the same contract — and they were breaking it too: an empty
        // `markerId` (`?? ""`) fails `minLength: 1`, and `height` / `gain` were
        // the mock's spellings rather than the catalog's. An undo that the
        // engine refuses is a Cmd-Z that silently does nothing.
        case "marker.set":
            guard let markerID = str("markerId") else { return [] }
            // Catalog default inverse is marker.remove, which is right for the
            // CREATE case; an upsert over an existing id inverts to itself with
            // the prior fields (apply.rs does the same).
            if let prior = markers.first(where: { $0.id == markerID }) {
                return [.catalog(name: "marker.set", params: [
                    "markerId": markerID,
                    "positionTicks": Int64(prior.bar) * timeSignature.ticksPerBar,
                    "label": prior.name,
                ])]
            }
            return [.catalog(name: "marker.remove", params: ["markerId": markerID])]

        case "section.set":
            guard let sectionID = str("sectionId") else { return [] }
            if let prior = sections.first(where: { $0.id == sectionID }) {
                return [.catalog(name: "section.set", params: [
                    "sectionId": sectionID,
                    "name": prior.name,
                    "startTicks": Int64(prior.startBar) * timeSignature.ticksPerBar,
                ])]
            }
            return [.catalog(name: "section.remove", params: ["sectionId": sectionID])]

        case "track.rename":
            guard let trackID = str("trackId").flatMap(UUID.init(uuidString:)),
                  let i = trackIndex(trackID) else { return [] }
            return [.catalog(name: "track.rename", params: ["trackId": trackID.uuidString, "name": tracks[i].name])]

        // `?? DEFAULT_TRACK_*` and not `?? ""` / `?? 80`: undoing the FIRST-EVER
        // colour has to put the track back to the engine's default colour, and
        // an empty string is not a colour the contract's pattern accepts. The
        // two constants mirror `timeline-core/src/model.rs`.
        case "track.setColor":
            guard let trackID = str("trackId").flatMap(UUID.init(uuidString:)) else { return [] }
            return [.catalog(name: "track.setColor", params: [
                "trackId": trackID.uuidString,
                "color": trackColors[trackID] ?? Self.defaultTrackColor,
            ])]

        case "track.setHeight":
            guard let trackID = str("trackId").flatMap(UUID.init(uuidString:)) else { return [] }
            return [.catalog(name: "track.setHeight", params: [
                "trackId": trackID.uuidString,
                "heightPx": trackHeights[trackID] ?? Self.defaultTrackHeightPx,
            ])]

        case "clip.rename":
            guard let clipID = str("clipId").flatMap(UUID.init(uuidString:)),
                  let loc = findClip(clipID) else { return [] }
            return [.catalog(name: "clip.rename", params: ["clipId": clipID.uuidString, "name": tracks[loc.trackIndex].clips[loc.clipIndex].name])]

        case "clip.setGain":
            guard let clipID = str("clipId").flatMap(UUID.init(uuidString:)),
                  let loc = findClip(clipID) else { return [] }
            return [.catalog(name: "clip.setGain", params: [
                "clipId": clipID.uuidString,
                "gainDb": max(-60, min(12, tracks[loc.trackIndex].clips[loc.clipIndex].gainDB)),
            ])]

        case "clip.mute":
            guard let clipID = str("clipId").flatMap(UUID.init(uuidString:)),
                  let loc = findClip(clipID) else { return [] }
            let wasMuted = tracks[loc.trackIndex].clips[loc.clipIndex].muted
            return [.catalog(name: "clip.mute", params: ["clipId": clipID.uuidString, "muted": wasMuted])]

        default:
            return []
        }
    }

    private func targetSummary(_ target: StudioMidiTarget) -> String {
        switch target.kind {
        case .builtin: return target.name ?? "builtin"
        case .command: return target.name ?? "command"
        case .sterling: return "Sterling: " + (target.instruction?.prefix(40) ?? "")
        }
    }

    // MARK: Mixer + automation helpers

    private func trackIndex(_ id: UUID) -> Int? {
        tracks.firstIndex(where: { $0.id == id })
    }

    private func clampGain(_ db: Double) -> Double { max(-60, min(12, db)) }

    /// Land the simulated capture as a clip on the recording track (mock only).
    /// The clip length is the elapsed capture time in ticks; the start snaps to
    /// the bar, mirroring the engine's landing.
    private func landMockRecording(continueCapture: Bool) -> Bool {
        guard recording, let tid = recordingTrackID,
              let i = tracks.firstIndex(where: { $0.id == tid }) else {
            recording = false; recordingTrackID = nil; return false
        }
        let elapsed = max(0.75, hostNow() - recordStartHostTime)
        let rawTicks = Int64(elapsed * tempoBPM / 60.0 * Double(StudioTick.ppq))
        let barTicks = timeSignature.ticksPerBar
        let start = recordRolling || barTicks == 0
            ? recordStartTicks
            : ((recordStartTicks + barTicks / 2) / barTicks) * barTicks
        // Punch: land exactly the region; else the elapsed capture length.
        let length: Int64 = {
            if let po = recordPunchOutTicks, po > start { return po - start }
            return max(barTicks, rawTicks)
        }()
        // Comp session: a repeated capture over the SAME region stacks as a
        // take-only pass in the take lane; the first places the comp clip.
        let key = CompKey(track: tid, start: recordStartTicks, punch: recordPunchOutTicks)
        if compSession == key, let laneID = compLaneID, var lane = tracks[i].takeLane, lane.id == laneID {
            // Continuation: stack a pass into the record lane this session created.
            let n = lane.takes.count + 1
            lane.takes = lane.takes.map { var t = $0; t.picked = false; return t }
            lane.takes.append(StudioTakeSnapshot(
                id: UUID(), name: "Pass \(n)",
                state: .rendered(seed: 0xC0FFEE00 &+ UInt64(n)), picked: true))
            tracks[i].takeLane = lane
        } else {
            // New comp session: place the comp clip and a FRESH record take lane.
            // Never adopt a lane this recording did not create (a generative lane
            // would otherwise get its takes de-picked and mis-counted).
            tracks[i].clips.append(StudioClipSnapshot(
                id: UUID(), name: "Recording", startTicks: start, lengthTicks: length,
                generative: false, waveformSeed: 0xC0FFEE00 &+ UInt64(tracks[i].clips.count)))
            let laneID = UUID()
            tracks[i].takeLane = StudioTakeLaneSnapshot(
                id: laneID, regionStartTicks: start, regionLengthTicks: length,
                takes: [StudioTakeSnapshot(id: UUID(), name: "Pass 1", state: .rendered(seed: 0xC0FFEE00), picked: true)])
            compLaneID = laneID
            compSession = key
            let end = start + length
            lengthBars = max(lengthBars, Int((end + barTicks - 1) / max(1, barTicks)))
        }
        if continueCapture {
            recording = true
            recordingTrackID = tid
            recordStartHostTime = hostNow()
        } else {
            recording = false
            recordingTrackID = nil
            recordPunchOutTicks = nil
        }
        return true
    }

    /// Simulated input meter while recording: a roaming "voice" level and a
    /// captured-frame count that grows with elapsed time.
    private func previewInputMeter(now: TimeInterval) -> StudioInputMeter {
        let elapsed = max(0, now - recordStartHostTime)
        let wob = 0.5 + 0.5 * sin(now * 5.7)            // 0...1
        let peakDB = -18.0 + 14.0 * wob                 // roams ~ -18..-4 dBFS
        let sampleRate = 48_000
        return StudioInputMeter(
            peakDB: max(-120, min(0, peakDB)),
            rmsDB: max(-120, min(0, peakDB - 6)),
            clipLatched: peakDB > -0.5,
            capturedFrames: Int64(elapsed * Double(sampleRate)),
            dropped: 0,
            sampleRate: sampleRate)
    }

    private func sorted(_ pts: [StudioAutoPoint]) -> [StudioAutoPoint] {
        pts.sorted { ($0.positionTicks, $0.id) < ($1.positionTicks, $1.id) }
    }

    /// Write a lane's points back and keep the `has*Automation` flags (engine
    /// truth: a lane is "present" when it carries at least one point) in sync.
    private func setLane(_ track: inout StudioTrackSnapshot, _ target: StudioAutoTarget, _ pts: [StudioAutoPoint]) {
        switch target {
        case .volume:
            track.volumeAutomation = pts
            track.hasVolumeAutomation = !pts.isEmpty
        case .pan:
            track.panAutomation = pts
            track.hasPanAutomation = !pts.isEmpty
        }
    }

    /// The reversing step(s) for an undoable command, read from CURRENT
    /// state before it mutates (mirrors the engine's self-inverse commands;
    /// the delete-class commands restore a value snapshot — see MockRestore).
    private func inverse(of command: StudioEngineCommand) -> [MockRestore] {
        switch command {
        case .trackMute(let t, _):
            guard let i = trackIndex(t) else { return [] }
            return [.command(.trackMute(trackID: t, muted: tracks[i].muted))]
        case .trackSolo(let t, _):
            guard let i = trackIndex(t) else { return [] }
            return [.command(.trackSolo(trackID: t, soloed: tracks[i].soloed))]
        case .mixGain(let t, _):
            guard let i = trackIndex(t) else { return [] }
            return [.command(.mixGain(trackID: t, gainDB: tracks[i].volumeDB))]
        case .mixPan(let t, _):
            guard let i = trackIndex(t) else { return [] }
            return [.command(.mixPan(trackID: t, pan: tracks[i].pan))]
        case .mixEq(let t, let band, _, _, _):
            guard let i = trackIndex(t), band >= 0, band < tracks[i].eq.count else { return [] }
            let b = tracks[i].eq[band]
            return [.command(.mixEq(trackID: t, band: band, freqHz: b.freqHz, gainDB: b.gainDB, q: b.q))]
        case .mixSend(let t, let bus, _):
            guard let i = trackIndex(t) else { return [] }
            let prior = bus == .a ? tracks[i].sendA : tracks[i].sendB
            return [.command(.mixSend(trackID: t, bus: bus, amount: prior))]
        case .mixMasterGain:
            return [.command(.mixMasterGain(gainDB: master.volumeDB))]
        case .mixLimiterSet:
            return [.command(.mixLimiterSet(
                enabled: master.limiterEnabled,
                ceilingDB: master.limiterCeilingDBTP,
                releaseMs: master.limiterReleaseMs))]
        case .autopointAdd(let t, let target, let pid, _, _):
            return [.command(.autopointRemove(trackID: t, target: target, pointID: pid))]
        case .autopointMove(let t, let target, let pid, _, _):
            guard let i = trackIndex(t),
                  let p = tracks[i].automation(target).first(where: { $0.id == pid }) else { return [] }
            return [.command(.autopointMove(trackID: t, target: target, pointID: pid,
                                            positionTicks: p.positionTicks, value: p.value))]
        case .autopointRemove(let t, let target, let pid):
            guard let i = trackIndex(t),
                  let p = tracks[i].automation(target).first(where: { $0.id == pid }) else { return [] }
            return [.command(.autopointAdd(trackID: t, target: target, pointID: pid,
                                           positionTicks: p.positionTicks, value: p.value))]
        case .autolaneClear(let t, let target):
            guard let i = trackIndex(t) else { return [] }
            return tracks[i].automation(target).map {
                .command(.autopointAdd(trackID: t, target: target, pointID: $0.id,
                                       positionTicks: $0.positionTicks, value: $0.value))
            }

        // The delete class (usability lane): value-snapshot restores, so the
        // preview undo genuinely brings back what was deleted — clips with
        // their seeds and fades, a track with its kind, name, mixer state and
        // instruments — the fidelity apply.rs's track_restore_sequence pins on
        // the real engine.
        case .clipRemove(let clipID):
            guard let loc = findClip(clipID) else { return [] }
            return [.clip(tracks[loc.trackIndex].clips[loc.clipIndex],
                          trackID: tracks[loc.trackIndex].id, at: loc.clipIndex)]
        case .trackRemove(let t):
            guard let i = trackIndex(t) else { return [] }
            return [.track(tracks[i], at: i)]
        case .trackAdd(let t, _, _):
            return [.command(.trackRemove(trackID: UUID(uuidString: t) ?? UUID()))]
        case .deviceRemove(let t, let deviceID):
            guard let i = trackIndex(t),
                  let d = tracks[i].devices.first(where: { $0.id == deviceID }) else { return [] }
            return [.device(d, trackID: t)]
        // The inverse of adding an instrument is removing exactly that one —
        // the same shape the catalog envelope below already had, now reachable
        // from the typed case the GUI sends.
        case .deviceAdd(let t, let deviceID, _):
            return [.command(.deviceRemove(trackID: t, deviceID: deviceID))]

        case .projectSetTempo(let bpm):
            return [.command(.projectSetTempo(bpm: tempoBPM))]

        case .projectSetTimeSig:
            return [.command(.projectSetTimeSig(
                numerator: timeSignature.beatsPerBar,
                denominator: timeSignature.beatUnit))]

        case .projectSetKey:
            return [.command(.projectSetKey(key: key))]

        case .catalog(let name, let params):
            // The catalog's own inverse for `import.audio` is `clip.remove`,
            // and it can name the exact clip because `importAudio` minted the
            // id before sending. Undoing a dragged-in sound takes that one clip
            // back off and touches nothing else.
            if name == "import.audio",
               let clipID = (params["clipId"] as? String).flatMap(UUID.init(uuidString:)) {
                return [.command(.clipRemove(clipID: clipID))]
            }
            if name == "device.add",
               let tid = (params["trackId"] as? String).flatMap(UUID.init(uuidString:)),
               let deviceID = params["deviceId"] as? String {
                return [.command(.deviceRemove(trackID: tid, deviceID: deviceID))]
            }
            // A zone add reverses to a zone remove; a zone REMOVE reverses to
            // an add carrying EVERY field, gain and pan included — the same
            // exactness `apply.rs` builds its inverse with, because a
            // replacement whose undo dropped the old pan would be a quiet lie.
            if name == "device.zone.add",
               let tid = params["trackId"] as? String,
               let deviceID = params["deviceId"] as? String,
               let zoneID = params["zoneId"] as? String {
                return [.command(.catalog(name: "device.zone.remove", params: [
                    "trackId": tid, "deviceId": deviceID, "zoneId": zoneID,
                ]))]
            }
            // The instrument's sound. Setting a key that was ABSENT inverts to
            // a CLEAR, not to a written default — the sparsity rule, mirrored
            // from `apply.rs`. Getting this wrong is how an undo would leave a
            // "default" behind that the DSP never actually had.
            if name == "device.param.set",
               let tidString = params["trackId"] as? String,
               let tid = UUID(uuidString: tidString),
               let deviceID = params["deviceId"] as? String,
               let key = params["key"] as? String,
               let i = trackIndex(tid),
               let d = tracks[i].devices.first(where: { $0.id == deviceID }) {
                if let prior = d.params[key] {
                    return [.command(.catalog(name: "device.param.set", params: [
                        "trackId": tidString, "deviceId": deviceID, "key": key, "value": prior,
                    ]))]
                }
                return [.command(.catalog(name: "device.param.clear", params: [
                    "trackId": tidString, "deviceId": deviceID, "key": key,
                ]))]
            }
            if name == "device.param.clear",
               let tidString = params["trackId"] as? String,
               let tid = UUID(uuidString: tidString),
               let deviceID = params["deviceId"] as? String,
               let key = params["key"] as? String,
               let i = trackIndex(tid),
               let d = tracks[i].devices.first(where: { $0.id == deviceID }),
               let prior = d.params[key] {
                return [.command(.catalog(name: "device.param.set", params: [
                    "trackId": tidString, "deviceId": deviceID, "key": key, "value": prior,
                ]))]
            }
            if name == "device.zone.remove",
               let tidString = params["trackId"] as? String,
               let tid = UUID(uuidString: tidString),
               let deviceID = params["deviceId"] as? String,
               let zoneID = params["zoneId"] as? String,
               let i = trackIndex(tid),
               let d = tracks[i].devices.first(where: { $0.id == deviceID }),
               let z = d.zones.first(where: { $0.id == zoneID }) {
                return [.command(.catalog(name: "device.zone.add", params: [
                    "trackId": tidString, "deviceId": deviceID, "zoneId": zoneID,
                    "sourceId": z.sourceID,
                    "rootPitch": NSNumber(value: z.rootPitch),
                    "loPitch": NSNumber(value: z.loPitch),
                    "hiPitch": NSNumber(value: z.hiPitch),
                    "gainDb": NSNumber(value: z.gainDB),
                    "pan": NSNumber(value: z.pan),
                ]))]
            }
            return inverseRouting(name, params).map(MockRestore.command)
        // Transport, the remaining clip edits, and the autolane.show view
        // toggle are not undoable in the preview engine (their undo is the
        // real engine's job).
        default:
            return []
        }
    }

    // MARK: Snapshot assembly

    private func currentSnapshot() -> StudioProjectSnapshot {
        let now = hostNow()
        // Preview meters: this engine is silent, so meter levels are DERIVED
        // from the mixer state (gain/mute/limiter), not measured audio. Moving a
        // fader visibly moves the meter (the round-trip made visible); the real
        // engine reports measured dBFS/LUFS from its live meter path.
        let meteredTracks = tracks.map { track -> StudioTrackSnapshot in
            var t = track
            t.meter = previewMeter(track, now: now)
            t.color = trackColors[track.id] ?? ""
            t.height = trackHeights[track.id] ?? 0
            return t
        }
        var meteredMaster = master
        meteredMaster.meter = previewMasterMeter(meteredTracks)
        if isPlaying {
            meteredMaster.lufsShortTerm = master.lufsIntegrated.map { $0 + 1.5 * sin(now * 1.1) }
            meteredMaster.correlation = 0.72 + 0.22 * sin(now * 0.7)
        } else {
            meteredMaster.lufsShortTerm = nil
            meteredMaster.correlation = nil
        }
        return StudioProjectSnapshot(
            revision: revision,
            name: name,
            tempoBPM: tempoBPM,
            timeSignature: timeSignature,
            key: key,
            lengthBars: lengthBars,
            sections: sections,
            tracks: meteredTracks,
            transport: StudioTransportSnapshot(
                isPlaying: isPlaying,
                positionTicks: currentPositionTicks(now: now),
                capturedAtHostTime: now,
                loopRegion: loopRegion,
                recording: recording,
                recordingTrackID: recordingTrackID,
                inputOpen: recording || inputListening,
                inputListening: inputListening,
                metronomeEnabled: metronomeEnabled
            ),
            stats: StudioEngineStats(
                callbackP95Millis: 0,
                underruns: 0,
                engineLabel: "mock"
            ),
            master: meteredMaster,
            provenanceSummary: provenanceSummary,
            inputDevices: mockInputDevices,
            inputMeter: (recording || inputListening) ? previewInputMeter(now: now) : nil,
            midi: buildMidiSnapshot(now: now),
            nodeMeters: previewNodeMeters(meteredTracks),
            markers: markers,
            loadedSources: loadedSources
        )
    }

    /// Preview bus/group meters, derived the way `previewMeter` derives a
    /// track's: this engine is silent, so a node's level is COMPUTED from what
    /// actually feeds it — each incoming edge's source preview level times the
    /// edge's level, buses feeding buses included — which keeps the routing
    /// pane's meters moving in the preview build for the same reason the mixer
    /// dock's do, and makes them RESPOND to the graph (disconnect an edge or
    /// pull its level down and the bus meter falls). The real engine reports
    /// measured dBFS from `MeterBank`'s node slots instead.
    private func previewNodeMeters(_ meteredTracks: [StudioTrackSnapshot]) -> [String: StudioChannelMeter] {
        guard isPlaying, !routing.nodes.isEmpty else { return [:] }
        var memo: [String: Double] = [:]
        var visiting: Set<String> = []   // apply() refuses cycles; belt for a corrupt graph
        func linear(_ ref: StudioNodeRef) -> Double {
            switch ref {
            case .master:
                return 0
            case .track(let id):
                guard let i = trackIndex(engineID: id), i < meteredTracks.count else { return 0 }
                let db = meteredTracks[i].meter.peakDB
                return db <= -120 ? 0 : pow(10, db / 20)
            case .bus(let id):
                if let m = memo[id] { return m }
                guard visiting.insert(id).inserted else { return 0 }
                defer { visiting.remove(id) }
                var sum = 0.0
                for e in routing.edges where e.to == .bus(id) {
                    sum += linear(e.from) * e.level
                }
                // The node FADER shapes the node's output — the real walk
                // meters POST-gain (`x *= g` before `accumulate_node_meter`),
                // so the preview does too: pull the fader down and the bus
                // meter follows, feeding downstream buses at the faded level.
                if let node = routing.node(id) {
                    sum *= pow(10, node.gainDB / 20)
                }
                memo[id] = sum
                return sum
            }
        }
        var out: [String: StudioChannelMeter] = [:]
        for n in routing.nodes {
            let lin = linear(.bus(n.id))
            let peakDB = lin > 0 ? min(0, 20 * log10(lin)) : -120
            out[n.id] = StudioChannelMeter(
                peakDB: max(-120, peakDB),
                rmsDB: peakDB <= -120 ? -120 : max(-120, peakDB - 5))
        }
        return out
    }

    // MARK: MIDI snapshot (spec 7.5)

    /// Test/preview seam ONLY (not a catalog command, not on StudioEngineProtocol):
    /// simulate a sterling-bound pad firing. Mirrors the real engine's
    /// `push_sterling`, which is a direct internal push, NOT a bus command: it
    /// appends to the ring and does NOT bump the snapshot revision (a Sterling
    /// press is journal-silent, spec 8.2). That revision-silence is precisely what
    /// makes the copilot drain's UNGATED read necessary, so a revision-gated read
    /// would miss it while the transport is idle. Going through send() instead
    /// would bump revision and mask that.
    func mockFireSterling(instruction: String, bindingId: String = "sterling-tighten", port: String? = nil) {
        mockMidiSterlingRing.append(StudioMidiSterlingItem(
            seq: mockMidiNextSeq,
            instruction: instruction,
            bindingId: bindingId,
            port: port ?? (mockMidiPorts.first ?? "")))
        mockMidiNextSeq += 1
        while mockMidiSterlingRing.count > 16 { mockMidiSterlingRing.removeFirst() }
    }

    /// Build the midi snapshot block. After ~1.2 s of learn a fake noteOn
    /// (ch0 #36) lands in `captured`.
    private func buildMidiSnapshot(now: TimeInterval) -> StudioMidiSnapshot {
        if mockMidiLearn.active, !mockLearnCaptured, (now - mockLearnStartHostTime) > 1.2 {
            mockMidiLearn = StudioMidiLearnState(
                active: true, device: mockMidiLearn.device, ageSeconds: now - mockLearnStartHostTime,
                captured: ["type": "noteOn", "channel": 0, "number": 36],
                current: nil)
            mockMidiLastEvent = StudioMidiLastEvent(
                seq: mockMidiNextSeq, port: mockMidiPorts.first ?? "",
                type: "noteOn", channel: 0, number: 36, value: 100)
            mockMidiNextSeq += 1
            mockLearnCaptured = true
        }
        return StudioMidiSnapshot(
            enabled: mockMidiEnabled,
            ports: mockMidiPorts.map { StudioMidiPort(name: $0, connected: true,
                map: "SX-KC211 (Analog Lab V)", mapKey: "sxkc211",
                source: "coremidi", tested: true, unsupportedReason: nil, override: nil) },
            maps: mockMidiMaps,
            activeBindings: mockMidiBindings,
            learn: mockMidiLearn,
            lastEvent: mockMidiLastEvent,
            sterling: StudioSterlingState(nextSeq: mockMidiNextSeq, pending: mockMidiSterlingRing))
    }

    /// Preview per-track meter: silent when stopped or muted, otherwise a
    /// deterministic level the fader shifts (so the round-trip is visible).
    private func previewMeter(_ track: StudioTrackSnapshot, now: TimeInterval) -> StudioChannelMeter {
        guard isPlaying, !track.muted else { return .silent }
        let seed = Double(abs(track.name.hashValue % 1000)) / 1000.0
        let wob = 0.5 + 0.5 * sin(now * 2.3 + seed * 6.2831853)     // 0...1
        let peakDB = min(0.0, -12.0 + 6.0 * wob + track.volumeDB)   // fader shifts it
        return StudioChannelMeter(peakDB: max(-120, peakDB), rmsDB: max(-120, peakDB - 5.0))
    }

    /// Preview master meter: the loudest unmuted track summed onto the bus,
    /// shifted by master gain; the limiter visibly holds the ceiling.
    private func previewMasterMeter(_ meteredTracks: [StudioTrackSnapshot]) -> StudioMasterMeter {
        guard isPlaying else { return .silent }
        let peaks = meteredTracks.filter { !$0.muted }.map { $0.meter.peakDB }
        guard let maxPeak = peaks.max() else { return .silent }
        let peakDB = min(0.0, maxPeak + 3.0 + master.volumeDB)      // bus sum + master fader
        var truePeakDB = peakDB
        var gr = 0.0
        if master.limiterEnabled, truePeakDB > master.limiterCeilingDBTP {
            gr = truePeakDB - master.limiterCeilingDBTP
            truePeakDB = master.limiterCeilingDBTP                  // limiter caps the ceiling
        }
        return StudioMasterMeter(
            peakDB: max(-120, peakDB),
            rmsDB: max(-120, peakDB - 5.0),
            truePeakDB: max(-120, truePeakDB),
            gainReductionDB: max(0, gr))
    }

    private var projectLengthTicks: Int64 {
        Int64(lengthBars) * timeSignature.ticksPerBar
    }

    private func hostNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func currentPositionTicks(now: TimeInterval) -> Int64 {
        guard isPlaying else { return anchorTicks }
        let ticksPerSecond = tempoBPM / 60.0 * Double(StudioTick.ppq)
        var pos = anchorTicks + Int64((now - anchorHostTime) * ticksPerSecond)
        if pos >= projectLengthTicks {
            // End of project: stop (mock has no loop-follow transport).
            pos = projectLengthTicks
            anchorTicks = pos
            isPlaying = false
            revision += 1
        }
        return pos
    }

    // MARK: Clip lookup helpers

    private func findClip(_ clipID: UUID) -> (trackIndex: Int, clipIndex: Int)? {
        for (ti, track) in tracks.enumerated() {
            if let ci = track.clips.firstIndex(where: { $0.id == clipID }) {
                return (ti, ci)
            }
        }
        return nil
    }

    private func removeClip(_ clipID: UUID) -> StudioClipSnapshot? {
        guard let location = findClip(clipID) else { return nil }
        return tracks[location.trackIndex].clips.remove(at: location.clipIndex)
    }

    private func mutateClip(
        _ clipID: UUID,
        _ body: (inout StudioClipSnapshot) -> Bool
    ) -> Bool {
        guard let location = findClip(clipID) else { return false }
        var clip = tracks[location.trackIndex].clips[location.clipIndex]
        guard body(&clip) else { return false }
        tracks[location.trackIndex].clips[location.clipIndex] = clip
        return true
    }

    // MARK: - Synthetic project fixture

    struct SyntheticProject: Sendable {
        var trackCount: Int
        var clipCount: Int
        /// The L5 performance-gate fixture: 8 tracks / 100 clips.
        static let standard = SyntheticProject(trackCount: 8, clipCount: 100)
        /// A brand-new "Studio" project: 0 tracks. Importing here must auto-create
        /// a track first (the "make the DAW usable" fix), not no-op.
        static let empty = SyntheticProject(trackCount: 0, clipCount: 0)
    }

    private struct BuiltProject {
        var name: String
        var tempoBPM: Double
        var timeSignature: StudioTimeSignature
        var key: String
        var lengthBars: Int
        var sections: [StudioSectionSnapshot]
        var tracks: [StudioTrackSnapshot]
        var provenanceSummary: String
        var takeRecords: [StudioTakeBrowserItem]
    }

    private static func buildProject(_ spec: SyntheticProject) -> BuiltProject {
        let sig = StudioTimeSignature.fourFour
        let tpb = sig.ticksPerBar
        var rng = SplitMix64(seed: 0x15_5EED)   // fixed: the fixture is deterministic

        // Song form: 92 bars.
        let form: [(String, Int, StudioSectionRole)] = [
            ("INTRO", 4, .neutral), ("VERSE 1", 12, .verse), ("CHORUS", 8, .chorus),
            ("VERSE 2", 12, .verse), ("CHORUS", 8, .chorus), ("BRIDGE", 8, .bridge),
            ("CHORUS", 8, .chorus), ("VERSE 3", 12, .verse), ("CHORUS", 8, .chorus),
            ("OUTRO", 12, .neutral),
        ]
        var sections: [StudioSectionSnapshot] = []
        var bar = 0
        // Engine-SHAPED ids (`sec_1`, `sec_2`, …) rather than minted UUIDs: a
        // section's identity is the string the engine holds, and the fixture
        // has to look like the thing it stands in for or the gesture that
        // addresses it is untestable here.
        for (index, (sectionName, length, role)) in form.enumerated() {
            sections.append(.init(
                id: "sec_\(index + 1)", name: sectionName,
                startBar: bar, lengthBars: length, role: role))
            bar += length
        }
        let lengthBars = bar   // 92

        // Track plan: name, stem kind, clip count, generative, take lane, automation.
        // Clip counts sum to exactly spec.clipCount (100 for the standard fixture).
        struct TrackPlan {
            var name: String
            var kind: StudioStemKind
            var clipCount: Int
            var generative: Bool
            var takes: Int
            var automation: Bool
        }
        var plans: [TrackPlan] = [
            .init(name: "Vocals", kind: .vocals, clipCount: 12, generative: true, takes: 0, automation: false),
            .init(name: "Backing Vox", kind: .vocals, clipCount: 12, generative: true, takes: 0, automation: false),
            .init(name: "Drums", kind: .drums, clipCount: 8, generative: true, takes: 3, automation: false),
            .init(name: "Percussion", kind: .drums, clipCount: 16, generative: true, takes: 0, automation: false),
            .init(name: "Bass", kind: .bass, clipCount: 12, generative: true, takes: 0, automation: false),
            .init(name: "Synths + Keys", kind: .other, clipCount: 14, generative: true, takes: 2, automation: false),
            .init(name: "Pads", kind: .other, clipCount: 10, generative: true, takes: 0, automation: false),
            .init(name: "VO (imported)", kind: .imported, clipCount: 16, generative: false, takes: 0, automation: true),
        ]
        plans = Array(plans.prefix(spec.trackCount))
        // Keep the fixture honest if a caller asks for other counts.
        let planned = plans.reduce(0) { $0 + $1.clipCount }
        if planned != spec.clipCount, var last = plans.last {
            last.clipCount = max(1, last.clipCount + (spec.clipCount - planned))
            plans[plans.count - 1] = last
        }

        var tracks: [StudioTrackSnapshot] = []
        for (trackIndex, plan) in plans.enumerated() {
            var clips: [StudioClipSnapshot] = []
            // Pack clips sequentially with small gaps, bar-aligned.
            let totalBars = Int64(lengthBars)
            var cursorBars: Int64 = Int64(truncatingIfNeeded: rng.next(upTo: 4))
            for clipIndex in 0..<plan.clipCount {
                let remainingClips = Int64(plan.clipCount - clipIndex)
                let barsLeft = max(1, totalBars - cursorBars)
                let maxLen = max(2, min(12, barsLeft - (remainingClips - 1) * 2))
                let lengthBarsClip = 2 + Int64(rng.next(upTo: UInt64(max(1, maxLen - 1))))
                let startBar = min(cursorBars, totalBars - 1)
                let clipName = plan.generative
                    ? plan.name.lowercased()
                    : "vo_read_final.wav"
                clips.append(StudioClipSnapshot(
                    id: UUID(),
                    name: clipName,
                    startTicks: startBar * tpb,
                    lengthTicks: max(1, min(lengthBarsClip, totalBars - startBar)) * tpb,
                    sourceOffsetTicks: 0,
                    fadeInTicks: StudioTick.ppq / 8,
                    fadeOutTicks: StudioTick.ppq / 8,
                    generative: plan.generative,
                    waveformSeed: rng.nextRaw() | 1
                ))
                let gap = Int64(rng.next(upTo: 3))
                cursorBars = startBar + lengthBarsClip + gap
                if cursorBars >= totalBars {
                    cursorBars = Int64(rng.next(upTo: 6))   // wrap: layered clips later in list
                }
            }
            clips.sort { $0.startTicks < $1.startTicks }

            var takeLane: StudioTakeLaneSnapshot?
            if plan.takes > 0 {
                // Mock revise region at bars 33-48 (matches the mockup).
                let takes = (0..<plan.takes).map { i in
                    StudioTakeSnapshot(
                        id: UUID(),
                        name: "Take \(i + 1)",
                        state: i == plan.takes - 1 && plan.takes >= 3
                            ? .rendering
                            : .rendered(seed: rng.nextRaw() | 1),
                        picked: i == 1
                    )
                }
                takeLane = StudioTakeLaneSnapshot(
                    id: UUID(),
                    regionStartTicks: 32 * tpb,
                    regionLengthTicks: 16 * tpb,
                    takes: takes
                )
            }

            // Seed a real editable volume-automation lane on the automation
            // track (a gentle level ride), so the lane shows with live points.
            var volAuto: [StudioAutoPoint] = []
            if plan.automation {
                volAuto = [
                    .init(id: "seed-v0", positionTicks: 0, value: -3),
                    .init(id: "seed-v1", positionTicks: 8 * tpb, value: -3),
                    .init(id: "seed-v2", positionTicks: 12 * tpb, value: 2),
                    .init(id: "seed-v3", positionTicks: 22 * tpb, value: 2),
                    .init(id: "seed-v4", positionTicks: 26 * tpb, value: -6),
                ]
            }
            tracks.append(StudioTrackSnapshot(
                id: UUID(),
                name: plan.name,
                kind: plan.kind,
                volumeDB: [-2.0, -4.5, -1.0, -6.0, -3.0, -4.0, -8.0, -5.0][trackIndex % 8],
                pan: 0,
                clips: clips,
                takeLane: takeLane,
                hasVolumeAutomation: !volAuto.isEmpty,
                volumeAutomation: volAuto
            ))
        }

        // Seed the Takes browser with real content: the landed-song provenance
        // anchor (kind landing -> filtered OUT of the auditionable list, the L8
        // decision) plus the revise candidates behind the fixture's take lanes.
        let regionStart = 32 * tpb
        let regionEnd = 48 * tpb
        var takeRecords: [StudioTakeBrowserItem] = []
        takeRecords.append(mockTake(
            id: "landed_neon_getaway", request: "req_landing", kind: .landing, stem: "mix",
            status: .candidate, prompt: "neon-soaked synthwave getaway, driving beat, 92 bpm",
            seed: 0x9E04, model: "acestep-v15", seq: takeRecords.count,
            region: nil, provenance: true, auditionable: false))
        for i in 0..<3 {
            takeRecords.append(mockTake(
                id: "seed_drums_v\(i)", request: "req_drums", kind: .revise, stem: "drums",
                status: .candidate, prompt: "strip to half-time, darker", seed: 0xD00D &+ UInt64(i),
                model: "acestep-v15-turbo", seq: takeRecords.count,
                region: (regionStart, regionEnd), provenance: false, auditionable: true))
        }
        for i in 0..<2 {
            takeRecords.append(mockTake(
                id: "seed_other_v\(i)", request: "req_other", kind: .revise, stem: "other",
                status: .candidate, prompt: "warmer analog pads", seed: 0x0DAD &+ UInt64(i),
                model: "acestep-v15-turbo", seq: takeRecords.count,
                region: (regionStart, regionEnd), provenance: false, auditionable: true))
        }

        return BuiltProject(
            name: "Neon Getaway",
            tempoBPM: 92.0,
            timeSignature: sig,
            key: "A min",
            lengthBars: lengthBars,
            sections: sections,
            tracks: tracks,
            provenanceSummary: "71% generated, 29% imported",
            takeRecords: takeRecords
        )
    }

    /// Build one mock take-browser record (the preview engine's stand-in for a
    /// project.takes entry + its joined lineage).
    private static func mockTake(
        id: String, request: String, kind: StudioTakeKind, stem: String,
        status: StudioTakeStatusKind, prompt: String, seed: UInt64, model: String, seq: Int,
        region: (Int64, Int64)?, provenance: Bool, auditionable: Bool
    ) -> StudioTakeBrowserItem {
        StudioTakeBrowserItem(
            takeID: id, requestID: request, kind: kind, stemName: stem, status: status,
            promotedInto: nil, assetHash: "mock_\(id)", auditionable: auditionable,
            provenance: provenance, offline: false, createdTs: nil, createdSeq: seq,
            lineage: StudioTakeLineage(
                prompt: prompt, seed: seed, model: model, steps: kind == .landing ? 60 : 8,
                device: "cpu", regionStartTicks: region?.0, regionEndTicks: region?.1))
    }

    // MARK: - MIDI seeded fixtures (spec table 5.5)

    /// Per spec §5.3, the sx-kc211-like port gets 4 maps and 8 bindings.
    private static func seededMaps() -> [StudioMidiMap] {
        [
            StudioMidiMap(key: "generic", name: "Generic MIDI Controller", source: "builtin", tested: true, bindingCount: 40, loadError: nil),
            StudioMidiMap(key: "sxkc211", name: "SX-KC211 (Analog Lab V)", source: "builtin", tested: true, bindingCount: 8, loadError: nil),
            StudioMidiMap(key: "launchkey", name: "Launchkey 49 (DAW)", source: "user", tested: false, bindingCount: 0, loadError: nil),
            StudioMidiMap(key: "nanokontrol", name: "KORG nanoKONTROL2", source: "user", tested: false, bindingCount: 0, loadError: nil),
        ]
    }

    /// Seeded from spec table 5.5: 8 bindings on the sx-kc211 map.
    ///
    /// `controlChange`, not the `cc` shorthand this fixture used to carry. The
    /// engine emits the catalog's own enum
    /// (`noteOn`/`noteOff`/`controlChange`/`pitchBend`), and
    /// `MidiSettingsView.controlParams` feeds a binding's `match.type` straight
    /// back into `midi.binding.set` — so a fixture speaking a dialect the
    /// contract does not have made the settings pane's own round trip
    /// untestable here, and green.
    private static func seededBindings() -> [StudioMidiBinding] {
        [
            StudioMidiBinding(id: "b1", label: "Play / Stop",
                match: StudioMidiControl(type: "controlChange", channel: 0, number: 20),
                target: StudioMidiTarget(kind: .builtin, name: "transport.togglePlay", params: nil, instruction: nil),
                targetSummary: "transport.togglePlay", enabled: true),
            StudioMidiBinding(id: "b2", label: "Tap Tempo",
                match: StudioMidiControl(type: "controlChange", channel: 0, number: 21),
                target: StudioMidiTarget(kind: .builtin, name: "transport.tapTempo", params: nil, instruction: nil),
                targetSummary: "transport.tapTempo", enabled: true),
            StudioMidiBinding(id: "b3", label: "Quantize Strength",
                match: StudioMidiControl(type: "controlChange", channel: 0, number: 22),
                target: StudioMidiTarget(kind: .command, name: "tools.quantize", params: ["strength": 1], instruction: nil),
                targetSummary: "tools.quantize", enabled: true),
            StudioMidiBinding(id: "b4", label: "Undo",
                match: StudioMidiControl(type: "controlChange", channel: 0, number: 23),
                target: StudioMidiTarget(kind: .builtin, name: "undo", params: nil, instruction: nil),
                targetSummary: "undo", enabled: true),
            StudioMidiBinding(id: "b5", label: "Redo",
                match: StudioMidiControl(type: "controlChange", channel: 0, number: 24),
                target: StudioMidiTarget(kind: .builtin, name: "redo", params: nil, instruction: nil),
                targetSummary: "redo", enabled: true),
            StudioMidiBinding(id: "b6", label: "Kick Mute",
                match: StudioMidiControl(type: "noteOn", channel: 0, number: 36),
                target: StudioMidiTarget(kind: .command, name: "track.mute", params: ["trackName": "Kick"], instruction: nil),
                targetSummary: "track.mute Kick", enabled: true),
            StudioMidiBinding(id: "b7", label: "Snare Mute",
                match: StudioMidiControl(type: "noteOn", channel: 0, number: 37),
                target: StudioMidiTarget(kind: .command, name: "track.mute", params: ["trackName": "Snare"], instruction: nil),
                targetSummary: "track.mute Snare", enabled: true),
            StudioMidiBinding(id: "b8", label: "Hi-Hat Mute",
                match: StudioMidiControl(type: "noteOn", channel: 0, number: 38),
                target: StudioMidiTarget(kind: .command, name: "track.mute", params: ["trackName": "Hi-Hat"], instruction: nil),
                targetSummary: "track.mute Hi-Hat", enabled: true),
            // A Sterling trigger (spec 8): the pad fires an agent instruction, not
            // a command. Seeded so the editable instruction cell is visible in the
            // preview build; the real engine seeds its own sterling bindings.
            StudioMidiBinding(id: "sterling-tighten", label: "Tighten Groove",
                match: StudioMidiControl(type: "noteOn", channel: 0, number: 60),
                target: StudioMidiTarget(kind: .sterling, name: nil, params: nil,
                    instruction: "Tighten the groove on the drums in the selected region."),
                targetSummary: "Sterling: Tighten the groove", enabled: true),
        ]
    }

    // MARK: - Deterministic waveform tiles

    /// Pure function of the tile key: peak per bin from a seeded musical
    /// envelope plus per-bin noise. Continuous across tiles and buckets
    /// because everything derives from absolute source ticks.
    static func generateTile(_ key: StudioTileKey) -> StudioWaveformTile {
        let ticksPerBin = StudioTileScheme.ticksPerBin(bucket: key.bucket)
        let binCount = StudioTileScheme.binsPerTile
        let tileStartTick = Int64(key.tileIndex) * StudioTileScheme.ticksPerTile(bucket: key.bucket)

        var seeded = SplitMix64(seed: key.seed)
        let rate = 1.7 + Double(seeded.nextRaw() % 1000) / 1000.0 * 0.6
        let phase = Double(seeded.nextRaw() % 6283) / 1000.0
        let beatTicks = Double(StudioTick.ppq)

        var peaks = [Float](repeating: 0, count: binCount)
        for bin in 0..<binCount {
            let tick = Double(tileStartTick + Int64(bin) * ticksPerBin)
            let beats = tick / beatTicks
            let envelope = 0.35 + 0.65 * abs(sin(beats / 4.0 * .pi * rate + phase))
            var noise = SplitMix64(seed: key.seed &+ UInt64(bitPattern: tileStartTick &+ Int64(bin) &* ticksPerBin))
            let jitter = 0.28 + 0.62 * Double(noise.nextRaw() % 1000) / 1000.0
            peaks[bin] = Float(min(1.0, envelope * jitter))
        }
        return StudioWaveformTile(key: key, peaks: peaks, ticksPerBin: ticksPerBin)
    }
}

// MARK: - SplitMix64 (deterministic, dependency-free)

struct SplitMix64: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in 0..<bound (bound 0 returns 0).
    mutating func next(upTo bound: UInt64) -> UInt64 {
        guard bound > 0 else { return 0 }
        return nextRaw() % bound
    }
}
