import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings ▸ MIDI tab (spec 7.3, 12.5). Shows controller ports, active
/// maps, current bindings, the MIDI learn state, and the last event monitor.
///
/// Read-model surface: mutations dispatch through .catalog(name:params:) on
/// the shared engine hub (spec 7.2), keeping the Swift layer stateless.
struct MidiSettingsView: View {
    @StateObject private var hub = StudioEngineHub.shared
    @State private var snapshot: StudioProjectSnapshot?
    @State private var showLearnSheet = false
    @State private var selectedMapKey: String?

    var body: some View {
        let midi = snapshot?.midi
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header.padding(.bottom, 4)
                portSection(midi)
                divider
                mapSection(midi)
                divider
                bindingSection(midi)
                divider
                learnSection(midi)
                divider
                monitorSection(midi)
            }
            .padding(24)
        }
        .background(StudioTokens.bg)
        .foregroundColor(StudioTokens.text)
        .task {
            // Spec 7.1: the tab drives the shared session engine and runs a
            // light 2 Hz poll while visible (MIDI Learn capture and the Monitor
            // need sub-second echo). SwiftUI cancels this task on disappear.
            if hub.engine == nil { hub.engine = StudioEngineFactory.shared }
            while !Task.isCancelled {
                await reloadSnapshot()
                try? await Task.sleep(nanoseconds: 500_000_000)   // 2 Hz
            }
        }
        .sheet(isPresented: $showLearnSheet) {
            MidiLearnSheet(midi: midi, hub: hub, onDone: { Task { await reloadSnapshot() } })
        }
    }

    private func reloadSnapshot() async {
        snapshot = await hub.currentSnapshot
    }

    private func sendCatalog(_ name: String, params: [String: AnyHashable] = [:]) {
        Task {
            _ = await hub.engine?.send(.catalog(name: name, params: params))
            await reloadSnapshot()
        }
    }

    /// The control matcher as wire params. Omits `number` for channel-wide
    /// controls (pitchBend) rather than coercing nil to 0, so replace/clear
    /// match the engine's stored control exactly.
    private func controlParams(_ c: StudioMidiControl) -> [String: AnyHashable] {
        var control: [String: AnyHashable] = ["type": c.type, "channel": c.channel]
        if let number = c.number { control["number"] = number }
        return control
    }

    /// Full binding.set envelope for a re-send (the enabled toggle). Carries the
    /// WHOLE target — params for command placeholders, instruction for sterling —
    /// plus the binding's own port as `device`, because binding.set is
    /// create-or-replace (spec 1.1): a partial target would wipe those fields,
    /// and the engine requires a device. valueMap is not carried because the
    /// engine does not emit it in the binding snapshot (tracked follow-up).
    private func bindingSetParams(_ b: StudioMidiBinding, enabled: Bool) -> [String: AnyHashable] {
        var target: [String: AnyHashable] = ["kind": b.target.kind.rawValue]
        if let name = b.target.name { target["name"] = name }
        if let params = b.target.params { target["params"] = params }
        if let instruction = b.target.instruction { target["instruction"] = instruction }
        var out: [String: AnyHashable] = [
            "label": b.label, "enabled": enabled,
            "control": controlParams(b.match), "target": target,
        ]
        if !b.port.isEmpty { out["device"] = b.port }
        return out
    }

    /// Spec 7.3.2: pick a `.json` map file, then dispatch midi.map.import with
    /// the required `sourcePath`.
    private func importMap() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sendCatalog("midi.map.import", params: ["sourcePath": url.path])
        }
    }

    /// Spec 7.3.2: pick a destination, then dispatch midi.map.export with the
    /// required `map` (selected map key) + `outputPath`.
    private func exportMap() {
        guard let key = selectedMapKey else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(key).json"
        if panel.runModal() == .OK, let url = panel.url {
            sendCatalog("midi.map.export", params: ["map": key, "outputPath": url.path])
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MIDI Control Surface")
                .font(.title2.weight(.semibold))
            Text("Configure controller ports, manage bindings, and learn new assignments.")
                .font(.subheadline.italic())
                .foregroundColor(StudioTokens.dim)
        }
    }

    private var divider: some View {
        Divider().overlay(StudioTokens.stroke)
    }

    // MARK: - 1. Controllers (Ports)

    @ViewBuilder
    private func portSection(_ midi: StudioMidiSnapshot?) -> some View {
        sectionHeader("Controllers", icon: "cable.connector")
        if let midi, !midi.ports.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(midi.ports) { port in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(port.connected ? StudioTokens.good : StudioTokens.faint)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(port.name)
                                .font(.body.weight(.medium))
                            if let source = port.source {
                                Text(source)
                                    .font(.caption)
                                    .foregroundColor(StudioTokens.dim)
                            }
                        }
                        Spacer()
                        if let map = port.map {
                            Text(map)
                                .font(.caption)
                                .foregroundColor(StudioTokens.cyan)
                        }
                        if let override_ = port.override {
                            Text("Override: \(override_)")
                                .font(.caption2)
                                .foregroundColor(StudioTokens.warn)
                        }
                        if let reason = port.unsupportedReason {
                            Text("⚠ \(reason)")
                                .font(.caption2)
                                .foregroundColor(StudioTokens.bad)
                        }
                        roleControl(port)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(StudioTokens.panel)
                    .cornerRadius(6)
                }
            }
        } else {
            emptyHint("No controller ports detected. Connect a MIDI device and ensure the engine is running.")
        }
    }

    /// What this port's KEYS do.
    ///
    /// The default is Keys play notes, and it matters: the bundled SX-KC211 map
    /// binds sixteen NOTES between C2 and D4 — middle C included — to transport,
    /// record, undo, redo, mixer gain and Sterling. With an instrument audible,
    /// playing middle C would fire "Sterling: add a layer" instead of sounding.
    /// Nothing is deleted by the default: this control puts every one of those
    /// bindings back, in one click, and the choice persists per port.
    ///
    /// Deliberately a segmented Picker and NOT anything inside a horizontal
    /// ScrollView: on macOS that silently eats clicks (SettingsView.swift's tab
    /// strip cost this codebase days over exactly that).
    @ViewBuilder
    private func roleControl(_ port: StudioMidiPort) -> some View {
        Picker("", selection: Binding(
            get: { port.role },
            set: { newRole in
                guard newRole != port.role else { return }
                sendCatalog("midi.port.role.set", params: ["port": port.name, "role": newRole])
            }
        )) {
            Text("Keys play").tag("instrument")
            Text("Control surface").tag("control")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 210)
        .help("Keys play: notes go to the instrument track (note-matched control bindings are suppressed; CC bindings still work). Control surface: every binding fires and the keys make no sound.")
        .accessibilityLabel("Role for \(port.name)")
    }

    // MARK: - 2. Mappings (Maps)

    @ViewBuilder
    private func mapSection(_ midi: StudioMidiSnapshot?) -> some View {
        sectionHeader("Mappings", icon: "square.grid.3x2")
        if let midi, !midi.maps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(midi.maps) { map in
                    mapRow(map)
                }
                HStack(spacing: 8) {
                    Button("Import Map…") { importMap() }
                    .buttonStyle(.bordered)
                    .tint(StudioTokens.purple)
                    Button("Export Map…") { exportMap() }
                    .buttonStyle(.bordered)
                    .tint(StudioTokens.cyan)
                    .disabled(selectedMapKey == nil)
                }
                .padding(.top, 4)
            }
        } else {
            emptyHint("No MIDI maps loaded. Import a map or connect a supported controller.")
        }
    }

    private func mapRow(_ map: StudioMidiMap) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(map.name)
                        .font(.body.weight(.medium))
                    if map.tested {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(StudioTokens.good)
                            .font(.caption)
                    }
                }
                HStack(spacing: 8) {
                    Text(map.key)
                        .font(.caption2)
                        .foregroundColor(StudioTokens.dim)
                    Text("\(map.bindingCount) bindings")
                        .font(.caption2)
                        .foregroundColor(StudioTokens.faint)
                    Text(map.source)
                        .font(.caption2)
                        .foregroundColor(StudioTokens.cyan)
                }
            }
            Spacer()
            if let error = map.loadError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(StudioTokens.bad)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(StudioTokens.panel)
        .cornerRadius(6)
        .onTapGesture { selectedMapKey = map.key }
    }

    // MARK: - 3. Active Bindings

    @ViewBuilder
    private func bindingSection(_ midi: StudioMidiSnapshot?) -> some View {
        sectionHeader("Active Bindings", icon: "table")
        if let midi, !midi.activeBindings.isEmpty {
            VStack(spacing: 0) {
                ForEach(midi.activeBindings) { binding in
                    bindingRow(binding, ports: midi.ports)
                }
            }
        } else {
            emptyHint("No active MIDI bindings. Use MIDI Learn or import a map to create assignments.")
        }
    }

    private func bindingRow(_ binding: StudioMidiBinding, ports: [StudioMidiPort]) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { binding.enabled },
                set: { _ in
                    sendCatalog("midi.binding.set",
                                params: bindingSetParams(binding, enabled: !binding.enabled))
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(StudioTokens.purple)
            .scaleEffect(0.75)

            VStack(alignment: .leading, spacing: 1) {
                Text(binding.label)
                    .font(.body.weight(.medium))
                if binding.target.kind == .sterling {
                    // Sterling row (spec 8.5): the instruction is editable and
                    // commits via midi.binding.set, the same create-or-replace
                    // path the enabled toggle uses.
                    SterlingInstructionField(instruction: binding.target.instruction ?? "") { newText in
                        var edited = binding
                        edited.target.instruction = newText
                        sendCatalog("midi.binding.set",
                                    params: bindingSetParams(edited, enabled: binding.enabled))
                    }
                } else {
                    Text(binding.targetSummary ?? binding.target.name ?? "")
                        .font(.caption)
                        .foregroundColor(StudioTokens.cyan)
                }
                if binding.suppressedByRole {
                    // Say it on the row. Silently listing a binding that cannot
                    // fire is the same lie as a green check on a dead path.
                    Text("Not firing — this key plays the instrument. Switch the port to Control surface to use it.")
                        .font(.caption2)
                        .foregroundColor(StudioTokens.warn)
                }
            }
            Spacer()
            Text(controlLabel(binding.match))
                .font(.caption2)
                .foregroundColor(StudioTokens.dim)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(StudioTokens.panelHi)
                .cornerRadius(4)

            Button {
                sendCatalog("midi.binding.clear", params: [
                    "device": binding.port.isEmpty ? (ports.first?.name ?? "") : binding.port,
                    "control": controlParams(binding.match),
                ])
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(StudioTokens.faint)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(StudioTokens.panel)
        .cornerRadius(4)
    }

    private func controlLabel(_ c: StudioMidiControl) -> String {
        let num = c.number.map { " #\($0)" } ?? ""
        return "\(c.type) ch\(c.channel)\(num)"
    }

    // MARK: - 4. MIDI Learn

    @ViewBuilder
    private func learnSection(_ midi: StudioMidiSnapshot?) -> some View {
        sectionHeader("MIDI Learn", icon: "waveform.path.ecg")
        let learn = midi?.learn
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if learn?.active == true {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(StudioTokens.bad)
                            .frame(width: 8, height: 8)
                        Text("Listening…")
                            .font(.body.weight(.medium))
                            .foregroundColor(StudioTokens.warn)
                    }
                    if let captured = learn?.captured {
                        Text("Captured: \(captureDesc(captured))")
                            .font(.caption)
                            .foregroundColor(StudioTokens.good)
                    }
                } else {
                    Text("Idle")
                        .font(.body.weight(.medium))
                        .foregroundColor(StudioTokens.dim)
                }
                Spacer()
                Button(learn?.active == true ? "Stop" : "Start") {
                    if learn?.active == true {
                        sendCatalog("midi.learn.stop")
                    } else {
                        sendCatalog("midi.learn.start", params: ["device": midi?.ports.first?.name ?? ""])
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(learn?.active == true ? StudioTokens.bad : StudioTokens.good)
            }
            if let age = learn?.ageSeconds {
                Text("\(String(format: "%.1f", age))s elapsed")
                    .font(.caption)
                    .foregroundColor(StudioTokens.faint)
            }
        }
        .padding(10)
        .background(StudioTokens.panel)
        .cornerRadius(8)
    }

    private func captureDesc(_ d: [String: AnyHashable]) -> String {
        let type = d["type"] as? String ?? ""
        let ch = d["channel"] as? Int ?? 0
        let num = d["number"] as? Int
        let rest = num.map { " #\($0)" } ?? ""
        return "\(type) ch\(ch)\(rest)"
    }

    // MARK: - 5. Monitor

    @ViewBuilder
    private func monitorSection(_ midi: StudioMidiSnapshot?) -> some View {
        sectionHeader("Monitor", icon: "antenna.radiowaves.left.and.right")
        if let event = midi?.lastEvent {
            HStack(spacing: 16) {
                Label("Seq \(event.seq)", systemImage: "number")
                    .font(.caption)
                    .foregroundColor(StudioTokens.dim)
                Text(event.port)
                    .font(.caption.weight(.medium))
                    .foregroundColor(StudioTokens.cyan)
                Text("\(event.type) ch\(event.channel)")
                    .font(.caption)
                    .foregroundColor(StudioTokens.purple)
                if let num = event.number {
                    Text("#\(num)")
                        .font(.caption)
                        .foregroundColor(StudioTokens.warn)
                }
                Text("val \(event.value)")
                    .font(.caption)
                    .foregroundColor(StudioTokens.good)
                Spacer()
            }
            .padding(10)
            .background(StudioTokens.panel)
            .cornerRadius(8)
        } else {
            emptyHint("No MIDI events received. Wiggle a controller or send a note.")
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(StudioTokens.purple)
            Text(title)
                .font(.headline.weight(.semibold))
        }
        .padding(.vertical, 4)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(StudioTokens.faint)
            .padding(.vertical, 8)
    }
}

