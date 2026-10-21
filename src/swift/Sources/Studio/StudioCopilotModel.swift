import SwiftUI

// MARK: - Sterling copilot model
//
// Observable bridge between the dock and the engine copilot loop. Owns the turn
// poll (8 Hz while a turn runs), the transcript, and the session action log.
//
// Event contract (engine copilot.rs): poll returns CUMULATIVE events with a
// monotonic `seq`; this model applies only unseen ones. Tool calls arrive as
// `tool_call_started` / `tool_call_finished` pairs keyed by `call_id` and render
// as their own rows: the trust surface. Refused calls (blocked / over-budget /
// confirm-gated) stay visible in warn color, so the person sees what Sterling
// attempted, not only what landed.

@MainActor
final class StudioCopilotModel: ObservableObject {

    // MARK: transcript types

    enum Role { case user, assistant }

    struct ChatMessage: Identifiable {
        let id = UUID().uuidString
        let role: Role
        var text: String
    }

    struct ToolRow: Identifiable {
        let id: String            // "\(turnId)-\(callId)", unique across turns
        let tool: String
        let tier: String          // read | perform | manage
        let argsSummary: String
        var ok: Bool?             // nil while running
        var resultSummary: String?
        let at: Date
        /// Timeline span this action touched, when it has one (for the chip's
        /// reveal-on-click). nil for mixer/transport ops with no locus.
        let regionStart: Int64?
        let regionEnd: Int64?

        var hasRegion: Bool { regionStart != nil }
        var isEdit: Bool { tier == "perform" || tier == "manage" }
    }

    enum Entry: Identifiable {
        case message(ChatMessage)
        case tool(ToolRow)
        var id: String {
            switch self {
            case .message(let m): return m.id
            case .tool(let r): return r.id
            }
        }
    }

    // MARK: published state

    @Published var entries: [Entry] = []
    @Published var actionLog: [ToolRow] = []
    @Published var running = false
    /// A plain note ("Stopped."). Not for provider failures - those are
    /// diagnostics, so the dock never leads with a raw error envelope again.
    @Published var statusText: String?
    /// A structured failure: headline, next step, and the provider's own message
    /// kept behind a disclosure.
    @Published var statusDiagnostic: SterlingDiagnostic?
    @Published var draft = ""
    /// Chips whose action has been undone, so the dock stops offering undo on
    /// them (undo is last-in-first-out, matching the command bus).
    @Published private(set) var undoneChipIDs: Set<String> = []

    /// The route for new turns: local Studio command-bus copilot or Brigade.
    var route: StudioCopilotRoute = .local
    /// Native FFI system-prompt override for the selected local custom agent.
    var systemPromptOverride: String?

    let backend: any StudioCopilotBackend
    private weak var viewModel: StudioViewModel?

    private var pollTimer: Timer?
    private var currentTurn: UInt64?
    private var appliedSeq = -1

    /// Client-side cursor into the engine's Sterling-trigger ring
    /// (midi.sterling.pending). nil until the first snapshot carrying a midi
    /// block; then set to that ring's `nextSeq` so triggers queued before this
    /// session never replay.
    private var midiCursor: Int?

    init(backend: any StudioCopilotBackend, viewModel: StudioViewModel) {
        self.backend = backend
        self.viewModel = viewModel
        seedDemoPreviewIfRequested()
    }

