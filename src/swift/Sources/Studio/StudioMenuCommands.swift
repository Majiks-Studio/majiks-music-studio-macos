import SwiftUI

// MARK: - The macOS menu bar, DERIVED from the palette table
//
// WHY THIS FILE EXISTS.
//
// Every capability the Studio has was reachable only by knowing where a glyph
// lived, or by knowing that ⌘K exists and typing into it. The menu bar had
// Library, Playback, Publisher, View, Window and Help — the music-library half
// of the app — and of the DAW's 56 reachable commands it carried exactly ONE
// (Save Project). Built, working, and invisible: the defect class this repo
// produces most.
//
// THE ONE RULE THIS FILE IS BUILT ON: there is no second list.
//
// `StudioPaletteCommands.all` already states, per row, the catalog verb it
// sends, what it needs before it can send it (as a sentence), the one value it
// asks for, and whether it destroys something. A hand-written menu tree would
// be a SECOND copy of that, and two hand-maintained lists of the same thing is
// precisely how the palette rotted to 11-of-119 in the first place and how
// `CatalogNames.swift` sat for months under a header naming a generator script
// that did not exist.
//
// So this file names NO catalog command anywhere. Placement is computed from
// the command's own namespace (`menu(forCatalogName:)`), the title, the keys,
// the precondition and the destructiveness all come from the row, and
// `StudioMenuTests.testTheMenuFileNamesNoCatalogCommandOfItsOwn` fails the
// build if a catalog name ever appears here as a literal. A row added to the
// palette table appears in a menu with no edit here at all.
//
// WHAT THE OWNER ASKED FOR, AND HOW IT WAS READ.
//
//   "the top menu bar needs to have menus for all the sections, like studio,
//    stems, etc."
//
// Read as BOTH halves, because both are true and they are different needs:
//
//   * NAVIGATION — "take me to Stems" is a thing he cannot currently do from
//     the menu bar at all. That is the View menu's `Go to` section (⌘1…⌘6),
//     built from `StudioSection`.
//   * ACTIONS — the verbs that act on what is open. Those are grouped by the
//     OBJECT they act on (Song / Track / Clip / Transport), not by the pane
//     they happen to live in, because a person looking for "make this quieter"
//     knows it is about a track and does not know it lives in the mixer dock.
//     Grouping by pane would have reproduced the original defect — you would
//     still need to know where the thing lives.
//
// A "Stems" ACTION menu was considered and deliberately not built: every verb
// a stem row offers (mute, solo, level) is a `track.*` / `mix.*` verb on an
// audio track, so a Stems menu would be the Track menu under a second name —
// the second-list defect again, wearing the owner's own word.

// MARK: - The menus this file owns

/// The top-level menus built from the palette table.
///
/// Four, and they are the four OBJECTS the Studio's verbs act on. `View` is
/// deliberately not here, and this file extends the View menu rather than
/// shadowing it — two menus called View would be a worse bug than no View menu
/// at all.
///
/// ⚠️ That last sentence was written here while the app was shipping exactly
/// the bug it warns about, so read the correction carefully: the View menu is
/// **macOS's**, not `Main.swift`'s. macOS auto-creates View and Window for any
/// WindowGroup app, and `CommandMenu` never merges — it always makes a NEW
/// top-level menu. `Main.swift` used to declare `CommandMenu("View")`, so the
/// menu bar carried two of them (and two Windows) until the dedupe lane turned
/// both into `CommandGroup`s. `StudioViewMenuItemsView` is mounted inside the
/// system's View menu through that group; there is no app-owned View menu for
/// it to be "not here" from.
enum StudioMenu: String, CaseIterable, Identifiable, Sendable {
    case song
    case track
    case clip
    case transport

    var id: String { rawValue }

    /// The word on the menu bar. Nouns, because every item inside is a verb;
    /// a menu called "Edit" full of sentences reads as a category error.
    var title: String {
        switch self {
        case .song: return "Song"
        case .track: return "Track"
        case .clip: return "Clip"
        case .transport: return "Transport"
        }
    }
}

