import SwiftUI

// MARK: - Command palette (Cmd+K)
//
// Fuzzy palette over the command catalog (CatalogNames.generated from
// command-catalog.v2.json) plus this build's view commands.
//
// WHAT CHANGED, AND WHY IT IS NOT "UNHIDE THE REST".
//
// This palette listed ELEVEN of 119 commands. Before that it listed 71 and
// wired 11, so selecting most of them did nothing; hiding the unwired ones was
// the right fix for that, and it left ⌘K as decoration. The rows now come from
// `StudioPaletteCommands.all` — a table where every row names the catalog verb
// it sends and states, as a sentence, what it needs before it can send it.
//
// The rule this file is built on: **a listed row either sends its command or is
// shown disabled with the reason.** There is no third state. A row that a
// person can highlight and press Return on to no effect is the same defect the
// 71/11 palette had, and it is the one this codebase produces most often.
//
// Disabled rows are SHOWN rather than hidden, which is the one substantive
// change of policy here. Hiding taught nothing: "quantize is not in this app"
// and "quantize needs some notes selected first" look identical when the row is
// absent. Greyed, with the remedy printed next to it, they do not.

struct StudioPaletteEntry: Identifiable {
    enum Kind {
        /// A catalog command, with everything needed to decide and to send it.
        case catalogWired(StudioPaletteCommand)
        /// This build's own view state. Not a catalog verb and never claimed
        /// to be one — the ids are all `studio.*`, which the catalog has no
        /// entry for, so the two lists cannot be confused.
        case view(@MainActor (StudioViewModel) -> Void)
    }

    let id: String        // command name, e.g. "clip.split"
    /// What it does, in words. This is what the list is really searched on;
    /// nobody types "autolane.clear" to throw a volume curve away.
    let title: String
    /// The row's NAME, for a surface that has room for a name and not a
    /// sentence — the menu bar.
    ///
    /// ⚠️ THIS IS THE `terse` / `teaching` PAIR THE HELP LAYER ALREADY USES,
    /// under its own two words, and it is deliberately the same idea rather
    /// than a new one: `StudioHelpEntry` has held `terse` (the control's NAME)
    /// beside `teaching` (what it DOES) since the help lane, and
    /// `.studioHelp(terse:teaching:)` is how every other control in the Studio
    /// carries both. `title` is this row's teaching; `terse` is its name.
    ///
    /// Why a second field rather than shortening `title`: ⌘K searches `title`,
    /// and it searches it precisely because the person this product is for
    /// types "split" and "left panel", not "studio.toggleBrowser". Cutting
    /// "Show or hide the left panel" down to "Left Panel" would have taken the
    /// words "show", "hide" and "panel" out of the only surface that is
    /// searched at all. The menu bar is not searched and has no room, so it
    /// wants the other register.
    ///
    /// Defaults to `title`, so a row that has never needed a short name is not
    /// forced to invent one — that default is what keeps this from becoming a
    /// second list of prose for all 56 catalog rows.
    let terse: String
    let subtitle: String
    let keys: String?
    let kind: Kind
    /// Why a VIEW row cannot run right now, or nil. Catalog rows defer to their
    /// own table; this exists because a view row can be inert too —
    /// `armReviseForSelection` returns immediately when no bars are selected,
    /// and a row that silently does nothing is the defect this palette keeps
    /// shipping. Nil means "nothing can stop it", which is true of a toggle.
    let viewBlock: (@MainActor (StudioPaletteContext) -> String?)?

    init(id: String, title: String, terse: String? = nil, subtitle: String, keys: String?,
         kind: Kind, viewBlock: (@MainActor (StudioPaletteContext) -> String?)? = nil) {
        self.id = id
        self.title = title
        self.terse = terse ?? title
        self.subtitle = subtitle
        self.keys = keys
        self.kind = kind
        self.viewBlock = viewBlock
    }

    var isWired: Bool { true }

    var command: StudioPaletteCommand? {
        if case .catalogWired(let command) = kind { return command }
        return nil
    }
}

enum StudioPaletteCatalog {

    /// All catalog command names, driven from command-catalog.v2.json so the
    /// palette cannot drift again.
    static let catalogNames: [String] = CatalogNames.names

