import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// THE TRANSPORT ROW'S OWN INVARIANT, ON THE ONE CHIP THAT BROKE IT.
//
// `StudioTransportBar` opens with this, and it is not decoration — it is a
// post-mortem:
//
//     "EVERY `Text` IN THIS BAR IS `lineLimit(1)` + `fixedSize`, AND THAT IS
//      STRUCTURAL, NOT COSMETIC. A bare `Text` in an `HStack` is horizontally
//      flexible: offered less width than it wants, it does not truncate, it
//      WRAPS. At the limit it wraps to one character per line… In 3.4.8
//      "POSITION" and "Generate" each wrapped into a vertical column, the
//      toolbar row grew to ~475 pt, and the browser, tracks and inspector were
//      squeezed into the bottom third of the window under a black void."
//
// `StudioSaveIndicator` sits in that row (`StudioTransportBar.body`) and its
// `Text(label)` carried NEITHER. It arrived from a different lane, in a
// different file, so the claim in the header above went on being written down
// while it stopped being true.
//
// This is measured, not asserted about source: the indicator is rendered
// through `ImageRenderer` — the deterministic no-window path — squeezed into a
// width narrower than its own text, and the question asked is the one that
// matters: did it get TALLER?

@MainActor
final class StudioSaveIndicatorWidthTests: XCTestCase {

    private func renderedSize<V: View>(_ view: V) -> CGSize? {
        ImageRenderer(content: view.environment(\.colorScheme, .dark)).nsImage?.size
    }

    /// Under width pressure the chip must keep its height. A wrapped label is
    /// not a cosmetic problem here — the row it is in has a fixed 52 pt height
    /// and is the first child of the shell's root `VStack`, so anything it
    /// steals comes out of the timeline.
    func testTheSaveChipDoesNotGrowTallerWhenTheRowIsTight() throws {
        // The saver's initializer is private and this test never mutates it —
        // it only draws whatever word the chip currently reads, which is the
        // thing under measurement.
        let chip = StudioSaveIndicator(saver: .shared)

        let relaxed = try XCTUnwrap(renderedSize(chip), "the chip rendered at its ideal size")
        // 24 pt is narrower than the word the chip draws, which is exactly the
        // condition the transport row puts it under when the window is small
        // or the other readouts are wide.
        let squeezed = try XCTUnwrap(renderedSize(chip.frame(width: 24)))

        XCTAssertLessThanOrEqual(
            squeezed.height, relaxed.height + 1,
            """
            squeezed to 24 pt the save chip grew from \(relaxed.height) pt to \
            \(squeezed.height) pt tall: its label WRAPPED. The transport row's own \
            header claims every Text in it is lineLimit(1) + fixedSize, and this is \
            the 3.4.8 toolbar-explosion shape.
            """)
        XCTAssertGreaterThan(relaxed.height, 0, "the chip drew something")
    }
}