/// Where a command goes, computed from the command's OWN namespace.
///
/// A function rather than a table, and that is the whole anti-drift device: a
/// table would be the second list this file exists not to have. The catalog's
/// namespaces already encode what each verb acts on, so the placement is a
/// reading of the name, not an opinion recorded next to it.
///
/// Returning nil is a REAL outcome and not a fallback: a namespace nobody has
/// placed must fail loudly (`testEveryOfferedCommandLandsInExactlyOneMenu`)
/// rather than land in a default menu where nobody would look for it.
func studioMenu(forCatalogName name: String) -> StudioMenu? {
    // The namespace, not the whole name. `prefix(while:)` rather than
    // `split(separator:)` so a nested name like `transport.loop.set` reads as
    // `transport` and not as something with two candidate namespaces.
    let namespace = String(name.prefix(while: { $0 != "." }))
    switch namespace {
    case "project":
        return .song
    // Everything that acts on ONE track, including its mixer strip, its
    // automation curve, its instrument, and the effects hung off it. The
    // effects panel shows a track or a bus, and a bus exists to serve tracks —
    // an "Effects" menu of seven items would be a fifth word on the menu bar
    // for a thing that is already "what this track sounds like".
    case "track", "mix", "device", "autolane", "autopoint", "route", "fx":
        return .track
    // Notes live INSIDE a clip and the piano roll is opened on one, so a
    // person hunting for "make these notes land on the beat" looks where the
    // clip is. A separate Notes menu would be empty whenever the roll is shut,
    // which is a menu that teaches you it is useless.
    case "clip", "note":
        return .clip
    // Recording and MIDI hardware are transport in the sense that matters
    // here: they are about the moment of playing, not about an object you
    // have selected.
    case "transport", "record", "midi":
        return .transport
    default:
        return nil
    }
}

// MARK: - What pressing a menu item does

/// Two shapes, because a menu cannot ask a question.
///
/// `.send` is the honest one: one gesture, one command, one undo step, exactly
/// as the mixer chip does it. `.askInPalette` is the other honest one — a row
/// that needs a number, or a row that destroys something and must be asked
/// twice, cannot be an item that fires on click. macOS already has a word for
/// "this will ask you something": the trailing ellipsis, which is why these
/// items carry one.
///
/// The alternative — omitting those rows from the menus — is the defect the
/// palette lane named: absent and impossible look identical.
enum StudioMenuAction: Equatable, Sendable {
    case send
    case askInPalette
}

/// One generated menu item over a catalog command.
struct StudioMenuItem: Identifiable, Sendable {
    /// The catalog name the row claims to send. `id` for `ForEach`, and the
    /// key the bridge dispatches and reports availability on.
    let name: String
    let menu: StudioMenu
    /// The row's NAME — `StudioPaletteEntry.terse`. For the 56 catalog rows
    /// that is still the palette's own sentence verbatim, because none of them
    /// has been given a short name yet and the field defaults to `title`; the
    /// ten `studio.*` view rows do carry one. See `StudioPaletteEntry.terse`.
    let title: String
    /// What the row DOES, in the palette's own words. Goes to the tooltip and
    /// to VoiceOver, never to the title — same `terse` / `teaching` split the
    /// help layer has used since it landed.
    let teaching: String
    let action: StudioMenuAction
    /// The shortcut this item BINDS, or nil. See `StudioMenuShortcut`.
    let shortcut: StudioMenuShortcut?

    var id: String { name }

    /// What the item reads on screen. The ellipsis is load-bearing: it is the
    /// macOS promise that clicking will ask rather than act.
    var label: String { action == .askInPalette ? "\(title)…" : title }
}

/// One generated menu item over one of this build's own view rows (`studio.*`).
///
/// Kept as a separate type rather than folded into `StudioMenuItem` because a
/// view row is NOT a catalog command and must never be able to claim one — the
/// same distinction `StudioPaletteEntry.Kind` draws, and for the same reason.
struct StudioMenuViewItem: Identifiable, Sendable {
    let id: String
    /// The NAME. `StudioPaletteEntry.terse` — "Left Panel", not "Show or hide
    /// the left panel".
    let title: String
    /// The sentence. `StudioPaletteEntry.title`, which is what ⌘K lists.
    let teaching: String
    var label: String { title }
}

// MARK: - A shortcut a menu may bind

/// A key equivalent parsed out of the palette row's own `keys` string.
///
/// ⚠️ TWO RULES, BOTH LEARNED THE HARD WAY.
///
///  1. **Command modifier required.** A menu shortcut is APP-GLOBAL. Binding a
///     bare `Delete` (which `clip.remove` teaches) would eat the Delete key in
///     every text field in the app — the library search box, the chat
///     composer, the instruction field. `Space` (`transport.play`) has exactly
///     that problem and is already bound in Playback, where it is guarded by a
///     tab check. Nothing in this file may bind a bare key.
///  2. **No collision with a shortcut `Main.swift` already declares.** Two
///     menu items on one key resolve by menu-bar ORDER, which is not a thing
///     anybody reading either site can see. `testNoGeneratedShortcutCollides`
///     scans `Main.swift` and fails if one slips through.
struct StudioMenuShortcut: Equatable, Sendable {
    let key: Character
    /// Printed the way a menu prints it, for tests and for the report.
    var printed: String { "Cmd \(String(key).uppercased())" }
}

