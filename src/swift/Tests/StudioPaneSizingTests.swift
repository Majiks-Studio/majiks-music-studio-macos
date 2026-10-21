import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// Lane: resizable panes.
//
// Layout is the thing a build cannot check, which is exactly why "it compiles"
// is not evidence for this work. What CAN be held is the state layer the
// dividers drive, and these drive the REAL types — `StudioPaneSizeSpec.clamp`,
// `StudioPaneSizes`, `StudioPaneSizing.available` — never a copy of the
// arithmetic. A test that re-implements min/max and then asserts its own answer
// proves nothing about the app; a test that hands the shipping store a
// throwaway UserDefaults suite proves the app's own path.
//
// Four things can rot here and all four are held below:
//
//  1. CLAMPING. A pane dragged past its limits stops at them, and cannot be
//     dragged to zero. Make the clamp a no-op and these fail by name.
//  2. PERSISTENCE. The size survives a relaunch. Proven by building a SECOND
//     store on the same suite, so a read-through cache cannot fake it.
//  3. RESET. Double-clicking a divider is the escape hatch; if it does not put
//     the pane back, a user who has dragged themselves into a corner is stuck.
//  4. THE FLOORS THAT ARE NOT TASTE. Two of the minima exist because the pane
//     below them CLIPS rather than scrolls (the mixer's strips, the routing
//     pane's parameter grid). Those are the two places where a drag could
//     re-create a bug that has already shipped once.

@MainActor
final class StudioPaneSizingTests: XCTestCase {

    /// A UserDefaults suite of this test's own, so nothing here can read or
    /// write the developer's real preferences.
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "StudioPaneSizingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func store() -> StudioPaneSizes { StudioPaneSizes(defaults: defaults) }

    // MARK: - 1. Clamping

    /// THE mutation check for the clamp. Make `StudioPaneSizeSpec.clamp` return
    /// its input and every pane in this table fails by name.
    func testNoPaneCanBeDraggedBelowItsMinimum() {
        for spec in StudioPaneSizing.all {
            XCTAssertEqual(
                spec.clamp(-4000), spec.minimum,
                "\(spec.id): a drag past the far edge went below the minimum")
            XCTAssertEqual(
                spec.clamp(0), spec.minimum,
                "\(spec.id): a pane can be dragged to nothing. Collapsing is the toolbar toggle's job; a drag clamps.")
            XCTAssertEqual(
                spec.clamp(spec.minimum - 1), spec.minimum,
                "\(spec.id): one point below the minimum was accepted")
        }
    }

    func testNoPaneCanBeDraggedAboveItsMaximum() {
        for spec in StudioPaneSizing.all {
            XCTAssertEqual(
                spec.clamp(9999), spec.maximum,
                "\(spec.id): a pane could be dragged large enough to swallow the window")
            XCTAssertEqual(
                spec.clamp(spec.maximum + 1), spec.maximum,
                "\(spec.id): one point above the maximum was accepted")
        }
    }

    func testASizeInsideTheRangeIsPassedThroughUntouched() {
        for spec in StudioPaneSizing.all {
            let middle = (spec.minimum + spec.maximum) / 2
            XCTAssertEqual(
                spec.clamp(middle), middle,
                "\(spec.id): a perfectly legal size was altered, so the pane will not follow the pointer")
        }
    }

