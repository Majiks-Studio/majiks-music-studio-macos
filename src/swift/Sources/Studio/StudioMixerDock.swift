import SwiftUI

// MARK: - Mixer dock (bottom, collapsible)
//
// L12: every strip control drives the command bus (mix.gain/pan/eq/send,
// track.mute/solo) and reads engine truth back from the snapshot. Controls hold
// their own value only while under gesture (the edit-guard), so the 30 Hz poll
// never fights a drag, and an agent's fader move shows up here on the next poll.
// The master strip carries the true-peak limiter, integrated + short-term LUFS,
// correlation, and gain reduction. Collapsed, a master mini-strip stays.

struct StudioMixerDock: View {
    @ObservedObject var model: StudioViewModel

    /// Intrinsic height of a channel strip, measured with ImageRenderer through
    /// the same path StudioMixerEvidence renders (258 pt for a channel strip,
    /// 257 for master). The dock used to be pinned at 236, which silently
    /// clipped the bottom 42 pt off every strip: the M / S buttons were not
    /// drawn at all and so could never be clicked. `StudioMixerDockTests`
    /// re-measures and fails if a strip ever outgrows the dock again.
    /// 258 -> 276 in the typed-controls lane, and the number is MEASURED, not
    /// chosen: `StudioMixerDockTests` renders the real strips and reported 281
    /// (channel) and 296 (master) once the knobs and the fader grew an editable
    /// number and a pair of arrows. 296 - 2 * 10 pt of padding is 276. Shipping
    /// the old 258 would have clipped the bottom 18 pt off every strip, which
    /// is the exact failure the comment above describes.
    nonisolated static let stripHeight: CGFloat = 276
    nonisolated static let stripVerticalPadding: CGFloat = 10
    nonisolated static var dockHeight: CGFloat { stripHeight + stripVerticalPadding * 2 }

    /// The live height of the strip region, owned by the shell because the user
    /// drags it there. `StudioPaneSizing.mixer` will not clamp it below
    /// `dockHeight`, which is the whole invariant the tests above protect: this
    /// region CLIPS rather than scrolls, so a shorter one does not draw a
    /// smaller mixer, it stops drawing the bottom of every strip.
    var stripsHeight: CGFloat = StudioMixerDock.dockHeight

    /// Horizontal geometry of the strip row, NAMED rather than inlined because
    /// the regression test derives "how many strips overflow a dock this wide"
    /// from these numbers instead of pinning a track count. That is the whole
    /// point: the last regression here was a strip growing 112 -> 173 pt, which
    /// moved the overflow threshold by a third of a track. A test that pinned
    /// "three tracks" would have gone on passing; one that recomputes from the
    /// real width cannot.
    nonisolated static let stripSpacing: CGFloat = 10
    nonisolated static let stripRowHorizontalPadding: CGFloat = 14
    /// One press of a chevron moves the row by exactly one channel.
    nonisolated static var stripPitch: CGFloat { StudioMixerStrip.width + stripSpacing }

    @State private var stripsWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    /// How far the row is slid to the left, in points. Explicit, clamped, and
    /// moved only by the two chevrons — see `strips` for why this is not a
    /// ScrollView.
    @State private var scrollX: CGFloat = 0

    private var master: StudioMasterSnapshot { model.snapshot?.master ?? StudioMasterSnapshot() }

    private var layout: StudioMixerStripLayout {
        StudioMixerStripLayout(contentWidth: stripsWidth,
                               viewportWidth: viewportWidth,
                               scrollX: scrollX)
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(StudioTokens.stroke).frame(height: 1)
            header
            if !model.mixerCollapsed {
                strips
                    // Top-aligned: dragged TALLER than a strip, the extra is
                    // empty panel BELOW the strips rather than a gap above them.
                    // See `StudioPaneSizing.mixer` for why growing this is of
                    // limited use today, and for the floor that keeps it from
                    // going shorter. There is deliberately no second
                    // `max(dockHeight, …)` here: one rule, in one place — a
                    // duplicate guard would mask a broken clamp.
                    .frame(height: stripsHeight, alignment: .top)
                    .clipped()
            }
        }
        .background(StudioTokens.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mixer")
    }