/// Shortcuts a palette row teaches that this file must NOT bind, and why.
///
/// A list of KEYS, not of commands — which is the distinction that keeps it
/// from being the second command list this file exists not to have. Two
/// entries, both because `Main.swift` already owns the key for something else.
let studioMenuShortcutsMainAlreadyOwns: [String: String] = [
    "Cmd S": "File ▸ Save Project already binds ⌘S to the same save, so binding it again would put two items on one key for one action.",
    "Cmd R": "Publisher ▸ Refresh already binds ⌘R. Record keeps its ⌘R inside the Studio (StudioRootView's shortcut buttons), where the tab check makes it unambiguous.",
]

/// Read a palette row's `keys` string as a bindable menu shortcut.
///
/// Deliberately strict and deliberately small: it understands exactly the
/// `"Cmd X"` shape the table writes, and answers nil to everything else —
/// `"Space"`, `"Delete"`, `"Shift ← / Shift →"`. A parser that guessed at the
/// arrow forms would be inventing bindings the app does not have.
func studioMenuShortcut(fromPaletteKeys keys: String?) -> StudioMenuShortcut? {
    guard let keys, studioMenuShortcutsMainAlreadyOwns[keys] == nil else { return nil }
    let parts = keys.split(separator: " ")
    guard parts.count == 2, parts[0] == "Cmd", parts[1].count == 1,
          let ch = parts[1].first, ch.isLetter else { return nil }
    return StudioMenuShortcut(key: Character(ch.lowercased()))
}

// MARK: - The plan

/// The whole menu bar's Studio half, computed. Nothing here is authored.
@MainActor
enum StudioMenuPlan {

    /// Every catalog row the palette offers, placed.
    ///
    /// Order is the palette table's own order, which is the catalog's product
    /// order (project, transport, tracks, clips, mix, notes, effects) — so a
    /// menu reads down in the same sequence the palette lists, and the two
    /// surfaces teach the same shape of the app.
    static let items: [StudioMenuItem] = StudioPaletteCommands.all.compactMap { command in
        guard let menu = studioMenu(forCatalogName: command.name) else { return nil }
        return StudioMenuItem(
            name: command.name,
            menu: menu,
            title: command.title,
            teaching: command.title,
            // A row that needs a value, or one that destroys something and
            // therefore must be asked twice, cannot fire on a click.
            action: (command.argument != nil || command.destructive) ? .askInPalette : .send,
            shortcut: studioMenuShortcut(fromPaletteKeys: command.keys))
    }

    static func items(in menu: StudioMenu) -> [StudioMenuItem] {
        items.filter { $0.menu == menu }
    }

    static func item(named name: String) -> StudioMenuItem? {
        items.first { $0.name == name }
    }

    /// The palette row behind a menu item. The menu never holds its own copy of
    /// a command; it holds a name and looks the row up, so there is exactly one
    /// definition of what `clip.split` does.
    static func command(named name: String) -> StudioPaletteCommand? {
        StudioPaletteCommands.all.first { $0.name == name }
    }

    // MARK: This build's own view rows

    /// The `studio.*` rows the palette lists that are NOT catalog commands:
    /// panel toggles, zoom-to-fit, the frame HUD, the perf sweep.
    ///
    /// Two of them are placed away from View on purpose and they are named
    /// here rather than derived, which is a deliberate, bounded exception:
    /// these are ids this build invented (they are absent from
    /// `CatalogNames.names`, and `testViewRowsNeverBorrowACatalogName` already
    /// holds that line), so naming them cannot recreate the catalog drift this
    /// file is built to prevent.
    static let exportViewRowID = "studio.export"
    static let reviseViewRowID = "studio.revise"
    static let separateViewRowID = "studio.separate"

    static func viewRowMenu(_ id: String) -> StudioMenu? {
        switch id {
        case exportViewRowID: return .song      // writing the song out is a Song verb
        case reviseViewRowID: return .clip      // it acts on the selected bars
        // Splitting a song MAKES tracks — four of them, one per part — so it
        // belongs with the verbs that act on a track and not in View, where the
        // panel toggles live. This is the "Stems menu" question the header of
        // this file already answered: a stem is an audio track, so its verbs
        // are Track verbs, and a fifth word on the menu bar would be the Track
        // menu under a second name.
        case separateViewRowID: return .track
        default: return nil                     // nil = the View menu
        }
    }

    /// Every view row, in palette order.
    static func viewRows() -> [StudioPaletteEntry] {
        StudioPaletteCatalog.entries().filter { $0.command == nil }
    }

    /// The view rows that belong to the View menu (everything not placed above).
    ///
    /// `title: $0.terse` and `teaching: $0.title` — the ONE place the two
    /// registers are pulled apart, and both come off the same palette row, so
    /// this is still not a second list.
    static func viewMenuRows() -> [StudioMenuViewItem] {
        viewRows()
            .filter { viewRowMenu($0.id) == nil }
            .map { StudioMenuViewItem(id: $0.id, title: $0.terse, teaching: $0.title) }
    }

