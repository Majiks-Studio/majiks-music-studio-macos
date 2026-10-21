import XCTest
import SwiftUI
import AppKit
@testable import MajiksMusicStudio

// The mixer's Mute and Solo have now died TWICE, both times through a fully
// green suite, and both times for the same mechanical reason: the M / S chips
// ended up inside a horizontal `ScrollView`, which on macOS claims the
// mouse-DOWN as a possible pan and cancels the `Button` press before it ever
// reaches the chip. The mute/solo LOGIC was never wrong — `params.rs` gates the
// rendered samples correctly and `engine/render/tests/solo.rs` proves it on
// audio, not on flags.
//
// Why nothing caught it: `StudioMixerDockTests` measures the strip's HEIGHT
// against the dock's, which was a real bug once and is a different bug. It also
// renders a bare `StudioMixerStrip`, so the wrapper around the row — the only
// place this failure can live — is not in the picture at all. Forcing
// `isOverflowing` to true, i.e. reproducing the exact broken state, passed 487
// tests across 90 suites.
//
// So this file asserts the one thing those could not: that nothing sits between
// the M / S chips and the pointer.
//
// ⚠️ WHAT `ImageRenderer` CAN AND CANNOT DO. The rest of this repo's mixer
// evidence goes through `ImageRenderer`, and it is the right tool there: it is
// deterministic, needs no window, and answers questions about PIXELS. It cannot
// answer this one. `ImageRenderer` rasterises a view; it never builds a
// responder chain, never dispatches an event, and returns nothing that could
// distinguish a button inside a scroll view from the same button outside one —
// both draw identically. That is precisely how a dead control renders perfectly
// and ships. Asking it about clickability would be the previous lane's mistake
// with a new coat of paint.
//
// What CAN answer it is `NSHostingView`: it builds the real AppKit backing
// hierarchy, in which SwiftUI's `ScrollView` becomes an actual
// `HostingScrollView` / `NSClipView` and each control becomes an actual
// `_NSShapeHitTestingView`. It needs no window and puts nothing on screen,
// which matters here: no lane may launch this app's GUI.
//
// ⚠️ What it still cannot do — measured, and stated so nobody re-derives it:
// `NSHostingView.hitTest(_:)` returns the hosting view ITSELF for every point
// inside it, because SwiftUI dispatches events through its own display list
// instead of the AppKit responder tree. There is no way in this process to
// deliver a click to the M chip and watch it arrive. The nearest true statement
// a test can make is structural, and it is the one that matters: the view that
// does the swallowing is either between the chip and the host, or it is not.
//
// Every detector in this file is CALIBRATED before it is trusted. A test that
// reports "no scroll view found" is worthless unless the same code has just
// been shown finding one, so the first two tests are a positive and a negative
// control on the detector itself.

@MainActor
final class StudioMixerHitTestingTests: XCTestCase {

    // MARK: - The detector

    /// Bring AppKit up before building any `NSView`. Harmless if it is already
    /// up (`ImageRenderer` elsewhere in this suite gets there first), and this
    /// does NOT activate or show anything.
    private func requireAppKit() {
        _ = NSApplication.shared
    }

    /// Lay a SwiftUI view out through the real AppKit path, detached from any
    /// window. Nothing here is ordered to the screen: an `NSHostingView` with no
    /// superview and no window draws nowhere.
    private func laidOut(_ view: some View, width: CGFloat, height: CGFloat) -> NSView {
        requireAppKit()
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .dark)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        // Twice, deliberately. SwiftUI materialises its platform views lazily
        // during layout, and a nested scroll view only appears once its content
        // has been measured — a single pass can report an empty subtree for a
        // hierarchy that will grow one on the next.
        host.layoutSubtreeIfNeeded()
        host.layout()
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Every scroll view in a laid-out hierarchy. `NSClipView` counts: it is the
    /// half of the pair that actually sits in front of the content and takes the
    /// click, and a hierarchy can expose one without the other.
    private func scrollViews(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        if view is NSScrollView || view is NSClipView { found.append(view) }
        for sub in view.subviews { found.append(contentsOf: scrollViews(in: sub)) }
        return found
    }

    private func describe(_ views: [NSView]) -> String {
        views.map { String(describing: type(of: $0)) }.sorted().joined(separator: ", ")
    }

