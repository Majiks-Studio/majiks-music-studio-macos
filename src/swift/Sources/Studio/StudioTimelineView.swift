import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Timeline canvas
//
// One SwiftUI Canvas draws ruler + lanes + clips + takes + overlays, culled
// to the viewport. Waveforms draw from cached unit-space tile paths (peaks
// arrays from the engine, DJ pattern); the graphics context is scaled per
// tile, so nothing is re-tessellated per frame. Track headers live in the
// separate SwiftUI column (StudioTrackHeaderColumn) for VoiceOver.

struct StudioTimelineCanvas: View {
    @ObservedObject var model: StudioViewModel
    @ObservedObject var tiles: StudioWaveformTileStore
    /// Observed for the same reason `tiles` is: a clip's notes land
    /// asynchronously, and the canvas has to be told to repaint when they do.
    @ObservedObject var midiNotes: StudioMidiNoteStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    @State private var contextClickPoint: CGPoint?
    @State private var contextBar: Int = 0
    @State private var contextTick: Int64 = 0
    @State private var showRenameAlert = false
    @State private var renameClipText = ""
    @State private var editingClipID: UUID?
    @State private var showTempoAlert = false
    @State private var tempoText = "120"

    init(model: StudioViewModel) {
        self.model = model
        self.tiles = model.tiles
        self.midiNotes = model.midiNotes
    }

    private var wantsFullRate: Bool {
        model.isPlaying || model.sweepActive || model.drag.kind != .none
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(
                minimumInterval: wantsFullRate ? nil : 1.0 / 12.0,
                paused: reduceMotion && !wantsFullRate
            )) { timeline in
                Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                    draw(
                        context: context,
                        size: size,
                        date: timeline.date
                    )
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in
                handleKeyPress(press)
            }
            .gesture(dragGesture(viewport: geo.size))
            .simultaneousGesture(doubleClickGesture(viewport: geo.size))
            .simultaneousGesture(magnifyGesture(viewport: geo.size))
            .onDrop(of: [.text, .fileURL, .audio], isTargeted: nil) { providers, location in
                handleDrop(providers, at: location, viewport: geo.size)
            }
            .overlay(alignment: .topTrailing) {
                tempoTruthBadges
                    .padding(.top, 4)
                    .padding(.trailing, 8)
            }
            .background(StudioScrollCatcher(onEvent: { event in
                handleScroll(event, viewport: geo.size)
            }, onContextClick: { point in
                // Runs BEFORE the context menu opens (local monitors fire
                // ahead of dispatch), so the menu below always acts on the
                // clip under the pointer.
                rightClickSelect(at: point, viewport: geo.size)
            }))
            // The pointer path to clip deletion and the clip rename/gain/mute
            // affordances. When the right-click lands in the ruler area, the
            // menu switches to section and marker actions instead.
            .contextMenu {
                if let point = contextClickPoint, point.y < rulerHeight {
                    rulerContextMenuContent()
                } else if !model.selection.clipIDs.isEmpty {
                    clipContextMenuContent()
                }
            }
            .alert("Rename Clip", isPresented: $showRenameAlert) {
                TextField("Clip name", text: $renameClipText)
                Button("Rename") {
                    if let id = editingClipID {
                        model.renameClip(id, name: renameClipText)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Set tempo", isPresented: $showTempoAlert) {
                TextField("BPM", text: $tempoText)
                // help-exempt: alert actions get no hover tooltip on macOS.
                Button("Set") {
                    if let bpm = Double(tempoText) { model.setTempo(bpm: bpm) }
                }
                // help-exempt: alert actions get no hover tooltip on macOS.
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The detected tempo is unavailable. Enter the tempo for this project.")
            }
            .onAppear {
                focused = true
                model.timelineViewportWidth = geo.size.width
            }
            .onChange(of: geo.size.width) { _, width in
                model.timelineViewportWidth = width
            }
            .accessibilityLabel("Timeline")
            .accessibilityHint("Arrangement canvas. Use the track headers for per-track controls.")
        }
        .clipped()
    }