    /// The view rows placed into one of the four object menus.
    static func viewRows(in menu: StudioMenu) -> [StudioMenuViewItem] {
        viewRows()
            .filter { viewRowMenu($0.id) == menu }
            .map { StudioMenuViewItem(id: $0.id, title: $0.terse, teaching: $0.title) }
    }

    static func viewRow(named id: String) -> StudioPaletteEntry? {
        viewRows().first { $0.id == id }
    }
}

// MARK: - What a menu actually PRINTS
//
// ⚠️ THE DEFECT THIS EXISTS TO PREVENT, in the shape it shipped in 3.6.0.
//
// Every disabled item printed its own title followed by an em dash and its
// whole disabled-reason. With the Studio tab never opened, every item in all
// five menus is blocked for the SAME reason — one 14-word sentence — so the
// View menu read:
//
//     Fit the whole song on screen — Open the Studio tab first — these act on
//         the song you have open there. View ▸ Go to ▸ Studio.
//     Show or hide the left panel — Open the Studio tab first — these act on
//         the song you have open there. View ▸ Go to ▸ Studio.
//     …five more…
//
// Seven copies of one sentence, on a 4K TV at couch distance. Typeset in
// `NSFont.menuFont(ofSize: 0)` — the font an `NSMenuItem` actually draws its
// title in — the widest of those seven is 836 pt of TEXT alone, before the menu
// adds its state column and its key-equivalent column. (The report that started
// this lane estimated ~680 pt by eye, which was reading the menu rather than
// measuring it; either number is the same defect.) The Song / Track / Clip /
// Transport menus were the same thing 10 to 20 items deep.
//
// It is the toolbar-blowout defect exactly — an unconstrained string in a
// container that sizes to its widest child — and an NSMenu never wraps, so
// there is no `lineLimit(1)` to reach for here. The only fix is to not put the
// sentence there.
//
// WHERE THE REASON WENT, AND WHY NOT THE OTHER TWO PLACES.
//
// It goes into a FOOTER: below a divider at the bottom of the menu, every
// DISTINCT reason among that menu's greyed items, printed once, wrapped onto
// lines a menu can hold.
//
//   * NOT the tooltip alone. `StudioMenuButton`'s old comment is right about
//     the platform: macOS shows no help tag on a DISABLED NSMenuItem, so a
//     reason that lived only in `.help(...)` is a reason nobody can read —
//     which is how "quantize is not in this app" and "quantize needs notes
//     selected" become indistinguishable. That is the failure this whole
//     arrangement exists to prevent, and moving the sentence into a tooltip
//     would be deleting it while appearing to keep it. `.help` is still
//     applied, as a second channel and for VoiceOver, and is not relied on.
//   * NOT a section header with the greyed items grouped underneath it. It
//     reads better and it makes items MOVE: an item's group would change as
//     the selection changed, so Clip ▸ Split would sit in a different place
//     depending on what was selected when you opened the menu. A menu whose
//     items move is worse than one that is wide. Item order stays exactly what
//     the palette table says, always.
//   * NOT a shortened reason. The teaching is the point of the help layer, and
//     the owner is not a DAW user. `wrap` cannot drop a word by construction
//     (`testWrappingAReasonCannotLoseAWordOfIt`), so the footer is the whole
//     sentence — it is only the LINE that is short, not the explanation.
//
// The footer is a plain `Text` inside the menu, which macOS renders as a
// greyed, unselectable item. Same idiom `StudioHelpMenu` already uses for its
// verbosity blurb, and it adds no interactive control to any file.

enum StudioMenuLayout {

    /// The longest line, in characters, a menu item is allowed to print.
    ///
    /// Characters and not points, deliberately: this is a source-level rule a
    /// person editing a reason string can apply by eye, and an AppKit font
    /// metric has no business inside a layout rule the palette table has to
    /// live by.
    ///
    /// 44 was chosen by measuring, not by taste. In the menu font it is about
    /// 265 pt, which is wider than any menu ITEM here and still narrower than
    /// the 300 pt bound the width test holds the whole menu to; and it is wide
    /// enough that SEVEN of the eight reasons the menus can currently show fit
    /// on one line, so the common case is a one-line footer. Only the
    /// studio-not-open sentence and the no-track one wrap at all.
    /// `StudioMenuTests.testTheViewMenuIsNoWiderThanTheItemsItSitsUnder` is the
    /// one that measures the actual typeset points.
    static let lineLimit = 44

