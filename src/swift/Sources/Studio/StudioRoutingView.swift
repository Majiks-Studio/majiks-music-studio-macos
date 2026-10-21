import SwiftUI

// MARK: - Routing + effects pane (E5-ui)
//
// The mixer's routing half: create and name buses, connect tracks into them,
// set each connection's level and its pre/post tap, and edit an insert chain on
// any track, bus or master.
//
// Three things about the construction, each of which has cost this codebase
// real time before:
//
//  1. There is NO horizontal ScrollView anywhere in here. On macOS a horizontal
//     ScrollView claims the mouse-down as a possible pan, which cancels Button
//     presses and steals `DragGesture(minimumDistance: 0)` out from under the
//     pointer — the failure that made the Settings tab strip feel dead. An
//     effect chain is exactly the shape that tempts one, so the chain row uses
//     an EXPLICIT transform (`StudioFxChainLayout.scrollX`) instead.
//  2. The chain slots are drawn with `Canvas` and hit-tested with layout math,
//     not built from a Button per slot — the same call the piano roll and the
//     on-screen keyboard make for dense repeated elements.
//  3. The pane's height is asserted against its content in
//     `StudioRoutingPaneTests`, because a container shorter than its content
//     clips silently and the clipped controls are simply never drawn. That is
//     how the mixer dock shipped with un-clickable M / S buttons.
//
// And the honest bit: this surface once said, permanently, that what it
// produced was stored but NOT yet audible. E5-graph landed the renderer, so
// that badge is GONE — routing and effects are audible, and every bus row
// carries a real meter read from the engine's node meter slots. Then the
// bus-fader and fx-param-automation lanes landed, and the surface narrowed its
// statements AGAIN: the "NO FADER" chip became a real fader (`route.node.set`),
// and the blanket automation note became a per-kind statement of exactly which
// keys the engine refuses (coefficients: EQ bands, attack/release) and why.
// A warning that outlives its gap is the inert-control bug mirrored. See
// `StudioRoutingCapability.fxAutomationNote(for:)` for the precise wording.

struct StudioRoutingPane: View {
    @ObservedObject var controller: StudioRoutingController

    /// The pane's DEFAULT height. Content that can grow (the host list, the
    /// send list, the parameter grid) scrolls VERTICALLY inside it; nothing is
    /// clipped. Still a static because `StudioRoutingPaneTests` measures
    /// against it and `StudioPaneSizing.routing` takes its default from it —
    /// the live height now comes in on `height`.
    nonisolated static let paneHeight: CGFloat = 300
    static let headerHeight: CGFloat = 30
    static let hostColumnWidth: CGFloat = 176

    /// The live height, owned by the shell because the user drags it there.
    /// Clamped by `StudioPaneSizing.routing`, whose minimum exists to keep the
    /// scrolling region below positive — see the comment on that spec.
    var height: CGFloat = StudioRoutingPane.paneHeight

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(StudioTokens.stroke).frame(height: 1)
            header
            HStack(spacing: 0) {
                hostColumn
                Rectangle().fill(StudioTokens.stroke).frame(width: 1)
                detailColumn
            }
            .frame(height: height - Self.headerHeight)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(StudioTokens.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Routing and effects")
    }

    // MARK: Header
    //
    // The "STORED, NOT YET AUDIBLE" badge that lived here is deliberately GONE:
    // E5-graph landed the renderer, so the badge's statement became false, and
    // an over-warning surface is the mirror image of the inert-control bug this
    // epic exists to kill. `testTheSurfaceDeclaresThatProcessingIsAudible` pins
    // the flip; the engine-absence warning below is a DIFFERENT statement (this
    // build does not publish a graph at all) and stays.

    private var header: some View {
        HStack(spacing: 10) {
            Text("ROUTING & FX")
                .font(.system(size: 9, weight: .bold)).kerning(1)
                .foregroundStyle(StudioTokens.dim)

            if !controller.routingReadable {
                Text("This engine build does not publish its routing graph, so nothing below is read back from the project.")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioTokens.bad)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let refusal = controller.lastRefusal {
                Text(refusal)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioTokens.bad)
                    .lineLimit(1).truncationMode(.middle)
                    .help(refusal)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.headerHeight)
    }