    /// The strip row. There is NO horizontal ScrollView here at any strip
    /// count, and that is the fix, not an optimisation.
    ///
    /// On macOS a horizontal ScrollView claims the mouse-DOWN as a possible
    /// pan. That cancels a `Button` press (M / S / LIM) and steals the knob and
    /// fader `DragGesture(minimumDistance: 0)` out from under the pointer — the
    /// same failure that made the Settings tab strip feel dead until it was
    /// rendered as a plain row. Enlarging the chips does nothing: the press
    /// never reaches them whatever size they are.
    ///
    /// This shipped twice. `607e7ac` removed the ScrollView but left it as an
    /// overflow fallback; `5d8491d` then widened a strip 112 -> 173 pt, which
    /// dropped the overflow threshold far enough that an ORDINARY three-track
    /// session with the Copilot dock open landed in the fallback and the M / S
    /// chips went dead again. A conditional ScrollView is a trap that arms
    /// itself the next time anything on a strip gets wider, so the condition is
    /// gone with it.
    ///
    /// Reaching the far strips is what the ScrollView was there for, so that
    /// job moves to an explicit `.offset(x:)` driven by two chevrons — the same
    /// idiom `StudioFxChainStrip` already uses for a row that outgrows its
    /// viewport, and the same `.offset` + `.clipped()` shape the track headers
    /// use vertically. A transform moves pixels; it never claims a click.
    ///
    /// The chevrons are always present (disabled at the ends) rather than
    /// appearing on overflow. Two reasons: a control that appears and vanishes
    /// is one a person at couch distance cannot learn, and — the mechanical
    /// one — a chevron that appeared on overflow would change the viewport
    /// width, which changes whether it is overflowing. That feedback loop is
    /// the same shape as the bug above.
    private var strips: some View {
        HStack(spacing: 0) {
            nudge(-1, "chevron.left")
            // A GeometryReader, not `.frame(maxWidth: .infinity)`, and this was
            // MEASURED rather than reasoned: a flexible frame does not shrink
            // an inflexible child, so the row reported its full 1722 pt ideal
            // width, the HStack grew to match, and the whole thing overflowed
            // the dock CENTRED — which pushed both chevrons off screen and left
            // the first channels unreachable. A GeometryReader takes the
            // proposal exactly and lets its child overflow inside it, which is
            // the shape `StudioFxChainStrip` uses for the same reason.
            GeometryReader { geo in
                stripRow
                    .offset(x: -layout.clampedScrollX)
                    .onAppear { viewportWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in viewportWidth = w }
            }
            .clipped()
            // `.clipped()` clips PIXELS, not the hit region. Without this a
            // strip slid off the left edge still answers clicks from
            // underneath the chevron that slid it there.
            .contentShape(Rectangle())
            nudge(1, "chevron.right")
        }
    }

