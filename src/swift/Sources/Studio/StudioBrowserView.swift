import SwiftUI
import AppKit

// MARK: - Browser (left rail)
//
// Songs / Sounds / Takes / Stems. Songs reuses LibraryStore data; the open
// project is pinned on top. Every section that says a row can be dragged has a
// real `.onDrag` behind it — `StudioBrowserPanesTests` compares each section's
// TOOLTIP against the gestures its code actually implements, for the reason
// below.
//
// THERE WAS A FIFTH SECTION, "Files", AND IT LIED TWICE.
//
// Its tooltip read "Audio files on your disk that you can drag straight onto a
// track." The rows were a plain `HStack` with no `.onDrag` and no gesture of any
// kind, so nothing could be dragged; and what they listed was the NAMES OF CLIPS
// already imported into this project, not files on any disk. It also filtered on
// `track.kind == .imported`, and `StudioTrackSnapshot.role`'s own comment says
// why that is not a thing to gate an affordance on: `kind` is a guess the Swift
// side makes from the track's NAME, so renaming an imported track to "Bass"
// emptied the pane.
//
// It was deleted rather than repaired, because everything it claimed is now
// done properly by a sibling, and done better:
//
//   * Sounds (`StudioSoundsBrowser`) is a real library of files on disk with a
//     real drag-to-place that lands as ONE command at the spot you drop it.
//   * Songs > Library rows import on double-click, drag onto the timeline as a
//     file URL, and offer the full landing on right-click.
//   * Takes drags too.
//
// The one control in it that worked — "Import audio…" — is a duplicate of the
// toolbar's always-visible Import button (`toolbar.import` ->
// `StudioRootView.chooseAudioFile`), so nothing a person could do is gone.

struct StudioBrowserView: View {
    @ObservedObject var model: StudioViewModel
    @EnvironmentObject var library: LibraryStore

    /// The rail's width, owned by the shell (StudioRootView) because the user
    /// drags it there. Defaulted to the shipped token so every other call site
    /// — and any preview — is unchanged.
    var width: CGFloat = StudioTokens.browserWidth

    enum Section: String, CaseIterable {
        case songs = "Songs"
        case sounds = "Sounds"
        case takes = "Takes"
        case stems = "Stems"

        /// Spelled out rather than interpolated from `rawValue`, so the
        /// coverage test can see the literal ids at the call site.
        var helpID: String {
            switch self {
            case .songs: return "browser.songs"
            case .sounds: return "browser.sounds"
            case .takes: return "browser.takes"
            case .stems: return "browser.stems"
            }
        }

        /// Sounds owns its own scroll view (a LazyVStack of up to fourteen
        /// thousand rows cannot borrow the shared one and still be lazy), so
        /// the shell asks each section whether to wrap it.
        var scrollsItself: Bool { self == .sounds }
    }

    /// Which section opens first.
    ///
    /// Defaulted, so every existing call site is unchanged. A test uses it to
    /// render one specific section deterministically — which is the only way,
    /// short of launching a window, to prove that picking Sounds actually
    /// reaches the sounds browser rather than an empty branch.
    var initialSection: Section = .songs

    /// Test seam: a prepared vault, handed straight through to the sounds
    /// section so a fixture can be rendered without a disk anywhere.
    ///
    /// This exists because a mutation SURVIVED without it. Every part of the
    /// sounds browser was proven and `private var sounds` — the ONE line that
    /// feeds it — was not: replacing `StudioSoundsBrowser(model:)` with an
    /// `EmptyView()` left all 26 tests green, which is a Sounds tab that opens
    /// onto nothing and a suite that says it works. Rendering the real shell
    /// through the real switch needs the real shell to have something to show.
    var injectedVault: StudioSoundsVaultModel?

