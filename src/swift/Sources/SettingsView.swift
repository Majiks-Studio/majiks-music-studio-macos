import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct SettingsView: View {
    @State private var selectedTab = 0

    // The nine settings sections in display order. Tags are stable ids that
    // pre-date this strip (external code targets them, e.g.
    // OpenSettingsToLibraryLocation -> 2), so display order != tag order and a
    // new section ALWAYS takes the next unused id rather than renumbering.
    //
    // Internal rather than private so `SettingsTabStripTests` can lay out the
    // REAL nine tabs. A test that measured a made-up row would stop tracking
    // this one the moment somebody added a tenth tab or a longer word — which
    // is the exact change that re-arms the failure this strip was rebuilt for.
    static let tabs: [SettingsTabDescriptor] = [
        .init(id: 0, title: "Agents", systemImage: "person.3",
              helpID: "settings.tab.agents"),
        .init(id: 7, title: "Sterling", systemImage: "waveform.circle",
              helpID: "settings.tab.sterling"),
        .init(id: 1, title: "LLM & Models", systemImage: "cpu",
              helpID: "settings.tab.llm"),
        .init(id: 5, title: "Models", systemImage: "square.and.arrow.down.on.square",
              helpID: "settings.tab.models"),
        .init(id: 2, title: "Library Location", systemImage: "folder.badge.gearshape",
              helpID: "settings.tab.libraryLocation"),
        .init(id: 3, title: "Library Backup", systemImage: "externaldrive.badge.timemachine",
              helpID: "settings.tab.libraryBackup"),
        .init(id: 4, title: "Server Pool", systemImage: "server.rack",
              helpID: "settings.tab.serverPool"),
        .init(id: 6, title: "MIDI", systemImage: "pianokeys",
              helpID: "settings.tab.midi"),
        .init(id: 8, title: "MCP / API", systemImage: "point.3.connected.trianglepath.dotted",
              helpID: "settings.tab.mcp"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Custom strip instead of the native macOS TabView toolbar: the
            // native one silently collapses trailing tabs into a tiny >>
            // overflow chevron when the window is narrow. This strip slides
            // under two always-present chevrons instead, so every tab stays
            // reachable AND clickable at any width — see SettingsTabStrip for
            // why "clickable" is the word that had to be earned here.
            SettingsTabStrip(selection: $selectedTab, tabs: Self.tabs)

            Divider()

            Group {
                switch selectedTab {
                case 0: AgentSettingsView()
                case 7: SterlingSettingsPane()
                case 1: LLMSettingsView()
                case 5: ManageModelsView()
                case 2: LibraryLocationSettingsView()
                case 3: LibraryBackupSettingsView()
                case 4: ServerPoolSettingsView()
                case 6: MidiSettingsView()
                case 8: StudioMCPSettingsView()
                default: AgentSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Floor wide enough for the full strip at default font metrics
        // (9 tabs: icons ~16pt + labels at ~13pt + 10pt cell padding + strip
        // insets sums to roughly 950pt), with margin for font rounding.
        //
        // This is now a COMFORT floor, not a correctness one, and the difference
        // matters: it used to be the thing keeping the strip out of a ScrollView
        // branch that killed the tabs, so "bump it whenever a tab is added" was
        // load-bearing. The strip no longer has that branch — below this width
        // it slides under two chevrons and every tab stays clickable — so a
        // tenth tab or a larger dynamic-type setting costs a chevron press, not
        // a dead row. Raising it is still the kind thing to do.
        .frame(minWidth: 980, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettingsToLibraryLocation"))) { _ in
            selectedTab = 2
        }
    }
}

// MARK: - Settings tab strip

struct SettingsTabDescriptor: Identifiable {
    let id: Int
    let title: String
    let systemImage: String
    /// Entry in `StudioHelpCatalog`. Several of these titles ("Server Pool",
    /// "MCP / API") name a concept rather than describe one, so the tab strip
    /// gets the same hover help the Studio surface does.
    let helpID: String
}

/// The Settings window's tab row: every tab visibly present, none hidden behind
/// an overflow chevron, and every one of them clickable at any window width.
///
/// THERE IS NO SCROLLVIEW HERE AT ANY WIDTH, and that is the fix rather than a
/// style choice.
///
/// On macOS a horizontal `ScrollView` claims the mouse-DOWN as a possible pan,
/// which cancels a `Button` press before it ever reaches the button. This strip
/// knew that: its non-scrolling branch carried the comment "a horizontal
/// ScrollView, whose hit-testing is unreliable on macOS and made the tabs feel
/// dead / require pixel-perfect clicks". What it kept was the OTHER branch — a
/// `ScrollView` used as an overflow fallback behind `contentWidth >
/// containerWidth`.
///
/// A conditional fallback is not a smaller version of the bug. It is the bug
/// with a delay on it, and `StudioMixerDock` has now paid for exactly this
/// shape twice: `607e7ac` removed the mixer's ScrollView but left it as an
/// overflow fallback, and `5d8491d` then widened a channel strip 112 -> 173 pt,
/// which lowered the overflow threshold far enough that an ORDINARY three-track
/// session landed in the fallback and the Mute and Solo chips went dead again —
/// through a fully green suite. Here the trigger is a longer tab word, a larger
/// dynamic-type setting, or a narrower window, and nobody re-tests the Settings
/// tabs after renaming a tab.
///
/// So the row is ALWAYS a plain `HStack` of Buttons, and reaching a tab that
/// does not fit moves to an explicit `.offset(x:)` driven by two chevrons — the
/// idiom `StudioMixerDock.nudge` and `StudioFxChainStrip.nudge` already use. A
/// transform moves pixels; it never claims a click.
///
/// The chevrons are always present (disabled at the ends) rather than appearing
/// on overflow, for the two reasons the mixer states: a control that appears and
/// vanishes is one a person at couch distance cannot learn, and — the mechanical
/// one — a chevron that appeared on overflow would change the viewport width,
/// which changes whether it is overflowing. That feedback loop is the same shape
/// as the bug itself.
struct SettingsTabStrip: View {
    @Binding var selection: Int
    let tabs: [SettingsTabDescriptor]

    /// How far one chevron press slides the row.
    ///
    /// The mixer moves by exactly one channel because every strip is the same
    /// width. Tabs are not: "MIDI" and "Library Location" differ by a factor of
    /// three, so there is no single tab pitch to move by. This is roughly one
    /// AVERAGE tab's worth, which keeps a press feeling like "one more tab"
    /// without claiming a precision the row does not have. Reaching a SPECIFIC
    /// tab does not depend on it landing perfectly — the clamp lets the row
    /// reach both ends, and picking a tab reveals that tab exactly (see
    /// `SettingsTabStripMath.revealing`).
    nonisolated static let nudgePitch: CGFloat = 105

    /// The row's height.
    ///
    /// A `GeometryReader` viewport has no intrinsic size of its own, so the
    /// strip has to state its height — and a stated height that is too small
    /// does not draw a smaller row, it CLIPS the bottom off every tab button.
    /// That is not hypothetical: the mixer dock was once pinned at 236 pt and
    /// silently cut the bottom 42 pt off every strip, so the M / S chips were
    /// never drawn at all and could never be clicked.
    /// `SettingsTabStripTests.testTheStripIsTallEnoughToDrawItsOwnButtons`
    /// re-measures the REAL row through `NSHostingView` and fails if it ever
    /// outgrows this number, so this is measured rather than chosen.
    nonisolated static let rowHeight: CGFloat = 58

    nonisolated static let buttonSpacing: CGFloat = 2
    nonisolated static let rowHorizontalInset: CGFloat = 8
    nonisolated static let rowVerticalInset: CGFloat = 6

    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    /// How far the row is slid to the left, in points. Explicit, clamped, and
    /// moved only by the two chevrons and by picking a tab.
    @State private var scrollX: CGFloat = 0
    /// Each tab's laid-out width, so picking a tab can reveal exactly that tab
    /// rather than guessing at one. Empty before the first layout pass, which
    /// `SettingsTabStripMath` reads as "nothing is known yet, do not move".
    @State private var tabWidths: [Int: CGFloat] = [:]

    /// Reuses the mixer's clamp DELIBERATELY. It is already a pure,
    /// pitch-injectable viewport clamp, and `StudioMixerHitTestingTests` already
    /// proves — across 24 content widths and five viewports — that its chevrons
    /// reach both ends and can never strand the row past either. A second copy
    /// of that arithmetic here would be a second thing to get wrong, and this
    /// repo's own rule applies: one rule, in one place, because a duplicate
    /// guard masks a broken clamp.
    private var layout: StudioMixerStripLayout { Self.layout(contentWidth: contentWidth,
                                                             viewportWidth: viewportWidth,
                                                             scrollX: scrollX) }

    /// Named, and internal, so a test can build the SAME layout the chevrons
    /// build. Dropping `pitch:` here compiles and still reaches both ends —
    /// `StudioMixerStripLayout`'s default pitch is one MIXER CHANNEL — so the
    /// strip would silently start moving by 183 pt, and would change again the
    /// next time somebody widened a channel strip. That mutation survived every
    /// assertion in this file until this function existed to be asserted on.
    static func layout(contentWidth: CGFloat, viewportWidth: CGFloat,
                       scrollX: CGFloat) -> StudioMixerStripLayout {
        StudioMixerStripLayout(contentWidth: contentWidth,
                               viewportWidth: viewportWidth,
                               scrollX: scrollX,
                               pitch: nudgePitch)
    }

    private var math: SettingsTabStripMath {
        SettingsTabStripMath(order: tabs.map(\.id),
                             widths: tabWidths,
                             spacing: Self.buttonSpacing,
                             leadingInset: Self.rowHorizontalInset)
    }

    var body: some View {
        HStack(spacing: 0) {
            nudge(-1, "chevron.left")
            // A GeometryReader, not `.frame(maxWidth: .infinity)`. Measured on
            // the mixer and written down there: a flexible frame does not shrink
            // an inflexible child, so the row reports its full ideal width, the
            // HStack grows to match, and the whole thing overflows CENTRED with
            // both chevrons pushed off screen — which leaves the first tabs
            // unreachable. A GeometryReader takes the proposal exactly and lets
            // its child overflow inside it.
            GeometryReader { geo in
                buttonRow
                    .offset(x: -layout.clampedScrollX)
                    .onAppear { viewportWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in viewportWidth = w }
            }
            .clipped()
            // `.clipped()` clips PIXELS, not the hit region. Without this a tab
            // slid off the left edge still answers clicks from underneath the
            // chevron that slid it there.
            .contentShape(Rectangle())
            .overlay(alignment: .leading) { edgeFade(leading: true) }
            .overlay(alignment: .trailing) { edgeFade(leading: false) }
            nudge(1, "chevron.right")
        }
        .frame(height: Self.rowHeight)
        // A tab can be selected from OUTSIDE the strip — the Library Location
        // notification does exactly that — and the selected tab may be slid off
        // the edge. Reveal it, or the pane and the highlighted tab disagree
        // about where the user is. This replaces the `ScrollViewReader` the
        // ScrollView used to carry; a proxy cannot exist without one.
        .onChange(of: selection) { _, newValue in
            withAnimation(.easeOut(duration: 0.15)) {
                scrollX = math.revealing(newValue,
                                         scrollX: layout.clampedScrollX,
                                         viewportWidth: viewportWidth,
                                         maxScroll: layout.maxScroll)
            }
        }
        .background(.bar)
    }

    /// The row of tab buttons, plus the two width probes the clamp and the
    /// reveal are computed from.
    ///
    /// Internal rather than private so the height guard can measure THE REAL
    /// ROW. A guard that measured a reconstruction of it would go quiet the day
    /// the two drifted, which is the failure mode this whole file is about.
    var buttonRow: some View {
        HStack(spacing: Self.buttonSpacing) {
            ForEach(tabs) { tab in
                SettingsTabButton(
                    tab: tab,
                    isSelected: tab.id == selection,
                    action: { selection = tab.id }
                )
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SettingsTabWidthKey.self,
                                               value: [tab.id: geo.size.width])
                    }
                )
            }
        }
        .padding(.horizontal, Self.rowHorizontalInset)
        .padding(.vertical, Self.rowVerticalInset)
        .onPreferenceChange(SettingsTabWidthKey.self) { tabWidths = $0 }
        // Measured on the row's OWN ideal width — the GeometryReader above
        // proposes the viewport and this HStack overflows it — so the scroll
        // clamp can never feed back on itself.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: StripWidthKey.self,
                    value: geo.size.width
                )
            }
        )
        .onPreferenceChange(StripWidthKey.self) { contentWidth = $0 }
    }

    /// Explicit horizontal transform, clamped — the whole reason there is no
    /// ScrollView above. Modelled on `StudioMixerDock.nudge`, deliberately: this
    /// repo has solved this problem twice already and the third solution should
    /// not be a new idea.
    private func nudge(_ direction: CGFloat, _ glyph: String) -> some View {
        let l = layout
        let enabled = direction < 0 ? l.canScrollLeft : l.canScrollRight
        return Button {
            scrollX = l.nudged(direction)
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .bold))
                // A generous target: these chevrons are the only way to a tab
                // that does not fit, and this window gets driven from a couch.
                .frame(width: 22, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
        .studioHelp(direction < 0 ? "settings.tab.scrollLeft" : "settings.tab.scrollRight")
        .accessibilityLabel(direction < 0 ? "Show earlier settings tabs" : "Show later settings tabs")
    }

    /// Soft gradient hinting that more tabs exist past the clipped edge.
    private func edgeFade(leading: Bool) -> some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor).opacity(0.9),
                Color(nsColor: .windowBackgroundColor).opacity(0.0),
            ],
            startPoint: leading ? .leading : .trailing,
            endPoint: leading ? .trailing : .leading
        )
        .frame(width: 24)
        // The fade is decoration drawn OVER the row. Without this it would sit
        // on top of the first and last tab and swallow their clicks — the same
        // dead-control failure the ScrollView caused, reintroduced by a gradient.
        .allowsHitTesting(false)
    }
}

