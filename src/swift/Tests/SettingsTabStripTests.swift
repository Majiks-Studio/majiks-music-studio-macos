import XCTest
import SwiftUI
import AppKit
@testable import MajiksMusicStudio

// The Settings tab strip, held to the claim its own comment makes.
//
// This surface is where the "a horizontal ScrollView eats Button clicks on
// macOS" failure was FIRST written down in this repo — the strip's non-scrolling
// branch already carried the comment "made the tabs feel dead / require
// pixel-perfect clicks". What it kept was the other branch: a `ScrollView` used
// as an overflow fallback behind `contentWidth > containerWidth`.
//
// `StudioMixerDock` then paid for exactly that shape twice. `607e7ac` removed
// the mixer's ScrollView and left it as an overflow fallback; `5d8491d` widened
// a channel strip 112 -> 173 pt, which lowered the overflow threshold far enough
// that an ordinary three-track session re-armed the fallback, and the Mute and
// Solo chips went dead again — through a fully green suite of 487 tests.
//
// Here the trigger is a longer tab word, a larger dynamic-type setting or a
// narrower window. Nobody re-tests the Settings tabs after renaming a tab.
//
// ⚠️ WHAT CAN AND CANNOT BE PROVEN HERE, stated so nobody re-derives it:
//
//   * `ImageRenderer` CANNOT answer this. It rasterises; it never builds a
//     responder chain, and a trapped button draws identically to a free one.
//   * `NSHostingView.hitTest(_:)` CANNOT answer it either: it returns the
//     hosting view ITSELF for every point inside it, because SwiftUI dispatches
//     events through its own display list rather than the AppKit responder
//     tree. There is no way in this process to deliver a click to a tab and
//     watch it arrive.
//   * What IS observable is the thing that does the swallowing. SwiftUI's
//     `ScrollView` becomes a real `HostingScrollView` / `NSClipView` pair in the
//     rendered AppKit hierarchy, and each control becomes a real
//     `_NSShapeHitTestingView`. The provable, load-bearing claim is STRUCTURAL:
//     is the swallowing view between the control and the host.
//
// Every detector below is CALIBRATED with a positive AND a negative control
// before it is trusted, and every "no scroll view" assertion is fenced by a
// population floor that is itself shown to reject an empty render — because a
// detector that has gone blind reports perfect health, which is how this bug
// shipped twice already.

@MainActor
final class SettingsTabStripTests: XCTestCase {

    // MARK: - The detector (same shape as StudioMixerHitTestingTests, and
    // deliberately its own copy: this file must still be able to see the
    // failure if a future lane edits the mixer's helpers)

    private func requireAppKit() { _ = NSApplication.shared }