    @State private var pickedSection: Section?
    private var section: Section { pickedSection ?? initialSection }
    /// Live filter for the Songs > Library list (case-insensitive, as-you-type).
    @State private var songSearch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Browser")
            ForEach(Section.allCases, id: \.self) { item in
                Button {
                    pickedSection = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(section == item ? StudioTokens.text : StudioTokens.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(section == item ? StudioTokens.panelHi : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .studioHelp(item.helpID)
                .accessibilityLabel("\(item.rawValue) browser section")
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }

            // Sounds is rendered OUTSIDE the shared scroll view, deliberately.
            // The three original sections are short lists that fit the rail;
            // Sounds is up to fourteen thousand rows and its laziness has to be
            // structural, which means owning the scroll view it scrolls in. A
            // LazyVStack nested inside the plain VStack below would be at the
            // mercy of how that stack proposes size, and "probably still lazy"
            // is not a thing to bet a 14,000-row list on.
            if section.scrollsItself {
                sounds
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        switch section {
                        case .songs: songs
                        case .sounds: EmptyView()   // handled above
                        case .takes: takes
                        case .stems: stems
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        // FIXED across the drag axis, flexible down it. Being explicit on both
        // axes is the lesson of the transport bar: a child that stays flexible
        // where you did not mean it to be takes space from its siblings
        // silently (see StudioTransportBar.readout(value:caption:)).
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(StudioTokens.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(StudioTokens.strokeSoft).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser")
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .kerning(1)
            .foregroundStyle(StudioTokens.faint)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private var songs: some View {
        header("This project")
        if let snapshot = model.snapshot {
            songRow(title: snapshot.name, generative: true, selected: true)
        }
        header("Library")
        if library.tracks.isEmpty {
            emptyNote("No library songs yet. Generate one in Create.")
        } else {
            librarySearchField
            let matches = StudioLibrarySearch.filter(library.tracks, query: songSearch)
            if matches.isEmpty {
                emptyNote("No songs match “\(songSearch)”.")
            } else {
                // Cap the rendered rows (this list isn't lazy); filtering narrows
                // the set well below the cap, so a specific song stays reachable.
                ForEach(matches.prefix(60)) { track in
                    // Interactive: double-click or drag loads the song onto the
                    // timeline (parity with Import audio… and the timeline file-drop).
                    StudioLibrarySongRow(model: model, track: track)
                }
            }
        }
    }

    /// Compact search box at the top of the Songs > Library list, styled to the
    /// Studio browser (StudioTokens) and mirroring the Library tab's "Search
    /// tracks…" affordance, so a specific song is findable in a list of 100s.
    /// Live + case-insensitive; the ✕ clears it.
    private var librarySearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StudioTokens.faint)
            TextField("Search songs…", text: $songSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTokens.text)
            if !songSearch.isEmpty {
                Button {
                    songSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTokens.faint)
                }
                .buttonStyle(.plain)
                // help-exempt: an ✕ inside a search box it only appears in is
                // self-evident, and the box itself carries the tooltip.
                .accessibilityLabel("Clear song search")
            }
        }
        .studioHelp("browser.search")
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(StudioTokens.panelHi)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search songs")
    }

    /// The sounds vault: search, audition, filter, drag onto a track.
    ///
    /// The 13,971-asset catalogue was unreachable from this app until this
    /// section existed — the only route to a sample was a file picker, which is
    /// no route at all against a library that size. See StudioSoundsBrowser for
    /// where the sounds live and what the vault does not know about them.
    @ViewBuilder
    private var sounds: some View {
        StudioSoundsBrowser(model: model, injected: injectedVault)
    }

    @ViewBuilder
    private var takes: some View {
        // The full Takes browser (L10): filter, lineage, preview, drag, purge.
        StudioTakesBrowser(model: model)
    }

    /// The tracks the Stems pane lists: the ones that actually HOLD audio.
    ///
    /// `role`, not `kind`, and the distinction is the whole fix.
    /// `StudioTrackSnapshot.role` is derived from clips and devices — engine
    /// truth — while `kind` is a guess the Swift side makes from the track's
    /// NAME (`RealStudioEngine.stemKind`), which its own comment says "is not
    /// fit to gate an affordance" because it flips when a user renames a track.
    ///
    /// Before this, the pane ran `ForEach(snapshot.tracks)` over EVERY track,
    /// MIDI instrument tracks included. A list of the song's layers that listed
    /// things which are not layers: an instrument track has no stem to show, and
    /// muting it from a pane called Stems means something else entirely.
    ///
    /// A static function rather than a computed property inside the view body,
    /// so the rule can be driven from a test without a window — the same reason
    /// `StudioSoundsBrowserActions` exists.
    static func stemTracks(in snapshot: StudioProjectSnapshot?) -> [StudioTrackSnapshot] {
        (snapshot?.tracks ?? []).filter { $0.role == .audio }
    }

    /// Why the Stems pane has nothing to list, or nil when it has.
    ///
    /// There are THREE ways to be empty here and they have three different
    /// remedies, and the pane used to answer all three with one sentence: "No
    /// stems yet. Open a song in Studio and it will be split into layers."
    /// Said to somebody whose project is still loading that is wrong; said to
    /// somebody with an empty project it points at a song they have not chosen;
    /// and said to somebody whose four tracks are all instruments it does not
    /// explain why the tracks they can plainly see are not listed here. That
    /// last one is the case a person hits after playing something in on the
    /// keys, and "there is nothing here" reads as a broken pane rather than as
    /// a true statement about what stems are.
    ///
    /// A static function on the view, not a computed property in the body, for
    /// the same reason `stemTracks` is one: the rule can then be driven from a
    /// test without a window.
    static func stemsEmptyReason(in snapshot: StudioProjectSnapshot?) -> String? {
        guard let snapshot else {
            return "The project is still loading. Its layers will appear here as soon as it does."
        }
        guard stemTracks(in: snapshot).isEmpty else { return nil }
        if snapshot.tracks.isEmpty {
            return "This project has nothing in it yet. Drag a song from Songs onto the timeline, or press Import, and its parts show up here."
        }
        let count = snapshot.tracks.count
        return "None of this project's \(count) track\(count == 1 ? "" : "s") holds a recording yet, so there is nothing here to split into layers — an instrument you play has no stem. Open a song in Studio (right-click one under Songs) to separate it into vocals, drums, bass and the rest."
    }

    @ViewBuilder
    private var stems: some View {
        header("Project stems")
        if let why = Self.stemsEmptyReason(in: model.snapshot) {
            emptyNote(why)
        } else {
            ForEach(Self.stemTracks(in: model.snapshot)) { track in
                // TWO lines per stem, not one. Everything below has to fit a
                // 172 pt rail with room to be HIT from a sofa, and one line
                // cannot hold a name, a solo, a mute, two level steps and a
                // readout at a size anybody can see. Stacking is what buys the
                // size; see `stemChipHeight`.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(StudioTokens.stemColor(track.kind))
                            .frame(width: 6, height: 6)
                        // ⚠️ NOT `fixedSize()`, AND THAT WAS THE BUG.
                        //
                        // This read `.lineLimit(1).fixedSize()`. `fixedSize()`
                        // means "take your ideal width whatever you are
                        // offered", so a stem named after the song it came from
                        // — "Lead Vocal Doubles Take Three" — widened the row
                        // past the rail and pushed the Solo and the Mute out of
                        // it. The pane lives in a vertical ScrollView, which
                        // CLIPS: the two controls were not small, they were off
                        // screen. That is "stems is missing the controls to do
                        // anything", reported by the owner, exactly.
                        //
                        // This is the same `fixedSize()` trap the transport row
                        // was blown to 475 pt by, seen from its other side. The
                        // shape that is right for a sentence in a tight row is
                        // the one `StudioPaletteReasonLabel` uses: one line,
                        // a bounded frame, and truncate rather than grow.
                        Text(track.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StudioTokens.dim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // The two chips that make this pane's own tooltip true. It
                        // says a part "can be changed on its own"; before them the
                        // rows did nothing at all, so the only way to hear the song
                        // without its drums was to go and find that track in the
                        // mixer. Both send the SAME `track.mute` / `track.solo`
                        // commands the mixer chips send, so one press is one undo
                        // step and an agent doing it produces the same journal.
                        stemChip("S", on: track.soloed, tint: StudioTokens.cyan, track: track)
                        stemChip("M", on: track.muted, tint: StudioTokens.purple, track: track)
                    }
                    // Level. Solo and mute are on and off; "a bit less drums"
                    // is the next thing anybody separating a song wants and the
                    // only route to it was to open the mixer and find the strip.
                    HStack(spacing: 4) {
                        stemLevelStep(track, by: -StudioBrowserStemActions.levelStepDB,
                                      glyph: "minus")
                        Text(StudioPaletteFormat.text(track.volumeDB, unit: .decibels))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(StudioTokens.faint)
                            // Bounded by construction: the widest this can ever
                            // print is "-60.0 dB". `fixedSize()` is safe on a
                            // string whose length is known; it is not safe on a
                            // name somebody typed, which is the line above.
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: 46, alignment: .leading)
                            .studioHelp("browser.stem.level")
                        stemLevelStep(track, by: StudioBrowserStemActions.levelStepDB,
                                      glyph: "plus")
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(track.name), \(track.roleSummary)")
            }
        }
    }

    /// How big a stem row's controls are, and why it is not the mixer's number.
    ///
    /// The chips shipped at 18x16 = 288 pt². The lane that added them flagged
    /// exactly this: "are they hittable at couch distance, or do they need the
    /// mixer's chip size?" The mixer's own are 22x16 = 352 pt², which is no
    /// answer at all — both are far under any target you can hit on a
    /// television from a sofa, and matching the mixer would have been copying
    /// the same mistake with more confidence.
    ///
    /// 26x20 = 520 pt². Still short of the 28x28 a pointer-free interface would
    /// want, and it is what a 172 pt rail carrying a name and two chips has
    /// room for. `stemChipMinimumArea` is the floor a test pins, so a restyle
    /// can change the shape and cannot shrink the target.
    static let stemChipWidth: CGFloat = 26
    static let stemChipHeight: CGFloat = 20
    static let stemChipMinimumArea: CGFloat = 500

    /// One stem row's Solo or Mute. A shared builder, so both chips carry the
    /// same generous hit target and the help rides through one application.
    private func stemChip(_ glyph: String, on: Bool, tint: Color,
                          track: StudioTrackSnapshot) -> some View {
        Button {
            if glyph == "S" {
                StudioBrowserStemActions.toggleSolo(model, track)
            } else {
                StudioBrowserStemActions.toggleMute(model, track)
            }
        } label: {
            Text(glyph)
                .font(.system(size: 11, weight: .heavy))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? StudioTokens.bg : StudioTokens.dim)
                // An 11 pt glyph is a ~9x11 pt click target. The frame and the
                // contentShape are what stop this needing a pixel-perfect click,
                // which is the complaint the mixer's chips started from.
                .frame(width: Self.stemChipWidth, height: Self.stemChipHeight)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(on ? tint : StudioTokens.panelHi))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .studioHelp(glyph == "S" ? "browser.stem.solo" : "browser.stem.mute")
        .accessibilityLabel(glyph == "S" ? "Solo \(track.name)" : "Mute \(track.name)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// One press of the stem's level, up or down.
    ///
    /// A STEPPER rather than a fader, deliberately. A drag in a 172 pt rail is
    /// a fine-motor gesture — the same thing that made a note's 3 pt edge
    /// unusable — and a drag also has to decide when a gesture ends before it
    /// can journal, whereas a press is unambiguous: one press, one `mix.gain`,
    /// one press of Cmd-Z. That is the same bargain the mixer's own chevrons
    /// and the settings tab strip's already make.
    ///
    /// One `Button` constructor for both steps on every row, and one
    /// `.studioHelp` with it, exactly as `stemChip` does.
    ///
    /// ⚠️ Note the back-tick pair above encloses the word alone. The help
    /// coverage net counts `Button` followed by a brace or a PAREN, so writing
    /// the constructor's name with its parenthesis IN A COMMENT makes this file
    /// read as one control heavier than it is — which is exactly what happened
    /// on the first draft of this comment, and it failed the net by name.
    private func stemLevelStep(
        _ track: StudioTrackSnapshot, by stepDB: Double, glyph: String
    ) -> some View {
        let atEnd = StudioBrowserStemActions.wouldMove(track, by: stepDB) == false
        return Button {
            StudioBrowserStemActions.nudgeLevel(model, track, by: stepDB)
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(atEnd ? StudioTokens.faint : StudioTokens.dim)
                .frame(width: Self.stemChipWidth, height: Self.stemChipHeight)
                .background(RoundedRectangle(cornerRadius: 4).fill(StudioTokens.panelHi))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Disabled at the ends rather than sending a command that changes
        // nothing: a journalled no-op is an undo step that undoes nothing,
        // which is worse than an inert button because it costs the user a
        // Cmd-Z to discover.
        .disabled(atEnd)
        .studioHelp("browser.stem.level.step")
        .accessibilityLabel(stepDB < 0
                            ? "Turn \(track.name) down" : "Turn \(track.name) up")
    }

    // The "This project" snapshot row (static, non-loadable). Library rows use
    // the interactive `StudioLibrarySongRow` below, which shares the same visual.
    private func songRow(title: String, generative: Bool, selected: Bool) -> some View {
        StudioSongRowLabel(title: title, generative: generative, selected: selected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(selected ? "open" : "")
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(StudioTokens.faint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - What a stem row DOES, named so a test can drive exactly that
//
// Both gestures go through named functions rather than closures written inline
// in the view, for the same reason `StudioSoundsBrowserActions` does: "the row
// is wired to the thing that was tested" is otherwise unassertable without
// launching a GUI, and this repo has shipped a command palette listing 71
// commands and wiring 11.
//
// Neither invents a command. `track.mute` and `track.solo` are what the mixer's
// M and S chips send, and `engine/render/tests/solo.rs` proves them on rendered
// AUDIO rather than on flags — so a stem soloed here is silent in a bounce for
// the same reason it is silent in the mixer.

enum StudioBrowserStemActions {

    @MainActor
    static func toggleSolo(_ model: StudioViewModel, _ track: StudioTrackSnapshot) {
        model.setTrackSolo(track.id, soloed: !track.soloed)
    }

    @MainActor
    static func toggleMute(_ model: StudioViewModel, _ track: StudioTrackSnapshot) {
        model.setTrackMute(track.id, muted: !track.muted)
    }

    /// How far one press moves a stem's level, and how far it may go.
    ///
    /// ⚠️ The range is the SAME one the palette's `mix.gain` row declares, and
    /// `StudioStemsPaneTests.testTheLevelRangeIsThePaletteRowsOwnRange` holds
    /// the two together. Two ranges for one parameter is how a control ends up
    /// able to send a value the command refuses — and `StudioViewModel.send`
    /// discards the engine's result, so that refusal would be silent.
    ///
    /// 1 dB a press: small enough to be a real adjustment, big enough that a
    /// person hears it. Twelve presses to the top of the range, which is a lot
    /// less than a person will ever want from here — the mixer's fader and
    /// ⌘K's typed value are both one gesture away for a bigger move.
    static let levelRange: ClosedRange<Double> = -60...12
    static let levelStepDB: Double = 1.0

    /// Whether a press would change anything. Drives the disabled state, so a
    /// button at the end of the range is greyed rather than journalling a
    /// command that moves nothing.
    static func wouldMove(_ track: StudioTrackSnapshot, by stepDB: Double) -> Bool {
        abs(clamped(track.volumeDB + stepDB) - track.volumeDB) > 0.0001
    }

    private static func clamped(_ db: Double) -> Double {
        min(levelRange.upperBound, max(levelRange.lowerBound, db))
    }

    /// One press. One `mix.gain` on the journalled bus, one press of Cmd-Z —
    /// the same command the mixer's fader and ⌘K's "Set this track's volume"
    /// send, so a stem turned down here is turned down everywhere and an agent
    /// doing it produces the same journal.
    @MainActor
    static func nudgeLevel(_ model: StudioViewModel, _ track: StudioTrackSnapshot, by stepDB: Double) {
        guard wouldMove(track, by: stepDB) else { return }
        model.setTrackGain(track.id, gainDB: clamped(track.volumeDB + stepDB))
    }
}

// MARK: - Song row visual (shared)
//
// The icon + title chrome used by both the static "This project" row and the
// interactive library rows, so they stay pixel-identical. `highlighted` paints
// the hover state; `dimmed` marks a non-loadable (remote / missing-file) row.

struct StudioSongRowLabel: View {
    let title: String
    let generative: Bool
    let selected: Bool
    var highlighted: Bool = false
    var dimmed: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if generative {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(StudioTokens.generativeGradient)
                        .opacity(selected ? 0.85 : 0.4)
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(StudioTokens.panelHi)
                }
            }
            .frame(width: 22, height: 22)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? StudioTokens.text : StudioTokens.dim)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(dimmed ? 0.45 : 1)
    }

    private var rowBackground: Color {
        if selected { return StudioTokens.panelHi }
        if highlighted { return StudioTokens.panelHi.opacity(0.5) }
        return .clear
    }
}

// MARK: - Interactive library song row
//
// Loads a library song onto the Studio timeline via the SAME path the "Import
// audio…" button and the timeline file-drop use (`model.importAudio(path:)` ->
// engine.importAudio -> clip + waveform tile). Two affordances, at parity:
//   • Double-click  -> import at the engine's target track / playhead.
//   • Drag onto the timeline -> the timeline's existing .fileURL drop handler
//     decodes the URL and calls the same importAudio.
// A song whose local audio file is missing (e.g. remote-only) is shown disabled
// (dimmed, no cursor, no gestures) rather than being a silent dead row.

struct StudioLibrarySongRow: View {
    @ObservedObject var model: StudioViewModel
    let track: Track
    @State private var hovering = false

    /// Loadable only when the track's audio is present on disk locally.
    ///
    /// ⚠️ CALL THIS ONCE PER BODY PASS AND HOLD THE ANSWER. It is not a field
    /// read: `Track.audioFileExists` builds a URL, renders it to a path and
    /// makes a `stat(2)` — ~12 µs a call, ~80% of it the URL/String work rather
    /// than the syscall. `body` used to read it SIX times (highlighted, dimmed,
    /// help, hint, traits, and the `if`), and the Songs pane draws up to sixty
    /// of these rows in a plain non-lazy `ForEach`, so a single browser pass
    /// cost ~360 of them — about 4.5 ms of main-thread layout, on a rail that
    /// redraws whenever the 30 Hz snapshot poll publishes.
    ///
    /// Same defect shape as the `BrigadeConfig.isConfigured` P0 one layer down:
    /// an accessor that reads free and is not. `StudioBrowserCostTests` counts
    /// the calls and fails if the reads multiply again.
    private var loadable: Bool { track.audioFileExists }

    /// The rich "Open in Studio" landing (analyze -> separate -> bar-aligned
    /// stem session), built from the track exactly as the Library tab's
    /// StudioCoordinator.openInStudio does. Right-click alternative to the
    /// double-click clip import.
    private var landingRequest: StudioLandingRequest {
        StudioLandingRequest(
            sourceAudioPath: track.audioURL.path,
            prompt: track.caption.isEmpty ? (track.originalPrompt ?? track.title) : track.caption,
            declaredBPM: track.bpm,
            key: track.key,
            sectionTags: StudioCoordinator.sectionTags(fromLyrics: track.lyrics),
            seed: nil,
            genModel: nil,
            projectName: track.title.isEmpty ? nil : track.title
        )
    }

    var body: some View {
        // ONE filesystem probe for the whole pass. Every use below reads this
        // `let`; none of them may go back to `loadable`. The gesture closures
        // still call the accessor directly and that is correct — they run on a
        // click, not on a layout pass, and a stale answer there would mean
        // importing a file that has since been deleted.
        let loadable = self.loadable

        let label = StudioSongRowLabel(
            title: track.title, generative: true, selected: false,
            highlighted: loadable && hovering, dimmed: !loadable
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            guard self.loadable else { return }
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture(count: 2) {
            guard self.loadable else { return }
            // Default builds up the session: each song lands on its OWN new track.
            // ⌘-double-click deliberately overdubs onto the current (first) track.
            let overdub = NSEvent.modifierFlags.contains(.command)
            model.importAudio(path: track.audioURL.path, newTrack: !overdub)
        }
        .help(loadable
              ? "Double-click to add this song on a new track (⌘-double-click to overdub onto the current track), drag it onto the timeline, or right-click to open in Studio (analyze + split into stems)."
              : "No local audio for this song yet — nothing to load.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(track.title)
        .accessibilityHint(loadable
                           ? "Double-click to load this song onto a new track"
                           : "No local audio; this song can't be loaded")
        .accessibilityAddTraits(loadable ? .isButton : [])

        // Drag-to-timeline only for loadable rows. The provider vends the file
        // URL as `public.file-url`, which the timeline's .onDrop decodes with
        // URL(dataRepresentation:) — exact parity with a Finder audio drop.
        if loadable {
            label
                .onDrag { NSItemProvider(object: track.audioURL as NSURL) }
                // Right-click / control-click: the rich landing (stems + bar-align),
                // the alternative to the simple double-click clip import.
                .contextMenu {
                    Button("Open in Studio") {
                        Task { await model.land(landingRequest) }
                    }
                }
        } else {
            label
        }
    }
}

// MARK: - Library song search (pure, testable)
//
// The Studio browser's Songs > Library search, factored out of the view so the
// predicate is unit-testable. Case-insensitive substring over a song's
// user-facing metadata (title / artist / album / genre), mirroring the Library
// tab's "Search tracks…" field. An empty query returns every track unfiltered.

enum StudioLibrarySearch {
    static func matches(_ track: Track, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if track.title.lowercased().contains(q) { return true }
        if track.artist?.lowercased().contains(q) == true { return true }
        if track.album?.lowercased().contains(q) == true { return true }
        if track.genre?.lowercased().contains(q) == true { return true }
        return false
    }

    static func filter(_ tracks: [Track], query: String) -> [Track] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tracks }
        return tracks.filter { matches($0, query: q) }
    }
}