    /// Every spec has to describe a range a person can actually move in. A
    /// minimum that equals its maximum is a divider that cannot be dragged —
    /// present, hoverable, inert. That is this codebase's signature bug and it
    /// would be invisible in review.
    func testEveryPaneHasRoomToMoveAndADefaultInsideIt() {
        for spec in StudioPaneSizing.all {
            XCTAssertLessThan(
                spec.minimum, spec.maximum,
                "\(spec.id): minimum and maximum leave no travel, so its divider is inert")
            // A minimum of zero would satisfy "clamped to the minimum" while
            // still letting the pane be dragged out of existence — the clamp
            // would be honoured and the requirement broken at the same time.
            // 64 pt is the floor below which none of these panes is a panel any
            // more; every real minimum here is comfortably above it.
            XCTAssertGreaterThanOrEqual(
                spec.minimum, 64,
                "\(spec.id): a minimum of \(spec.minimum) pt lets the pane be dragged away to a sliver")
            XCTAssertGreaterThanOrEqual(spec.defaultSize, spec.minimum, "\(spec.id): default is below its own minimum")
            XCTAssertLessThanOrEqual(spec.defaultSize, spec.maximum, "\(spec.id): default is above its own maximum")
        }
    }

    /// A gesture whose origin was never recorded produces NaN, and NaN survives
    /// min/max silently — it would be stored, and the pane would come back from
    /// the next launch with no size at all.
    func testANonFiniteSizeFallsBackToTheDefaultRatherThanBeingStored() {
        let spec = StudioPaneSizing.browser
        XCTAssertEqual(spec.clamp(.nan), spec.defaultSize)
        XCTAssertEqual(spec.clamp(.infinity), spec.defaultSize)

        let sizes = store()
        sizes.set(.nan, for: spec)
        XCTAssertEqual(sizes.size(of: spec), spec.defaultSize,
                       "a NaN drag frame was persisted, so the pane has no size")
    }

    /// Ids and storage keys are what the persisted state is filed under. A
    /// duplicate silently ties two panes together: drag one, the other moves.
    func testEveryPaneHasItsOwnIdentityAndItsOwnVersionedKey() {
        var ids = Set<String>()
        var keys = Set<String>()
        for spec in StudioPaneSizing.all {
            XCTAssertTrue(ids.insert(spec.id).inserted, "duplicate pane id: \(spec.id)")
            XCTAssertTrue(keys.insert(spec.key).inserted, "duplicate storage key: \(spec.key)")
            XCTAssertTrue(spec.key.hasPrefix("studio.pane."),
                          "\(spec.id): \(spec.key) does not follow the Studio's key convention")
            XCTAssertTrue(spec.key.hasSuffix(".v1"),
                          "\(spec.id): \(spec.key) is unversioned, so a later change of meaning would silently reinterpret a stored value")
        }
    }

    // MARK: - 2. Persistence

    /// THE mutation check for persistence. A second store on the same suite,
    /// so the read-through cache in the first one cannot answer for it: this is
    /// the same thing that happens when the app is relaunched.
    func testASizeSurvivesARelaunch() {
        let spec = StudioPaneSizing.inspector
        let chosen: CGFloat = 341

        let first = store()
        first.set(chosen, for: spec)
        XCTAssertEqual(first.size(of: spec), chosen)

        let afterRelaunch = StudioPaneSizes(defaults: defaults)
        XCTAssertEqual(
            afterRelaunch.size(of: spec), chosen,
            "the inspector's width did not survive a relaunch, so every drag is forgotten at quit")
    }

    func testEveryPaneRoundTripsThroughTheStore() {
        for spec in StudioPaneSizing.all {
            // A quarter of the way up the pane's own range: legal for every
            // pane, and never equal to the default, so a store that silently
            // ignores writes cannot pass by accident.
            let chosen = (spec.minimum * 3 + spec.maximum) / 4
            store().set(chosen, for: spec)
            XCTAssertEqual(
                StudioPaneSizes(defaults: defaults).size(of: spec), chosen, accuracy: 0.001,
                "\(spec.id): the size did not round-trip through UserDefaults")
        }
    }

    func testAPaneWithNothingStoredIsTheSizeItShippedWith() {
        for spec in StudioPaneSizing.all {
            XCTAssertEqual(store().size(of: spec), spec.defaultSize,
                           "\(spec.id): a first launch does not get the shipped layout")
            XCTAssertTrue(store().isDefault(spec))
        }
    }

