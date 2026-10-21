import SwiftUI
import AppKit

// MARK: - Piano roll
//
// ═══ HIT-TESTING: WHY THERE IS NO SCROLLVIEW IN THIS FILE ═══
//
// A horizontal `ScrollView` breaks Button hit-testing on macOS: clicks on child
// buttons silently no-op. It has bitten this app three times — the Settings tabs
// read as dead (fixed in d6b528a) and every mixer strip's Mute/Solo was
// unclickable. So this surface has NO ScrollView at any level, and no `Button`
// inside the scrolling region at all.
//
// Instead the whole 2-D surface — keyboard gutter, ruler, grid, notes, velocity
// lane, play head — is ONE `Canvas`, and scroll/zoom are explicit transforms
// (`scrollTicks`, `scrollY`, `pxPerTick`, `rowHeight`) that the controller owns.
// Consequences, all deliberate:
//
//   * Nothing is a child view, so nothing can have its clicks eaten by a
//     scroll container, collapsed to a glyph outline by a missing
//     `.contentShape`, or swallowed by a decorative overlay. There is exactly
//     one gesture target: the canvas.
//   * Every "click on a thing" is answered by `StudioPianoRollGeometry` from the
//     SAME `StudioPianoRollLayout` the drawing used, so what you see is what you
//     grab, by construction rather than by discipline.
//   * The keyboard gutter's keys are DRAWN, not Buttons. A column of 128 buttons
//     is precisely the shape that broke before.
//   * Small notes get an outward grab margin and a minimum-width resize edge
//     (`StudioPianoRollGeometry.minEdgeGrabPx`), because a 2-3 pt edge is a
//     resize handle you cannot hit.
//
// The only Buttons live in the toolbar strip ABOVE the canvas, in a plain
// HStack that never scrolls.
//
// Gesture composition follows StudioTimelineCanvas, which already solves this
// correctly and holds its 60 fps gate: one `DragGesture(minimumDistance: 0)`,
// pinch and double-click added with `.simultaneousGesture`, and wheel events
// picked up by the `StudioScrollCatcher` NSEvent monitor (SwiftUI exposes no
// scroll-wheel events).

struct StudioPianoRollView: View {
    @ObservedObject var controller: StudioPianoRollController
    /// Frame-time evidence, shared with the arrangement's HUD.
    @ObservedObject var frameStats: StudioFrameStats
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private var wantsFullRate: Bool {
        (controller.session?.transport.isPlaying ?? false) || controller.drag.kind != .none
    }

    var body: some View {
        GeometryReader { geo in
            let layout = controller.layout(for: geo.size)
            TimelineView(.animation(
                minimumInterval: wantsFullRate ? nil : 1.0 / 12.0,
                paused: reduceMotion && !wantsFullRate
            )) { _ in
                Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                    draw(context: context, layout: controller.layout(for: size))
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in handleKey(press) }
            .gesture(dragGesture(layout: layout))
            .simultaneousGesture(doubleClickGesture(layout: layout))
            .simultaneousGesture(magnifyGesture(layout: layout))
            .background(StudioScrollCatcher { event in handleScroll(event, layout: layout) })
            .onAppear {
                focused = true
                controller.autoFitIfNeeded(layout: layout)
            }
            .onChange(of: geo.size) { _, size in
                controller.autoFitIfNeeded(layout: controller.layout(for: size))
            }
            .accessibilityLabel("Piano roll")
            .accessibilityHint(
                "Note editor. Draw, move and resize notes. \(controller.selection.count) selected.")
        }
        .clipped()
    }

    // MARK: - Drawing
    //
    // Everything batches into a handful of `Path`s. Hundreds of `View`s (or
    // hundreds of `context.fill` calls) is what turns a piano roll into a
    // slideshow; notes are bucketed by velocity so the note layer costs a fixed
    // number of fills no matter how many notes are on screen.