    @MainActor
    static func entries() -> [StudioPaletteEntry] {
        // Catalog rows, in the catalog's own order, so the list reads as the
        // product does: project, transport, tracks, clips, mix, notes, effects.
        let byName = Dictionary(
            uniqueKeysWithValues: StudioPaletteCommands.all.map { ($0.name, $0) })
        var out: [StudioPaletteEntry] = catalogNames.compactMap { name in
            guard let command = byName[name] else { return nil }
            return StudioPaletteEntry(
                id: name, title: command.title, subtitle: "command catalog v2",
                keys: command.keys, kind: .catalogWired(command))
        }

        // ⚠️ EVERY ROW BELOW CARRIES BOTH REGISTERS, and the seven that land in
        // the View menu are why the `terse` field exists at all.
        //
        // The View menu shipped in 3.6.0 reading
        //
        //     Fit the whole song on screen — Open the Studio tab first — …
        //     Show or hide the left panel — Open the Studio tab first — …
        //     …seven times…
        //
        // 836 pt of grey text typeset in the menu font, most of it one 14-word
        // sentence repeated seven times, sitting directly under
        // `Zoom In · Zoom Out · Actual Size`.
        // Two separate defects wearing one shape: the reason was in the TITLE
        // (fixed in StudioMenuCommands.swift — it is said once per menu now),
        // and the titles were DESCRIPTIONS rather than names. A menu item's
        // title is its NAME. "Show or hide the left panel" is a sentence you
        // would type into ⌘K; "Left Panel" is what goes on a menu.
        //
        // So the sentence stays exactly where it was — `title`, which is what
        // ⌘K lists and searches — and `terse` is added beside it in the idiom
        // of the three items above these in the menu: Title Case, two or three
        // words, noun-led.
        out.append(StudioPaletteEntry(
            id: "studio.zoomToFit", title: "Fit the whole song on screen",
            terse: "Fit Song to Window",
            subtitle: "this build", keys: "Z",
            kind: .view { $0.zoomToFitViewport() }))
        // "Left Panel" / "Right Panel" rather than "Browser" / "Inspector":
        // the sentence these rows have always used is "the left panel", and
        // the person this product is for reads a menu, not a DAW glossary.
        out.append(StudioPaletteEntry(
            id: "studio.toggleBrowser", title: "Show or hide the left panel",
            terse: "Left Panel",
            subtitle: "this build", keys: nil,
            kind: .view { $0.browserCollapsed.toggle() }))
        out.append(StudioPaletteEntry(
            id: "studio.toggleInspector", title: "Show or hide the right panel",
            terse: "Right Panel",
            subtitle: "this build", keys: nil,
            kind: .view { $0.inspectorCollapsed.toggle() }))
        out.append(StudioPaletteEntry(
            id: "studio.toggleMixer", title: "Show or hide the mixer",
            terse: "Mixer",
            subtitle: "this build", keys: nil,
            kind: .view { $0.mixerCollapsed.toggle() }))
        out.append(StudioPaletteEntry(
            id: "studio.toggleRouting", title: "Show or hide the effects panel",
            terse: "Effects Panel",
            subtitle: "this build", keys: nil,
            kind: .view { $0.routingShown.toggle() }))
        out.append(StudioPaletteEntry(
            id: "studio.toggleFrameHUD", title: "Show or hide the frame-rate readout",
            terse: "Frame Rate",
            subtitle: "this build", keys: nil,
            kind: .view { $0.frameStats.hudVisible.toggle() }))
        // No ellipsis: it measures and reports, it asks nothing. The four
        // above are toggles and carry no ellipsis for the same reason.
        out.append(StudioPaletteEntry(
            id: "studio.runPerfSweep", title: "Measure how smoothly the timeline draws",
            terse: "Measure Drawing Speed",
            subtitle: "this build", keys: nil,
            kind: .view { $0.runPerfSweep(viewportWidth: $0.timelineViewportWidth) },
            viewBlock: { $0.model.sweepActive ? "A measurement is already running." : nil }))
        // The two panels that own a whole command family the palette cannot
        // type: a generation request, and an output path. Opening them is the
        // honest reach — they are `studio.*` view rows, not a claim to have
        // sent `gen.revise` or `export.master`.
        //
        // ⚠️ THE ELLIPSIS ON THESE THREE IS THE ONE ON `.askInPalette`, not
        // decoration. This file's menu half already treats a trailing ellipsis
        // as the macOS promise that clicking will ASK rather than act, and
        // these three open a panel, a sheet and an `NSOpenPanel` respectively.
        // The four toggles and the two measurements above carry none, because
        // they act on the spot.
        out.append(StudioPaletteEntry(
            id: "studio.revise", title: "Revise the selected bars with AI",
            terse: "Revise Selected Bars…",
            subtitle: "this build", keys: "R",
            kind: .view { $0.armReviseForSelection() },
            viewBlock: { ctx in
                // `armReviseForSelection` returns immediately without a region.
                // Blocked rather than silently inert.
                ctx.model.selection.region == nil
                    ? "Drag across the bar numbers at the top to choose the bars first."
                    : nil
            }))
        out.append(StudioPaletteEntry(
            id: "studio.export", title: "Export the finished song to a file",
            terse: "Export Song…",
            subtitle: "this build", keys: nil,
            kind: .view { $0.exportSheetShown = true }))
        // SPLITTING A SONG INTO ITS PARTS, from ⌘K and (via `viewRowMenu`) from
        // the Track menu. It is a `studio.*` view row and not a catalog command
        // on purpose: the catalog HAS a `gen.separate`, and that command's own
        // description says it "RECORDS the request on the bus and returns; it
        // does not itself call a backend" — a row pointed at it would list a
        // verb, send it, get `ok: true`, and produce nothing. Same for
        // `import.audio`'s `separate` flag, which the host names in its own
        // result as declared-and-not-implemented. The honest reach is the panel
        // idiom this file already uses for Revise and Export.
        //
        // The title is what a person would TYPE. "Separate" is the DAW word and
        // "stems" is the word on the tab, so both are in the sentence — ⌘K
        // searches the title, and the person this is for looks for "split".
        //
        // That sentence is 78 characters, and until `terse` existed it was
        // ALSO what the Track menu printed — the same defect as the View menu's
        // seven, one item wide instead of seven deep.
        out.append(StudioPaletteEntry(
            id: StudioMenuPlan.separateViewRowID,
            title: "Split a song into stems — separate vocals, drums and bass onto their own tracks",
            terse: "Split Song into Stems…",
            subtitle: "this build", keys: nil,
            kind: .view { $0.chooseSongAndSeparate() },
            viewBlock: { ctx in
                // Every way this row can be inert, said out loud. A row a
                // person can highlight and press Return on to no effect is the
                // defect this palette exists to prevent.
                if ctx.model.separating { return StemSeparationRun.alreadyRunningRefusal }
                if ctx.model.stemSeparator == nil { return StudioViewModel.noSeparatorReason }
                if ctx.model.songChooser == nil { return StudioViewModel.noChooserReason }
                if ctx.model.snapshot == nil { return StudioViewModel.noProjectReason }
                return nil
            }))
        return out
    }