    /// Explicit horizontal transform, one channel per press, clamped — the
    /// whole reason there is no ScrollView above. Modelled on
    /// `StudioFxChainStrip.nudge`, deliberately: this repo already solved this
    /// problem once and the second solution should not be a new idea.
    private func nudge(_ direction: CGFloat, _ glyph: String) -> some View {
        let l = layout
        let enabled = direction < 0 ? l.canScrollLeft : l.canScrollRight
        return Button {
            scrollX = l.nudged(direction)
        } label: {
            Image(systemName: glyph).font(.system(size: 11, weight: .bold))
                // A generous target: the owner drives this from a couch, and
                // the chevron is now the ONLY way to reach a far channel.
                .frame(width: 20, height: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? StudioTokens.dim : StudioTokens.faint.opacity(0.4))
        .disabled(!enabled)
        .studioHelp(direction < 0 ? "mixer.scrollLeft" : "mixer.scrollRight")
        .accessibilityLabel(direction < 0 ? "Show earlier channels" : "Show later channels")
    }

    private var stripRow: some View {
        HStack(alignment: .top, spacing: Self.stripSpacing) {
            ForEach(model.snapshot?.tracks ?? []) { track in
                StudioMixerStrip(model: model, track: track)
            }
            StudioMasterStrip(model: model, master: master)
        }
        .padding(.horizontal, Self.stripRowHorizontalPadding)
        .padding(.vertical, Self.stripVerticalPadding)
        // Measured on the row's own ideal width (before the maxWidth stretch
        // above), so the scroll clamp can never feed back on itself.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: MixerStripsWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(MixerStripsWidthKey.self) { stripsWidth = $0 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.mixerCollapsed.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.mixerCollapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                    // "MIXER" when folded: the word VOLUME is the
                    // reason this strip exists as the only evidence of the
                    // dock. "MASTER" alone is DAW jargon for the finished mix
                    // and never answered "where do I control volume?".
                    Text(model.mixerCollapsed ? "MIXER · VOLUME" : "MIXER")
                        .font(.system(size: 9, weight: .bold))
                        .kerning(1)
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(StudioTokens.dim)
            }
            .buttonStyle(.plain)
            .studioHelp(model.mixerCollapsed ? "mixer.expand" : "mixer.collapse")
            .accessibilityLabel(model.mixerCollapsed ? "Show mixer" : "Hide mixer")

            if model.mixerCollapsed {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(StudioTokens.purple).frame(width: 7, height: 7)
                    Text(collapsedVolumeReadout)
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(StudioTokens.dim)
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .studioHelp("mixer.masterMini")
                .accessibilityLabel("Master volume")
                .accessibilityValue(collapsedVolumeReadout)
            }
            Spacer()
            // Undo / redo (mixer + automation moves round-trip through the bus).
            // The glyphs are 10 pt; without an explicit frame + contentShape the
            // clickable area is the glyph itself (~12x11 pt), which is why they
            // felt like they needed a pixel-perfect click.
            HStack(spacing: 8) {
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(StudioTokens.dim)
                .keyboardShortcut("z", modifiers: .command)
                .studioHelp("mixer.undo")
                .accessibilityLabel("Undo")
                Button { model.redo() } label: {
                    Image(systemName: "arrow.uturn.forward").font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(StudioTokens.dim)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .studioHelp("mixer.redo")
                .accessibilityLabel("Redo")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Collapsed strip readout. Leads with the master fader level in dB — the
    /// number a non-DAW user means by "volume" — and keeps LUFS as a quieter
    /// second fact for anyone who already cares. Pure so a shape test can pin
    /// the leading "dB" without rendering.
    var collapsedVolumeReadout: String {
        let gain = String(format: "%+.1f dB", master.volumeDB)
        let lufs = master.lufsIntegrated
        let lufsText = lufs.map { String(format: "%.1f LUFS", $0) } ?? "LUFS pending"
        return "\(gain) · \(lufsText)"
    }
}

/// Ideal width of the strip row. With the viewport width the GeometryReader
/// reports, it is one of the only two inputs the scroll clamp has.
private struct MixerStripsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - The mixer's horizontal transform, as pure math
//
// Split out of the view for one reason: "every channel is REACHABLE" is the
// promise the deleted ScrollView used to keep, and it has to be checkable
// without a window. A clamp that is off by one strip does not crash, does not
// change a pixel test, and does not fail a build — it just makes the last
// channel permanently unreachable, which is the same class of dead control the
// ScrollView caused at the other end.

/// Where the strip row sits inside its viewport, and how far the chevrons can
/// move it.
struct StudioMixerStripLayout: Equatable, Sendable {
    /// Ideal width of the whole strip row, padding included.
    var contentWidth: CGFloat = 0
    /// Width actually available between the two chevrons.
    var viewportWidth: CGFloat = 0
    /// Requested offset. May be stale after a track is deleted, which is why
    /// nothing reads it directly — read `clampedScrollX`.
    var scrollX: CGFloat = 0
    /// One press moves one channel.
    var pitch: CGFloat = StudioMixerDock.stripPitch

    /// `max(1, …)` on the viewport so a not-yet-measured layout (width 0, which
    /// is what the very first pass reports) cannot claim the row is scrollable
    /// by its own full width and strand the user mid-row before anything has
    /// been drawn.
    var maxScroll: CGFloat { max(0, contentWidth - max(1, viewportWidth)) }

    var clampedScrollX: CGFloat { min(maxScroll, max(0, scrollX)) }

    /// Half a point of slack, matching the overflow epsilon this dock has used
    /// since the strips were first measured: floating-point widths land a few
    /// thousandths off and an exact compare leaves a chevron enabled that
    /// cannot move anything.
    var canScrollLeft: Bool { clampedScrollX > 0.5 }
    var canScrollRight: Bool { clampedScrollX < maxScroll - 0.5 }

    /// The row is wider than the space it has, so some channel is off-screen
    /// right now and the chevrons are the only way to it.
    var isOverflowing: Bool { maxScroll > 0.5 }

    func nudged(_ direction: CGFloat) -> CGFloat {
        min(maxScroll, max(0, clampedScrollX + direction * pitch))
    }
}

// MARK: - One channel strip

struct StudioMixerStrip: View {
    @ObservedObject var model: StudioViewModel
    let track: StudioTrackSnapshot

    /// 112 -> 173. A knob column is 51 pt now (a 34 pt number field plus a
    /// 13 pt arrow stack), and three of them plus the 2 pt gaps is 157 pt
    /// inside 8 pt padding. The alternative was keeping 112 and letting the
    /// three columns compress, which on macOS does not shrink a TextField —
    /// it clips it, and a clipped number field is a control you cannot read
    /// what you typed into.
    ///
    /// A named constant rather than a literal in `body` because that 54 %
    /// widening is what re-broke the mixer: it moved the point at which the
    /// dock overflowed, and the tests could not see the number that moved.
    /// `StudioMixerHitTestingTests` now builds its overflow case FROM this, so
    /// widening a strip again cannot outrun its own regression test.
    nonisolated static let width: CGFloat = 173

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(StudioTokens.stemColor(track.kind))
                    .frame(width: 7, height: 7)
                Text(track.name).font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(StudioTokens.text).lineLimit(1)
                Spacer(minLength: 0)
            }

            StudioEqMini(bands: track.eq) { band, f, g, q in
                model.setTrackEq(track.id, band: band, freqHz: f, gainDB: g, q: q)
            }
            .frame(height: 34)
            .studioHelp("mixer.strip.eq")

            HStack(spacing: 2) {
                panKnob.studioHelp("mixer.strip.pan")
                sendKnob(.a).studioHelp("mixer.strip.sendA")
                sendKnob(.b).studioHelp("mixer.strip.sendB")
            }

            HStack(alignment: .center, spacing: 8) {
                gainFader.studioHelp("mixer.strip.fader")
                StudioMeterBar(peakDB: track.meter.peakDB, rmsDB: track.meter.rmsDB)
                    .studioHelp("mixer.strip.meter")
            }
            .frame(height: 96)

            HStack(spacing: 4) {
                stateChip("M", on: track.muted,
                          label: track.muted ? "Unmute \(track.name)" : "Mute \(track.name)",
                          helpID: track.muted ? "mixer.unmute" : "mixer.mute") {
                    model.setTrackMute(track.id, muted: !track.muted)
                }
                stateChip("S", on: track.soloed,
                          label: track.soloed ? "Unsolo \(track.name)" : "Solo \(track.name)",
                          helpID: track.soloed ? "mixer.unsolo" : "mixer.solo") {
                    model.setTrackSolo(track.id, soloed: !track.soloed)
                }
            }
        }
        .padding(8)
        .frame(width: Self.width)
        .background(StudioTokens.panelHi)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTokens.stroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(track.name) channel strip")
    }

