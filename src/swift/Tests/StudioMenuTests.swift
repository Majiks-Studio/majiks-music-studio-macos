import XCTest
import SwiftUI
import AppKit
@testable import MajiksMusicStudio

// The macOS menu bar, held to the one claim that matters.
//
// THE CLAIM: **the menu bar is the palette table, rendered.** Not a copy of it,
// not a curated selection from it — the same rows, placed by a rule over their
// own names. Two hand-maintained lists of the same 119 commands is precisely
// how ⌘K rotted to 11-of-119 and how `CatalogNames.swift` sat for months under
// a header naming a generator that did not exist.
//
// So the tests here are structural rather than sampled, and the load-bearing
// one is negative: `testTheMenuFilesNameNoCatalogCommandOfTheirOwn` fails if a
// catalog command name ever appears as a string literal in the menu sources. A
// menu built from a second list would pass every "is it reachable" test on the
// day it was written and rot the same way the palette did; only the source scan
// can see the rot coming.
//
// The other three claims:
//
//   * ENABLEMENT — an item whose precondition fails is DISABLED, and the reason
//     is the palette row's own sentence, reached from the row rather than
//     re-derived. Disabled-with-a-reason, never hidden: "quantize is not in
//     this app" and "quantize needs notes selected" look identical when a row
//     is absent.
//   * DISPATCH — selecting an item puts that item's own catalog name on the
//     command bus. Every item, both shapes, not a sample.
//   * NAVIGATION — `View ▸ Go to` sends you to the pane it names.

// MARK: - The bridge, driven

@MainActor
final class StudioMenuTests: XCTestCase {

    override func tearDown() async throws {
        // The bridge is a singleton whose whole point is outliving one
        // appearance of the Studio tab. Leaving one test's fixture installed
        // would make the next test's answers depend on ORDER.
        StudioMenuBridge.shared.uninstall()
    }

    // MARK: - 1. The menu IS the palette table

    /// The headline. Every row ⌘K offers is reachable from a menu.
    func testEveryCommandThePaletteOffersIsReachableFromAMenu() {
        let offered = Set(StudioPaletteCommands.all.map(\.name))
        let inMenus = Set(StudioMenuPlan.items.map(\.name))

        XCTAssertEqual(
            inMenus, offered,
            """
            The palette offers \(offered.count) commands and the menus carry \
            \(inMenus.count). Missing from the menus: \
            \(offered.subtracting(inMenus).sorted()). Claimed by the menus but \
            not offered by the palette: \(inMenus.subtracting(offered).sorted()).
            """)
        XCTAssertEqual(
            StudioMenuPlan.items.count, inMenus.count,
            "a command appears in two menus, so one of the two items is the one nobody finds")
        XCTAssertGreaterThanOrEqual(
            inMenus.count, 50,
            "the menus carry only \(inMenus.count) commands; the palette reaches \(offered.count)")
    }

    /// Placement is a reading of the command's own namespace, and every
    /// namespace the palette uses has to have been read. A namespace nobody
    /// placed must fail HERE rather than silently landing in a default menu,
    /// where nobody would look for it.
    func testEveryOfferedCommandLandsInExactlyOneMenu() {
        var unplaced: [String] = []
        for command in StudioPaletteCommands.all {
            if studioMenu(forCatalogName: command.name) == nil { unplaced.append(command.name) }
        }
        XCTAssertTrue(
            unplaced.isEmpty,
            """
            \(unplaced.sorted()) have a namespace `studioMenu(forCatalogName:)` \
            does not place. A new command family must be given a menu on purpose; \
            defaulting it into one would put it where nobody looks.
            """)
    }

    func testNoGeneratedMenuIsEmpty() {
        for menu in StudioMenu.allCases {
            XCTAssertFalse(
                StudioMenuPlan.items(in: menu).isEmpty,
                "the \(menu.title) menu has no items, so it is a word on the menu bar that opens onto nothing")
        }
    }

    /// This build's own view rows — the panel toggles, zoom-to-fit, the frame
    /// HUD, Revise, Export — are reachable too. They are not catalog commands
    /// and must never claim to be, but a person cannot tell the difference and
    /// should not have to.
    func testEveryViewRowIsReachableFromExactlyOneMenu() {
        let all = Set(StudioMenuPlan.viewRows().map(\.id))
        XCTAssertGreaterThanOrEqual(all.count, 8, "the view rows vanished from the palette catalog")

        var placed: [String] = []
        placed += StudioMenuPlan.viewMenuRows().map(\.id)
        for menu in StudioMenu.allCases {
            placed += StudioMenuPlan.viewRows(in: menu).map(\.id)
        }
        XCTAssertEqual(Set(placed), all,
                       "unplaced view rows: \(all.subtracting(placed).sorted())")
        // ⚠️ `placed.count == placed.count` was written here first and is a
        // constant compared against itself — it passes whatever the code does.
        // De-duplicating one side is what makes it a claim.
        XCTAssertEqual(Set(placed).count, placed.count,
                       "a view row is in two menus: \(placed.sorted())")
    }

