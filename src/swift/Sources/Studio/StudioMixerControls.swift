import SwiftUI

// MARK: - Reusable mixer controls (L12)
//
// Each control reads engine truth (a value from the snapshot) and drives the
// command bus. The edit-guard is control-local (the DJ AppModel pattern): while
// a gesture is live the control shows its own value; the change lands as ONE
// journaled command on gesture end (a clean single undo step); until the next
// snapshot confirms it, the control holds the value it sent so the 30 Hz poll
// never yanks it back. Continuous live-audio-during-drag (txn-grouped) is a
// documented v1.1 refinement.

// MARK: dB / fader taper

enum StudioFaderTaper {
    /// Fader travel is linear in dB over the catalog gain range.
    static let minDB = -60.0
    static let maxDB = 12.0

    static func dbToPos(_ db: Double) -> Double {
        min(1, max(0, (db - minDB) / (maxDB - minDB)))
    }
    static func posToDB(_ pos: Double) -> Double {
        minDB + min(1, max(0, pos)) * (maxDB - minDB)
    }
    /// Scale ticks shown next to a fader.
    static let ticks: [Double] = [12, 0, -12, -24, -48]
}

/// dBFS -> 0...1 meter fill over a fixed viewing range.
enum StudioMeterScale {
    static let floorDB = -60.0
    static func norm(_ db: Double) -> Double {
        min(1, max(0, (db - floorDB) / (0 - floorDB)))
    }
}

// MARK: - Typed value + arrows (the shared numeric entry, used by EVERY control)
//
// WHY IT IS ONE VIEW.
//
// The mixer, the routing/FX pane and the instrument panel between them expose
// 38 `FX_PARAM_KEYS`, 10 `DEVICE_PARAM_KEYS`, and the mixer's own pan / sends /
// faders / limiter — call it fifty numbers, every one of which was reachable
// ONLY by dragging. Adding a text field fifty times would have drifted within a
// lane: fifty parsers, fifty clamps, fifty ideas of what one arrow press means.
// So this is one control, embedded once inside `StudioKnob`,
// `StudioFaderControl` and `StudioParamSlider`, and every existing call site
// gained typing and arrows without being rewritten.
//
// COMMIT SEMANTICS, which are the whole reason this is not a plain TextField.
// One user gesture is one journaled command and therefore one Cmd-Z. The
// binding NEVER commits — typing "2500" must not send 2, then 25, then 250,
// then 2500. `submit(_:)` is called exactly twice in `body`: on Return, and on
// losing focus. The second of those is a no-op by construction, because a
// commit whose value PRINTS the same as engine truth returns `.unchanged` and
// sends nothing (see `StudioTypedEntry.outcome`).
//
// AND THE TEXT TRAP. Every `Text` in a tight `HStack` here carries
// `lineLimit(1)` + `fixedSize()`. An unconstrained one under width pressure
// wraps to a character per line — "POSITION" became an 8-line column and blew
// the toolbar to 475 pt in 3.4.8. These strips are tighter than that toolbar.

struct StudioTypedValueField: View {
    /// What the control is showing right now: engine truth, or the value under
    /// a live drag. NOT a binding — this field never owns the value, it only
    /// proposes a new one through `onCommit`.
    var value: Double
    var range: ClosedRange<Double>
    var unit: StudioParamUnit
    /// The control's OWN formatter. Reused rather than duplicated, so what the
    /// field prints, what it accepts, and what the knob's caption used to say
    /// are all one string.
    var format: (Double) -> String
    /// For VoiceOver, which needs the parameter's name — the field itself is
    /// just digits.
    var label: String
    /// The help catalog id for the editable number. Defaults to the shared
    /// entry; the two faders override it so their long-standing readout
    /// entries stay attached to the control that replaced them.
    var helpID: String = "control.typedValue"
    var fieldWidth: CGFloat = 34
    var onCommit: (Double) -> Void