    /// A value written by an older build, or a hand-edited plist, must not
    /// become the pane's size just because it is present.
    func testAStoredValueOutsideTheRangeIsClampedOnTheWayOut() {
        let spec = StudioPaneSizing.copilot
        defaults.set(Double(4000), forKey: spec.key)
        XCTAssertEqual(store().size(of: spec), spec.maximum)

        defaults.set(Double(1), forKey: spec.key)
        XCTAssertEqual(store().size(of: spec), spec.minimum)

        // Not a number at all.
        defaults.set("wide please", forKey: spec.key)
        XCTAssertEqual(store().size(of: spec), spec.defaultSize)
    }

    /// Merely LOOKING at the Studio on a small screen must not overwrite a size
    /// the user chose on a big one. Reads clamp for display; only a drag writes.
    func testReadingASizeOnASmallWindowDoesNotShrinkTheStoredOne() {
        let spec = StudioPaneSizing.browser
        let sizes = store()
        sizes.set(spec.maximum, for: spec)

        _ = sizes.size(of: spec, available: 140)     // rendered on a narrow window

        XCTAssertEqual(
            StudioPaneSizes(defaults: defaults).size(of: spec), spec.maximum,
            "opening the Studio on a laptop permanently shrank a width chosen on the TV")
    }

    // MARK: - 3. Reset

    /// THE mutation check for double-click-to-reset. Gut `reset` and this fails.
    func testDoubleClickingADividerPutsThatPaneBackToItsDefault() {
        for spec in StudioPaneSizing.all {
            let sizes = store()
            sizes.set(spec.maximum, for: spec)
            XCTAssertNotEqual(sizes.size(of: spec), spec.defaultSize, "\(spec.id): the setup did not move the pane")

            sizes.reset(spec)

            XCTAssertEqual(
                sizes.size(of: spec), spec.defaultSize,
                "\(spec.id): the reset escape hatch does not reach the default")
            XCTAssertTrue(
                sizes.isDefault(spec),
                "\(spec.id): reset wrote the default rather than clearing the key, so a later change to the default would never reach this user")
            XCTAssertEqual(
                StudioPaneSizes(defaults: defaults).size(of: spec), spec.defaultSize,
                "\(spec.id): the reset did not survive a relaunch")
        }
    }

    /// Resetting one pane must not touch the others — the divider you
    /// double-clicked is the pane you meant.
    func testResettingOnePaneLeavesTheOthersAlone() {
        let sizes = store()
        for spec in StudioPaneSizing.all { sizes.set(spec.maximum, for: spec) }

        sizes.reset(StudioPaneSizing.pianoRoll)

        XCTAssertEqual(sizes.size(of: StudioPaneSizing.pianoRoll), StudioPaneSizing.pianoRoll.defaultSize)
        for spec in StudioPaneSizing.all where spec.id != StudioPaneSizing.pianoRoll.id {
            XCTAssertEqual(sizes.size(of: spec), spec.maximum,
                           "\(spec.id) moved when the piano roll's divider was double-clicked")
        }
    }

    // MARK: - 4. The floors that are not taste

    /// The mixer's strip region CLIPS rather than scrolls. A dock shorter than a
    /// strip does not show a smaller mixer — it stops drawing the bottom of
    /// every strip, and the M / S buttons become unclickable. That shipped once.
    /// `StudioMixerDockTests` guards the constant; this guards the DRAG.
    func testTheMixerCannotBeDraggedShorterThanAFullChannelStrip() {
        XCTAssertEqual(
            StudioPaneSizing.mixer.minimum, StudioMixerDock.dockHeight,
            "the mixer's drag floor drifted from the height a channel strip actually needs")
        XCTAssertEqual(
            StudioPaneSizing.mixer.clamp(40), StudioMixerDock.dockHeight,
            "the mixer could be dragged short enough to clip its own M / S buttons")
        XCTAssertGreaterThanOrEqual(
            StudioPaneSizing.mixer.clamp(StudioMixerDock.stripHeight),
            StudioMixerDock.stripHeight + StudioMixerDock.stripVerticalPadding * 2)
    }