    /// ⚠️ AppKit's own `hitTest(_:)` CANNOT answer this, and that was measured,
    /// not assumed: `NSHostingView.hitTest` returns the hosting view itself for
    /// every point inside it, because SwiftUI dispatches events through its own
    /// display list rather than through the AppKit responder tree. So there is
    /// no test in this process that can literally deliver a click to the M chip
    /// and watch it arrive.
    ///
    /// What IS observable is the thing that does the swallowing. SwiftUI's
    /// `ScrollView` becomes a real `HostingScrollView` / `NSClipView` pair in
    /// the rendered hierarchy, and every control in the row becomes a real
    /// `_NSShapeHitTestingView`. So the question is asked structurally, of the
    /// chips themselves: is there a scroll view BETWEEN a control and the host?
    /// That is the exact relationship that cancels the press.

    /// The AppKit hit-testing views SwiftUI creates for the controls in a
    /// hierarchy. Their presence is also what keeps every assertion below from
    /// passing vacuously on a dock that rendered nothing at all — which it does
    /// by default, because `mixerCollapsed` starts true.
    /// Both spellings, because they are style-dependent and this must not be:
    /// a `.buttonStyle(.plain)` Button (what every chip in the mixer is) becomes
    /// a `_NSShapeHitTestingView`, while a default-styled one becomes a
    /// `SwiftUIAppKitButton`. A detector that knew only one would go quiet the
    /// day someone restyled a chip, which is the same silent-degradation shape
    /// this whole file exists to prevent.
    private static let controlViewMarkers = ["HitTesting", "AppKitButton"]

    private func controlHitViews(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        let name = String(describing: type(of: view))
        if Self.controlViewMarkers.contains(where: { name.contains($0) }) { found.append(view) }
        for sub in view.subviews { found.append(contentsOf: controlHitViews(in: sub)) }
        return found
    }

    /// Every control in `host` that has a scroll view somewhere between it and
    /// the host — i.e. every control whose mouse-down would be claimed as a pan.
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

    // MARK: - Calibration: the detector is shown a scroll view, and shown none