    /// The in-progress edit. Seeded from `format(value)` and written back on
    /// every commit, which is how a CLAMP becomes visible: type 999 into a
    /// ±12 dB fader and the field reads "+12.0 dB" the instant you press
    /// Return, rather than keeping a number the engine never accepted.
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    // MARK: The two paths that reach the bus
    //
    // Both are methods on the view rather than closures buried in `body`, for
    // the reason this codebase keeps re-learning: a control that compiles,
    // appears and does nothing passes every test that only looks at state.
    // `StudioTypedControlTests` constructs this view with a recording
    // `onCommit` and calls these directly, so "the field's commit is a no-op"
    // and "the arrow step is zero" are both red tests.

    /// Commit typed text. Returns what happened so the field can show it — and
    /// so a test can assert the clamp, the revert and the single command.
    @discardableResult
    func submit(_ raw: String) -> StudioTypedOutcome {
        let outcome = StudioTypedEntry.outcome(
            text: raw, unit: unit, range: range, current: value, format: format)
        if let v = outcome.committedValue { onCommit(v) }
        return outcome
    }

    /// One arrow press. Returns the value it moved to, which is what the
    /// mutation check pins against a hardcoded number.
    @discardableResult
    func nudge(_ direction: Int) -> Double {
        let next = unit.stepped(value, by: direction, in: range)
        if next != value { onCommit(next) }
        return next
    }

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(StudioTokens.text)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .focused($focused)
                .frame(width: fieldWidth, height: 16)
                .background(StudioTokens.bg)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(focused ? StudioTokens.cyan : StudioTokens.stroke, lineWidth: 1))
                .onSubmit { apply(submit(draft)) }
                // Blur commits too: clicking away from a field you have typed
                // into must not throw the number away. It is safe to call
                // twice because an unchanged commit sends nothing.
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { apply(submit(draft)) }
                }
                .accessibilityLabel(label)
                .accessibilityValue(draft)

            VStack(spacing: 1) {
                arrow(1, "chevron.up")
                arrow(-1, "chevron.down")
            }
        }
        .studioHelp(helpID)
        // Engine truth moved (a drag, an agent, an undo): re-seed, unless the
        // user is mid-edit, in which case yanking the text out from under them
        // is the fader-fights-the-hand bug in a text field.
        .onAppear { draft = format(value) }
        .onChange(of: value) { _, v in if !focused { draft = format(v) } }
    }

    /// What the field must READ after a commit.
    ///
    /// Pure and static because "out-of-range is clamped AND SHOWN clamped" and
    /// "rubbish reverts, visibly" are requirements about the text on screen,
    /// not about the outcome enum — and a mutation check found exactly that
    /// gap: gutting the assignment below left every other test in this lane
    /// green while the field silently kept a number the engine had refused.
    static func displayText(after outcome: StudioTypedOutcome,
                            previous: Double,
                            format: (Double) -> String) -> String {
        format(outcome.displayValue ?? previous)
    }

    /// Show the result. A rejected edit puts the previous value back, visibly —
    /// never a silent drop, and never a zero read out of rubbish.
    private func apply(_ outcome: StudioTypedOutcome) {
        draft = Self.displayText(after: outcome, previous: value, format: format)
    }

    private func arrow(_ direction: Int, _ glyph: String) -> some View {
        Button { _ = nudge(direction) } label: {
            Image(systemName: glyph)
                .font(.system(size: 6, weight: .black))
                .foregroundStyle(StudioTokens.dim)
                // The glyph is 6 pt; without an explicit frame the clickable
                // area IS the glyph, which is the mistake the mixer's undo
                // buttons already paid for once.
                .frame(width: 13, height: 8)
                .background(StudioTokens.panelHi)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .studioHelp(direction > 0 ? "control.stepUp" : "control.stepDown")
        .accessibilityLabel(direction > 0 ? "Increase \(label)" : "Decrease \(label)")
    }
}

// MARK: - Vertical fader