    /// The routing pane's fixed rows (header, focus row, chain strip, hairlines)
    /// come to 120 pt and everything that can grow lives below them.
    /// `StudioRoutingPaneTests` pins that the DEFAULT height leaves more than
    /// 120 pt of scroll region; dragging must not be able to take that away, or
    /// the parameter grid gets zero height and vanishes.
    func testTheRoutingPaneCannotBeDraggedUntilItsParameterGridVanishes() {
        let shortest = StudioPaneSizing.routing.clamp(0)
        XCTAssertGreaterThan(
            shortest - StudioPaneSizing.routingFixedRows,
            StudioPaneSizing.routingScrollFloor,
            """
            At its smallest the routing pane leaves \
            \(shortest - StudioPaneSizing.routingFixedRows) pt for the parameter \
            grid and the send list, which is not a usable scroll region. Raise \
            StudioPaneSizing.routing.minimum.
            """)
        XCTAssertEqual(StudioPaneSizing.routing.defaultSize, StudioRoutingPane.paneHeight,
                       "the routing pane's default drifted from the height its own tests measure against")
    }

    /// Defaults are the sizes the shell shipped with: a user who never touches a
    /// divider must see exactly the layout they saw before this lane.
    func testTheDefaultsAreTheSizesTheShellAlreadyUsed() {
        XCTAssertEqual(StudioPaneSizing.browser.defaultSize, StudioTokens.browserWidth)
        XCTAssertEqual(StudioPaneSizing.inspector.defaultSize, StudioTokens.inspectorWidth)
        XCTAssertEqual(StudioPaneSizing.copilot.defaultSize, StudioCopilotDock.width)
        XCTAssertEqual(StudioPaneSizing.pianoRoll.defaultSize, StudioPianoRollPane.defaultHeight)
        XCTAssertEqual(StudioPaneSizing.routing.defaultSize, StudioRoutingPane.paneHeight)
        XCTAssertEqual(StudioPaneSizing.mixer.defaultSize, StudioMixerDock.dockHeight)
        XCTAssertEqual(StudioPaneSizing.keyboard.defaultSize, StudioOnScreenKeyboardPane.defaultHeight)
    }

    // MARK: - 5. The window's own ceiling

    /// The slack-absorbing view is the point of the whole layout: the centre
    /// column takes what is left horizontally, the timeline vertically. A pane
    /// dragged until that view is zero has swallowed the window.
    func testAPaneCannotBeDraggedUntilTheTimelineHasNoRoomLeft() {
        let workspace = CGSize(width: 1280, height: 800)
        let spec = StudioPaneSizing.pianoRoll

        let ceiling = StudioPaneSizing.available(for: spec, workspace: workspace, otherVisible: 0)
        XCTAssertEqual(ceiling, 800 - StudioPaneSizing.timelineFloor)
        XCTAssertLessThanOrEqual(
            spec.clamp(9999, available: ceiling), workspace.height - StudioPaneSizing.timelineFloor,
            "the piano roll could be dragged over the timeline's floor")
    }

    func testEveryOtherOpenPaneTakesRoomOffTheCeiling() {
        let workspace = CGSize(width: 1280, height: 900)
        // Piano roll open at 300 and the mixer expanded at its default.
        let others = StudioPaneSizing.pianoRoll.defaultSize + StudioPaneSizing.mixer.defaultSize
        let ceiling = StudioPaneSizing.available(
            for: StudioPaneSizing.keyboard, workspace: workspace, otherVisible: others)

        XCTAssertEqual(ceiling, 900 - others - StudioPaneSizing.timelineFloor)
        XCTAssertLessThan(
            ceiling, StudioPaneSizing.keyboard.maximum,
            "with two other panes open the window, not the spec, must be the binding limit")
    }