    @ViewBuilder
    private var tempoTruthBadges: some View {
        if let snapshot = model.snapshot {
            let messages = StudioTempoTruth.messages(
                confidence: snapshot.tempoConfidence, timeSignature: snapshot.timeSignature)
            if !messages.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    if snapshot.tempoConfidence <= 0 {
                        HStack(spacing: 6) {
                            Label("Tempo not detected — grid at 120 BPM", systemImage: "exclamationmark.triangle.fill")
                            Button("Set tempo") {
                                tempoText = String(format: "%.3g", snapshot.tempoBPM)
                                showTempoAlert = true
                            }
                            .buttonStyle(.bordered)
                            .studioHelp(terse: "Set tempo",
                                        teaching: "Enter the song's tempo when automatic detection is unavailable.")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Tempo not detected. Grid at 120 BPM. Set tempo.")
                    }
                    if snapshot.timeSignature != .fourFour {
                        Label("Grid is 4/4 (v1); song requested \(snapshot.timeSignature.beatsPerBar)/\(snapshot.timeSignature.beatUnit)", systemImage: "info.circle")
                            .accessibilityLabel("Grid is 4/4 version 1; song requested \(snapshot.timeSignature.beatsPerBar) slash \(snapshot.timeSignature.beatUnit)")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(6)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.yellow)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], at point: CGPoint, viewport: CGSize) -> Bool {
        if let file = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            file.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in model.importAudio(path: url.path) }
            }
            return true
        }
        return handleStringDrop(providers, at: point, viewport: viewport)
    }

    // MARK: Layout constants

    /// The ruler is three stacked bands, top to bottom: sections, bar numbers,
    /// loop strip. Everything below is lanes. `StudioTrackHeaderColumn` sums
    /// the same three tokens so the header corner and the ruler stay level.
    /// Both the height and the band a press lands in come from
    /// `StudioRulerBand`, which is pure and unit-tested.
    private var rulerHeight: CGFloat { StudioRulerBand.rulerHeight }

    /// Top edge of the loop strip.
    private var loopStripY: CGFloat { StudioRulerBand.loopStripY }

    private func rows() -> [StudioRowLayout] {
        guard let snapshot = model.snapshot else { return [] }
        return StudioRowLayoutBuilder.rows(
            tracks: snapshot.tracks,
            expandedTakeLanes: model.expandedTakeLanes,
            visibleAutomationLanes: model.visibleAutomationLanes
        )
    }

    /// Drag-to-timeline for the two STRING payloads the browser vends: a take
    /// from the Takes browser (L10) and a sound from the Sounds vault.
    ///
    /// Both land on the point they were dropped on (X -> ticks, Y -> track
    /// lane), using the same row layout the canvas draws with so hit-testing
    /// never disagrees. Which of the two it is cannot be known until the
    /// payload has loaded — that is asynchronous — so the branch is inside the
    /// completion, keyed off `StudioSoundsBrowserActions.dragPrefix`. A take id
    /// has no prefix and falls through to the take path exactly as before.
    ///
    /// The tick here is the RAW pointer position. Snapping a dropped sound to
    /// the grid is `placeSound`'s job, not this one's — see its header for why
    /// it lives on the view model rather than at this call site.
    private func handleStringDrop(_ providers: [NSItemProvider], at point: CGPoint, viewport: CGSize) -> Bool {
        guard let provider = providers.first else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let scroll = model.effectiveScrollTicks(now: now, viewportWidth: viewport.width)
        let ticks = StudioTimelineMath.pxToTicks(point.x, pxPerTick: model.pxPerTick, scrollTicks: scroll)
        let laneY = point.y - rulerHeight + model.scrollY
        guard let row = StudioRowLayoutBuilder.row(at: laneY, rows: rows()),
              case .track(let trackID) = row.kind else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let payload = obj as? String else { return }
            Task { @MainActor in
                if let path = StudioSoundsBrowserActions.soundPath(fromDrag: payload) {
                    model.placeSound(path: path, onTrack: trackID, atTicks: max(0, ticks))
                } else {
                    model.dropTake(takeID: payload, trackID: trackID, atTicks: max(0, ticks))
                }
            }
        }
        return true
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext, size: CGSize, date: Date) {
        let drawStart = CACurrentMediaTime()
        defer {
            model.frameStats.recordDraw(startedAt: drawStart, fullRate: wantsFullRate)
        }

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(StudioTokens.bg))
        guard let snapshot = model.snapshot else {
            let text = Text("Loading project").font(.system(size: 12)).foregroundStyle(StudioTokens.dim)
            context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let scroll = model.effectiveScrollTicks(now: now, viewportWidth: size.width)
        let pxPerTick = model.pxPerTick
        let rowLayouts = rows()
        let lanesRect = CGRect(x: 0, y: rulerHeight, width: size.width, height: size.height - rulerHeight)
        let shimmerPhase = StudioTokens.shimmerPhase(now: date.timeIntervalSinceReferenceDate)

        // Lanes (clipped so scrolled rows never bleed into the ruler).
        var lanes = context
        lanes.clip(to: Path(lanesRect))
        drawGrid(&lanes, snapshot: snapshot, scroll: scroll, pxPerTick: pxPerTick, size: size)
        drawRows(
            &lanes, snapshot: snapshot, rowLayouts: rowLayouts, scroll: scroll,
            pxPerTick: pxPerTick, size: size, shimmerPhase: shimmerPhase)
        drawRegionSelection(
            &lanes, scroll: scroll, pxPerTick: pxPerTick, lanesRect: lanesRect,
            grid: snapshot.barGrid, shimmerPhase: shimmerPhase)
        drawRubberBand(&lanes)

        // Ruler, then playhead over everything. The loop strip is drawn as its
        // own call rather than from inside `drawRuler`, which bails early at
        // extreme zoom-out (`pxPerBar > 0.5`) — the bar TICKS are unreadable
        // there, but a loop brace is not, and vanishing it would be the
        // "the loop went away" bug.
        drawRuler(context, snapshot: snapshot, scroll: scroll, pxPerTick: pxPerTick, size: size)
        drawLoopStrip(context, scroll: scroll, pxPerTick: pxPerTick, size: size)
        drawPlayhead(context, snapshot: snapshot, now: now, scroll: scroll, pxPerTick: pxPerTick, size: size)
    }

    private func drawGrid(
        _ context: inout GraphicsContext,
        snapshot: StudioProjectSnapshot,
        scroll: Int64,
        pxPerTick: CGFloat,
        size: CGSize
    ) {
        let grid = snapshot.barGrid
        let sig = grid.timeSignature
        let tpb = grid.ticksPerBar
        let pxPerBar = CGFloat(tpb) * pxPerTick
        guard pxPerBar > 0.5 else { return }

        let lastTick = scroll + Int64(size.width / pxPerTick)

        // Section starts are 0-based bar INDICES, so bar 1 is index 0 — the
        // same origin `barLines` counts from.
        let sectionStarts = Set(snapshot.sections.map { Int64($0.startBar) })

        // Bar lines (draw only when bars are at least a few px apart). Same
        // source as the ruler above, so the two can never drift apart.
        let barStride = Int64(max(1, StudioTimelineMath.barLabelStride(pxPerBar: pxPerBar) / 4))
        var barPath = Path()
        var downbeatPath = Path()
        for line in StudioTimelineMath.barLines(
            grid: grid, fromTicks: scroll,
            toTicks: min(snapshot.lengthTicks, lastTick + tpb), strideBars: barStride
        ) {
            let x = StudioTimelineMath.ticksToPx(line.ticks, pxPerTick: pxPerTick, scrollTicks: scroll)
            guard x >= -1, x <= size.width + 1 else { continue }
            if sectionStarts.contains(Int64(line.barNumber - 1)) {
                downbeatPath.move(to: CGPoint(x: x, y: 0))
                downbeatPath.addLine(to: CGPoint(x: x, y: size.height))
            } else {
                barPath.move(to: CGPoint(x: x, y: 0))
                barPath.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        context.stroke(barPath, with: .color(.white.opacity(StudioTokens.gridBarAlpha)), lineWidth: 1)
        context.stroke(downbeatPath, with: .color(.white.opacity(StudioTokens.gridDownbeatAlpha)), lineWidth: 1)

        // Beat lines at high zoom.
        let pxPerBeat = CGFloat(sig.ticksPerBeat) * pxPerTick
        if StudioTimelineMath.showsBeatLines(pxPerBeat: pxPerBeat), barStride == 1 {
            var beatPath = Path()
            // Beats subdivide the ANCHORED bar, so they inherit its phase.
            for line in StudioTimelineMath.barLines(
                grid: grid, fromTicks: scroll - tpb,
                toTicks: min(snapshot.lengthTicks, lastTick + tpb)
            ) {
                for beat in 1..<sig.beatsPerBar {
                    let beatTick = line.ticks + Int64(beat) * sig.ticksPerBeat
                    let x = StudioTimelineMath.ticksToPx(beatTick, pxPerTick: pxPerTick, scrollTicks: scroll)
                    if x >= -1, x <= size.width + 1 {
                        beatPath.move(to: CGPoint(x: x, y: 0))
                        beatPath.addLine(to: CGPoint(x: x, y: size.height))
                    }
                }
            }
            context.stroke(beatPath, with: .color(.white.opacity(StudioTokens.gridBeatAlpha)), lineWidth: 1)
        }
    }

    private func drawRows(
        _ context: inout GraphicsContext,
        snapshot: StudioProjectSnapshot,
        rowLayouts: [StudioRowLayout],
        scroll: Int64,
        pxPerTick: CGFloat,
        size: CGSize,
        shimmerPhase: Double
    ) {
        let visibleTop = model.scrollY
        let visibleBottom = model.scrollY + size.height - rulerHeight
        // Row layouts contain track ids. Resolve them once per canvas pass so
        // a 32+ track session does not linearly scan the snapshot for every
        // visible row.
        let tracksByID = Dictionary(uniqueKeysWithValues: snapshot.tracks.map { ($0.id, $0) })

        for row in rowLayouts {
            guard row.maxY > visibleTop, row.y < visibleBottom else { continue }
            let rowY = rulerHeight + row.y - model.scrollY
            switch row.kind {
            case .track(let trackID):
                guard let track = tracksByID[trackID] else { continue }
                // Row separator.
                var sep = Path()
                sep.move(to: CGPoint(x: 0, y: rowY + row.height - 0.5))
                sep.addLine(to: CGPoint(x: size.width, y: rowY + row.height - 0.5))
                context.stroke(sep, with: .color(StudioTokens.strokeSoft), lineWidth: 1)
                drawClips(
                    &context, track: track, rowY: rowY, rowHeight: row.height,
                    scroll: scroll, pxPerTick: pxPerTick, size: size, shimmerPhase: shimmerPhase)

            case .takeLane(let trackID):
                guard let track = tracksByID[trackID],
                      let lane = track.takeLane else { continue }
                context.fill(
                    Path(CGRect(x: 0, y: rowY, width: size.width, height: row.height)),
                    with: .color(StudioTokens.panel))
                drawTakes(
                    &context, track: track, lane: lane, rowY: rowY,
                    scroll: scroll, pxPerTick: pxPerTick, size: size, shimmerPhase: shimmerPhase)

            case .automation(let trackID, let target):
                guard let track = tracksByID[trackID] else { continue }
                drawAutomationLane(
                    &context, track: track, target: target, rowY: rowY, height: row.height,
                    scroll: scroll, pxPerTick: pxPerTick, size: size)
            }
        }
    }

    private func drawClips(
        _ context: inout GraphicsContext,
        track: StudioTrackSnapshot,
        rowY: CGFloat,
        rowHeight: CGFloat,
        scroll: Int64,
        pxPerTick: CGFloat,
        size: CGSize,
        shimmerPhase: Double
    ) {
        let visibleTicks = scroll..<(scroll + Int64(size.width / max(pxPerTick, 0.000001)) + 1)
        let movingClipID = model.drag.kind == .clipMove ? model.drag.provisionalClip?.id : nil

        for raw in track.clips {
            // A clip being cross-track dragged draws as a ghost elsewhere.
            if raw.id == movingClipID { continue }
            let clip = model.effectiveClip(raw)
            guard clip.endTicks > visibleTicks.lowerBound, clip.startTicks < visibleTicks.upperBound else { continue }
            drawClipBody(
                &context, clip: clip, kind: track.kind, rowY: rowY, rowHeight: rowHeight,
                scroll: scroll, pxPerTick: pxPerTick, canvasWidth: size.width,
                shimmerPhase: shimmerPhase,
                selected: model.selection.clipIDs.contains(clip.id), ghost: false)
        }

        // Ghost for a cross-track move landing on this track.
        if let ghost = model.drag.provisionalClip, model.drag.kind == .clipMove,
           model.drag.targetTrackID == track.id {
            drawClipBody(
                &context, clip: ghost, kind: track.kind, rowY: rowY, rowHeight: rowHeight,
                scroll: scroll, pxPerTick: pxPerTick, canvasWidth: size.width,
                shimmerPhase: shimmerPhase,
                selected: true, ghost: true)
        }
    }

    private func drawClipBody(
        _ context: inout GraphicsContext,
        clip: StudioClipSnapshot,
        kind: StudioStemKind,
        rowY: CGFloat,
        rowHeight: CGFloat,
        scroll: Int64,
        pxPerTick: CGFloat,
        canvasWidth: CGFloat,
        shimmerPhase: Double,
        selected: Bool,
        ghost: Bool
    ) {
        let x = StudioTimelineMath.ticksToPx(clip.startTicks, pxPerTick: pxPerTick, scrollTicks: scroll)
        let width = max(2, CGFloat(clip.lengthTicks) * pxPerTick)
        let rect = CGRect(
            x: x, y: rowY + StudioTokens.clipVerticalInset,
            width: width, height: rowHeight - StudioTokens.clipVerticalInset * 2)
        let shape = Path(roundedRect: rect, cornerRadius: StudioTokens.clipCornerRadius)
        let stem = StudioTokens.stemColor(kind)

        context.fill(shape, with: .color(StudioTokens.clipFillColor(kind)))

        // The clip's CONTENTS, clipped to the clip shape.
        //
        // This used to call `drawWaveform` unconditionally, for every clip
        // regardless of kind. A MIDI clip has no audio, so it has no waveform
        // tiles, so the call drew nothing and every note clip in the
        // arrangement was a flat coloured rectangle with a name on it — an
        // empty clip and a 56-note performance rendered identically.
        var wave = context
        wave.clip(to: shape)
        if clip.isMidi {
            drawMidiNotes(
                &wave, clip: clip, kind: kind, rect: rect,
                pxPerTick: pxPerTick, canvasWidth: canvasWidth, dim: ghost)
        } else {
            drawWaveform(&wave, clip: clip, kind: kind, rect: rect, pxPerTick: pxPerTick, dim: ghost)
        }

        // Fades: darkened wedges + (when selected) corner handles.
        if clip.fadeInTicks > 0 {
            let fw = min(CGFloat(clip.fadeInTicks) * pxPerTick, rect.width)
            wave.fill(
                Path(CGRect(x: rect.minX, y: rect.minY, width: fw, height: rect.height)),
                with: .linearGradient(
                    Gradient(colors: [.black.opacity(0.55), .clear]),
                    startPoint: CGPoint(x: rect.minX, y: rect.midY),
                    endPoint: CGPoint(x: rect.minX + fw, y: rect.midY)))
        }
        if clip.fadeOutTicks > 0 {
            let fw = min(CGFloat(clip.fadeOutTicks) * pxPerTick, rect.width)
            wave.fill(
                Path(CGRect(x: rect.maxX - fw, y: rect.minY, width: fw, height: rect.height)),
                with: .linearGradient(
                    Gradient(colors: [.clear, .black.opacity(0.55)]),
                    startPoint: CGPoint(x: rect.maxX - fw, y: rect.midY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
        }

        context.stroke(
            Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: StudioTokens.clipCornerRadius),
            with: .color(stem.opacity(ghost ? 0.8 : StudioTokens.clipStrokeAlpha)),
            lineWidth: 1)

        if selected && !ghost {
            context.fill(shape, with: .color(.white.opacity(0.06)))
            context.stroke(
                Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: StudioTokens.clipCornerRadius - 1),
                with: .color(.white.opacity(0.85)), lineWidth: 1)
            drawFadeHandles(&context, clip: clip, rect: rect, pxPerTick: pxPerTick)
        }

        // Name tag.
        if rect.width > 40 {
            let tag = Text(clip.name)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(StudioTokens.clipTagColor(kind))
            context.draw(tag, at: CGPoint(x: rect.minX + 7, y: rect.minY + 7), anchor: .leading)
        }

        // AI badge: generative clips only (THE SHIMMER RULE).
        if clip.generative, rect.width > 64 {
            let badgeRect = CGRect(x: rect.maxX - 26, y: rect.minY + 3, width: 20, height: 11)
            let badge = Path(roundedRect: badgeRect, cornerRadius: 5.5)
            let phase = reduceMotion ? 0.5 : shimmerPhase
            context.fill(badge, with: .linearGradient(
                Gradient(stops: StudioTokens.gradientStops),
                startPoint: CGPoint(x: badgeRect.minX - badgeRect.width * phase, y: badgeRect.minY),
                endPoint: CGPoint(x: badgeRect.maxX + badgeRect.width * (1 - phase), y: badgeRect.maxY)))
            context.draw(
                Text("AI").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white),
                at: CGPoint(x: badgeRect.midX, y: badgeRect.midY))
        }

        if clip.muted {
            context.fill(shape, with: .color(StudioTokens.bg.opacity(0.5)))
        }
    }

    /// The note-clip counterpart of `drawWaveform`.
    ///
    /// Same shape as the waveform path on purpose: ask the store for what it
    /// holds, draw that, and arm a fetch for what it does not. The fetch is
    /// gated on the project's journal revision, so a rolling transport — which
    /// repaints this canvas continuously and does not move the revision — costs
    /// exactly one dictionary lookup per clip per frame and no engine calls at
    /// all. See StudioMidiNoteStore for why the notes are not simply on the
    /// snapshot.
    private func drawMidiNotes(
        _ context: inout GraphicsContext,
        clip: StudioClipSnapshot,
        kind: StudioStemKind,
        rect: CGRect,
        pxPerTick: CGFloat,
        canvasWidth: CGFloat,
        dim: Bool
    ) {
        let content = midiNotes.content(for: clip.id)
        // Unconditional, NOT "only when pending": notes drawn in the piano roll
        // have to reach the arrangement, and they only do so if a clip whose
        // notes are already cached is still re-checked against the revision.
        // The store's own gate (revision, in-flight, refetch interval) makes
        // this a few dictionary lookups when there is nothing to do.
        midiNotes.request(
            clip.id,
            projectRevision: model.snapshot?.revision ?? 0,
            from: model.noteEngine)
        StudioMidiClipRender.draw(
            &context, content: content, kind: kind, rect: rect,
            pxPerTick: pxPerTick, visibleX: 0...max(0, canvasWidth), dim: dim)
    }

    private func drawWaveform(
        _ context: inout GraphicsContext,
        clip: StudioClipSnapshot,
        kind: StudioStemKind,
        rect: CGRect,
        pxPerTick: CGFloat,
        dim: Bool
    ) {
        let bucket = StudioTileScheme.bucket(forPxPerTick: pxPerTick)
        let sourceRange = clip.sourceOffsetTicks..<(clip.sourceOffsetTicks + clip.lengthTicks)
        let tileRange = StudioTileScheme.tileRange(bucket: bucket, sourceTicks: sourceRange)
        let ticksPerTile = StudioTileScheme.ticksPerTile(bucket: bucket)
        let amplitude = rect.height / 2 - 3
        let color = StudioTokens.stemColor(kind).opacity(
            dim ? StudioTokens.waveformDimAlpha : StudioTokens.waveformBodyAlpha)

        for tileIndex in tileRange {
            let key = StudioTileKey(seed: clip.waveformSeed, bucket: bucket, tileIndex: tileIndex)
            guard let tile = tiles.tile(for: key) else {
                tiles.request(key, from: model.engine)
                // Placeholder: quiet midline while the tile renders.
                var line = Path()
                line.move(to: CGPoint(x: rect.minX, y: rect.midY))
                line.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                context.stroke(line, with: .color(color.opacity(0.3)), lineWidth: 1)
                continue
            }
            // Tile origin in timeline px.
            let tileStartSourceTick = Int64(tileIndex) * ticksPerTile
            let clipRelative = tileStartSourceTick - clip.sourceOffsetTicks
            let tileX = rect.minX + CGFloat(clipRelative) * pxPerTick
            let pxPerBin = CGFloat(tile.ticksPerBin) * pxPerTick

            var tileCtx = context
            tileCtx.translateBy(x: tileX, y: rect.midY)
            tileCtx.scaleBy(x: pxPerBin, y: amplitude)
            tileCtx.fill(tile.path, with: .color(color))
        }
    }

    private func drawFadeHandles(
        _ context: inout GraphicsContext,
        clip: StudioClipSnapshot,
        rect: CGRect,
        pxPerTick: CGFloat
    ) {
        for (ticks, isIn) in [(clip.fadeInTicks, true), (clip.fadeOutTicks, false)] {
            let fx = isIn
                ? rect.minX + CGFloat(ticks) * pxPerTick
                : rect.maxX - CGFloat(ticks) * pxPerTick
            let handle = CGRect(x: fx - 3.5, y: rect.minY + 1, width: 7, height: 7)
            context.fill(Path(ellipseIn: handle), with: .color(.white.opacity(0.9)))
            context.stroke(Path(ellipseIn: handle), with: .color(StudioTokens.bg), lineWidth: 1)
        }
    }

    private func drawTakes(
        _ context: inout GraphicsContext,
        track: StudioTrackSnapshot,
        lane: StudioTakeLaneSnapshot,
        rowY: CGFloat,
        scroll: Int64,
        pxPerTick: CGFloat,
        size: CGSize,
        shimmerPhase: Double
    ) {
        let x = StudioTimelineMath.ticksToPx(lane.regionStartTicks, pxPerTick: pxPerTick, scrollTicks: scroll)
        let width = CGFloat(lane.regionLengthTicks) * pxPerTick
        guard x < size.width, x + width > 0 else { return }
        let stem = StudioTokens.stemColor(track.kind)

        for (i, take) in lane.takes.enumerated() {
            let rect = CGRect(
                x: x, y: rowY + CGFloat(i) * StudioTokens.takeRowHeight + 4,
                width: width, height: StudioTokens.takeRowHeight - 6)
            let shape = Path(roundedRect: rect, cornerRadius: 5)

            switch take.state {
            case .rendered(let seed):
                context.fill(shape, with: .color(StudioTokens.takeFillColor(track.kind)))
                var wave = context
                wave.clip(to: shape)
                let fake = StudioClipSnapshot(
                    id: take.id, name: take.name, startTicks: lane.regionStartTicks,
                    lengthTicks: lane.regionLengthTicks, sourceOffsetTicks: 0,
                    generative: true, waveformSeed: seed)
                drawWaveform(&wave, clip: fake, kind: track.kind, rect: rect, pxPerTick: pxPerTick, dim: true)
            case .rendering:
                // Rendering takes are generative surfaces: shimmer allowed.
                let phase = reduceMotion ? 0.5 : shimmerPhase
                context.fill(shape, with: .linearGradient(
                    Gradient(stops: StudioTokens.gradientStops),
                    startPoint: CGPoint(x: rect.minX - rect.width * phase, y: rect.minY),
                    endPoint: CGPoint(x: rect.maxX + rect.width * (1 - phase), y: rect.maxY)))
                context.fill(shape, with: .color(StudioTokens.clipBase.opacity(0.72)))
            }

            context.stroke(
                Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 5),
                with: .color(take.picked ? stem : stem.opacity(0.45)),
                lineWidth: take.picked ? 2 : 1)

            if rect.width > 56 {
                let label = take.state == .rendering ? "\(take.name), rendering" : take.name
                context.draw(
                    Text(label).font(.system(size: 9, weight: .bold))
                        .foregroundStyle(take.picked ? StudioTokens.text : StudioTokens.dim),
                    at: CGPoint(x: rect.minX + 6, y: rect.midY), anchor: .leading)
            }
        }
    }

    /// Draw a live automation lane via the shared renderer (identical to the
    /// evidence preview), feeding it the live drag provisional for this lane.
    private func drawAutomationLane(
        _ context: inout GraphicsContext,
        track: StudioTrackSnapshot,
        target: StudioAutoTarget,
        rowY: CGFloat,
        height: CGFloat,
        scroll: Int64,
        pxPerTick: CGFloat,
        size: CGSize
    ) {
        let provisional: StudioAutoPoint? = (model.drag.kind == .automationPoint
            && model.drag.autoTrackID == track.id && model.drag.autoTarget == target)
            ? model.drag.autoProvisional : nil
        StudioAutomationLaneRenderer.draw(
            &context, track: track, target: target, rowY: rowY, height: height,
            width: size.width, scroll: scroll, pxPerTick: pxPerTick, dragProvisional: provisional)
    }

    private func drawRegionSelection(
        _ context: inout GraphicsContext,
        scroll: Int64,
        pxPerTick: CGFloat,
        lanesRect: CGRect,
        grid: StudioBarGrid,
        shimmerPhase: Double
    ) {
        guard let region = model.selection.region else { return }
        let x0 = StudioTimelineMath.ticksToPx(region.startTicks, pxPerTick: pxPerTick, scrollTicks: scroll)
        let x1 = StudioTimelineMath.ticksToPx(region.endTicks, pxPerTick: pxPerTick, scrollTicks: scroll)
        guard x1 > 0, x0 < lanesRect.maxX else { return }
        let rect = CGRect(x: x0, y: lanesRect.minY, width: x1 - x0, height: lanesRect.height)

        context.fill(Path(rect), with: .color(StudioTokens.purple.opacity(0.08)))

        // Region edges carry the generative gradient: this region is the
        // revise unit (in-flight/armed revise border, THE SHIMMER RULE).
        let phase = reduceMotion ? 0.5 : shimmerPhase
        for edgeX in [x0, x1] {
            let edge = CGRect(x: edgeX - 1, y: rect.minY, width: 2, height: rect.height)
            context.fill(Path(edge), with: .linearGradient(
                Gradient(stops: StudioTokens.gradientStops),
                startPoint: CGPoint(x: edge.midX, y: rect.minY - rect.height * phase),
                endPoint: CGPoint(x: edge.midX, y: rect.maxY + rect.height * (1 - phase))))
        }

        // Floating pill: "Revise bars 33-48, press R".
        let bars = region.barRange(grid: grid)
        let pillText = Text("Revise bars \(bars.lowerBound)-\(bars.upperBound)  R")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.white)
        let resolved = context.resolve(pillText)
        let textSize = resolved.measure(in: CGSize(width: 400, height: 40))
        let pillRect = CGRect(
            x: rect.midX - textSize.width / 2 - 11, y: rect.minY + 6,
            width: textSize.width + 22, height: 20)
        context.fill(
            Path(roundedRect: pillRect, cornerRadius: 10),
            with: .linearGradient(
                Gradient(stops: StudioTokens.gradientStops),
                startPoint: CGPoint(x: pillRect.minX - pillRect.width * phase, y: pillRect.minY),
                endPoint: CGPoint(x: pillRect.maxX + pillRect.width * (1 - phase), y: pillRect.maxY)))
        context.draw(resolved, at: CGPoint(x: pillRect.midX, y: pillRect.midY))
    }

    private func drawRubberBand(_ context: inout GraphicsContext) {
        guard model.drag.kind == .rubberBand else { return }
        let rect = StudioSelectionOps.bandRect(from: model.drag.startPoint, to: model.drag.currentPoint)
        context.fill(Path(rect), with: .color(.white.opacity(0.05)))
        context.stroke(Path(rect), with: .color(.white.opacity(0.25)), lineWidth: 1)
    }

    private func drawRuler(
        _ context: GraphicsContext,
        snapshot: StudioProjectSnapshot,
        scroll: Int64,
        pxPerTick: CGFloat,
        size: CGSize
    ) {
        let grid = snapshot.barGrid
        let tpb = grid.ticksPerBar
        let pxPerBar = CGFloat(tpb) * pxPerTick

        // Sections band.
        context.fill(
            Path(CGRect(x: 0, y: 0, width: size.width, height: StudioTokens.sectionRulerHeight)),
            with: .color(StudioTokens.panel))
        for section in snapshot.sections {
            let start = grid.tickForBarIndex(Int64(section.startBar))
            let end = grid.tickForBarIndex(Int64(section.startBar + section.lengthBars))
            let x0 = StudioTimelineMath.ticksToPx(start, pxPerTick: pxPerTick, scrollTicks: scroll)
            let w = CGFloat(end - start) * pxPerTick
            guard x0 + w > 0, x0 < size.width else { continue }
            let rect = CGRect(x: x0, y: 0, width: w, height: StudioTokens.sectionRulerHeight)
            context.fill(Path(rect), with: .color(StudioTokens.sectionColor(section.role)))
            var border = Path()
            border.move(to: CGPoint(x: rect.maxX - 0.5, y: 0))
            border.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.height))
            context.stroke(border, with: .color(.black.opacity(0.4)), lineWidth: 1)
            if w > 34 {
                context.draw(
                    Text(section.name).font(.system(size: 9, weight: .bold)).foregroundStyle(.white),
                    at: CGPoint(x: rect.minX + 8, y: rect.midY), anchor: .leading)
            }
        }

        // Bars band.
        let barsRect = CGRect(
            x: 0, y: StudioTokens.sectionRulerHeight,
            width: size.width, height: StudioTokens.barRulerHeight)
        context.fill(Path(barsRect), with: .color(StudioTokens.bg))
        var bottom = Path()
        bottom.move(to: CGPoint(x: 0, y: barsRect.maxY - 0.5))
        bottom.addLine(to: CGPoint(x: size.width, y: barsRect.maxY - 0.5))
        context.stroke(bottom, with: .color(StudioTokens.strokeSoft), lineWidth: 1)

        guard pxPerBar > 0.5 else { return }
        let labelStride = Int64(StudioTimelineMath.barLabelStride(pxPerBar: pxPerBar))
        var ticksPath = Path()
        let lastTick = min(snapshot.lengthTicks, scroll + Int64(size.width / pxPerTick) + tpb)
        for line in StudioTimelineMath.barLines(
            grid: snapshot.barGrid, fromTicks: scroll, toTicks: lastTick, strideBars: labelStride
        ) {
            let x = StudioTimelineMath.ticksToPx(line.ticks, pxPerTick: pxPerTick, scrollTicks: scroll)
            ticksPath.move(to: CGPoint(x: x, y: barsRect.minY))
            ticksPath.addLine(to: CGPoint(x: x, y: barsRect.maxY))
            if x < size.width - 20 {
                context.draw(
                    Text("\(line.barNumber)")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(StudioTokens.faint),
                    at: CGPoint(x: x + 4, y: barsRect.midY), anchor: .leading)
            }
        }
        context.stroke(ticksPath, with: .color(.white.opacity(0.13)), lineWidth: 1)
    }

    /// The loop strip and its brace.
    ///
    /// Draws whatever `model.effectiveLoopRegion` says: the live draft while a
    /// loop drag is in flight, otherwise the region the ENGINE is holding
    /// (`snapshot.transport.loop`, which is the engine's own `transport.loop`
    /// view round-tripped through `meters`-adjacent transport JSON). With no
    /// loop the strip is an empty gutter with a hint of texture — visible
    /// enough to invite a drag, never a brace that is not there.
    private func drawLoopStrip(
        _ context: GraphicsContext,
        scroll: Int64,
        pxPerTick: CGFloat,
        size: CGSize
    ) {
        let strip = CGRect(
            x: 0, y: loopStripY, width: size.width, height: StudioTokens.loopRulerHeight)
        context.fill(Path(strip), with: .color(StudioTokens.clipBase))

        var top = Path()
        top.move(to: CGPoint(x: 0, y: strip.minY + 0.5))
        top.addLine(to: CGPoint(x: size.width, y: strip.minY + 0.5))
        context.stroke(top, with: .color(StudioTokens.strokeSoft), lineWidth: 1)

        guard let region = model.effectiveLoopRegion else { return }
        let x0 = StudioTimelineMath.ticksToPx(
            region.lowerBound, pxPerTick: pxPerTick, scrollTicks: scroll)
        let x1 = StudioTimelineMath.ticksToPx(
            region.upperBound, pxPerTick: pxPerTick, scrollTicks: scroll)
        guard x1 > 0, x0 < size.width else { return }

        let brace = CGRect(x: x0, y: strip.minY + 2, width: max(2, x1 - x0), height: strip.height - 4)
        context.fill(
            Path(roundedRect: brace, cornerRadius: 3),
            with: .color(StudioTokens.purple.opacity(0.55)))
        context.stroke(
            Path(roundedRect: brace, cornerRadius: 3),
            with: .color(StudioTokens.purple), lineWidth: 1)

        // End caps: the two edges you would grab, drawn solid so the brace
        // reads as a bracket rather than a coloured smear at TV distance.
        for capX in [brace.minX, brace.maxX - 2] where capX >= -2 && capX <= size.width {
            context.fill(
                Path(CGRect(x: capX, y: strip.minY + 1, width: 2, height: strip.height - 2)),
                with: .color(StudioTokens.purple))
        }

        // The loop region shaded down the lanes, so you can see WHAT repeats
        // without reading the strip. Faint: the region selection already owns
        // the strong tint down there.
        context.fill(
            Path(CGRect(x: brace.minX, y: rulerHeight,
                        width: brace.width, height: max(0, size.height - rulerHeight))),
            with: .color(StudioTokens.purple.opacity(0.05)))
    }

    private func drawPlayhead(
        _ context: GraphicsContext,
        snapshot: StudioProjectSnapshot,
        now: TimeInterval,
        scroll: Int64,
        pxPerTick: CGFloat,
        size: CGSize
    ) {
        // The draft while a scrub drag is running, else engine truth. The draft
        // is what makes the line track the cursor at display rate: engine truth
        // only moves when a snapshot poll lands, so a drag drawn from it would
        // lag visibly behind the pointer and read as "it does not move".
        let ticks = model.effectivePlayheadTicks(now: now)
        let x = StudioTimelineMath.ticksToPx(ticks, pxPerTick: pxPerTick, scrollTicks: scroll)
        guard x >= -8, x <= size.width + 8 else { return }
        let scrubbing = model.drag.kind == .playheadScrub

        var glow = Path()
        glow.move(to: CGPoint(x: x, y: 0))
        glow.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(glow, with: .color(.white.opacity(scrubbing ? 0.45 : 0.25)), lineWidth: 3)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(.white), lineWidth: 1)

        // THE GRAB HANDLE SITS IN THE BAND THAT OWNS THE GESTURE.
        //
        // It used to be a 7 pt triangle at y = 0, which is inside the SECTIONS
        // band — so the one part of the play head that looked grabbable was the
        // one part that does something else when you drag it (select bars).
        // Pressing the visible handle selected a region and the play head did
        // not move, which is exactly the "I cannot drag that playing bar thing"
        // report. The handle is now drawn across the bar-numbers band, the band
        // whose drag scrubs, so the affordance and the gesture are the same
        // pixels. Nothing about the band split changes: the three ruler bands
        // stay disjoint y-ranges and still each own exactly one drag.
        let top = StudioTokens.sectionRulerHeight
        let bottom = StudioRulerBand.loopStripY
        let halfWidth: CGFloat = 6
        var grip = Path()
        grip.move(to: CGPoint(x: x - halfWidth, y: top))
        grip.addLine(to: CGPoint(x: x + halfWidth, y: top))
        grip.addLine(to: CGPoint(x: x + halfWidth, y: bottom - 5))
        grip.addLine(to: CGPoint(x: x, y: bottom))
        grip.addLine(to: CGPoint(x: x - halfWidth, y: bottom - 5))
        grip.closeSubpath()
        context.fill(grip, with: .color(scrubbing ? StudioTokens.purple : .white))
        context.stroke(grip, with: .color(.white.opacity(scrubbing ? 1.0 : 0.0)), lineWidth: 1)
    }

    // MARK: - Gestures

    private func dragGesture(viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                focused = true
                if model.drag.kind == .none {
                    beginDrag(at: value.startLocation, viewport: viewport)
                }
                updateDrag(to: value.location, viewport: viewport)
            }
            .onEnded { value in
                let moved = hypot(
                    value.location.x - value.startLocation.x,
                    value.location.y - value.startLocation.y)
                let kind = model.drag.kind
                if moved < 3, kind == .rubberBand {
                    // A click on empty space or a clip: selection semantics.
                    click(at: value.startLocation, viewport: viewport)
                    model.cancelDrag()
                } else if moved < 3, kind == .clipMove {
                    // Click on a clip without movement: already selected in begin.
                    model.cancelDrag()
                } else if moved < 3, kind == .loopRegion {
                    // A CLICK in the loop strip clears the loop. It is the
                    // inverse of the drag, in the same place as the drag, and
                    // it is the reason this feature does not need an undo step
                    // the engine would refuse to give it (loop is transport
                    // class: `Command::is_undoable()` is false for it).
                    model.clearLoop()
                    model.cancelDrag()
                } else {
                    updateDrag(to: value.location, viewport: viewport)
                    model.endDrag()
                }
            }
    }

    private func doubleClickGesture(viewport: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                // Double-click a section header: select that section's bars.
                guard value.location.y < StudioTokens.sectionRulerHeight,
                      let snapshot = model.snapshot else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let scroll = model.effectiveScrollTicks(now: now, viewportWidth: viewport.width)
                let tick = StudioTimelineMath.pxToTicks(
                    value.location.x, pxPerTick: model.pxPerTick, scrollTicks: scroll)
                let grid = snapshot.barGrid
                guard let section = snapshot.sections.first(where: {
                    tick >= grid.tickForBarIndex(Int64($0.startBar))
                        && tick < grid.tickForBarIndex(Int64($0.startBar + $0.lengthBars))
                }) else { return }
                model.selection.clipIDs.removeAll()
                model.selection.region = StudioRegionSelection(
                    rawStart: grid.tickForBarIndex(Int64(section.startBar)),
                    rawEnd: grid.tickForBarIndex(Int64(section.startBar + section.lengthBars)))
                model.reviseArmed = false
            }
    }

    @State private var magnifyBaseline: CGFloat?

    private func magnifyGesture(viewport: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = magnifyBaseline ?? model.pxPerTick
                magnifyBaseline = base
                let anchor = value.startLocation.x
                let target = StudioTimelineMath.clampZoom(base * value.magnification)
                guard model.pxPerTick > 0 else { return }
                model.zoom(by: target / model.pxPerTick, anchorPx: anchor)
            }
            .onEnded { _ in magnifyBaseline = nil }
    }

    private func handleScroll(_ event: StudioScrollEvent, viewport: CGSize) {
        switch event {
        case .pan(let dx, let dy):
            let contentHeight = StudioRowLayoutBuilder.totalHeight(rows()) + 80
            model.pan(
                byPx: -dx, dyPx: -dy,
                contentHeight: contentHeight,
                viewportHeight: viewport.height - rulerHeight)
        case .zoom(let factor, let atX):
            model.zoom(by: factor, anchorPx: atX)
        }
    }

    // MARK: Hit testing

    private struct ClipHit {
        var clip: StudioClipSnapshot
        var track: StudioTrackSnapshot
        var rect: CGRect
    }

    private func hitClip(at point: CGPoint, viewport: CGSize) -> ClipHit? {
        guard let snapshot = model.snapshot else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let scroll = model.effectiveScrollTicks(now: now, viewportWidth: viewport.width)
        let rowLayouts = rows()
        let laneY = point.y - rulerHeight + model.scrollY
        guard let row = StudioRowLayoutBuilder.row(at: laneY, rows: rowLayouts),
              case .track(let trackID) = row.kind,
              let track = snapshot.tracks.first(where: { $0.id == trackID }) else { return nil }

        for raw in track.clips.reversed() {
            let clip = model.effectiveClip(raw)
            let x = StudioTimelineMath.ticksToPx(clip.startTicks, pxPerTick: model.pxPerTick, scrollTicks: scroll)
            let width = max(2, CGFloat(clip.lengthTicks) * model.pxPerTick)
            let rect = CGRect(
                x: x, y: rulerHeight + row.y - model.scrollY + StudioTokens.clipVerticalInset,
                width: width, height: row.height - StudioTokens.clipVerticalInset * 2)
            if rect.insetBy(dx: -2, dy: 0).contains(point) {
                return ClipHit(clip: clip, track: track, rect: rect)
            }
        }
        return nil
    }

    private func visibleClipFrames(viewport: CGSize) -> [(id: UUID, frame: CGRect)] {
        guard let snapshot = model.snapshot else { return [] }
        let now = ProcessInfo.processInfo.systemUptime
        let scroll = model.effectiveScrollTicks(now: now, viewportWidth: viewport.width)
        var out: [(UUID, CGRect)] = []
        for row in rows() {
            guard case .track(let trackID) = row.kind,
                  let track = snapshot.tracks.first(where: { $0.id == trackID }) else { continue }
            for raw in track.clips {
                let clip = model.effectiveClip(raw)
                let x = StudioTimelineMath.ticksToPx(clip.startTicks, pxPerTick: model.pxPerTick, scrollTicks: scroll)
                let width = max(2, CGFloat(clip.lengthTicks) * model.pxPerTick)
                out.append((clip.id, CGRect(
                    x: x, y: rulerHeight + row.y - model.scrollY + StudioTokens.clipVerticalInset,
                    width: width, height: row.height - StudioTokens.clipVerticalInset * 2)))
            }
        }
        return out
    }

    // MARK: Drag routing

    private func beginDrag(at point: CGPoint, viewport: CGSize) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        var state = StudioDragState()
        state.startPoint = point
        state.currentPoint = point
        state.shift = shift

        let now = ProcessInfo.processInfo.systemUptime
        let scroll = model.effectiveScrollTicks(now: now, viewportWidth: viewport.width)
        let tickAt = { (x: CGFloat) in
            StudioTimelineMath.pxToTicks(x, pxPerTick: model.pxPerTick, scrollTicks: scroll)
        }

        // GESTURE COEXISTENCE RULE, stated once, here: the ruler's three bands
        // each own exactly one drag, decided by WHERE the press lands and
        // nothing else. No modifier keys, no press-and-hold, no "drag far
        // enough and it becomes something else". Sections band -> select bars;
        // bar-numbers band -> scrub the play head; loop strip -> set the loop.
        // The bands are disjoint y-ranges, so the three cannot race, and a
        // person who learns one has learned where the others are. (This
        // codebase has lost days to gestures that shared a surface — the
        // horizontal `ScrollView` that ate Button clicks, the piano roll's
        // explicit transforms. Disjoint bands is the cheapest way not to
        // repeat it. There is no `ScrollView` anywhere in this view.)
        let band = StudioRulerBand.at(y: point.y)
        if band == .sections {
            // Sections band: region selection (bar-snapped by design).
            state.kind = .rulerRegion
            state.anchorTicks = tickAt(point.x)
        } else if band == .bars {
            // Bars band: playhead scrub. The press only sets the LOCAL draft;
            // the single `transport.seek` goes out on release (`endDrag`),
            // exactly like the loop strip below. A click (press + release with
            // no movement) therefore still jumps the play head, because
            // `onEnded` runs `endDrag` for this kind — one command either way.
            state.kind = .playheadScrub
            model.playheadDraft = model.clampedPlayhead(tickAt(point.x))
        } else if band == .loop {
            // Loop strip: draw a loop brace. The anchor is where you pressed;
            // the drag only moves a LOCAL draft (`model.loopDraft`) and the
            // single `transport.loop.set` goes out on release.
            state.kind = .loopRegion
            state.anchorTicks = tickAt(point.x)
        } else if let hit = hitClip(at: point, viewport: viewport) {
            let edge: CGFloat = 6
            let fadeInX = hit.rect.minX + CGFloat(hit.clip.fadeInTicks) * model.pxPerTick
            let fadeOutX = hit.rect.maxX - CGFloat(hit.clip.fadeOutTicks) * model.pxPerTick
            let nearTop = point.y < hit.rect.minY + 10
            let selected = model.selection.clipIDs.contains(hit.clip.id)

            if selected, nearTop, abs(point.x - fadeInX) <= 7 {
                state.kind = .fadeIn
            } else if selected, nearTop, abs(point.x - fadeOutX) <= 7 {
                state.kind = .fadeOut
            } else if point.x <= hit.rect.minX + edge {
                state.kind = .clipTrimLeading
            } else if point.x >= hit.rect.maxX - edge {
                state.kind = .clipTrimTrailing
            } else {
                state.kind = .clipMove
                state.grabOffsetTicks = tickAt(point.x) - hit.clip.startTicks
                if !selected {
                    model.selection = StudioSelectionOps.clicked(
                        model.selection, clipID: hit.clip.id, shift: shift)
                }
            }
            state.originalClip = hit.clip
            state.provisionalClip = hit.clip
            state.targetTrackID = hit.track.id
        } else if let auto = automationLaneHit(at: point) {
            // In an automation lane: option-click removes the nearest point,
            // click-or-drag on a point moves it, click on empty space draws one.
            let track = model.snapshot?.tracks.first(where: { $0.id == auto.trackID })
            let existing = track.flatMap {
                StudioAutomationMath.nearestPoint(
                    $0.automation(auto.target), target: auto.target,
                    pxPerTick: model.pxPerTick, scrollTicks: scroll,
                    rowY: auto.rowY, height: auto.height, at: point)
            }
            if NSEvent.modifierFlags.contains(.option), let hitPoint = existing {
                model.removeAutoPoint(auto.trackID, target: auto.target, id: hitPoint.id)
                return   // a removal, not a drag
            }
            state.kind = .automationPoint
            state.autoTrackID = auto.trackID
            state.autoTarget = auto.target
            if let hitPoint = existing {
                state.autoIsNew = false
                state.autoProvisional = hitPoint
            } else {
                let tick = StudioTimelineMath.snap(
                    max(0, tickAt(point.x)), mode: model.snapMode,
                    grid: model.barGrid, pxPerTick: model.pxPerTick)
                let value = StudioAutomationMath.yToValue(
                    point.y, target: auto.target, rowY: auto.rowY, height: auto.height)
                state.autoIsNew = true
                state.autoProvisional = StudioAutoPoint(
                    id: model.mintAutoPointID(), positionTicks: tick, value: value)
            }
        } else {
            state.kind = .rubberBand
        }
        model.beginDrag(state)
    }

    private struct AutoLaneHit {
        var trackID: UUID
        var target: StudioAutoTarget
        var rowY: CGFloat
        var height: CGFloat
    }

    /// The automation lane under a canvas point, with its on-screen geometry.
    private func automationLaneHit(at point: CGPoint) -> AutoLaneHit? {
        guard model.snapshot != nil else { return nil }
        let laneY = point.y - rulerHeight + model.scrollY
        guard let row = StudioRowLayoutBuilder.row(at: laneY, rows: rows()),
              case .automation(let trackID, let target) = row.kind else { return nil }
        return AutoLaneHit(
            trackID: trackID, target: target,
            rowY: rulerHeight + row.y - model.scrollY, height: row.height)
    }

    /// The on-screen geometry of a specific lane (kept stable through a drag
    /// even if the cursor leaves the lane vertically).
    private func automationLaneGeometry(_ trackID: UUID?, _ target: StudioAutoTarget?) -> (rowY: CGFloat, height: CGFloat)? {
        guard let trackID, let target else { return nil }
        for row in rows() {
            if case .automation(let tid, let tgt) = row.kind, tid == trackID, tgt == target {
                return (rulerHeight + row.y - model.scrollY, row.height)
            }
        }
        return nil
    }

    private func updateDrag(to point: CGPoint, viewport: CGSize) {
        guard model.drag.kind != .none else { return }
        var state = model.drag
        state.currentPoint = point

        let now = ProcessInfo.processInfo.systemUptime
        let scroll = model.effectiveScrollTicks(now: now, viewportWidth: viewport.width)
        let rawTick = StudioTimelineMath.pxToTicks(point.x, pxPerTick: model.pxPerTick, scrollTicks: scroll)

        switch state.kind {
        case .rulerRegion:
            model.selection.clipIDs.removeAll()
            model.selection.region = StudioSelectionOps.rulerRegion(
                fromTicks: state.anchorTicks, toTicks: rawTick, grid: model.barGrid)
            model.reviseArmed = false

        case .loopRegion:
            // Bar-snapped, minimum one bar — the same rule the sections band
            // uses, reached through the same helper, so a loop and a selection
            // drawn over the same bars land on identical ticks.
            model.loopDraft = StudioSelectionOps.rulerRegion(
                fromTicks: state.anchorTicks, toTicks: rawTick, grid: model.barGrid)
                .map { $0.startTicks...$0.endTicks }

        case .playheadScrub:
            // Local draft only. NOT `model.seek` — that was a command per
            // mouse-move; see `StudioViewModel.playheadDraft`.
            model.playheadDraft = model.clampedPlayhead(rawTick)

        case .clipMove:
            guard let original = state.originalClip else { break }
            var clip = original
            let snapped = StudioTimelineMath.snap(
                rawTick - state.grabOffsetTicks, mode: model.snapMode,
                grid: model.barGrid, pxPerTick: model.pxPerTick)
            clip.startTicks = StudioTimelineMath.clampedMoveStart(
                proposedStartTicks: snapped, lengthTicks: clip.lengthTicks,
                projectLengthTicks: model.projectLengthTicks)
            state.provisionalClip = clip
            // Vertical: retarget track under the cursor.
            let laneY = point.y - rulerHeight + model.scrollY
            if let row = StudioRowLayoutBuilder.row(at: laneY, rows: rows()),
               case .track(let trackID) = row.kind {
                state.targetTrackID = trackID
            }
            model.updateDragOverride(clip)

        case .clipTrimLeading, .clipTrimTrailing:
            guard let original = state.originalClip else { break }
            let snapped = StudioTimelineMath.snap(
                rawTick, mode: model.snapMode, grid: model.barGrid, pxPerTick: model.pxPerTick)
            let edge: StudioTimelineMath.TrimEdge =
                state.kind == .clipTrimLeading ? .leading : .trailing
            let trimmed = StudioTimelineMath.trimmed(
                start: original.startTicks, length: original.lengthTicks,
                edge: edge, toTicks: snapped, minLengthTicks: StudioTick.ppq / 4)
            var clip = original
            let delta = trimmed.start - original.startTicks
            clip.sourceOffsetTicks = max(0, original.sourceOffsetTicks + delta)
            clip.startTicks = trimmed.start
            clip.lengthTicks = trimmed.length
            state.provisionalClip = clip
            model.updateDragOverride(clip)

        case .fadeIn, .fadeOut:
            guard let original = state.originalClip else { break }
            var clip = original
            if state.kind == .fadeIn {
                clip.fadeInTicks = min(max(0, rawTick - original.startTicks), original.lengthTicks)
            } else {
                clip.fadeOutTicks = min(max(0, original.endTicks - rawTick), original.lengthTicks)
            }
            state.provisionalClip = clip
            model.updateDragOverride(clip)

        case .rubberBand:
            let rect = StudioSelectionOps.bandRect(from: state.startPoint, to: point)
            model.selection = StudioSelectionOps.rubberBand(
                model.selection, rect: rect,
                clipFrames: visibleClipFrames(viewport: viewport), shift: state.shift)

        case .automationPoint:
            guard let target = state.autoTarget, var prov = state.autoProvisional,
                  let geo = automationLaneGeometry(state.autoTrackID, target) else { break }
            prov.positionTicks = StudioTimelineMath.snap(
                max(0, rawTick), mode: model.snapMode, grid: model.barGrid, pxPerTick: model.pxPerTick)
            prov.value = StudioAutomationMath.yToValue(
                point.y, target: target, rowY: geo.rowY, height: geo.height)
            state.autoProvisional = prov
            model.updateAutoDragProvisional(prov)

        case .none:
            break
        }
        model.drag = state
    }

    private func click(at point: CGPoint, viewport: CGSize) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if let hit = hitClip(at: point, viewport: viewport) {
            model.selection = StudioSelectionOps.clicked(model.selection, clipID: hit.clip.id, shift: shift)
            model.reviseArmed = false
        } else if !shift {
            model.clearSelection()
        }
    }

    /// Context-click follows the platform rule: right-clicking a clip that is
    /// not in the selection makes it THE selection (same op as a plain click);
    /// right-clicking an already-selected clip keeps the multi-selection so
    /// the menu acts on all of it. Empty space changes nothing — the menu
    /// still offers whatever is selected.
    @ViewBuilder
    private func clipContextMenuContent() -> some View {
        let count = model.selection.clipIDs.count
        if count == 1, let clipID = model.selection.clipIDs.first {
            Button("Rename Clip") {
                editingClipID = clipID
                renameClipText = ""
                showRenameAlert = true
            }
            .studioHelp(terse: "Rename Clip",
                        teaching: "Change the name of this clip to describe what it contains.")
            Menu("Clip Gain") {
                Button("-12 dB") { model.setClipGain(clipID, gainDB: -12) }
                Button("-6 dB") { model.setClipGain(clipID, gainDB: -6) }
                Button("-3 dB") { model.setClipGain(clipID, gainDB: -3) }
                Button("0 dB") { model.setClipGain(clipID, gainDB: 0) }
                Button("+3 dB") { model.setClipGain(clipID, gainDB: 3) }
                Button("+6 dB") { model.setClipGain(clipID, gainDB: 6) }
            }
            .studioHelp(terse: "Clip gain",
                        teaching: "Adjust the playback level of this clip without changing its track fader.")
            let isMuted = model.snapshot?.tracks.contains(where: { t in
                t.clips.contains(where: { $0.id == clipID && $0.muted })
            }) ?? false
            Button(isMuted ? "Unmute" : "Mute") {
                model.setClipMute(clipID, muted: !isMuted)
            }
            .studioHelp(terse: isMuted ? "Unmute clip" : "Mute clip",
                        teaching: "Silence or restore playback of this clip without changing its track mute.")
            Divider()
        }
        Button(count == 1 ? "Delete Clip" : "Delete \(count) Clips",
               role: .destructive) {
            model.deleteSelection()
        }
    }

    @ViewBuilder
    private func rulerContextMenuContent() -> some View {
        if let snapshot = model.snapshot {
            let bar = contextBar
            Button("Add Section Here") {
                model.setSection(name: "SECTION", startBar: bar)
            }
            .studioHelp(terse: "Add section",
                        teaching: "Mark a section of the arrangement starting at this bar for navigation, colouring and editing.")
            if let section = snapshot.sections.first(where: {
                bar >= $0.startBar && bar < $0.startBar + $0.lengthBars
            }) {
                Button("Remove Section") {
                    model.removeSection(sectionID: section.id)
                }
                .studioHelp(terse: "Remove section",
                            teaching: "Remove this section marker. The arrangement itself stays unchanged.")
            }
            Divider()
            Button("Add Marker Here") {
                model.setMarker(name: "M\(snapshot.markers.count + 1)", bar: bar)
            }
            .studioHelp(terse: "Add marker",
                        teaching: "Place a reference marker at this bar for navigation.")
            if let marker = snapshot.markers.first(where: { $0.bar == bar }) {
                Button("Remove Marker") {
                    model.removeMarker(markerID: marker.id)
                }
                .studioHelp(terse: "Remove marker",
                            teaching: "Remove this reference marker.")
            }
            Divider()
            // The loop, reachable a second way. The strip is the gesture; this
            // is for the person who has not found it yet, and it is where
            // "loop this whole section" is one click instead of an accurate
            // drag.
            if let section = snapshot.sections.first(where: {
                bar >= $0.startBar && bar < $0.startBar + $0.lengthBars
            }) {
                let grid = snapshot.barGrid
                Button("Loop \(section.name)") {
                    model.setLoop(
                        startTicks: grid.tickForBarIndex(Int64(section.startBar)),
                        endTicks: grid.tickForBarIndex(Int64(section.startBar + section.lengthBars)))
                }
                .studioHelp(
                    terse: "Loop this section",
                    teaching: "Repeat this section over and over while the song plays, so you can play along to it. When the play head reaches the end of the section it jumps straight back to the start, with no gap and no drift.")
            }
            if model.loopRegion != nil {
                Button("Clear Loop") {
                    model.clearLoop()
                }
                .studioHelp(
                    terse: "Stop repeating",
                    teaching: "Turn the loop off. The song plays straight through again from wherever the play head is. Nothing you recorded or edited changes.")
            }
        }
    }

    private func rightClickSelect(at point: CGPoint, viewport: CGSize) {
        contextClickPoint = point
        guard let snapshot = model.snapshot else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let scroll = model.effectiveScrollTicks(now: now, viewportWidth: viewport.width)
        let tick = StudioTimelineMath.pxToTicks(
            point.x, pxPerTick: model.pxPerTick, scrollTicks: scroll)
        contextBar = snapshot.barGrid.barNumber(at: tick) - 1
        contextTick = tick
        guard point.y >= rulerHeight else { return }
        guard let hit = hitClip(at: point, viewport: viewport) else { return }
        guard !model.selection.clipIDs.contains(hit.clip.id) else { return }
        model.selection = StudioSelectionOps.clicked(model.selection, clipID: hit.clip.id, shift: false)
        model.reviseArmed = false
    }

    // MARK: Keys (plain keys; Cmd shortcuts live on toolbar buttons)

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            if model.drag.kind != .none {
                model.cancelDrag()
            } else {
                model.clearSelection()
            }
            return .handled
        case .delete, .deleteForward:
            guard !model.selection.clipIDs.isEmpty else { return .ignored }
            model.deleteSelection()
            return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "r":
            guard model.selection.region != nil else { return .ignored }
            model.armReviseForSelection()
            return .handled
        case "z":
            model.zoomToFitViewport()
            return .handled
        default:
            return .ignored
        }
    }
}

