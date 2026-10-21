import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// The help layer's gates.
//
// A test that asserts "a help string exists" is close to worthless: the failure
// mode here is not an absent string, it is a PRESENT string that teaches
// nothing ("Solo — solo"), or a catalog entry that quietly stopped being
// attached to any control. So these hold three things that can actually rot:
//
//  1. CONTENT. Every entry's `teaching` says something its label does not.
//     Empty, or a restatement of the terse name, or shorter than the terse
//     name, is a failure.
//  2. ATTACHMENT. Every catalog id is referenced from the app sources. Strip
//     `.studioHelp(...)` off one control and this test names the id that went
//     dark — which is exactly the mutation check.
//  3. GROWTH. The number of interactive controls in each covered file is
//     PINNED. Adding a Button, Toggle, Picker or Menu fails the build until
//     someone either gives it help or writes down why it does not need any.
//     That is the only mechanism that survives the author of a future lane not
//     having read any of this.
//
// Plus the preference itself: `.off` must genuinely stop showing tooltips, and
// must NOT take VoiceOver's description away with them.

final class StudioHelpTests: XCTestCase {

    // MARK: - 1. Content

    func testEveryEntryHasBothRegistersFilledIn() {
        for entry in StudioHelpCatalog.entries {
            XCTAssertFalse(entry.terse.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(entry.id): terse is empty")
            XCTAssertFalse(entry.teaching.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(entry.id): teaching is empty")
            XCTAssertFalse(entry.control.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(entry.id): control is empty, so a coverage report cannot be read next to the screen")
        }
    }

    /// The rule the whole lane rests on: the tooltip says what the control DOES.
    /// A `teaching` that merely repeats the name, or the glyph, is the failure
    /// this catalog exists to prevent, not evidence against it.
    func testTeachingNeverJustRepeatsTheLabel() {
        for entry in StudioHelpCatalog.entries {
            let teaching = entry.teaching.lowercased()
            let terse = entry.terse.lowercased()
            let control = entry.control.lowercased()

            XCTAssertNotEqual(teaching, terse,
                              "\(entry.id): teaching is identical to the terse name, so it teaches nothing")
            XCTAssertNotEqual(teaching, control,
                              "\(entry.id): teaching is just the on-screen label")
            XCTAssertGreaterThan(
                entry.teaching.count, entry.terse.count,
                "\(entry.id): teaching (\(entry.teaching.count) chars) is no longer than the terse name (\(entry.terse.count)), so it cannot be saying more")
            // A full sentence, not a fragment. The floor is deliberately low
            // enough that a genuinely short-but-complete explanation passes.
            XCTAssertGreaterThanOrEqual(
                entry.teaching.count, 30,
                "\(entry.id): teaching is too short to explain anything: \"\(entry.teaching)\"")
        }
    }

    func testIDsAreUnique() {
        var seen = Set<String>()
        for entry in StudioHelpCatalog.entries {
            XCTAssertTrue(seen.insert(entry.id).inserted, "duplicate help id: \(entry.id)")
        }
        XCTAssertEqual(seen.count, StudioHelpCatalog.byID.count,
                       "entries and byID disagree, so a lookup silently misses an entry")
    }

    /// The sharp end of the jargon. Walks the REAL parameter tables, so a new
    /// DSP parameter cannot land with an unexplained knob.
    func testEveryEffectParameterHasHelp() {
        for kind in StudioFxKind.allCases {
            for spec in kind.params {
                let id = StudioHelpCatalog.fxParamHelpID(spec.key)
                XCTAssertNotNil(
                    StudioHelpCatalog.entry(id),
                    "\(kind.label) parameter \"\(spec.key)\" (\(spec.label)) has no help entry \(id)")
            }
        }
    }

    // MARK: - 2. The preference

    func testTheDefaultServesSomeoneWhoHasNeverUsedADAW() {
        XCTAssertEqual(StudioHelpVerbosity.default, .teaching)
        XCTAssertEqual(StudioHelpVerbosity.from("nonsense"), .teaching,
                       "an unreadable stored value must fall back to the teaching default, not to silence")
        XCTAssertTrue(StudioHelpVerbosity.storageKey.hasSuffix(".v1"),
                      "the preference key must be versioned")
    }

    /// The mutation check for the preference: make `resolve` ignore its
    /// verbosity argument and this fails.
    func testTheVerbosityPreferenceChangesWhatIsShown() {
        let entry = try! XCTUnwrap(StudioHelpCatalog.entry("mixer.solo"))

        let teaching = StudioHelpCatalog.resolve(entry, verbosity: .teaching)
        let terse = StudioHelpCatalog.resolve(entry, verbosity: .terse)
        let off = StudioHelpCatalog.resolve(entry, verbosity: .off)

        XCTAssertEqual(teaching.tooltip, entry.teaching)
        XCTAssertEqual(terse.tooltip, entry.terse)
        XCTAssertNil(off.tooltip, "\"No tooltips\" must show no tooltip, not an empty one")

        XCTAssertNotEqual(teaching.tooltip, terse.tooltip,
                          "the two visible levels are indistinguishable, so the preference is a no-op")
    }

    /// Turning tooltips off is a statement about hover, not about assistive
    /// technology. Silencing VoiceOver as a side effect would be a regression.
    func testTurningTooltipsOffDoesNotSilenceVoiceOver() {
        for entry in StudioHelpCatalog.entries {
            let off = StudioHelpCatalog.resolve(entry, verbosity: .off)
            XCTAssertNil(off.tooltip, "\(entry.id): tooltip survives .off")
            XCTAssertEqual(off.accessibilityHint, entry.teaching,
                           "\(entry.id): VoiceOver lost the explanation when tooltips were turned off")
        }
    }

    func testAnUnknownIDResolvesToNothingRatherThanAnEmptyTooltip() {
        XCTAssertNil(StudioHelpCatalog.resolve("no.such.control", verbosity: .teaching))
    }

    // MARK: - 3. Attachment and growth (source scan)

    private static let sourcesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // Tests
        .appendingPathComponent("../Sources")
        .standardizedFileURL

    /// Every `.swift` under Sources except the help layer itself (whose whole
    /// job is to hold the ids, so it would satisfy any cross-check trivially).
    private func appSources() throws -> [(name: String, text: String)] {
        let fm = FileManager.default
        let enumerator = try XCTUnwrap(
            fm.enumerator(at: Self.sourcesDirectory, includingPropertiesForKeys: nil),
            "cannot enumerate \(Self.sourcesDirectory.path)")
        var out: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard url.lastPathComponent != "StudioHelp.swift" else { continue }
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 20, "the source scan found almost nothing, so it is not scanning")
        return out
    }

    /// Ids that legitimately live only inside the help layer.
    private static let idsAppliedInsideTheHelpLayer: Set<String> = [
        // The verbosity menu is itself part of StudioHelp.swift, and its own
        // tooltip is deliberately a plain `.help` so it keeps explaining itself
        // after the user has turned tooltips off.
        "toolbar.help",
    ]

    /// THE mutation check. Delete `.studioHelp("mixer.solo")` from the mixer
    /// strip and this fails naming `mixer.solo`.
    ///
    /// `fx.param.*` ids are excluded on purpose: they are applied through
    /// `fxParamHelpID(spec.key)` rather than as literals, and
    /// `testEveryEffectParameterHasHelp` checks them against the real DSP
    /// parameter tables, which is a stronger check than a text search.
    func testEveryCatalogEntryIsAttachedToAControl() throws {
        let sources = try appSources()
        var orphans: [String] = []

        for entry in StudioHelpCatalog.entries {
            if entry.id.hasPrefix("fx.param.") { continue }
            if Self.idsAppliedInsideTheHelpLayer.contains(entry.id) { continue }
            let needle = "\"\(entry.id)\""
            if !sources.contains(where: { $0.text.contains(needle) }) {
                orphans.append(entry.id)
            }
        }

        XCTAssertTrue(
            orphans.isEmpty,
            "these help entries are attached to no control, so nothing shows them: \(orphans.sorted().joined(separator: ", "))")
    }

    /// The reverse: a `.studioHelp("…")` call site whose id is not in the
    /// catalog renders no tooltip at all and would be invisible in review.
    func testEveryAppliedIDExistsInTheCatalog() throws {
        let pattern = try NSRegularExpression(pattern: #"\.studioHelp\(\s*"([^"]+)"\s*\)"#)
        var unknown: [String] = []
        var applied = 0

        for source in try appSources() {
            let range = NSRange(source.text.startIndex..., in: source.text)
            for match in pattern.matches(in: source.text, range: range) {
                guard let r = Range(match.range(at: 1), in: source.text) else { continue }
                applied += 1
                let id = String(source.text[r])
                if StudioHelpCatalog.entry(id) == nil {
                    unknown.append("\(source.name): \(id)")
                }
            }
        }

        XCTAssertGreaterThan(applied, 40, "the scan matched almost no call sites, so it is not testing anything")
        XCTAssertTrue(unknown.isEmpty,
                      "these controls ask for help ids that do not exist: \(unknown.sorted().joined(separator: ", "))")
    }

    /// The growth tripwire.
    ///
    /// These counts are the number of interactive controls each covered file
    /// declares today. Adding a Button, Toggle, Picker, Menu or Slider changes
    /// the count and fails this test. The fix is never to just bump the number:
    /// give the new control a `.studioHelp(...)`, or write a
    /// `// help-exempt: <reason>` comment on it, and THEN bump the number.
    ///
    /// A count rather than a ratio because the two do not correspond one to one
    /// — a readout that is not a control still earns a tooltip, and a row of
    /// four chips shares one. A count is the honest thing to pin.
    private static let expectedControlCounts: [String: Int] = [
        // 16 -> 18: TWO lanes each added one Button here and each bumped this
        // to 17, which is how a merge turns two correct edits into one wrong
        // number. Both buttons are real, so the count is 18.
        //
        // +1  the "Open in Studio failed" alert's OK button. A landing that
        //     cannot separate now refuses with a message naming the fix, and
        //     that message had nowhere to appear -- `landingError` was written
        //     and never read. help-exempt: an alert button gets no hover
        //     tooltip on macOS.
        // +1  Effects became a word Button (like Keys) rather than a
        //     panelToggle call, so it adds its own `Button(` constructor.
        //
        // 18 -> 19: the "Could not split that song" alert's OK button. A split
        //     that refuses (demucs missing, no torch) now says so where the
        //     gesture happened, carrying the separator's own words.
        //     help-exempt: an alert button gets no hover tooltip on macOS.
        "StudioRootView.swift": 22,
        // 8 after the metronome landed: the click toggle, and the Menu that
        // sets how loud it is. Both carry `.studioHelp`.
        //
        // Still 10 after the Loop button landed, and that is worth writing
        // down rather than looking like an oversight: the Loop button is built
        // by `transportButton(...)`, the shared builder that already produces
        // Play, Stop, Return-to-start and the metronome toggle, so it adds no
        // LITERAL `Button(` to this file. This number counts constructors, not
        // controls. What did move is the help floor below (20 -> 21), which
        // counts `helpID:` handed to that builder — which is exactly why that
        // net counts both forms.
        //
        // 10 -> 11: labeledTransportButton (Back / Fwd words) is a second
        // shared builder with its own `Button(` constructor. VOLUME is a
        // DragGesture control, not a Button/Slider, so it does not move this.
        "StudioTransportBar.swift": 11,
        // 4 -> 9 with the quantize lane: the toolbar gained a Menu, and inside
        // it two action Buttons (Selection / All Notes in Clip), an Amount
        // Picker and a "quantize note ends" Toggle. Every one of those four is
        // help-exempt for the same reason the track header's menu items are —
        // macOS menu items get no hover tooltip — and the teaching for the
        // whole feature (what a strength is, and that Undo restores the
        // performance) lives on `pianoRoll.quantize`, the hover that leads a
        // person into the menu in the first place.
        "StudioPianoRollView.swift": 9,
        // 26 since the sampler lane: the "+ Instrument" slot became a Menu of
        // three (Synth / Sampler / Drum Rack), the chip became a button onto the
        // instrument panel, and the context menu gained "Edit <instrument>…"
        // plus the two sample-instrument creators. Every menu ITEM is
        // help-exempt (macOS menu items get no hover tooltip); the teaching for
        // all of them lives on `trackHeader.instrument.add` and
        // `trackHeader.row`, which are the hovers that lead a person there.
        "StudioTrackHeaderColumn.swift": 26,
        // 5 -> 6: the shared `nudge(_:_:)` builder that produces both of the
        // mixer's new chevrons. ONE `Button(` constructor for two on-screen
        // controls, and both carry help through it.
        "StudioMixerDock.swift": 6,
        // NEW to the net in the typed-controls lane, and it is the file that
        // most needed to be in it: `StudioMixerControls.swift` holds the two
        // primitives every numeric control in the Studio is built from, plus
        // the shared typed-value field they now embed. ONE `Button`
        // constructor — the `arrow(_:_:)` builder that produces both chevrons
        // for every knob, fader and slider in the product. A second control
        // appearing in here would be a control appearing fifty times on
        // screen, which is precisely the growth worth failing a build over.
        "StudioMixerControls.swift": 1,
        "StudioRoutingView.swift": 18,
        "StudioInspectorView.swift": 6,
        // 8 -> 12: Listen toggle, input-channel Menu, channel-meter strip,
        // and the microphone settings recovery button
        "StudioRecordBar.swift": 12,
        // STILL 4, and that is a coincidence of two offsetting edits rather than
        // "nothing changed" — which is exactly the state a merge gets wrong, so
        // it is written down. The Files section went (-1: its "Import audio…"
        // Button, a duplicate of the toolbar's always-visible Import), and the
        // Stems rows gained the shared `stemChip(_:on:tint:track:)` builder
        // (+1: ONE `Button(` constructor producing a Solo and a Mute for every
        // stem). If you are resolving a conflict here, check whether BOTH of
        // those are still true before touching the number.
        //
        // 4 -> 5: `stemLevelStep(_:by:glyph:)`, the shared builder behind the
        // − and + on every stem row. ONE `Button(` constructor for two
        // on-screen controls per stem, and it carries its own `.studioHelp`.
        // RAISED because the pane genuinely gained a control: the owner's
        // report was that Stems has nothing you can do with it, and solo and
        // mute are on/off — level is the first thing you actually want next.
        "StudioBrowserView.swift": 5,
        // NEW to the net with the sounds vault, and it joins deliberately
        // rather than sitting outside the table where a new file quietly can.
        // 4 constructors: the shared filter-chip builder (which produces all
        // six chips from one site), the ✕ inside the search box, "Choose sounds
        // folder…", and the sound row itself. The ✕ is help-exempt with the
        // reason at its call site; the other three carry `.studioHelp`, and the
        // chip builder carries its id through a `help:` parameter so each of
        // the six chips gets its own sentence.
        //
        // 4 -> 9 when the vault got its pipe. The browser could show sounds and
        // had no way to GET any, so five constructors joined: the "Get more
        // sounds…" disclosure, the pack-row builder (one site, N rows), Save
        // for the account key, Stop, and "Update tempos". Every one carries its
        // own `.studioHelp`; none is exempt, because none of them is a menu
        // item or an alert button.
        "StudioSoundsBrowser.swift": 10,
        // 13 -> 14: the shared `nudge(_:_:)` builder that produces both of the
        // tab strip's chevrons. ONE `Button(` constructor for two on-screen
        // controls, and both carry help through it. They replaced the strip's
        // overflow ScrollView — the conditional fallback that would have gone
        // dead on a longer tab word.
        "SettingsView.swift": 14,
        // New to the net in the loop lane. The arrangement canvas was outside
        // it — reasonably, since most of it is a `Canvas` with gestures rather
        // than controls — but its context menus ARE controls, and the loop lane
        // added two of them (Loop <section> / Clear Loop). Measured: 18
        // constructors, 9 help applications. Pinning it now means the next
        // context-menu item in here has to be a decision.
        // 18 -> 21: the visible tempo-confidence badge's Set tempo action
        // plus the two actions in its Set tempo alert. The alert actions are
        // help-exempt at their call sites because macOS gives them no hover
        // tooltip; the badge action carries the user-facing affordance.
        "StudioTimelineView.swift": 21,
        // The instrument panel: Done, Replace…, the pad button, and the pad's
        // Clear menu item. Done and Clear are help-exempt (see their call
        // sites); the pad's help rides `helpID:` through a shared builder so
        // all sixteen pads carry it from one application.
        //
        // 4 -> 8 with the SYNTH TONE EDITOR: the named-sound button, the
        // "Shape it yourself" disclosure, the waveform chip, and the raw
        // parameter slider. Each is a shared builder used several times over,
        // so four constructors cover five presets, four waveforms and five
        // sliders. All four carry help; the two inline ones (preset, waveform)
        // carry it inline because the useful half of the sentence is the
        // preset's / waveform's own description, which no static catalog entry
        // can hold.
        // 8 -> 9: the Load Drum Kit button that loads a folder of one-shots.
        "StudioInstrumentView.swift": 9,
        // NEW to the net with the stem breakout. The Stems tab had no help
        // coverage at all — it predates this lane and used plain `.help(...)`
        // strings on four of its controls and nothing on the rest — which is
        // how a surface whose two most important controls are called "S" and
        // "M" shipped with no explanation of either. 29 constructors: the
        // transport's four, three sliders in a lane, two in the transport, the
        // Solo/Mute pair, the row's overflow Menu, and the buttons inside the
        // three alerts, the session context menu and that overflow menu — all
        // of which are help-exempt (macOS gives menu items and alert buttons no
        // hover tooltip) with the reason written at each site.
        //
        // 29 -> 32 when this tab finally got the thing it is named after.
        // +1  the sidebar's "Split into Stems" — a full-width WORD button, not
        //     a glyph beside the +, because the owner's report was that he
        //     could not find this option in this pane at all and he reads it
        //     from a sofa. Carries `stems.separate`.
        // +1  the same offer in the EMPTY state, which is the screen he was
        //     actually looking at. Carries `stems.separate.empty`.
        // +1  the "Could not split that song" alert's OK button. help-exempt:
        //     macOS gives alert buttons no hover tooltip and the alert's own
        //     message is the explanation — which here is the separator's
        //     verbatim refusal naming the interpreter and the missing package.
        "StemSessionsView.swift": 32,
    ]

    /// The minimum number of `.studioHelp` applications each covered file must
    /// carry. Removing help fails here even when the catalog entry is still
    /// referenced from somewhere else.
    private static let expectedHelpFloors: [String: Int] = [
        "StudioRootView.swift": 4,
        // 20 -> 21: the Loop button, whose help rides `helpID:` into the shared
        // transport-button builder. RAISED because coverage genuinely grew by
        // one control's worth, which is the only reason a floor should ever
        // move. (A floor lowered to make a red net go green is how a net dies;
        // that mistake was made in this repo once already.)
        // 21 -> 22: master VOLUME on the transport strip (discoverability).
        "StudioTransportBar.swift": 22,
        "StudioPianoRollView.swift": 5,
        // 17 -> 18: the "Made when you played" line, which explains the one
        // track in the app that nobody asked for. RAISED because coverage
        // genuinely grew by one thing that needs explaining.
        "StudioTrackHeaderColumn.swift": 18,
        // 22 -> 23: the chevrons' `.studioHelp(...)`, applied once in the
        // shared builder and inherited by both. Two lanes raised counts in
        // this table concurrently and git could not tell that the edits were
        // to DIFFERENT rows — if you hit that conflict again, the answer is
        // almost always both numbers, not either.
        "StudioMixerDock.swift": 23,
        // 5: the field's own `.studioHelp(helpID)`, the two arrows' entries,
        // and the `helpID:` the two faders hand in. Applied ONCE here and
        // inherited by every call site — which is the point of the file.
        "StudioMixerControls.swift": 5,
        // 17 -> 18: empty-chain effects catalog list (discoverability).
        "StudioRoutingView.swift": 18,
        "StudioInspectorView.swift": 13,
        // 11 -> 16: MIC OPEN chip, Listen, input channel, per-channel meters,
        // and microphone settings recovery.
        "StudioRecordBar.swift": 16,
        // 2 -> 3: the stem row's `stemChip` builder, whose single
        // `.studioHelp(...)` puts a distinct sentence on the Solo and the Mute.
        // RAISED because coverage genuinely grew — those two chips are the most
        // important controls in that pane and neither spells its own name.
        //
        // 3 -> 5: the stem row's level. TWO applications, and both earn their
        // place: `browser.stem.level.step` rides the shared `stemLevelStep`
        // builder onto the − and the +, and `browser.stem.level` sits on the dB
        // readout, which is not a control and is still the one thing in that
        // row a person has to be told how to read. "0.0 dB" means nothing to
        // somebody who has never opened a DAW.
        "StudioBrowserView.swift": 5,
        // 4: the search box, the chip builder, the folder picker and the row.
        // The chip builder's single application is what puts a distinct
        // sentence on each of All / Hits / Loops / Stems / In tempo / In key.
        //
        // 4 -> 10 with the pipe. RAISED because coverage genuinely grew: five
        // new Buttons plus the key `SecureField`, which is not a Button
        // constructor and still earns a sentence — it is the one control in the
        // Studio that asks a person for a credential, so it had better say what
        // happens to it.
        "StudioSoundsBrowser.swift": 10,
        // 1 -> 2: the tab strip's two chevrons, whose help rides one
        // `.studioHelp(...)` in the shared `nudge` builder. RAISED because
        // coverage genuinely grew by a control's worth.
        "SettingsView.swift": 2,
        // 7 before the loop lane, 9 after (Loop <section>, Clear Loop). Both
        // carry inline `.studioHelp(terse:teaching:)` like the section and
        // marker items beside them.
        // 9 -> 10: the visible Set tempo affordance carries inline help.
        "StudioTimelineView.swift": 10,
        // 6 -> 16: the tone editor's four controls, each applied through both
        // forms (inline `.studioHelp` on the preset and waveform chips, and
        // `helpID:` handed into the shared `StudioParamSlider`).
        // 16 -> 17: the Load Drum Kit button.
        "StudioInstrumentView.swift": 17,
        // Every hoverable control in the Stems tab, plus the readouts that are
        // not controls but still earn a tooltip: the two dB labels, the pan
        // label, both meters, the waveform lane and the shared ruler.
        //
        // 24 -> 26: `stems.separate` and `stems.separate.empty`. RAISED because
        // coverage genuinely grew by two controls' worth, and they are the two
        // that answer "I don't see that option in the stems section".
        "StemSessionsView.swift": 26,
    ]

    func testCoveredFilesHaveNotGrownNewControlsWithoutADecision() throws {
        let controlPattern = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_.])(Button|Toggle|Picker|Menu|Slider)\s*[({]"#)

        let byName = Dictionary(uniqueKeysWithValues: try appSources().map { ($0.name, $0.text) })

        for (name, expected) in Self.expectedControlCounts.sorted(by: { $0.key < $1.key }) {
            let text = try XCTUnwrap(byName[name], "covered file \(name) is gone; update the coverage table")
            let range = NSRange(text.startIndex..., in: text)
            let found = controlPattern.numberOfMatches(in: text, range: range)
            XCTAssertEqual(
                found, expected,
                """
                \(name) has \(found) interactive controls, the coverage table says \(expected).
                A control was added or removed. Give any new one a `.studioHelp(...)` or a \
                `// help-exempt: <reason>` comment, then update expectedControlCounts.
                """)
        }
    }

    func testCoveredFilesStillApplyTheirHelp() throws {
        let byName = Dictionary(uniqueKeysWithValues: try appSources().map { ($0.name, $0.text) })

        for (name, floor) in Self.expectedHelpFloors.sorted(by: { $0.key < $1.key }) {
            let text = try XCTUnwrap(byName[name], "covered file \(name) is gone; update the coverage table")
            // Count BOTH forms of attachment. A control can carry help either
            // directly (`.studioHelp("id")`) or by passing `helpID:` into a
            // shared builder that applies it once for every caller. Counting
            // only the former made this net report a REGRESSION when two
            // controls were refactored onto one builder — coverage was
            // unchanged, the text just moved. A guard that cries wolf gets
            // its floor lowered, which is how a real net dies.
            let direct = text.components(separatedBy: ".studioHelp(").count - 1
            let viaBuilder = text.components(separatedBy: "helpID:").count - 1
            let count = direct + viaBuilder
            XCTAssertGreaterThanOrEqual(
                count, floor,
                "\(name) applies help \(count) times, which is below its floor of \(floor): help was removed from a control")
        }
    }

    /// The surfaces the help layer covers, named, so a reader can tell what is
    /// IN it from what merely has no test.
    func testTheCoverageTableAndTheHelpFloorsDescribeTheSameFiles() {
        XCTAssertEqual(Set(Self.expectedControlCounts.keys), Set(Self.expectedHelpFloors.keys))
    }

    /// The track header column is called out by name because it is where the
    /// help layer's founding bug actually happened: a user could not find how
    /// to delete a track, and the answer was a context menu with no tooltip on
    /// it. It was the largest uncovered file when the first help lane finished,
    /// only because a concurrent lane owned it.
    ///
    /// So this is not a duplicate of the table above — the table would still be
    /// satisfied if some future edit dropped the file out of both dictionaries
    /// at once. This asserts the file is in the net at all, and that the one
    /// entry which is the whole point of covering it is still attached.
    func testTheTrackHeaderIsInTheCoverageNet() throws {
        XCTAssertNotNil(Self.expectedControlCounts["StudioTrackHeaderColumn.swift"],
                        "the track header dropped out of the coverage table")
        XCTAssertNotNil(Self.expectedHelpFloors["StudioTrackHeaderColumn.swift"])

        let header = try XCTUnwrap(
            try appSources().first(where: { $0.name == "StudioTrackHeaderColumn.swift" })?.text)
        XCTAssertTrue(
            header.contains("\"trackHeader.row\""),
            "the row-level tooltip is gone: it is the only thing that tells a hovering user the delete lives in a right-click")
        XCTAssertTrue(
            header.contains(".contextMenu"),
            "the row tooltip promises a right-click menu that is no longer here")
    }

    /// The row tooltip has to name the gesture AND the two things it reaches,
    /// because that sentence is the entire discovery path for both destructive
    /// actions in the Studio.
    func testTheRowTooltipNamesTheRightClickAndWhatItReaches() throws {
        let entry = try XCTUnwrap(StudioHelpCatalog.entry("trackHeader.row"))
        let teaching = entry.teaching.lowercased()
        for needle in ["right-click", "delete", "instrument", "cmd-z"] {
            XCTAssertTrue(teaching.contains(needle),
                          "trackHeader.row's teaching never says \"\(needle)\": \(entry.teaching)")
        }
    }
}