/// A dB-calibrated vertical fader. `value` is engine truth; `onCommit(db)` sends
/// the command on release; a double-click resets to `resetDB`.
///
/// Since the typed-controls lane it also carries the dB number UNDER the track,
/// as an editable field with arrows: the fader is the coarse gesture, the field
/// is how you get to exactly −6.0 dB from a sofa. `helpID` points that field at
/// the catalog entry the strip's old static readout used, because it is the
/// same fact and the same place on screen.
struct StudioFaderControl: View {
    var value: Double
    var resetDB: Double = 0
    var accent: Color = StudioTokens.faderCap
    var helpID: String = "control.typedValue"
    var onCommit: (Double) -> Void

    @State private var dragPos: Double?      // live drag (fader position 0...1)
    @State private var pending: Double?      // sent, awaiting snapshot confirm

    private var shownDB: Double {
        if let dragPos { return StudioFaderTaper.posToDB(dragPos) }
        return pending ?? value
    }

    static func dbLabel(_ db: Double) -> String { String(format: "%.1f dB", db) }

    /// The typed field this fader draws, exposed rather than inlined so a test
    /// can drive the REAL one — same range, same unit, same `onCommit` closure
    /// the body installs. A test that rebuilt an equivalent field would prove
    /// the field and nothing about whether the fader is holding one.
    /// `testTheNumericPrimitivesDrawTheSharedField` pins that `body` uses this.
    func typedField() -> StudioTypedValueField {
        StudioTypedValueField(
            value: shownDB,
            range: StudioFaderTaper.minDB...StudioFaderTaper.maxDB,
            unit: .decibels,
            format: Self.dbLabel,
            label: "Fader",
            helpID: helpID,
            fieldWidth: 40,
            onCommit: { db in
                pending = db
                onCommit(db)
            })
    }

    var body: some View {
        VStack(spacing: 3) {
            track
            typedField()
        }
        .frame(width: 57)
    }

    private var track: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let pos = StudioFaderTaper.dbToPos(shownDB)
            let capY = (h - 14) * (1 - pos)
            ZStack(alignment: .top) {
                // Track + scale ticks.
                Capsule().fill(StudioTokens.stroke).frame(width: 4).frame(maxWidth: .infinity)
                // Unity marker.
                let unityY = (h - 14) * (1 - StudioFaderTaper.dbToPos(0)) + 7
                Rectangle().fill(StudioTokens.dim.opacity(0.5))
                    .frame(width: 16, height: 1).offset(y: unityY)
                // Cap.
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent)
                    .frame(width: 20, height: 14)
                    .overlay(Rectangle().fill(StudioTokens.bg.opacity(0.4)).frame(height: 1))
                    .offset(y: capY)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let p = 1 - Double(g.location.y - 7) / Double(max(1, h - 14))
                        dragPos = min(1, max(0, p))
                    }
                    .onEnded { _ in
                        if let dragPos {
                            let db = StudioFaderTaper.posToDB(dragPos)
                            pending = db
                            onCommit(db)
                        }
                        dragPos = nil
                    }
            )
            .onTapGesture(count: 2) {
                pending = resetDB
                onCommit(resetDB)
            }
        }
        .frame(width: 22)
        .frame(maxWidth: .infinity)
        .onChange(of: value) { _, v in
            if let p = pending, abs(v - p) < 0.05 { pending = nil }
        }
        .accessibilityElement()
        .accessibilityLabel("Fader")
        .accessibilityValue(Self.dbLabel(shownDB))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1.0 : -1.0
            let db = max(StudioFaderTaper.minDB, min(StudioFaderTaper.maxDB, shownDB + step))
            pending = db
            onCommit(db)
        }
    }
}

// MARK: - Rotary knob

