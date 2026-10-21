import SwiftUI

// MARK: - The on-screen keyboard
//
// The no-hardware path to "press a key, hear a note". Someone who downloads this
// with no MIDI gear had, before this existed, no way to play an instrument at
// all: the only note-triggering surface in the app was the piano roll's vertical
// gutter, which is a row LABEL for a grid, not an instrument.
//
// This is a different object from that gutter and does not replace it. The
// gutter is vertical because in a piano roll pitch is the Y axis and time is the
// X axis, so the keys label the rows; rotating it would destroy the grid's
// meaning. THIS is a keyboard: horizontal, at the bottom, laid out the way the
// instrument it imitates is laid out.
//
// ── One note path ─────────────────────────────────────────────────────────
//
// Every key here goes out through `onNote`, which StudioRootView wires to the
// SAME `previewNote` the hardware MIDI pump and the roll's gutter use. There is
// no second note path: a screen key and a cable key sound through the same
// engine call, are buffered by the same retro-capture buffer, and are kept by
// the same Keep. Building a parallel path is how the two halves of E1 drifted
// apart and shipped a piano roll wired to a mock.
//
// ── No ScrollView ─────────────────────────────────────────────────────────
//
// See the note at the top of StudioKeyboardMath.swift. The keys are drawn into a
// Canvas (not 128 Buttons, following the roll's gutter) and panned with an
// explicit octave control (not a horizontal ScrollView, whose macOS hit-testing
// silently eats clicks — which on a keyboard would be total failure).

// The controller lives in StudioKeyboardController.swift — same three-part split
// the piano roll uses (math / controller / view), so the parts a test can drive
// without a view are in files with no SwiftUI in them.

// MARK: - The pane

struct StudioOnScreenKeyboardPane: View {
    @ObservedObject var controller: StudioKeyboardController
    @ObservedObject var model: StudioViewModel

    /// The pane's default height — the number this pane shipped with, kept as a
    /// named constant so `StudioPaneSizing.keyboard` and the view cannot drift.
    nonisolated static let defaultHeight: CGFloat = 132

    /// The live height, owned by the shell because the user drags it there.
    var height: CGFloat = StudioOnScreenKeyboardPane.defaultHeight

    /// Pitches the ENGINE says are sounding — hardware MIDI included. Lighting
    /// from this rather than from `controller.held` is what makes a USB keyboard
    /// light the on-screen keys too.
    ///
    /// This was already true of the engine and already proven there
    /// (`agent-surface/tests/play_a_note.rs`), and it still did not reach a human
    /// eye: `RealStudioEngine.snapshot(ifNewerThan:)` early-returned nil whenever
    /// the journal seq had not moved and the transport was stopped, and playing a
    /// note is deliberately journal-silent and deliberately does not roll the
    /// transport. So the app never adopted a snapshot while someone was playing.
    /// Fixed at that gate; the line below is unchanged and was never the problem.
    private var engineSounding: Set<UInt8> {
        Set(model.snapshot?.performance.sounding ?? [])
    }

