import AppKit
import SwiftUI

// MARK: - The thing you drag
//
// The view half of pane resizing; the rules and the persistence are in
// StudioPaneSizing.swift.
//
// A divider nobody can find is not a feature, so this is three things at once:
//
//  * a HIT BAND wider than the line it draws (`StudioTokens.dividerHit`), because
//    a 1 pt target is a 1 pt target whether or not it is beautiful, and this app
//    is used from a sofa;
//  * a CURSOR change on hover, which on macOS is the only universal "this edge
//    moves" signal there is;
//  * a HAIRLINE that is always visible and brightens under the pointer, so the
//    edge reads as a control before you touch it rather than after.
//
// Double-click puts the pane back to the size it shipped with. That is the
// escape hatch for someone who has dragged themselves into a corner, and it
// costs one gesture to offer.
//
// Deliberately NOT a Button and deliberately not inside any ScrollView. A
// horizontal ScrollView on macOS claims the mouse-down as a possible pan and
// silently eats the press — the failure that made the Settings tab strip and
// the mixer strips read as dead (see SettingsView.swift). A drag handle inside
// one would never move at all.

struct StudioPaneDivider: View {
    let spec: StudioPaneSizeSpec
    @ObservedObject var sizes: StudioPaneSizes
    /// The ceiling the window imposes right now: what is left of the workspace
    /// once the other visible panes and the timeline's floor are accounted for.
    /// nil until the shell has been measured (one layout pass at launch).
    var available: CGFloat?

    @State private var hovering = false
    /// The pane's size when the current drag started.
    ///
    /// The gesture translation is measured from mouse-down, so the size has to
    /// be too. Adding each frame's translation to the CURRENT size instead
    /// would compound it and the pane would accelerate away from the pointer.
    @State private var dragOrigin: CGFloat?

    private var isActive: Bool { hovering || dragOrigin != nil }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(
                width: spec.axis == .horizontal ? StudioTokens.dividerHit : nil,
                height: spec.axis == .vertical ? StudioTokens.dividerHit : nil)
            // Explicit about flexibility on BOTH axes. A child that is flexible
            // on an axis takes space from its siblings silently — that is how
            // the transport bar grew to 475 pt and squeezed every pane below it
            // into the bottom third of the window (see
            // `StudioTransportBar.readout(value:caption:)`). The divider is
            // FIXED across the drag axis and fills the other one, and says so.
            .frame(
                maxWidth: spec.axis == .horizontal ? StudioTokens.dividerHit : .infinity,
                maxHeight: spec.axis == .vertical ? StudioTokens.dividerHit : .infinity)
            .overlay(hairline)
            .background(isActive ? StudioTokens.cyan.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
            .onHover { inside in
                // Guarded so a re-entered hover cannot push twice and leave the
                // resize cursor stuck on after the pointer has left.
                guard inside != hovering else { return }
                hovering = inside
                if inside { cursor.push() } else { NSCursor.pop() }
            }
            .gesture(drag)
            // Simultaneous rather than layered: a double-click and a drag are
            // mutually exclusive in practice (the drag needs a point of travel
            // before it starts), so there is nothing to arbitrate, and this
            // avoids the ordering guesswork that makes one of the two dead.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { sizes.reset(spec) })
            .studioHelp(spec.helpID)
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue("\(Int(sizes.size(of: spec, available: available).rounded())) points")
            // Resizable without a mouse. VoiceOver users and anyone driving the
            // app from the keyboard get the same control, in the same steps.
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 16
                let current = sizes.size(of: spec, available: available)
                switch direction {
                case .increment: sizes.set(current + step, for: spec, available: available)
                case .decrement: sizes.set(current - step, for: spec, available: available)
                @unknown default: break
                }
            }
    }

    // MARK: The line

    private var hairline: some View {
        Rectangle()
            .fill(isActive ? StudioTokens.cyan : StudioTokens.strokeSoft)
            .frame(
                width: spec.axis == .horizontal ? (isActive ? 2 : 1) : nil,
                height: spec.axis == .vertical ? (isActive ? 2 : 1) : nil)
    }

    private var cursor: NSCursor {
        spec.axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    private var accessibilityLabel: String {
        switch spec.axis {
        case .horizontal: return "Resize the \(spec.id) panel's width"
        case .vertical: return "Resize the \(spec.id) panel's height"
        }
    }

    // MARK: The drag

    private var drag: some Gesture {
        // GLOBAL coordinate space on purpose. The divider MOVES as the pane it
        // resizes changes size, so a local translation would be measured
        // against a frame that the previous frame's drag just shifted — the
        // pane would run away from the pointer or stall against it. A global
        // translation is measured from where the mouse went down and is immune
        // to that feedback.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let origin = dragOrigin ?? sizes.size(of: spec, available: available)
                if dragOrigin == nil { dragOrigin = origin }
                let travel = spec.axis == .horizontal
                    ? value.translation.width
                    : value.translation.height
                sizes.set(
                    origin + travel * spec.growth.rawValue,
                    for: spec, available: available)
            }
            .onEnded { _ in dragOrigin = nil }
    }
}

// MARK: - Measuring the room the panes are dividing up

/// The size of the workspace row (everything below the transport and record
/// strips). Read by `StudioRootView` and handed to every divider, so a drag can
/// be stopped BEFORE the timeline is squeezed to nothing rather than after.
///
/// Measured on the CONTAINER, whose size comes from the window and never from
/// its children, so — unlike the mixer dock's overflow measurement, which had
/// to be taken on the row's ideal width to avoid feeding back on itself —
/// there is no loop here to design around.
struct StudioWorkspaceSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
