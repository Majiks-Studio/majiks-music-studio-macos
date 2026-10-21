import CoreGraphics
import Foundation

// MARK: - How big each Studio pane is, and who is allowed to change it
//
// The Studio shell shipped with every pane at a fixed size: the browser 172 pt,
// the inspector 272, Sterling's dock 320, the piano roll and the routing pane
// 300 tall, the keyboard 132. Those numbers were chosen once, on one machine.
// The person who owns this product uses it on a 4K TV from a sofa AND on a
// laptop, and the split that is right for one is wrong for the other — on the
// TV the browser is a postage stamp, on the laptop Sterling's dock is a third
// of the window. A fixed layout cannot serve both, so the sizes become the
// user's.
//
// This file is the STATE half: the specs, the clamping, and the store. It has
// no SwiftUI in it, which is the same three-part split the piano roll and the
// on-screen keyboard use (math / controller / view) and for the same reason —
// everything a test needs to drive lives in a file a test can import without a
// window. The drag affordance itself is StudioPaneDivider.swift.
//
// Two things are deliberately NOT here:
//
//  * No wire command, and nothing in project.json. A pane's width is a property
//    of the person looking at the screen, not of the song. Journaling it would
//    put "I made the browser wider" in the undo history next to "I deleted a
//    track", and would travel with a .mstudio package to a machine with a
//    different screen.
//  * No new persistence mechanism. UserDefaults, the same store the Studio
//    already keeps `studio.copilotOpen`, `studio.coachMarksSeen.v1` and the
//    help verbosity in, with the same `studio.*.v1` versioned-key convention.

/// Which way a pane is resized.
enum StudioPaneAxis: Sendable {
    /// A side rail: the divider runs vertically, the drag changes a WIDTH.
    case horizontal
    /// A bottom pane: the divider runs horizontally, the drag changes a HEIGHT.
    case vertical
}

/// Which way a positive drag translation moves a pane's size.
///
/// The browser's divider is on its trailing edge, so dragging right makes it
/// wider. The inspector's and Sterling's are on their LEADING edge, so the same
/// drag makes them narrower. Every bottom pane's divider sits on its top edge,
/// so dragging down makes it shorter. Getting this backwards is the classic
/// resizable-pane bug and it is not something a build can catch, so it is a
/// value on the spec rather than a sign buried in a gesture handler.
enum StudioPaneGrowth: CGFloat, Sendable {
    /// A positive translation (right / down) grows the pane.
    case withDrag = 1
    /// A positive translation (right / down) shrinks the pane.
    case againstDrag = -1
}

// MARK: - One pane's size rules

/// Everything about one resizable pane except its pixels.
struct StudioPaneSizeSpec: Identifiable, Hashable, Sendable {
    /// Short name, used in test failures and as the tail of the storage key.
    let id: String
    /// The UserDefaults key. Versioned, so a future change to what the number
    /// MEANS gets a new key rather than silently reinterpreting a stored value
    /// (the same rule `StudioHelpVerbosity.storageKey` follows).
    let key: String
    let axis: StudioPaneAxis
    let growth: StudioPaneGrowth
    /// Where a double-click on the divider puts the pane back to.
    let defaultSize: CGFloat
    /// The pane can never be dragged smaller than this. Collapsing is a
    /// different gesture with its own control (the toolbar toggles, the mixer's
    /// chevron); a drag CLAMPS, it never collapses. A pane that vanished under
    /// the pointer would read as a crash.
    let minimum: CGFloat
    /// The hard ceiling, whatever the screen. A separate, tighter ceiling comes
    /// from the window at run time — see `available(for:workspace:otherVisible:)`.
    let maximum: CGFloat
    /// The catalog id for the divider's hover help.
    let helpID: String

    /// The one place a number becomes a legal size.
    ///
    /// `available` is the room the window has left for this pane right now; nil
    /// means "not measured yet", which happens for exactly one layout pass at
    /// launch and must not be read as "no room".
    func clamp(_ value: CGFloat, available: CGFloat? = nil) -> CGFloat {
        // A NaN reaches this from a gesture whose start point was never
        // recorded, and NaN survives min/max silently — it would be stored, and
        // the pane would come back from the next launch with no size at all.
        guard value.isFinite else { return defaultSize }
        var ceiling = maximum
        if let available, available.isFinite {
            // The window's limit can never push a pane below its own minimum:
            // at that point the layout is out of room and something has to
            // overflow, and a pane collapsed to nothing is the worse failure.
            ceiling = Swift.min(ceiling, Swift.max(minimum, available))
        }
        return Swift.min(Swift.max(value, minimum), ceiling)
    }
}

// MARK: - The panes