    private func draw(context: GraphicsContext, layout: StudioPianoRollLayout) {
        let drawStart = CACurrentMediaTime()
        defer { frameStats.recordDraw(startedAt: drawStart, fullRate: wantsFullRate) }

        context.fill(Path(CGRect(origin: .zero, size: layout.size)), with: .color(StudioTokens.bg))
        guard let clip = controller.clip else {
            context.draw(
                Text("No note clip open")
                    .font(.system(size: 12)).foregroundStyle(StudioTokens.dim),
                at: CGPoint(x: layout.size.width / 2, y: layout.size.height / 2))
            return
        }

        let notes = controller.displayNotes()
        let visible = layout.culled(notes, clipOriginTicks: clip.startTicks)

        var grid = context
        grid.clip(to: Path(layout.noteRect))
        drawPitchRows(&grid, layout: layout)
        drawClipBounds(&grid, layout: layout, clip: clip)
        drawGridLines(&grid, layout: layout)
        drawNotes(&grid, layout: layout, clip: clip, notes: visible)
        drawMarquee(&grid)

        drawGutter(context, layout: layout, notes: visible)
        drawRuler(context, layout: layout)
        if layout.velocityLaneHeight > 0 {
            drawVelocityLane(context, layout: layout, clip: clip, notes: visible)
        }
        drawPlayhead(context, layout: layout)
    }

    /// Black-key rows get a darker stripe so the keyboard reads across the grid.
    private func drawPitchRows(_ context: inout GraphicsContext, layout: StudioPianoRollLayout) {
        guard layout.rowHeight > 0 else { return }
        let pitches = layout.visiblePitchRange
        var accidentals = Path()
        var octaveLines = Path()
        for raw in Int(pitches.lowerBound)...Int(pitches.upperBound) {
            let pitch = UInt8(raw)
            let y = layout.y(forPitch: pitch)
            if StudioPitchName.isAccidental(pitch) {
                accidentals.addRect(CGRect(
                    x: layout.noteRect.minX, y: y,
                    width: layout.noteRect.width, height: layout.rowHeight))
            }
            if StudioPitchName.isOctaveRoot(pitch) {
                octaveLines.move(to: CGPoint(x: layout.noteRect.minX, y: y + layout.rowHeight))
                octaveLines.addLine(to: CGPoint(x: layout.noteRect.maxX, y: y + layout.rowHeight))
            }
        }
        context.fill(accidentals, with: .color(.black.opacity(0.22)))
        context.stroke(octaveLines, with: .color(.white.opacity(0.10)), lineWidth: 1)
    }

    /// Everything outside the clip's own span is dimmed — you can see it, you
    /// just cannot put a note there.
    private func drawClipBounds(
        _ context: inout GraphicsContext,
        layout: StudioPianoRollLayout,
        clip: StudioMidiClipSnapshot
    ) {
        let start = layout.x(forTicks: clip.startTicks)
        let end = layout.x(forTicks: clip.endTicks)
        var outside = Path()
        if start > layout.noteRect.minX {
            outside.addRect(CGRect(
                x: layout.noteRect.minX, y: layout.noteRect.minY,
                width: start - layout.noteRect.minX, height: layout.noteRect.height))
        }
        if end < layout.noteRect.maxX {
            outside.addRect(CGRect(
                x: end, y: layout.noteRect.minY,
                width: layout.noteRect.maxX - end, height: layout.noteRect.height))
        }
        context.fill(outside, with: .color(StudioTokens.bg.opacity(0.55)))
    }

    /// Bar / beat / division lines, all phase-aligned to the project's
    /// beat-tracked bar grid (see StudioBarGrid).
    private func drawGridLines(_ context: inout GraphicsContext, layout: StudioPianoRollLayout) {
        let barGrid = controller.barGrid
        let range = layout.visibleTickRange
        guard layout.pxPerTick > 0 else { return }

        var divisionPath = Path()
        let division = controller.grid == .off ? .sixteenth : controller.grid
        if let step = division.ticks(barGrid.timeSignature),
           CGFloat(step) * layout.pxPerTick >= 5 {
            for tick in barGrid.gridLines(in: range, division: division) {
                let x = layout.x(forTicks: tick)
                divisionPath.move(to: CGPoint(x: x, y: layout.noteRect.minY))
                divisionPath.addLine(to: CGPoint(x: x, y: layout.noteRect.maxY))
            }
        }
        context.stroke(divisionPath, with: .color(.white.opacity(0.05)), lineWidth: 1)

        var beatPath = Path()
        if CGFloat(barGrid.ticksPerBeat) * layout.pxPerTick >= 8 {
            for tick in barGrid.gridLines(in: range, division: .quarter) {
                let x = layout.x(forTicks: tick)
                beatPath.move(to: CGPoint(x: x, y: layout.noteRect.minY))
                beatPath.addLine(to: CGPoint(x: x, y: layout.noteRect.maxY))
            }
        }
        context.stroke(beatPath, with: .color(.white.opacity(0.09)), lineWidth: 1)

        var barPath = Path()
        for tick in barGrid.barLines(in: range) {
            let x = layout.x(forTicks: tick)
            barPath.move(to: CGPoint(x: x, y: layout.noteRect.minY))
            barPath.addLine(to: CGPoint(x: x, y: layout.noteRect.maxY))
        }
        context.stroke(barPath, with: .color(.white.opacity(0.20)), lineWidth: 1)
    }

