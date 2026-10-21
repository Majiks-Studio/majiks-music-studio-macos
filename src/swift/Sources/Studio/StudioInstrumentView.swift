import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - The instrument panel: where a sound gets into a sampler or a drum rack
//
// WHY THIS EXISTS.
//
// The multi-zone sampler and the sixteen-pad drum rack have been finished,
// RT-safe and covered by tests for a long time. They were also completely
// unreachable: `device.add` could create one, `device.zone.add` could bind a
// sound to it, and NOTHING in the app could call the second one. The only
// instrument a person could make from the GUI was a Synth. A vault of 13,971
// recordings — 5,888 drum one-shots among them — was not playable from a
// keyboard at all, because there was no way to put one into an instrument.
//
// This panel is the other half of that. It is deliberately small: load a sound,
// see what is loaded, change it, clear it. It is NOT a zone-mapping editor and
// NOT a waveform editor.
//
// WHERE THE SOUNDS COME FROM. `NSOpenPanel`, and Finder drops onto a pad.
// Both hand the engine a LOCAL PATH, which is all the engine ever wants: it
// decodes, content-addresses, and stores the bytes itself. That is also why a
// vault browser can be added later without touching anything here — a remote
// asset downloaded to a cache is just another path.
//
// THE GRID IS BUTTONS, NOT A CANVAS, and that is a considered exception to the
// "draw dense repeats with Canvas" rule the piano roll and the on-screen
// keyboard set. That rule is about HUNDREDS of elements (128 keys, thousands of
// notes) whose only job is to be drawn. This is sixteen large targets that each
// need their own hover help, their own accessibility label, their own context
// menu and their own file-drop target; a Canvas would mean hand-rolling all
// four. And it is a `LazyVGrid` with no horizontal `ScrollView` anywhere near
// it — a pad grid is exactly the shape that tempts one, and on macOS a
// horizontal ScrollView silently eats Button clicks.

// MARK: - Picking files

enum StudioSoundPicker {
    /// One audio file, or nil if the person cancelled.
    @MainActor
    static func pickOne(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = prompt
        panel.prompt = "Load"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Several audio files, in the order the panel reports them.
    @MainActor
    static func pickMany(prompt: String) -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = prompt
        panel.prompt = "Load"
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }

    /// Pick a folder; returns all audio files inside, sorted.
    @MainActor
    static func pickFolder(prompt: String) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = prompt
        panel.prompt = "Load Kit"
        guard panel.runModal() == .OK, let url = panel.url else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.typeIdentifierKey],
                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var audioFiles: [String] = []
        let audioTypes: Set = ["public.mp3", "public.wav", "public.aiff", "public.aac",
                               "com.apple.coreaudio-format", "com.apple.m4a-audio"]
        for case let fileURL as URL in enumerator {
            guard let type = try? fileURL.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                  audioTypes.contains(type) else { continue }
            audioFiles.append(fileURL.path)
        }
        return audioFiles.sorted()
    }
}

// MARK: - The panel

struct StudioInstrumentView: View {
    @ObservedObject var model: StudioViewModel
    let trackID: UUID
    @Binding var isPresented: Bool
    /// Test-only initial state for the deterministic ImageRenderer proof. The
    /// production sheet leaves the disclosure closed, as a person expects;
    /// the proof opens it before rasterizing the shipped panel.
    let initiallyShowsRawControls: Bool

    init(model: StudioViewModel, trackID: UUID, isPresented: Binding<Bool>,
         initiallyShowsRawControls: Bool = false) {
        self.model = model
        self.trackID = trackID
        self._isPresented = isPresented
        self.initiallyShowsRawControls = initiallyShowsRawControls
    }