    /// Break a reason onto lines a menu can hold, WITHOUT losing any of it.
    ///
    /// Greedy, on whitespace, and it never splits a word — so a single word
    /// longer than the limit gets a line of its own and the line comes out over
    /// the limit rather than the word coming out mangled. That is the right way
    /// round: an over-wide line is visible, a hyphenated identifier is a bug
    /// report.
    ///
    /// The invariant that matters is that the words survive:
    /// `wrap(s).joined(separator: " ")` is `s` with its whitespace normalised,
    /// for every reason in the palette table. That is what makes this a MOVE of
    /// the teaching rather than an edit of it.
    ///
    /// BALANCED, not plain greedy, and that is worth the six lines: plain
    /// greedy puts the studio-not-open sentence on lines of 43, 40 and 7
    /// characters, and a menu item reading just "Studio." under two full ones
    /// looks like something went wrong rather than like a wrapped sentence.
    /// Balancing is done by re-wrapping at the NARROWEST limit that still fits
    /// in the same number of lines (33, here, giving 33 / 29 / 28) — so it can
    /// only ever make lines shorter, never add one, and it is still `wrap`, so
    /// the word-preserving invariant above is untouched.
    static func wrap(_ sentence: String, limit: Int = lineLimit) -> [String] {
        let words = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }

        var best = greedy(words, limit)
        // Greedy line count is monotonic as the limit narrows, so the first
        // limit that needs an extra line is the stopping point.
        var narrow = limit
        while narrow > 1 {
            let candidate = greedy(words, narrow - 1)
            if candidate.count > best.count { break }
            narrow -= 1
            best = candidate
        }
        return best
    }

    /// Plain greedy fill. A word longer than the limit gets a line to itself
    /// rather than being cut in half.
    private static func greedy(_ words: [String], _ limit: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= limit {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// The footer for one menu: every distinct reason among its items, once,
    /// wrapped, in the order the items appear.
    ///
    /// DISTINCT is the whole point. Before the Studio has ever been opened all
    /// 20 items in the Track menu carry the identical sentence, and printing it
    /// 20 times is the defect; printing it once is the fix. When the Studio IS
    /// open the reasons are the palette rows' own preconditions and there are
    /// usually one or two of them per menu ("Select a clip first.", "Select
    /// some notes in the piano roll first."), so the footer stays two or three
    /// lines.
    ///
    /// ⚠️ WHAT THIS GIVES UP, said out loud rather than discovered later: with
    /// two distinct reasons in one menu, the footer does not say WHICH greyed
    /// item has which. The per-item `.help(...)` does, when macOS delivers it,
    /// and VoiceOver always does. That is a real loss and it is the price of
    /// not reordering items; it is bounded, because a reason that covers only
    /// one item is rare and a menu with three is rarer still.
    static func footerLines(reasons: [String?]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for case let reason? in reasons where seen.insert(reason).inserted {
            out += wrap(reason)
        }
        return out
    }
}

// MARK: - Where the app's tabs live, as a menu can see them

/// The six panes, so `View ▸ Go to` can name them.
///
/// The tags are `ContentView`'s own `.tag(...)` values, which are literals at
/// the call site and cannot be imported. `StudioMenuTests` scans
/// `ContentView.swift` for each `.tag(n)` AND counts them, so a seventh tab —
/// or a renumbered one — fails rather than producing a menu item that switches
/// to the wrong pane. That pairing matters: the count alone would miss a
/// renumber, and the presence check alone would miss an addition.
enum StudioSection: Int, CaseIterable, Identifiable, Sendable {
    case chat = 0
    case create = 1
    case library = 2
    case publisher = 3
    case stems = 4
    case studio = 5

    var id: Int { rawValue }
    var tag: Int { rawValue }

    /// The word on the tab, verbatim, because a menu that calls a pane
    /// something the tab does not is a menu that sends people to the wrong
    /// place. "Studio" is the DAW and "Create" is the generator, which is the
    /// exact pair `StudioCoordinator`'s own comment records getting wrong.
    var title: String {
        switch self {
        case .chat: return "Chat"
        case .create: return "Create"
        case .library: return "Library"
        case .publisher: return "Publisher"
        case .stems: return "Stems"
        case .studio: return "Studio"
        }
    }

    /// ⌘1…⌘6, in the order the tabs are DECLARED rather than in tag order, so
    /// the numbers match what the eye counts along the tab strip.
    static var inTabStripOrder: [StudioSection] {
        [.chat, .create, .studio, .stems, .library, .publisher]
    }

    var shortcutKey: Character? {
        guard let index = Self.inTabStripOrder.firstIndex(of: self) else { return nil }
        return Character(String(index + 1))
    }
}

// MARK: - The bridge between the App scene and the live Studio
//
// The menus are declared in `Main.swift`, at App scope. The Studio's view
// model, piano-roll controller and routing controller are `@StateObject`s
// inside `StudioRootView`, which is four levels down inside a TabView. There is
// no way for a `CommandMenu` to reach them directly.
//
// So the Studio pushes UP, exactly as it already does for the spacebar
// (`StudioCoordinator.dawTransportToggle`). This is that same idiom, one step
// larger: `StudioRootView` installs a closure that vends the live
// `StudioPaletteContext`, and this object is what the menus observe.
//
// ⚠️ THE DISABLED STATE IS THE POINT, so read how it is kept fresh.
//
// `reasons` is republished only when the map CHANGES, and it is recomputed from
// the palette rows' OWN `block` closures — never from a second copy of their
// logic, which is the "coverage test carrying its own traversal" trap. What it
// is not is a 30 Hz poll: recomputing 56 preconditions on every snapshot tick
// would invalidate the whole App body while a song plays. It refreshes when the
// things preconditions actually depend on move — the selection, recording, the
// roll, the routing focus — and again when a menu begins tracking.

@MainActor
final class StudioMenuBridge: ObservableObject {

    static let shared = StudioMenuBridge()

    /// Vends the live context. nil until `StudioRootView` has appeared once.
    private var provider: (@MainActor () -> StudioPaletteContext)?

    /// name -> why it cannot run. Absent means ready. Published, so the App
    /// body re-renders and the `.disabled(...)` on each item re-evaluates.
    @Published private(set) var reasons: [String: String] = [:]

    /// What every Studio item says before the Studio has ever been opened.
    ///
    /// This is a REACHABILITY answer, not an error: the menus are visible from
    /// the Chat tab, and "these act on the song in Studio" plus a greyed item
    /// is how a person learns where the DAW is. `View ▸ Go to ▸ Studio` is one
    /// menu away.
    static let studioNotOpenReason =
        "Open the Studio tab first — these act on the song you have open there. View ▸ Go to ▸ Studio."

    var isStudioOpen: Bool { provider != nil }

    private var menuTrackingObserver: NSObjectProtocol?

    private init() {
        // Refresh when ANY menu begins tracking. Cheap (one traversal per
        // click on the menu bar, not per frame) and it is the one moment the
        // answer is about to be read.
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Called by `StudioRootView.onAppear`.
    func install(_ provider: @escaping @MainActor () -> StudioPaletteContext) {
        self.provider = provider
        refresh()
    }

    /// Test seam and teardown. Named `uninstall` rather than `reset` because it
    /// restores the "Studio has never been opened" state exactly, which is a
    /// state the menus have to render correctly.
    func uninstall() {
        provider = nil
        refresh()
    }

    /// Recompute every item's availability from the palette rows themselves.
    func refresh() {
        var next: [String: String] = [:]
        if let provider {
            let context = provider()
            for item in StudioMenuPlan.items {
                guard let command = StudioMenuPlan.command(named: item.name) else { continue }
                if case .blocked(let why) = command.availability(in: context) {
                    next[item.name] = why
                }
            }
            for row in StudioMenuPlan.viewRows() {
                if let why = row.viewBlock?(context) { next[row.id] = why }
            }
        } else {
            for item in StudioMenuPlan.items { next[item.name] = Self.studioNotOpenReason }
            for row in StudioMenuPlan.viewRows() { next[row.id] = Self.studioNotOpenReason }
        }
        // Publish only on change. `@Published` fires `objectWillChange`
        // unconditionally on assignment, and this object is observed by the App
        // scene — an unconditional 30 Hz assignment would redraw the window.
        if next != reasons { reasons = next }
    }

    /// Why this item cannot run, or nil. The ONE thing the menu asks.
    func reason(for id: String) -> String? { reasons[id] }

    func isEnabled(_ id: String) -> Bool { reasons[id] == nil }

    // MARK: Dispatch

    /// Run a generated catalog item.
    ///
    /// `.send` rows go through `StudioPaletteFlow.step` — the SAME decision the
    /// palette's Return key goes through, not a parallel path — so a row that
    /// became blocked between the menu opening and the click is refused rather
    /// than fired at a state that no longer supports it.
    ///
    /// `.askInPalette` rows open ⌘K seeded on that row. The menu's job there is
    /// to take you to the question, and it says so with its ellipsis.
    func run(_ name: String) {
        guard let provider else { return }
        let context = provider()
        guard let item = StudioMenuPlan.item(named: name),
              let command = StudioMenuPlan.command(named: name) else {
            runViewRow(name, in: context)
            return
        }
        switch item.action {
        case .askInPalette:
            context.model.paletteSeed = name
            context.model.paletteShown = true
        case .send:
            switch StudioPaletteFlow.step(
                for: command, stage: .browsing, typed: "", in: context
            ) {
            case .commit(let value):
                command.perform(context, value)
            case .blocked, .rejected:
                // Refuses rather than fires. The item was greyed; a click that
                // arrives anyway (a stale menu, a scripted press) must not act.
                refresh()
            case .askForArgument, .askForConfirmation:
                // Unreachable by construction — a row that asks anything is
                // classified `.askInPalette` above. Falling through to the
                // palette rather than dropping the gesture on the floor is the
                // failure mode that stays honest if that ever stops being true.
                context.model.paletteSeed = name
                context.model.paletteShown = true
            }
        }
    }

    /// Open ⌘K with nothing seeded — Help ▸ Search All Studio Commands.
    ///
    /// A no-op before the Studio has ever been opened, deliberately: there is
    /// no view model to show a palette over yet, and the Help item switches to
    /// the Studio tab first so the next runloop turn has one.
    func openPalette() {
        guard let provider else { return }
        let context = provider()
        context.model.paletteSeed = nil
        context.model.paletteShown = true
    }

    private func runViewRow(_ id: String, in context: StudioPaletteContext) {
        guard let row = StudioMenuPlan.viewRow(named: id) else { return }
        if row.viewBlock?(context) != nil { return }
        if case .view(let action) = row.kind { action(context.model) }
    }
}

// MARK: - The items, as SwiftUI
//
// `CommandMenu`'s content is an ordinary `View`, so the generated items are one
// small view used by every menu. One place applies the label, the shortcut, the
// disabled state and the reason — which is why "the reason went missing from
// half the menus" is not a state this can reach.

/// The catalog items of one menu.
struct StudioMenuItemsView: View {
    let menu: StudioMenu
    @ObservedObject var bridge: StudioMenuBridge

    var body: some View {
        ForEach(StudioMenuPlan.items(in: menu)) { item in
            StudioMenuButton(
                id: item.name,
                label: item.label,
                teaching: item.teaching,
                shortcut: item.shortcut,
                bridge: bridge)
        }
        // This build's own view rows placed into this menu (Export in Song,
        // Revise in Clip), below a divider so a person can see that they are a
        // different kind of thing: they open a panel rather than send a verb.
        let rows = StudioMenuPlan.viewRows(in: menu)
        if !rows.isEmpty {
            Divider()
            ForEach(rows) { row in
                StudioMenuButton(
                    id: row.id, label: row.label, teaching: row.teaching,
                    shortcut: nil, bridge: bridge)
            }
        }
        StudioMenuReasonFooter(
            ids: StudioMenuPlan.items(in: menu).map(\.name) + rows.map(\.id),
            bridge: bridge)
    }
}

/// The Studio's own entries in the existing View menu: the panel toggles, the
/// zoom-to-fit, the frame HUD, the perf sweep.
struct StudioViewMenuItemsView: View {
    @ObservedObject var bridge: StudioMenuBridge

    var body: some View {
        let rows = StudioMenuPlan.viewMenuRows()
        ForEach(rows) { row in
            StudioMenuButton(
                id: row.id, label: row.label, teaching: row.teaching,
                shortcut: nil, bridge: bridge)
        }
        StudioMenuReasonFooter(ids: rows.map(\.id), bridge: bridge)
    }
}

/// Why the greyed items above cannot run — said ONCE per menu.
///
/// A plain `Text` rather than a disabled `Button`, and that is not cosmetic:
/// a Button here would be a menu item a person can arrow onto and press Return
/// on, and it does nothing, which is the "listed but inert" row this whole
/// arrangement exists to make impossible. `Text` inside menu content renders as
/// a greyed, unselectable item — the idiom `StudioHelpMenu` already uses for
/// its verbosity blurb — and it adds no interactive control to any file's
/// pinned count in `StudioHelpTests`.
///
/// It renders nothing at all when every item is ready, so a working Studio has
/// no footer and no divider.
struct StudioMenuReasonFooter: View {
    let ids: [String]
    @ObservedObject var bridge: StudioMenuBridge

    var body: some View {
        let lines = StudioMenuLayout.footerLines(reasons: ids.map { bridge.reason(for: $0) })
        if !lines.isEmpty {
            Divider()
            // Keyed by OFFSET, not by the line itself. Two distinct reasons
            // can wrap onto an identical line ("first." ends more than one of
            // the palette's sentences), and `id: \.self` would collapse those
            // into a single menu item — a word of the teaching silently gone,
            // which is the one thing this whole arrangement may not do.
            ForEach(Array(lines.enumerated()), id: \.offset) { line in
                Text(line.element)
            }
        }
    }
}

/// One menu item.
///
/// ⚠️ THE TITLE IS THE ITEM'S NAME AND NOTHING ELSE. It used to be the name, an
/// em dash and the whole disabled-reason; read the `StudioMenuLayout` header
/// for what that produced and why the reason now lives in the menu's footer.
///
/// `.help` still carries the reason when there is one and what the item does
/// when there is not — as a SECOND channel, never as the only one. macOS does
/// not deliver a help tag to a disabled `NSMenuItem`, so nothing may depend on
/// it; VoiceOver reads it either way.
struct StudioMenuButton: View {
    let id: String
    let label: String
    /// What this item DOES, in the palette's own sentence. The hover text.
    let teaching: String
    let shortcut: StudioMenuShortcut?
    @ObservedObject var bridge: StudioMenuBridge

    /// What the item reads. Written as a static function so a test can assert
    /// the exact string without building a menu — and kept as a function taking
    /// the reason, rather than deleted, precisely so the mutation that puts the
    /// reason back has an obvious place to be put back INTO and a test that
    /// fails by name when it is (`testADisabledItemsTitleIsItsNameAndNothingElse`).
    static func title(label: String, reason: String?) -> String {
        // `reason` is deliberately NOT read. It is still a parameter so that
        // this signature keeps naming the thing it refuses to print.
        label
    }

    var body: some View {
        let reason = bridge.reason(for: id)
        Button(Self.title(label: label, reason: reason)) {
            bridge.run(id)
        }
        .disabled(reason != nil)
        .help(reason ?? teaching)
        .modifier(StudioMenuShortcutModifier(shortcut: shortcut))
    }
}

/// Keeps the menu bar's disabled states following the app.
///
/// ⚠️ NOT on every snapshot. Recomputing 56 preconditions at the 30 Hz poll
/// rate would republish into the App scene while a song plays, and an
/// `@Published` assignment there redraws the window — the same defect shape the
/// persistent player bar was split into its own observing leaf to fix.
///
/// These four are what every `block` sentence in the palette table actually
/// reads: a selection (which derives BOTH the target clip and the target
/// track), whether a take is running, what the piano roll has selected, and
/// which effect the effects panel has focused. `StudioMenuBridge` also
/// refreshes when a menu begins tracking, which covers anything that moves
/// without one of these firing.
///
/// One `ViewModifier` rather than four chained `.onChange`es on
/// `StudioRootView.body`: that body is already at the type-checker's budget and
/// chaining them tips it into "unable to type-check this expression in
/// reasonable time". Same reason `StudioCoordinatorBridge` exists.
struct StudioMenuFreshness: ViewModifier {
    @ObservedObject var model: StudioViewModel
    @ObservedObject var pianoRoll: StudioPianoRollController
    @ObservedObject var routing: StudioRoutingController

    func body(content: Content) -> some View {
        content
            .onChange(of: model.selection) { _, _ in StudioMenuBridge.shared.refresh() }
            .onChange(of: model.isRecording) { _, _ in StudioMenuBridge.shared.refresh() }
            .onChange(of: pianoRoll.selection) { _, _ in StudioMenuBridge.shared.refresh() }
            .onChange(of: routing.selectedFxID) { _, _ in StudioMenuBridge.shared.refresh() }
    }
}

// MARK: - The four menus, as one Commands block
//
// ⚠️ `CommandsBuilder` takes at most ten children and `Main.swift`'s
// `.commands { }` already had nine. Four more CommandMenus written inline there
// exceeded it and the compiler reported it as "extra arguments at positions
// #11, #12, #13" — a message that names no menu and points at the opening
// brace. Grouping them into one `Commands` conformance is the fix, and it also
// puts the Studio's whole menu bar in the file that generates it.

struct StudioCommandMenus: Commands {
    @ObservedObject var bridge: StudioMenuBridge

    var body: some Commands {
        CommandMenu(StudioMenu.song.title) {
            StudioMenuItemsView(menu: .song, bridge: bridge)
        }
        CommandMenu(StudioMenu.track.title) {
            StudioMenuItemsView(menu: .track, bridge: bridge)
        }
        CommandMenu(StudioMenu.clip.title) {
            StudioMenuItemsView(menu: .clip, bridge: bridge)
        }
        // Named Transport rather than folded into the existing Playback menu on
        // purpose: Playback drives the LIBRARY player (the track you are
        // listening to), Transport drives the SONG YOU ARE BUILDING. They read
        // different clocks — which is why the persistent player bar is hidden
        // on the Studio tab — and one menu over two clocks would lie about
        // which one a command moved.
        CommandMenu(StudioMenu.transport.title) {
            StudioMenuItemsView(menu: .transport, bridge: bridge)
        }
    }
}

/// Applies a key equivalent only when there is one. A `ViewModifier` rather
/// than an `if` in the body because a conditional inside `CommandMenu` content
/// changes the item's identity, and a menu item that is rebuilt with a new
/// identity every refresh loses its highlight under the pointer.
private struct StudioMenuShortcutModifier: ViewModifier {
    let shortcut: StudioMenuShortcut?

    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: .command)
        } else {
            content
        }
    }
}