    /// Velocity buckets, so the note layer is a fixed handful of fills whatever
    /// the note count. Six buckets is enough to read dynamics at a glance and
    /// cheap enough to stay flat under a few thousand notes.
    private static let velocityBuckets = 6

    private func drawNotes(
        _ context: inout GraphicsContext,
        layout: StudioPianoRollLayout,
        clip: StudioMidiClipSnapshot,
        notes: [StudioNote]
    ) {
        guard !notes.isEmpty else { return }
        let stem = StudioTokens.stemColor(clip.kind)
        let radius = min(3.0, layout.rowHeight / 3)

        var buckets = [Path](repeating: Path(), count: Self.velocityBuckets)
        var selectedPath = Path()
        var outlinePath = Path()
        var edgePath = Path()
        var labelled: [(StudioNote, CGRect)] = []

        for note in notes {
            let rect = layout.rect(for: note, clipOriginTicks: clip.startTicks)
                .insetBy(dx: 0, dy: min(1, layout.rowHeight * 0.08))
            let shape = Path(roundedRect: rect, cornerRadius: radius)
            if controller.selection.contains(note.id) {
                selectedPath.addPath(shape)
                // Resize affordance on selected notes wide enough to show it.
                if rect.width >= StudioPianoRollGeometry.twoEdgeMinWidth {
                    let grab = StudioPianoRollGeometry.edgeGrabWidth(noteWidthPx: rect.width)
                    edgePath.addRect(CGRect(
                        x: rect.minX, y: rect.minY, width: min(2, grab), height: rect.height))
                    edgePath.addRect(CGRect(
                        x: rect.maxX - min(2, grab), y: rect.minY,
                        width: min(2, grab), height: rect.height))
                }
            } else {
                let bucket = min(
                    Self.velocityBuckets - 1,
                    note.velocity * Self.velocityBuckets / 128)
                buckets[bucket].addPath(shape)
            }
            outlinePath.addPath(shape)
            if layout.rowHeight >= 11, rect.width >= 30, labelled.count < 96 {
                labelled.append((note, rect))
            }
        }

        for (index, path) in buckets.enumerated() where !path.isEmpty {
            // 0.34 -> 1.0 across the buckets: quiet notes recede, loud ones sing.
            let alpha = 0.34 + 0.66 * Double(index) / Double(Self.velocityBuckets - 1)
            context.fill(path, with: .color(stem.opacity(alpha)))
        }
        if !selectedPath.isEmpty {
            context.fill(selectedPath, with: .color(.white.opacity(0.92)))
        }
        context.stroke(outlinePath, with: .color(StudioTokens.bg.opacity(0.85)), lineWidth: 1)
        if !edgePath.isEmpty {
            context.fill(edgePath, with: .color(StudioTokens.cyan.opacity(0.9)))
        }

        for (note, rect) in labelled {
            let selected = controller.selection.contains(note.id)
            context.draw(
                Text(StudioPitchName.label(note.pitch))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(selected ? StudioTokens.bg : StudioTokens.text.opacity(0.85)),
                at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
        }
    }

    private func drawMarquee(_ context: inout GraphicsContext) {
        guard controller.drag.kind == .marquee, controller.drag.didMove else { return }
        let rect = StudioPianoRollGeometry.marqueeRect(
            from: controller.drag.startPoint, to: controller.drag.currentPoint)
        context.fill(Path(rect), with: .color(.white.opacity(0.06)))
        context.stroke(Path(rect), with: .color(.white.opacity(0.30)), lineWidth: 1)
    }

    /// The keyboard gutter. Drawn, never buttons.
    private func drawGutter(
        _ context: GraphicsContext,
        layout: StudioPianoRollLayout,
        notes: [StudioNote]
    ) {
        var gutter = context
        gutter.clip(to: Path(layout.gutterRect))
        gutter.fill(Path(layout.gutterRect), with: .color(StudioTokens.panel))

        guard layout.rowHeight > 0 else { return }
        let pitches = layout.visiblePitchRange
        let sounding = Set(notes.filter { controller.selection.contains($0.id) }.map(\.pitch))

        var whites = Path()
        var blacks = Path()
        var lit = Path()
        var separators = Path()
        for raw in Int(pitches.lowerBound)...Int(pitches.upperBound) {
            let pitch = UInt8(raw)
            let y = layout.y(forPitch: pitch)
            let rect = CGRect(x: 0, y: y, width: layout.gutterWidth, height: layout.rowHeight)
            if sounding.contains(pitch) {
                lit.addRect(rect)
            } else if StudioPitchName.isAccidental(pitch) {
                blacks.addRect(CGRect(
                    x: 0, y: rect.minY, width: layout.gutterWidth * 0.62, height: rect.height))
            } else {
                whites.addRect(rect)
            }
            if StudioPitchName.isOctaveRoot(pitch) {
                separators.move(to: CGPoint(x: 0, y: rect.maxY))
                separators.addLine(to: CGPoint(x: layout.gutterWidth, y: rect.maxY))
            }
        }
        gutter.fill(whites, with: .color(StudioTokens.faderCap.opacity(0.82)))
        gutter.fill(blacks, with: .color(.black.opacity(0.88)))
        gutter.fill(lit, with: .color(StudioTokens.cyan.opacity(0.85)))
        gutter.stroke(separators, with: .color(.black.opacity(0.5)), lineWidth: 1)

        // Octave labels only — 128 labels would be noise and 128 text resolves.
        if layout.rowHeight >= 8 {
            for raw in Int(pitches.lowerBound)...Int(pitches.upperBound) {
                let pitch = UInt8(raw)
                guard StudioPitchName.isOctaveRoot(pitch) else { continue }
                gutter.draw(
                    Text(StudioPitchName.label(pitch))
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(StudioTokens.bg),
                    at: CGPoint(
                        x: layout.gutterWidth - 5,
                        y: layout.y(forPitch: pitch) + layout.rowHeight / 2),
                    anchor: .trailing)
            }
        }
        var edge = Path()
        edge.move(to: CGPoint(x: layout.gutterWidth - 0.5, y: layout.rulerHeight))
        edge.addLine(to: CGPoint(x: layout.gutterWidth - 0.5, y: layout.size.height))
        context.stroke(edge, with: .color(StudioTokens.stroke), lineWidth: 1)
    }

    private func drawRuler(_ context: GraphicsContext, layout: StudioPianoRollLayout) {
        var ruler = context
        ruler.clip(to: Path(CGRect(x: 0, y: 0, width: layout.size.width, height: layout.rulerHeight)))
        ruler.fill(
            Path(CGRect(x: 0, y: 0, width: layout.size.width, height: layout.rulerHeight)),
            with: .color(StudioTokens.panel))

        let barGrid = controller.barGrid
        let lines = barGrid.barLines(in: layout.visibleTickRange)
        let pxPerBar = CGFloat(barGrid.ticksPerBar) * layout.pxPerTick
        let stride = max(1, StudioTimelineMath.barLabelStride(pxPerBar: pxPerBar))
        var ticks = Path()
        for tick in lines {
            let bar = barGrid.barNumber(at: tick)
            guard bar % stride == 0 || stride == 1 else { continue }
            let x = layout.x(forTicks: tick)
            ticks.move(to: CGPoint(x: x, y: 0))
            ticks.addLine(to: CGPoint(x: x, y: layout.rulerHeight))
            ruler.draw(
                Text("\(bar)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(StudioTokens.faint),
                at: CGPoint(x: x + 4, y: layout.rulerHeight / 2), anchor: .leading)
        }
        ruler.stroke(ticks, with: .color(.white.opacity(0.14)), lineWidth: 1)

        var bottom = Path()
        bottom.move(to: CGPoint(x: 0, y: layout.rulerHeight - 0.5))
        bottom.addLine(to: CGPoint(x: layout.size.width, y: layout.rulerHeight - 0.5))
        context.stroke(bottom, with: .color(StudioTokens.strokeSoft), lineWidth: 1)
    }

    private func drawVelocityLane(
        _ context: GraphicsContext,
        layout: StudioPianoRollLayout,
        clip: StudioMidiClipSnapshot,
        notes: [StudioNote]
    ) {
        var lane = context
        lane.clip(to: Path(layout.velocityRect))
        lane.fill(Path(layout.velocityRect), with: .color(StudioTokens.panel.opacity(0.9)))

        var top = Path()
        top.move(to: CGPoint(x: layout.velocityRect.minX, y: layout.velocityRect.minY + 0.5))
        top.addLine(to: CGPoint(x: layout.velocityRect.maxX, y: layout.velocityRect.minY + 0.5))
        lane.stroke(top, with: .color(StudioTokens.stroke), lineWidth: 1)

        let stem = StudioTokens.stemColor(clip.kind)
        var stems = Path()
        var selectedStems = Path()
        var heads = Path()
        var selectedHeads = Path()
        for note in notes {
            let x = layout.x(forTicks: clip.startTicks + note.startTicks).rounded() + 0.5
            let y = layout.velocityY(note.velocity)
            let selected = controller.selection.contains(note.id)
            if selected {
                selectedStems.move(to: CGPoint(x: x, y: layout.velocityRect.maxY - 2))
                selectedStems.addLine(to: CGPoint(x: x, y: y))
                selectedHeads.addEllipse(in: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
            } else {
                stems.move(to: CGPoint(x: x, y: layout.velocityRect.maxY - 2))
                stems.addLine(to: CGPoint(x: x, y: y))
                heads.addEllipse(in: CGRect(x: x - 2, y: y - 2, width: 4, height: 4))
            }
        }
        lane.stroke(stems, with: .color(stem.opacity(0.6)), lineWidth: 1.5)
        lane.fill(heads, with: .color(stem))
        lane.stroke(selectedStems, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
        lane.fill(selectedHeads, with: .color(.white))

        lane.draw(
            Text("VEL").font(.system(size: 8, weight: .heavy)).kerning(1)
                .foregroundStyle(StudioTokens.faint),
            at: CGPoint(x: layout.velocityRect.minX + 6, y: layout.velocityRect.minY + 9),
            anchor: .leading)
    }

    private func drawPlayhead(_ context: GraphicsContext, layout: StudioPianoRollLayout) {
        let ticks = controller.playheadTicks(now: ProcessInfo.processInfo.systemUptime)
        let x = layout.x(forTicks: ticks)
        guard x >= layout.noteRect.minX - 8, x <= layout.noteRect.maxX + 8 else { return }
        var head = context
        head.clip(to: Path(CGRect(
            x: layout.gutterWidth, y: 0,
            width: layout.size.width - layout.gutterWidth, height: layout.size.height)))
        var glow = Path()
        glow.move(to: CGPoint(x: x, y: 0))
        glow.addLine(to: CGPoint(x: x, y: layout.size.height))
        head.stroke(glow, with: .color(.white.opacity(0.22)), lineWidth: 3)
        head.stroke(glow, with: .color(.white), lineWidth: 1)
        var cap = Path()
        cap.move(to: CGPoint(x: x - 5, y: 0))
        cap.addLine(to: CGPoint(x: x + 5, y: 0))
        cap.addLine(to: CGPoint(x: x, y: 7))
        cap.closeSubpath()
        head.fill(cap, with: .color(.white))
    }

    // MARK: - Gestures

    private func modifiers() -> StudioNoteModifiers {
        let flags = NSEvent.modifierFlags
        return StudioNoteModifiers(
            shift: flags.contains(.shift),
            command: flags.contains(.command),
            option: flags.contains(.option))
    }

    private func dragGesture(layout: StudioPianoRollLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                focused = true
                let mods = modifiers()
                if controller.drag.kind == .none {
                    controller.press(at: value.startLocation, modifiers: mods, layout: layout)
                }
                controller.dragged(to: value.location, modifiers: mods, layout: layout)
            }
            .onEnded { value in
                controller.released(at: value.location, modifiers: modifiers(), layout: layout)
            }
    }

    /// Double-click: on empty grid it writes a note of the current grid length;
    /// on a note it deletes it. The pair a musician reaches for without being
    /// told, in both tools.
    private func doubleClickGesture(layout: StudioPianoRollLayout) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard let clip = controller.clip,
                      layout.noteRect.contains(value.location) else { return }
                if let hit = StudioPianoRollGeometry.hitTest(
                    clip.notes, selected: controller.selection, layout: layout,
                    clipOriginTicks: clip.startTicks, at: value.location) {
                    controller.selection = [hit.noteID]
                    controller.deleteSelection()
                } else {
                    controller.drawNote(at: value.location, layout: layout, modifiers: modifiers())
                }
            }
    }

    @State private var magnifyBaseline: CGFloat?

    private func magnifyGesture(layout: StudioPianoRollLayout) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = magnifyBaseline ?? controller.pxPerTick
                magnifyBaseline = base
                guard controller.pxPerTick > 0 else { return }
                let target = StudioPianoRollLayout.clampPxPerTick(base * value.magnification)
                controller.zoomHorizontal(
                    by: target / controller.pxPerTick,
                    anchorPx: value.startLocation.x, layout: layout)
            }
            .onEnded { _ in magnifyBaseline = nil }
    }

    private func handleScroll(_ event: StudioScrollEvent, layout: StudioPianoRollLayout) {
        switch event {
        case .pan(let dx, let dy):
            controller.pan(dxPx: -dx, dyPx: -dy, layout: layout)
        case .zoom(let factor, let atX):
            controller.zoomHorizontal(by: factor, anchorPx: atX, layout: layout)
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            if controller.drag.kind != .none { controller.cancelDrag() } else { controller.selection.removeAll() }
            return .handled
        case .delete, .deleteForward:
            guard !controller.selection.isEmpty else { return .ignored }
            controller.deleteSelection()
            return .handled
        case .leftArrow:
            controller.handleKey("", arrow: .left, shift: press.modifiers.contains(.shift), command: false)
            return .handled
        case .rightArrow:
            controller.handleKey("", arrow: .right, shift: press.modifiers.contains(.shift), command: false)
            return .handled
        case .upArrow:
            controller.handleKey("", arrow: .up, shift: press.modifiers.contains(.shift), command: false)
            return .handled
        case .downArrow:
            controller.handleKey("", arrow: .down, shift: press.modifiers.contains(.shift), command: false)
            return .handled
        default:
            break
        }
        return controller.handleKey(
            press.characters, arrow: nil,
            shift: press.modifiers.contains(.shift),
            command: press.modifiers.contains(.command)) ? .handled : .ignored
    }
}