// MARK: - MIDI Learn Sheet

struct MidiLearnSheet: View {
    let midi: StudioMidiSnapshot?
    let hub: StudioEngineHub
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("MIDI Learn")
                .font(.title3.weight(.semibold))
            Text("Move a control on your controller to capture it, then choose an action.")
                .font(.subheadline)
                .foregroundColor(StudioTokens.dim)
                .multilineTextAlignment(.center)

            if let captured = midi?.learn.captured {
                VStack(spacing: 4) {
                    Text("Captured:")
                        .font(.caption)
                        .foregroundColor(StudioTokens.dim)
                    Text(MidiLearnSheet.captureDescMid(captured))
                        .font(.title2.weight(.medium))
                        .foregroundColor(StudioTokens.good)
                }
                .padding()
                .background(StudioTokens.panel)
                .cornerRadius(8)
            } else {
                HStack(spacing: 6) {
                    Circle().fill(StudioTokens.bad).frame(width: 8, height: 8)
                    Text("Listening…")
                        .foregroundColor(StudioTokens.warn)
                }
            }

            Button("Done") { onDone() }
                .buttonStyle(.borderedProminent)
                .tint(StudioTokens.purple)
        }
        .padding(24)
        .frame(width: 340)
        .background(StudioTokens.bg)
        .foregroundColor(StudioTokens.text)
    }

    /// Shared helper for Learn Sheet display.
    static func captureDescMid(_ d: [String: AnyHashable]) -> String {
        let type = d["type"] as? String ?? ""
        let ch = d["channel"] as? Int ?? 0
        let num = d["number"] as? Int
        let rest = num.map { " #\($0)" } ?? ""
        return "\(type) ch\(ch)\(rest)"
    }
}

