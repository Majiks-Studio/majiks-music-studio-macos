import Foundation

// RealStudioEngine - the FFI-backed engine that conforms to L5's
// `StudioEngineProtocol`, so the Studio tab can switch from StudioMockEngine to
// the real timeline-core engine at integration checkpoint I1 by changing one
// initializer. It is NOT the default yet (the brief: make the adapter exist and
// compile; I1 flips the tab).
//
// The engine speaks string ids (t1, c1) and snake_case serde JSON; the UI
// speaks UUIDs and StudioProjectSnapshot. This actor is the translator: a
// stable string<->UUID map both ways, plus a seed->clip map so the peak-tile
// path can serve real audio peaks.
//
// Fidelity notes for I1 (honest, not silent):
//  - stem kind is inferred from the track name (the engine has no stem-kind
//    field yet). Provenance IS surfaced now: the snapshot carries the same
//    per-clip `origin` the exported manifest is built from, so `generative` and
//    the export dialog's split are the engine's answer rather than a guess.
//    (Until fix/provenance-clip-origin this read `generative: false` for every
//    clip, so a fully AI-generated project previewed as 100% imported.)
//  - clipTrim maps a single dragged edge to one catalog clip.trim; a two-edge
//    drag needs the ViewModel to send two trims.

actor RealStudioEngine: StudioEngineProtocol {
    private let client: EngineClient

    private var trackUUID: [String: UUID] = [:]
    private var uuidTrack: [UUID: String] = [:]
    private var clipUUID: [String: UUID] = [:]
    private var uuidClip: [UUID: String] = [:]
    private var seedToClip: [UInt64: String] = [:]
    /// Where each seed's clip starts INSIDE its source, in ticks. The engine's
    /// waveform bins are counted from the clip's `offset_frames`, not from
    /// source tick 0, so a trimmed clip needs this to line its tiles up.
    private var seedSourceOffsetTicks: [UInt64: Int64] = [:]
    /// Samples per tick for the current project, learned from every snapshot.
    /// The waveform seam converts the UI's TICK tile lattice into the engine's
    /// SAMPLE one with it; see `StudioEngineTileFetch`. Seeded to the engine
    /// default (48 kHz, 120 BPM, 960 PPQ = 25) so it is never zero.
    private var samplesPerTick: Double = 25
    /// Last seen clip geometry (string id -> (startTicks, lengthTicks)), for
    /// translating absolute-edge trims/duplicates into catalog deltas.
    private var clipGeometry: [String: (start: Int64, length: Int64)] = [:]
    /// Whether a live audio session is open. Live is opened lazily on the first
    /// play (a user action), so a launched-but-idle app never grabs the device.
    private var liveStarted = false

    /// Last transport play-state / position we reported to the UI. Transport
    /// verbs (play/stop/seek) are UNJOURNALED — they do NOT bump the journal
    /// `seq` — so a purely seq-gated early-out swallows the play->stop
    /// transition: the UI would never adopt the `playing=false` snapshot and
    /// would keep wall-clock-extrapolating the play head from the last
    /// `playing=true` snapshot ("Stop does nothing; the play head keeps
    /// advancing"). We remember what we last reported so the poll can force a
    /// fresh snapshot the instant the transport state changes, even without a
    /// seq bump. Seeded to the idle default (stopped, at 0).
    private var lastReportedPlaying = false
    private var lastReportedPositionTicks: Int64 = 0
    /// Last metronome flag delivered to the UI. See the delivery gate in
    /// `snapshot(ifNewerThan:)`.
    private var lastReportedMetronome = false

    /// The SAME memory, for the other unjournaled thing a person does: PLAYING.
    ///
    /// Auditioning a note is journal-silent by design (noodling must not fill the
    /// undo stack) and it deliberately does not roll the transport
    /// (`play_a_note.rs::playing_never_starts_the_transport`). Both of those are
    /// correct, and together they made the gate above swallow every performance
    /// update while the transport was stopped — which is exactly how a person
    /// plays a keyboard. `snapshot.performance.sounding` was therefore populated
    /// by the engine, proven by engine tests, and NEVER SEEN by the app: the
    /// on-screen keyboard could not light from a hardware key, and Keep's live
    /// count could not count up, unless the user happened to be playing back.
    ///
    /// Every Swift test that "proved" the performance block called
    /// `snapshot(ifNewerThan: nil)` — the ungated call the app does not use — so
    /// the whole class was invisible to the suite. Remembering the last reported
    /// performance closes the same hole the transport pair closes, at the cost of
    /// one cheap read of the raw JSON that was already fetched.
    private var lastReportedPerformance: PerformanceGateKey?

    /// The bit of the `performance` block a poll must not miss, read straight off
    /// the raw snapshot JSON so the gate can be decided BEFORE the expensive
    /// `buildSnapshot`. Anything that changes here is something a human just did
    /// with their hands.
    private struct PerformanceGateKey: Equatable {
        var sounding: [Int64]
        var keepableNotes: Int64
        var endTicks: Int64?

        init?(_ root: EngineJSON) {
            guard let perf = root["performance"] as? [String: Any] else { return nil }
            let pj = EngineJSON(perf)
            sounding = (perf["sounding"] as? [Any])?
                .compactMap { ($0 as? NSNumber)?.int64Value } ?? []
            keepableNotes = pj.int64("keepableNotes") ?? 0
            endTicks = pj.int64("endTicks")
        }
    }

    /// The same transport-transition memory, kept SEPARATELY for the note seam
    /// (`RealStudioNoteEngine.swift`). The piano roll polls on its own cadence
    /// and only while its pane is open, so sharing one pair of fields would let
    /// whichever surface polled first swallow the other's stop transition — the
    /// exact "Stop does nothing, the play head keeps advancing" bug, one layer
    /// over.
    var lastNotePlaying = false
    var lastNotePositionTicks: Int64 = 0

    /// - Parameter audible: when true (the shipping GUI app, set by
    ///   `StudioEngineFactory`), the live output device is AUDIBLE by default so
    ///   a user pressing Play is heard — no env var required. Defaults to false,
    ///   so any headless/test construction keeps the device silent.
    /// What opening this package had to do to rebuild it. Read ONCE, here,
    /// because it describes an event at open time rather than live state — and
    /// read here rather than lazily so the answer cannot change under a caller
    /// that asks late. `nil` only if the engine could not answer at all, which
    /// the reporter treats as "say nothing" rather than as a problem.
    nonisolated let openRecovery: StudioProjectRecoveryFacts?

    init(dataDir: String, audible: Bool = false) throws {
        let client = try EngineClient(dataDir: dataDir)
        self.client = client
        self.openRecovery = (try? client.openRecovery()).map(StudioProjectRecoveryFacts.init(engineJSON:))
        // Opt into audible output BEFORE the first play opens the live stream.
        // This is the GUI's explicit "the app is heard" decision; leaving it off
        // (CLI/tests/CI) preserves the silence safety.
        if audible {
            try? client.setAudibleOutput(true)
        }
    }

    /// The in-process MCP server (Settings toggle / launch args wire this).
    /// Returns the engine's REDACTED connection snippet — the clear token stays
    /// with the host (StudioMCPServerModel), which is the only thing that knows
    /// whether the human asked to see it.
    @discardableResult
    func startMCP(port: UInt16, pat: String, enabled: Bool) throws -> String {
        try client.mcpStart(port: port, pat: pat, enabled: enabled)
    }

    /// Stop the in-process MCP server, if one is running. No-op otherwise.
    func stopMCP() {
        client.mcpStop()
    }

    /// Whether the in-process MCP server is currently up. Used to make start
    /// idempotent (a second bind would fail with "address already in use").
    func isMCPRunning() -> Bool {
        client.mcpRunning()
    }

    /// The engine client for Sterling's backend. Nonisolated: EngineClient is
    /// Sendable and the underlying MajiksEngine is internally thread-safe
    /// (Arc<Mutex<StudioHost>>), so the copilot drives the SAME host instance the
    /// UI does without hopping the actor on every 8 Hz poll.
    nonisolated var copilotClient: EngineClient { client }

    /// Open the live audio session if it is not already running. Called on the
    /// first transport play so the real engine drives playback. The cpal stream
    /// is audible when this engine was constructed audible (the GUI app default);
    /// headless/test constructions leave it silence-gated.
    func ensureLive() {
        guard !liveStarted else { return }
        do {
            try client.startLive()
            liveStarted = true
        } catch {
            // A missing device (or a headless run) leaves us on the tracked
            // transport view; the tab still works, just without a live clock.
            NSLog("RealStudioEngine: startLive failed (\(error))")
        }
    }

    /// Close the live audio session (releases the device).
    func stopLive() {
        liveStarted = false
        _ = try? client.stopLive()
    }

    // MARK: StudioEngineProtocol

    func snapshot(ifNewerThan clientRevision: UInt64?) async -> StudioProjectSnapshot? {
        guard let json = try? client.snapshot(sinceSeq: nil) else { return nil }
        let seq = UInt64(json.int64("seq") ?? 0)
        let transport = json.dict("transport") ?? [:]
        let playing = (transport["playing"] as? Bool) ?? false
        let positionTicks = EngineJSON(transport).int64("positionTicks") ?? 0
        // Force delivery on a transport transition the seq gate cannot see:
        // stop/pause flips `playing` true->false and a stop->seek(0) reset moves
        // `positionTicks`, but neither bumps the journal `seq`. Without this the
        // early-out below would return nil the instant playback stops and the UI
        // would keep extrapolating the play head forever. While playing we always
        // fall through (the `!playing` guard fails), so this only re-arms delivery
        // for the stopped/paused edge and then goes quiet again once reported.
        // `transport.metronome` is a NON-JOURNALED command, so toggling the
        // click while the transport is stopped moves neither `seq` nor
        // `playing` nor `positionTicks` — the early-out below would return nil
        // and the button would sit at its old state until something else
        // happened. Include it in the gate for exactly that reason.
        let metronome = (transport["metronomeEnabled"] as? Bool) ?? false
        let transportChanged =
            playing != lastReportedPlaying || positionTicks != lastReportedPositionTicks
            || metronome != lastReportedMetronome
        // Force delivery on a PERFORMANCE change the seq gate cannot see either
        // — a key going down or coming up on a stopped transport. See
        // `lastReportedPerformance`. Read off the raw JSON we already have, so
        // an idle poll still costs one dictionary lookup and no snapshot build.
        let performance = PerformanceGateKey(json)
        let performanceChanged = performance != lastReportedPerformance
        if let rev = clientRevision, rev >= seq, !playing, !transportChanged, !performanceChanged {
            return nil
        }
        lastReportedPlaying = playing
        lastReportedPositionTicks = positionTicks
        lastReportedMetronome = metronome
        lastReportedPerformance = performance
        // Meters are a separate read surface (measured dBFS/LUFS live, silence
        // floor offline). Merge them into the snapshot the dock reads.
        let meters = try? client.meters()
        return buildSnapshot(json, meters: meters, seq: seq)
    }

    @discardableResult
    func send(_ command: StudioEngineCommand) async -> StudioCommandResult {
        do {
            try route(command)
            return StudioCommandResult(ok: true, message: nil)
        } catch let e as FfiError {
            return StudioCommandResult(ok: false, message: "\(command.catalogName): \(ffiMessage(e))")
        } catch {
            return StudioCommandResult(ok: false, message: "\(command.catalogName): \(error)")
        }
    }

    func importAudio(path: String, trackID: UUID?, startTicks: Int64) async -> StudioCommandResult {
        guard let trackID, let track = uuidTrack[trackID] else {
            return StudioCommandResult(ok: false, message: "No target track is selected.")
        }
        do {
            _ = try client.submit(name: "import.audio", params: [
                "sourcePath": path, "targetTrackId": track, "startTicks": max(0, startTicks)
            ])
            return StudioCommandResult(ok: true, message: nil)
        } catch let e as FfiError {
            return StudioCommandResult(ok: false, message: ffiMessage(e))
        } catch {
            return StudioCommandResult(ok: false, message: error.localizedDescription)
        }
    }

    /// Load sounds into a sampler / drum rack. One FFI call, one txn, one Cmd-Z.
    ///
    /// The whole reason this is not assembled from `send(.catalog(...))` calls
    /// here: the `sourceId` a zone needs does not exist until a file has been
    /// decoded and content-hashed, only the host can do that, and the host's
    /// own import already opens a transaction — which cannot be nested. So the
    /// bracket lives on the host side, over the SAME journaled commands the UI
    /// would otherwise have sent.
    func bindSamples(_ request: StudioSampleBindRequest) async -> StudioSampleBindOutcome {
        guard let track = uuidTrack[request.trackID] else {
            return .failed("That track is no longer in the project.")
        }
        var args: [String: Any] = [
            "trackId": track,
            "reason": request.reason,
            "bindings": request.bindings.map { b -> [String: Any] in
                var d: [String: Any] = [
                    "sourcePath": b.sourcePath,
                    "rootPitch": b.rootPitch,
                    "loPitch": b.loPitch,
                    "hiPitch": b.hiPitch,
                ]
                if let g = b.gainDB { d["gainDb"] = g }
                if let p = b.pan { d["pan"] = p }
                return d
            },
        ]
        if let deviceID = request.deviceID, !deviceID.isEmpty { args["deviceId"] = deviceID }
        if let kind = request.kind, !kind.isEmpty { args["kind"] = kind }
        if !request.removeZoneIDs.isEmpty { args["removeZoneIds"] = request.removeZoneIDs }
        do {
            let parsed = try client.bindSamples(args: args)
            return StudioSampleBindOutcome(
                ok: true,
                message: nil,
                deviceID: parsed.string("deviceId"),
                kind: parsed.string("kind"),
                createdDevice: parsed.bool("createdDevice") ?? false,
                zoneIDs: parsed.array("zones").compactMap { EngineJSON($0).string("zoneId") })
        } catch let e as FfiError {
            // The engine's own refusal text, verbatim: it names the remedy
            // ("remove the instrument instead", "wider than the 16-pad rack"),
            // and a paraphrase here would drift from what the engine enforces.
            return .failed(ffiMessage(e))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func undo() async -> Bool { (try? client.undo()) ?? false }

    @discardableResult
    func redo() async -> Bool { (try? client.redo()) ?? false }

    /// Peak tiles for the UI's tick lattice, read out of the engine's sample
    /// lattice.
    ///
    /// This used to be `zoom: key.bucket, startBin: tileIndex * 256` — the tile
    /// bucket handed straight to an argument that means something else.
    /// `StudioTileScheme`'s bucket is TICKS per bin; `StudioHost::waveform`'s
    /// zoom is SAMPLES per bin. See `StudioEngineTileFetch` for what that cost:
    /// the arrangement drew the first ~9% of every clip stretched across all of
    /// it, so a three-and-a-half-minute song showed its intro for the whole row.
    func waveformTile(_ key: StudioTileKey) async -> StudioWaveformTile? {
        guard let clipId = seedToClip[key.seed] else { return nil }
        let bins = StudioTileScheme.binsPerTile
        let ticksPerBin = StudioTileScheme.ticksPerBin(bucket: key.bucket)
        let samplesPerUIBin = Double(ticksPerBin) * samplesPerTick
        let plan = StudioEngineTileFetch.plan(
            tileIndex: key.tileIndex,
            binsPerTile: bins,
            samplesPerUIBin: samplesPerUIBin,
            sourceOffsetSamples: Double(seedSourceOffsetTicks[key.seed] ?? 0) * samplesPerTick)

        var enginePeaks: [Float] = []
        // A tile entirely before the clip's source origin has nothing to ask
        // for; it draws as the quiet midline it already is.
        if plan.firstSample + Double(bins) * samplesPerUIBin > 0 {
            guard let json = try? client.tiles(
                clipId: clipId,
                zoom: UInt32(plan.zoom),
                startBin: UInt64(plan.startBin),
                maxBins: UInt32(plan.maxBins)
            ) else { return nil }
            let raw = (json["peaks"] as? [Any]) ?? []
            enginePeaks = raw.compactMap { ($0 as? NSNumber)?.floatValue }
        }
        return StudioWaveformTile(
            key: key,
            peaks: StudioEngineTileFetch.resample(
                enginePeaks: enginePeaks,
                plan: plan,
                binsPerTile: bins,
                samplesPerUIBin: samplesPerUIBin),
            ticksPerBin: ticksPerBin
        )
    }

    // MARK: Open in Studio (L8 landing bridge)

    func openInStudio(_ request: StudioLandingRequest) async -> StudioCommandResult {
        var args: [String: Any] = [
            "sourceAudioRef": request.sourceAudioPath,
            "prompt": request.prompt,
            "source": "generated",
            "separator": "htdemucs",
        ]
        if let bpm = request.declaredBPM { args["declaredBpm"] = bpm }
        if let key = request.key, !key.isEmpty { args["key"] = key }
        if !request.sectionTags.isEmpty { args["sectionTags"] = request.sectionTags }
        if let seed = request.seed { args["seed"] = seed }
        if let model = request.genModel { args["genModel"] = model }
        if let name = request.projectName { args["projectName"] = name }
        if let src = Self.resolvePythonSrc() { args["pythonSrc"] = src }

        do {
            _ = try client.tool(name: "studio_open_in_studio", args: args)
            // The engine swapped to the freshly built project; drop the stale
            // id maps so the next snapshot re-mints UUIDs for the new session.
            trackUUID.removeAll(); uuidTrack.removeAll()
            clipUUID.removeAll(); uuidClip.removeAll()
            seedToClip.removeAll(); clipGeometry.removeAll()
            seedSourceOffsetTicks.removeAll()
            return StudioCommandResult(ok: true, message: nil)
        } catch let e as FfiError {
            return StudioCommandResult(ok: false, message: "Open in Studio: \(ffiMessage(e))")
        } catch {
            return StudioCommandResult(ok: false, message: "Open in Studio: \(error)")
        }
    }

    /// Resolve the bundled Python backend dir (same resolution BackendViewModel
    /// uses): the app Resources `python` dir in production, else the
    /// MAJIKS_PYTHON_SRC override, else a dev `src/python`. The engine's
    /// htdemucs separator shells into it.
    private static func resolvePythonSrc() -> String? {
        let fm = FileManager.default
        let marker = "majik_backend/rpc_server.py"
        if let res = Bundle.main.resourceURL?.appendingPathComponent("python", isDirectory: true),
           fm.fileExists(atPath: res.appendingPathComponent(marker).path) {
            return res.path
        }
        if let env = ProcessInfo.processInfo.environment["MAJIKS_PYTHON_SRC"] { return env }
        let cwd = fm.currentDirectoryPath
        for cand in ["src/python", "../python", "../../src/python"] {
            let p = URL(fileURLWithPath: cwd).appendingPathComponent(cand)
            if fm.fileExists(atPath: p.appendingPathComponent(marker).path) { return p.path }
        }
        return nil
    }

    // MARK: Revise / Extend / Add-a-Layer (L9)
    //
    // Routes through the existing `client.tool(...)` path (the same validate +
    // dispatch the MCP server uses), so no regenerated FFI binding is needed:
    // each is a whole pipeline of catalog commands on the real timeline-core
    // bus, with real undo + provenance. UUIDs (UI) map to the engine's string
    // ids; take handles stay opaque strings.

    func revise(_ request: StudioReviseRequest) async -> StudioReviseOutcome {
        let clipIds = request.clipIDs.compactMap { uuidClip[$0] }
        guard !clipIds.isEmpty else { return .failed("No clip under the selection.") }
        var args: [String: Any] = [
            "regionStartTicks": request.regionStartTicks,
            "regionEndTicks": request.regionEndTicks,
            "instruction": request.instruction,
            "variants": request.variants,
            "keepLyrics": request.keepLyrics,
            "crossfadeMs": request.crossfadeMs,
        ]
        if request.allStems {
            args["scope"] = "all-stems"
            args["clipId"] = clipIds.first
        } else {
            args["scope"] = request.scope.map { $0.rawValue }
            args["clipIds"] = clipIds
        }
        if let seed = request.seed { args["seed"] = seed }
        guard let json = try? client.tool(name: "studio_revise", args: args) else {
            return .failed("The engine could not start the revise.")
        }
        var variants: [StudioReviseVariant] = []
        var drafts: [Int: [String]] = [:]
        for vt in json.array("variantTakes") {
            let index = ((vt["variant"] as? NSNumber)?.intValue) ?? variants.count
            let seed = UInt64(bitPattern: ((vt["seed"] as? NSNumber)?.int64Value) ?? 0)
            var proms: [StudioPromotion] = []
            var draftIDs: [String] = []
            for p in (vt["promotions"] as? [[String: Any]] ?? []) {
                guard let takeID = p["takeId"] as? String, let clipStr = p["clipId"] as? String else { continue }
                let stem = StudioStemKind(rawValue: (p["stem"] as? String) ?? "other") ?? .other
                proms.append(StudioPromotion(takeID: takeID, clipID: uuid(forClip: clipStr), stem: stem))
                draftIDs.append(takeID)
            }
            variants.append(StudioReviseVariant(index: index, seed: seed, promotions: proms))
            drafts[index] = draftIDs
        }
        let audition = json.dict("audition") ?? [:]
        let loopStart = (audition["loopStartTicks"] as? NSNumber)?.int64Value ?? request.regionStartTicks
        let loopEnd = (audition["loopEndTicks"] as? NSNumber)?.int64Value ?? request.regionEndTicks
        return StudioReviseOutcome(ok: true, message: nil, variants: variants,
            auditionLoopStart: loopStart, auditionLoopEnd: loopEnd, draftTakeIDsByVariant: drafts)
    }

    func commitRevise(_ promotions: [StudioPromotion], reason: String) async -> StudioCommandResult {
        let proms: [[String: Any]] = promotions.compactMap { p in
            guard let clip = uuidClip[p.clipID] else { return nil }
            return ["takeId": p.takeID, "clipId": clip]
        }
        guard !proms.isEmpty else { return StudioCommandResult(ok: false, message: "Nothing to commit.") }
        return reviseTool("studio_commit", ["promotions": proms, "reason": reason])
    }

    func finalizeRevise(draftTakeIDs: [String]) async -> StudioCommandResult {
        guard !draftTakeIDs.isEmpty else { return StudioCommandResult(ok: true, message: nil) }
        return reviseTool("studio_finalize", ["draftTakeIds": draftTakeIDs, "rung": "full"])
    }

    func discardRevise(takeIDs: [String]) async -> StudioCommandResult {
        reviseTool("studio_discard", ["takeIds": takeIDs])
    }

    func extendClip(clipID: UUID, addedSeconds: Double, instruction: String, variants: Int) async -> StudioGenOutcome {
        guard let clip = uuidClip[clipID] else { return .failed("Unknown clip.") }
        guard let json = try? client.tool(name: "studio_extend", args: [
            "clipId": clip, "addedDurationSeconds": addedSeconds, "instruction": instruction, "variants": variants,
        ]) else { return .failed("The engine could not start the extend.") }
        return StudioGenOutcome(ok: true, message: nil, takes: parseTakes(json), targetTrackID: nil)
    }

    func commitExtend(takeID: String, clipID: UUID) async -> StudioCommandResult {
        guard let clip = uuidClip[clipID] else { return StudioCommandResult(ok: false, message: "Unknown clip.") }
        return reviseTool("studio_commit_extend", ["takeId": takeID, "clipId": clip])
    }

    func addLayer(instruction: String, regionStartTicks: Int64, regionEndTicks: Int64, contextClipID: UUID?, stem: StudioStemKind, variants: Int) async -> StudioGenOutcome {
        var args: [String: Any] = [
            "instruction": instruction, "regionStartTicks": regionStartTicks,
            "regionEndTicks": regionEndTicks, "stem": stem == .imported ? "other" : stem.rawValue, "variants": variants,
        ]
        if let ctx = contextClipID, let s = uuidClip[ctx] { args["contextClipId"] = s }
        guard let json = try? client.tool(name: "studio_layer", args: args) else {
            return .failed("The engine could not start the layer.")
        }
        return StudioGenOutcome(ok: true, message: nil, takes: parseTakes(json),
            targetTrackID: json.string("targetTrackId"))
    }

    func commitLayer(takeID: String, targetTrackID: String, regionStartTicks: Int64) async -> StudioCommandResult {
        reviseTool("studio_commit_layer", ["takeId": takeID, "targetTrackId": targetTrackID, "regionStartTicks": regionStartTicks])
    }

    // MARK: Export + provenance (L13)
    //
    // Routes export.master / export.region / export.stems / export.manifest
    // through the SAME journaled command bus (client.submit -> host.submit), so
    // every export is auditable and drives the offline bounce. The manifest is
    // built by the engine from the command journal; this only surfaces the
    // result. Publish reuses the EXISTING majiks.online path (server-side certs);
    // this lane hands it a master + manifest and does not reimplement minting.

    func exportAudio(_ request: StudioExportRequest) async -> StudioExportOutcome {
        var params: [String: Any] = ["format": request.format.rawValue]
        let name: String
        switch request.scope {
        case .master:
            name = "export.master"
            params["outputPath"] = request.outputPath
            params["loudnessTarget"] = request.loudness.wire
            params["includeManifest"] = request.includeManifest
        case .region:
            name = "export.region"
            params["outputPath"] = request.outputPath
            params["startTicks"] = request.regionStartTicks
            params["endTicks"] = request.regionEndTicks
            params["loudnessTarget"] = request.loudness.wire
            params["includeManifest"] = request.includeManifest
        case .stems:
            name = "export.stems"
            params["format"] = "wav"           // stems are 24-bit WAV
            params["outputDir"] = request.outputPath
            params["includeManifest"] = request.includeManifest
        }
        do {
            let json = try client.submit(name: name, params: params)
            return exportOutcome(from: json, request: request)
        } catch let e as FfiError {
            return .failed(ffiMessage(e))
        } catch {
            return .failed("\(error)")
        }
    }

    func writeManifest(outputPath: String) async -> StudioExportOutcome {
        do {
            let json = try client.submit(name: "export.manifest", params: ["outputPath": outputPath])
            let prov = json.dict("provenance").flatMap { EngineJSON($0).string("summary") }
            let path = json.string("outputPath") ?? outputPath
            return StudioExportOutcome(
                ok: json.bool("ok") ?? false, message: nil,
                outputPath: path, format: "manifest",
                loudness: nil, manifestPath: path, provenanceSummary: prov)
        } catch let e as FfiError {
            return .failed(ffiMessage(e))
        } catch {
            return .failed("\(error)")
        }
    }

    func publishToMajiks(_ request: StudioPublishRequest) async -> StudioCommandResult {
        // Prepare the publish payload: export the master + provenance manifest.
        // The upload + server-side certificate minting is the EXISTING
        // majiks.online publisher (majik_backend/publisher_rpc.publish_track),
        // reused untouched; this hands it a master and a machine-readable manifest.
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Majiks Studio Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = request.title.isEmpty ? "Untitled" : request.title
        let out = dir.appendingPathComponent("\(safe).wav").path
        let outcome = await exportAudio(StudioExportRequest(
            scope: .master, format: .wav, loudness: .streaming,
            includeManifest: request.includeManifest, outputPath: out))
        guard outcome.ok else {
            return StudioCommandResult(ok: false, message: outcome.message ?? "Export for publish failed.")
        }
        return StudioCommandResult(
            ok: true,
            message: "Master + provenance manifest ready. majiks.online publishing uses the existing publisher (server-side certificates).")
    }

    private func exportOutcome(from json: EngineJSON, request: StudioExportRequest) -> StudioExportOutcome {
        let ok = json.bool("ok") ?? false
        var loudness: StudioLoudnessResult?
        if let l = json.dict("loudness") {
            let lj = EngineJSON(l)
            loudness = StudioLoudnessResult(
                target: lj.string("target") ?? "none",
                integratedLufsAfter: lj.double("integratedLufsAfter"),
                appliedGainDB: lj.double("appliedGainDb") ?? 0,
                samplePeakDBFS: lj.double("samplePeakDbfs"),
                errorLU: lj.double("errorLu") ?? 0)
        }
        let prov = json.dict("provenance").flatMap { EngineJSON($0).string("summary") }
        let outPath = json.string("outputPath") ?? (request.scope == .stems ? request.outputPath : nil)
        return StudioExportOutcome(
            ok: ok, message: ok ? nil : json.string("note"),
            outputPath: outPath, format: json.string("format"),
            loudness: loudness, manifestPath: json.string("manifestPath"),
            provenanceSummary: prov)
    }

    private func parseTakes(_ json: EngineJSON) -> [StudioGenTake] {
        json.array("takes").compactMap { t in
            guard let id = t["takeId"] as? String else { return nil }
            let seed = UInt64(bitPattern: ((t["seed"] as? NSNumber)?.int64Value) ?? 0)
            return StudioGenTake(takeID: id, seed: seed, label: (t["label"] as? String) ?? "Take")
        }
    }

    private func reviseTool(_ name: String, _ args: [String: Any]) -> StudioCommandResult {
        do {
            _ = try client.tool(name: name, args: args)
            return StudioCommandResult(ok: true, message: nil)
        } catch let e as FfiError {
            return StudioCommandResult(ok: false, message: ffiMessage(e))
        } catch {
            return StudioCommandResult(ok: false, message: "\(error)")
        }
    }

    // MARK: Takes browser (L10)
    //
    // Reads takes.list (studio_takes) and drives take.auditionMix / take.promote
    // / studio_purge_takes through the SAME client.tool / client.submit path
    // everything else uses, so the browser and an agent share one path.

    func takes(query: StudioTakesQuery) async -> [StudioTakeBrowserItem] {
        var args: [String: Any] = ["includePurged": query.includePurged]
        if let c = query.clipID { args["clipId"] = c }
        if let r = query.requestID { args["requestId"] = r }
        if let k = query.kind { args["kind"] = k.rawValue }
        if query.auditionableOnly { args["auditionableOnly"] = true }
        guard let json = try? client.tool(name: "studio_takes", args: args) else { return [] }
        return json.array("takes").map(parseTakeItem)
    }

    private func parseTakeItem(_ raw: [String: Any]) -> StudioTakeBrowserItem {
        let t = EngineJSON(raw)
        let stem = t.string("stem") ?? "mix"
        let hashes = t.dict("assetHashes") ?? [:]
        let assetHash = (hashes[stem] as? String) ?? (hashes.values.first as? String)
        let lin = EngineJSON(t.dict("lineage") ?? [:])
        let regionStart = lin.int64("regionStartTicks")
        let regionEnd = lin.int64("regionEndTicks")
        return StudioTakeBrowserItem(
            takeID: t.string("takeId") ?? "",
            requestID: t.string("requestId") ?? "",
            kind: StudioTakeKind(rawValue: t.string("kind") ?? "other") ?? .other,
            stemName: stem,
            status: StudioTakeStatusKind(rawValue: t.string("status") ?? "candidate") ?? .candidate,
            promotedInto: t.string("promotedInto"),
            assetHash: assetHash,
            auditionable: t.bool("auditionable") ?? false,
            provenance: t.bool("provenance") ?? false,
            offline: t.bool("offline") ?? false,
            createdTs: t.string("createdTs"),
            createdSeq: t.int64("createdSeq").map(Int.init),
            lineage: StudioTakeLineage(
                prompt: lin.string("prompt"),
                seed: lin.int64("seed").map { UInt64(bitPattern: $0) },
                model: lin.string("model"),
                steps: lin.int64("steps").map(Int.init),
                device: lin.string("device"),
                regionStartTicks: (regionStart != nil && regionEnd != nil) ? regionStart : nil,
                regionEndTicks: (regionStart != nil && regionEnd != nil) ? regionEnd : nil))
    }

    func auditionMix(takeID: String, stems: [String]) async -> StudioCommandResult {
        do {
            _ = try client.submit(name: "take.auditionMix", params: ["takeId": takeID, "stems": stems])
            return StudioCommandResult(ok: true, message: nil)
        } catch let e as FfiError {
            return StudioCommandResult(ok: false, message: ffiMessage(e))
        } catch {
            return StudioCommandResult(ok: false, message: "\(error)")
        }
    }

    func purgeTakes(scope: StudioPurgeScope) async -> StudioPurgeResult {
        var args: [String: Any] = ["confirm": true]
        switch scope {
        case .all: break
        case .take(let id): args["takeId"] = id
        case .request(let r): args["requestId"] = r
        }
        do {
            let json = try client.tool(name: "studio_purge_takes", args: args)
            let purgedCount = (json["purgedTakeIds"] as? [Any])?.count ?? 0
            return StudioPurgeResult(
                ok: true, purgedCount: purgedCount,
                assetsDeleted: Int(json.int64("assetsDeleted") ?? 0),
                bytesReclaimed: json.int64("bytesReclaimed") ?? 0, message: nil)
        } catch let e as FfiError {
            return .failed(ffiMessage(e))
        } catch {
            return .failed("\(error)")
        }
    }

    func placeTake(takeID: String, ontoClipID: UUID) async -> StudioCommandResult {
        guard let clip = uuidClip[ontoClipID] else {
            return StudioCommandResult(ok: false, message: "Unknown clip.")
        }
        // Drag-to-timeline = use this take here (take.promote is undoable).
        do {
            _ = try client.submit(name: "take.promote", params: ["takeId": takeID, "targetClipId": clip])
            return StudioCommandResult(ok: true, message: nil)
        } catch let e as FfiError {
            return StudioCommandResult(ok: false, message: ffiMessage(e))
        } catch {
            return StudioCommandResult(ok: false, message: "\(error)")
        }
    }

    // MARK: Command routing (StudioEngineCommand -> catalog envelope)

    private func route(_ command: StudioEngineCommand) throws {
        switch command {
        case .transportPlay:
            ensureLive()
            _ = try client.transport(action: "play", positionTicks: nil)
        case .transportStop:
            _ = try client.transport(action: "stop", positionTicks: nil)
        case .transportSeek(let ticks):
            _ = try client.transport(action: "seek", positionTicks: UInt64(max(0, ticks)))
        case .transportLoopSet(let start, let end):
            try submit("transport.loop.set", ["startTicks": start, "endTicks": end])
        case .transportLoopClear:
            try submit("transport.loop.clear", [:])
        case .transportMetronome(let enabled):
            try submit("transport.metronome", ["enabled": enabled])

        case .clipMove(let clipID, let toTrackID, let toStartTicks):
            guard let clip = uuidClip[clipID], let track = uuidTrack[toTrackID] else {
                throw FfiError.InvalidArgument(message: "unknown clip/track id")
            }
            try submit("clip.move", ["clipId": clip, "trackId": track, "startTicks": toStartTicks])

        case .clipTrim(let clipID, let newStartTicks, let newLengthTicks):
            guard let clip = uuidClip[clipID], let geo = clipGeometry[clip] else {
                throw FfiError.InvalidArgument(message: "unknown clip id or no geometry")
            }
            if newStartTicks != geo.start {
                // start edge: +delta shortens from the start (catalog rule).
                try submit("clip.trim", ["clipId": clip, "edge": "start", "deltaTicks": newStartTicks - geo.start])
            } else if newLengthTicks != geo.length {
                try submit("clip.trim", ["clipId": clip, "edge": "end", "deltaTicks": newLengthTicks - geo.length])
            }

        case .clipSplit(let clipID, let atTicks):
            guard let clip = uuidClip[clipID] else {
                throw FfiError.InvalidArgument(message: "unknown clip id")
            }
            let newId = mintClipId()
            try submit("clip.split", ["clipId": clip, "atTicks": atTicks, "newClipId": newId])

        case .clipDuplicate(let clipID):
            guard let clip = uuidClip[clipID], let geo = clipGeometry[clip] else {
                throw FfiError.InvalidArgument(message: "unknown clip id")
            }
            let newId = mintClipId()
            try submit("clip.duplicate", ["clipId": clip, "newClipId": newId, "startTicks": geo.start + geo.length])

        case .clipRemove(let clipID):
            guard let clip = uuidClip[clipID] else {
                throw FfiError.InvalidArgument(message: "unknown clip id")
            }
            try submit("clip.remove", ["clipId": clip])

        case .clipFadeSet(let clipID, let fadeInTicks, let fadeOutTicks):
            guard let clip = uuidClip[clipID] else {
                throw FfiError.InvalidArgument(message: "unknown clip id")
            }
            try submit("clip.fade.set", ["clipId": clip, "edge": "in", "lengthTicks": max(0, fadeInTicks), "shape": "equalPower"])
            try submit("clip.fade.set", ["clipId": clip, "edge": "out", "lengthTicks": max(0, fadeOutTicks), "shape": "equalPower"])

        case .trackMute(let trackID, let muted):
            guard let track = uuidTrack[trackID] else { throw FfiError.InvalidArgument(message: "unknown track id") }
            try submit("track.mute", ["trackId": track, "muted": muted])

        case .trackSolo(let trackID, let soloed):
            guard let track = uuidTrack[trackID] else { throw FfiError.InvalidArgument(message: "unknown track id") }
            try submit("track.solo", ["trackId": track, "soloed": soloed])

        case .trackArm(let trackID, let armed):
            guard let track = uuidTrack[trackID] else { throw FfiError.InvalidArgument(message: "unknown track id") }
            try submit("track.arm", ["trackId": track, "armed": armed])
        case .trackSetInputChannel(let trackID, let channel):
            guard let track = uuidTrack[trackID] else { throw FfiError.InvalidArgument(message: "unknown track id") }
            try submit("track.setInputChannel", ["trackId": track, "channel": max(0, channel)])

        // track.add mints its own engine id (unlike the mutate verbs above, the
        // track does not exist yet), then rides the SAME generic client.submit
        // bus as record.* — no new FFI symbol. The next snapshot maps this engine
        // id to a Swift UUID (uuid(forTrack:)) so importAudio can target it.
        case .trackAdd(let trackID, let name, let index):
            try submit("track.add", ["trackId": trackID, "name": name, "index": max(0, index)])

        case .trackRemove(let trackID):
            try submit("track.remove", ["trackId": engineTrack(trackID)])

        case .deviceRemove(let trackID, let deviceID):
            try submit("device.remove", ["trackId": engineTrack(trackID), "deviceId": deviceID])

        // Like track.add, the id is minted UI-side because the device does not
        // exist yet. `deviceId` must not contain '.', or the engine's ParamRef
        // path `track.device.<deviceId>.<paramKey>` stops parsing — the minted
        // id strips the UUID's hyphens and adds no dots.
        case .deviceAdd(let trackID, let deviceID, let kind):
            try submit("device.add", ["trackId": engineTrack(trackID),
                                      "deviceId": deviceID, "kind": kind])

        // ---- recording (L19): the generic command path, no new FFI symbols ----
        case .recordInputListen(let enabled, let deviceID):
            var params: [String: Any] = ["enabled": enabled]
            if let deviceID { params["deviceId"] = deviceID }
            try submit("record.inputListen", params)
        case .recordStart(let trackID, let deviceID, let startTicks, let punchOutTicks):
            guard let track = uuidTrack[trackID] else { throw FfiError.InvalidArgument(message: "unknown track id") }
            var params: [String: Any] = ["trackId": track]
            if let startTicks { params["startTicks"] = max(0, startTicks) }
            if let deviceID, !deviceID.isEmpty { params["deviceId"] = deviceID }
            if let punchOutTicks, let startTicks, punchOutTicks > startTicks { params["punchOutTicks"] = punchOutTicks }
            try submit("record.start", params)
        case .recordRotate:
            try submit("record.rotate", [:])
        case .recordStop:
            try submit("record.stop", [:])
        case .recordCancel:
            try submit("record.cancel", [:])

        case .projectSetTempo(let bpm):
            try submit("project.setTempo", ["bpm": bpm])
        case .projectSetTimeSig(let num, let den):
            try submit("project.setTimeSig", ["numerator": num, "denominator": den])
        case .projectSetKey(let key):
            try submit("project.setKey", ["key": key])

        // ---- mixer (L12) ----
        case .mixGain(let trackID, let gainDB):
            try submit("mix.gain", ["trackId": engineTrack(trackID), "gainDb": gainDB])
        case .mixPan(let trackID, let pan):
            try submit("mix.pan", ["trackId": engineTrack(trackID), "pan": pan])
        case .mixEq(let trackID, let band, let freqHz, let gainDB, let q):
            try submit("mix.eq", ["trackId": engineTrack(trackID), "band": band,
                                  "freqHz": freqHz, "gainDb": gainDB, "q": q])
        case .mixSend(let trackID, let bus, let amount):
            try submit("mix.send", ["trackId": engineTrack(trackID), "bus": bus.rawValue, "amount": amount])
        case .mixMasterGain(let gainDB):
            try submit("mix.master.gain", ["gainDb": gainDB])
        case .mixLimiterSet(let enabled, let ceilingDB, let releaseMs):
            try submit("mix.limiter.set", ["enabled": enabled, "ceilingDb": ceilingDB, "releaseMs": releaseMs])

        // ---- automation (L12) ----
        case .autolaneShow(let trackID, let target, let visible):
            try submit("autolane.show", ["trackId": engineTrack(trackID),
                                         "target": target.wireName, "visible": visible])
        case .autopointAdd(let trackID, let target, let pointID, let positionTicks, let value):
            try submit("autopoint.add", ["trackId": engineTrack(trackID), "target": target.wireName,
                                         "pointId": pointID, "positionTicks": positionTicks, "value": value])
        case .autopointMove(let trackID, let target, let pointID, let positionTicks, let value):
            try submit("autopoint.move", ["trackId": engineTrack(trackID), "target": target.wireName,
                                          "pointId": pointID, "positionTicks": positionTicks, "value": value])
        case .autopointRemove(let trackID, let target, let pointID):
            try submit("autopoint.remove", ["trackId": engineTrack(trackID),
                                            "target": target.wireName, "pointId": pointID])
        case .autolaneClear(let trackID, let target):
            try submit("autolane.clear", ["trackId": engineTrack(trackID), "target": target.wireName])
        case .catalog(let name, let params):
            try submit(name, resolvingUIIDs(params))
        }
    }

    /// Resolve a UI track UUID to the engine's string id, or throw.
    private func engineTrack(_ trackID: UUID) throws -> String {
        guard let track = uuidTrack[trackID] else {
            throw FfiError.InvalidArgument(message: "unknown track id")
        }
        return track
    }

    /// The half of the `.catalog` escape hatch that was missing.
    ///
    /// THE TWO ID SPACES ARE NOT THE SAME STRING. `uuid(forTrack:)` MINTS a
    /// fresh `UUID` the first time it sees an engine id, so a track's Swift
    /// `id` and its engine id (`t_01J…`, `t_9f3c1a2b`) are unrelated values.
    /// Every TYPED case above knows that and resolves through `uuidTrack` /
    /// `uuidClip` before submitting. The generic `.catalog` case forwarded
    /// `params` verbatim — so every command that rides it carrying a UI id
    /// named a track the engine has never heard of, and was refused. Always.
    /// On the shipped build. That is `device.param.set` (both the named-sound
    /// buttons and every raw synth control), `track.rename`, `track.reorder`,
    /// `track.setColor`, `track.setHeight`, `clip.rename`, `clip.setGain` and
    /// `clip.mute`.
    ///
    /// WHY NOTHING CAUGHT IT. `StudioMockEngine` resolves `trackId` with
    /// `UUID(uuidString:)` against its own ids, because the mock's track ids
    /// ARE the UUIDs the UI minted. In the mock the two spaces coincide, so the
    /// whole tone lane is green under `swift test` while the real product
    /// cannot change a sound. The conflation lived in the test double, which is
    /// the one place it can never be seen from.
    ///
    /// THE MEMBERSHIP TEST, and not a shape test, because a shape test is not
    /// safe. `track.add` mints its id UI-side and the engine KEEPS it, so some
    /// engine-native ids are themselves UUID-shaped — a rule of "looks like a
    /// UUID, therefore translate it" would rewrite a perfectly good engine id
    /// into a refusal. That was not a hypothetical: the first draft did exactly
    /// that and `testAnEngineNativeIDInACatalogParamIsUntouched` caught it.
    ///
    /// So the question asked is which SIDE the string is already on:
    ///  - a UUID this engine handed out (`uuidTrack` / `uuidClip`) -> translate;
    ///  - a string the engine has issued or been given as a track/clip id
    ///    (`trackUUID` / `clipUUID`, keyed the other way) -> already native,
    ///    leave it exactly as it is;
    ///  - anything else names nothing this engine has ever seen, which for a
    ///    UI id means the project it came from is gone. Refused HERE, in a
    ///    sentence, rather than becoming the engine's "unknown track: 8B1F…-…"
    ///    in front of someone who has never used a DAW. A non-UUID string is
    ///    left alone even then: it is somebody else's id space, not ours to
    ///    judge, and the engine gives the better answer about it.
    private func resolvingUIIDs(_ params: [String: AnyHashable]) throws -> [String: Any] {
        var out: [String: Any] = params
        for key in StudioEngineIDParam.uiMinted {
            // WHICH MAP, from the classification rather than from the name. A
            // suffix rule would happen to get all seven right today
            // (`targetTrackId` is a track, `contextClipId` is a clip) and would
            // silently mis-file the first key that breaks the pattern — and it
            // would also sweep in `newClipId`, which must NOT be translated
            // because `clip.duplicate` and `clip.split` mint it for a clip the
            // engine has never seen.
            let isTrack = StudioEngineIDParam.trackKeys.contains(key)
            guard let raw = params[key] as? String else { continue }
            if isTrack ? (trackUUID[raw] != nil) : (clipUUID[raw] != nil) { continue }
            guard let uiID = UUID(uuidString: raw) else { continue }
            guard let engineID = isTrack ? uuidTrack[uiID] : uuidClip[uiID] else {
                throw FfiError.InvalidArgument(
                    message: isTrack
                        ? "that track is no longer in the project"
                        : "that clip is no longer in the project")
            }
            out[key] = engineID
        }
        return out
    }

    private func submit(_ name: String, _ params: [String: Any]) throws {
        _ = try client.submit(name: name, params: params)
    }

    private func mintClipId() -> String {
        "clip_\(UUID().uuidString.prefix(12))"
    }

    // MARK: Snapshot translation (engine JSON -> StudioProjectSnapshot)

    private func buildSnapshot(_ root: EngineJSON, meters: EngineJSON?, seq: UInt64) -> StudioProjectSnapshot {
        let project = EngineJSON(root.dict("project") ?? [:])
        let sig = timeSignature(project)
        let ticksPerBar = sig.ticksPerBar
        // What a tick is WORTH in samples, for the waveform seam. Read here
        // because this is the only place the project JSON is parsed, and the
        // app always has a snapshot before it draws a clip, so a tile request
        // can never precede this.
        let bpm = project.double("bpm_wire", "bpmWire") ?? 120
        let tempoChanges: [(ticks: Int64, bpm: Double)] = project.array("tempoMap").compactMap {
            let segment = EngineJSON($0)
            guard let segmentBPM = segment.double("bpm"), segmentBPM > 0 else { return nil }
            return (segment.int64("startTicks") ?? 0, segmentBPM)
        }
        let tempoMap = tempoChanges.isEmpty
            ? StudioTempoMap.constant(bpm: bpm)
            : StudioTempoMap.from(changes: tempoChanges)
        samplesPerTick = StudioEngineTileFetch.samplesPerTick(
            sampleRate: project.double("sample_rate", "sampleRate") ?? 48_000,
            bpm: bpm)

        // Meters (measured; keyed by engine track id). Master LUFS + correlation
        // are also here, not in the project JSON.
        var trackMeters: [String: StudioChannelMeter] = [:]
        var masterMeter = StudioMasterMeter.silent
        var lufsIntegrated: Double?
        var lufsShortTerm: Double?
        var correlation: Double?
        if let meters {
            for m in meters.array("tracks") {
                let mj = EngineJSON(m)
                if let tid = mj.string("trackId") {
                    trackMeters[tid] = StudioChannelMeter(
                        peakDB: mj.double("peakDb") ?? -120, rmsDB: mj.double("rmsDb") ?? -120)
                }
            }
            let mm = EngineJSON(meters.dict("master") ?? [:])
            masterMeter = StudioMasterMeter(
                peakDB: mm.double("peakDb") ?? -120,
                rmsDB: mm.double("rmsDb") ?? -120,
                truePeakDB: mm.double("truePeakDb") ?? -120,
                gainReductionDB: mm.double("gainReductionDb") ?? 0)
            lufsIntegrated = mm.double("lufsIntegrated")
            lufsShortTerm = mm.double("lufsShortTerm")
            correlation = mm.double("correlation")
        }

        var tracks: [StudioTrackSnapshot] = []
        var maxEnd: Int64 = 0
        var importedClips = 0
        var totalClips = 0
        for t in project.array("tracks") {
            let tj = EngineJSON(t)
            guard let tid = tj.string("id", "trackId") else { continue }
            let clipsJSON = tj.array("clips")
            var clips: [StudioClipSnapshot] = []
            for c in clipsJSON {
                let cj = EngineJSON(c)
                guard let cid = cj.string("id", "clipId") else { continue }
                let start = cj.int64("start_ticks", "startTicks") ?? 0
                let len = max(1, cj.int64("length_ticks", "lengthTicks") ?? 1)
                clipGeometry[cid] = (start, len)
                maxEnd = max(maxEnd, start + len)
                totalClips += 1
                // The engine's own provenance classification — the one the
                // exported manifest is built from. Absent on a snapshot older
                // than the field, in which case the UI falls back to deriving
                // it (StudioClipSnapshot.origin).
                let engineOrigin = cj.string("origin").flatMap(StudioClipOrigin.init(rawValue:))
                if engineOrigin == .imported { importedClips += 1 }
                let sourceId = cj.string("source_id", "assetHash") ?? cid
                let seed = seedFor(sourceId)
                let sourceOffsetTicks = cj.int64("source_offset_ticks", "sourceOffsetTicks") ?? 0
                seedToClip[seed] = cid
                seedSourceOffsetTicks[seed] = sourceOffsetTicks
                // E1's §1 clip discriminator. Absent on every audio clip (the
                // key is omitted, not set to "audio"), so this reads false for
                // every pre-E1 project.
                let isMidi = cj.string("kind") == "midi"
                clips.append(StudioClipSnapshot(
                    id: uuid(forClip: cid),
                    name: cj.string("name") ?? cid,
                    startTicks: start,
                    lengthTicks: len,
                    sourceOffsetTicks: sourceOffsetTicks,
                    fadeInTicks: EngineJSON(cj.dict("fade_in") ?? [:]).int64("length_ticks") ?? 0,
                    fadeOutTicks: EngineJSON(cj.dict("fade_out") ?? [:]).int64("length_ticks") ?? 0,
                    gainDB: cj.double("gain_db", "gainDb") ?? 0,
                    muted: cj.bool("muted") ?? false,
                    generative: engineOrigin == .generated,
                    waveformSeed: seed,
                    isMidi: isMidi,
                    engineOrigin: engineOrigin
                ))
            }
            let automation = EngineJSON(tj.dict("automation") ?? [:])
            let volAuto = autoPoints(automation, "volume")
            let panAuto = autoPoints(automation, "pan")
            tracks.append(StudioTrackSnapshot(
                id: uuid(forTrack: tid),
                name: tj.string("name") ?? tid,
                kind: stemKind(tj.string("name") ?? ""),
                muted: tj.bool("mute", "muted") ?? false,
                soloed: tj.bool("solo", "soloed") ?? false,
                armed: tj.bool("armed") ?? false,
                inputChannel: Int(tj.int64("input_channel", "inputChannel") ?? 0),
                volumeDB: tj.double("gain", "gainDb") ?? 0,
                pan: tj.double("pan") ?? 0,
                clips: clips,
                takeLane: parseTakeLane(tj),
                hasVolumeAutomation: !volAuto.isEmpty,
                // Instruments (E1/E2). The model omits `devices` when empty, so
                // absence decodes as [] — every pre-E1 track reads device-free.
                devices: tj.array("devices").compactMap { d in
                    let dj = EngineJSON(d)
                    guard let id = dj.string("id") else { return nil }
                    // `zones` is the SOURCE BINDING — which recording a sampler
                    // zone or a drum pad plays. Omitted-when-empty on the wire
                    // exactly like `devices`, so a synth (and every pre-E2
                    // device) decodes as [].
                    let zones: [StudioZoneSnapshot] = dj.array("zones").compactMap { z in
                        let zj = EngineJSON(z)
                        guard let zid = zj.string("id"),
                              let source = zj.string("source_id", "sourceId") else { return nil }
                        return StudioZoneSnapshot(
                            id: zid,
                            sourceID: source,
                            rootPitch: Int(zj.int64("root_pitch", "rootPitch") ?? 60),
                            loPitch: Int(zj.int64("lo_pitch", "loPitch") ?? 0),
                            hiPitch: Int(zj.int64("hi_pitch", "hiPitch") ?? 127),
                            gainDB: zj.double("gain", "gainDb") ?? 0,
                            pan: zj.double("pan") ?? 0)
                    }
                    // The AUTHORED SOUND (`device.param.set`). Omitted-when-
                    // empty on the wire like `zones`, so an untouched synth
                    // decodes as [:] — which the panel reads as "the DSP
                    // defaults", never as zeroes.
                    var params: [String: Double] = [:]
                    for (k, v) in dj.dict("params") ?? [:] {
                        if let n = v as? NSNumber { params[k] = n.doubleValue }
                    }
                    return StudioDeviceSnapshot(
                        id: id, kind: dj.string("kind") ?? "synth",
                        zones: zones, params: params)
                },
                eq: eqBands(tj),
                sendA: EngineJSON(tj.dict("sends") ?? [:]).double("a") ?? 0,
                sendB: EngineJSON(tj.dict("sends") ?? [:]).double("b") ?? 0,
                volumeAutomation: volAuto,
                panAutomation: panAuto,
                hasPanAutomation: !panAuto.isEmpty,
                meter: trackMeters[tid] ?? .silent,
                // Why this track is here, when the app is the one that put it
                // here. Omitted-when-ordinary on the wire exactly like `devices`
                // and per-clip `origin`, so a track someone made themselves —
                // and every project written before the engine reported this —
                // decodes as nil and the header says nothing about it.
                origin: tj.string("origin").flatMap(StudioTrackOrigin.init(rawValue:))
            ))
        }

        let lengthBars = max(1, Int((maxEnd + ticksPerBar - 1) / max(1, ticksPerBar)))
        let sections = buildSections(project, ticksPerBar: ticksPerBar, lengthBars: lengthBars)

        let transport = EngineJSON(root.dict("transport") ?? [:])
        let loop = transport.dict("loop")
        let loopRegion: ClosedRange<Int64>? = loop.flatMap { l in
            let s = (l["startTicks"] as? NSNumber)?.int64Value
            let e = (l["endTicks"] as? NSNumber)?.int64Value
            if let s, let e, e > s { return s...e }
            return nil
        }

        let master = EngineJSON(project.dict("master") ?? [:])
        let limiter = EngineJSON(master.dict("limiter") ?? [:])

        return StudioProjectSnapshot(
            revision: seq,
            name: project.string("name") ?? "Untitled",
            tempoBPM: bpm,
            // Projects created before measured-tempo landing have no
            // confidence field. That is unknown, not failed detection.
            tempoConfidence: project.double("tempoConfidence") ?? 1,
            tempoMap: tempoMap,
            timeSignature: sig,
            key: project.string("key") ?? "",
            lengthBars: lengthBars,
            sections: sections,
            tracks: tracks,
            transport: StudioTransportSnapshot(
                isPlaying: transport.bool("playing") ?? false,
                positionTicks: transport.int64("positionTicks") ?? 0,
                capturedAtHostTime: ProcessInfo.processInfo.systemUptime,
                loopRegion: loopRegion,
                recording: transport.bool("recording") ?? false,
                recordingTrackID: transport.string("recordingTrackId").map { uuid(forTrack: $0) },
                inputOpen: transport.bool("inputOpen") ?? false,
                inputListening: transport.bool("inputListening") ?? false,
                metronomeEnabled: transport.bool("metronomeEnabled") ?? false
            ),
            stats: {
                let s = EngineJSON(root.dict("stats") ?? [:])
                let live = s.bool("live") ?? false
                return StudioEngineStats(
                    callbackP95Millis: s.double("callbackP95Ms") ?? 0,
                    underruns: Int(s.int64("underruns") ?? 0),
                    engineLabel: live ? "engine (live)" : "engine (offline)",
                    // Absent on an older engine build, which reads as "this
                    // engine cannot tell you", not as "no clicks happened" —
                    // the same convention `loadedSources` and the performance
                    // block use. Zero is the honest floor either way.
                    metronomeClicks: Int(s.int64("metronomeClicks") ?? 0),
                    deviceFramesAudible: Int(s.int64("deviceFramesAudible") ?? 0)
                )
            }(),
            master: StudioMasterSnapshot(
                volumeDB: master.double("gain_db", "gainDb") ?? 0,
                lufsIntegrated: lufsIntegrated,
                limiterCeilingDBTP: limiter.double("ceiling_db", "ceilingDb") ?? -1.0,
                limiterEnabled: limiter.bool("enabled") ?? false,
                limiterReleaseMs: limiter.double("release_ms", "releaseMs") ?? 50,
                lufsShortTerm: lufsShortTerm,
                correlation: correlation,
                meter: masterMeter
            ),
            provenanceSummary: totalClips == 0
                ? "empty project"
                : "\(totalClips) clip\(totalClips == 1 ? "" : "s"), \(importedClips) imported",
            inputDevices: (root["audioInputs"] as? [Any])?.compactMap { $0 as? String } ?? [],
            inputMeter: buildInputMeter(meters),
            midi: parseMidiBlock(root),
            // E5 §8: measured bus/group meters (`meters()["nodes"]`), parsed by
            // the routing surface's own JSON reader so the shape is pinned in
            // StudioRoutingRealEngineTests alongside the graph parse.
            nodeMeters: StudioRoutingJSON.parseNodeMeters(meters),
            performance: parsePerformanceBlock(root),
            markers: buildMarkers(project, ticksPerBar: ticksPerBar),
            // Where bar 1 begins. The engine has emitted this since E1
            // (agent-surface `host.rs` project_json); dropping it here is what
            // left the arrangement ruler drawing from tick 0.
            // hash -> the file it was loaded from. The ONLY way the UI can put
            // a name on a drum pad: `source_id` is 64 hex characters, and the
            // model deliberately holds no path. Absent on an older engine
            // build, which reads as "we cannot name these", not as "they are
            // missing" — the sound still plays either way.
            loadedSources: (project["loadedSources"] as? [String: Any])?
                .compactMapValues { ($0 as? [String: Any])?["path"] as? String } ?? [:],
            phaseAnchorTicks: project.int64("phase_anchor_ticks", "phaseAnchorTicks") ?? 0
        )
    }

    /// Parse the `performance` block — what is sounding, and what is keepable.
    /// Absent on an older engine build, which reads as "nothing to keep" rather
    /// than as a crash: the keyboard still plays, it just cannot offer Keep.
    private func parsePerformanceBlock(_ root: EngineJSON) -> StudioPerformanceSnapshot {
        guard let perf = root["performance"] as? [String: Any] else { return .idle }
        let pj = EngineJSON(perf)
        let sounding: [UInt8] = (perf["sounding"] as? [Any])?
            .compactMap { ($0 as? NSNumber)?.intValue }
            .filter { (0...127).contains($0) }
            .map(UInt8.init) ?? []
        return StudioPerformanceSnapshot(
            keepableNotes: Int(pj.int64("keepableNotes") ?? 0),
            sounding: sounding,
            startTicks: pj.int64("startTicks"),
            endTicks: pj.int64("endTicks"))
    }

    /// Parse the optional `midi` block (spec 6). Returns nil when absent
    /// (older engine builds).
    private func parseMidiBlock(_ root: EngineJSON) -> StudioMidiSnapshot? {
        guard let midi = root["midi"] as? [String: Any] else { return nil }
        let mj = EngineJSON(midi)
        let ports: [StudioMidiPort] = (midi["ports"] as? [Any])?.compactMap { p in
            guard let pj = p as? [String: Any] else { return nil }
            return StudioMidiPort(
                name: pj["name"] as? String ?? "",
                connected: (pj["connected"] as? Bool) ?? false,
                map: pj["map"] as? String,
                mapKey: pj["mapKey"] as? String,
                source: pj["source"] as? String,
                tested: pj["tested"] as? Bool,
                unsupportedReason: pj["unsupportedReason"] as? String,
                override: pj["override"] as? String,
                role: (pj["role"] as? String) ?? "instrument")
        } ?? []
        let maps: [StudioMidiMap] = (midi["maps"] as? [Any])?.compactMap { m in
            guard let mj = m as? [String: Any] else { return nil }
            return StudioMidiMap(
                key: mj["key"] as? String ?? "",
                name: mj["name"] as? String ?? "",
                source: mj["source"] as? String ?? "",
                tested: (mj["tested"] as? Bool) ?? false,
                bindingCount: (mj["bindingCount"] as? Int) ?? 0,
                loadError: mj["loadError"] as? String)
        } ?? []
        let bindings: [StudioMidiBinding] = (midi["activeBindings"] as? [Any])?.compactMap { b in
            guard let bj = b as? [String: Any] else { return nil }
            let match = bj["match"] as? [String: Any] ?? [:]
            let target = bj["target"] as? [String: Any] ?? [:]
            return StudioMidiBinding(
                id: bj["id"] as? String ?? "",
                label: bj["label"] as? String ?? "",
                match: StudioMidiControl(
                    type: match["type"] as? String ?? "",
                    channel: (match["channel"] as? Int) ?? 0,
                    number: match["number"] as? Int),
                target: StudioMidiTarget(
                    kind: StudioMidiTargetKind(rawValue: target["kind"] as? String ?? "") ?? .command,
                    name: target["name"] as? String,
                    params: target["params"] as? [String: AnyHashable],
                    instruction: target["instruction"] as? String),
                targetSummary: bj["targetSummary"] as? String,
                enabled: (bj["enabled"] as? Bool) ?? true,
                port: bj["port"] as? String ?? "",
                suppressedByRole: (bj["suppressedByRole"] as? Bool) ?? false)
        } ?? []
        let learnRaw = midi["learn"] as? [String: Any] ?? [:]
        let learn = StudioMidiLearnState(
            active: (learnRaw["active"] as? Bool) ?? false,
            device: learnRaw["device"] as? String,
            ageSeconds: learnRaw["ageSeconds"] as? Double,
            captured: learnRaw["captured"] as? [String: AnyHashable],
            current: learnRaw["current"] as? [String: AnyHashable])
        let lastEventRaw = midi["lastEvent"] as? [String: Any]
        let lastEvent: StudioMidiLastEvent? = lastEventRaw.map { le in
            StudioMidiLastEvent(
                seq: (le["seq"] as? Int) ?? 0,
                port: le["port"] as? String ?? "",
                type: le["type"] as? String ?? "",
                channel: (le["channel"] as? Int) ?? 0,
                number: le["number"] as? Int,
                value: (le["value"] as? Int) ?? 0)
        }
        let sterlingRaw = midi["sterling"] as? [String: Any]
        let sterling: StudioSterlingState? = sterlingRaw.map { s in
            let pending: [StudioMidiSterlingItem] = (s["pending"] as? [Any])?.compactMap { item in
                guard let ij = item as? [String: Any] else { return nil }
                return StudioMidiSterlingItem(
                    seq: (ij["seq"] as? Int) ?? 0,
                    instruction: ij["instruction"] as? String ?? "",
                    bindingId: ij["bindingId"] as? String ?? "",
                    port: ij["port"] as? String ?? "")
            } ?? []
            return StudioSterlingState(nextSeq: (s["nextSeq"] as? Int) ?? 0, pending: pending)
        }
        return StudioMidiSnapshot(
            enabled: (midi["enabled"] as? Bool) ?? true,
            ports: ports, maps: maps, activeBindings: bindings,
            learn: learn, lastEvent: lastEvent, sterling: sterling)
    }

    /// Parse the live input-meter block from the meters read surface (present
    /// only while an input stream is open — recording or opt-in listen).
    private func buildInputMeter(_ meters: EngineJSON?) -> StudioInputMeter? {
        guard let meters, let inp = meters.dict("input") else { return nil }
        let ij = EngineJSON(inp)
        let channels: [StudioChannelMeter] = ij.array("channels").compactMap { raw in
            let cj = EngineJSON(raw)
            return StudioChannelMeter(
                peakDB: cj.double("peakDb") ?? -120,
                rmsDB: cj.double("rmsDb") ?? -120
            )
        }
        return StudioInputMeter(
            peakDB: ij.double("peakDb") ?? -120,
            rmsDB: ij.double("rmsDb") ?? -120,
            clipLatched: ij.bool("clipLatched") ?? false,
            capturedFrames: ij.int64("capturedFrames") ?? 0,
            dropped: Int(ij.int64("dropped") ?? 0),
            sampleRate: Int(ij.int64("sampleRate") ?? 48_000),
            channels: channels)
    }

    private func buildSections(_ project: EngineJSON, ticksPerBar: Int64, lengthBars: Int) -> [StudioSectionSnapshot] {
        let raw = project.array("sections")
        let starts: [Int64] = raw.compactMap { EngineJSON($0).int64("start_ticks", "startTicks") }.sorted()
        return raw.enumerated().compactMap { (i, s) in
            let sj = EngineJSON(s)
            guard let start = sj.int64("start_ticks", "startTicks") else { return nil }
            // THE ENGINE'S OWN ID, not a minted one. This used to be `UUID()`,
            // freshly on every poll, which made "Remove Section" unaddressable:
            // `section.remove` takes the string the engine holds, and nothing
            // ever read it, so there was not even a map to translate through.
            // A section with no id is also skipped rather than guessed at —
            // a guessed id would address the wrong section.
            guard let id = sj.string("id", "sectionId") else { return nil }
            let startBar = Int(start / max(1, ticksPerBar))
            let nextStart = starts.first(where: { $0 > start }) ?? Int64(lengthBars) * ticksPerBar
            let lengthBarsSection = max(1, Int((nextStart - start) / max(1, ticksPerBar)))
            return StudioSectionSnapshot(
                id: id,
                name: sj.string("name") ?? "Section \(i + 1)",
                startBar: startBar,
                lengthBars: lengthBarsSection,
                role: sectionRole(sj.string("name") ?? "")
            )
        }
    }

    /// The project's markers, which this build did not read at all.
    ///
    /// `StudioProjectSnapshot.markers` defaulted to `[]` on the real engine and
    /// nothing ever filled it, so the ruler drew no markers, "Remove Marker"
    /// never appeared, and "Add Marker Here" numbered every new marker `M1`.
    /// The engine has held them the whole time (`Project.markers`); the read
    /// half was simply missing.
    private func buildMarkers(_ project: EngineJSON, ticksPerBar: Int64) -> [StudioMarker] {
        project.array("markers").compactMap { m in
            let mj = EngineJSON(m)
            guard let id = mj.string("id", "markerId"),
                  let position = mj.int64("position_ticks", "positionTicks") else { return nil }
            return StudioMarker(
                id: id,
                name: mj.string("label") ?? id,
                bar: Int(position / max(1, ticksPerBar)))
        }
    }

    /// Parse a track's 4 channel EQ bands (serde snake_case) with defaults.
    private func eqBands(_ tj: EngineJSON) -> [StudioEqBand] {
        let arr = tj.array("eq")
        guard !arr.isEmpty else { return StudioEqBand.defaults }
        var out: [StudioEqBand] = []
        for (i, e) in arr.enumerated() {
            let ej = EngineJSON(e)
            let d = StudioEqBand.defaults[min(i, StudioEqBand.defaults.count - 1)]
            out.append(StudioEqBand(
                index: i,
                freqHz: ej.double("freq_hz", "freqHz") ?? d.freqHz,
                gainDB: ej.double("gain_db", "gainDb") ?? 0,
                q: ej.double("q") ?? 1))
        }
        return out
    }

    /// Parse one automation lane's breakpoints (`automation.volume` / `.pan`).
    private func autoPoints(_ automation: EngineJSON, _ key: String) -> [StudioAutoPoint] {
        (automation[key] as? [[String: Any]] ?? []).compactMap {
            let p = EngineJSON($0)
            guard let id = p.string("id") else { return nil }
            return StudioAutoPoint(
                id: id,
                positionTicks: p.int64("position_ticks", "positionTicks") ?? 0,
                value: p.double("value") ?? 0)
        }
    }

    // MARK: id + inference helpers

    /// Parse the first take-lane from a track's `takeLanes` array (injected by
    /// the Rust snapshot builder; nil when the track has no comp clips).
    private func parseTakeLane(_ tj: EngineJSON) -> StudioTakeLaneSnapshot? {
        guard let lanes = tj["takeLanes"] as? [[String: Any]], let first = lanes.first else { return nil }
        let lane = EngineJSON(first)
        let start = lane.int64("regionStartTicks") ?? 0
        let length = lane.int64("regionLengthTicks") ?? 1
        let takes: [StudioTakeSnapshot] = (lane["takes"] as? [[String: Any]] ?? []).enumerated().map { (i, t) in
            let tj = EngineJSON(t)
            let tid = tj.string("takeId") ?? ""
            let seed = UInt64(bitPattern: tj.int64("seed") ?? 0)
            let picked = tj.bool("picked") ?? false
            return StudioTakeSnapshot(
                id: uuid(forClip: tid),
                name: "Pass \(i + 1)",
                state: .rendered(seed: seed),
                picked: picked)
        }
        return StudioTakeLaneSnapshot(
            id: UUID(),
            regionStartTicks: start,
            regionLengthTicks: length,
            takes: takes)
    }

    // MARK: id map, shared with the NOTE seam
    //
    // Internal (not private) so `RealStudioNoteEngine.swift` translates ids
    // through the SAME map the arrangement does. A note engine that minted its
    // own UUIDs would be unable to open the roll on the clip the arrangement
    // selected — the two surfaces would be talking about different objects
    // while looking identical.

    /// The engine's string id for a UI clip UUID, or nil if unseen.
    func engineClipID(_ id: UUID) -> String? { uuidClip[id] }

    /// The engine's string id for a UI track UUID, or nil if unseen.
    func engineTrackID(_ id: UUID) -> String? { uuidTrack[id] }

    /// The stable UI UUID for an engine clip id, minting one on first sight.
    func clipUUID(forEngineID id: String) -> UUID { uuid(forClip: id) }

    /// The stable UI UUID for an engine track id, minting one on first sight.
    func trackUUID(forEngineID id: String) -> UUID { uuid(forTrack: id) }

    /// The FFI facade, for the note seam in the sibling file. Same instance the
    /// arrangement uses, so both surfaces drive one host.
    var noteClient: EngineClient { client }

    private func uuid(forTrack id: String) -> UUID {
        if let u = trackUUID[id] { return u }
        let u = UUID()
        trackUUID[id] = u
        uuidTrack[u] = id
        return u
    }

    private func uuid(forClip id: String) -> UUID {
        if let u = clipUUID[id] { return u }
        let u = UUID()
        clipUUID[id] = u
        uuidClip[u] = id
        return u
    }

    /// Deterministic 64-bit seed from an asset hash (FNV-1a), so a clip's
    /// waveform seed is stable and the tile store can find its clip.
    private func seedFor(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash | 1
    }

    private func timeSignature(_ project: EngineJSON) -> StudioTimeSignature {
        let ts = EngineJSON(project.dict("time_sig") ?? project.dict("timeSig") ?? [:])
        let num = Int(ts.int64("numerator") ?? 4)
        let den = Int(ts.int64("denominator") ?? 4)
        return StudioTimeSignature(beatsPerBar: max(1, num), beatUnit: max(1, den))
    }

    private func stemKind(_ name: String) -> StudioStemKind {
        let n = name.lowercased()
        if n.contains("voc") || n.contains("vox") { return .vocals }
        if n.contains("drum") || n.contains("perc") || n.contains("beat") { return .drums }
        if n.contains("bass") { return .bass }
        if n.contains("import") || n.contains("vo ") { return .imported }
        return .other
    }

    private func sectionRole(_ name: String) -> StudioSectionRole {
        let n = name.lowercased()
        if n.contains("verse") { return .verse }
        if n.contains("chorus") || n.contains("drop") { return .chorus }
        if n.contains("bridge") { return .bridge }
        return .neutral
    }

    private func ffiMessage(_ e: FfiError) -> String {
        switch e {
        case .NotInitialized(let m), .InvalidArgument(let m), .Io(let m), .Audio(let m),
             .Gen(let m), .RateLimited(let m), .ConfirmationRequired(let m), .Unsupported(let m):
            return m
        case .Command(_, let m):
            return m
        }
    }
    /// Metronome monitor state, through the non-catalog `studio_metronome_set`
    /// tool. Failures are swallowed on purpose: this is monitoring, and a
    /// missing click must never become an error dialog in front of someone who
    /// is trying to play.
    func setMetronome(enabled: Bool?, levelDB: Double?, countInBeats: Int?) async {
        var args: [String: Any] = [:]
        if let enabled { args["enabled"] = enabled }
        if let levelDB { args["levelDb"] = levelDB }
        if let countInBeats { args["countInBeats"] = countInBeats }
        guard !args.isEmpty else { return }
        _ = try? client.tool(name: "studio_metronome_set", args: args)
    }

}