enum StudioPaneSizing {
    // MARK: Side rails (widths)
    //
    // Defaults are the numbers the shell already used, so nothing moves for a
    // user who never touches a divider. The minima are "still readable": a
    // browser under ~120 pt cannot show a song title, an inspector under
    // ~180 pt wraps every readout, Sterling under ~240 pt cannot hold a line of
    // chat.

    static let browser = StudioPaneSizeSpec(
        id: "browser",
        key: "studio.pane.browserWidth.v1",
        axis: .horizontal, growth: .withDrag,
        defaultSize: StudioTokens.browserWidth, minimum: 120, maximum: 480,
        helpID: "layout.divider.browser")

    static let inspector = StudioPaneSizeSpec(
        id: "inspector",
        key: "studio.pane.inspectorWidth.v1",
        axis: .horizontal, growth: .againstDrag,
        defaultSize: StudioTokens.inspectorWidth, minimum: 180, maximum: 560,
        helpID: "layout.divider.inspector")

    static let copilot = StudioPaneSizeSpec(
        id: "copilot",
        key: "studio.pane.copilotWidth.v1",
        axis: .horizontal, growth: .againstDrag,
        defaultSize: StudioCopilotDock.width, minimum: 240, maximum: 640,
        helpID: "layout.divider.copilot")

    // MARK: Bottom panes (heights)

    static let pianoRoll = StudioPaneSizeSpec(
        id: "pianoRoll",
        key: "studio.pane.pianoRollHeight.v1",
        axis: .vertical, growth: .againstDrag,
        // 160 is the roll's 32 pt toolbar plus four rows of keys — the least
        // that is still a note editor rather than a sliver.
        defaultSize: StudioPianoRollPane.defaultHeight, minimum: 160, maximum: 900,
        helpID: "layout.divider.pianoRoll")

    /// The routing pane's minimum is NOT a taste judgement. Its header, focus
    /// row, chain strip and the two hairlines are fixed at
    /// 30 + 26 + 62 + 2 = 120 pt, and everything that can grow (the parameter
    /// grid, the send list) lives in what is left. `StudioRoutingPaneTests`
    /// already pins that the DEFAULT height leaves more than 120 pt of scroll
    /// region; a drag must not be allowed to take that away, or the parameter
    /// grid gets zero height and vanishes — which is the same class of bug as
    /// the mixer's clipped M / S buttons, arrived at by dragging instead of by
    /// a bad constant.
    static let routingFixedRows: CGFloat = 120
    static let routingScrollFloor: CGFloat = 120

    static let routing = StudioPaneSizeSpec(
        id: "routing",
        key: "studio.pane.routingHeight.v1",
        axis: .vertical, growth: .againstDrag,
        defaultSize: StudioRoutingPane.paneHeight,
        minimum: 260, maximum: 900,
        helpID: "layout.divider.routing")

    /// The mixer's minimum is its CONTENT height, not a taste judgement either.
    /// A channel strip is 258 pt of fixed layout and the dock clips rather than
    /// scrolls, so a dock shorter than `StudioMixerDock.dockHeight` does not
    /// show a smaller mixer — it stops drawing the bottom of every strip, and
    /// the M / S buttons become unclickable. That shipped once and cost months;
    /// `StudioMixerDockTests` guards the constant, and this guards the drag.
    ///
    /// The honest consequence, written down rather than glossed: the mixer is
    /// effectively GROW-ONLY, and the extra height is empty panel below the
    /// strips, because a strip has a fixed intrinsic height and nothing in it
    /// stretches. Making the fader absorb the slack is a real improvement and a
    /// different lane; it touches the ImageRenderer height tests.
    static let mixer = StudioPaneSizeSpec(
        id: "mixer",
        key: "studio.pane.mixerHeight.v1",
        axis: .vertical, growth: .againstDrag,
        defaultSize: StudioMixerDock.dockHeight,
        minimum: StudioMixerDock.dockHeight, maximum: 720,
        helpID: "layout.divider.mixer")

    static let keyboard = StudioPaneSizeSpec(
        id: "keyboard",
        key: "studio.pane.keyboardHeight.v1",
        axis: .vertical, growth: .againstDrag,
        // The control rail (Keep, octave, span, velocity) needs ~96 pt before
        // it starts hiding its own buttons.
        defaultSize: StudioOnScreenKeyboardPane.defaultHeight, minimum: 96, maximum: 420,
        helpID: "layout.divider.keyboard")

    static let all: [StudioPaneSizeSpec] = [
        browser, inspector, copilot, pianoRoll, routing, mixer, keyboard,
    ]

    // MARK: What the window has left