    /// The horizontal axis obeys the same rule against the centre column.
    func testASideRailCannotBeDraggedOverTheCentreColumnsFloor() {
        let workspace = CGSize(width: 1000, height: 800)
        let ceiling = StudioPaneSizing.available(
            for: StudioPaneSizing.inspector, workspace: workspace, otherVisible: 172)
        XCTAssertEqual(ceiling, 1000 - 172 - StudioPaneSizing.centreColumnFloor)
        XCTAssertEqual(StudioPaneSizing.inspector.clamp(9999, available: ceiling), ceiling)
    }

    /// When the window really is out of room the pane still gets its own
    /// minimum. Something has to overflow at that point, and a rail collapsed
    /// to nothing under the pointer is the worse of the two failures — it reads
    /// as the panel having been deleted.
    func testAWindowWithNoRoomLeftStillLeavesEveryPaneItsMinimum() {
        let cramped = CGSize(width: 360, height: 220)
        for spec in StudioPaneSizing.all {
            let ceiling = StudioPaneSizing.available(for: spec, workspace: cramped, otherVisible: 0)
            XCTAssertGreaterThanOrEqual(ceiling, spec.minimum, "\(spec.id)")
            XCTAssertEqual(spec.clamp(0, available: ceiling), spec.minimum, "\(spec.id)")
        }
    }

    /// Before the first layout pass the workspace measures zero. Reading that
    /// as "no room" would snap every pane to its minimum for one visible frame
    /// at every launch.
    func testAnUnmeasuredWorkspaceIsNotReadAsNoRoom() {
        for spec in StudioPaneSizing.all {
            XCTAssertEqual(
                StudioPaneSizing.available(for: spec, workspace: .zero, otherVisible: 0),
                spec.maximum,
                "\(spec.id): an unmeasured shell would snap this pane on the first frame")
        }
    }

    // MARK: - 6. Which way the drag goes

    /// Not something a build can catch and not something a unit test can see on
    /// screen, but the SIGN is data on the spec, so it can at least be pinned.
    /// The browser's divider is on its trailing edge (drag right = wider);
    /// every other divider is on the pane's leading or top edge, so the same
    /// drag makes those panes smaller.
    func testTheDragDirectionMatchesWhichEdgeTheDividerSitsOn() {
        XCTAssertEqual(StudioPaneSizing.browser.growth, .withDrag,
                       "the browser's divider is on its trailing edge: dragging right must widen it")
        for spec in StudioPaneSizing.all where spec.id != "browser" {
            XCTAssertEqual(
                spec.growth, .againstDrag,
                "\(spec.id)'s divider sits on its leading or top edge, so a positive drag must shrink it")
        }
    }

    func testTheAxisMatchesWhatThePaneIsMeasuredIn() {
        let rails = [StudioPaneSizing.browser, StudioPaneSizing.inspector, StudioPaneSizing.copilot]
        for spec in rails {
            XCTAssertEqual(spec.axis, StudioPaneAxis.horizontal,
                           "\(spec.id) is a side rail and is measured in width")
        }
        let bottom = [
            StudioPaneSizing.pianoRoll, StudioPaneSizing.routing,
            StudioPaneSizing.mixer, StudioPaneSizing.keyboard,
        ]
        for spec in bottom {
            XCTAssertEqual(spec.axis, StudioPaneAxis.vertical,
                           "\(spec.id) is a bottom pane and is measured in height")
        }
        XCTAssertEqual(rails.count + bottom.count, StudioPaneSizing.all.count,
                       "a pane was added to `all` without being named on an axis here")
    }

    // MARK: - 7. Help