    /// Evidence hook (inert unless `--sterling-demo-preview` is passed): seed the
    /// transcript + action log with the scripted arrangement demo so the dock UI
    /// can be captured with its real chips. The live demo runs headless in the
    /// engine test; this only paints the same steps for a screenshot.
    private func seedDemoPreviewIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--sterling-demo-preview") else { return }
        let tpb: Int64 = 3840
        entries.append(.message(ChatMessage(
            role: .user,
            text: "make the outro 16 bars longer, keep the mood, and duck the bed under my VO track")))
        func chip(_ tool: String, _ tier: String, _ args: String, _ result: String, start: Int64? = nil) -> ToolRow {
            ToolRow(
                id: "preview-\(actionLog.count)", tool: tool, tier: tier, argsSummary: args,
                ok: true, resultSummary: result, at: Date(),
                regionStart: start, regionEnd: start.map { $0 + tpb })
        }
        let rows = [
            chip("studio_snapshot", "read", "{}", "2 tracks, 2 clips, 120 BPM"),
            chip("studio_section_set", "perform", "{\"name\":\"OUTRO\",\"startTicks\":15360}", "seq 6, journaled", start: 15360),
            chip("studio_clip_duplicate", "perform", "{\"clipId\":\"bed1\",\"newClipId\":\"bed_outro\"}", "seq 7, journaled", start: 15360),
            chip("studio_clip_crossfade_set", "perform", "{\"lengthTicks\":960,\"shape\":\"equalPower\"}", "seq 8, journaled"),
            chip("studio_mix_gain", "perform", "{\"trackId\":\"tbed\",\"gainDb\":-6}", "seq 9, journaled"),
        ]
        for row in rows {
            entries.append(.tool(row))
            actionLog.append(row)
        }
        entries.append(.message(ChatMessage(
            role: .assistant,
            text: "Done. Extended the outro past the old ending, crossfaded the seam, and ducked the bed 6 dB under the VO. Say the word and I'll undo it.")))
    }

    // MARK: derived

    var available: Bool { backend.isAvailable }

    /// The one chip that still offers undo: the newest landed edit not yet
    /// undone (LIFO, so only the top of Sterling's stack is reversible here).
    var undoableChipID: String? {
        actionLog.last(where: { $0.isEdit && $0.ok == true && !undoneChipIDs.contains($0.id) })?.id
    }

    // MARK: actions

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        draft = ""
        sendText(text)
    }

    func sendText(_ text: String) {
        guard !running else { return }
        entries.append(.message(ChatMessage(role: .user, text: text)))
        clearStatus()
        do {
            let turnId = try backend.send(StudioCopilotSendRequest(
                text: text,
                route: route,
                systemPromptOverride: route.isBrigade ? nil : systemPromptOverride
            ))
            currentTurn = turnId
            appliedSeq = -1
            running = true
            startPolling(turnId)
        } catch {
            // localizedDescription, not String(describing:) - the latter prints
            // the enum CASE name and drops the sentence the error carries.
            statusText = error.localizedDescription
        }
    }

    /// Reset both status channels together, so a stale diagnostic never outlives
    /// the failure it described.
    func clearStatus() {
        statusText = nil
        statusDiagnostic = nil
    }

    /// The endpoint/model/key-family the current turn ran against. Only a key
    /// FAMILY LABEL crosses this boundary, never key material.
    static func currentContext() -> SterlingEndpointContext {
        SterlingEndpointContext(
            endpoint: SterlingConfig.endpoint,
            model: SterlingConfig.model,
            key: SterlingKeychain.key()
        )
    }

    // MARK: MIDI triggers (M5)
    //
    // A MIDI control bound to a `sterling` target does not run a command; the
    // engine pushes {seq, instruction, bindingId, port} onto a bounded ring
    // (midi.sterling.pending). The dock drives this drain off the view model's
    // existing snapshot, so a physical pad becomes a shortcut for the AGENT:
    // each new item runs as a Sterling turn through the SAME backend.send a typed
    // message uses, so the resulting edit journals as the agent (the engine
    // stamps agent/sterling), never the human. Nothing here makes sound.

    /// The drain loop the dock starts once (spec 8). ~4 Hz. SwiftUI cancels it
    /// when the dock disappears.
    func runMidiTriggerDrain() async {
        while !Task.isCancelled {
            await drainMidiTriggerTick()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// One tick: read the ring, then drain. The read is UNGATED
    /// (ifNewerThan: nil) on purpose. A Sterling press is journal-silent (spec
    /// 8.2), so it does not bump the snapshot revision; the view model's
    /// revision-gated 30 Hz poll therefore would NOT refresh on a press while the
    /// transport is stopped, and the trigger would never be seen. So we read the
    /// engine directly, the same ungated pattern MidiSettingsView and
    /// StudioViewModel.adoptFresh use. Split from applyMidiTriggerDrain so tests
    /// can drive the cursor logic with hand-built snapshots.
    func drainMidiTriggerTick() async {
        let midi = await viewModel?.engine.snapshot(ifNewerThan: nil)?.midi
        applyMidiTriggerDrain(midi)
    }

    /// One drain step over a given midi snapshot, split out so tests drive it
    /// with hand-built snapshots.
    /// The first sight of the ring sets the cursor to `nextSeq` (pre-session
    /// items never replay). After that the oldest unseen item runs, one turn at a
    /// time; the rest wait for a later tick. A no-op when nothing is new.
    func applyMidiTriggerDrain(_ midi: StudioMidiSnapshot?) {
        guard let sterling = midi?.sterling else { return }
        guard let cursor = midiCursor else {
            midiCursor = sterling.nextSeq
            return
        }
        let fresh = sterling.pending
            .filter { $0.seq >= cursor }
            .sorted { $0.seq < $1.seq }
        guard let next = fresh.first else { return }

        guard available else {
            statusText = StudioCopilotError.unavailable.errorDescription
            midiCursor = sterling.nextSeq
            return
        }
        guard !running else { return }   // one turn at a time; retry the rest next tick

        midiCursor = next.seq + 1
        submitMidiTrigger(next, in: midi)
    }

    /// Run one ring item as a Sterling turn. The transcript shows the trigger
    /// ("MIDI trigger: <label>"); the agent receives the raw instruction.
    private func submitMidiTrigger(_ item: StudioMidiSterlingItem, in midi: StudioMidiSnapshot?) {
        entries.append(.message(ChatMessage(
            role: .user, text: "MIDI trigger: \(triggerLabel(for: item, in: midi))")))
        clearStatus()
        do {
            let turnId = try backend.send(StudioCopilotSendRequest(
                text: item.instruction,
                route: route,
                systemPromptOverride: route.isBrigade ? nil : systemPromptOverride
            ))
            currentTurn = turnId
            appliedSeq = -1
            running = true
            startPolling(turnId)
        } catch {
            statusText = error.localizedDescription
        }
    }

    /// The binding's label when the snapshot still carries it, else the
    /// instruction (trimmed) so the transcript line is always meaningful.
    private func triggerLabel(for item: StudioMidiSterlingItem, in midi: StudioMidiSnapshot?) -> String {
        if let binding = midi?.activeBindings.first(where: { $0.id == item.bindingId }),
           !binding.label.isEmpty {
            return binding.label
        }
        let trimmed = item.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(60)) + "..."
    }

    /// Stop: request cancellation; the poll observes the terminal state.
    func stop() {
        guard let turnId = currentTurn else { return }
        try? backend.cancel(turnId)
    }

    /// Clear chat: wipes engine-side memory + the transcript. The action log
    /// stays (it is the session audit trail). Refused while running.
    func clear() {
        guard !running else { return }
        try? backend.clearHistory()
        entries.removeAll()
        clearStatus()
    }

    /// Reveal a chip's affected region on the timeline (bar-snapped select +
    /// scroll into view). Uses only existing view-model state.
    func reveal(_ row: ToolRow) {
        guard let vm = viewModel, let start = row.regionStart else { return }
        let tpb = vm.timeSignature.ticksPerBar
        let end = row.regionEnd ?? (start + tpb)
        guard let region = StudioRegionSelection(rawStart: start, rawEnd: end) else { return }
        vm.selection = StudioSelection(clipIDs: [], region: region)
        vm.scrollTicks = max(0, start - tpb)   // a bar of lead-in
    }

    /// Undo a chip's action. Undo is last-in-first-out (the command bus is a
    /// linear stack), so only `undoableChipID` offers this. The view model's
    /// 30 Hz snapshot poll then redraws the reverted timeline.
    func undo(_ row: ToolRow) {
        guard row.id == undoableChipID else { return }
        do {
            if try backend.undo() {
                undoneChipIDs.insert(row.id)
            }
        } catch {
            statusText = error.localizedDescription
        }
    }

    // MARK: polling

    private func startPolling(_ turnId: UInt64) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce(turnId) }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        currentTurn = nil
        running = false
    }

    private func pollOnce(_ turnId: UInt64) {
        guard let body = try? backend.poll(turnId),
              let obj = Self.jsonObject(body)
        else {
            clearStatus()
            statusText = "Sterling's turn went missing."
            stopPolling()
            return
        }

        for event in (obj["events"] as? [[String: Any]]) ?? [] {
            let seq = (event["seq"] as? NSNumber)?.intValue ?? -1
            guard seq > appliedSeq else { continue }
            appliedSeq = seq
            apply(event, turnId: turnId)
        }

        let state = (obj["state"] as? String) ?? "failed"
        guard state != "running" else { return }
        if state == "cancelled" { statusText = "Stopped." }
        stopPolling()
    }

    private func apply(_ event: [String: Any], turnId: UInt64) {
        switch event["type"] as? String {
        case "text_delta":
            appendAssistantText((event["text"] as? String) ?? "")

        case "tool_call_started":
            let region = event["region"] as? [String: Any]
            let row = ToolRow(
                id: "\(turnId)-\((event["call_id"] as? String) ?? UUID().uuidString)",
                tool: (event["tool"] as? String) ?? "?",
                tier: (event["tier"] as? String) ?? "unknown",
                argsSummary: (event["args_summary"] as? String) ?? "",
                ok: nil,
                resultSummary: nil,
                at: Date(),
                regionStart: (region?["startTicks"] as? NSNumber)?.int64Value,
                regionEnd: (region?["endTicks"] as? NSNumber)?.int64Value
            )
            entries.append(.tool(row))
            actionLog.append(row)

        case "tool_call_finished":
            let id = "\(turnId)-\((event["call_id"] as? String) ?? "")"
            finishToolRow(
                id: id,
                ok: (event["ok"] as? Bool) ?? false,
                summary: (event["result_summary"] as? String) ?? ""
            )

        case "turn_error":
            // The engine hands up the provider's own failure text (already
            // key-scrubbed). Rendering that raw was the bug: a 401 arrived as a
            // JSON envelope in red. Classify it into something actionable and
            // keep the original behind the details disclosure.
            let message = (event["message"] as? String) ?? ""
            statusDiagnostic = .fromEngineMessage(message, context: Self.currentContext())
            statusText = nil

        default:
            break
        }
    }

    /// Text deltas extend the trailing assistant bubble; anything else since (a
    /// tool row, a user message) starts a fresh bubble, so "say then act then
    /// say" reads in true order.
    private func appendAssistantText(_ text: String) {
        guard !text.isEmpty else { return }
        if case .message(var message)? = entries.last, message.role == .assistant {
            message.text += text
            entries[entries.count - 1] = .message(message)
        } else {
            entries.append(.message(ChatMessage(role: .assistant, text: text)))
        }
    }

    private func finishToolRow(id: String, ok: Bool, summary: String) {
        if let index = entries.lastIndex(where: { entry in
            if case .tool(let row) = entry { return row.id == id }
            return false
        }), case .tool(var row) = entries[index] {
            row.ok = ok
            row.resultSummary = summary
            entries[index] = .tool(row)
        }
        if let index = actionLog.lastIndex(where: { $0.id == id }) {
            actionLog[index].ok = ok
            actionLog[index].resultSummary = summary
        }
    }

    static func jsonObject(_ body: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    }
}