    private var track: StudioTrackSnapshot? {
        model.snapshot?.tracks.first(where: { $0.id == trackID })
    }
    private var device: StudioDeviceSnapshot? { track?.devices.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if let device, device.playsSamples {
                        if device.kind == "drum" {
                            StudioDrumPadGrid(model: model, trackID: trackID, device: device)
                        } else {
                            samplerBody(device)
                        }
                    } else if let device, device.makesItsOwnSound {
                        StudioSynthToneEditor(
                            model: model, trackID: trackID, device: device,
                            initiallyShowsRawControls: initiallyShowsRawControls)
                    } else {
                        // A snapshot can change underneath a sheet — a track's
                        // instrument can be removed from the context menu while this is
                        // open.
                        Text(device == nil
                             ? "This track has no instrument any more."
                             : "There is nothing to change on this instrument.")
                            .font(.system(size: 12))
                            .foregroundStyle(StudioTokens.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            footer
        }
        .padding(16)
        .frame(width: 460, height: panelHeight)
        .background(StudioTokens.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Instrument for \(track?.name ?? "this track")")
    }

    /// The sheet height is stable for the surrounding macOS presentation. Its
    /// content is deliberately vertical-scrollable, so the height is no
    /// longer a guessed promise that every future control will fit. The footer
    /// stays outside the scroll view and is therefore always inside the panel.
    private var panelHeight: CGFloat {
        switch device?.kind {
        case "drum": return 520
        case "synth": return 600
        default: return 340
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((device?.instrumentLabel ?? "Instrument").uppercased())
                .font(.system(size: 10, weight: .bold))
                .kerning(1)
                .foregroundStyle(StudioTokens.faint)
            Text(track?.name ?? "Track")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(StudioTokens.text)
        }
    }

    private var footer: some View {
        HStack {
            Text("Every change here is one step. Cmd-Z takes it back.")
                .font(.system(size: 10.5))
                .foregroundStyle(StudioTokens.faint)
                .lineLimit(1)
                .fixedSize()
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
                // help-exempt: "Done" closes the panel it is inside, and a
                // tooltip that says so teaches nothing (help rule 3).
                .accessibilityLabel("Close the instrument panel")
        }
    }

    // MARK: Sampler

    @ViewBuilder
    private func samplerBody(_ device: StudioDeviceSnapshot) -> some View {
        Text("This instrument plays a recording. Which key you press decides how fast it " +
             "plays back, which is what makes it a pitched instrument rather than a sound effect.")
            .font(.system(size: 11))
            .foregroundStyle(StudioTokens.dim)
            .fixedSize(horizontal: false, vertical: true)

        ForEach(device.zones) { zone in
            zoneCard(device: device, zone: zone)
        }

        if device.zones.count > 1 {
            Text("\(device.zones.count) sounds are mapped across the keyboard. " +
                 "The lowest zone covering a key is the one you hear.")
                .font(.system(size: 10.5))
                .foregroundStyle(StudioTokens.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func zoneCard(device: StudioDeviceSnapshot, zone: StudioZoneSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTokens.cyan)
                Text(model.soundName(zone.sourceID) ?? "Sound not found")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.soundName(zone.sourceID) == nil
                                     ? StudioTokens.faint : StudioTokens.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Replace…") {
                    guard let path = StudioSoundPicker.pickOne(
                        prompt: "Pick the recording this instrument should play.") else { return }
                    model.replaceSamplerSound(
                        trackID: trackID, deviceID: device.id, zone: zone, path: path)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTokens.cyan)
                .studioHelp("instrument.sampler.replace")
                .accessibilityLabel("Replace this sound")
            }

            Text(zone.isFullRange
                 ? "Answers every key on the keyboard."
                 : "Answers \(StudioPitchName.name(zone.loPitch)) to \(StudioPitchName.name(zone.hiPitch)).")
                .font(.system(size: 10.5))
                .foregroundStyle(StudioTokens.faint)

            HStack(spacing: 8) {
                Text("Original key")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTokens.dim)
                Spacer(minLength: 8)
                Text(StudioPitchName.name(zone.rootPitch))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(StudioTokens.text)
                    .frame(width: 40, alignment: .trailing)
                Stepper("Original key", value: Binding(
                    get: { zone.rootPitch },
                    set: { model.setZoneRootPitch(trackID: trackID, deviceID: device.id,
                                                  zone: zone, rootPitch: $0) }
                ), in: 0...127)
                .labelsHidden()
            }
            .studioHelp("instrument.sampler.rootKey")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Original key")
            .accessibilityValue(StudioPitchName.name(zone.rootPitch))
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTokens.panelHi)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTokens.stroke, lineWidth: 1))
    }
}

// MARK: - The tone editor: what a Synth SOUNDS like
//
// WHY THIS EXISTS.
//
// The synth has had four waveforms, a resonant low-pass and a full ADSR since
// E2 — every one of them per-note, RT-safe and already automatable through
// `track.device.<deviceId>.<paramKey>`. And no catalog command could write one,
// so the app's only instrument sound was `Waveform::Saw`, the harshest of the
// four, for everyone, permanently. The comment at the top of this file said the
// panel was "NOT a waveform editor" and it was right, which was the problem.
//
// `device.param.set` is the missing verb. This is the surface on it.
//
// NAMED SOUNDS FIRST. The person this was built for does not know what a
// sawtooth is and asked for "something nicer, like piano, so I can actually
// play something". A row of five named buttons answers that; four sliders and a
// waveform enum do not. The raw controls are underneath, collapsed, for anyone
// who wants them — which is the same shape the mixer's channel EQ uses.
//
// AND NOTHING HERE IS A PIANO. This app ships no instrument samples, so a
// sampled acoustic piano is not a thing a preset can be. "Electric Piano" is
// the honest name for a synthesized imitation, and the panel says so in words
// rather than leaving a person to discover it by ear.
//
// A ROW OF BUTTONS IN AN HStack + LazyVGrid, explicitly NOT a horizontal
// ScrollView: on macOS a horizontal ScrollView silently eats Button clicks, the
// lesson SettingsView.swift's tab strip paid for.