    /// Every divider is a control, and this codebase's rule is that a control
    /// explains itself. The generic coverage net in StudioHelpTests cannot see
    /// these, because a divider's id arrives through `spec.helpID` rather than
    /// as a literal at the call site.
    func testEveryDividerCarriesTeachingHelp() throws {
        for spec in StudioPaneSizing.all {
            let entry = try XCTUnwrap(
                StudioHelpCatalog.entry(spec.helpID),
                "\(spec.id): its divider asks for help id \(spec.helpID), which is not in the catalog")
            XCTAssertTrue(
                entry.teaching.lowercased().contains("drag"),
                "\(spec.id): the teaching never says the edge can be dragged, which is the one thing a hairline cannot show: \(entry.teaching)")
            XCTAssertTrue(
                entry.teaching.lowercased().contains("double-click"),
                "\(spec.id): the teaching never mentions the reset escape hatch: \(entry.teaching)")
        }
    }

    // MARK: - 8. The panes actually USE the size they are handed
    //
    // Everything above holds the state layer, and a perfect state layer is
    // worth nothing if the view ignores it. That is not a hypothetical here:
    // three of these panes had their size written into the view as a literal
    // (`.frame(height: 132)`), and swapping a literal for a parameter is
    // exactly the kind of change that can be half-made — the parameter added,
    // the frame still hard-coded — with a green build either way.
    //
    // Measured with ImageRenderer, the same deterministic no-window path
    // StudioMixerDockTests and StudioRoutingPaneTests already use.