    // MARK: The strip's three numeric controls
    //
    // Exposed as properties rather than inlined in `body` for the reason this
    // codebase keeps paying for: a control can compile, appear, and be wired to
    // nothing. `StudioTypedControlTests` builds the REAL strip and drives
    // `panKnob.typedField().submit("L40")`, so the assertion is about the
    // command the mixer's own pan knob sends — not about a knob a test built
    // that happens to look like it.
    //
    // `unit:` is what makes the typed field and the arrows mean something: pan
    // reads and prints L/C/R percentages, the sends read and print 0-100 %.
    // Neither is the raw -1...1 / 0...1 the wire carries, and a field that
    // demanded the wire number would be a second notation for a control that
    // already prints a first one.

    var panKnob: StudioKnob {
        StudioKnob(value: track.pan, range: -1...1, resetValue: 0, label: "PAN",
                   unit: .pan, accent: StudioTokens.purple, format: Self.panLabel) {
            model.setTrackPan(track.id, pan: $0)
        }
    }

    func sendKnob(_ bus: StudioSendBus) -> StudioKnob {
        StudioKnob(value: bus == .a ? track.sendA : track.sendB,
                   range: 0...1, resetValue: 0, label: bus == .a ? "REV" : "DLY",
                   unit: .percent, format: Self.pctLabel) {
            model.setTrackSend(track.id, bus: bus, amount: $0)
        }
    }