    /// Lay a SwiftUI view out through the real AppKit path, detached from any
    /// window. An `NSHostingView` with no superview and no window draws
    /// nowhere: no lane may launch this app's GUI.
    private func laidOut(_ view: some View, width: CGFloat, height: CGFloat) -> NSView {
        requireAppKit()
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        // Twice, deliberately: SwiftUI materialises its platform views lazily
        // during layout, and a nested scroll view only appears once its content
        // has been measured.
        host.layoutSubtreeIfNeeded()
        host.layout()
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Every scroll view in a laid-out hierarchy. `NSClipView` counts: it is the
    /// half that actually sits in front of the content and takes the click.
    private func scrollViews(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        if view is NSScrollView || view is NSClipView { found.append(view) }
        for sub in view.subviews { found.append(contentsOf: scrollViews(in: sub)) }
        return found
    }

    private func describe(_ views: [NSView]) -> String {
        views.map { String(describing: type(of: $0)) }.sorted().joined(separator: ", ")
    }

    /// Both spellings, because they are button-STYLE dependent and this must not
    /// be: a `.buttonStyle(.plain)` Button becomes a `_NSShapeHitTestingView`,
    /// a default-styled one a `SwiftUIAppKitButton`. A detector that knew only
    /// one would go quiet the day someone restyled a tab.
    private static let controlViewMarkers = ["HitTesting", "AppKitButton"]

    private func controlHitViews(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        let name = String(describing: type(of: view))
        if Self.controlViewMarkers.contains(where: { name.contains($0) }) { found.append(view) }
        for sub in view.subviews { found.append(contentsOf: controlHitViews(in: sub)) }
        return found
    }

    /// Every control with a scroll view somewhere between it and the host —
    /// i.e. every control whose mouse-down would be claimed as a pan.
    private func controlsBehindAScrollView(in host: NSView) -> [NSView] {
        controlHitViews(in: host).filter { control in
            var v: NSView = control
            while let parent = v.superview, v !== host {
                if parent is NSScrollView || parent is NSClipView { return true }
                v = parent
            }
            return false
        }
    }

    // MARK: - Calibration

    /// POSITIVE CONTROL. The strip's own row, wrapped the way this file used to
    /// wrap it, hosted too narrow to fit. If this stops finding a scroll view
    /// the detector has gone blind and every "no scroll view" result below is
    /// vacuous.
    func testTheDetectorSeesAHorizontalScrollViewWhenThereIsOne() {
        let probe = ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(SettingsView.tabs) { tab in
                    Button(tab.title) {}.buttonStyle(.plain).padding(.horizontal, 14)
                }
            }
        }
        let host = laidOut(probe, width: 300, height: 60)
        XCTAssertFalse(
            scrollViews(in: host).isEmpty,
            """
            The scroll-view detector found nothing in a hierarchy that IS a \
            ScrollView. Every other assertion in this file is now vacuous. Do \
            not delete this test to go green — fix the detector.
            """)
    }

    /// SECOND POSITIVE CONTROL, for the ANCESTRY probe rather than the presence
    /// one. Deliberately a DEFAULT-styled row: measured on the mixer and true
    /// here too — inside a windowless scroll view SwiftUI materialises AppKit
    /// views for default-styled buttons but not for `.plain` ones. So for a
    /// `.plain` strip the PRESENCE of the scroll view is the load-bearing
    /// evidence, and this test is what shows the ancestry probe is not simply
    /// broken.
    func testTheAncestryProbeReportsAControlTrappedInsideAScrollView() {
        let probe = ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { i in
                    Button("Tab \(i)") {}.frame(width: 140, height: 30)
                }
            }
        }
        let host = laidOut(probe, width: 300, height: 60)
        let controls = controlHitViews(in: host)
        XCTAssertFalse(
            controls.isEmpty,
            "no control views were found inside a row of twelve Buttons, so the population probe is blind")
        XCTAssertEqual(
            controlsBehindAScrollView(in: host).count, controls.count,
            "controls inside a real ScrollView were not reported as being behind one")
    }

    /// NEGATIVE CONTROL. The same row without the wrapper. If this found a
    /// scroll view the detector would be an always-true assertion.
    func testTheDetectorSeesNoScrollViewInAPlainRow() {
        let probe = HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { i in
                Button("Tab \(i)") {}.frame(width: 140, height: 30)
            }
        }
        let host = laidOut(probe, width: 300, height: 60)
        XCTAssertTrue(
            scrollViews(in: host).isEmpty,
            "the detector reports a scroll view in a plain HStack: \(describe(scrollViews(in: host)))")
        XCTAssertFalse(controlHitViews(in: host).isEmpty,
                       "the plain row rendered no controls, so the negative control proves nothing")
        XCTAssertTrue(controlsBehindAScrollView(in: host).isEmpty)
    }

    // MARK: - The strip, rendered

    private func strip(_ tabs: [SettingsTabDescriptor] = SettingsView.tabs) -> some View {
        SettingsTabStrip(selection: .constant(0), tabs: tabs)
    }

    /// The chevrons draw whatever the tab count is, so they are the population a
    /// strip that rendered NO tabs still has. Measured at the same width as the
    /// render under test rather than pinned: how many AppKit views one SwiftUI
    /// Button materialises is not a number this file should be asserting.
    private func chevronOnlyControlCount(width: CGFloat) -> Int {
        controlHitViews(in: laidOut(strip([]), width: width,
                                    height: SettingsTabStrip.rowHeight + 20)).count
    }

    /// ⚠️ MEASURED, and it sets the shape of every floor below: SwiftUI only
    /// materialises an AppKit hit-test view for a control that is actually
    /// VISIBLE inside the clip. The nine-tab strip reports 5 controls at 200 pt,
    /// 7 at 400 pt, 9 at 700 pt and 11 once the row fits (its ideal width is
    /// 1010). So "all nine tabs have AppKit views" is simply FALSE at a narrow
    /// width, and a floor of `tabs + 2` would fail on correct code — it did,
    /// first time out. The floor that holds at every width is "more than a strip
    /// with no tabs at all draws", which is self-calibrating.
    ///
    /// This is also why the PRESENCE of a scroll view — not the ancestry of the
    /// controls — is the load-bearing evidence in this file: a regression that
    /// re-wrapped the row would take the off-screen controls out of the
    /// hierarchy entirely, and an ancestry probe cannot report on a view that
    /// does not exist.
    private func renderedStrip(width: CGFloat) throws -> NSView {
        let host = laidOut(strip(), width: width, height: SettingsTabStrip.rowHeight + 20)
        let controls = controlHitViews(in: host)
        XCTAssertGreaterThan(
            controls.count, chevronOnlyControlCount(width: width),
            """
            the strip at \(Int(width)) pt rendered \(controls.count) controls, no more than \
            a strip with NO TABS draws at the same width. Not one tab drew, so anything \
            this render is asked about is answered vacuously.
            """)
        return host
    }

    /// The floor above is itself calibrated here, because a floor nobody has
    /// shown rejecting anything is decoration — the mixer lane's first draft
    /// rendered a COLLAPSED dock (no strips at all) and every "no scroll view"
    /// assertion in it was true of an empty picture.
    func testAnEmptyStripFallsUnderTheFloorTheOtherTestsRelyOn() {
        let ideal = measuredRowWidth()
        // At a width where every tab fits, a strip with no tabs must be well
        // under the full population — otherwise the floor accepts a strip that
        // drew nothing.
        let emptyWide = chevronOnlyControlCount(width: ideal + 120)
        XCTAssertLessThan(
            emptyWide, SettingsView.tabs.count,
            "a strip with NO tabs drew \(emptyWide) controls, as many as nine tabs would, so no population floor built on this can tell the two apart")

        for width in [200.0, 400.0, 700.0, ideal + 120] as [CGFloat] {
            let full = controlHitViews(in: laidOut(strip(), width: width,
                                                   height: SettingsTabStrip.rowHeight + 20)).count
            XCTAssertGreaterThan(
                full, chevronOnlyControlCount(width: width),
                "at \(Int(width)) pt the nine-tab strip drew no more controls than the empty one, so the strip is not drawing its tabs in this harness at all")
        }
    }

    /// The full population, asserted where it is actually true: a window wide
    /// enough for the whole row. This is the claim `renderedStrip`'s
    /// self-calibrating floor deliberately does not make — without it, "more
    /// than an empty strip" would be satisfied by a strip that drew one tab and
    /// stopped.
    func testEveryTabDrawsWhenTheWindowIsWideEnoughForTheRow() {
        let host = laidOut(strip(), width: measuredRowWidth() + 120,
                           height: SettingsTabStrip.rowHeight + 20)
        let count = controlHitViews(in: host).count
        XCTAssertGreaterThanOrEqual(
            count, SettingsView.tabs.count + 2,
            """
            a window wide enough for the whole row drew \(count) controls, fewer than \
            \(SettingsView.tabs.count) tabs plus two chevrons. A tab that never draws is a \
            tab nobody can click, whatever the scroll-view assertions say.
            """)
    }

    /// Widening the window draws MORE tabs, all the way to the whole row. This
    /// is what says the tabs are per-row controls rather than a fixed handful
    /// that happens to clear a floor.
    func testWideningTheWindowBringsMoreTabsIntoExistence() {
        let ideal = measuredRowWidth()
        let counts = [200.0, 500.0, ideal + 120].map { (w: CGFloat) in
            controlHitViews(in: laidOut(strip(), width: w,
                                        height: SettingsTabStrip.rowHeight + 20)).count
        }
        XCTAssertLessThan(counts[0], counts[1],
                          "going from 200 pt to 500 pt drew no extra tabs (\(counts)), so the row is not laying out per tab")
        XCTAssertLessThan(counts[1], counts[2],
                          "a window wide enough for the whole row drew no more tabs than a 500 pt one (\(counts))")
    }

    // MARK: - THE regression test

    /// The headline. The widths sweep from a quarter of the row's ideal width
    /// to twice it, so the overflow state — the exact state the deleted
    /// conditional used to switch on — is forced on, repeatedly, and this test
    /// fails by name while nothing else notices.
    ///
    /// The widths are DERIVED from the strip's own measured row rather than
    /// listed, so widening a tab (a longer word, a larger font) cannot outrun
    /// the sweep. A pinned "300 pt" would quietly stop covering overflow the
    /// day the row got wider, which is the mechanical form of the mixer's
    /// 112 -> 173 regression.
    func testTheSettingsTabsAreNeverInsideAHorizontalScrollViewAtAnyWidth() throws {
        let ideal = measuredRowWidth()
        XCTAssertGreaterThan(ideal, 0, "the row measured no width, so this sweep straddles nothing")

        for width in [ideal * 0.25, ideal * 0.5, ideal * 0.75, ideal, ideal * 2] {
            let host = try renderedStrip(width: width)
            let found = scrollViews(in: host)
            XCTAssertTrue(
                controlsBehindAScrollView(in: host).isEmpty && found.isEmpty,
                """
                the tab strip in a \(Int(width)) pt window (the row wants \(Int(ideal)) pt) \
                put its tabs inside \(describe(found)). On macOS that view claims the \
                mouse-down as a pan and cancels the Button press — this is the owner's \
                "the tabs don't work", exactly. Reach a tab that does not fit with the \
                chevrons' `.offset(x:)`, not a ScrollView.
                """)
        }
    }

    /// The same claim asked of the CONTROLS rather than of the tree.
    func testNoTabSitsBehindAScrollView() throws {
        let host = try renderedStrip(width: measuredRowWidth() * 0.4)
        let swallowed = controlsBehindAScrollView(in: host)
        XCTAssertTrue(
            swallowed.isEmpty,
            "\(swallowed.count) of \(controlHitViews(in: host).count) controls in the tab strip have a scroll view between them and the window")
    }

    // MARK: - A second, independent axis: the static view TYPE

    // The rendered sweep can only see configurations it instantiates. A
    // conditional fallback is invisible to it in every configuration where the
    // condition happens to be false — which is exactly how "leave it as an
    // overflow fallback" survived review on the mixer and re-armed two commits
    // later. A branch that is never taken is still baked into the view's
    // STATIC type.

    private struct NeverTakenScrollProbe: View {
        var overflowing = false
        var body: some View {
            Group {
                if overflowing {
                    ScrollView(.horizontal, showsIndicators: false) { Text("x") }
                } else {
                    Text("x")
                }
            }
        }
    }

    func testTheTypeProbeSeesAScrollViewInABranchThatIsNeverTaken() throws {
        let name = String(reflecting: NeverTakenScrollProbe.Body.self)
        try XCTSkipUnless(
            name.contains("ScrollView"),
            "Swift's runtime does not expand this opaque body type here, so the type axis cannot see a ScrollView; the rendered sweep is the load-bearing evidence either way")
    }

    func testTheStripsViewTypeMentionsNoScrollView() throws {
        let probe = String(reflecting: NeverTakenScrollProbe.Body.self)
        try XCTSkipUnless(probe.contains("ScrollView"),
                          "the type axis is not available on this toolchain; see the probe test above")

        let name = String(reflecting: SettingsTabStrip.Body.self)
        XCTAssertFalse(
            name.contains("ScrollView"),
            """
            The settings tab strip's view type still contains a ScrollView. Even in \
            a branch that is never taken today, that is a fallback waiting to re-arm \
            the next time a tab word gets longer — which is precisely how this bug \
            shipped a second time on the mixer.
            """)
    }

    /// Called out by name, the way the mixer dock is in
    /// `StudioMixerHitTestingTests`: the repo-wide allowlist would still be
    /// satisfied if a future lane simply put `SettingsView.swift` back on it.
    func testSettingsViewIsNotAllowlistedAndHasNoHorizontalScrollView() throws {
        let text = try String(contentsOf: sourcesDirectory.appendingPathComponent("SettingsView.swift"),
                              encoding: .utf8)
        XCTAssertFalse(
            text.contains("ScrollView(.horizontal"),
            "the settings tab strip constructs a horizontal ScrollView again")
        XCTAssertTrue(
            text.contains(".offset(x:"),
            "the explicit horizontal transform that replaced the ScrollView is gone; a tab that does not fit is now unreachable")
    }

    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources")
            .standardizedFileURL
    }

    // MARK: - The other half: a tab that does not fit must still be REACHABLE

    // Deleting the ScrollView outright would trade one dead control for many —
    // every tab past the window's edge becomes unreachable. The chevrons are
    // what keeps that from happening, and a clamp that is off by one tab does
    // not crash, does not move a pixel test and does not fail a build. It just
    // makes the last tab permanently out of reach.

    /// The strip reuses `StudioMixerStripLayout` — the mixer's proven clamp —
    /// with its own pitch. This is the settings-specific half: at the pitch and
    /// widths this strip actually uses, both ends are reachable.
    func testEveryTabIsReachableByPressingTheChevron() {
        let ideal = measuredRowWidth()
        for viewport in [120.0, 240.0, 400.0, 700.0] as [CGFloat] {
            var l = StudioMixerStripLayout(contentWidth: ideal, viewportWidth: viewport,
                                           pitch: SettingsTabStrip.nudgePitch)
            guard l.isOverflowing else { continue }

            var presses = 0
            while l.canScrollRight && presses < 200 {
                l.scrollX = l.nudged(1)
                presses += 1
            }
            XCTAssertFalse(
                l.canScrollRight,
                "a \(Int(viewport)) pt window stopped \(Int(l.maxScroll - l.clampedScrollX)) pt short of the row's end after \(presses) presses, so the last tabs cannot be reached at all")
            XCTAssertEqual(l.clampedScrollX, l.maxScroll, accuracy: 0.5)

            var back = 0
            while l.canScrollLeft && back < 200 {
                l.scrollX = l.nudged(-1)
                back += 1
            }
            XCTAssertEqual(l.clampedScrollX, 0, accuracy: 0.5,
                           "the row could not be brought back to the first tab")
        }
    }

    /// The chevrons must move by a TAB, not by a mixer channel.
    ///
    /// `SettingsTabStrip` reuses `StudioMixerStripLayout` — the mixer's proven
    /// clamp — and that type's `pitch` DEFAULTS to `StudioMixerDock.stripPitch`,
    /// one channel strip. Dropping `pitch:` at the call site compiles, still
    /// reaches both ends, and would make this strip's step change the next time
    /// somebody widened a channel strip in a completely different file. That is
    /// the coupling the reuse buys, and it is worth one assertion.
    func testTheStripStepsByATabAndNotByAMixerChannel() {
        let l = SettingsTabStrip.layout(contentWidth: 2000, viewportWidth: 400, scrollX: 0)
        XCTAssertEqual(
            l.pitch, SettingsTabStrip.nudgePitch,
            "the tab strip is stepping by \(l.pitch) pt — the mixer's channel pitch is \(StudioMixerDock.stripPitch), which is what `StudioMixerStripLayout` defaults to when `pitch:` is left off")
        XCTAssertEqual(l.nudged(1), SettingsTabStrip.nudgePitch, accuracy: 0.001,
                       "one chevron press does not move one tab's worth")
    }

    // MARK: - Two hit-region facts nothing in this process can observe

    // ⚠️ BOTH OF THESE SURVIVED EVERY OTHER ASSERTION IN THIS FILE, and the
    // check below is text rather than behaviour BECAUSE there is nothing
    // stronger available — which is the same wall the file header describes.
    // `ImageRenderer` never builds a responder chain; `NSHostingView.hitTest`
    // answers with itself; and neither an overlay gradient nor a missing
    // `contentShape` changes the AppKit subtree at all, so the rendered sweep
    // cannot see either one. They are named here so a lane reading this knows
    // the evidence is weak, rather than assuming the sweep covered them.
    //
    // What each one costs if it goes:
    //   * the edge fades are drawn OVER the first and last tab; hit-testable,
    //     they swallow exactly those two tabs' clicks — a dead control
    //     reintroduced by a gradient.
    //   * `.clipped()` clips PIXELS, not the hit region, so without the
    //     `contentShape` a tab slid off the left edge still answers clicks from
    //     underneath the chevron that slid it there.
    func testTheTwoHitRegionGuardsAreStillOnTheStrip() throws {
        let text = try String(contentsOf: sourcesDirectory.appendingPathComponent("SettingsView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(
            text.contains(".allowsHitTesting(false)"),
            "the tab strip's edge fades are hit-testable again, so the first and last tab are covered by a gradient that takes their clicks")
        // Scoped to the VIEWPORT, between `.clipped()` and the trailing
        // chevron. A bare `text.contains(".contentShape(Rectangle())")` passes
        // on this file whatever happens to the viewport — the chevron label and
        // every tab button carry one of their own — and it did: that was the
        // first version of this assertion, and the mutation walked straight
        // through it.
        let clipped = try XCTUnwrap(text.range(of: ".clipped()"),
                                    "the tab viewport no longer clips, so the row spills over the chevrons")
        let nextChevron = try XCTUnwrap(text.range(of: "nudge(1,", range: clipped.upperBound..<text.endIndex),
                                        "the trailing chevron is gone")
        XCTAssertTrue(
            text[clipped.upperBound..<nextChevron.lowerBound].contains(".contentShape(Rectangle())"),
            "the clipped viewport lost its contentShape, so a tab scrolled off the edge still answers clicks from under the chevron")
    }

    // MARK: - Picking a tab reveals it

    // The Settings window can be opened ON a tab from outside
    // (`OpenSettingsToLibraryLocation` -> tab 2). With the ScrollViewReader
    // gone, nothing would bring that tab into view, and the pane and the
    // highlighted tab would disagree about where the user is.

    private func math(widths: [CGFloat]) -> SettingsTabStripMath {
        var byID: [Int: CGFloat] = [:]
        for (i, w) in widths.enumerated() { byID[i] = w }
        return SettingsTabStripMath(order: Array(widths.indices), widths: byID,
                                    spacing: 2, leadingInset: 8)
    }

    func testATabAlreadyOnScreenIsNotYanked() {
        let m = math(widths: Array(repeating: 100, count: 9))
        // Tab 1 spans 110...210 with the 8 pt inset and 2 pt gaps.
        XCTAssertEqual(m.revealing(1, scrollX: 0, viewportWidth: 400, maxScroll: 600), 0,
                       "a tab already fully visible caused the row to move, so every click yanks the strip")
    }

    func testATabPastTheRightEdgeIsBroughtIntoView() {
        let m = math(widths: Array(repeating: 100, count: 9))
        let range = try! XCTUnwrap(m.range(of: 8))
        let scrolled = m.revealing(8, scrollX: 0, viewportWidth: 400, maxScroll: 700)
        XCTAssertGreaterThan(scrolled, 0, "the last tab was selected and the row did not move at all")
        XCTAssertLessThanOrEqual(
            range.upperBound, scrolled + 400,
            "the last tab is still past the right edge after the reveal, so opening Settings on it shows a highlighted tab nobody can see")
    }

    func testATabPastTheLeftEdgeIsBroughtBack() {
        let m = math(widths: Array(repeating: 100, count: 9))
        let range = try! XCTUnwrap(m.range(of: 0))
        let scrolled = m.revealing(0, scrollX: 700, viewportWidth: 400, maxScroll: 700)
        XCTAssertLessThan(scrolled, 700)
        XCTAssertGreaterThanOrEqual(range.lowerBound, scrolled - 0.001)
    }

    func testTheRevealNeverLeavesTheRow() {
        let m = math(widths: Array(repeating: 100, count: 9))
        for id in 0..<9 {
            let s = m.revealing(id, scrollX: 0, viewportWidth: 400, maxScroll: 700)
            XCTAssertGreaterThanOrEqual(s, 0, "tab \(id) scrolled the row right of its own start")
            XCTAssertLessThanOrEqual(s, 700, "tab \(id) slid the row past its end into blank panel")
        }
    }

    /// Before anything has been laid out there are no widths, and guessing
    /// would move the row to a position that means nothing.
    func testAnUnmeasuredStripDoesNotMove() {
        let m = SettingsTabStripMath(order: [0, 1, 2], widths: [:])
        XCTAssertNil(m.range(of: 1))
        XCTAssertEqual(m.revealing(1, scrollX: 40, viewportWidth: 400, maxScroll: 700), 40)
    }

    // MARK: - The stated height is not smaller than the row it must show

    /// A `GeometryReader` viewport has no intrinsic size, so the strip states
    /// its height. A stated height that is too small does not draw a smaller
    /// row — it CLIPS the bottom off every tab button, which is exactly how the
    /// mixer dock once drew strips whose M / S chips were never rendered and so
    /// could never be clicked.
    func testTheStripIsTallEnoughToDrawItsOwnButtons() {
        requireAppKit()
        let row = SettingsTabStrip(selection: .constant(0), tabs: SettingsView.tabs).buttonRow
        let host = NSHostingView(rootView: AnyView(row))
        let fitting = host.fittingSize
        XCTAssertGreaterThan(fitting.height, 0,
                             "the row measured no height at all, so this guard is vacuous")
        XCTAssertGreaterThanOrEqual(
            SettingsTabStrip.rowHeight, fitting.height,
            """
            the tab row wants \(fitting.height) pt and the strip is pinned at \
            \(SettingsTabStrip.rowHeight). The bottom \(fitting.height - SettingsTabStrip.rowHeight) pt \
            of every tab button is clipped away and cannot be clicked. Raise \
            SettingsTabStrip.rowHeight — never shrink the buttons to fit a number.
            """)
    }

    private func measuredRowWidth() -> CGFloat {
        requireAppKit()
        let row = SettingsTabStrip(selection: .constant(0), tabs: SettingsView.tabs).buttonRow
        return NSHostingView(rootView: AnyView(row)).fittingSize.width
    }
}