    var body: some View {
        HStack(spacing: 0) {
            controlRail
            Divider().overlay(StudioTokens.stroke)
            keysCanvas
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(StudioTokens.panel)
        .overlay(alignment: .top) { Divider().overlay(StudioTokens.stroke) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On-screen keyboard")
        // Hand every snapshot's sounding set to the controller, which applies the
        // minimum lit time and learns the plugged-in instrument's range from it.
        .onAppear { controller.observeSounding(engineSounding) }
        .onChange(of: model.snapshot?.performance.sounding ?? []) { _, fresh in
            controller.observeSounding(Set(fresh))
        }
    }

    // MARK: Left rail — octave, velocity, and the Keep affordance

    private var controlRail: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                keepButton
                discardButton
            }
            octaveControl
            spanControl
            velocityControl
            if !controller.isWired {
                Text("Silent build")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTokens.warn)
                    .help("This build is running on the mock engine, so the keys draw but make no sound.")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 186, alignment: .leading)
    }

    /// THE difference between hearing and keeping, said in words a person
    /// already has. Never "arm", never "record": you played something, this
    /// keeps it. The count is live, so it is visibly true rather than a promise.
    private var keepButton: some View {
        let count = model.snapshot?.performance.keepableNotes ?? 0
        return Button {
            Task { await model.keepPerformance() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 10))
                Text(count > 0 ? "Keep \(count) note\(count == 1 ? "" : "s")" : "Keep")
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(count > 0 ? StudioTokens.purple.opacity(0.30) : StudioTokens.panelHi))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(count > 0 ? StudioTokens.purple : StudioTokens.stroke, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .help(count > 0
            ? "Put the \(count) note\(count == 1 ? "" : "s") you just played into the project. One undo takes it back."
            : "Play something and this will keep it. Nothing needs to be armed first.")
        .accessibilityLabel(count > 0 ? "Keep the \(count) notes you just played" : "Nothing to keep yet")
    }

    /// THROW IT AWAY. The other half of Keep, and Keep shipped without it.
    ///
    /// The buffer is a rolling 128 beats, so a bad pass and a good pass sit in
    /// the same count: before this, the only ways to get rid of a bad take were
    /// to keep everything and press Cmd-Z, or to stop playing and wait a minute
    /// for it to roll off. "How do I not keep notes?" was a fair question with
    /// no answer on screen.
    ///
    /// DESTRUCTIVE-BUT-SAFE, and the shape says so: it is styled as a warning
    /// rather than an error, it names the count it will throw away, and its help
    /// text says in words that nothing already in the project can be reached by
    /// it. No confirmation dialog — the thing it destroys was never saved, and a
    /// dialog on every discard would teach a person that discarding is dangerous
    /// when the point of it is that it is not.
    private var discardButton: some View {
        let count = model.snapshot?.performance.keepableNotes ?? 0
        return Button {
            Task { await model.discardPerformance() }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 10))
                .padding(.vertical, 5)
                .padding(.horizontal, 7)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(count > 0 ? StudioTokens.warn.opacity(0.22) : StudioTokens.panelHi))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(count > 0 ? StudioTokens.warn : StudioTokens.stroke, lineWidth: 0.8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .help(count > 0
            ? "Throw away the \(count) note\(count == 1 ? "" : "s") you just played, without " +
              "putting any of them in the project. It cannot touch anything already in your " +
              "song — only what you have played and not kept — so nothing you have made can " +
              "be lost. There is nothing to undo afterwards; just play again."
            : "Once you have played something, this throws it away instead of keeping it. It " +
              "only ever reaches notes you have played and not kept, never anything already " +
              "in your song.")
        .accessibilityLabel(count > 0
            ? "Throw away the \(count) notes you just played"
            : "Nothing to throw away yet")
        .accessibilityHint("Empties what you have played without adding it to the project")
    }

    private var octaveControl: some View {
        // A plain HStack of Buttons, NOT a horizontal ScrollView — the tab-strip
        // lesson in SettingsView.swift.
        HStack(spacing: 4) {
            Button { controller.shiftOctave(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(controller.basePitch <= StudioKeyboardOctave.lowest)
            .help("Down an octave (Z)")
            .accessibilityLabel("Down an octave")

            Text(StudioPitchName.label(controller.basePitch))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioTokens.dim)
                .frame(minWidth: 34)

            Button { controller.shiftOctave(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(controller.basePitch >= StudioKeyboardSpan.clampBase(127, octaves: controller.octaves))
            .help("Up an octave (X)")
            .accessibilityLabel("Up an octave")

            Text("–\(StudioPitchName.label(controller.topPitch))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(StudioTokens.faint)
        }
        .foregroundStyle(StudioTokens.text)
    }

    /// HOW MANY OCTAVES ARE ON SCREEN — the answer to "can the keyboard match my
    /// physical keys". Plain Buttons in an HStack, never a horizontal ScrollView.
    ///
    /// Next to it, the fit toggle. It is a toggle rather than a dialog because
    /// the app cannot ask a controller how many keys it has (MIDI carries no such
    /// message) but it CAN widen to cover every pitch it has actually received,
    /// which needs no answer from the user at all. See `StudioKeyboardSpan`.
    private var spanControl: some View {
        HStack(spacing: 4) {
            Button { controller.setOctaves(controller.octaves - 1) } label: {
                Image(systemName: "minus").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(controller.octaves <= StudioKeyboardSpan.minimum)
            .help("Show one octave fewer")
            .accessibilityLabel("Show one octave fewer")

            Text("\(controller.octaves) oct")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioTokens.dim)
                .frame(minWidth: 34)

            Button { controller.setOctaves(controller.octaves + 1) } label: {
                Image(systemName: "plus").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(controller.octaves >= StudioKeyboardSpan.maximum)
            .help("Show one octave more")
            .accessibilityLabel("Show one octave more")

            Button { controller.fitsToHardware.toggle() } label: {
                Text("Fit")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(controller.fitsToHardware
                                ? StudioTokens.purple.opacity(0.30) : StudioTokens.panelHi))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(controller.fitsToHardware
                                ? StudioTokens.purple : StudioTokens.stroke, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help(fitHelp)
            .accessibilityLabel(controller.fitsToHardware
                ? "Fitting the keys to your MIDI keyboard" : "Not fitting the keys to your MIDI keyboard")
        }
        .foregroundStyle(StudioTokens.text)
    }

    /// Say what has actually been learned, not what the feature is called. A
    /// range that has been observed is a fact; before then this is honest that it
    /// has seen nothing yet.
    private var fitHelp: String {
        guard controller.fitsToHardware else {
            return "Not widening the keys. Turn this on and the keyboard grows to cover every note your MIDI instrument sends."
        }
        guard let learned = controller.learnedRange else {
            return "Widen the keys to cover whatever your MIDI instrument plays. MIDI cannot say how many keys a controller has, so this learns it from the notes that arrive — play the lowest and highest key once and the range is set."
        }
        return "Widened to cover \(StudioPitchName.label(learned.lowerBound))–\(StudioPitchName.label(learned.upperBound)), which is what your MIDI instrument has played so far."
    }

    private var velocityControl: some View {
        HStack(spacing: 5) {
            Text("Vel")
                .font(.system(size: 9))
                .foregroundStyle(StudioTokens.faint)
            Slider(
                value: Binding(
                    get: { Double(controller.typingVelocity) },
                    set: { controller.typingVelocity = Int($0.rounded()) }),
                in: Double(StudioKeyboardVelocity.minimum)...Double(StudioKeyboardVelocity.maximum))
            .controlSize(.mini)
            Text("\(controller.typingVelocity)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(StudioTokens.dim)
                .frame(width: 22, alignment: .trailing)
        }
        .help("How hard the computer keys play. A mouse click gets its velocity from where on the key you click — nearer the front is louder.")
    }

    // MARK: The keys

    private var keysCanvas: some View {
        GeometryReader { geo in
            let layout = StudioKeyboardLayout(
                basePitch: controller.basePitch,
                octaves: controller.octaves,
                size: geo.size)
            Canvas(opaque: false) { context, _ in
                draw(context: context, layout: layout)
            }
            .contentShape(Rectangle())
            .gesture(pointerGesture(layout))
            .focusable()
            .onKeyPress(phases: [.down, .up]) { press in
                guard let character = press.characters.first else { return .ignored }
                // Modifier chords belong to the menus and the roll's shortcuts.
                guard press.modifiers.isEmpty else { return .ignored }
                return controller.handleTyping(character, isDown: press.phase == .down)
                    ? .handled : .ignored
            }
        }
        .onDisappear { controller.releaseAll() }
    }

    private func draw(context: GraphicsContext, layout: StudioKeyboardLayout) {
        let lit = controller.lit
        // Batched into a handful of Paths, exactly like the roll's gutter: 128
        // separate fills per frame is the cost the roll already refused to pay.
        var whites = Path()
        var whitesLit = Path()
        var separators = Path()
        for key in layout.whiteKeys {
            let r = key.rect.insetBy(dx: 0.5, dy: 0)
            if lit.contains(key.pitch) { whitesLit.addRect(r) } else { whites.addRect(r) }
            separators.move(to: CGPoint(x: key.rect.maxX, y: 0))
            separators.addLine(to: CGPoint(x: key.rect.maxX, y: key.rect.maxY))
        }
        context.fill(whites, with: .color(Color(white: 0.88)))
        context.fill(whitesLit, with: .color(StudioTokens.purple))
        context.stroke(separators, with: .color(StudioTokens.stroke), lineWidth: 1)

        var blacks = Path()
        var blacksLit = Path()
        for key in layout.blackKeys {
            let r = RoundedRectangle(cornerRadius: 2).path(in: key.rect)
            if lit.contains(key.pitch) { blacksLit.addPath(r) } else { blacks.addPath(r) }
        }
        context.fill(blacks, with: .color(Color(white: 0.10)))
        context.fill(blacksLit, with: .color(StudioTokens.purple))

        // Octave labels on the C keys, so a player can find middle C without
        // counting. Same rule as the roll's gutter: label the octave, not
        // every key.
        //
        // SIZED FOR THE ROOM, NOT FOR A LAPTOP. These were 9 pt medium in mid
        // grey (white: 0.35) on an off-white key — fine at desk distance, and
        // unreadable on the 4K TV this is actually played on, which is the one
        // place a person needs to find middle C without counting. Bigger,
        // heavier, and much darker against the key. The width guard rises with
        // the type size so a squeezed keyboard drops the labels rather than
        // overlapping them.
        for key in layout.whiteKeys where StudioPitchName.isOctaveRoot(key.pitch) {
            guard layout.whiteWidth >= 17 else { break }
            context.draw(
                Text(StudioPitchName.label(key.pitch))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.14)),
                at: CGPoint(x: key.rect.midX, y: key.rect.maxY - 12))
        }
    }

    /// One DragGesture drives press, glissando and release — the same shape the
    /// piano roll uses. `minimumDistance: 0` so a plain click is a press, and
    /// sliding across keys retriggers, which is what a glissando IS.
    private func pointerGesture(_ layout: StudioKeyboardLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let pitch = layout.pitch(at: value.location) else {
                    controller.releaseAll()
                    return
                }
                if controller.held.contains(pitch) { return }
                // Sliding onto a new key releases the old one first, so a
                // glissando never strands a held note.
                controller.releaseAll()
                let keyHeight = StudioPitchName.isAccidental(pitch)
                    ? layout.size.height * StudioKeyboardLayout.blackHeightRatio
                    : layout.size.height
                controller.press(
                    pitch,
                    velocity: StudioKeyboardVelocity.from(y: value.location.y, keyHeight: keyHeight))
            }
            .onEnded { _ in controller.releaseAll() }
    }
}