    /// The strip's static "-6.0 dB" readout is GONE, and its help id moved onto
    /// the fader's own typed field — same number, same place on screen, except
    /// you can now type into it. Two copies of one value, one of them editable,
    /// is how a user ends up typing into the dead one.
    var gainFader: StudioFaderControl {
        StudioFaderControl(value: track.volumeDB,
                           accent: StudioTokens.stemColor(track.kind),
                           helpID: "mixer.strip.gainReadout") {
            model.setTrackGain(track.id, gainDB: $0)
        }
    }

    static func panLabel(_ p: Double) -> String {
        if abs(p) < 0.02 { return "C" }
        return p < 0 ? "L\(Int((-p * 100).rounded()))" : "R\(Int((p * 100).rounded()))"
    }
    static func pctLabel(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func stateChip(
        _ title: String, on: Bool, label: String, helpID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 9, weight: .heavy))
                .frame(width: 22, height: 16)
                .background(on ? StudioTokens.warn : StudioTokens.panelHi)
                .foregroundStyle(on ? Color.black.opacity(0.8) : StudioTokens.dim)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(on ? StudioTokens.warn : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        // "M" and "S" are the two most-guessed-at letters in any DAW. The
        // tooltip says what they DO; the VoiceOver label keeps naming the track.
        .studioHelp(helpID)
        .accessibilityLabel(label)
    }
}

// MARK: - Master strip

struct StudioMasterStrip: View {
    @ObservedObject var model: StudioViewModel
    let master: StudioMasterSnapshot