    /// POSITIVE CONTROL. A row of buttons wrapped exactly the way the mixer used
    /// to wrap its strips, hosted too narrow to fit. If this ever stops finding
    /// a scroll view then the detector has gone blind and every "no scroll view"
    /// result below is vacuous — which is the failure mode that let this bug
    /// ship twice.
    func testTheDetectorSeesAHorizontalScrollViewWhenThereIsOne() {
        let probe = ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(0..<12, id: \.self) { i in
                    // `.plain`, exactly like the M / S chips: the probe has to
                    // be the same shape as the thing it calibrates for.
                    Button("\(i)") {}
                        .buttonStyle(.plain)
                        .frame(width: StudioMixerStrip.width, height: 200)
                        .contentShape(Rectangle())
                }
            }
        }
        let host = laidOut(probe, width: 400, height: 300)
        let found = scrollViews(in: host)
        XCTAssertFalse(
            found.isEmpty,
            """
            The scroll-view detector found nothing in a hierarchy that IS a \
            ScrollView. Every other assertion in this file is now vacuous. Do \
            not delete this test to go green — fix the detector.
            """)

    }

    /// SECOND POSITIVE CONTROL, for the ancestry probe rather than the presence
    /// one, and it is deliberately a DEFAULT-styled row.
    ///
    /// Measured, and worth writing down because it decides which assertion in
    /// this file is load-bearing: inside a windowless scroll view SwiftUI
    /// materialises AppKit views for default-styled buttons but NOT for
    /// `.plain` ones — the plain row's controls simply never appear in the
    /// hierarchy. So for the mixer, whose chips are all `.plain`, the ancestry
    /// probe cannot be the primary evidence. The PRESENCE of the scroll view
    /// is, and that is what the test above calibrates.
    func testTheAncestryProbeReportsAControlTrappedInsideAScrollView() {
        let probe = ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(0..<12, id: \.self) { i in
                    Button("\(i)") {}.frame(width: StudioMixerStrip.width, height: 200)
                }
            }
        }
        let host = laidOut(probe, width: 400, height: 300)
        let controls = controlHitViews(in: host)
        XCTAssertFalse(
            controls.isEmpty,
            "no control views were found inside a row of twelve Buttons, so the population probe is blind and every non-vacuity floor below is worthless")
        XCTAssertEqual(
            controlsBehindAScrollView(in: host).count, controls.count,
            "controls inside a real ScrollView were not reported as being behind one, so the ancestry probe cannot see the failure it exists to catch")
    }

    /// NEGATIVE CONTROL. The same row without the wrapper. If this found a
    /// scroll view the detector would be an always-true assertion.
    func testTheDetectorSeesNoScrollViewInAPlainRow() {
        let probe = HStack(spacing: 10) {
            ForEach(0..<12, id: \.self) { i in
                Button("\(i)") {}.frame(width: StudioMixerStrip.width, height: 200)
            }
        }
        let host = laidOut(probe, width: 400, height: 300)
        XCTAssertTrue(
            scrollViews(in: host).isEmpty,
            "the detector reports a scroll view in a plain HStack, so it is not discriminating: \(describe(scrollViews(in: host)))")
        XCTAssertFalse(controlHitViews(in: host).isEmpty, "the plain row rendered no controls, so the negative control proves nothing")
        XCTAssertTrue(controlsBehindAScrollView(in: host).isEmpty)
    }

    // MARK: - The model under test

    private func bootedModel() async throws -> StudioViewModel {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        for _ in 0..<80 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // ⚠️ `mixerCollapsed` DEFAULTS TO TRUE, and this line is the difference
        // between a real test and a green no-op. A collapsed dock renders the
        // header and nothing else: fifteen views, no strips, and therefore no
        // scroll view — so every assertion in this file passed on the BROKEN
        // code until this was caught. `renderedDock` re-asserts the population
        // at every call site so it cannot silently come back.
        model.mixerCollapsed = false
        return model
    }

    /// Host the real dock and refuse to return a hierarchy that did not draw
    /// its strips. The floor is two controls per channel — the M and the S —
    /// which is the smallest claim that cannot be met by a header alone.
    private func renderedDock(_ model: StudioViewModel, width: CGFloat,
                              tracks: Int) throws -> NSView {
        let host = laidOut(StudioMixerDock(model: model),
                           width: width, height: StudioMixerDock.dockHeight + 40)
        let controls = controlHitViews(in: host)
        XCTAssertGreaterThan(
            controls.count, tracks * 2,
            """
            the dock at \(Int(width)) pt with \(tracks) tracks rendered only \
            \(controls.count) controls, which is fewer than its Mute and Solo \
            chips alone. The strips did not draw, so anything this render is \
            asked about is answered vacuously.
            """)
        return host
    }

    /// Ideal width of the strip row at a given channel count, from the SAME
    /// constants the row is built from. Nothing here is a pinned number: widen a
    /// strip and this widens with it, which is exactly what `5d8491d` did to the
    /// real row while every test went on passing.
    private func contentWidth(tracks: Int) -> CGFloat {
        StudioMixerDock.stripRowHorizontalPadding * 2
            + CGFloat(tracks) * StudioMixerStrip.width
            + StudioMasterStrip.width
            + CGFloat(tracks) * StudioMixerDock.stripSpacing
    }

    /// Shrink the mock's eight tracks down to `count` through the real command
    /// bus, so the dock is rendering a genuine snapshot rather than a fixture
    /// shaped to pass.
    private func trim(_ model: StudioViewModel, to count: Int) async throws {
        while let tracks = model.snapshot?.tracks, tracks.count > count {
            guard let last = tracks.last else { break }
            await model.deleteTrack(last.id)?.value
        }
        let got = try XCTUnwrap(model.snapshot?.tracks.count)
        XCTAssertEqual(got, count, "could not reach \(count) tracks; the sweep below would be testing the wrong shape")
    }

    /// The floor in `renderedDock` is itself calibrated here, because it very
    /// nearly shipped as decoration: `mixerCollapsed` defaults to TRUE, so the
    /// first draft of this file rendered a header and no strips at all and every
    /// "no scroll view" assertion in it was true of an empty picture. This
    /// renders the dock the way it used to and shows the floor rejects it.
    func testACollapsedDockFallsUnderTheFloorTheOtherTestsRelyOn() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let tracks = try XCTUnwrap(model.snapshot?.tracks.count)

        model.mixerCollapsed = true
        let collapsed = laidOut(StudioMixerDock(model: model),
                                width: contentWidth(tracks: tracks) * 0.5,
                                height: StudioMixerDock.dockHeight + 40)
        XCTAssertLessThanOrEqual(
            controlHitViews(in: collapsed).count, tracks * 2,
            """
            a COLLAPSED dock rendered more than \(tracks * 2) controls, so the \
            population floor the rest of this file leans on would accept a dock \
            that drew no strips — which is exactly the vacuous green this file \
            exists to make impossible.
            """)

        model.mixerCollapsed = false
        let expanded = try renderedDock(model, width: contentWidth(tracks: tracks) * 0.5, tracks: tracks)
        XCTAssertGreaterThan(
            controlHitViews(in: expanded).count, controlHitViews(in: collapsed).count,
            "expanding the mixer added no controls, so the dock is not drawing its strips in this harness at all")
    }

    // MARK: - THE regression test

    /// The headline. Force `StudioMixerDock.isOverflowing` to `true` — the exact
    /// pre-`607e7ac` state, and the state `5d8491d` re-created for an ordinary
    /// three-track session — and this test fails by name while the other 487 do
    /// not notice.
    ///
    /// The viewport widths are DERIVED from the row's own ideal width rather
    /// than listed, so the sweep still straddles the overflow threshold no
    /// matter what a strip grows to. A pinned "1200 pt" would have quietly
    /// stopped covering the overflow case the day the strip went 112 -> 173.
    func testTheMixerDockNeverWrapsTheStripsInAScrollViewAtAnyTrackCount() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        // 8 is the mock's synthetic session; 3 is the ordinary session the
        // owner reported dead with the Copilot dock open. 1 is the degenerate
        // end, where the master strip alone can still overflow a narrow dock.
        for tracks in [8, 6, 4, 3, 2, 1] {
            try await trim(model, to: tracks)
            let ideal = contentWidth(tracks: tracks)

            // Far too narrow, mildly too narrow, exactly at the seam, and
            // comfortably wide. The first three are overflow; the last is not.
            for width in [ideal * 0.25, ideal * 0.75, ideal, ideal * 2] {
                let host = try renderedDock(model, width: width, tracks: tracks)
                let found = scrollViews(in: host)
                XCTAssertTrue(
                    controlsBehindAScrollView(in: host).isEmpty && found.isEmpty,
                    """
                    \(tracks) tracks in a \(Int(width)) pt dock (the row wants \
                    \(Int(ideal)) pt) put the strips inside \(describe(found)). \
                    On macOS that view claims the mouse-down as a pan and \
                    cancels the M / S button press — this is the owner's \
                    "solo and mute don't work anymore", exactly. Reach the far \
                    strips with the chevrons' `.offset(x:)`, not a ScrollView.
                    """)
            }
        }
    }

    /// The same claim asked of the CONTROLS rather than of the tree: every
    /// control the dock rendered — the M and S chips among them — must have a
    /// clear path to the host. Narrower than the row on purpose; a row that fits
    /// was never the broken case.
    func testNoControlInTheDockSitsBehindAScrollView() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        for tracks in [8, 3] {
            try await trim(model, to: tracks)
            let width = contentWidth(tracks: tracks) * 0.5
            let host = try renderedDock(model, width: width, tracks: tracks)

            let swallowed = controlsBehindAScrollView(in: host)
            XCTAssertTrue(
                swallowed.isEmpty,
                """
                \(swallowed.count) of \(controlHitViews(in: host).count) controls in a \
                \(tracks)-track mixer at \(Int(width)) pt have a scroll view between \
                them and the window. On macOS that view claims the mouse-down as \
                a pan and the press never reaches them — the M and S chips are \
                among those controls.
                """)
        }
    }

    /// Width independence, stated as its own claim rather than left implicit in
    /// the sweep above: whatever a strip grows to, the dock is scroll-free. The
    /// widths here are multiples of the REAL strip width, so this assertion
    /// cannot be satisfied by a number that stopped meaning anything.
    func testTheStripRowStaysScrollFreeAcrossEveryRatioOfContentToViewport() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let tracks = try XCTUnwrap(model.snapshot?.tracks.count)
        let ideal = contentWidth(tracks: tracks)
        XCTAssertGreaterThan(ideal, 0)

        // One strip wide up to twice the row: eight ratios, four of them well
        // inside overflow.
        for multiple in stride(from: 1.0, through: 8.0, by: 1.0) {
            let width = StudioMixerStrip.width * multiple
            let host = try renderedDock(model, width: width, tracks: tracks)
            let found = scrollViews(in: host)
            XCTAssertTrue(
                controlsBehindAScrollView(in: host).isEmpty && found.isEmpty,
                "at \(Int(width)) pt (row wants \(Int(ideal)) pt) the strips are inside \(describe(found))")
        }
    }

    // MARK: - The other half: the far strips must still be REACHABLE

    // Deleting the ScrollView outright would trade one dead control for many —
    // every channel past the window's edge becomes unreachable. The chevrons
    // are what keeps that from happening, and a clamp that is off by one strip
    // does not crash, does not move a pixel test, and does not fail a build. It
    // just makes the last channel permanently out of reach.

    func testEveryChannelIsReachableByPressingTheChevron() {
        for tracks in 1...24 {
            for viewport in [200.0, 400.0, 800.0, 1600.0, 3000.0] as [CGFloat] {
                var l = StudioMixerStripLayout(contentWidth: contentWidth(tracks: tracks),
                                               viewportWidth: viewport)
                guard l.isOverflowing else { continue }

                var presses = 0
                while l.canScrollRight && presses < tracks + 4 {
                    l.scrollX = l.nudged(1)
                    presses += 1
                }
                XCTAssertFalse(
                    l.canScrollRight,
                    "\(tracks) tracks in \(Int(viewport)) pt: the row stopped \(Int(l.maxScroll - l.clampedScrollX)) pt short of its end after \(presses) presses, so the last channels cannot be reached at all")
                XCTAssertEqual(
                    l.clampedScrollX, l.maxScroll, accuracy: 0.5,
                    "\(tracks) tracks in \(Int(viewport)) pt: the right chevron went dead before the row reached its end")

                var back = 0
                while l.canScrollLeft && back < tracks + 4 {
                    l.scrollX = l.nudged(-1)
                    back += 1
                }
                XCTAssertEqual(
                    l.clampedScrollX, 0, accuracy: 0.5,
                    "\(tracks) tracks in \(Int(viewport)) pt: the row could not be brought back to the first channel")
            }
        }
    }

    /// The clamp itself, against inputs no gesture produces but a stale
    /// `@State` after a track deletion does.
    func testTheOffsetIsClampedToTheRowNoMatterWhatIsAskedFor() {
        let l = StudioMixerStripLayout(contentWidth: 2000, viewportWidth: 600)
        XCTAssertEqual(l.maxScroll, 1400, accuracy: 0.001)

        for asked in [-9_999.0, -1.0, 0.0, 700.0, 1400.0, 1401.0, 9_999.0] as [CGFloat] {
            var probe = l
            probe.scrollX = asked
            XCTAssertGreaterThanOrEqual(probe.clampedScrollX, 0,
                                        "asked for \(asked), got a negative offset: the row would be pushed right of its own start")
            XCTAssertLessThanOrEqual(probe.clampedScrollX, l.maxScroll,
                                     "asked for \(asked), got \(probe.clampedScrollX): the row is slid past its end and the mixer shows empty panel")
        }
    }

    /// A row that fits has nowhere to go, and both chevrons must SAY so. A
    /// chevron that stays lit but moves nothing is the same "the button does
    /// nothing" report this whole lane started from.
    func testAFittingRowLeavesBothChevronsDead() {
        let l = StudioMixerStripLayout(contentWidth: 500, viewportWidth: 1200)
        XCTAssertEqual(l.maxScroll, 0)
        XCTAssertFalse(l.isOverflowing)
        XCTAssertFalse(l.canScrollLeft)
        XCTAssertFalse(l.canScrollRight)
        XCTAssertEqual(l.clampedScrollX, 0)
    }

    /// The two ends. At rest only "later" is available; fully scrolled only
    /// "earlier" is.
    func testTheChevronsAreLitExactlyWhenThereIsSomewhereToGo() {
        var l = StudioMixerStripLayout(contentWidth: 2000, viewportWidth: 600)
        XCTAssertFalse(l.canScrollLeft, "at rest there is nothing to the left of the first channel")
        XCTAssertTrue(l.canScrollRight)

        l.scrollX = l.maxScroll
        XCTAssertTrue(l.canScrollLeft)
        XCTAssertFalse(l.canScrollRight, "at the far end the right chevron still claims it can move")
    }

    /// Before anything has been measured every width is 0. A `maxScroll` of
    /// `contentWidth` there would let the very first press strand the user in
    /// blank panel.
    func testAnUnmeasuredLayoutCannotScrollAnywhere() {
        let l = StudioMixerStripLayout()
        XCTAssertEqual(l.maxScroll, 0)
        XCTAssertFalse(l.canScrollRight)
        XCTAssertFalse(l.canScrollLeft)
    }

    // MARK: - A second, independent axis: the static view TYPE

    // The rendered sweep above can only see configurations it actually
    // instantiates. A conditional fallback — `if isOverflowing { ScrollView … }`
    // — is invisible to it in every configuration where the condition happens
    // to be false, which is exactly how `607e7ac`'s "leave it as an overflow
    // fallback" survived review and then re-armed itself two commits later.
    //
    // A branch that is never taken is still baked into the view's STATIC type.
    // So this axis catches the fallback's mere existence, in any configuration,
    // without rendering anything at all.

    /// POSITIVE CONTROL for the axis: a probe whose ScrollView is in a branch
    /// that is never taken. If this stops finding it, the type test below is
    /// vacuous and must be deleted rather than trusted.
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
            """
            Swift's runtime does not expand this opaque body type \
            (\(name.prefix(200))), so the type axis cannot see a ScrollView and \
            testTheDocksViewTypeMentionsNoScrollView below proves nothing. The \
            rendered NSHostingView sweep is the load-bearing evidence either way.
            """)
    }

    func testTheDocksViewTypeMentionsNoScrollView() throws {
        let probe = String(reflecting: NeverTakenScrollProbe.Body.self)
        try XCTSkipUnless(probe.contains("ScrollView"),
                          "the type axis is not available on this toolchain; see the probe test above")

        let name = String(reflecting: StudioMixerDock.Body.self)
        XCTAssertFalse(
            name.contains("ScrollView"),
            """
            The mixer dock's view type still contains a ScrollView. Even in a \
            branch that is never taken today, that is a fallback waiting to \
            re-arm the next time a strip gets wider — which is precisely how \
            this bug shipped the second time.
            """)
    }

    // MARK: - Sweep: this is a CLASS of failure, not an instance

    /// Every file under `Sources` allowed to construct a horizontal
    /// `ScrollView`, with the reason written down.
    ///
    /// The same mechanism has now cost this product the Settings tab strip, was
    /// caught just in time on the drum-pad grid (by
    /// `StudioSamplerUITests.theGridDoesNotEatItsOwnClicks`, a per-file guard),
    /// and killed the mixer's M / S twice. Per-file guards only ever catch the
    /// file someone already thought to guard. This catches the NEXT one, from a
    /// lane that has never read a word of this.
    ///
    /// Landing in this list is not automatically wrong — it means someone has
    /// to prove the controls inside are still reachable and say why here.
    ///
    /// \u{26A0}\u{FE0F} THIS LIST IS NOW EMPTY, which is a stronger state than it looks —
    /// but it also makes `testTheScrollViewAllowlistHasNoStaleEntries` below
    /// vacuous, so it is said out loud here rather than discovered later. The
    /// load-bearing test is `testNoNewSurfacePutsItsControlsInsideAHorizontal-
    /// ScrollView`, now a flat repo-wide ban, and its own non-vacuity floor
    /// (`out.count > 20` in `appSources`) is what keeps it honest.
    ///
    /// The two entries that used to be here are gone because both were FIXED,
    /// not because the rule was relaxed:
    ///
    ///   * `SettingsView.swift` held the conditional-fallback shape that re-broke
    ///     the mixer — a plain HStack until it overflowed, a ScrollView after —
    ///     so any longer tab word, larger dynamic-type setting or narrower window
    ///     re-armed it. It uses the chevron `.offset(x:)` idiom now.
    ///   * `LyricsEditorView.swift` was allowlisted with the reason "each
    ///     button's effect is also reachable by typing the tag". That was true of
    ///     six of its eight buttons: "Full Template" writes a whole song skeleton
    ///     and "Clear Tags" strips every tag out of the lyric, and neither is
    ///     something a person can type. It is a wrapping `LazyVGrid` now.
    private static let filesAllowedAHorizontalScrollView: [String: String] = [:]

    private static let sourcesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../Sources")
        .standardizedFileURL

    private func appSources() throws -> [(name: String, text: String)] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: Self.sourcesDirectory, includingPropertiesForKeys: nil))
        var out: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 20, "the source scan found almost nothing, so it is not scanning")
        return out
    }

    func testNoNewSurfacePutsItsControlsInsideAHorizontalScrollView() throws {
        var offenders: [String] = []
        for source in try appSources() where source.text.contains("ScrollView(.horizontal") {
            if Self.filesAllowedAHorizontalScrollView[source.name] == nil {
                offenders.append(source.name)
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            \(offenders.sorted().joined(separator: ", ")) construct a horizontal \
            ScrollView. On macOS that view claims the mouse-down as a pan and \
            cancels Button presses inside it — it has killed the mixer's Mute \
            and Solo twice and the Settings tabs once. Move the row behind an \
            explicit `.offset(x:)` with chevrons (see StudioMixerDock.nudge or \
            StudioFxChainStrip), or add the file above with a reason.
            """)
    }

    /// The allowlist must not rot into standing permission for files that no
    /// longer have the problem.
    ///
    /// \u{26A0}\u{FE0F} With the list empty this loop runs zero times, so it asserts nothing
    /// on its own — the calibration below is what stops it being a green line
    /// that means nothing. It stays because the moment somebody adds an entry it
    /// is load-bearing again, and because deleting it would take the rule with it.
    func testTheScrollViewAllowlistHasNoStaleEntries() throws {
        let byName = Dictionary(uniqueKeysWithValues: try appSources().map { ($0.name, $0.text) })

        // Calibration: the needle this test and the sweep above search for must
        // actually match the construct it is named after. Without this, "no file
        // contains a horizontal ScrollView" would also be the reading if the
        // needle were misspelt.
        XCTAssertTrue(
            "ScrollView(.horizontal, showsIndicators: false) { Text(\"x\") }"
                .contains("ScrollView(.horizontal"),
            "the needle no longer matches a horizontal ScrollView, so the repo-wide sweep is blind")
        for (name, reason) in Self.filesAllowedAHorizontalScrollView.sorted(by: { $0.key < $1.key }) {
            let text = try XCTUnwrap(byName[name], "allowlisted file \(name) is gone; remove it from the list")
            XCTAssertTrue(
                text.contains("ScrollView(.horizontal"),
                "\(name) no longer has a horizontal ScrollView (\(reason)); drop it from the allowlist so the next one is caught")
        }
    }

    /// The mixer is called out by name, the way the track header is in
    /// `StudioHelpTests`: the allowlist above would still be satisfied if some
    /// future lane simply added `StudioMixerDock.swift` to it.
    func testTheMixerDockIsNotAllowlistedAndHasNoHorizontalScrollView() throws {
        XCTAssertNil(
            Self.filesAllowedAHorizontalScrollView["StudioMixerDock.swift"],
            "the mixer dock was added to the allowlist, which is how this bug comes back a third time")
        let dock = try XCTUnwrap(
            try appSources().first(where: { $0.name == "StudioMixerDock.swift" })?.text)
        XCTAssertFalse(dock.contains("ScrollView("),
                       "the mixer dock constructs a ScrollView again")
        XCTAssertTrue(dock.contains(".offset(x:"),
                      "the explicit horizontal transform that replaced the ScrollView is gone; the far strips are now unreachable")
    }

    // MARK: - The chips themselves are still wired

    /// Cheap, and it closes the loop the owner's report opens: the chips exist,
    /// they carry the help ids, and pressing them changes engine truth. The
    /// rendered-audio proof lives in `engine/render/tests/solo.rs`; this only
    /// asserts the UI still reaches it.
    func testTheMuteAndSoloChipsStillDriveEngineTruth() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let track = try XCTUnwrap(model.snapshot?.tracks.first)

        model.setTrackMute(track.id, muted: !track.muted)
        model.setTrackSolo(track.id, soloed: !track.soloed)
        for _ in 0..<80 {
            if let t = model.snapshot?.tracks.first(where: { $0.id == track.id }),
               t.muted != track.muted, t.soloed != track.soloed { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let after = try XCTUnwrap(model.snapshot?.tracks.first(where: { $0.id == track.id }))
        XCTAssertNotEqual(after.muted, track.muted, "the mute command did not reach engine truth")
        XCTAssertNotEqual(after.soloed, track.soloed, "the solo command did not reach engine truth")
    }
}