    private func renderedSize<V: View>(_ view: V) -> CGSize? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        return CGSize(width: cg.width, height: cg.height)
    }

    private func bootedModel() async -> StudioViewModel {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        for _ in 0..<80 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return model
    }

    func testThePianoRollPaneIsAsTallAsItIsToldToBe() throws {
        let controller = StudioPianoRollController(engine: StudioMockNoteEngine.demoSession())
        let wanted = StudioPaneSizing.pianoRoll.maximum - 100
        let size = try XCTUnwrap(renderedSize(
            StudioPianoRollPane(
                controller: controller, frameStats: StudioFrameStats(), height: wanted)
            .frame(width: 900)))
        XCTAssertEqual(
            size.height, wanted, accuracy: 1,
            "the piano roll drew \(size.height) pt when it was handed \(wanted): its height parameter is not reaching the frame, so dragging its divider will move nothing")
    }

    func testTheRoutingPaneIsAsTallAsItIsToldToBe() async throws {
        let controller = StudioRoutingController(engine: StudioMockEngine())
        await controller.attach()
        let wanted = StudioPaneSizing.routing.minimum + 90
        let size = try XCTUnwrap(renderedSize(
            StudioRoutingPane(controller: controller, height: wanted).frame(width: 900)))
        XCTAssertEqual(
            size.height, wanted, accuracy: 1,
            "the routing pane drew \(size.height) pt when it was handed \(wanted)")
    }

    func testTheOnScreenKeyboardPaneIsAsTallAsItIsToldToBe() async throws {
        let model = await bootedModel()
        defer { model.stopPolling() }
        let wanted = StudioPaneSizing.keyboard.maximum - 60
        let size = try XCTUnwrap(renderedSize(
            StudioOnScreenKeyboardPane(
                controller: StudioKeyboardController(), model: model, height: wanted)
            .frame(width: 900)))
        XCTAssertEqual(
            size.height, wanted, accuracy: 1,
            "the keyboard pane drew \(size.height) pt when it was handed \(wanted)")
    }

    /// The browser and Sterling's dock are here because their view-level
    /// mutations SURVIVED the first pass of this table: with only the state
    /// tests in place, replacing `.frame(width: width)` with the old hard-coded
    /// token in either file left the whole suite green. Two dividers that moved
    /// nothing, and nothing red. These are the tests that close that.
    func testTheBrowserIsAsWideAsItIsToldToBe() async throws {
        let model = await bootedModel()
        defer { model.stopPolling() }
        let wanted = StudioPaneSizing.browser.maximum - 60
        let size = try XCTUnwrap(renderedSize(
            StudioBrowserView(model: model, width: wanted)
                .environmentObject(LibraryStore())
                .frame(height: 600)))
        XCTAssertEqual(
            size.width, wanted, accuracy: 1,
            "the browser drew \(size.width) pt wide when it was handed \(wanted): its width parameter is not reaching the frame, so dragging its divider will move nothing")
    }

    func testSterlingsDockIsAsWideAsItIsToldToBe() async throws {
        let model = await bootedModel()
        defer { model.stopPolling() }
        // The dock only draws its panel when it is open; the reopen strip has
        // no width to set. `studio.copilotOpen` is the flag the dock reads.
        UserDefaults.standard.set(true, forKey: "studio.copilotOpen")

        let agents = AgentStore()
        agents.load()
        let wanted = StudioPaneSizing.copilot.maximum - 80
        let size = try XCTUnwrap(renderedSize(
            StudioCopilotDock(studio: model, panelWidth: wanted)
                .environmentObject(StudioCoordinator())
                .environmentObject(agents)
                .frame(height: 600)))
        XCTAssertEqual(
            size.width, wanted, accuracy: 1,
            "Sterling's dock drew \(size.width) pt wide when it was handed \(wanted)")
    }

    func testTheInspectorIsAsWideAsItIsToldToBe() async throws {
        let model = await bootedModel()
        defer { model.stopPolling() }
        let wanted = StudioPaneSizing.inspector.maximum - 40
        let size = try XCTUnwrap(renderedSize(
            StudioInspectorView(model: model, width: wanted).frame(height: 600)))
        XCTAssertEqual(
            size.width, wanted, accuracy: 1,
            "the inspector drew \(size.width) pt wide when it was handed \(wanted)")
    }

    /// The shell's own wiring, which the render tests above cannot see: they
    /// prove a pane HONOURS a size it is handed, not that anything ever hands
    /// it one. `StudioRootView` cannot be rendered in a unit test (it builds
    /// its own engine-backed StateObjects), so this is a source scan — the same
    /// technique `StudioHelpTests` uses to prove a help id is still attached to
    /// a control. Weaker than a render, and stated as such; it does catch the
    /// case where a pane gains a spec, a divider and a persisted size that the
    /// shell never actually reads.
    func testTheShellWiresEveryPaneToItsSizeAndItsDivider() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Studio/StudioRootView.swift")
            .standardizedFileURL
        let text = try String(contentsOf: root, encoding: .utf8)

        for spec in StudioPaneSizing.all {
            let name = spec.id
            XCTAssertTrue(
                text.contains("paneSize(StudioPaneSizing.\(name))"),
                "the shell never reads \(name)'s stored size, so its divider persists a number nothing draws with")
            XCTAssertTrue(
                text.contains("divider(StudioPaneSizing.\(name))"),
                "\(name) has a size spec but no divider in the shell, so there is nothing to drag")
        }
    }

    /// The mixer is the one pane whose height is bounded from BELOW by its own
    /// content, so this checks the expanded dock grows with the number it is
    /// given rather than staying pinned at `dockHeight`.
    func testTheMixerDockGrowsWithTheHeightItIsToldToBe() async throws {
        let model = await bootedModel()
        defer { model.stopPolling() }
        model.mixerCollapsed = false

        let wanted = StudioMixerDock.dockHeight + 120
        let taller = try XCTUnwrap(renderedSize(
            StudioMixerDock(model: model, stripsHeight: wanted).frame(width: 1000)))
        let atDefault = try XCTUnwrap(renderedSize(
            StudioMixerDock(model: model, stripsHeight: StudioMixerDock.dockHeight)
                .frame(width: 1000)))

        XCTAssertEqual(
            taller.height - atDefault.height, 120, accuracy: 1,
            "the mixer dock ignored the extra height it was given, so its divider moves nothing")
    }
}
