import SwiftUI
import AppKit

// MARK: - Record bar (L19)
//
// The record cockpit: it slides in under the transport when a track is armed.
// It carries the gain-staging surface (live input meter + a rolling input
// scope), the device picker, the count-in, the record timer, and the AI-native
// "Build around this" bridge that hands a human take to the engineer.
//
// COLOR LANGUAGE: recording is human, so this bar is RED (StudioTokens.bad),
// never the generative shimmer. The one exception is "Build around this", which
// invokes generation and therefore shimmers -- the visual thesis of the app:
// your performance is red, and the button that turns it into generation glows.
//
// AUDIO SAFETY: nothing here can make sound. Monitoring (hearing yourself) is
// double-gated behind MAJIKS_TEST_AUDIBLE in the engine and is not wired to any
// control on this bar; the input meter is a silent, visual gain-staging aid.
//
// PRIVACY: arming a track does NOT open the microphone. The mic opens on Record
// (or the explicit Listen toggle). The "MIC OPEN" chip is the user-visible
// indicator of that fact — without it, a DAW that listens while you decide is
// a privacy bug.

private let recordRed = StudioTokens.bad

struct StudioRecordBar: View {
    @ObservedObject var model: StudioViewModel

    var body: some View {
        // transport.recording is driven by the engine's input stream, not the
        // armed flag, so the cockpit (Stop, timer, meter) must not vanish if the
        // capture target is disarmed mid-record. Fall back to the recording track.
        if let track = model.firstArmedTrack ?? model.recordingTrack {
            content(armed: track)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func content(armed: StudioTrackSnapshot) -> some View {
        barRow(armed: armed)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(height: 54)
            .background(barBackground)
            .overlay { if model.isCountingIn { countInOverlay } }
            .animation(.easeOut(duration: 0.18), value: model.isRecording)
    }

    @ViewBuilder
    private func barRow(armed: StudioTrackSnapshot) -> some View {
        HStack(spacing: 14) {
            if let message = model.microphoneAccessMessage {
                HStack(spacing: 6) {
                    Text(message).font(.system(size: 10, weight: .semibold))
                    Button("Open Microphone Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    .studioHelp("record.microphoneSettings")
                }
                .foregroundStyle(recordRed)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(message)
                .accessibilityHint("Microphone access is required to record or listen")
            }
            recordButton
            armedChip(armed)
            punchChip
            // Privacy: show when the engine has actually opened an input stream.
            if model.inputOpen { micOpenChip }
            devicePicker
            inputChannelPicker(armed)
            listenToggle
            Divider().frame(height: 26).overlay(StudioTokens.strokeSoft)
            // Meter is live only when an input stream is open (recording OR
            // opt-in listen). Arming alone leaves this silent.
            StudioInputLevelMeter(
                meter: model.inputMeter,
                active: model.inputMeter != nil
            )
                .frame(width: 150)
                .studioHelp("record.meter")
            // Per-channel meters: which mic is which before a take.
            if let channels = model.inputMeter?.channels, channels.count > 1 {
                channelMeters(channels)
            }
            StudioInputScope(
                level: StudioMeterScale.norm(model.inputMeter?.peakDB ?? -120),
                active: model.inputMeter != nil
            )
            .frame(maxWidth: .infinity, minHeight: 30)
            .studioHelp("record.scope")
            captureControls
            if model.isRecording { recordTimer }
            buildAround(armed: armed)
        }
    }

    /// User-visible privacy indicator: an input device stream is open right now.
    private var micOpenChip: some View {
        HStack(spacing: 4) {
            Circle().fill(recordRed).frame(width: 6, height: 6)
                .modifier(RecordPulse(active: true))
            Text(model.isRecording ? "MIC OPEN" : "MIC LISTEN")
                .font(.system(size: 9, weight: .heavy))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(recordRed)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(recordRed.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(recordRed.opacity(0.5), lineWidth: 1))
        .fixedSize()
        .studioHelp("record.inputOpen")
        .accessibilityLabel(model.isRecording ? "Microphone open for recording" : "Microphone open for listening")
    }

    private func inputChannelPicker(_ track: StudioTrackSnapshot) -> some View {
        Menu {
            ForEach(0..<max(1, model.inputChannelCount), id: \.self) { ch in
                Button {
                    model.setInputChannel(trackID: track.id, channel: ch)
                } label: {
                    Label(
                        "Input \(ch + 1)",
                        systemImage: track.inputChannel == ch ? "checkmark" : ""
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cable.connector").font(.system(size: 9, weight: .bold))
                Text("In \(track.inputChannel + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(StudioTokens.dim)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(StudioTokens.panelHi)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioTokens.stroke, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(model.isRecording)
        .studioHelp("record.inputChannel")
        .accessibilityLabel("Input channel")
        .accessibilityValue("Input \(track.inputChannel + 1)")
    }

    private var listenToggle: some View {
        Button {
            model.toggleInputListen()
        } label: {
            Text(model.inputListening ? "Listen" : "Listen")
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(model.inputListening || model.inputOpen ? recordRed : StudioTokens.dim)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(model.inputListening ? recordRed.opacity(0.15) : StudioTokens.panelHi)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                    model.inputListening ? recordRed.opacity(0.5) : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.isRecording)
        .studioHelp("record.inputListen")
        .accessibilityLabel(model.inputListening ? "Stop input listen" : "Listen to input")
    }

    private func channelMeters(_ channels: [StudioChannelMeter]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(channels.enumerated()), id: \.offset) { i, ch in
                VStack(spacing: 1) {
                    Text("\(i + 1)")
                        .font(.system(size: 7, weight: .bold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(StudioTokens.faint)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(recordRed.opacity(0.85))
                        .frame(width: 6, height: CGFloat(max(2, StudioMeterScale.norm(ch.peakDB) * 22)))
                        .frame(height: 22, alignment: .bottom)
                }
            }
        }
        .fixedSize()
        .studioHelp("record.channelMeters")
        .accessibilityLabel("Per-channel input meters")
    }

    private var barBackground: some View {
        StudioTokens.panel
            .overlay(alignment: .top) {
                Rectangle().fill(recordRed.opacity(model.isRecording ? 0.9 : 0.35)).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(StudioTokens.strokeSoft).frame(height: 1)
            }
    }

    // MARK: Record / stop button

    private var recordButton: some View {
        Button(action: { withAnimation(.easeOut(duration: 0.15)) { model.toggleRecord() } }) {
            ZStack {
                Circle()
                    .stroke(recordRed.opacity(0.8), lineWidth: 2)
                    .frame(width: 30, height: 30)
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(recordRed)
                        .frame(width: 12, height: 12)   // stop square
                } else {
                    Circle()
                        .fill(recordRed)
                        .frame(width: 18, height: 18)
                        .opacity(model.canRecord || model.isCountingIn ? 1 : 0.4)
                }
            }
            .frame(width: 34, height: 34)
            .modifier(RecordPulse(active: model.isRecording))
        }
        .buttonStyle(.plain)
        .disabled(!model.canRecord && !model.isRecording && !model.isCountingIn)
        .studioHelp(model.isRecording ? "record.stop" : "record.start")
        .accessibilityLabel(model.isRecording ? "Stop recording" : "Record")
    }

    // MARK: Armed track chip

    private func armedChip(_ track: StudioTrackSnapshot) -> some View {
        HStack(spacing: 6) {
            Circle().fill(recordRed).frame(width: 7, height: 7)
                .modifier(RecordPulse(active: model.isRecording))
            VStack(alignment: .leading, spacing: 0) {
                Text(model.isRecording ? "RECORDING" : (model.isCountingIn ? "COUNT-IN" : "ARMED"))
                    .font(.system(size: 8, weight: .heavy)).kerning(0.8)
                    .foregroundStyle(recordRed)
                Text(track.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(StudioTokens.text)
                    .lineLimit(1)
            }
            if model.armedTracks.count > 1 {
                Text("+\(model.armedTracks.count - 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(StudioTokens.faint)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .studioHelp("record.armed")
        .accessibilityLabel("\(model.isRecording ? "Recording" : "Armed"): \(track.name)")
    }

    // MARK: Punch region chip

    /// Shows when a region is selected on an armed track: Record will capture
    /// only these bars and auto-stop at the end.
    @ViewBuilder
    private var punchChip: some View {
        if let punch = model.punchRegion {
            let bars = punch.barRange(grid: model.barGrid)
            let label = bars.lowerBound == bars.upperBound
                ? "PUNCH bar \(bars.lowerBound)"
                : "PUNCH bars \(bars.lowerBound)-\(bars.upperBound)"
            HStack(spacing: 4) {
                Image(systemName: "scope").font(.system(size: 9, weight: .bold))
                Text(label).font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(recordRed)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(recordRed.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(recordRed.opacity(0.4), lineWidth: 1))
            .fixedSize()
            .studioHelp("record.punch")
            .accessibilityLabel("Punch region \(label)")
        }
    }

    // MARK: Input device picker

    private var devicePicker: some View {
        Menu {
            Button {
                model.selectedInputDevice = nil
            } label: {
                Label("System Default", systemImage: model.selectedInputDevice == nil ? "checkmark" : "")
            }
            if !model.inputDevices.isEmpty { Divider() }
            ForEach(model.inputDevices, id: \.self) { dev in
                Button {
                    model.selectedInputDevice = dev
                } label: {
                    Label(dev, systemImage: model.selectedInputDevice == dev ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "mic.fill").font(.system(size: 9, weight: .bold))
                Text(model.selectedInputDevice ?? "System Default")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(StudioTokens.dim)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(StudioTokens.panelHi)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioTokens.stroke, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(model.isRecording)
        .studioHelp("record.device")
        .accessibilityLabel("Input device")
        .accessibilityValue(model.selectedInputDevice ?? "System Default")
    }

    // MARK: Count-in

    private var countInControl: some View {
        HStack(spacing: 5) {
            Text("COUNT-IN").font(.system(size: 8, weight: .heavy)).kerning(0.6)
                .foregroundStyle(StudioTokens.faint)
            ForEach([0, 1, 2, 4], id: \.self) { beats in
                Button {
                    model.countInBeats = beats
                } label: {
                    Text(beats == 0 ? "Off" : "\(beats)")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: beats == 0 ? 24 : 18, height: 18)
                        .background(model.countInBeats == beats ? StudioTokens.purple : StudioTokens.panelHi)
                        .foregroundStyle(model.countInBeats == beats ? .white : StudioTokens.dim)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(model.countInBeats == beats ? StudioTokens.purple : StudioTokens.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                // help-exempt: the four beat choices share one tooltip on the
                // cluster below; repeating it per button would fire four
                // identical popups across a 90 pt row.
                .accessibilityLabel("Count-in \(beats == 0 ? "off" : "\(beats) beats")")
            }
        }
        .disabled(model.isRecording || model.isCountingIn)
        .fixedSize()
        .studioHelp("record.countIn")
    }

    // MARK: Count-in + loop-record cluster

    private var captureControls: some View {
        HStack(spacing: 10) {
            countInControl
            loopControl
        }
    }

    /// Loop-record: keep capturing passes over the selected region; each pass
    /// stacks as a comp take. Enabled only when a region is selected.
    private var loopControl: some View {
        Button {
            model.loopRecord.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "repeat").font(.system(size: 9, weight: .bold))
                Text(model.loopRecord && model.loopPass > 0 ? "Loop \u{00B7} \(model.loopPass + 1)" : "Loop")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(model.loopRecord ? recordRed : StudioTokens.dim)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(model.loopRecord ? recordRed.opacity(0.14) : StudioTokens.panelHi)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(model.loopRecord ? recordRed.opacity(0.5) : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.selection.region == nil)
        .fixedSize()
        .studioHelp("record.loop")
        .accessibilityLabel("Loop record")
        .accessibilityValue(model.loopRecord ? "on" : "off")
    }

    // MARK: Record timer

    private var recordTimer: some View {
        Text(StudioMeterScale.clock(model.inputMeter?.capturedSeconds ?? 0))
            .font(.system(size: 14, weight: .bold).monospacedDigit())
            .foregroundStyle(recordRed)
            .fixedSize()
            .studioHelp("record.timer")
            .accessibilityLabel("Recording time")
            .accessibilityValue(StudioMeterScale.clock(model.inputMeter?.capturedSeconds ?? 0))
    }

    // MARK: Build around this (the AI-native bridge; shimmer = generation)

    @ViewBuilder
    private func buildAround(armed: StudioTrackSnapshot) -> some View {
        if !model.isRecording, !model.isCountingIn, let last = armed.clips.max(by: { $0.startTicks < $1.startTicks }) {
            Button {
                model.buildAround(clipID: last.id)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars").font(.system(size: 10, weight: .bold))
                    Text("Build around this")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11).padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .studioShimmerBackground(cornerRadius: 7)
            .fixedSize()
            .studioHelp("record.buildAround")
            .accessibilityLabel("Build around this take")
        }
    }

    // MARK: Count-in overlay

    private var countInOverlay: some View {
        ZStack {
            Rectangle().fill(StudioTokens.bg.opacity(0.82))
            VStack(spacing: 2) {
                Text("\(model.countInRemaining)")
                    .font(.system(size: 30, weight: .heavy).monospacedDigit())
                    .foregroundStyle(recordRed)
                    .contentTransition(.numericText())
                Text("count-in").font(.system(size: 9, weight: .bold)).kerning(1)
                    .foregroundStyle(StudioTokens.dim)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Pulse modifier (armed-recording heartbeat)

private struct RecordPulse: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                content.opacity(0.55 + 0.45 * abs(sin(t * 2.4)))
            }
        } else {
            content
        }
    }
}

// MARK: - Input level meter (horizontal, dBFS, peak-hold + clip)

struct StudioInputLevelMeter: View {
    let meter: StudioInputMeter?
    let active: Bool
    @State private var hold: Double = 0     // peak-hold, 0...1
    /// UI-side latch so a one-frame over stays visible even if the engine
    /// stream restarts; OR'd with engine `clipLatched`.
    @State private var clipLatched = false

    var body: some View {
        let peak = active ? StudioMeterScale.norm(meter?.peakDB ?? -120) : 0
        let rms = active ? StudioMeterScale.norm(meter?.rmsDB ?? -120) : 0
        let engineClip = meter?.clipLatched == true || (meter?.peakDB ?? -120) > -0.5
        let clipping = clipLatched || engineClip
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("IN").font(.system(size: 8, weight: .heavy)).foregroundStyle(StudioTokens.faint)
                Spacer(minLength: 0)
                Button {
                    clipLatched = false
                } label: {
                    Circle().fill(clipping ? StudioTokens.bad : StudioTokens.stroke)
                        .frame(width: 6, height: 6)
                }
                .buttonStyle(.plain)
                .studioHelp("record.clip")
                .onChange(of: engineClip) { _, over in
                    if over { clipLatched = true }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(StudioTokens.clipBase)
                    // RMS body
                    RoundedRectangle(cornerRadius: 3)
                        .fill(StudioMeterScale.gradient)
                        .frame(width: max(0, geo.size.width * rms))
                        .opacity(0.55)
                    // Peak overlay
                    RoundedRectangle(cornerRadius: 3)
                        .fill(StudioMeterScale.gradient)
                        .frame(width: max(0, geo.size.width * peak))
                        .mask(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .frame(width: max(0, geo.size.width * peak))
                        }
                    // Peak-hold tick
                    if hold > 0.01 {
                        Rectangle().fill(StudioTokens.text.opacity(0.8))
                            .frame(width: 2)
                            .offset(x: max(0, geo.size.width * hold - 1))
                    }
                }
                .onChange(of: peak) { _, new in
                    if new >= hold { hold = new } else { hold = max(new, hold - 0.02) }
                }
            }
            .frame(height: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue(active ? StudioMeterScale.dbLabel(meter?.peakDB ?? -120) : "no signal")
    }
}

// MARK: - Input scope (rolling waveform of the incoming level)

struct StudioInputScope: View {
    /// Current input level, 0...1 (dB-mapped).
    let level: Double
    let active: Bool
    @State private var history: [Double] = Array(repeating: 0, count: 120)
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { ctx, size in
            guard history.count > 1 else { return }
            let mid = size.height / 2
            let step = size.width / CGFloat(history.count - 1)
            var path = Path()
            // Mirrored waveform: top edge then back along the bottom.
            for (i, v) in history.enumerated() {
                let x = CGFloat(i) * step
                let h = CGFloat(v) * (size.height / 2 - 1)
                let p = CGPoint(x: x, y: mid - h)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            for (i, v) in history.enumerated().reversed() {
                let x = CGFloat(i) * step
                let h = CGFloat(v) * (size.height / 2 - 1)
                path.addLine(to: CGPoint(x: x, y: mid + h))
            }
            path.closeSubpath()
            let fill = active ? recordRed : StudioTokens.faint
            ctx.fill(path, with: .color(fill.opacity(0.85)))
            // Center line
            var line = Path()
            line.move(to: CGPoint(x: 0, y: mid))
            line.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(line, with: .color(StudioTokens.stroke.opacity(0.6)), lineWidth: 1)
        }
        .background(StudioTokens.clipBase)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(StudioTokens.stroke, lineWidth: 1))
        .onReceive(tick) { _ in
            // Publish on CHANGE, not on tick. `history` is @State, and @State
            // does not compare — every assignment invalidates and redraws the
            // Canvas, whether or not a pixel moved. Before this guard the scope
            // repainted thirty times a second for as long as a track was armed,
            // including with no input stream open at all, which is the same
            // defect `AudioPlayer.startTimer` had one floor up (see
            // StudioIdleInvalidationTests).
            guard let next = Self.advanced(history, level: level, active: active) else { return }
            history = next
        }
        .accessibilityHidden(true)
    }

    /// The rolling window advanced by one tick, or `nil` when the advance would
    /// be a no-op.
    ///
    /// Pure and `static` so `StudioIdleInvalidationTests` can count updates
    /// without standing up a view — the same shape as `StudioViewModel.pollOnce`,
    /// which is the reference for what a correct 30 Hz poll looks like here: it
    /// asks `engine.snapshot(ifNewerThan:)` and returns early on nil rather than
    /// republishing what everyone already has.
    ///
    /// The nil test is the ARRAY, not a proxy for it. A settled silent scope is
    /// the case that mattered, but an input holding a dead-flat level is equally
    /// nothing to redraw, and comparing the result catches both without either
    /// being enumerated as a special case.
    static func advanced(_ history: [Double], level: Double, active: Bool) -> [Double]? {
        guard !history.isEmpty else { return nil }
        // Live: the current level. Idle: decay the tail toward silence, which
        // reaches exactly 0 (not asymptotically) and then stays there.
        let next = active ? max(0, min(1, level)) : max(0, (history.last ?? 0) - 0.08)
        var out = history
        out.removeFirst()
        out.append(next)
        return out == history ? nil : out
    }
}

// MARK: - Meter scale helpers (extends the shared StudioMeterScale, which
// already provides the dBFS -> 0...1 `norm` mapping used across the mixer).

extension StudioMeterScale {
    static func dbLabel(_ db: Double) -> String {
        db <= -120 ? "silent" : String(format: "%.0f dBFS", db)
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60
        let sec = Int(s) % 60
        let cs = Int((s - floor(s)) * 10)
        return String(format: "%01d:%02d.%01d", m, sec, cs)
    }

    /// Green -> amber -> red level gradient (matches the transport master meter).
    static var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: StudioTokens.good, location: 0),
                .init(color: StudioTokens.good, location: 0.62),
                .init(color: StudioTokens.warn, location: 0.82),
                .init(color: StudioTokens.bad, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}