    /// A MENU ITEM'S TITLE IS ITS NAME.
    ///
    /// The View menu shipped `Show or hide the left panel`, `Fit the whole song
    /// on screen` and five more sentences directly under `Zoom In · Zoom Out ·
    /// Actual Size`. Those are ⌘K search text — which is where they still live,
    /// and the half of this that matters is that they were MOVED and not cut:
    /// the sentence is the row's `title` and the menu shows its `terse`.
    ///
    /// Held to the same shape `StudioHelpTests.testTeachingNeverJustRepeatsTheLabel`
    /// holds every tooltip to, because it is the same pair of registers.
    func testEveryViewRowsMenuNameIsANameAndItsSentenceSurvives() {
        var checked = 0
        for row in StudioMenuPlan.viewRows() {
            let name = row.terse
            XCTAssertFalse(name.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(row.id) has no menu name at all")
            XCTAssertNotEqual(
                name, row.title,
                """
                \(row.id)'s menu name is still its whole sentence: "\(name)". A menu \
                item's title is its NAME — "Left Panel", not "Show or hide the left \
                panel". Give the row a `terse:` in StudioCommandPalette.
                """)
            XCTAssertGreaterThan(
                row.title.count, name.count,
                "\(row.id): the sentence is no longer than the name, so ⌘K lost the words it is searched on")
            let words = name.split(whereSeparator: \.isWhitespace).count
            XCTAssertLessThanOrEqual(
                words, 4,
                "\(row.id)'s menu name is \(words) words (\"\(name)\") — that is a sentence, not a name")
            XCTAssertTrue(
                name.first?.isUppercase == true,
                "\(row.id)'s menu name \"\(name)\" is not Title Case like Zoom In / Actual Size")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(
            checked, 8, "only \(checked) view rows were checked, so this test is reading an empty list")

        // …and the sentence really does reach the menu item, which is what the
        // tooltip and VoiceOver read. Losing it here would be losing the
        // teaching while every name-shaped assertion above still passed.
        for item in StudioMenuPlan.viewMenuRows() {
            let row = StudioMenuPlan.viewRow(named: item.id)
            XCTAssertEqual(item.teaching, row?.title,
                           "\(item.id): the menu item's teaching is not the palette row's sentence")
            XCTAssertEqual(item.label, row?.terse,
                           "\(item.id): the menu item prints something that is not the row's name")
        }
    }

    // MARK: - 2. THE ANTI-DRIFT TEST

    private static let sourcesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../Sources")
        .standardizedFileURL

    private func source(_ relativePath: String) throws -> String {
        let url = Self.sourcesDirectory.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The same source with every `//` comment removed.
    ///
    /// ⚠️ Use this for any guard whose job is "this CALL is still here". A
    /// `contains` satisfied by a COMMENT ABOUT the line it is policing is a
    /// guard this repo has already shipped once, and this file's own prose
    /// quotes the very call sites it checks — so an un-stripped scan here would
    /// be satisfied by the paragraph explaining what it is looking for.
    private func code(_ relativePath: String) throws -> String {
        try source(relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// THE one that stops the menu bar becoming a second list.
    ///
    /// If a future lane hand-writes `Button("Split the clip") { … "clip.split" }`
    /// into a menu, this fails naming `clip.split`. That is the ONLY mechanism
    /// that survives someone not having read any of the prose: everything else
    /// here would still pass on the day the second list was written, and rot
    /// the day after — which is exactly what happened to the palette.
    func testTheMenuFilesNameNoCatalogCommandOfTheirOwn() throws {
        let files = ["Studio/StudioMenuCommands.swift", "Main.swift"]
        var offences: [String] = []
        for file in files {
            let text = try source(file)
            for name in CatalogNames.names where text.contains("\"\(name)\"") {
                offences.append("\(file): \(name)")
            }
        }
        XCTAssertTrue(
            offences.isEmpty,
            """
            \(offences.sorted()) — a catalog command is named as a literal in the \
            menu sources. The menu bar must be DERIVED from \
            StudioPaletteCommands.all, never authored beside it: two \
            hand-maintained lists of the same 119 commands is how ⌘K rotted to 11.
            """)
        // The scan has to be reading something. A path typo would make the
        // loop above vacuously true.
        XCTAssertGreaterThan(try source(files[0]).count, 4000,
                             "the menu source scan read almost nothing, so it is not scanning")
        XCTAssertGreaterThan(CatalogNames.names.count, 100,
                             "the catalog name list is empty, so the scan above checked nothing")
    }

    /// Every generated menu is actually MOUNTED. `StudioMenuPlan` could be
    /// perfect and the menu bar still carry none of it — the half-wiring this
    /// repo keeps shipping.
    func testEveryGeneratedMenuIsMountedOnTheMenuBar() throws {
        let menus = try source("Studio/StudioMenuCommands.swift")
        for menu in StudioMenu.allCases {
            XCTAssertTrue(
                menus.contains("StudioMenuItemsView(menu: .\(menu.rawValue)"),
                "the \(menu.title) menu is planned but its CommandMenu carries nothing")
            XCTAssertTrue(
                menus.contains("CommandMenu(StudioMenu.\(menu.rawValue).title)"),
                "the \(menu.title) menu has no CommandMenu, or its title is hand-written rather than taken from the enum")
        }
        // …and the whole block is actually attached to the scene. Without this
        // the four menus could be perfect and appear nowhere, which is the
        // half-wiring this repo keeps shipping.
        let main = try source("Main.swift")
        XCTAssertTrue(main.contains("StudioCommandMenus(bridge:"),
                      "the Studio's four menus are never attached to the App's .commands")
        XCTAssertTrue(main.contains("StudioViewMenuItemsView(bridge:"),
                      "the Studio's panel toggles are not mounted in the View menu")
        XCTAssertTrue(main.contains("Go to \\(section.title)"),
                      "View ▸ Go to is gone, which is the navigation half of what was asked for")
    }

    // MARK: - 2b. THE THREE SURVIVORS
    //
    // Everything above and below passes with the menu bar CONNECTED TO
    // NOTHING. Three mutations were run against the whole 618-test suite and
    // every one of them was green:
    //
    //   * delete `installMenuBridge()` from `StudioRootView.onAppear` — the
    //     menus never get a live Studio, so every item in all five menus is
    //     permanently greyed with "Open the Studio tab first" and stays that
    //     way with the Studio open in front of you;
    //   * delete `.disabled(...)` from the item — every item is always
    //     clickable, including the ones whose precondition fails;
    //   * delete the `StudioMenuFreshness` modifier — the greyed states are
    //     computed once and never follow the app again.
    //
    // All three compile, render, and are wrong in a way only a person at the
    // machine can see, which is precisely the "built, working, and invisible"
    // class this whole lane is about. Every test above drives
    // `StudioMenuBridge` directly, so none of them can see the WIRING.
    //
    // This is a source guard and is honestly weaker than a behavioural one —
    // it proves the call site exists, not that macOS delivers it. What it does
    // buy is that deleting any of the three fails BY NAME instead of shipping.
    // It reads the source with comments STRIPPED, because the paragraph you
    // are reading names every call site it checks.

    func testTheMenuBarIsWiredToTheLiveStudioAndNotJustToItself() throws {
        let root = try code("Studio/StudioRootView.swift")
        // ⚠️ COUNTED, not `contains`. `installMenuBridge()` appears in its own
        // `private func` DEFINITION, so a plain `contains` is satisfied by a
        // method nobody calls — the first version of this guard was, and the
        // mutation that deletes the call site survived it a second time. Two
        // occurrences: the definition, and at least one call.
        let installMentions = root.components(separatedBy: "installMenuBridge()").count - 1
        XCTAssertGreaterThanOrEqual(
            installMentions, 2,
            """
            `installMenuBridge()` appears \(installMentions) time(s) in \
            StudioRootView — it is defined and never called. The Song, Track, \
            Clip, Transport and View menus would render, grey EVERY item with \
            "Open the Studio tab first", and stay that way with the Studio open \
            in front of you. This mutation passed all 618 other tests twice.
            """)
        XCTAssertTrue(
            root.contains("func installMenuBridge()"),
            "installMenuBridge is gone entirely; the count above would then be measuring call sites of nothing")
        XCTAssertTrue(
            root.contains("StudioMenuBridge.shared.install {"),
            "installMenuBridge() no longer installs anything")
        XCTAssertTrue(
            root.contains("StudioMenuFreshness("),
            """
            The freshness modifier is gone from StudioRootView. Every greyed item \
            would be frozen at whatever it was when the Studio first appeared — \
            selecting a clip would not enable Clip ▸ Delete. This mutation passed \
            all 618 other tests.
            """)

        let menus = try code("Studio/StudioMenuCommands.swift")
        XCTAssertTrue(
            menus.contains(".disabled(reason != nil)"),
            """
            StudioMenuButton no longer disables an item that cannot run. Every \
            item would be clickable, including the ones whose precondition fails \
            — and `run` refuses those, so they would be live-looking and inert, \
            which is the exact defect the palette shipped twice. This mutation \
            passed all 618 other tests.
            """)
        XCTAssertTrue(
            menus.contains(".help(reason ?? teaching)"),
            "the item's tooltip is gone, so an enabled item explains nothing on hover")

        // ⚠️ THE FOOTER IS A FOURTH SURVIVOR of exactly the kind this section
        // is about. `StudioMenuLayout.footerLines` can be perfect and correct
        // and tested, and if the view that MOUNTS it is deleted the reason
        // simply stops appearing anywhere a person can read — greyed items and
        // no explanation, which is worse than the wall of text this lane
        // replaced. Every test above reasons about the pure function.
        //
        // Two mounts, because there are two menu-content views: the four object
        // menus share `StudioMenuItemsView`, and the View menu has its own.
        // COUNTED rather than `contains`, for the reason `installMenuBridge()`
        // above is counted — a `contains` would be satisfied by the declaration
        // alone, i.e. by a footer nobody mounts.
        let footerMounts = menus.components(separatedBy: "StudioMenuReasonFooter(").count - 1
        XCTAssertGreaterThanOrEqual(
            footerMounts, 2,
            """
            `StudioMenuReasonFooter(` is mounted \(footerMounts) time(s) in \
            StudioMenuCommands; there are two menu-content views and each needs \
            one. Below two, at least one menu greys its items and says nothing at \
            all about why.
            """)
        XCTAssertTrue(
            menus.contains("struct StudioMenuReasonFooter"),
            "the footer is gone entirely; the count above would then be measuring mounts of nothing")

        // The stripper has to be stripping, or all five checks above are being
        // answered by the paragraph that describes them.
        XCTAssertFalse(
            try code("Studio/StudioMenuCommands.swift").contains("MARK: - The menus this file owns"),
            "the comment stripper is not stripping, so these guards can be satisfied by prose")
        XCTAssertTrue(
            try source("Studio/StudioMenuCommands.swift").contains("MARK: - The menus this file owns"),
            "the stripper removed something that is not a comment")
    }

    // MARK: - 3. Shortcuts

    /// Rule 1: a menu shortcut is APP-GLOBAL, so a bare key is not an option.
    /// Binding `Delete` (which `clip.remove` teaches) would eat the Delete key
    /// in every text field in the app.
    func testOnlyCommandShortcutsAreEverBound() {
        XCTAssertNil(studioMenuShortcut(fromPaletteKeys: "Space"))
        XCTAssertNil(studioMenuShortcut(fromPaletteKeys: "Delete"))
        XCTAssertNil(studioMenuShortcut(fromPaletteKeys: "Shift \u{2190} / Shift \u{2192}"))
        XCTAssertNil(studioMenuShortcut(fromPaletteKeys: nil))
        XCTAssertEqual(studioMenuShortcut(fromPaletteKeys: "Cmd E")?.key, "e")

        for item in StudioMenuPlan.items {
            guard let shortcut = item.shortcut else { continue }
            XCTAssertTrue(shortcut.key.isLetter,
                          "\(item.name) binds a non-letter key equivalent: \(shortcut.key)")
        }
        XCTAssertFalse(StudioMenuPlan.items.compactMap(\.shortcut).isEmpty,
                       "no menu item teaches a shortcut at all, so the menus teach nobody the keyboard")
    }

    /// Rule 2: never collide with something `Main.swift` already binds. Two
    /// menu items on one key resolve by menu-bar ORDER, which is not visible
    /// from either site.
    func testNoGeneratedShortcutCollidesWithOneMainSwiftAlreadyBinds() throws {
        let main = try source("Main.swift")
        let pattern = try NSRegularExpression(
            pattern: #"\.keyboardShortcut\(\s*"([^"])"\s*,\s*modifiers:\s*\.command\s*\)"#)
        let range = NSRange(main.startIndex..., in: main)
        var owned = Set<Character>()
        for match in pattern.matches(in: main, range: range) {
            guard let r = Range(match.range(at: 1), in: main),
                  let ch = main[r].first else { continue }
            owned.insert(Character(String(ch).lowercased()))
        }
        XCTAssertGreaterThan(
            owned.count, 3,
            "the Main.swift shortcut scan found \(owned.count) plain-⌘ bindings, so it is not scanning")

        for item in StudioMenuPlan.items {
            guard let shortcut = item.shortcut else { continue }
            XCTAssertFalse(
                owned.contains(shortcut.key),
                """
                \(item.name) binds ⌘\(String(shortcut.key).uppercased()), which \
                Main.swift already binds to something else. Two items on one key \
                resolve by menu-bar order — add the key to \
                studioMenuShortcutsMainAlreadyOwns with a reason instead.
                """)
        }
    }

    /// The exclusion list has to be TRUE, not superstitious. Each key it names
    /// must genuinely be bound in Main.swift; an exclusion for a key nobody
    /// owns is a shortcut silently withheld from the user.
    func testTheShortcutsMainAlreadyOwnsAreRealAndReasoned() throws {
        let main = try source("Main.swift")
        XCTAssertFalse(studioMenuShortcutsMainAlreadyOwns.isEmpty)
        for (keys, reason) in studioMenuShortcutsMainAlreadyOwns {
            let letter = String(keys.dropFirst("Cmd ".count)).lowercased()
            XCTAssertTrue(
                main.contains(".keyboardShortcut(\"\(letter)\", modifiers: .command)"),
                """
                \(keys) is excluded as "already owned by Main.swift", but Main.swift \
                binds no such plain-⌘ shortcut. The exclusion is withholding a \
                shortcut for a collision that does not exist.
                """)
            XCTAssertGreaterThanOrEqual(
                reason.count, 30, "\(keys): \"\(reason)\" is too short to be a reason")
            XCTAssertTrue(
                StudioPaletteCommands.all.contains { $0.keys == keys },
                "\(keys) is excluded but no palette row teaches it, so the entry is dead")
        }
    }

    // MARK: - 4. Enablement: disabled WITH A REASON, never hidden

    /// Before the Studio has ever been opened there is no project for any of
    /// these to act on. Every one of them must SAY so — and say where to go.
    func testEveryItemIsDisabledWithADirectionBeforeTheStudioIsEverOpened() {
        StudioMenuBridge.shared.uninstall()
        let bridge = StudioMenuBridge.shared

        XCTAssertFalse(bridge.isStudioOpen)
        for item in StudioMenuPlan.items {
            let reason = bridge.reason(for: item.name)
            XCTAssertNotNil(reason, "\(item.name) reads as ready with no Studio open at all")
            XCTAssertEqual(reason, StudioMenuBridge.studioNotOpenReason)
        }
        for row in StudioMenuPlan.viewRows() {
            XCTAssertNotNil(bridge.reason(for: row.id), "\(row.id) reads as ready with no Studio open")
        }
        XCTAssertTrue(
            StudioMenuBridge.studioNotOpenReason.contains("Studio"),
            "the reason must name where to go, or a greyed menu teaches nothing")
    }

    /// The reason on a disabled item is the palette row's OWN sentence, reached
    /// from the row. Not re-derived here and not re-worded there: a second copy
    /// of the reason is a second copy of the logic, which is the trap where a
    /// coverage test carries its own traversal.
    func testADisabledItemCarriesItsPaletteRowsOwnReason() async {
        let f = PaletteFixture()
        f.model.startPolling()
        await f.wait { f.model.snapshot != nil }
        defer { f.teardown() }

        // Deliberately unstaged: nothing selected, no roll, no routing.
        StudioMenuBridge.shared.install { StudioPaletteContext(model: f.model) }
        StudioMenuBridge.shared.refresh()

        var checked = 0
        for item in StudioMenuPlan.items {
            guard let command = StudioMenuPlan.command(named: item.name) else {
                return XCTFail("\(item.name) has a menu item and no palette row behind it")
            }
            let fromRow = command.availability(in: StudioPaletteContext(model: f.model)).reason
            XCTAssertEqual(
                StudioMenuBridge.shared.reason(for: item.name), fromRow,
                """
                \(item.name): the menu says \
                "\(StudioMenuBridge.shared.reason(for: item.name) ?? "ready")" and its \
                palette row says "\(fromRow ?? "ready")". The menu is deciding for \
                itself instead of asking the row.
                """)
            if fromRow != nil { checked += 1 }
        }
        XCTAssertGreaterThan(
            checked, 20,
            """
            Only \(checked) items were blocked with nothing selected. Rows that need \
            a clip, a track, the piano roll or the effects panel must block there — \
            if they read as ready, the menu offers items that do nothing.
            """)
    }

    /// The other half, and the one that makes the pair non-vacuous: staging the
    /// app must actually turn items ON. Without this, a `refresh()` that
    /// returned "blocked" unconditionally would pass the test above.
    func testStagingTheStudioEnablesTheItemsThatWereDisabled() async {
        let f = PaletteFixture()
        await f.stageStandard()
        defer { f.teardown() }

        StudioMenuBridge.shared.install { StudioPaletteContext(model: f.model) }
        StudioMenuBridge.shared.refresh()
        let bareEnabled = StudioMenuPlan.items.filter { StudioMenuBridge.shared.isEnabled($0.name) }.count

        StudioMenuBridge.shared.install { f.context }
        StudioMenuBridge.shared.refresh()
        let stagedEnabled = StudioMenuPlan.items.filter { StudioMenuBridge.shared.isEnabled($0.name) }.count

        XCTAssertGreaterThan(
            stagedEnabled, bareEnabled,
            """
            \(stagedEnabled) items are enabled with a clip selected and the roll and \
            effects panel open, and \(bareEnabled) with none of that. The menu's \
            enabled state does not follow the app, so it is decoration.
            """)
        // The specific ones a person would notice, named so a regression says
        // WHICH affordance went dark rather than "a count moved".
        for name in ["clip.remove", "clip.duplicate", "track.mute", "note.quantize", "fx.add"] {
            XCTAssertTrue(
                StudioMenuBridge.shared.isEnabled(name),
                "\(name) is still disabled with everything it needs on screen: "
                + (StudioMenuBridge.shared.reason(for: name) ?? "?"))
        }
    }

    /// ⚠️ THIS TEST WAS REVERSED, and the reason is written down rather than
    /// left to `git blame`, because reversing a test is exactly the move that
    /// should not be made quietly.
    ///
    /// It used to be `testADisabledItemsTitlePrintsTheRemedy` and it asserted
    /// that a greyed item's title was "<name> — <whole reason>". That was a
    /// considered choice at the time and its reasoning is still half right:
    /// macOS shows no help tag on a disabled `NSMenuItem`, so a reason that
    /// lived ONLY in `.help(...)` would be a reason nobody can read.
    ///
    /// What it missed is that a title is not the only other place a reason can
    /// live, and that the reason is the SAME on every item whenever the block
    /// is a reachability answer. Before the Studio tab has ever been opened all
    /// 56 items and all 10 view rows carry the identical 14-word sentence, so
    /// the View menu printed it seven times and ran to 836 pt of typeset text
    /// — a wall of grey on the owner's 4K TV, and the Song / Track / Clip /
    /// Transport menus were the same defect 10 to 20 items deep.
    ///
    /// So the reason MOVED — to a footer that prints each distinct reason once
    /// (`StudioMenuLayout.footerLines`, and the three tests below) — and it was
    /// not deleted. The old test's claim is still held; it is just held over
    /// the whole menu now instead of over one item's title.
    func testADisabledItemsTitleIsItsNameAndNothingElse() {
        let plain = StudioMenuButton.title(label: "Delete the selected clip", reason: nil)
        XCTAssertEqual(plain, "Delete the selected clip",
                       "an item that CAN run must not carry a dash and an explanation")

        let blocked = StudioMenuButton.title(
            label: "Delete the selected clip", reason: StudioPaletteContext.noClipReason)
        XCTAssertEqual(
            blocked, plain,
            """
            A greyed item's title is "\(blocked)" — the disabled-reason is back in \
            the title. Every item blocked for the same reason then prints that \
            reason again, and a menu is as wide as its widest item: this is the \
            836 pt View menu, and the same sentence seven times over. The reason \
            belongs in the menu's footer (StudioMenuLayout.footerLines), once.
            """)
    }

    // MARK: - 4b. …and the reason is said ONCE, in the footer

    /// The move is only honest if nothing is lost in it. `wrap` may break a
    /// sentence onto lines; it may not drop, reorder or edit a word of it.
    ///
    /// Driven over EVERY reason the app can actually produce — the palette
    /// rows' own block sentences and the view rows' — rather than over a
    /// sample, because the one that breaks will be the one nobody thought of.
    func testWrappingAReasonCannotLoseAWordOfIt() async {
        var checked = 0
        for reason in await Self.everyReasonTheMenusCanShow() {
            let wrapped = StudioMenuLayout.wrap(reason)
            XCTAssertFalse(wrapped.isEmpty, "\"\(reason)\" wrapped to nothing at all")
            XCTAssertEqual(
                wrapped.joined(separator: " "),
                reason.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                """
                Wrapping "\(reason)" changed it. The footer is a MOVE of the \
                teaching, not an edit of it — a wrap that can drop a word is a \
                wrap that deletes the explanation while looking like it kept it.
                """)
            for line in wrapped where line.split(whereSeparator: \.isWhitespace).count > 1 {
                XCTAssertLessThanOrEqual(
                    line.count, StudioMenuLayout.lineLimit,
                    "\"\(line)\" is \(line.count) chars, over the \(StudioMenuLayout.lineLimit)-char line limit, and it is not one unbreakable word")
            }
            checked += 1
        }
        XCTAssertGreaterThan(
            checked, 5,
            "only \(checked) reasons were wrapped, so this test is reading an empty list")
    }

    /// The headline. Before the Studio has ever been opened every item in a
    /// menu is blocked for the SAME reason, and the footer prints it ONCE.
    func testTheFooterSaysOneSharedReasonOnceRatherThanOncePerItem() {
        StudioMenuBridge.shared.uninstall()
        let bridge = StudioMenuBridge.shared

        for menu in StudioMenu.allCases {
            let ids = StudioMenuPlan.items(in: menu).map(\.name)
                + StudioMenuPlan.viewRows(in: menu).map(\.id)
            XCTAssertGreaterThan(ids.count, 1, "the \(menu.title) menu has nothing to share a reason")
            let lines = StudioMenuLayout.footerLines(reasons: ids.map { bridge.reason(for: $0) })
            XCTAssertEqual(
                lines.joined(separator: " "), StudioMenuBridge.studioNotOpenReason,
                """
                The \(menu.title) menu's footer is \(lines.count) line(s) over \
                \(ids.count) items that all share one reason. It must be that one \
                sentence, wrapped, and no more.
                """)
        }

        // The View menu — the one the defect was reported against.
        let viewIDs = StudioMenuPlan.viewMenuRows().map(\.id)
        XCTAssertEqual(viewIDs.count, 7, "the View menu no longer carries the seven rows this lane is about")
        let viewLines = StudioMenuLayout.footerLines(reasons: viewIDs.map { bridge.reason(for: $0) })
        XCTAssertEqual(viewLines.joined(separator: " "), StudioMenuBridge.studioNotOpenReason)
        XCTAssertLessThanOrEqual(
            viewLines.count, 4,
            "the View menu's footer is \(viewLines.count) lines deep, which is a wall of grey text again")
    }

    /// The other half, and the one that makes the pair non-vacuous: two
    /// DIFFERENT reasons must both survive, not be collapsed to the first.
    func testTwoDifferentReasonsAreBothKeptAndNeitherIsRepeated() {
        let a = StudioPaletteContext.noClipReason
        let b = StudioPaletteContext.noTrackReason
        XCTAssertNotEqual(a, b, "the two reasons this test contrasts are the same string")

        let lines = StudioMenuLayout.footerLines(reasons: [a, nil, b, a, b, nil, a])
        let joined = lines.joined(separator: " ")
        XCTAssertEqual(
            joined,
            [a, b].map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .joined(separator: " "),
            "the footer is \"\(joined)\" — it either lost a reason or repeated one")

        XCTAssertTrue(
            StudioMenuLayout.footerLines(reasons: [nil, nil, nil]).isEmpty,
            "a menu with nothing blocked still draws a footer, and therefore a divider onto nothing")
    }

    /// THE WIDTH CLAIM, typeset rather than counted.
    ///
    /// ⚠️ This measures the TEXT, in the menu's own font, and an `NSMenu` is
    /// wider than its widest string by a chrome inset (the state column on the
    /// left, the key-equivalent column and padding on the right). So the number
    /// here is a floor on the menu's width, not the width — which is the right
    /// way round for a guard, and is why the bound is generous rather than
    /// tight. The rendered menu is the one thing this lane could not see; see
    /// the report.
    ///
    /// The bound is set by the items the Studio's rows sit UNDER: `Go to
    /// Publisher`, `Zoom In`, `Zoom Out`, `Actual Size`. Those are macOS's and
    /// this app's own idiom, and a Studio row wider than all of them is a row
    /// that has gone back to being a sentence.
    func testTheViewMenuIsNoWiderThanTheItemsItSitsUnder() {
        StudioMenuBridge.shared.uninstall()
        let bridge = StudioMenuBridge.shared

        let rows = StudioMenuPlan.viewMenuRows()
        let itemWidths = rows.map { (row: $0.label, width: Self.menuTextWidth($0.label)) }
        let footer = StudioMenuLayout.footerLines(
            reasons: rows.map { bridge.reason(for: $0.id) })
        let footerWidths = footer.map { (row: $0, width: Self.menuTextWidth($0)) }

        // 220 pt is roughly "Split Song into Stems…" — three words and change,
        // which is the widest NAME any of these rows should ever need.
        for (label, width) in itemWidths {
            XCTAssertLessThanOrEqual(
                width, 220,
                """
                The View menu item "\(label)" typesets \(Int(width.rounded())) pt. \
                A menu item's title is its NAME; at that width it is a sentence \
                again, and a menu is as wide as its widest item.
                """)
        }
        // The footer is allowed to be wider than an item — it is prose — but
        // not by so much that it becomes the thing that sets the menu's width.
        for (line, width) in footerWidths {
            XCTAssertLessThanOrEqual(
                width, 300,
                "the footer line \"\(line)\" typesets \(Int(width.rounded())) pt, so the footer is now what makes the menu wide")
        }

        let widest = (itemWidths + footerWidths).max { $0.width < $1.width }
        let widestWidth = widest?.width ?? 0
        XCTAssertLessThanOrEqual(
            widestWidth, 300,
            "the widest line in the View menu is \"\(widest?.row ?? "")\" at \(Int(widestWidth.rounded())) pt")

        // Non-vacuous: the string that shipped in 3.6.0 must FAIL this bound,
        // or the bound is measuring nothing. This is the exact title the owner
        // read off the running build.
        let shipped = "Fit the whole song on screen — " + StudioMenuBridge.studioNotOpenReason
        XCTAssertGreaterThan(
            Self.menuTextWidth(shipped), 600,
            "the 3.6.0 title measures under 600 pt, so the measurement is not measuring")
    }

    /// One string, typeset in the menu bar's own font.
    ///
    /// `NSFont.menuFont(ofSize: 0)` is the system menu font at its natural
    /// size, which is what an `NSMenuItem` actually draws its title in.
    private static func menuTextWidth(_ text: String) -> CGFloat {
        NSAttributedString(
            string: text,
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        ).size().width
    }

    /// Every sentence that can end up in a menu footer.
    ///
    /// ASKED OF THE ROWS THEMSELVES rather than listed here: one unstaged
    /// fixture, and then every palette row's own `availability` and every view
    /// row's own `viewBlock`. A test that carried its own copy of the reasons
    /// would pass on the day it was written and never see the sentence a future
    /// lane adds — which is the trap `testEveryCommandThePaletteOffersIsReachable…`
    /// is built around, one level down.
    ///
    /// ONE fixture, and the reasons are collected in a single pass. This class
    /// is `@MainActor` and `swift test` runs the XCTest and swift-testing suites
    /// concurrently in one process; the header on `declaredTitles` below records
    /// the run where per-test work in here starved sixteen unrelated async tests
    /// into failing.
    private static func everyReasonTheMenusCanShow() async -> [String] {
        var out: Set<String> = [StudioMenuBridge.studioNotOpenReason]
        let f = PaletteFixture()
        f.model.startPolling()
        await f.wait { f.model.snapshot != nil }
        defer { f.teardown() }

        // Deliberately unstaged — nothing selected, no roll, no routing focus —
        // which is the state in which most rows have something to say.
        let context = StudioPaletteContext(model: f.model)
        for command in StudioPaletteCommands.all {
            if let why = command.availability(in: context).reason { out.insert(why) }
        }
        for row in StudioMenuPlan.viewRows() {
            if let why = row.viewBlock?(context) { out.insert(why) }
        }
        return out.sorted()
    }

    /// A click that arrives on a greyed item anyway — a stale menu, a scripted
    /// press — must not act.
    func testRunningADisabledItemPutsNothingOnTheBus() async {
        let f = PaletteFixture()
        f.model.startPolling()
        await f.wait { f.model.snapshot != nil }
        defer { f.teardown() }

        StudioMenuBridge.shared.install { StudioPaletteContext(model: f.model) }
        StudioMenuBridge.shared.refresh()
        XCTAssertFalse(StudioMenuBridge.shared.isEnabled("clip.split"),
                       "clip.split reads as ready with nothing selected; this test proves nothing")

        StudioMenuBridge.shared.run("clip.split")
        try? await Task.sleep(nanoseconds: 200_000_000)
        let sent = await f.spy.names()
        XCTAssertFalse(sent.contains("clip.split"),
                       "a disabled menu item fired anyway and put clip.split on the bus")
        XCTAssertFalse(f.model.paletteShown,
                       "a disabled menu item opened the palette instead of refusing")
    }

    // MARK: - 5. Dispatch: the item reaches the JOURNAL, with its own name

    /// Every `.send` item. Not a sample, and an item nobody can stage FAILS
    /// rather than being quietly skipped — the rule `StudioPaletteReachTests`
    /// set, for the same reason.
    func testEverySendItemReachesTheCommandBusWithItsOwnName() async {
        var proven: [String] = []
        let sendItems = StudioMenuPlan.items.filter { $0.action == .send }
        XCTAssertGreaterThanOrEqual(sendItems.count, 20, "almost nothing is a direct-send item")

        for item in sendItems {
            let f = PaletteFixture()
            await f.stageStandard()
            if let extra = PaletteStaging.extra[item.name] { await extra(f) }
            StudioMenuBridge.shared.install { f.context }
            StudioMenuBridge.shared.refresh()

            guard StudioMenuBridge.shared.isEnabled(item.name) else {
                XCTFail("""
                    \(item.name) is in a menu but nothing could make it runnable — it \
                    stayed disabled with "\(StudioMenuBridge.shared.reason(for: item.name) ?? "?")". \
                    Either stage it, or stop putting it in a menu.
                    """)
                f.teardown()
                continue
            }

            StudioMenuBridge.shared.run(item.name)

            // `project.save` is the one row that does not ride the view model's
            // bus — `StudioProjectSaver` is a singleton holding its own engine,
            // so asserting on THIS fixture's spy would pass or fail on test
            // ORDER. It is proven on the saver's own state machine instead,
            // exactly as StudioPaletteReachTests proves it.
            if item.name == "project.save" {
                var landed = false
                await f.wait(timeout: 3.0) {
                    if case .saved(let date) = StudioProjectSaver.shared.status, date != nil {
                        landed = true
                    }
                    return landed
                }
                XCTAssertTrue(landed, "Song ▸ Save the project never drove a written checkpoint")
                if landed { proven.append(item.name) }
                f.teardown()
                continue
            }

            let reached = await f.busSaw(item.name)
            XCTAssertTrue(
                reached,
                """
                \(item.name): the menu LISTS it, it read as enabled, and selecting it \
                put nothing on the command bus. That is the "listed but inert" item \
                this whole arrangement exists to make impossible.
                """)
            if reached { proven.append(item.name) }
            f.teardown()
        }

        XCTAssertEqual(
            proven.count, sendItems.count,
            "unproven menu items: \(Set(sendItems.map(\.name)).subtracting(proven).sorted())")
    }

    /// Every `.askInPalette` item — the rows that need a value or a second
    /// Return. A menu cannot ask a question, so these open ⌘K on the question,
    /// and the assertion runs the whole way through to the bus: menu → seed →
    /// the palette's own flow → commit → journal.
    func testEveryAskItemOpensThePaletteOnItsQuestionAndThatQuestionReachesTheBus() async {
        var proven: [String] = []
        let askItems = StudioMenuPlan.items.filter { $0.action == .askInPalette }
        XCTAssertGreaterThanOrEqual(askItems.count, 15, "almost nothing asks a question")

        for item in askItems {
            let f = PaletteFixture()
            await f.stageStandard()
            if let extra = PaletteStaging.extra[item.name] { await extra(f) }
            StudioMenuBridge.shared.install { f.context }
            StudioMenuBridge.shared.refresh()

            guard StudioMenuBridge.shared.isEnabled(item.name) else {
                XCTFail("\(item.name) could not be staged: \(StudioMenuBridge.shared.reason(for: item.name) ?? "?")")
                f.teardown()
                continue
            }

            XCTAssertTrue(item.label.hasSuffix("…"),
                          "\(item.name) asks a question but its menu item makes no such promise: \(item.label)")

            StudioMenuBridge.shared.run(item.name)
            XCTAssertEqual(f.model.paletteSeed, item.name,
                           "\(item.name): the menu did not hand the palette its row")
            XCTAssertTrue(f.model.paletteShown, "\(item.name): the palette never opened")

            // What the palette will show, from the same pure function the view
            // calls in `onAppear`.
            guard let seeded = StudioPaletteFlow.seeded(item.name, in: f.context) else {
                XCTFail("\(item.name): the palette had no question to open on")
                f.teardown()
                continue
            }
            switch seeded.stage {
            case .argument(let name), .confirming(let name):
                XCTAssertEqual(name, item.name, "the palette opened on a DIFFERENT row")
            case .browsing:
                XCTFail("\(item.name): seeded straight back to browsing, so the menu asked nothing")
            }
            XCTAssertFalse(seeded.prompt.isEmpty, "\(item.name): the question is blank")

            // Now answer it exactly as Return does, and follow it to the bus.
            guard let command = StudioMenuPlan.command(named: item.name) else {
                XCTFail("\(item.name) has no palette row")
                f.teardown()
                continue
            }
            let typed = PaletteStaging.typedOverride[item.name] ?? seeded.typed
            guard case .commit(let value) = StudioPaletteFlow.step(
                for: command, stage: seeded.stage, typed: typed, in: f.context
            ) else {
                XCTFail("\(item.name): answering the menu's own question did not commit")
                f.teardown()
                continue
            }
            command.perform(f.context, value)
            let reached = await f.busSaw(item.name)
            XCTAssertTrue(
                reached,
                "\(item.name): the menu opened the question, the question was answered, and nothing reached the bus")
            if reached { proven.append(item.name) }
            f.teardown()
        }

        XCTAssertEqual(
            proven.count, askItems.count,
            "unproven menu items: \(Set(askItems.map(\.name)).subtracting(proven).sorted())")
    }

    /// A destructive row must not fire from a menu click. It carries an
    /// ellipsis and opens the confirmation, exactly as ⌘K does — one extra
    /// Return against a mis-fired delete is a trade worth making, and a menu
    /// item is far easier to hit by accident than a fuzzy match.
    func testADestructiveItemAsksRatherThanDeleting() async {
        let f = PaletteFixture()
        await f.stageStandard()
        defer { f.teardown() }
        StudioMenuBridge.shared.install { f.context }
        StudioMenuBridge.shared.refresh()

        let remove = StudioMenuPlan.item(named: "clip.remove")
        XCTAssertEqual(remove?.action, .askInPalette,
                       "clip.remove fires straight from a menu click")

        StudioMenuBridge.shared.run("clip.remove")
        try? await Task.sleep(nanoseconds: 200_000_000)
        let sent = await f.spy.names()
        XCTAssertFalse(sent.contains("clip.remove"),
                       "selecting Clip ▸ Delete deleted the clip without asking")
        XCTAssertEqual(f.model.paletteSeed, "clip.remove")

        let seeded = StudioPaletteFlow.seeded("clip.remove", in: f.context)
        XCTAssertEqual(seeded?.stage, .confirming(name: "clip.remove"))
        XCTAssertTrue(seeded?.prompt.lowercased().contains("return again") == true,
                      "the confirmation does not say what to press: \(seeded?.prompt ?? "")")
    }

    /// A view row reaches this build's own state. Same claim, different bus:
    /// there is no catalog command behind `studio.toggleMixer`, and the row
    /// must never pretend there is.
    func testAViewRowFromAMenuChangesThisBuildsOwnState() async {
        let f = PaletteFixture()
        await f.stageStandard()
        defer { f.teardown() }
        StudioMenuBridge.shared.install { f.context }
        StudioMenuBridge.shared.refresh()

        let before = f.model.mixerCollapsed
        StudioMenuBridge.shared.run("studio.toggleMixer")
        XCTAssertNotEqual(f.model.mixerCollapsed, before,
                          "View ▸ Mixer did nothing")
    }

    // MARK: - 6. Navigation — the other half of "menus for all the sections"

    /// The tags are `ContentView`'s own `.tag(...)` literals and cannot be
    /// imported, so they are checked against the source.
    ///
    /// BOTH halves matter: presence alone would miss a SEVENTH tab, and a count
    /// alone would miss a RENUMBER. Together they fail on either.
    func testEverySectionsTagIsARealTabInContentView() throws {
        let content = try source("ContentView.swift")
        for section in StudioSection.allCases {
            XCTAssertTrue(
                content.contains(".tag(\(section.tag))"),
                "\(section.title) claims tab tag \(section.tag), which ContentView does not declare")
        }
        // ⚠️ `.tag(` on its own counts SEVEN, because ContentView's own header
        // comment contains the words "the `.tag(...)` calls in `body`". A
        // `contains` that matches a COMMENT ABOUT the line it is policing is a
        // guard this repo has already shipped once; the digit is what makes
        // this one read the code.
        let tagPattern = try NSRegularExpression(pattern: #"\.tag\(\d+\)"#)
        let declared = tagPattern.numberOfMatches(
            in: content, range: NSRange(content.startIndex..., in: content))
        XCTAssertEqual(
            declared, StudioSection.allCases.count,
            """
            ContentView declares \(declared) tabs and StudioSection names \
            \(StudioSection.allCases.count). View ▸ Go to would be missing one, or \
            pointing at one that no longer exists.
            """)
        XCTAssertEqual(StudioSection.studio.tag, StudioRootView.tabTag,
                       "Go to Studio would open a different tab than the Studio's own tabTag")
    }

    func testTheGoToShortcutsAreOneThroughSixAndUnique() {
        let keys = StudioSection.inTabStripOrder.compactMap(\.shortcutKey)
        XCTAssertEqual(keys.count, StudioSection.allCases.count)
        XCTAssertEqual(Set(keys).count, keys.count, "two sections share a shortcut: \(keys)")
        XCTAssertEqual(String(keys), "123456")
        XCTAssertEqual(Set(StudioSection.inTabStripOrder), Set(StudioSection.allCases),
                       "the strip order is missing a section, so one pane has no Go to item")
    }

    // MARK: - 7. TWO MENUS WITH THE SAME WORD ON THEM
    //
    // The defect this section exists to make impossible, in the owner's words:
    // his menu bar read
    //
    //     File · Edit · View · Song · Track · Clip · Transport · Library ·
    //     Playback · Publisher · View · Window · Window · Help
    //
    // Two Views and two Windows, for two years and one release respectively.
    // Nothing here caught it, and nothing here COULD: every test above reasons
    // about `StudioMenuPlan`, which knows what goes INSIDE a menu and has never
    // known what the menus are called.
    //
    // The cause is one sentence: `CommandMenu` always creates a NEW top-level
    // menu. macOS auto-creates View and Window for any WindowGroup app, so
    // `CommandMenu("View")` is a second one, always, silently, and it compiles.
    // `CommandGroup(before:)` with a `CommandGroupPlacement` is the only thing
    // that puts items into a menu the system already owns.
    //
    // ⚠️ WHAT THESE GUARDS CANNOT SEE — say it here so nobody mistakes a green
    // run for a clean menu bar:
    //
    //   * They read the menus this app DECLARES. The ones macOS adds at runtime
    //     are known to them only as `menuTitlesMacOSMakesItself` below, which is
    //     a hardcoded fact about the platform. If a future macOS adds a seventh
    //     auto menu, these pass and the menu bar is wrong.
    //   * They cannot see WHERE a `CommandGroup` actually lands. `.sidebar` and
    //     `.windowList` are resolved by macOS; that the View items appear in the
    //     View menu at all is a claim only a person opening the menu can settle.
    //   * They cannot see a collision between an app shortcut and a SYSTEM one
    //     (⌃⌘S Show Sidebar, ⌘M Minimize, ⌃⌘F Enter Full Screen). Those keys
    //     appear in no source file. The third test below covers only the half
    //     that IS in the source — Main.swift colliding with itself, which is the
    //     half that was actually broken.
    //   * `testTheRunningMenuBarIsNotReachableFromTheTestTarget` pins WHY these
    //     are source scans, and fails the day that stops being true.

    /// The top-level menus macOS/SwiftUI creates on its own for a
    /// WindowGroup-based app.
    ///
    /// A fact about the PLATFORM, not a copy of anything this app declares —
    /// which is the whole reason comparing the two is a claim and not a
    /// tautology. (Format appears only for an app with text-editing commands;
    /// it is listed anyway, because declaring `CommandMenu("Format")` would be
    /// the same mistake waiting for the day someone adds a `TextEditor`.)
    private static let menuTitlesMacOSMakesItself: Set<String> =
        ["File", "Edit", "Format", "View", "Window", "Help"]

    /// The top-level menu titles this app declares, READ out of the two files
    /// that declare them.
    ///
    /// ⚠️ Read, never listed. A test that carries its own copy of the menu
    /// titles and then checks that copy proves nothing — it is the constant
    /// compared against itself this repo has already shipped once, and it is
    /// the obvious wrong way to write exactly this guard.
    ///
    /// Both forms the app really uses are parsed: the string literal
    /// (`CommandMenu("Library")`) and the enum
    /// (`CommandMenu(StudioMenu.song.title)`).
    /// `testTheMenuTitleScanReadsTheMenusThatAreActuallyThere` fails if EITHER
    /// branch stops matching, so neither can quietly rot into a scan of nothing
    /// while the two guards below keep passing on half a menu bar.
    ///
    /// Comments are STRIPPED first, and that is load-bearing rather than tidy:
    /// the paragraph above and Main.swift's own warning both write
    /// `CommandMenu("View")` inside prose explaining why it must never be
    /// written. An unstripped scan would be answered by the warning instead of
    /// by the code — the precise trap `code(_:)` was added for.
    /// ⚠️ COMPUTED ONCE FOR THE WHOLE CLASS, and that is a correctness fix
    /// rather than a tidiness one. MEASURED, on a quiet box with a fresh
    /// `.build`, all three runs otherwise identical:
    ///
    ///   | code under test                       | gate 6 | failing |
    ///   |---------------------------------------|--------|---------|
    ///   | pristine (twice)                      | 0      | 0       |
    ///   | the Main.swift menu fix alone         | 0      | 0       |
    ///   | the menu fix + these guards, UNCACHED | 1      | 16      |
    ///
    /// Sixteen unrelated async tests — transport, metronome, reachability —
    /// started failing with `sent → []` because of THESE tests. `swift test`
    /// runs the XCTest and swift-testing suites CONCURRENTLY IN ONE PROCESS,
    /// this class is `@MainActor`, and the uncached version re-read and
    /// re-scanned two source files on every one of four guards. Blocking the
    /// main actor that much starves the async suites past their wait windows.
    ///
    /// So: read once, parse once, hold the answer. A test that makes OTHER
    /// tests fail is a defect in the test, and "those tests were already
    /// flaky" is not a defence — these are what tipped them over.
    private static let declaredTitles: [String] = {
        guard
            let literal = try? NSRegularExpression(pattern: #"CommandMenu\(\s*"([^"]*)"\s*\)"#),
            let viaEnum = try? NSRegularExpression(pattern: #"CommandMenu\(\s*StudioMenu\.(\w+)\.title\s*\)"#)
        else { return [] }

        var titles: [String] = []
        for file in ["Main.swift", "Studio/StudioMenuCommands.swift"] {
            let text = codeOnce(file)
            let range = NSRange(text.startIndex..., in: text)
            for match in literal.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                titles.append(String(text[r]))
            }
            for match in viaEnum.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text),
                      let menu = StudioMenu(rawValue: String(text[r])) else { continue }
                titles.append(menu.title)
            }
        }
        return titles
    }()

    /// `Main.swift`'s code with whitespace collapsed, computed once. Collapsing
    /// is what lets a shortcut split across two lines (⌘1…⌘6 is) be seen.
    private static let mainSwiftFlattenedCode: String =
        codeOnce("Main.swift").split(whereSeparator: \.isWhitespace).joined(separator: " ")

    /// Every `.keyboardShortcut(...)` argument string in Main.swift -> how many
    /// times it is written. Computed once; see `declaredTitles` for why.
    private static let mainSwiftShortcutCounts: [String: Int] = {
        guard let pattern = try? NSRegularExpression(pattern: #"\.keyboardShortcut\(([^)]*)\)"#)
        else { return [:] }
        let text = mainSwiftFlattenedCode
        var counts: [String: Int] = [:]
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            counts[String(text[r]), default: 0] += 1
        }
        return counts
    }()

    /// One source file, comments stripped, read from disk exactly once.
    ///
    /// A `static` twin of `code(_:)` because the caches above are `static` and
    /// cannot call an instance method. Same stripping rule, and the stripping
    /// is load-bearing for the same reason: Main.swift's own warning writes
    /// `CommandMenu("View")` inside the paragraph explaining why it must never
    /// be written, so an unstripped scan is answered by the warning.
    private static func codeOnce(_ relativePath: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources")
            .standardizedFileURL
            .appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    private func declaredTopLevelMenuTitles() throws -> [String] { Self.declaredTitles }

    /// Both branches of the scan are alive. Without this, either guard below
    /// could be reading three menus out of eleven and reporting green.
    func testTheMenuTitleScanReadsTheMenusThatAreActuallyThere() throws {
        let titles = try declaredTopLevelMenuTitles()

        // The ENUM branch. These four come from `StudioMenu` itself rather than
        // from a list written in this test, so this cannot be satisfied by its
        // own copy of the answer.
        for menu in StudioMenu.allCases {
            XCTAssertTrue(
                titles.contains(menu.title),
                """
                the scan found no `CommandMenu(StudioMenu.\(menu.rawValue).title)`. \
                Either the Studio's menus stopped being declared that way, or the \
                enum branch of the scan is dead and the duplicate guards below are \
                reading a partial menu bar.
                """)
        }

        // The LITERAL branch. Main.swift declares Library, Playback and
        // Publisher as plain strings; if that regex stopped matching, a
        // `CommandMenu("View")` written there is exactly what would slip past.
        XCTAssertGreaterThan(
            titles.count, StudioMenu.allCases.count,
            """
            the scan matched \(titles.count) menus and \(StudioMenu.allCases.count) \
            of them came from the enum branch, so the string-literal branch matched \
            NOTHING — which is the branch that has to see a hand-written \
            CommandMenu("View").
            """)
    }

    /// No two top-level menus carry the same word.
    ///
    /// This is the one that catches `File · Edit · … · Window · Window · Help`
    /// when both Windows are declared by this app.
    func testNoTwoTopLevelMenusShareATitle() throws {
        let titles = try declaredTopLevelMenuTitles()
        let duplicated = Set(titles.filter { title in titles.filter { $0 == title }.count > 1 })
        XCTAssertTrue(
            duplicated.isEmpty,
            """
            \(duplicated.sorted()) is declared as a top-level menu twice. \
            `CommandMenu` never merges — two of them means two menus with one word \
            between them on the menu bar, and which one a person opens is luck. \
            Put the second one's items into the first, or into the system menu \
            with a CommandGroup.
            """)
    }

    /// No app-declared menu shadows one macOS makes by itself.
    ///
    /// THE guard for the defect actually reported: both duplicates were the app
    /// declaring a menu the system had already made, so a same-file duplicate
    /// check would have seen nothing wrong at all.
    func testNoAppDeclaredMenuShadowsOneMacOSMakesItself() throws {
        let titles = try declaredTopLevelMenuTitles()
        let shadowed = Set(titles).intersection(Self.menuTitlesMacOSMakesItself)
        XCTAssertTrue(
            shadowed.isEmpty,
            """
            \(shadowed.sorted()) is declared with `CommandMenu`, and macOS creates a \
            menu of that name by itself for any WindowGroup app — so the menu bar \
            carries TWO. `CommandMenu` always makes a new top-level menu and has no \
            merge behaviour; use `CommandGroup(before:)` with the matching \
            `CommandGroupPlacement` (.sidebar / .toolbar for View, .windowList / \
            .windowArrangement / .windowSize for Window) to put items INTO the \
            system's menu. If the items genuinely have no placement, RENAME the \
            menu to what it actually is — a second "View" is worse than a menu \
            called "Sections".
            """)
    }

    /// Nothing in Main.swift binds a key equivalent something else in
    /// Main.swift already binds.
    ///
    /// ⚠️ THE COLLISION THIS FOUND, and the reason it is worth its length:
    /// `.keyboardShortcut` applied to a `Window` SCENE is the key equivalent of
    /// the Window-menu item SwiftUI generates for that scene. `Window("Library")`
    /// carried ⌥⌘L and `Window("Studio")` carried ⌥⌘S — the same two keys the
    /// Pop Out toggles bind. Four items, two keys, resolved by menu-bar order,
    /// and invisible from either declaration because they sat 70 lines apart in
    /// two different constructs.
    ///
    /// Whitespace is collapsed first so a shortcut split across two lines (⌘1…⌘6
    /// is) is seen. Comparing the argument text verbatim means
    /// `[.command, .shift]` and `[.shift, .command]` would read as different —
    /// a false negative, never a false positive, which is the right way round
    /// for a guard nobody is watching.
    private static let mainSwiftShortcutsWrittenTwiceOnPurpose: [String: String] = [
        #""?", modifiers: .command"#:
            """
            Help ▸ Majik's Music Studio Help binds ⌘? and the Help WINDOW scene \
            binds it too — but that scene calls `.commandsRemoved()`, so it \
            contributes no menu item and only one live item claims the key.
            """,
    ]

    func testNothingInMainSwiftBindsAShortcutSomethingElseInMainSwiftBinds() throws {
        let counts = Self.mainSwiftShortcutCounts
        XCTAssertGreaterThan(
            counts.count, 15,
            "the Main.swift shortcut scan found \(counts.count) bindings, so it is not scanning")

        for (binding, count) in counts where count > 1 {
            if let why = Self.mainSwiftShortcutsWrittenTwiceOnPurpose[binding] {
                XCTAssertGreaterThanOrEqual(why.count, 30, "\(binding): \"\(why)\" is too short to be a reason")
                continue
            }
            XCTFail("""
                `.keyboardShortcut(\(binding))` is written \(count) times in Main.swift. \
                Two menu items on one key resolve by menu-bar ORDER, which is not \
                visible from either site — this is how ⌥⌘L named both Window ▸ Pop Out \
                Library and the Library window scene's own item at the same time. \
                Drop one, or add it to mainSwiftShortcutsWrittenTwiceOnPurpose with a \
                reason that is true.
                """)
        }

        // The one exemption has to stay TRUE rather than superstitious: it is
        // only safe because the Help window suppresses its own menu item.
        XCTAssertTrue(
            Self.mainSwiftFlattenedCode.contains(".commandsRemoved()"),
            """
            ⌘? is exempted from the duplicate check because the Help window's scene \
            calls `.commandsRemoved()`. It no longer does, so ⌘? now names two live \
            menu items.
            """)
    }

    /// ⚠️ WHY THE THREE GUARDS ABOVE ARE SOURCE SCANS, pinned as a fact rather
    /// than left as a paragraph.
    ///
    /// The strongest version of this guard walks the real `NSApp.mainMenu` and
    /// asks the menu bar itself how many menus are called "View" — and would
    /// then also see the ones macOS adds, which no source scan can. It is not
    /// available: `swift test` runs an XCTest harness, not this app, so SwiftUI
    /// never turns a single `Commands` declaration into an `NSMenu` in this
    /// process. That was measured, not assumed.
    ///
    /// So this test asserts the LIMIT. The day the app's own menus do reach the
    /// test process, it fails by name and tells the next lane to replace the
    /// scans with the real traversal.
    func testTheRunningMenuBarIsNotReachableFromTheTestTarget() {
        let live = (NSApp?.mainMenu?.items ?? []).map(\.title)
        for declared in StudioMenu.allCases.map(\.title) + ["Library", "Playback", "Publisher"] {
            XCTAssertFalse(
                live.contains(declared),
                """
                `NSApp.mainMenu` carries "\(declared)", so this app's `Commands` DO \
                reach the test process now. The title guards above are source scans \
                only because that was false when they were written — replace them \
                with a traversal of the real menu bar, which can also see the menus \
                macOS adds and these cannot.
                """)
        }
    }

}