struct StudioSynthToneEditor: View {
    @ObservedObject var model: StudioViewModel
    let trackID: UUID
    let device: StudioDeviceSnapshot

    @State private var showsRawControls = false

    init(model: StudioViewModel, trackID: UUID, device: StudioDeviceSnapshot,
         initiallyShowsRawControls: Bool = false) {
        self.model = model
        self.trackID = trackID
        self.device = device
        self._showsRawControls = State(initialValue: initiallyShowsRawControls)
    }

    private var stored: [String: Double] { device.params }
    private var current: StudioInstrumentPreset? { StudioInstrumentTone.current(for: stored) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A Synth makes its own sound rather than playing a recording, so this is " +
                 "where you choose what that sound is. Every one of these is a starting " +
                 "point — pick one, play a key, and change it below if you want to.")
                .font(.system(size: 11))
                .foregroundStyle(StudioTokens.dim)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                      spacing: 8) {
                ForEach(StudioInstrumentTone.presets) { preset in
                    presetButton(preset)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sounds")

            Text(current.map { "Playing: \($0.name)." } ?? StudioInstrumentTone.startingSound)
                .font(.system(size: 10.5))
                .foregroundStyle(StudioTokens.faint)
                .fixedSize(horizontal: false, vertical: true)

            // The honesty line. Not a footnote: "piano" is what was asked for
            // and this is the sentence that stops the answer being a lie.
            Text("None of these is a recording of a real instrument — this app has no " +
                 "instrument recordings. They are sounds built from scratch that imitate one.")
                .font(.system(size: 10))
                .foregroundStyle(StudioTokens.faint)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(StudioTokens.stroke)

            Button {
                showsRawControls.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showsRawControls ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("Shape it yourself")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(StudioTokens.cyan)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .studioHelp("instrument.tone.raw")
            .accessibilityLabel(showsRawControls ? "Hide the individual controls"
                                                 : "Show the individual controls")

            if showsRawControls {
                rawControls
            }
        }
    }

    // MARK: The named sounds

    private func presetButton(_ preset: StudioInstrumentPreset) -> some View {
        let selected = current?.id == preset.id
        return Button {
            model.applyInstrumentPreset(trackID: trackID, deviceID: device.id, preset)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudioTokens.text)
                Text(preset.blurb)
                    .font(.system(size: 9.5))
                    .foregroundStyle(StudioTokens.faint)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .background(selected ? StudioTokens.purple.opacity(0.24) : StudioTokens.panelHi)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                selected ? StudioTokens.purple : StudioTokens.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Inline rather than a catalog id: the useful half of this sentence is
        // the preset's OWN description, which no static entry can carry. The
        // shape `trackHeader`'s instrument chip already uses.
        .studioHelp(
            terse: preset.name,
            teaching: "\(preset.blurb) One click changes the whole sound of this instrument, " +
                "and one Cmd-Z puts the old one back.")
        .accessibilityLabel(preset.name)
        .accessibilityValue(selected ? "playing" : "")
        .accessibilityHint(preset.blurb)
    }

    // MARK: The raw controls, for anyone who wants them

    @ViewBuilder
    private var rawControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Tone")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTokens.dim)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 52, alignment: .leading)
                // Plain Buttons in an HStack — never a horizontal ScrollView.
                ForEach(StudioInstrumentTone.waveforms, id: \.value) { wave in
                    waveformChip(wave)
                }
                Spacer(minLength: 0)
            }
            .studioHelp("instrument.tone.waveform")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tone")

            // `unit:` is what tells the typed field's arrows that brightness
            // steps by a SEMITONE rather than by 1 Hz. 200 Hz to 16 kHz is
            // 6 1/3 octaves; a 1 Hz arrow would need 15,800 presses to cross
            // it, and be inaudible for the whole of the top octave.
            paramSlider(key: "cutoff", label: "Brightness", range: 200...16000,
                        helpID: "instrument.tone.cutoff", unit: .hertz,
                        format: { "\(Int($0)) Hz" })

            ForEach(StudioInstrumentTone.envelope) { stage in
                paramSlider(key: stage.id, label: stage.label, range: stage.range,
                            helpID: "instrument.tone.envelope",
                            unit: StudioParamUnit.forSpecUnit(stage.unit),
                            format: { stage.unit.isEmpty
                                ? String(format: "%.2f", $0)
                                : String(format: "%.3f %@", $0, stage.unit) })
            }
        }
    }

    private func waveformChip(_ wave: (value: Double, name: String, blurb: String)) -> some View {
        let selected = StudioInstrumentTone.value("waveform", in: stored).rounded() == wave.value
        return Button {
            model.setInstrumentParam(trackID: trackID, deviceID: device.id,
                                     key: "waveform", value: wave.value)
        } label: {
            Text(wave.name)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? StudioTokens.purple.opacity(0.30) : StudioTokens.panelHi))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? StudioTokens.purple : StudioTokens.stroke, lineWidth: 0.8))
                .foregroundStyle(StudioTokens.text)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .studioHelp(terse: wave.name, teaching: wave.blurb)
        .accessibilityLabel(wave.name)
        .accessibilityValue(selected ? "in use" : "")
    }

    /// One raw instrument control. Returns the concrete `StudioParamSlider`
    /// rather than `some View` so `StudioTypedControlTests` can drive the REAL
    /// slider's typed field into the real `device.param.set` — the same reason
    /// the mixer strips and the FX editor expose theirs.
    func paramSlider(key: String, label: String, range: ClosedRange<Double>,
                     helpID: String, unit: StudioParamUnit,
                     format: @escaping (Double) -> String) -> StudioParamSlider {
        StudioParamSlider(
            label: label,
            value: StudioInstrumentTone.value(key, in: stored),
            range: range,
            helpID: helpID,
            unit: unit,
            format: format,
            onCommit: { v in
                model.setInstrumentParam(trackID: trackID, deviceID: device.id,
                                         key: key, value: v)
            })
    }
}