    /// Case-insensitive subsequence match, ranked: prefix < substring < scatter.
    ///
    /// The TITLE is searched too, one rank below the name at each tier, because
    /// the person this product is for does not know the word "autolane". The
    /// name still wins every tie, so a typed prefix of a command name lands on
    /// that command.
    static func matches(_ query: String, in entries: [StudioPaletteEntry]) -> [StudioPaletteEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        func score(_ name: String) -> Int? {
            let n = name.lowercased()
            if n.hasPrefix(q) { return 0 }
            if n.contains(q) { return 2 }
            var it = q.startIndex
            for ch in n {
                if it < q.endIndex, ch == q[it] { it = q.index(after: it) }
            }
            return it == q.endIndex ? 4 : nil
        }
        let scored: [(StudioPaletteEntry, Int)] = entries.compactMap { entry in
            let byName = score(entry.id)
            // +1 puts a title hit just behind a name hit of the same kind.
            let byTitle = score(entry.title).map { $0 + 1 }
            guard let s = [byName, byTitle].compactMap({ $0 }).min() else { return nil }
            return (entry, s)
        }
        return scored
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 < rhs.1
            }
            .map(\.0)
    }
}

// MARK: - Palette view

struct StudioCommandPalette: View {
    @ObservedObject var model: StudioViewModel
    /// The two controllers the note and effect rows need. Optional because the
    /// palette is also built in previews and tests without them; every row that
    /// needs one says so in its disabled reason rather than vanishing.
    var pianoRoll: StudioPianoRollController?
    var routing: StudioRoutingController?

