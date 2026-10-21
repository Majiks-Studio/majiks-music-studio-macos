import SwiftUI

// MARK: - Transport bar
//
// Mockup top strip: transport buttons, position (bars.beats.divisions,
// tabular numerals), BPM, key, time signature, snap picker, follow toggle,
// master meters, engine stats chip, Generate button (shimmer surface).

struct StudioTransportBar: View {
    /// The toolbar row's fixed height. THE BACKSTOP for the wrap-explosion
    /// described on `readout(value:caption:)`: this row is the first child of
    /// the root `VStack`, so if anything in it grows vertically the timeline
    /// pays for it. Pinning the height means a control that forgets
    /// `lineLimit(1)` gets clipped — visibly wrong in its own 52 pt, rather
    /// than silently eating half the window.
    static let rowHeight: CGFloat = 52

    @ObservedObject var model: StudioViewModel
    /// Whether the project file is current. Quiet by design: the work is
    /// already on disk (every command is journaled at submit), so this reports
    /// the CHECKPOINT, never "you are about to lose something".
    @ObservedObject private var saver = StudioProjectSaver.shared
    @State private var generatePopover = false

    var body: some View {
        HStack(spacing: 18) {
            transportButtons
            readouts
            Spacer(minLength: 8)
            snapAndFollow
            // VOLUME before the meter on purpose: a level you can SET belongs
            // next to the level the engine is REPORTING, and putting the word
            // VOLUME on the transport itself is the answer to "where is the
            // volume?" that the collapsed mixer strip never gave.
            masterVolume
            meters
            StudioSaveIndicator(saver: saver)
            engineChip
            exportButton
            generateButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        // THE BACKSTOP. Every Text in this row is `lineLimit(1)` + `fixedSize()`
        // already, but a future control that forgets still cannot blow the
        // toolbar to 475 pt the way "POSITION" and "Generate" did in 3.4.8 —
        // it gets clipped inside 52 pt instead of eating the timeline.
        .frame(height: Self.rowHeight)
        .background(StudioTokens.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioTokens.strokeSoft).frame(height: 1)
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 8) {
            transportButton(
                systemImage: "backward.end.fill",
                label: "Return to start",
                helpID: "transport.returnToStart",
                active: false
            ) {
                model.returnToStart()
            }
            // REWIND / FAST-FORWARD. One bar per press.
            //
            // WORDS, not glyphs. The ◀◀ / ▶▶ icons shipped and worked, and the
            // owner who this app is for still could not find them: icon-only
            // transport is DAW-native literacy this person does not have. The
            // one control in the top strip he found immediately was "Keys",
            // which is a word for the same reason SF Symbols has no spare
            // piano glyph that still means "piano". Same call here — "Back"
            // and "Fwd" disambiguate where a third triangle cannot.
            //
            // A BAR, not a second and not a held shuttle — see
            // `StudioViewModel.nudgePlayhead(bars:)` for why. They flank Play
            // in the standard tape order (rewind, play, fast-forward), and
            // Return-to-start keeps the far-left "go home" slot.
            labeledTransportButton(
                title: "Back",
                label: "Rewind one bar",
                helpID: "transport.rewind",
                active: false
            ) {
                model.nudgePlayhead(bars: -1)
            }
            transportButton(
                systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                label: model.isPlaying ? "Pause" : "Play",
                helpID: model.isPlaying ? "transport.pause" : "transport.play",
                active: model.isPlaying
            ) {
                // Pass the viewport so pausing commits the follow-scroll and the
                // timeline holds where it visually is.
                model.togglePlayback(viewportWidth: model.timelineViewportWidth)
            }
            labeledTransportButton(
                title: "Fwd",
                label: "Forward one bar",
                helpID: "transport.fastForward",
                active: false
            ) {
                model.nudgePlayhead(bars: 1)
            }
            transportButton(
                systemImage: "stop.fill",
                label: "Stop",
                helpID: "transport.stop",
                active: false
            ) {
                model.stop()
            }
            recordTransportButton
            metronomeControl
            loopButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transport")
    }

    /// THE METRONOME. A click you can hear, next to the transport it belongs
    /// to, in the same 30x24 idiom as every other transport button: purple
    /// filled when on, `panelHi` when off.
    ///
    /// The level lives in a `Menu` hung off a right-hand chevron rather than
    /// a slider in the strip — the strip is already dense, and level is a
    /// set-once preference, not something you ride. No horizontal `ScrollView`
    /// anywhere near it: on macOS that silently eats the Button's clicks.
    private var metronomeControl: some View {
        HStack(spacing: 2) {
            transportButton(
                systemImage: "metronome",
                label: model.metronomeEnabled ? "Metronome on" : "Metronome off",
                helpID: model.metronomeEnabled
                    ? "transport.metronome.on"
                    : "transport.metronome.off",
                active: model.metronomeEnabled
            ) {
                model.toggleMetronome()
            }
            Menu {
                ForEach(Self.clickLevels, id: \.1) { name, db in
                    Button {
                        model.metronomeLevelDB = db
                    } label: {
                        if model.metronomeLevelDB == db {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: 14, height: 24)
                    .background(StudioTokens.panelHi)
                    .foregroundStyle(StudioTokens.dim)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(StudioTokens.stroke, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 14)
            .accessibilityLabel("Click level")
            .studioHelp("transport.metronome.level")
        }
    }

    /// LOOP. The second half of the loop control: the ruler's loop strip is
    /// where you draw a region, this is where you turn one on without drawing
    /// and where you turn it off from the keyboard-hand side of the screen.
    ///
    /// Same 30x24 idiom as the rest of the transport cluster, purple when a
    /// loop is set. It is never disabled — with nothing selected it still has
    /// a defensible answer (the section under the play head, else four bars
    /// from it), because a control that greys out for reasons a newcomer
    /// cannot see is how the loop got lost in the first place.
    private var loopButton: some View {
        transportButton(
            systemImage: "repeat",
            label: model.loopRegion == nil ? "Loop" : "Clear loop",
            helpID: model.loopRegion == nil ? "transport.loop.off" : "transport.loop.on",
            active: model.loopRegion != nil
        ) {
            model.toggleLoop()
        }
        .accessibilityValue(model.loopDescription(
            timeSignature: model.timeSignature) ?? "no loop set")
    }

    /// Click levels, in dB relative to the engine default (-12 dBFS peak).
    /// Named rather than numeric: "how loud is the click" is not a decibel
    /// question for the person this is for.
    private static let clickLevels: [(String, Double)] = [
        ("Quiet", -10),
        ("Normal", 0),
        ("Loud", 6),
    ]

    /// Record: red, beside the transport cluster. Disabled until a track is
    /// armed; a filled square while capturing (press to stop and land the take);
    /// the count-in number while counting in.
    private var recordTransportButton: some View {
        Button {
            model.toggleRecord()
        } label: {
            Group {
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 2).fill(StudioTokens.bad).frame(width: 9, height: 9)
                } else if model.isCountingIn {
                    Text("\(model.countInRemaining)")
                        .font(.system(size: 11, weight: .heavy).monospacedDigit())
                        .foregroundStyle(StudioTokens.bad)
                } else {
                    Circle()
                        .fill(model.canRecord ? StudioTokens.bad : StudioTokens.bad.opacity(0.35))
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 30, height: 24)
            .background(model.isRecording ? StudioTokens.bad.opacity(0.22) : StudioTokens.panelHi)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(model.isRecording ? StudioTokens.bad : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!model.canRecord && !model.isRecording && !model.isCountingIn)
        .accessibilityLabel(model.isRecording ? "Stop recording" : "Record")
        // Disabled records get their OWN entry, which names the remedy: the
        // question a newcomer asks here is not "what is record", it is "why is
        // it grey".
        .studioHelp(model.canRecord || model.isRecording ? "transport.record" : "transport.record.blocked")
    }

    private func transportButton(
        systemImage: String,
        label: String,
        helpID: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 30, height: 24)
                .background(active ? StudioTokens.purple : StudioTokens.panelHi)
                .foregroundStyle(active ? .white : StudioTokens.text)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(active ? StudioTokens.purple : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .studioHelp(helpID)
    }

    /// Word-labelled transport button. Same chrome and help path as
    /// `transportButton`, different face: short text instead of a glyph, for
    /// the two moves a non-DAW user cannot decode from a triangle. Every Text
    /// is `lineLimit(1)` + `fixedSize()` — without both, a tight HStack wraps
    /// the caption to one character per line and the row explodes (3.4.8).
    private func labeledTransportButton(
        title: String,
        label: String,
        helpID: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(active ? StudioTokens.purple : StudioTokens.panelHi)
                .foregroundStyle(active ? .white : StudioTokens.text)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(active ? StudioTokens.purple : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .studioHelp(helpID)
    }

    // MARK: - Master volume on the transport
    //
    // Volume is the most basic control in any audio app, and until this lived
    // here the only path to it was the mixer dock — collapsed by default, with
    // nothing but a thin "MIXER · MASTER" strip as evidence it existed. The
    // fader still lives there for per-track work; the MASTER level also lives
    // here so "make it louder" is answerable from the top bar without opening
    // anything.
    //
    // ONE journaled `mix.master.gain` on gesture end (or arrow / typed commit),
    // same as the master strip fader. No new command.

    /// Compact master volume: a short horizontal track + the word VOLUME and
    /// the dB readout. Exposed as a property so tests drive the REAL control
    /// (same onCommit, same range) rather than a rebuilt twin.
    var masterVolume: some View {
        StudioTransportVolumeControl(
            valueDB: model.snapshot?.master.volumeDB ?? 0
        ) { db in
            model.setMasterGain(db)
        }
    }

    private var readouts: some View {
        HStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: model.isPlaying ? 0.05 : 3600)) { _ in
                readout(
                    value: StudioTimelineMath.positionString(
                        ticks: model.playheadTicks(now: ProcessInfo.processInfo.systemUptime),
                        timeSignature: model.timeSignature,
                        phaseAnchorTicks: model.phaseAnchorTicks),
                    caption: "POSITION")
                .studioHelp("transport.position")
                .accessibilityLabel("Position")
                .accessibilityValue(StudioTimelineMath.positionString(
                    ticks: model.playheadTicks(now: ProcessInfo.processInfo.systemUptime),
                    timeSignature: model.timeSignature,
                    phaseAnchorTicks: model.phaseAnchorTicks))
            }
            tempoField
                .accessibilityLabel("Tempo")
                .accessibilityValue("\(Int(model.snapshot?.tempoBPM ?? 0)) beats per minute")
            keyField
            .frame(width: 48)
                .accessibilityLabel("Key")
                .accessibilityValue(model.snapshot?.key ?? "not set")
            timeSigPicker
            .accessibilityLabel("Time signature")
            .accessibilityValue("\(model.timeSignature.beatsPerBar) \(model.timeSignature.beatUnit)")
        }
    }

    private var timeSigPicker: some View {
        Menu {
            ForEach([(4,4), (3,4), (2,4), (6,8), (12,8)], id: \.0) { num, den in
                Button {
                    model.setTimeSig(numerator: num, denominator: den)
                } label: {
                    if model.timeSignature.beatsPerBar == num && model.timeSignature.beatUnit == den {
                        Label("\(num)/\(den)", systemImage: "checkmark")
                    } else {
                        Text("\(num)/\(den)")
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.timeSignature.beatsPerBar)/\(model.timeSignature.beatUnit)")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(StudioTokens.text)
                Text("TIME")
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(StudioTokens.faint)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .studioHelp("transport.timeSignature")
    }

    /// EVERY `Text` IN THIS BAR IS `lineLimit(1)` + `fixedSize`, AND THAT IS
    /// STRUCTURAL, NOT COSMETIC.
    ///
    /// A bare `Text` in an `HStack` is horizontally flexible: offered less
    /// width than it wants, it does not truncate, it WRAPS. At the limit it
    /// wraps to one character per line, which turns an 8-character caption into
    /// an 8-line column and makes the whole toolbar row that tall. The row is
    /// the first child of the root `VStack`, so every point it steals comes
    /// straight out of the timeline below it.
    ///
    /// That is not hypothetical — it shipped. In 3.4.8 "POSITION" and
    /// "Generate" (both 8 characters) each wrapped into a vertical column, the
    /// toolbar row grew to ~475 pt, and the browser, tracks and inspector were
    /// squeezed into the bottom third of the window under a black void. The
    /// tell was that `timeSigPicker` — the ONE control here that already had
    /// `.fixedSize()` — was also the one control that still rendered correctly.
    ///
    /// `fixedSize` makes these texts inflexible, so the `Spacer` yields to them
    /// instead of the other way round. `StudioTransportBar.rowHeight` is the
    /// backstop: even if some future control forgets this, it cannot blow up
    /// the row.
    private func readout(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(StudioTokens.text)
                .lineLimit(1)
                .fixedSize()
            Text(caption)
                .font(.system(size: 8, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(StudioTokens.faint)
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: - The two readouts you can type into
    //
    // Exposed as properties, not built inline, for the reason `masterVolume`
    // and every mixer knob already are: a test drives the REAL control rather
    // than a rebuilt twin that happens to look like it.

    /// BPM. The help says "click the number and type a new value" — see
    /// `StudioCommittedReadoutField` for what that sentence used to be worth.
    var tempoField: StudioCommittedReadoutField {
        let current = model.snapshot?.tempoBPM ?? 120
        return StudioCommittedReadoutField(
            text: StudioTransportEntry.tempoText(current),
            caption: "BPM",
            helpID: "transport.bpm"
        ) { raw in
            let entry = StudioTransportEntry.tempo(raw, current: current)
            if let bpm = entry.send { model.setTempo(bpm: bpm) }
            return entry.display
        }
    }

    /// KEY. Same commit contract; a key is a word rather than a number, so the
    /// rule it commits under lives beside the tempo's in `StudioTransportEntry`.
    var keyField: StudioCommittedReadoutField {
        let current = model.snapshot?.key ?? "-"
        return StudioCommittedReadoutField(
            text: current,
            caption: "KEY",
            helpID: "transport.key"
        ) { raw in
            let entry = StudioTransportEntry.key(raw, current: current)
            if let key = entry.send { model.setKey(key) }
            return entry.display
        }
    }

    private var snapAndFollow: some View {
        HStack(spacing: 8) {
            Picker("Snap", selection: $model.snapMode) {
                ForEach(StudioSnapMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 96)
            .studioHelp("transport.snap")
            .accessibilityLabel("Snap")
            .accessibilityValue(model.snapMode.label)

            Toggle(isOn: $model.followPlayhead) {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 10, weight: .bold))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .accessibilityLabel("Follow playhead")
            .studioHelp("transport.follow")
        }
    }

    /// THE MASTER METER. Measured, never animated.
    ///
    /// This used to be two bars driven by `abs(sin(t))` — they bounced
    /// convincingly whenever the transport ran and were connected to no audio
    /// at all. What is drawn now is `snapshot.master.meter`, which
    /// `RealStudioEngine.buildSnapshot` parses out of the host's `meters()`
    /// read (`"master"` -> `peakDb` / `rmsDb`, dBFS from `MeterBank`). That is
    /// the SAME single read the mixer dock's master strip and the routing
    /// pane's bus meters ride, which matters: peaks are read-and-reset on the
    /// render side, so a second independent `meters()` poller would steal half
    /// of everyone's peaks. There is exactly one poller — the snapshot poll —
    /// and every meter surface reads its result.
    ///
    /// ONE bar, not two. The engine publishes the master as a single
    /// mono-collapsed peak (`host.rs meters()`: `to_db(master_peak_l.max(
    /// master_peak_r))`), so there is no left and no right on the wire. Two
    /// bars here could only be the same number drawn twice — a picture of
    /// stereo that is not a measurement of it. The second channel is drawn as
    /// nothing, and the help text says why.
    ///
    /// No `TimelineView` driver either: repaint comes from the snapshot poll,
    /// so the bar moves when the ENGINE publishes a new level and is otherwise
    /// still. A meter with its own clock is a meter that can lie about a dead
    /// engine.
    private var meters: some View {
        let reading = StudioTransportMeter.reading(for: model.snapshot)
        return Group {
            switch reading {
            case .measured(let peakDB, let rmsDB):
                StudioMeterBar(peakDB: peakDB, rmsDB: rmsDB, width: 6)
                    .accessibilityHidden(true)
            case .unavailable:
                // No snapshot yet: an EMPTY well. Absence and silence are
                // different statements and this one is "I cannot tell you".
                RoundedRectangle(cornerRadius: 3)
                    .fill(StudioTokens.bg)
                    .frame(width: 6)
            }
        }
        .frame(width: 6, height: 20)
        .studioHelp("transport.meters")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Master output level")
        .accessibilityValue(reading.spokenValue)
    }

    private var engineChip: some View {
        let snapshot = model.snapshot
        return HStack(spacing: 4) {
            Text("engine")
                .foregroundStyle(StudioTokens.dim)
            Text(StudioEngineChip.text(for: snapshot))
                .foregroundStyle(StudioTokens.good)
        }
        .font(.system(size: 10, weight: .semibold).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .studioHelp("transport.engine")
        .accessibilityLabel("Engine status")
        .accessibilityValue(StudioEngineChip.spokenValue(for: snapshot))
    }

    private var exportButton: some View {
        Button {
            model.exportSheetShown = true
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(StudioTokens.text)
                .frame(width: 30, height: 24)
                .background(StudioTokens.panelHi)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Export")
        .studioHelp("transport.export")
    }

    private var generateButton: some View {
        Button {
            generatePopover = true
        } label: {
            Text("Generate")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .studioShimmerBackground(cornerRadius: 8)
        .studioHelp("transport.generate")
        .accessibilityLabel("Generate")
        .accessibilityHint("Generation lands in a later lane of this build")
        .popover(isPresented: $generatePopover) {
            Text("Generation wires into the Studio timeline in a later build. Use the Create tab to generate songs.")
                .font(.system(size: 12))
                .frame(width: 240)
                .padding(12)
        }
    }
}

// MARK: - What the master meter is allowed to draw

/// The reading behind the transport strip's master meter. Two states, and the
/// difference between them is the whole point: a level of -120 dBFS is the
/// engine SAYING "silence", while `.unavailable` is the engine not having said
/// anything yet. The first draws a bar at the floor; the second draws nothing.
enum StudioTransportMeterReading: Equatable, Sendable {
    /// No engine snapshot yet. Draw an empty well, speak "no reading".
    case unavailable
    /// Measured dBFS, straight off `meters()` via the snapshot poll.
    case measured(peakDB: Double, rmsDB: Double)

    /// VoiceOver copy. Says the NUMBER when there is one, because "playing" is
    /// not a level — and "playing" was exactly what the old sine-wave meter
    /// spoke, a true sentence in front of a fictional picture.
    var spokenValue: String {
        switch self {
        case .unavailable:
            return "no reading yet"
        case .measured(let peakDB, _):
            return peakDB <= StudioMeterScale.floorDB
                ? "silent"
                : String(format: "peak %.0f decibels", peakDB)
        }
    }
}

/// The transport meter's entire data path, as a pure function so it can be
/// tested without a view. It is deliberately tiny — the point is that there is
/// NOTHING here but engine truth: no clock, no `isPlaying`, no easing.
enum StudioTransportMeter {

    static func reading(for snapshot: StudioProjectSnapshot?) -> StudioTransportMeterReading {
        guard let meter = snapshot?.master.meter else { return .unavailable }
        return .measured(peakDB: meter.peakDB, rmsDB: meter.rmsDB)
    }
}

// MARK: - The engine chip, including the one signal the click has

/// The engine chip's text, as a pure function of the snapshot, for the same
/// reason `StudioTransportMeter` is one: a chip built inline in a view body
/// cannot be asserted on, and this one carries a diagnostic that has to be
/// right.
///
/// THE CLICK IS OTHERWISE INVISIBLE IN THIS APP. The metronome is deliberately
/// excluded from the master bus, the meters, the true-peak detector and the
/// capture tap, so a take you record to it has no click in it — and so the
/// master meter two controls to the left reads exactly the same whether the
/// click is running or dead. `metronomeClicks` is the only thing on screen
/// that can tell those apart, which is the whole reason it is here: a user
/// hearing one chirp and then silence can now say whether the engine is still
/// making clicks (fault is after the engine) or has stopped (the enable never
/// reached the audio thread). It is a NUMBER, not a control — nothing about it
/// is journaled, undoable, or part of the project.
enum StudioEngineChip {

    /// The click segment, or nil when it is not worth the width.
    ///
    /// Present while the metronome is ARMED — so "still 0" is a reading you can
    /// take rather than an absence you have to interpret — and afterwards
    /// whenever the count is nonzero, because a count-in clicks with the
    /// metronome switched off. Absent otherwise, which is what keeps the
    /// transport bar's resting width exactly where it was.
    static func clickSegment(for snapshot: StudioProjectSnapshot?) -> String? {
        guard let snapshot else { return nil }
        let armed = snapshot.transport.metronomeEnabled
        let clicks = snapshot.stats.metronomeClicks
        guard armed || clicks > 0 else { return nil }
        return "\(clicks) clicks"
    }

    /// What the chip reads. "starting" before the first snapshot: the engine
    /// has not said anything yet, which is a different statement from zero.
    static func text(for snapshot: StudioProjectSnapshot?) -> String {
        guard let snapshot else { return "starting" }
        let s = snapshot.stats
        let suffix = clickSegment(for: snapshot).map { ", \($0)" } ?? ""
        return "\(s.engineLabel), \(String(format: "%.1f", s.callbackP95Millis)) ms p95, "
            + "\(s.underruns) underruns\(suffix)"
    }

    /// VoiceOver copy. Drops the buffer timing (a number nobody listens to) and
    /// keeps the two counts that mean something: underruns, and the clicks.
    static func spokenValue(for snapshot: StudioProjectSnapshot?) -> String {
        guard let snapshot else { return "starting" }
        let suffix = clickSegment(for: snapshot).map { ", \($0)" } ?? ""
        return "\(snapshot.stats.engineLabel), \(snapshot.stats.underruns) underruns\(suffix)"
    }
}

// MARK: - Typing into the transport's two editable readouts
//
// WHAT SHIPPED, AND WHY IT LOOKED FINE.
//
// BPM and KEY were `TextField("", text: <computed Binding>)`, and the binding's
// setter called the command bus. A macOS `TextField` writes its binding on
// EVERY KEYSTROKE, so typing `130` over `120.0` did not send one command, it
// sent one per character — and `setTempo` clamps to 20…300, so the first two
// were `project.setTempo(20)` and `project.setTempo(20)`: three journal
// entries, three Cmd-Z steps, and two tempi the user never asked for. The
// binding's GETTER then re-read engine truth, so the 30 Hz snapshot poll
// replaced the half-typed text with "20.0" underneath the caret.
//
// None of that is a new idea in this codebase. `StudioMixerControls.swift`
// opens with the rule — "the binding NEVER commits — typing 2500 must not send
// 2, then 25, then 250, then 2500" — and `StudioTypedValueField` implements it
// for all fifty numeric controls in the mixer, the FX pane and the instrument
// panel. The transport's two readouts were the pair that never got it, because
// they were added in a different lane from a different door.
//
// So this is that rule, applied to the two fields that were missing it. It is
// deliberately NOT `StudioTypedValueField` itself: that control draws a 9 pt
// boxed number with an arrow stack, and the transport readouts are a 15 pt
// figure under a caption. Same contract, different face.

/// What typing into the transport's readouts MEANS, as pure functions.
///
/// Separate from the view for the same reason `StudioTypedEntry` is: "does this
/// reach the bus, and what does the field read afterwards" is the whole
/// behaviour, and it has to be assertable without a window.
enum StudioTransportEntry {

    /// What the BPM readout prints. One formatter, used to draw the field, to
    /// decide "unchanged", and to show a clamp — three copies of `"%.1f"` is
    /// how a field stops accepting its own output.
    static func tempoText(_ bpm: Double) -> String { String(format: "%.1f", bpm) }

    /// The tempo field's commit rule, on `StudioTypedEntry` — the same parse,
    /// clamp and unchanged-sends-nothing every knob and fader already uses. So
    /// a clamp is VISIBLE (type `900`, read back `300.0`), rubbish REVERTS
    /// rather than being read as zero, and clicking into the field and back out
    /// without changing anything puts nothing on the journal.
    ///
    /// - Returns: the BPM to send (nil = send nothing) and the text the field
    ///   must now read.
    static func tempo(_ raw: String, current: Double) -> (send: Double?, display: String) {
        let outcome = StudioTypedEntry.outcome(
            text: raw, unit: .plain, range: StudioViewModel.tempoRangeBPM,
            current: current, format: tempoText)
        return (outcome.committedValue,
                StudioTypedValueField.displayText(
                    after: outcome, previous: current, format: tempoText))
    }

    /// The key field's commit rule. A key is a word, so there is no parser to
    /// share — but the two properties that matter are the same. An empty edit
    /// sends nothing (`setKey` refuses it anyway, and a refusal the user never
    /// asked for is noise on screen), and an edit that equals what is already
    /// there sends nothing, so click-in-click-out is not a journal entry.
    static func key(_ raw: String, current: String) -> (send: String?, display: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current else { return (nil, current) }
        return (trimmed, trimmed)
    }
}

/// A transport readout you can type into, with the commit contract every other
/// typed control in the Studio has.
///
/// ONE USER GESTURE IS ONE JOURNALED COMMAND AND THEREFORE ONE CMD-Z. The
/// binding writes `draft` and nothing else; `commit` is called exactly twice in
/// `body` — on Return, and on losing focus — and the second is a no-op by
/// construction because an unchanged commit sends nothing.
struct StudioCommittedReadoutField: View {
    /// Engine truth, already formatted. NOT a binding: this field never owns
    /// the value, it only proposes a new one.
    var text: String
    var caption: String
    var helpID: String
    /// Take this raw text; send what it means (or nothing) and answer with what
    /// the field must now READ. Returning engine truth is how a rejected edit
    /// reverts visibly and a clamped one shows where it landed.
    var commit: (String) -> String

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    // MARK: The two paths, as methods rather than closures buried in `body`
    //
    // Both are named so a test drives the exact call the text field makes. That
    // is not decoration: the defect this control replaces was that the
    // KEYSTROKE path reached the bus, and a test can only prove it no longer
    // does if the keystroke path is something it can call.

    /// What the text field's binding does on every character typed. It writes
    /// the draft. It does NOT commit, and `StudioTransportTypingTests` fails if
    /// that ever stops being true.
    func textDidChange(_ raw: String) { draft = raw }

    /// Return, or losing focus. The only path to the bus.
    @discardableResult
    func submit(_ raw: String) -> String {
        let shown = commit(raw)
        draft = shown
        return shown
    }

    /// Engine truth moved (an agent, an undo, a poll): what should the field
    /// read? Pure and static because "do not yank the text out from under the
    /// caret" is a rule about a value, not a story about `@State` — and it is
    /// the second half of what shipped broken here.
    static func reseed(draft: String, engineTruth: String, focused: Bool) -> String {
        focused ? draft : engineTruth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            TextField("", text: Binding(get: { draft }, set: { textDidChange($0) }))
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(StudioTokens.text)
                .textFieldStyle(.plain)
                .frame(width: 56)
                .multilineTextAlignment(.center)
                .focused($focused)
                .onSubmit { submit(draft) }
                // Blur commits too: clicking away from a number you have typed
                // must not throw it away. Safe to call twice — an unchanged
                // commit sends nothing.
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { submit(draft) }
                }
            Text(caption)
                .font(.system(size: 8, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(StudioTokens.faint)
                .lineLimit(1)
                .fixedSize()
        }
        .studioHelp(helpID)
        .onAppear { draft = text }
        .onChange(of: text) { _, t in
            draft = Self.reseed(draft: draft, engineTruth: t, focused: focused)
        }
    }
}

// MARK: - Master volume on the transport strip

/// Pure math behind the transport VOLUME control, so a test can assert the
/// mapping without standing up a view. Same taper as every other fader in the
/// app (`StudioFaderTaper`) — a dB at the transport means the same dB on the
/// master strip.
enum StudioTransportVolume {
    static let trackWidth: CGFloat = 72
    /// 14 pt, the band `StudioTokens.loopRulerHeight` already documents as the
    /// size that "reads at arm's length on a 4K TV". This was 10 — smaller than
    /// the repo's own stated floor for the one control a person reaches for
    /// first.
    static let trackHeight: CGFloat = 14
    /// The draggable cap. Its LEFT edge is placed at `capX`, so it travels
    /// `trackWidth - capWidth`, not `trackWidth`, and the pointer addresses its
    /// CENTRE. Both facts have to be in the same place or the two directions
    /// disagree — which is what shipped.
    static let capWidth: CGFloat = 10

    /// Position 0...1 -> dB on the shared fader range.
    static func db(at pos: Double) -> Double {
        StudioFaderTaper.posToDB(min(1, max(0, pos)))
    }

    /// dB -> position 0...1.
    static func pos(forDB db: Double) -> Double {
        StudioFaderTaper.dbToPos(db)
    }

    /// Left edge of the cap, in track-local points.
    static func capX(forPos pos: Double, width: Double) -> Double {
        min(1, max(0, pos)) * max(0, width - Double(capWidth))
    }

    /// Pointer x -> position. THE EXACT INVERSE of `capX(forPos:width:)`.
    ///
    /// `StudioFaderControl` — the fader this control's own header says it
    /// matches — does this correctly on the vertical axis: it draws the cap at
    /// `capY = (h - 14) * (1 - pos)` and reads the pointer back as
    /// `1 - (y - 7) / (h - 14)`, compensating for the cap's own length at both
    /// ends. This control drew over `width - capWidth` and read back over the
    /// FULL `width`. The two maps therefore disagreed by `(5 - 10 * pos) / 72`
    /// of full scale — up to 5 dB of the 72 dB range — so clicking the cap
    /// exactly where it was drawn MOVED the master gain (by -3.3 dB at unity,
    /// which is where it sits by default), and +12 dB could not be reached by
    /// clicking the cap at all.
    static func pos(atX x: Double, width: Double) -> Double {
        let travel = max(1, width - Double(capWidth))
        return min(1, max(0, (x - Double(capWidth) / 2) / travel))
    }

    /// What the caption under the track reads. Hardcoded format so a pixel
    /// test can look for the exact string "VOLUME" and a shape test can pin
    /// the dB half without guessing at locale.
    static func caption(db: Double) -> String {
        String(format: "%.1f dB", db)
    }

    /// The word drawn above the track. A constant so the discoverability
    /// shape test fails by name if someone renames the face without updating
    /// the affordance.
    static let wordLabel = "VOLUME"
}

/// Compact horizontal master volume for the transport bar.
///
/// Drag the track, or use VoiceOver adjustables. Commit is ONE
/// `mix.master.gain` on gesture end — same journaled, one-undo-step contract
/// as the master strip fader. While dragging, the control shows its own value
/// so the 30 Hz snapshot poll never yanks the cap out from under the pointer.
struct StudioTransportVolumeControl: View {
    var valueDB: Double
    var onCommit: (Double) -> Void

    @State private var dragPos: Double?
    @State private var pending: Double?

    private var shownDB: Double {
        if let dragPos { return StudioTransportVolume.db(at: dragPos) }
        return pending ?? valueDB
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            track
            HStack(spacing: 4) {
                Text(StudioTransportVolume.wordLabel)
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(StudioTokens.faint)
                    .lineLimit(1)
                    .fixedSize()
                Text(StudioTransportVolume.caption(db: shownDB))
                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StudioTokens.dim)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .studioHelp("transport.volume")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Master volume")
        .accessibilityValue(StudioTransportVolume.caption(db: shownDB))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1.0 : -1.0
            let next = max(StudioFaderTaper.minDB,
                           min(StudioFaderTaper.maxDB, shownDB + step))
            pending = next
            onCommit(next)
        }
        .onChange(of: valueDB) { _, v in
            if let p = pending, abs(v - p) < 0.05 { pending = nil }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pos = StudioTransportVolume.pos(forDB: shownDB)
            let capX = CGFloat(StudioTransportVolume.capX(forPos: pos, width: Double(w)))
            ZStack(alignment: .leading) {
                Capsule().fill(StudioTokens.stroke)
                // Fill up to the cap so the "how loud" reading is a length,
                // not only a knob position — length is legible at couch distance.
                Capsule()
                    .fill(StudioTokens.purple.opacity(0.85))
                    .frame(width: max(4, capX + StudioTransportVolume.capWidth / 2))
                RoundedRectangle(cornerRadius: 2)
                    .fill(StudioTokens.text)
                    .frame(width: StudioTransportVolume.capWidth,
                           height: StudioTransportVolume.trackHeight)
                    .offset(x: capX)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragPos = StudioTransportVolume.pos(
                            atX: Double(g.location.x), width: Double(w))
                    }
                    .onEnded { _ in
                        if let dragPos {
                            let db = StudioTransportVolume.db(at: dragPos)
                            pending = db
                            onCommit(db)
                        }
                        dragPos = nil
                    }
            )
            .onTapGesture(count: 2) {
                pending = 0
                onCommit(0)
            }
        }
        .frame(width: StudioTransportVolume.trackWidth,
               height: StudioTransportVolume.trackHeight)
    }

    /// Drive a commit the way a test would, without going through the gesture
    /// machinery. Returns the dB that was sent so a mutation check can pin it
    /// to a hardcoded number rather than "something changed".
    @discardableResult
    func commit(position: Double) -> Double {
        let db = StudioTransportVolume.db(at: position)
        onCommit(db)
        return db
    }
}