/// One raw instrument parameter, as a labelled slider with its value in words.
///
/// COMMITS ON RELEASE, not on every frame of the drag, and that is not a
/// performance nicety: a `device.param.set` per pixel would be a hundred journal
/// entries and a hundred Cmd-Z presses to undo one gesture. The `drag` /
/// `pending` pair is the same shape `StudioFaderControl` uses — `drag` is what
/// the finger is doing, `pending` is what has been sent and not yet confirmed by
/// a snapshot, and engine truth wins the moment it catches up. Showing engine
/// truth during the drag would make the knob fight the hand.
struct StudioParamSlider: View {
    let label: String
    /// Engine truth: the device's stored value, or the DSP default when the key
    /// is absent (params are sparse — an unset key is NOT zero).
    let value: Double
    let range: ClosedRange<Double>
    let helpID: String
    /// What kind of number this is, for the typed field beside the slider.
    /// Same `StudioParamUnit` the mixer's knobs use — one parser, one stepping
    /// rule, three primitives.
    let unit: StudioParamUnit
    let format: (Double) -> String
    let onCommit: (Double) -> Void

    @State private var drag: Double?
    @State private var pending: Double?

    private var shown: Double {
        let v = drag ?? pending ?? value
        return Swift.min(Swift.max(v, range.lowerBound), range.upperBound)
    }

    /// The typed field beside the slider, exposed so a test can drive the REAL
    /// one — same range, same unit, same commit closure the body installs.
    func typedField() -> StudioTypedValueField {
        StudioTypedValueField(
            value: shown, range: range, unit: unit, format: format,
            label: label, fieldWidth: 56,
            onCommit: { v in
                pending = v
                drag = nil
                onCommit(v)
            })
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(StudioTokens.dim)
                .frame(width: 52, alignment: .leading)
            Slider(
                value: Binding(get: { shown }, set: { drag = $0 }),
                in: range,
                onEditingChanged: { editing in
                    guard !editing, let v = drag else { return }
                    pending = v
                    drag = nil
                    onCommit(v)
                })
                .controlSize(.mini)
            // The static readout that used to sit here is the typed field now.
            // Not a second control beside it: a number you can read and a
            // number you can type, one pixel apart, is how a person ends up
            // typing into the dead one.
            typedField()
        }
        .studioHelp(helpID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        // Engine truth caught up (or someone picked a preset, which changes this
        // out from under the slider): stop showing the local guess.
        .onChange(of: value) { _, fresh in
            if let p = pending, abs(fresh - p) < 1e-6 { pending = nil }
            else if drag == nil { pending = nil }
        }
    }
}