    @State private var query = ""
    @State private var highlighted = 0
    @State private var stage: StudioPaletteStage = .browsing
    /// What the second field is asking for, and what is typed into it.
    @State private var prompt: String = ""
    @State private var argumentText: String = ""
    @State private var complaint: String?
    @FocusState private var fieldFocused: Bool
    @FocusState private var argumentFocused: Bool

    private var context: StudioPaletteContext {
        StudioPaletteContext(model: model, pianoRoll: pianoRoll, routing: routing)
    }

    private var filtered: [StudioPaletteEntry] {
        StudioPaletteCatalog.matches(query, in: StudioPaletteCatalog.entries())
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Rectangle().fill(StudioTokens.stroke).frame(height: 1)
            if stage == .browsing {
                if let complaint {
                    Text(complaint)
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTokens.warn)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                resultsList
            } else {
                stagePanel
            }
        }
        .frame(width: 520)
        .background(StudioTokens.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioTokens.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .onAppear {
            fieldFocused = true
            consumeMenuSeed()
        }
        .onChange(of: query) { _, _ in highlighted = 0; complaint = nil }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(0, filtered.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
        .onKeyPress(.escape) {
            // Escape backs OUT of a question before it closes the palette. A
            // single Escape that threw away both the answer and the palette
            // would make the confirm step feel like a trap.
            if stage == .browsing {
                model.paletteShown = false
            } else {
                cancelStage()
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private var searchField: some View {
        TextField("Type a command", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(StudioTokens.text)
            .padding(12)
            .focused($fieldFocused)
            .disabled(stage != .browsing)
            .onSubmit { runHighlighted() }
            .studioHelp("palette.search")
            .accessibilityLabel("Command search")
    }

    // MARK: The question a row asks before it runs

    @ViewBuilder
    private var stagePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTokens.text)
                .fixedSize(horizontal: false, vertical: true)
            if case .argument = stage {
                TextField("", text: $argumentText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold).monospaced())
                    .foregroundStyle(StudioTokens.text)
                    .padding(8)
                    .background(StudioTokens.panelHi)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .focused($argumentFocused)
                    .onSubmit { runHighlighted() }
                    .studioHelp("palette.argument")
                    .accessibilityLabel("Value")
            }
            if let complaint {
                Text(complaint)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTokens.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Return to go ahead · Escape to change your mind")
                .font(.system(size: 10))
                .foregroundStyle(StudioTokens.faint)
                .lineLimit(1)
                .fixedSize()
                .studioHelp("palette.confirm")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { argumentFocused = true }
    }

    private var resultsList: some View {
        let results = filtered
        let ctx = context
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<results.count, id: \.self) { index in
                        let entry = results[index]
                        StudioPaletteRow(
                            entry: entry,
                            availability: availability(of: entry, in: ctx),
                            highlighted: index == highlighted)
                            .id(entry.id)
                            .onTapGesture { run(entry) }
                    }
                }
            }
            .frame(maxHeight: 320)
            .onChange(of: highlighted) { _, index in
                guard results.indices.contains(index) else { return }
                proxy.scrollTo(results[index].id)
            }
        }
    }

    /// A view row is always ready — it toggles this build's own state and has
    /// no engine precondition. A catalog row asks its table.
    private func availability(
        of entry: StudioPaletteEntry, in ctx: StudioPaletteContext
    ) -> StudioPaletteAvailability {
        if let command = entry.command { return command.availability(in: ctx) }
        if let why = entry.viewBlock?(ctx) { return .blocked(why) }
        return .ready
    }

    /// A menu item with an ellipsis sent us here. Open on that row's question.
    ///
    /// The question comes from `StudioPaletteFlow.seeded`, which is the SAME
    /// `step` the Return key drives — the menu and the palette must ask the
    /// identical question or the two surfaces have drifted where a user can
    /// see it. The query is set to the command's name as well, so pressing
    /// Escape backs out onto a list already narrowed to the row the menu meant.
    ///
    /// The seed is cleared whatever happens, including when it names something
    /// that cannot run: a seed left behind would re-ask its question the next
    /// time the user opened ⌘K by hand.
    private func consumeMenuSeed() {
        guard let seed = model.paletteSeed else { return }
        model.paletteSeed = nil
        query = seed
        highlighted = 0
        guard let seeded = StudioPaletteFlow.seeded(seed, in: context) else { return }
        stage = seeded.stage
        prompt = seeded.prompt
        argumentText = seeded.typed
        complaint = nil
    }

    private func runHighlighted() {
        let results = filtered
        guard results.indices.contains(highlighted) else { return }
        run(results[highlighted])
    }

    private func cancelStage() {
        stage = .browsing
        prompt = ""
        argumentText = ""
        complaint = nil
        fieldFocused = true
    }

    private func run(_ entry: StudioPaletteEntry) {
        guard let command = entry.command else {
            // A view row that cannot run says so, in the same place a catalog
            // row does, rather than closing the palette and doing nothing.
            if let why = entry.viewBlock?(context) {
                complaint = why
                return
            }
            model.paletteShown = false
            if case .view(let action) = entry.kind { action(model) }
            return
        }

        switch StudioPaletteFlow.step(
            for: command, stage: stage, typed: argumentText, in: context
        ) {
        case .blocked(let why):
            complaint = why
            stage = .browsing

        case .askForArgument(let label, let initial):
            prompt = "\(command.title). \(label)?"
            argumentText = initial
            complaint = nil
            stage = .argument(name: command.name)

        case .askForConfirmation(let text):
            prompt = text
            complaint = nil
            stage = .confirming(name: command.name)

        case .rejected(let why):
            complaint = why

        case .commit(let value):
            model.paletteShown = false
            command.perform(context, value)
            cancelStage()
            query = ""
        }
    }
}