// MARK: - Pane (toolbar + canvas)
//
// The toolbar is a plain HStack of real Buttons. It is deliberately NOT inside
// any scrolling container: that is the exact arrangement that made the Settings
// tabs and the mixer strips read as dead.

struct StudioPianoRollPane: View {
    @ObservedObject var controller: StudioPianoRollController
    @ObservedObject var frameStats: StudioFrameStats

    /// The pane's default height, named so `StudioPaneSizing.pianoRoll` and the
    /// view cannot drift apart.
    nonisolated static let defaultHeight: CGFloat = 300

    /// The live height. The shell drags it; every other call site gets the
    /// default it always had.
    var height: CGFloat = StudioPianoRollPane.defaultHeight

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(StudioTokens.stroke)
            StudioPianoRollView(controller: controller, frameStats: frameStats)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(StudioTokens.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(StudioTokens.stroke).frame(height: 1)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            // `lineLimit(1)` + `fixedSize()` on every Text in this row: an
            // unconstrained Text in a tight HStack wraps to one character per
            // line, which is what blew the mixer toolbar to 475 pt in 3.4.8.
            // The row got tighter when quantize joined it, so both Texts are
            // pinned rather than left to luck.
            Text(controller.clip?.name.uppercased() ?? "PIANO ROLL")
                .font(.system(size: 9, weight: .heavy)).kerning(1)
                .foregroundStyle(StudioTokens.dim)
                .lineLimit(1)
                .fixedSize()

            Picker("", selection: $controller.tool) {
                ForEach(StudioPianoRollTool.allCases, id: \.self) { tool in
                    Image(systemName: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 74)
            .studioHelp("pianoRoll.tool")

            Picker("Grid", selection: $controller.grid) {
                ForEach(StudioNoteGrid.allCases, id: \.self) { g in
                    Text(g.label).tag(g)
                }
            }
            .frame(width: 116)
            .studioHelp("pianoRoll.grid")

            Divider().frame(height: 16)

            toolButton("minus.magnifyingglass", "Zoom out", "pianoRoll.zoomOut") {
                controller.pxPerTick = StudioPianoRollLayout.clampPxPerTick(controller.pxPerTick / 1.4)
            }
            toolButton("plus.magnifyingglass", "Zoom in", "pianoRoll.zoomIn") {
                controller.pxPerTick = StudioPianoRollLayout.clampPxPerTick(controller.pxPerTick * 1.4)
            }
            toolButton("arrow.down.and.line.horizontal.and.arrow.up", "Shorter rows", "pianoRoll.shorterRows") {
                controller.rowHeight = StudioPianoRollLayout.clampRowHeight(controller.rowHeight / 1.3)
            }
            toolButton("arrow.up.and.line.horizontal.and.arrow.down", "Taller rows", "pianoRoll.tallerRows") {
                controller.rowHeight = StudioPianoRollLayout.clampRowHeight(controller.rowHeight * 1.3)
            }

            Divider().frame(height: 16)

            toolButton("arrow.uturn.backward", "Undo note edit", "pianoRoll.undo") { controller.undo() }
                .disabled(!controller.canUndo)
            toolButton("arrow.uturn.forward", "Redo note edit", "pianoRoll.redo") { controller.redo() }
                .disabled(!controller.canRedo)
            toolButton("square.on.square", "Duplicate selection", "pianoRoll.duplicate") { controller.duplicateSelection() }
                .disabled(controller.selection.isEmpty)
            toolButton("trash", "Delete selection", "pianoRoll.delete") { controller.deleteSelection() }
                .disabled(controller.selection.isEmpty)

            quantizeMenu

            Spacer()

            Toggle("Velocity", isOn: $controller.velocityLaneShown)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
                .foregroundStyle(StudioTokens.dim)
                .studioHelp("pianoRoll.velocityLane")

            Text(selectionSummary)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(StudioTokens.faint)
                .lineLimit(1)
                .fixedSize()
                .studioHelp("pianoRoll.selectionCount")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(StudioTokens.panel)
    }

    /// Quantize.
    ///
    /// A MENU rather than a bare button, for one reason: quantize is the only
    /// edit in this toolbar that can rewrite the timing of a whole performance,
    /// and the owner's own take is deliberately off the grid — the tempo map
    /// was fitted to his playing rather than the reverse. So the amount and the
    /// ends toggle are visible at the moment of the decision instead of hidden
    /// in a preference, and "the selection" and "everything" are two separate,
    /// separately worded commands rather than one button whose meaning depends
    /// on what happens to be selected.
    ///
    /// Nothing in here fires on its own. Picking an amount changes an argument;
    /// only the two action rows send a command.
    private var quantizeMenu: some View {
        Menu {
            Button("Quantize Selection") { controller.quantizeSelection() }
                .disabled(!controller.canQuantizeSelection)
            Button("Quantize All Notes in Clip") { controller.quantizeAllNotesInClip() }
                .disabled(!controller.canQuantizeClip)
            Divider()
            Picker("Amount", selection: $controller.quantizeStrengthPercent) {
                // 100% is mechanical and usually wrong; 50-80 tightens the
                // timing while leaving the playing recognisable.
                ForEach([25, 50, 65, 80, 100], id: \.self) { percent in
                    Text("\(percent)%").tag(percent)
                }
            }
            Toggle("Quantize note ends too", isOn: $controller.quantizeEnds)
            Divider()
            Text(controller.quantizeGridTicks == nil
                 ? "Set a Grid other than Off to quantize"
                 : "Grid: \(controller.grid.label)")
        } label: {
            Image(systemName: "align.horizontal.left")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26)
        .foregroundStyle(StudioTokens.text)
        .studioHelp("pianoRoll.quantize")
        .accessibilityLabel("Quantize")
    }

    private var selectionSummary: String {
        let total = controller.clip?.notes.count ?? 0
        let selected = controller.selection.count
        return selected > 0 ? "\(selected) of \(total) notes" : "\(total) notes"
    }

    private func toolButton(
        _ systemImage: String,
        _ label: String,
        _ helpID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudioTokens.text)
        // The tooltip teaches; `label` stays the terse VoiceOver name.
        .studioHelp(helpID)
        .accessibilityLabel(label)
    }
}