// MARK: - Where each tab sits in the row, as pure math
//
// Split out of the view for the reason the mixer's clamp is: "the tab you just
// picked is ON SCREEN" is a promise the deleted `ScrollViewReader` used to keep,
// and it has to be checkable without a window. A reveal that is off by one tab
// does not crash, does not move a pixel test and does not fail a build — it just
// leaves the Settings window highlighting a tab nobody can see.

/// Tab geometry inside the row, and the smallest slide that brings one fully
/// into view.
struct SettingsTabStripMath: Equatable, Sendable {
    /// Tab ids in DISPLAY order. Display order is not id order in this window
    /// (ids are stable across releases), so this cannot be derived from the ids.
    var order: [Int] = []
    /// Measured widths by tab id. A tab absent from here has not been laid out.
    var widths: [Int: CGFloat] = [:]
    var spacing: CGFloat = SettingsTabStrip.buttonSpacing
    var leadingInset: CGFloat = SettingsTabStrip.rowHorizontalInset

    /// Where `id` starts and ends inside the row, or nil when the row has not
    /// been laid out far enough to know. Nil rather than a guess: a reveal
    /// computed from a made-up width would move the row somewhere meaningless,
    /// which is worse than not moving it.
    func range(of id: Int) -> ClosedRange<CGFloat>? {
        var x = leadingInset
        for tab in order {
            guard let w = widths[tab] else { return nil }
            if tab == id { return x...(x + w) }
            x += w + spacing
        }
        return nil
    }