/// A rotary knob over an arbitrary range. Vertical drag changes the value;
/// double-click resets. `onCommit` fires on release (one journaled command).
///
/// The caption under the knob is no longer a `Text` — it is
/// `StudioTypedValueField`, so every knob in the product now takes a typed
/// number and has up/down arrows without a single call site implementing
/// either. The drag is untouched.
///
/// `unit` has NO default, deliberately. It is what decides how big one arrow
/// press is and how a typed string is read, and a silent `.plain` fallback
/// would give a new frequency knob 0.05 Hz arrows across 20 Hz–20 kHz — a
/// control that looks wired and is useless. Making the compiler ask is the
/// cheapest possible guard against that.
struct StudioKnob: View {
    var value: Double
    var range: ClosedRange<Double>
    var resetValue: Double
    var label: String
    var unit: StudioParamUnit
    var accent: Color = StudioTokens.cyan
    var format: (Double) -> String
    var onCommit: (Double) -> Void

    @State private var dragValue: Double?
    @State private var pending: Double?
    @State private var dragAnchor: Double = 0

    private var shown: Double { dragValue ?? pending ?? value }
    private var norm: Double {
        (shown - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// The typed field under this knob, exposed so a test can drive the REAL
    /// one — the knob's own range, unit, formatter and commit closure. See the
    /// note on `StudioFaderControl.typedField()`.
    func typedField() -> StudioTypedValueField {
        StudioTypedValueField(
            value: shown, range: range, unit: unit, format: format, label: label,
            onCommit: { v in
                pending = v
                onCommit(v)
            })
    }

    /// The circle itself, split out of `body` because the column now holds a
    /// dial, a label, a text field and two buttons, and the type-checker
    /// times out on the whole thing in one expression.
    private var dial: some View {
        ZStack {
            Circle().fill(StudioTokens.panelHi)
                .overlay(Circle().stroke(StudioTokens.stroke, lineWidth: 1))
            // Value arc (from ~225 deg sweeping 270 deg).
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, norm))) * 0.75)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(135))
            // Indicator.
            GeometryReader { geo in
                let a = Angle.degrees(135 + 270 * min(1, max(0, norm)))
                let r = geo.size.width / 2 - 4
                Path { p in
                    let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x + cos(a.radians) * r, y: c.y + sin(a.radians) * r))
                }
                .stroke(StudioTokens.text, lineWidth: 1.5)
            }
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            dial
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragValue == nil { dragAnchor = shown }
                        // ~160 px of vertical travel spans the full range.
                        let span = range.upperBound - range.lowerBound
                        let delta = -Double(g.translation.height) / 160.0 * span
                        dragValue = min(range.upperBound, max(range.lowerBound, dragAnchor + delta))
                    }
                    .onEnded { _ in
                        if let dragValue { pending = dragValue; onCommit(dragValue) }
                        dragValue = nil
                    }
            )
            .onTapGesture(count: 2) { pending = resetValue; onCommit(resetValue) }
            // The accessibility element is the KNOB, not the whole column. It
            // used to be the column, which was fine when the column was a knob
            // and two static Texts — now the column also contains a text field
            // and two arrow buttons, and `children: .ignore` would have hidden
            // all three from VoiceOver the day they were added.
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(format(shown))
            .accessibilityAdjustableAction { direction in
                // Deliberately NOT the arrows' step: this is the knob's own
                // coarse travel (a fortieth of the range), and the arrows sit
                // next to it as separate, finer, unit-aware buttons.
                let step = (range.upperBound - range.lowerBound) / 40
                let v = max(range.lowerBound,
                            min(range.upperBound, shown + (direction == .increment ? step : -step)))
                pending = v; onCommit(v)
            }

            // lineLimit(1) + fixedSize() is not decoration here: this label
            // sits in a 46 pt column three-across, and an unconstrained Text
            // under that much width pressure wraps to one character per line.
            Text(label).font(.system(size: 7, weight: .bold)).foregroundStyle(StudioTokens.faint)
                .lineLimit(1).fixedSize()

            typedField()
        }
        .frame(width: 51)
        .onChange(of: value) { _, v in
            if let p = pending, abs(v - p) < 0.01 { pending = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - EQ mini view (honest RBJ response curve + draggable band nodes)

/// Draws the actual biquad magnitude response of the 4 bands (matching the
/// engine's RBJ cookbook), with a draggable node per band: vertical = gain,
/// horizontal = frequency. Each release sends one mix.eq command.
struct StudioEqMini: View {
    var bands: [StudioEqBand]
    var onCommit: (_ band: Int, _ freqHz: Double, _ gainDB: Double, _ q: Double) -> Void

    @State private var drag: (band: Int, freqHz: Double, gainDB: Double)?
    private let sampleRate = 48_000.0
    private let minF = 30.0, maxF = 18_000.0
    private let gainSpan = 15.0   // +/- dB shown on the curve

    private func effectiveBands() -> [StudioEqBand] {
        guard let drag else { return bands }
        var b = bands
        if drag.band < b.count {
            b[drag.band].freqHz = drag.freqHz
            b[drag.band].gainDB = drag.gainDB
        }
        return b
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let eb = effectiveBands()
            ZStack {
                // Zero line.
                Path { p in p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2)) }
                    .stroke(.white.opacity(0.08), lineWidth: 1)
                // Response curve.
                curvePath(bands: eb, w: w, h: h)
                    .stroke(StudioTokens.cyan.opacity(0.9), lineWidth: 1.5)
                // Band nodes.
                ForEach(eb) { band in
                    let x = freqToX(band.freqHz, w: w)
                    let y = gainToY(band.gainDB, h: h)
                    Circle().fill(nodeColor(band)).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                        .position(x: x, y: y)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let band = drag?.band ?? nearestBand(to: g.startLocation, w: w, h: h)
                        let f = xToFreq(min(w, max(0, g.location.x)), w: w)
                        let gain = yToGain(min(h, max(0, g.location.y)), h: h)
                        drag = (band, f, gain)
                    }
                    .onEnded { _ in
                        if let d = drag {
                            let q = d.band < bands.count ? bands[d.band].q : 1
                            onCommit(d.band, d.freqHz, d.gainDB, q)
                        }
                        drag = nil
                    }
            )
        }
        .background(StudioTokens.bg)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("EQ, 4 bands")
        .accessibilityValue(bands.map { String(format: "%.0f Hz %.0f dB", $0.freqHz, $0.gainDB) }.joined(separator: ", "))
    }

    private func nodeColor(_ band: StudioEqBand) -> Color {
        abs(band.gainDB) < 0.1 ? StudioTokens.faderCap : StudioTokens.cyan
    }

    private func curvePath(bands: [StudioEqBand], w: CGFloat, h: CGFloat) -> Path {
        var path = Path()
        let steps = max(24, Int(w / 3))
        for i in 0...steps {
            let x = CGFloat(i) / CGFloat(steps) * w
            let f = xToFreq(x, w: w)
            var db = 0.0
            for band in bands { db += StudioBiquad.magnitudeDB(kind: band.kind, sampleRate: sampleRate, freqHz: band.freqHz, gainDB: band.gainDB, q: band.q, at: f) }
            let y = gainToY(db, h: h)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    // Log-frequency x-axis; linear-dB y-axis centered on 0.
    private func freqToX(_ f: Double, w: CGFloat) -> CGFloat {
        let t = (log10(max(minF, min(maxF, f))) - log10(minF)) / (log10(maxF) - log10(minF))
        return CGFloat(t) * w
    }
    private func xToFreq(_ x: CGFloat, w: CGFloat) -> Double {
        let t = Double(x / max(1, w))
        return pow(10, log10(minF) + t * (log10(maxF) - log10(minF)))
    }
    private func gainToY(_ db: Double, h: CGFloat) -> CGFloat {
        h / 2 - CGFloat(max(-gainSpan, min(gainSpan, db)) / gainSpan) * (h / 2 - 3)
    }
    private func yToGain(_ y: CGFloat, h: CGFloat) -> Double {
        Double((h / 2 - y) / (h / 2 - 3)) * gainSpan
    }
    private func nearestBand(to p: CGPoint, w: CGFloat, h: CGFloat) -> Int {
        var best = 0; var bestD = CGFloat.greatestFiniteMagnitude
        for band in bands {
            let d = abs(freqToX(band.freqHz, w: w) - p.x)
            if d < bestD { bestD = d; best = band.index }
        }
        return best
    }
}

/// RBJ cookbook biquad magnitude (dB) at a frequency, mirroring the engine's
/// `render::dsp::biquad` so the curve shows exactly what will render.
enum StudioBiquad {
    static func magnitudeDB(kind: StudioEqBandKind, sampleRate: Double, freqHz: Double, gainDB: Double, q: Double, at f: Double) -> Double {
        if abs(gainDB) < 1e-6 { return 0 }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * min(max(10, freqHz), sampleRate * 0.45) / sampleRate
        let (sinW0, cosW0) = (sin(w0), cos(w0))
        let alpha = sinW0 / (2 * max(0.05, min(10, q)))
        let rootA = a.squareRoot()
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch kind {
        case .bell:
            b0 = 1 + alpha * a; b1 = -2 * cosW0; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosW0; a2 = 1 - alpha / a
        case .lowShelf:
            let tra = 2 * rootA * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW0 + tra)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
            b2 = a * ((a + 1) - (a - 1) * cosW0 - tra)
            a0 = (a + 1) + (a - 1) * cosW0 + tra
            a1 = -2 * ((a - 1) + (a + 1) * cosW0)
            a2 = (a + 1) + (a - 1) * cosW0 - tra
        case .highShelf:
            let tra = 2 * rootA * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW0 + tra)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
            b2 = a * ((a + 1) + (a - 1) * cosW0 - tra)
            a0 = (a + 1) - (a - 1) * cosW0 + tra
            a1 = 2 * ((a - 1) - (a + 1) * cosW0)
            a2 = (a + 1) - (a - 1) * cosW0 - tra
        }
        // Normalize and evaluate |H(e^jw)| at f.
        let (nb0, nb1, nb2, na1, na2) = (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
        let w = 2 * Double.pi * f / sampleRate
        let numRe = nb0 + nb1 * cos(w) + nb2 * cos(2 * w)
        let numIm = -(nb1 * sin(w) + nb2 * sin(2 * w))
        let denRe = 1 + na1 * cos(w) + na2 * cos(2 * w)
        let denIm = -(na1 * sin(w) + na2 * sin(2 * w))
        let num = (numRe * numRe + numIm * numIm).squareRoot()
        let den = (denRe * denRe + denIm * denIm).squareRoot()
        guard den > 0, num > 0 else { return 0 }
        return 20 * log10(num / den)
    }
}

// MARK: - Meter bar (peak + block RMS)

/// A vertical dBFS meter: a filled RMS body with a bright peak tick.
struct StudioMeterBar: View {
    var peakDB: Double
    var rmsDB: Double
    var width: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let rmsFill = CGFloat(StudioMeterScale.norm(rmsDB)) * h
            let peakY = h - CGFloat(StudioMeterScale.norm(peakDB)) * h
            ZStack(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: StudioTokens.good, location: 0),
                        .init(color: StudioTokens.good, location: 0.7),
                        .init(color: StudioTokens.warn, location: 0.88),
                        .init(color: StudioTokens.bad, location: 1),
                    ], startPoint: .bottom, endPoint: .top)
                    .frame(height: max(0, rmsFill))
                if peakDB > StudioMeterScale.floorDB {
                    Rectangle().fill(.white)
                        .frame(height: 1.5)
                        .offset(y: -(h - peakY) + 0.75)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .offset(y: peakY)
                }
            }
        }
        .frame(width: width)
        .background(StudioTokens.bg)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityLabel("Level")
        .accessibilityValue(peakDB <= StudioMeterScale.floorDB ? "silent" : String(format: "peak %.0f dB", peakDB))
    }
}