// MARK: - The drum pad grid
//
// Four rows of four, low key bottom-left, the way hardware pads are laid out —
// so the pad your finger goes to is the key the keyboard plays. A LazyVGrid,
// explicitly NOT inside a horizontal ScrollView.

struct StudioDrumPadGrid: View {
    @ObservedObject var model: StudioViewModel
    let trackID: UUID
    let device: StudioDeviceSnapshot

    /// The rack's base key: the lowest bound pad, which is exactly what the
    /// engine's `build_drum_kit` uses to lay the sixteen slots out. Deriving it
    /// the same way is what keeps the grid's key labels honest.
    private var baseKey: Int {
        StudioDrumRack.baseKey(forBoundKeys: device.zones.map(\.loPitch))
    }

    /// Keys top row = highest, so the grid reads like a hardware rack.
    private var rows: [[Int]] {
        let keys = StudioDrumRack.keys(baseKey: baseKey)
        return stride(from: 12, through: 0, by: -4).map { Array(keys[$0..<($0 + 4)]) }
    }

    private func zone(for key: Int) -> StudioZoneSnapshot? {
        device.zones.first { $0.isSingleKey && $0.loPitch == key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sixteen pads, one key each, starting at \(StudioPitchName.name(baseKey)). " +
                 "Press that key on a keyboard — or draw the note in the piano roll — and the " +
                 "pad's sound plays once, from the top.")
                .font(.system(size: 11))
                .foregroundStyle(StudioTokens.dim)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                      spacing: 8) {
                ForEach(rows.flatMap { $0 }, id: \.self) { key in
                    pad(key: key)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Drum pads")

            HStack(spacing: 8) {
                Button("Load Drum Kit") {
                    let paths = StudioSoundPicker.pickFolder(
                        prompt: "Pick a folder of drum one-shots.")
                    guard !paths.isEmpty else { return }
                    model.loadDrumRack(trackID: trackID, paths: paths)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .studioHelp("instrument.drum.loadKit")

                Text("Drop an audio file straight onto a pad, or click one to pick a file.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(StudioTokens.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One pad. `helpID:` is passed into this shared builder, which applies the
    /// help once for all sixteen — the coverage net counts that form too.
    private func pad(key: Int) -> some View {
        let bound = zone(for: key)
        let name = bound.flatMap { model.soundName($0.sourceID) }
        return padButton(
            key: key,
            bound: bound,
            name: name,
            helpID: bound == nil ? "instrument.pad.empty" : "instrument.pad.loaded")
    }

    private func padButton(key: Int, bound: StudioZoneSnapshot?, name: String?,
                           helpID: String) -> some View {
        Button {
            guard let path = StudioSoundPicker.pickOne(
                prompt: "Pick the sound for \(StudioPitchName.name(key)).") else { return }
            model.loadDrumPad(trackID: trackID, deviceID: device.id, key: key,
                              path: path, replacing: bound?.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(StudioPitchName.name(key))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(bound == nil ? StudioTokens.faint : StudioTokens.cyan)
                Spacer(minLength: 0)
                Text(name ?? (bound == nil ? "empty" : "sound not found"))
                    .font(.system(size: 10, weight: bound == nil ? .regular : .semibold))
                    .foregroundStyle(bound == nil ? StudioTokens.faint : StudioTokens.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            .background(bound == nil ? StudioTokens.bg : StudioTokens.purple.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                bound == nil ? StudioTokens.stroke : StudioTokens.purple.opacity(0.7),
                lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .studioHelp(helpID)
        .contextMenu {
            // help-exempt: macOS menu items get no hover tooltip; the pad
            // itself carries the teaching that leads a person here.
            if let bound {
                Button("Clear \(StudioPitchName.name(key))", role: .destructive) {
                    model.clearDrumPad(trackID: trackID, deviceID: device.id, zone: bound)
                }
            }
        }
        // A Finder drop is the fastest way to fill a kit from a folder of
        // one-shots, which is the shape the sounds vault actually has.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    model.loadDrumPad(trackID: trackID, deviceID: device.id, key: key,
                                      path: url.path, replacing: bound?.id)
                }
            }
            return true
        }
        .accessibilityLabel("Pad \(StudioPitchName.name(key))")
        .accessibilityValue(name ?? (bound == nil ? "empty" : "sound not found"))
        .accessibilityHint(bound == nil
                           ? "Pick a sound for this key"
                           : "Pick a different sound for this key")
    }
}