    /// The smallest change to `scrollX` that puts `id` fully inside a viewport
    /// `viewportWidth` wide, clamped to the row.
    ///
    /// A tab already fully visible returns `scrollX` UNCHANGED. A reveal that
    /// always scrolled would yank the strip sideways on every ordinary click,
    /// which is its own kind of broken control.
    func revealing(_ id: Int, scrollX: CGFloat, viewportWidth: CGFloat,
                   maxScroll: CGFloat) -> CGFloat {
        guard viewportWidth > 0, maxScroll > 0, let r = range(of: id) else { return scrollX }
        if r.lowerBound >= scrollX, r.upperBound <= scrollX + viewportWidth { return scrollX }

        // Off the LEFT: bring its leading edge in, with the row's own inset as
        // air so it does not sit flush against the chevron.
        // Off the RIGHT: the smallest offset that gets its trailing edge in —
        // then never further right than its leading edge, so a tab WIDER than
        // the viewport shows its beginning rather than its end.
        let wanted = r.lowerBound < scrollX
            ? r.lowerBound - leadingInset
            : min(r.upperBound - viewportWidth + leadingInset, r.lowerBound)
        return min(maxScroll, max(0, wanted))
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTabDescriptor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.systemImage)
                    .imageScale(.medium)
                Text(tab.title)
                    .lineLimit(1)
                    // Never truncate a label to "..." — the strip scrolls
                    // instead, so full titles are always legible.
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.callout)
            // Roomier padding + a minimum height so the whole pill - not just
            // the icon/text glyphs - is a comfortable click target.
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 30)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            // Hit-test the full cell (including the gap between icon and text
            // and the rounded background), not just the text-sized content.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .studioHelp(tab.helpID)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // Point-hand cursor makes the clickable area obvious on hover.
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