/// The remedy sentence on a blocked row.
///
/// Its own view, and internal, for one reason: it is the ONLY thing in a palette
/// row that can wrap, and the row it sits in is pinned to `rowHeight`. A pinned
/// frame makes a height assertion on the ROW tautological — it reports 28 pt
/// whether the sentence fitted or was clipped to ribbons — which is exactly what
/// happened here: deleting this label's `lineLimit(1)` passed both the
/// whole-palette pixel test AND the per-row one. Measuring the part that can
/// break is the only assertion that moves when it breaks.
///
/// `lineLimit(1)` + a bounded frame rather than `fixedSize()`: this one is a
/// whole sentence and MUST be allowed to truncate, but it must never wrap. An
/// unconstrained Text in a tight HStack wraps to one character per line, which
/// is what took the transport row to 475 pt.
struct StudioPaletteReasonLabel: View {
    let reason: String

    /// How much room the sentence gets before it truncates.
    static let maxWidth: CGFloat = 240
    /// One line of 10 pt type, measured. An equality in the test, so a wrap of
    /// any depth fails rather than only a catastrophic one.
    static let singleLineHeight: CGFloat = 13

    var body: some View {
        Text(reason)
            .font(.system(size: 10))
            .foregroundStyle(StudioTokens.dim)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.maxWidth, alignment: .trailing)
    }
}

/// Internal rather than private so a test can rasterize ONE row.
///
/// It was private, and the pixel test was written against the whole palette
/// instead — which is capped at `frame(maxHeight: 320)`, so a row that wrapped
/// could not move the number being asserted.
struct StudioPaletteRow: View {
    let entry: StudioPaletteEntry
    let availability: StudioPaletteAvailability
    let highlighted: Bool

    /// Every row is exactly this tall, stated rather than emergent.
    ///
    /// Not a maximum: an EQUALITY. Measured, a ready row came out 29 pt (the
    /// shortcut badge carries its own 2 pt of padding) and a blocked one 27 pt,
    /// so the list shifted by two points every time the highlight moved between
    /// them. On a 4K TV at sofa distance a list that jitters as you arrow
    /// through it is the difference between reading it and chasing it.
    static let rowHeight: CGFloat = 28

    // Every Text in this row is `lineLimit(1)` + `fixedSize()`. An
    // unconstrained Text in a tight HStack wraps to one character per line —
    // that is what blew the transport row to 475 pt — and the reason string
    // here is a whole sentence, so it is the likeliest one to do it.
    var body: some View {
        HStack(spacing: 8) {
            Text(entry.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(availability.isReady ? StudioTokens.text : StudioTokens.dim)
                .lineLimit(1)
                .fixedSize()
            Text(entry.id)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(StudioTokens.faint)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            if let reason = availability.reason {
                StudioPaletteReasonLabel(reason: reason)
            } else if let keys = entry.keys {
                Text(keys)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(StudioTokens.dim)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(StudioTokens.panelHi)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background(highlighted ? StudioTokens.panelHi : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(availability.reason ?? "available")
    }
}