// MARK: - Sterling instruction field (M5)

/// The editable instruction cell for a Sterling-trigger binding in the Active
/// Bindings table. Holds its own draft so the 2 Hz settings poll never clobbers
/// mid-edit; commits on Return or when focus leaves, and only when the text
/// actually changed (binding.set is create-or-replace, so a no-op re-send is
/// skipped). Resyncs from engine truth when it is not being edited.
private struct SterlingInstructionField: View {
    let instruction: String
    let commit: (String) -> Void

    @State private var draft: String
    @State private var lastCommitted: String
    @FocusState private var focused: Bool

    init(instruction: String, commit: @escaping (String) -> Void) {
        self.instruction = instruction
        self.commit = commit
        _draft = State(initialValue: instruction)
        _lastCommitted = State(initialValue: instruction)
    }

    var body: some View {
        TextField("Sterling instruction", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.caption)
            .foregroundColor(StudioTokens.cyan)
            .lineLimit(1...3)
            .focused($focused)
            .onSubmit { commitIfChanged() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commitIfChanged() }
            }
            .onChange(of: instruction) { _, newValue in
                // Engine truth changed while we are not editing: adopt it.
                if !focused, newValue != draft {
                    draft = newValue
                    lastCommitted = newValue
                }
            }
    }

    private func commitIfChanged() {
        guard draft != lastCommitted else { return }
        lastCommitted = draft
        commit(draft)
    }
}