/// Each tab's laid-out width, keyed by its stable id.
private struct SettingsTabWidthKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct StripWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// `StripContainerWidthKey` is gone with the conditional it fed. The container's
// width now comes from the viewport's own GeometryReader, which is the only
// place that can report it without the strip's own size feeding back into the
// decision that sets the strip's own size.

struct LibraryBackupSettingsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var backups: [(url: URL, date: Date, trackCount: Int)] = []
    @State private var lastBackupMessage: String?
    @State private var showRestoreConfirmation = false
    @State private var pendingRestoreURL: URL?
    @State private var restoreError: String?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("Library Backup")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Back up and restore your track library metadata")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top)

                Divider()

                // Info
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                        .font(.caption)
                    Text("Backups save your library.json metadata (track names, ratings, tags). Audio files are not included. Up to 10 rolling backups are kept automatically on every save.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

                // Actions
                VStack(alignment: .leading, spacing: 16) {
                    Text("Actions")
                        .font(.headline)

                    HStack(spacing: 12) {
                        Button(action: performManualBackup) {
                            HStack {
                                Image(systemName: "arrow.down.doc")
                                Text("Backup Now")
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: openBackupFolder) {
                            HStack {
                                Image(systemName: "folder")
                                Text("Show in Finder")
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    if let message = lastBackupMessage {
                        HStack {
                            Image(systemName: message.contains("Error") ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundColor(message.contains("Error") ? .red : .green)
                            Text(message)
                                .font(.caption)
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                    }

                    if let error = restoreError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    }
                }

                Divider()

                // Backup List
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Recent Backups")
                            .font(.headline)
                        Spacer()
                        Text("\(backups.count) backup(s)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if backups.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "doc.on.doc")
                                    .font(.title)
                                    .foregroundColor(.secondary)
                                Text("No backups yet")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                Text("Backups are created automatically when the library is saved, or manually with the button above.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(Array(backups.enumerated()), id: \.offset) { index, backup in
                                HStack(spacing: 12) {
                                    Image(systemName: index == 0 ? "clock.badge.checkmark" : "clock")
                                        .foregroundColor(index == 0 ? .green : .secondary)
                                        .font(.title3)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(dateFormatter.string(from: backup.date))
                                            .font(.body)
                                            .fontWeight(index == 0 ? .medium : .regular)
                                        HStack(spacing: 8) {
                                            Text("\(backup.trackCount) track(s)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text(backup.url.lastPathComponent)
                                                .font(.caption2)
                                                .foregroundColor(.secondary.opacity(0.7))
                                        }
                                    }

                                    Spacer()

                                    if index == 0 {
                                        Text("Latest")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundColor(.green)
                                            .cornerRadius(4)
                                    }

                                    Button("Restore") {
                                        pendingRestoreURL = backup.url
                                        showRestoreConfirmation = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(10)
                                .background(Color(.windowBackgroundColor))
                                .cornerRadius(8)
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refreshBackups()
        }
        .alert("Restore Backup", isPresented: $showRestoreConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingRestoreURL = nil
            }
            Button("Restore", role: .destructive) {
                if let url = pendingRestoreURL {
                    performRestore(from: url)
                }
                pendingRestoreURL = nil
            }
        } message: {
            if let url = pendingRestoreURL,
               let backup = backups.first(where: { $0.url == url }) {
                Text("This will replace your current library with the backup from \(dateFormatter.string(from: backup.date)) containing \(backup.trackCount) track(s). A backup of your current library will be created first. Continue?")
            } else {
                Text("This will replace your current library with the selected backup. A backup of your current library will be created first. Continue?")
            }
        }
    }

    private func refreshBackups() {
        backups = library.listBackups()
    }

    private func performManualBackup() {
        restoreError = nil
        if let url = library.manualBackup() {
            lastBackupMessage = "Backup created: \(url.lastPathComponent)"
        } else {
            lastBackupMessage = "Backup created"
        }
        refreshBackups()
    }

    private func openBackupFolder() {
        let url = library.backupDirectoryURL()
        // Ensure the directory exists before opening
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func performRestore(from url: URL) {
        restoreError = nil
        do {
            try library.restoreFromBackup(url)
            lastBackupMessage = "Library restored successfully"
            refreshBackups()
        } catch {
            restoreError = "Restore failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Library Location Settings

struct LibraryLocationSettingsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var currentPath: String = FileStore.shared.baseDirectory.path
    @State private var isCustomLocation: Bool = false
    @State private var librarySize: String = "Calculating..."
    @State private var isMoving = false
    @State private var moveProgress: String?
    @State private var moveError: String?
    @State private var moveSuccess: String?
    @State private var showMoveConfirmation = false
    @State private var pendingNewURL: URL?
    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("Library Location")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Choose where your audio library and metadata are stored")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top)

                Divider()

                // Current Location
                VStack(alignment: .leading, spacing: 16) {
                    Text("Current Location")
                        .font(.headline)

                    HStack(spacing: 12) {
                        Image(systemName: isCustomLocation ? "externaldrive" : "internaldrive")
                            .font(.title2)
                            .foregroundColor(isCustomLocation ? .blue : .secondary)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentPath)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)

                            HStack(spacing: 12) {
                                Text(librarySize)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if isCustomLocation {
                                    Text("Custom Location")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.2))
                                        .foregroundColor(.blue)
                                        .cornerRadius(4)
                                } else {
                                    Text("Default")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.gray.opacity(0.2))
                                        .foregroundColor(.secondary)
                                        .cornerRadius(4)
                                }
                            }
                        }

                        Spacer()

                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: currentPath)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(8)
                }

                Divider()

                // Move Library
                VStack(alignment: .leading, spacing: 16) {
                    Text("Move Library")
                        .font(.headline)

                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Move your entire audio library to a different location, such as an external drive. All audio files, artwork, and metadata will be moved. The app will use the new location going forward.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)

                    HStack(spacing: 12) {
                        Button(action: chooseNewLocation) {
                            HStack {
                                Image(systemName: "folder.badge.plus")
                                Text("Choose New Location...")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isMoving)

                        if isCustomLocation {
                            Button(action: { showResetConfirmation = true }) {
                                HStack {
                                    Image(systemName: "arrow.uturn.backward")
                                    Text("Reset to Default")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isMoving)
                        }
                    }

                    if isMoving {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(moveProgress ?? "Moving library...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                    }

                    if let error = moveError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    }

                    if let success = moveSuccess {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(success)
                                .font(.caption)
                        }
                        .padding(8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                    }
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refreshInfo()
        }
        .alert("Move Library", isPresented: $showMoveConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingNewURL = nil
            }
            Button("Move Library") {
                if let url = pendingNewURL {
                    performMove(to: url)
                }
                pendingNewURL = nil
            }
        } message: {
            if let url = pendingNewURL {
                Text("This will move your entire audio library (\(librarySize)) to:\n\n\(url.path)\n\nThe app will use the new location immediately. This may take a while for large libraries.")
            }
        }
        .alert("Reset to Default Location", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Move Back to Default", role: .destructive) {
                performMove(to: FileStore.defaultBaseDirectory)
            }
        } message: {
            Text("This will move your library back to the default location in Application Support. All files will be moved from the current custom location.")
        }
    }

    private func refreshInfo() {
        currentPath = FileStore.shared.baseDirectory.path
        isCustomLocation = FileStore.shared.isUsingCustomLocation

        // Calculate size in background
        DispatchQueue.global(qos: .userInitiated).async {
            let size = Self.calculateDirectorySize(at: FileStore.shared.baseDirectory)
            let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            DispatchQueue.main.async {
                librarySize = formatted
            }
        }
    }

    private func chooseNewLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose Library Location"
        panel.message = "Select a folder where your Majik's Music Studio library will be stored. A 'MajiksMusicStudio' folder will be created inside."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let selectedURL = panel.url {
            let newBase = selectedURL.appendingPathComponent("MajiksMusicStudio", isDirectory: true)
            if newBase.path == FileStore.shared.baseDirectory.path {
                moveError = "That's already the current library location."
                return
            }
            pendingNewURL = newBase
            showMoveConfirmation = true
        }
    }

    private func performMove(to newURL: URL) {
        isMoving = true
        moveError = nil
        moveSuccess = nil
        moveProgress = "Moving audio files..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileStore.shared.relocateLibrary(to: newURL)

                DispatchQueue.main.async {
                    // Reload the library from the new location
                    library.load()
                    isMoving = false
                    moveSuccess = "Library moved successfully to \(newURL.path)"
                    moveProgress = nil
                    refreshInfo()
                }
            } catch {
                DispatchQueue.main.async {
                    isMoving = false
                    moveError = "Move failed: \(error.localizedDescription)"
                    moveProgress = nil
                }
            }
        }
    }

    private nonisolated static func calculateDirectorySize(at url: URL) -> Int64 {
        var totalSize: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  let isDir = values.isDirectory, !isDir,
                  let size = values.fileSize else { continue }
            totalSize += Int64(size)
        }
        return totalSize
    }
}