// MARK: - Scroll + pinch catcher
//
// SwiftUI exposes no scroll-wheel events; a local NSEvent monitor turns
// two-finger scroll into pan and Cmd+scroll into zoom, only when the event
// lands inside this view's bounds in the key window.

enum StudioScrollEvent {
    case pan(dx: CGFloat, dy: CGFloat)
    case zoom(factor: CGFloat, atX: CGFloat)
}

struct StudioScrollCatcher: NSViewRepresentable {
    var onEvent: @MainActor (StudioScrollEvent) -> Void
    /// Called on a context-click (right-click, or ctrl+click) at the given
    /// point in this view's TOP-LEFT coordinates, BEFORE the click reaches
    /// SwiftUI — so a `.contextMenu` on the same view opens against whatever
    /// selection this callback establishes. The event is never consumed.
    var onContextClick: (@MainActor (CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onEvent = onEvent
        view.onContextClick = onContextClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onEvent = onEvent
        view.onContextClick = onContextClick
    }

    @MainActor
    final class CatcherView: NSView {
        var onEvent: (@MainActor (StudioScrollEvent) -> Void)?
        var onContextClick: (@MainActor (CGPoint) -> Void)?
        private var monitor: Any?

        /// Top-left origin so the reported point lives in the same space as
        /// SwiftUI's gestures and the canvas hit-testing. Scroll handling only
        /// reads x and deltas, so it is unaffected.
        override var isFlipped: Bool { true }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            // Local monitors always run on the main thread; install while in
            // a window, tear down when leaving it (covers dismantle too).
            if newWindow == nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.scrollWheel, .rightMouseDown, .leftMouseDown]
                ) { [weak self] event in
                    // Local monitors run synchronously on the main thread;
                    // only the Bool crosses the isolation boundary.
                    let consumed = MainActor.assumeIsolated { () -> Bool in
                        guard let self else { return false }
                        return self.handle(event) ?? false
                    }
                    return consumed ? nil : event
                }
            }
        }

        /// nil = not ours; true = consumed.
        private func handle(_ event: NSEvent) -> Bool? {
            guard let window, event.window === window,
                  !isHiddenOrHasHiddenAncestor else { return nil }
            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local) else { return nil }

            // Context-click (right, or ctrl+left): report the point so the
            // selection can move under the pointer, and PASS THE EVENT ON —
            // consuming it would suppress the SwiftUI context menu it exists
            // to serve.
            if event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
                onContextClick?(local)
                return nil
            }
            guard event.type == .scrollWheel else { return nil }

            if event.modifierFlags.contains(.command) {
                let factor = pow(1.0035, -event.scrollingDeltaY)
                onEvent?(.zoom(factor: factor, atX: local.x))
                return true
            }
            var dx = event.scrollingDeltaX
            var dy = event.scrollingDeltaY
            if event.modifierFlags.contains(.shift), dx == 0 {
                dx = dy
                dy = 0
            }
            onEvent?(.pan(dx: dx, dy: dy))
            return true
        }
    }
}