    // MARK: Host column — master, every bus, every track

    private var hostColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.hosts, id: \.self) { ref in
                        hostRow(ref)
                    }
                    if !controller.tracksAddressable && !controller.tracks.isEmpty {
                        Text("Tracks are not addressable on this engine, so only master and buses can carry a chain.")
                            .font(.system(size: 9))
                            .foregroundStyle(StudioTokens.warn)
                            .padding(.horizontal, 8).padding(.top, 4)
                    }
                }
                .padding(.vertical, 6)
            }
            Rectangle().fill(StudioTokens.stroke).frame(height: 1)
            HStack(spacing: 6) {
                addNodeButton(kind: .bus)
                addNodeButton(kind: .group)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: Self.hostColumnWidth)
    }

    private func hostRow(_ ref: StudioNodeRef) -> some View {
        let selected = controller.focus == ref
        let chainCount = controller.state.chain(for: ref).count
        return Button {
            controller.focus = ref
            controller.selectedFxID = controller.state.chain(for: ref).first?.id
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(hostTint(ref)).frame(width: 6, height: 6)
                Text(controller.displayName(ref))
                    .font(.system(size: 10, weight: selected ? .heavy : .semibold))
                    .foregroundStyle(selected ? StudioTokens.text : StudioTokens.dim)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // A REAL bus meter (E5 §8: `MeterBank` node slots, read off the
                // engine's meters surface each poll). Drawn only when the
                // engine reported this node id THIS poll: an id with no
                // reading draws nothing — a fabricated bar pinned at silence
                // would read as a broken mix, the defect this pane refuses.
                if let meter = controller.nodeMeters[ref] {
                    StudioNodeMeterBar(meter: meter,
                                       label: controller.displayName(ref))
                }
                if chainCount > 0 {
                    Text("\(chainCount)")
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(StudioTokens.faint)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? StudioTokens.panelHi : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .studioHelp("routing.host")
        .accessibilityLabel("\(controller.displayName(ref)) chain, \(chainCount) effects")
    }

    private func hostTint(_ ref: StudioNodeRef) -> Color {
        switch ref {
        case .master: return StudioTokens.purple
        case .bus: return StudioTokens.cyan
        case .track(let id):
            let kind = controller.tracks.first { $0.engineID == id }?.kind ?? .other
            return StudioTokens.stemColor(kind)
        }
    }

    private func addNodeButton(kind: StudioRouteNodeKind) -> some View {
        Button {
            let n = controller.state.nodes.filter { $0.kind == kind }.count + 1
            controller.addBus(kind: kind, name: "\(kind.label) \(n)")
        } label: {
            Text("+ \(kind.label.uppercased())")
                .font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 7).frame(height: 20)
                .background(StudioTokens.panelHi)
                .foregroundStyle(StudioTokens.dim)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(StudioTokens.stroke, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `kind.blurb` said the same thing, but only in one register. The
        // catalog entry teaches the WORD (bus, group) as well as the button.
        .studioHelp(kind == .bus ? "routing.addBus" : "routing.addGroup")
        .accessibilityLabel("Add \(kind.label)")
    }

    // MARK: Detail column — what this node feeds, and what is inserted on it

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            focusHeader
            Rectangle().fill(StudioTokens.strokeSoft).frame(height: 1)
            StudioFxChainStrip(controller: controller)
                .frame(height: StudioFxChainStrip.stripHeight)
            Rectangle().fill(StudioTokens.strokeSoft).frame(height: 1)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if let busID = controller.focus.busID {
                        busFaderRow(busID)
                    }
                    selectedFxEditor
                    outputsSection
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var focusHeader: some View {
        HStack(spacing: 8) {
            Text(controller.displayName(controller.focus))
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(StudioTokens.text)
            Text(controller.routingSummary(for: controller.focus))
                .font(.system(size: 9))
                .foregroundStyle(StudioTokens.dim)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            // The "NO FADER" chip that lived here is deliberately GONE:
            // `route.node.set` landed (catalog v2 #113), so the fader is a real
            // control now — drawn in `busFaderRow` below the header, where a
            // knob fits. A chip claiming "no command sets a bus's gain" would
            // be the stale badge all over again.
            if let busID = controller.focus.busID {
                Button { controller.removeBus(busID) } label: {
                    Text("REMOVE").font(.system(size: 8, weight: .heavy))
                        .padding(.horizontal, 6).frame(height: 18)
                        .foregroundStyle(StudioTokens.bad)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(StudioTokens.bad.opacity(0.5), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .studioHelp("routing.remove")
                .accessibilityLabel("Remove \(controller.displayName(controller.focus))")
            }
        }
        .padding(.horizontal, 12).frame(height: 26)
    }

    // MARK: Bus fader (route.node.set — real since catalog v2 #113)

    /// The node fader the "NO FADER" chip used to apologize for. One journaled,
    /// undoable `route.node.set` per gesture, clamped to the command's own
    /// schema range. The caption states the one precedence rule a user could
    /// trip over: a `bus.<id>.gain` automation lane, when present, wins.
    /// The knob itself, exposed so `StudioTypedControlTests` can drive the REAL
    /// bus fader's typed field rather than a rebuilt copy of it.
    func busFaderKnob(_ busID: String) -> StudioKnob {
        StudioKnob(value: controller.state.node(busID)?.gainDB ?? 0,
                   range: StudioRoutingCaps.nodeGainMinDB...StudioRoutingCaps.nodeGainMaxDB,
                   resetValue: 0, label: "FADER", unit: .decibels,
                   accent: StudioTokens.purple,
                   format: { String(format: "%+.1f dB", $0) }) { db in
            controller.setNodeGain(busID, gainDB: db)
        }
    }

    private func busFaderRow(_ busID: String) -> some View {
        let gain = controller.state.node(busID)?.gainDB ?? 0
        return HStack(alignment: .top, spacing: 10) {
            busFaderKnob(busID)
            .studioHelp("routing.busFader")
            Text("The bus fader — journaled and undoable. A gain automation lane on this bus, when one exists, takes precedence while it plays.")
                .font(.system(size: 8))
                .foregroundStyle(StudioTokens.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(controller.displayName(controller.focus)) fader, \(String(format: "%+.1f", gain)) decibels")
    }

    // MARK: Outputs (edges out of the focused node)

    @ViewBuilder
    private var outputsSection: some View {
        let edges = controller.state.outgoing(from: controller.focus)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("SENDS & OUTPUTS")
                    .font(.system(size: 8, weight: .heavy)).kerning(0.8)
                    .foregroundStyle(StudioTokens.faint)
                Spacer(minLength: 0)
                connectMenu
            }
            if edges.isEmpty {
                Text(controller.focus.isMaster
                     ? "Master is the end of the chain."
                     : "No explicit connections, so this feeds master directly at unity.")
                    .font(.system(size: 9)).foregroundStyle(StudioTokens.faint)
            } else {
                ForEach(edges) { edge in
                    StudioSendRow(controller: controller, edge: edge)
                }
            }
        }
    }

    @ViewBuilder
    private var connectMenu: some View {
        // A plain Menu, deliberately NOT inside a horizontal ScrollView.
        let candidates = controller.hosts.filter { $0 != controller.focus }
        if !controller.focus.isMaster {
            Menu {
                ForEach(candidates, id: \.self) { dest in
                    let refusal = controller.connectionRefusal(from: controller.focus, to: dest)
                    Button {
                        controller.connect(from: controller.focus, to: dest)
                    } label: {
                        Text(refusal == nil
                             ? controller.displayName(dest)
                             : "\(controller.displayName(dest)) — \(refusal!)")
                    }
                    .disabled(refusal != nil)
                }
                Divider()
                let masterRefusal = controller.connectionRefusal(from: controller.focus, to: .master)
                Button("Master") { controller.connect(from: controller.focus, to: .master) }
                    .disabled(masterRefusal != nil)
            } label: {
                Text("CONNECT TO…").font(.system(size: 8, weight: .heavy))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .studioHelp("routing.connect")
            .accessibilityLabel("Connect \(controller.displayName(controller.focus)) to")
        }
    }

    // MARK: Selected effect

    @ViewBuilder
    private var selectedFxEditor: some View {
        if let id = controller.selectedFxID,
           let fx = controller.state.fx(on: controller.focus, id: id) {
            StudioFxEditor(controller: controller, fx: fx)
        } else if controller.state.chain(for: controller.focus).isEmpty {
            // THE EFFECTS BROWSER, for an empty chain. Nine effects exist and
            // until this list sat here the only way to learn their names was
            // to open the "+ Effect" menu and read it. "What can this thing
            // do?" now has an answer on the surface the Effects button opens.
            VStack(alignment: .leading, spacing: 4) {
                Text("No effects on \(controller.displayName(controller.focus)) yet. Pick one:")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioTokens.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Text(StudioEffectsCatalog.summaryLine)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioTokens.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .studioHelp("routing.fxCatalog")
                    .accessibilityLabel("Available effects")
                    .accessibilityValue(StudioEffectsCatalog.summaryLine)
                Text("Use + Effect on the chain above to add one.")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTokens.faint)
            }
        } else {
            Text("Select an effect in the chain.")
                .font(.system(size: 9)).foregroundStyle(StudioTokens.faint)
        }
    }
}

// MARK: - Effects catalog (names only)
//
// The answer to "what effects does this app have?", as pure data. The menu
// that adds them, the empty-chain browser above, and the coach mark that
// names three of them all read from the same place — `StudioFxKind.allCases`
// — so a tenth effect cannot land with an orphan name on one surface.

enum StudioEffectsCatalog {
    /// The nine insert effects, in the same order as the + Effect menu.
    static var labels: [String] { StudioFxKind.allCases.map(\.label) }

    /// One line for the empty-chain surface and for tests that assert the
    /// nine are listed without rendering a view.
    static var summaryLine: String { labels.joined(separator: " · ") }

    /// Hard floor: the product ships nine. A shape test pins this number so a
    /// future kind that forgets to join `CaseIterable` is a red test, not a
    /// missing menu item someone notices from the couch.
    static let expectedCount = 9
}

// MARK: - The chain strip
//
// Canvas-drawn slots plus ONE gesture. No per-slot Button, and no horizontal
// ScrollView: when the chain is wider than the strip it is moved by an explicit
// `scrollX` transform driven by the arrow buttons at the ends.

struct StudioFxChainStrip: View {
    @ObservedObject var controller: StudioRoutingController

    static let stripHeight: CGFloat = 62
    @State private var layout = StudioFxChainLayout()
    @State private var viewportWidth: CGFloat = 0

    private var chain: [StudioFx] { controller.state.chain(for: controller.focus) }

    var body: some View {
        HStack(spacing: 4) {
            nudge(-1, "chevron.left")
            GeometryReader { geo in
                let l = currentLayout
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    // Fixed to the layout's own slot height so the gesture's
                    // local y matches `slotIndex(at:)`'s 0...slotHeight band. A
                    // taller container would make the top and bottom strips of
                    // the row dead to the pointer.
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, _ in draw(ctx, layout: l) }
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { g in
                                        if controller.chainDrag == nil {
                                            guard let i = l.slotIndex(at: g.startLocation),
                                                  i < chain.count else { return }
                                            controller.selectedFxID = chain[i].id
                                            controller.beginChainDrag(
                                                fxID: chain[i].id, at: g.location, layout: l)
                                        } else {
                                            controller.updateChainDrag(to: g.location, layout: l)
                                        }
                                    }
                                    .onEnded { _ in controller.endChainDrag() }
                            )
                        addMenu(layout: l)
                    }
                    .frame(height: l.slotHeight)
                    .clipped()
                    Spacer(minLength: 0)
                }
                .onAppear { viewportWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in viewportWidth = w }
            }
            nudge(1, "chevron.right")
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Effect chain on \(controller.displayName(controller.focus)), \(chain.count) effects")
    }

    private var currentLayout: StudioFxChainLayout {
        var l = layout
        l.count = chain.count
        let maxScroll = max(0, l.contentWidth - max(1, viewportWidth))
        l.scrollX = min(l.scrollX, maxScroll)
        return l
    }

    /// Explicit horizontal transform. One slot per press, clamped — the whole
    /// reason there is no ScrollView here.
    private func nudge(_ direction: CGFloat, _ glyph: String) -> some View {
        let l = currentLayout
        let maxScroll = max(0, l.contentWidth - max(1, viewportWidth))
        let enabled = direction < 0 ? l.scrollX > 0 : l.scrollX < maxScroll
        return Button {
            layout.scrollX = min(maxScroll, max(0, l.scrollX + direction * l.pitch))
        } label: {
            Image(systemName: glyph).font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? StudioTokens.dim : StudioTokens.faint.opacity(0.4))
        .disabled(!enabled)
        .studioHelp(direction < 0 ? "routing.chainScrollLeft" : "routing.chainScrollRight")
        .accessibilityLabel(direction < 0 ? "Scroll chain left" : "Scroll chain right")
    }

    /// The "+ FX" menu, positioned over the dashed trailing slot the Canvas
    /// draws. When the explicit transform has pushed that slot off the left
    /// edge it is hidden AND made non-hit-testable, or an invisible menu would
    /// sit on top of the first visible slot and swallow its clicks.
    private func addMenu(layout l: StudioFxChainLayout) -> some View {
        let r = l.addRect
        let onScreen = r.minX >= 0
        return Menu {
            ForEach(StudioFxKind.allCases, id: \.self) { kind in
                Button(kind.label) { controller.addFx(to: controller.focus, kind: kind) }
            }
        } label: {
            // "+ Effect", not "+ FX". The owner asked for "effects or plugins";
            // FX is DAW shorthand for the same thing and from a couch it reads
            // as an initialism with no expansion. Words in this strip already
            // won once (Keys, Instrument, Effects).
            Text("+ Effect")
                .font(.system(size: 9, weight: .heavy))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(StudioTokens.dim)
                .frame(width: max(r.width, 56), height: r.height)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: max(r.width, 56), height: r.height)
        .offset(x: max(0, r.minX))
        .opacity(onScreen ? 1 : 0)
        .allowsHitTesting(onScreen)
        .studioHelp("routing.fxAdd")
        .accessibilityLabel("Add an effect to \(controller.displayName(controller.focus))")
        .accessibilityHidden(!onScreen)
    }

    private func draw(_ ctx: GraphicsContext, layout l: StudioFxChainLayout) {
        let dragIndex = controller.chainDrag?.dropIndex
        for (i, fx) in chain.enumerated() {
            let r = l.rect(at: i)
            let selected = controller.selectedFxID == fx.id
            let dragging = controller.chainDrag?.fxID == fx.id
            let path = Path(roundedRect: r, cornerRadius: 6)
            ctx.fill(path, with: .color(fx.bypassed
                                        ? StudioTokens.panel
                                        : StudioTokens.panelHi))
            ctx.stroke(path, with: .color(selected ? StudioTokens.cyan : StudioTokens.stroke),
                       lineWidth: selected ? 1.5 : 1)
            if dragging {
                ctx.stroke(path, with: .color(StudioTokens.purple), lineWidth: 1.5)
            }
            // Badge + name. A bypassed slot is drawn dim AND struck through, so
            // "off" is legible without colour alone.
            let tint = fx.bypassed ? StudioTokens.faint : StudioTokens.text
            ctx.draw(Text(fx.kind.badge)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(tint),
                     at: CGPoint(x: r.midX, y: r.minY + 15))
            ctx.draw(Text(fx.id)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(StudioTokens.dim),
                     at: CGPoint(x: r.midX, y: r.minY + 30))
            if fx.bypassed {
                var line = Path()
                line.move(to: CGPoint(x: r.minX + 8, y: r.midY))
                line.addLine(to: CGPoint(x: r.maxX - 8, y: r.midY))
                ctx.stroke(line, with: .color(StudioTokens.faint), lineWidth: 1)
            }
            if fx.sidechain != nil {
                ctx.draw(Text("KEY").font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(StudioTokens.warn),
                         at: CGPoint(x: r.midX, y: r.maxY - 7))
            }
            if fx.kind.latencyFrames > 0 {
                ctx.draw(Text("\(fx.kind.latencyFrames)f").font(.system(size: 7, weight: .bold))
                            .foregroundStyle(StudioTokens.warn),
                         at: CGPoint(x: r.maxX - 12, y: r.minY + 7))
            }
        }
        // Drop marker for a live reorder.
        if let dragIndex {
            let r = l.rect(at: dragIndex)
            var marker = Path()
            marker.move(to: CGPoint(x: r.minX - l.slotSpacing / 2, y: 0))
            marker.addLine(to: CGPoint(x: r.minX - l.slotSpacing / 2, y: l.slotHeight))
            ctx.stroke(marker, with: .color(StudioTokens.purple), lineWidth: 2)
        }
        // The dashed trailing slot the "+ FX" menu sits on.
        let add = l.addRect
        ctx.stroke(Path(roundedRect: add, cornerRadius: 6),
                   with: .color(StudioTokens.stroke),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
}

// MARK: - Bus meter (real node levels, E5 §8)
//
// A compact horizontal dBFS meter for a bus/group row: RMS body + peak tick,
// on the SAME viewing scale as every other meter in the app
// (`StudioMeterScale`), so a level means one thing everywhere. The values are
// measured — `MeterBank`'s node slots, flushed once per block by the render
// walk, exposed by the host's meters read, and carried on the project
// snapshot — never derived UI-side from fader positions.

struct StudioNodeMeterBar: View {
    var meter: StudioChannelMeter
    var label: String
    var width: CGFloat = 36
    var height: CGFloat = 5

    var body: some View {
        let rmsW = CGFloat(StudioMeterScale.norm(meter.rmsDB)) * width
        let peakX = CGFloat(StudioMeterScale.norm(meter.peakDB)) * width
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(StudioTokens.bg)
            LinearGradient(
                stops: [
                    .init(color: StudioTokens.good, location: 0),
                    .init(color: StudioTokens.good, location: 0.7),
                    .init(color: StudioTokens.warn, location: 0.88),
                    .init(color: StudioTokens.bad, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                .frame(width: width)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: max(0, rmsW))
                }
            if meter.peakDB > StudioMeterScale.floorDB {
                Rectangle().fill(.white)
                    .frame(width: 1.5, height: height)
                    .offset(x: min(max(0, peakX - 0.75), width - 1.5))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .studioHelp("routing.busMeter")
        .accessibilityLabel("\(label) level")
        .accessibilityValue(meter.peakDB <= StudioMeterScale.floorDB
                            ? "silent"
                            : String(format: "peak %.0f dB", meter.peakDB))
    }
}

// MARK: - One outgoing connection

struct StudioSendRow: View {
    @ObservedObject var controller: StudioRoutingController
    let edge: StudioRouteEdge

    var body: some View {
        HStack(spacing: 8) {
            Text(controller.displayName(edge.to))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StudioTokens.text)
                .frame(width: 92, alignment: .leading).lineLimit(1)

            levelKnob.studioHelp("routing.sendLevel")

            tapToggle
            Spacer(minLength: 0)

            Button { controller.disconnect(edge.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(StudioTokens.dim)
            .studioHelp("routing.disconnect")
            .accessibilityLabel("Disconnect from \(controller.displayName(edge.to))")
        }
        .padding(.vertical, 2)
    }

    /// The connection's level knob.
    ///
    /// `.decibels` also knows how to read "-inf" back, which matters here more
    /// than anywhere: a send at zero is the one value this control PRINTS as a
    /// word, and a field that refused to accept the word it prints is a field
    /// you cannot retype. Exposed so a test can drive the real one.
    var levelKnob: StudioKnob {
        StudioKnob(value: StudioSendTaper.levelToDB(edge.level),
                   range: StudioSendTaper.minDB...StudioSendTaper.maxDB,
                   resetValue: 0, label: "LEVEL", unit: .decibels,
                   accent: StudioTokens.cyan,
                   format: { $0 <= StudioSendTaper.minDB ? "-inf" : String(format: "%.1f dB", $0) }) { db in
            controller.setEdgeLevel(edge.id, level: StudioSendTaper.dbToLevel(db))
        }
    }

    /// One button, two states — one `route.edge.set`, one undo step.
    private var tapToggle: some View {
        Button {
            controller.setEdgeTap(edge.id, tap: edge.tap == .post ? .pre : .post)
        } label: {
            Text(edge.tap.label)
                .font(.system(size: 8, weight: .heavy))
                .frame(width: 38, height: 18)
                .background(edge.tap == .pre ? StudioTokens.warn.opacity(0.2) : StudioTokens.panelHi)
                .foregroundStyle(edge.tap == .pre ? StudioTokens.warn : StudioTokens.dim)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(edge.tap == .pre ? StudioTokens.warn.opacity(0.6) : StudioTokens.stroke,
                            lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Dynamic rather than a plain catalog id, because there are two facts
        // here and a newcomer needs both: what the control MEANS, and which way
        // it is currently set. The pre-tap's EQ-free behaviour is a deliberate
        // divergence from what other DAWs mean by "pre-fader", so it is stated
        // in the tooltip rather than buried.
        .studioHelp(
            terse: StudioHelpCatalog.entry("routing.tap")?.terse ?? "Tap point",
            teaching: (StudioHelpCatalog.entry("routing.tap")?.teaching ?? "")
                + "\n\nRight now: " + edge.tap.note)
        .accessibilityLabel("Tap point")
        .accessibilityValue(edge.tap.label)
        .accessibilityHint(edge.tap.note)
    }
}

// MARK: - The selected effect's controls

struct StudioFxEditor: View {
    @ObservedObject var controller: StudioRoutingController
    let fx: StudioFx

    private let columns = [GridItem(.adaptive(minimum: 58, maximum: 78), spacing: 4)]

    /// This kind's ONE automation statement, or nil when there is nothing to
    /// say (every key automates and behaves unsurprisingly — silence, not a
    /// reassurance banner). Exposed as a property, not inlined in `body`, so
    /// `testTheFxEditorShowsItsNoteExactlyWhereOneExists` can hold the view
    /// to it: hiding the footnote while refusals exist is a red test, not a
    /// quiet regression.
    var automationFootnote: String? {
        StudioRoutingCapability.fxAutomationNote(for: fx.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(fx.kind.label.uppercased())
                    .font(.system(size: 9, weight: .heavy)).kerning(0.8)
                    .foregroundStyle(StudioTokens.faint)
                bypassButton
                if fx.kind.acceptsSidechain { sidechainMenu }
                Spacer(minLength: 0)
                Button { controller.removeFx(from: controller.focus, id: fx.id) } label: {
                    Text("DELETE").font(.system(size: 8, weight: .heavy))
                        .padding(.horizontal, 6).frame(height: 18)
                        .foregroundStyle(StudioTokens.bad)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(StudioTokens.bad.opacity(0.5), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .studioHelp("routing.fxDelete")
                .accessibilityLabel("Delete \(fx.kind.label)")
            }

            if fx.kind.latencyFrames > 0 {
                Text("Adds \(fx.kind.latencyFrames) frames of latency (about \(String(format: "%.1f", Double(fx.kind.latencyFrames) / 48.0)) ms). Parallel paths are delay-compensated by the engine.")
                    .font(.system(size: 9)).foregroundStyle(StudioTokens.warn)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(fx.editableParams) { spec in
                    paramControl(spec)
                }
            }

            // The kind's one automation statement, exactly where a user would
            // look for "automate this knob". Per KIND now, from the same table
            // the drift pin holds against the engine's FxParamRate spec: the
            // blanket "not renderable" line this replaced had become an
            // over-warning the moment FxNode::set_frame_param landed. Kinds
            // with nothing to warn about render nothing here.
            if let note = automationFootnote {
                Text(note)
                    .font(.system(size: 8))
                    .foregroundStyle(StudioTokens.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(note)
                    .accessibilityLabel("Automation on \(fx.kind.label) parameters")
                    .accessibilityHint(note)
            }
        }
    }

    /// Bypass has its own control and its own code path. It is never rendered
    /// among the parameters, because it is not one.
    private var bypassButton: some View {
        Button {
            controller.setFxBypass(on: controller.focus, id: fx.id, bypassed: !fx.bypassed)
        } label: {
            Text(fx.bypassed ? "BYPASSED" : "ACTIVE")
                .font(.system(size: 8, weight: .heavy))
                .padding(.horizontal, 7).frame(height: 18)
                .background(fx.bypassed ? StudioTokens.panelHi : StudioTokens.good.opacity(0.18))
                .foregroundStyle(fx.bypassed ? StudioTokens.faint : StudioTokens.good)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(fx.bypassed ? StudioTokens.stroke : StudioTokens.good.opacity(0.5), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .studioHelp(fx.bypassed ? "routing.fxBypass.bypassed" : "routing.fxBypass.active")
        .accessibilityLabel("Bypass \(fx.kind.label)")
        .accessibilityValue(fx.bypassed ? "bypassed" : "active")
    }

    private var sidechainMenu: some View {
        Menu {
            Button("Internal (its own input)") {
                controller.clearSidechain(on: controller.focus, id: fx.id)
            }
            Divider()
            ForEach(controller.hosts, id: \.self) { source in
                let refusal = controller.sidechainRefusal(source: source, host: controller.focus)
                Button {
                    controller.setSidechain(on: controller.focus, id: fx.id, source: source)
                } label: {
                    Text(refusal == nil
                         ? controller.displayName(source)
                         : "\(controller.displayName(source)) — \(refusal!)")
                }
                .disabled(refusal != nil)
            }
        } label: {
            Text(fx.sidechain.map { "KEY: \(controller.displayName($0))" } ?? "KEY: INTERNAL")
                .font(.system(size: 8, weight: .heavy))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .studioHelp("routing.sidechain")
        .accessibilityLabel("Sidechain key source")
    }

    /// ONE parameter's knob — the control that reaches all 38 `FX_PARAM_KEYS`.
    ///
    /// `spec.paramUnit` is derived from the same `unit` string the engine's DSP
    /// tables are transcribed into, so every one of those keys gets typing and
    /// a sensible arrow step from ONE mapping — and a parameter added to those
    /// tables tomorrow gets both without anyone editing this file.
    ///
    /// Exposed so `StudioTypedControlTests` can walk EVERY kind and every key
    /// and drive the real knob's typed field into the real command bus. A test
    /// that rebuilt the knob would have proven the parser and nothing about
    /// whether this editor holds one.
    func paramKnob(_ spec: StudioFxParamSpec) -> StudioKnob {
        StudioKnob(value: fx.value(for: spec.key),
                   range: spec.minValue...spec.maxValue,
                   resetValue: spec.defaultValue,
                   label: spec.label,
                   unit: spec.paramUnit,
                   accent: fx.isSet(spec.key) ? StudioTokens.cyan : StudioTokens.faderCap,
                   format: spec.format) { v in
            controller.setFxParam(on: controller.focus, id: fx.id, key: spec.key, value: v)
        }
    }

    @ViewBuilder
    private func paramControl(_ spec: StudioFxParamSpec) -> some View {
        let value = fx.value(for: spec.key)
        VStack(spacing: 2) {
            if spec.isSwitch {
                Button {
                    controller.setFxParam(on: controller.focus, id: fx.id,
                                          key: spec.key, value: value >= 0.5 ? 0 : 1)
                } label: {
                    VStack(spacing: 2) {
                        Text(spec.format(value)).font(.system(size: 9, weight: .heavy))
                            .frame(width: 46, height: 22)
                            .background(StudioTokens.panelHi)
                            .foregroundStyle(StudioTokens.text)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(StudioTokens.stroke, lineWidth: 1))
                        Text(spec.label).font(.system(size: 7, weight: .bold))
                            .foregroundStyle(StudioTokens.faint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .studioHelp(StudioHelpCatalog.fxParamHelpID(spec.key))
                .accessibilityLabel(spec.label)
                .accessibilityValue(spec.format(value))
            } else {
                // Keyed on the engine's own wire key, so THRESH means the same
                // thing on the compressor and the gate without two strings.
                paramKnob(spec).studioHelp(StudioHelpCatalog.fxParamHelpID(spec.key))
            }
            // Only offered where there is something to clear. Clearing makes the
            // key ABSENT again (the DSP default), which is a different fact from
            // writing the default value into the project.
            if fx.isSet(spec.key) {
                Button {
                    controller.clearFxParam(on: controller.focus, id: fx.id, key: spec.key)
                } label: {
                    Text("clear").font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(StudioTokens.faint)
                        .frame(height: 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .studioHelp("routing.fxParamClear")
                .accessibilityLabel("Clear \(spec.label), returning it to the default")
            } else {
                Color.clear.frame(height: 10)
            }
        }
    }
}