    /// Wider than a channel strip: it carries the limiter, both LUFS readouts
    /// and correlation. Named for the same reason `StudioMixerStrip.width` is —
    /// the row's total width is computed from these two in one place.
    nonisolated static let width: CGFloat = 190

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(StudioTokens.purple).frame(width: 7, height: 7)
                Text("MASTER").font(.system(size: 10, weight: .heavy)).foregroundStyle(StudioTokens.text)
                Spacer(minLength: 0)
            }

            loudnessReadout

            limiterControls

            HStack(alignment: .center, spacing: 8) {
                gainFader.studioHelp("mixer.master.fader")
                StudioMeterBar(peakDB: master.meter.peakDB, rmsDB: master.meter.rmsDB)
                    .studioHelp("mixer.master.meter")
                StudioMeterBar(peakDB: master.meter.truePeakDB, rmsDB: master.meter.truePeakDB - 4)
                    .studioHelp("mixer.master.meter")
            }
            .frame(height: 96)

            // The master gain half of this line moved INTO the fader's typed
            // field. What is left is the true-peak reading, which is a
            // measurement rather than a setting and so has nothing to type.
            Text("TP \(fmt(master.meter.truePeakDB, "dBTP"))")
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .foregroundStyle(StudioTokens.dim)
                .lineLimit(1).fixedSize()
        }
        .padding(8)
        // 158 -> 190, for the same reason the channel strip grew: the limiter
        // row now carries two knob columns at 51 pt each beside the LIM button
        // and the gain-reduction readout.
        .frame(width: Self.width)
        .background(StudioTokens.panelHi)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTokens.purple.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Master strip")
    }

    private var loudnessReadout: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("LUFS").font(.system(size: 7, weight: .heavy)).foregroundStyle(StudioTokens.faint)
                Spacer()
                Text("CORR").font(.system(size: 7, weight: .heavy)).foregroundStyle(StudioTokens.faint)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(fmt(master.lufsIntegrated, "")).font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(StudioTokens.text).lineLimit(1)
                Text("I").font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTokens.faint)
                Spacer(minLength: 0)
                correlationDot
            }
            HStack(spacing: 3) {
                Text("short").font(.system(size: 7, weight: .bold)).foregroundStyle(StudioTokens.faint)
                Text(fmt(master.lufsShortTerm, "")).font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StudioTokens.dim).lineLimit(1)
                Text("S").font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTokens.faint)
                Spacer(minLength: 0)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(StudioTokens.bg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .studioHelp("mixer.master.lufs")
    }

    private var correlationDot: some View {
        let c = master.correlation
        let color: Color = {
            guard let c else { return StudioTokens.faint }
            if c < 0 { return StudioTokens.bad }
            if c < 0.4 { return StudioTokens.warn }
            return StudioTokens.good
        }()
        return HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(c.map { String(format: "%+.2f", $0) } ?? "--")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(StudioTokens.dim)
        }
        .studioHelp("mixer.master.correlation")
        .accessibilityLabel("Correlation")
        .accessibilityValue(master.correlation.map { String(format: "%.2f", $0) } ?? "silent")
    }

    private var limiterControls: some View {
        HStack(spacing: 4) {
            Button {
                model.setLimiter(enabled: !master.limiterEnabled,
                                 ceilingDB: master.limiterCeilingDBTP, releaseMs: master.limiterReleaseMs)
            } label: {
                Text("LIM").font(.system(size: 8, weight: .heavy))
                    .frame(width: 26, height: 26)
                    .background(master.limiterEnabled ? StudioTokens.good.opacity(0.22) : StudioTokens.panelHi)
                    .foregroundStyle(master.limiterEnabled ? StudioTokens.good : StudioTokens.dim)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(master.limiterEnabled ? StudioTokens.good.opacity(0.6) : StudioTokens.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .studioHelp(master.limiterEnabled ? "mixer.master.limiter.on" : "mixer.master.limiter.off")
            .accessibilityLabel(master.limiterEnabled ? "Disable limiter" : "Enable limiter")

            ceilingKnob.studioHelp("mixer.master.ceiling")
            releaseKnob.studioHelp("mixer.master.release")
            VStack(spacing: 1) {
                Text("GR").font(.system(size: 7, weight: .heavy)).foregroundStyle(StudioTokens.faint)
                Text(master.meter.gainReductionDB > 0.05
                     ? String(format: "-%.1f", master.meter.gainReductionDB) : "0.0")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(master.meter.gainReductionDB > 0.05 ? StudioTokens.warn : StudioTokens.dim)
            }
            .frame(maxWidth: .infinity)
            .studioHelp("mixer.master.gainReduction")
        }
    }

    // MARK: The master strip's three numeric controls
    //
    // Same reasoning as `StudioMixerStrip`'s: exposed so a test can drive the
    // real ones. The limiter's two knobs are the sharpest case in the mixer for
    // typing — a true-peak ceiling is chosen as a number ("-1 dBTP", because
    // that is what the encoder needs), never found by dragging a 30 pt circle.

    var gainFader: StudioFaderControl {
        StudioFaderControl(value: master.volumeDB, accent: StudioTokens.purple,
                           helpID: "mixer.master.readout") {
            model.setMasterGain($0)
        }
    }

    var ceilingKnob: StudioKnob {
        StudioKnob(value: master.limiterCeilingDBTP, range: -6...0, resetValue: -1,
                   label: "CEIL", unit: .decibels, accent: StudioTokens.purple,
                   format: { String(format: "%.1f", $0) }) {
            model.setLimiter(enabled: master.limiterEnabled, ceilingDB: $0,
                             releaseMs: master.limiterReleaseMs)
        }
    }

    var releaseKnob: StudioKnob {
        StudioKnob(value: master.limiterReleaseMs, range: 1...1000, resetValue: 50,
                   label: "REL", unit: .milliseconds, accent: StudioTokens.purple,
                   format: { "\(Int($0.rounded()))" }) {
            model.setLimiter(enabled: master.limiterEnabled,
                             ceilingDB: master.limiterCeilingDBTP, releaseMs: $0)
        }
    }

    private func fmt(_ v: Double?, _ unit: String) -> String {
        guard let v, v > -120 else { return "--" }
        return unit.isEmpty ? String(format: "%.1f", v) : String(format: "%.1f %@", v, unit)
    }
}