    /// The slack-absorbing views' floors.
    ///
    /// The whole point of the horizontal axis is that the CENTRE column takes
    /// the slack, and of the vertical axis that the TIMELINE does. A pane
    /// dragged until the thing it was supposed to leave room for is zero pt
    /// tall has swallowed the window, which is exactly what min/max are for —
    /// so the ceiling is not a fixed number, it is what is left.
    ///
    /// Width: the track-header column (150) plus enough canvas to see a bar.
    static let centreColumnFloor: CGFloat = 320
    /// Height: section ruler (22) + bar ruler (16) + loop strip (14) + one
    /// default-height track (90), rounded up. Below this the timeline is a
    /// ruler with no music under it.
    static let timelineFloor: CGFloat = 160

    static func floor(for axis: StudioPaneAxis) -> CGFloat {
        switch axis {
        case .horizontal: return centreColumnFloor
        case .vertical: return timelineFloor
        }
    }

    /// The largest `spec` may be right now: the workspace, less every OTHER
    /// visible pane on the same axis, less the floor the timeline (or the
    /// centre column) is owed.
    ///
    /// `workspace` of zero means the shell has not been measured yet — one
    /// layout pass at launch — and returns the spec's own ceiling rather than
    /// a bogus tiny one, so panes do not visibly snap on the first frame.
    static func available(
        for spec: StudioPaneSizeSpec,
        workspace: CGSize,
        otherVisible: CGFloat
    ) -> CGFloat {
        let extent = spec.axis == .horizontal ? workspace.width : workspace.height
        guard extent > 0, extent.isFinite else { return spec.maximum }
        return Swift.max(spec.minimum, extent - otherVisible - floor(for: spec.axis))
    }
}

// MARK: - The store

/// Every pane's current size, persisted.
///
/// `UserDefaults` rather than `@AppStorage` for one reason, and it is the
/// reason the mutation table in this lane means anything: `@AppStorage` can
/// only be pointed at a different store by re-declaring every key, so a test
/// written against it would either scribble on the developer's real
/// preferences or test a copy of the arithmetic instead of the code the app
/// runs. This type IS the code the app runs, and a test hands it a throwaway
/// suite. The mechanism underneath is identical — the same `UserDefaults`,
/// the same versioned `studio.*.v1` keys as `studio.copilotOpen` and
/// `studio.coachMarksSeen.v1`.
@MainActor
final class StudioPaneSizes: ObservableObject {
    static let shared = StudioPaneSizes()

    private let defaults: UserDefaults
    /// Read-through cache. A drag re-reads every visible pane's size on each
    /// frame of the gesture; UserDefaults is fast but this keeps a 60 Hz drag
    /// off it entirely. Writes go through to `defaults` immediately, so the
    /// cache can never be the only copy of a size.
    private var cache: [String: CGFloat] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// This pane's size, clamped. Never writes: merely rendering on a small
    /// window must not shrink a size the user chose on a big one.
    func size(of spec: StudioPaneSizeSpec, available: CGFloat? = nil) -> CGFloat {
        spec.clamp(stored(spec), available: available)
    }

    /// Set this pane's size from a drag. Clamps first, then persists.
    func set(_ size: CGFloat, for spec: StudioPaneSizeSpec, available: CGFloat? = nil) {
        let clamped = spec.clamp(size, available: available)
        guard clamped != stored(spec) else { return }   // no redraw for a no-op drag frame
        cache[spec.key] = clamped
        defaults.set(Double(clamped), forKey: spec.key)
        objectWillChange.send()
    }

    /// Double-click on a divider: back to the shipped size.
    ///
    /// Removes the key rather than writing the default, so "never touched" and
    /// "put back" are the same stored state — a later change to a default then
    /// reaches a user who had reset, which is what they asked for.
    func reset(_ spec: StudioPaneSizeSpec) {
        cache[spec.key] = nil
        defaults.removeObject(forKey: spec.key)
        objectWillChange.send()
    }

    /// True when this pane still has whatever size it shipped with.
    func isDefault(_ spec: StudioPaneSizeSpec) -> Bool {
        defaults.object(forKey: spec.key) == nil
    }

    func resetAll() {
        for spec in StudioPaneSizing.all { reset(spec) }
    }

    /// The raw stored number, or the default when nothing (or something
    /// unreadable — a string written by an older build, a hand-edited plist)
    /// is there. Unclamped on purpose: clamping is `spec.clamp`'s job and
    /// happens on every read AND every write, so there is one rule, not two.
    private func stored(_ spec: StudioPaneSizeSpec) -> CGFloat {
        if let cached = cache[spec.key] { return cached }
        guard let raw = defaults.object(forKey: spec.key) as? Double else {
            return spec.defaultSize
        }
        let value = CGFloat(raw)
        cache[spec.key] = value
        return value
    }
}
