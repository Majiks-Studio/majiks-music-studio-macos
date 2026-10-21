import XCTest
import SwiftUI
import AppKit
@testable import MajiksMusicStudio

// The Stems pane, after "I think stems is missing the controls to do anything".
//
// WHAT WAS ACTUALLY WRONG. The controls were there — a Solo and a Mute per row,
// both reaching `track.solo` / `track.mute` — and they could be OFF SCREEN.
//
// The stem name was `Text(track.name).lineLimit(1).fixedSize()`. `fixedSize()`
// means "take your ideal width whatever the proposal is", so a stem called
// anything longer than about a dozen characters widened the row past the
// browser rail's 172 pt, and the two chips — which sit after the name — went
// out the right-hand edge of a vertical `ScrollView`, which clips. Not small,
// not hard to hit: ABSENT. A pane with the controls pushed out of it is exactly
// "missing the controls to do anything", and it is the SAME `fixedSize()` trap
// the transport row was blown to 475 pt by, seen from its other side: too
// little constraint wraps a Text, too much shoves its neighbours out.
//
// `testALongStemNameDoesNotPushTheChipsOutOfTheRail` is the assertion that
// moves when that is true. It measures the real AppKit hit-test views of the
// real `StudioBrowserView` at the real rail width, so it cannot be satisfied by
// a pane that merely compiles.
//
// The three other things this file holds:
//
//   * SIZE. 18x16 pt is not a target on a television across a room. The chips
//     are 26x20 and the test pins the AREA, so a restyle that shrinks them
//     fails rather than passing because "it still renders".
//   * LEVEL. Solo and mute are on/off; "a bit less drums" is the next thing
//     anybody wants and the only way to it was to find the track in the mixer.
//     Two steppers, each press one `mix.gain` command and one undo step.
//   * WHY IT IS EMPTY. "No stems yet" is the same sentence whether the project
//     is still loading, has no tracks at all, or has tracks that are all
//     instruments — three different situations with three different remedies.

@MainActor
final class StudioStemsPaneTests: XCTestCase {

    // MARK: - Rendering the real pane

    /// Every AppKit hit-test view the pane materialises, in the host's
    /// coordinate space. The same walk `StudioBrowserPanesTests` uses to count
    /// controls, keeping the frames instead of the count.
    ///
    /// ⚠️ THE HOST IS EXACTLY THE RAIL'S WIDTH, and that is load-bearing rather
    /// than tidy. Hosted in anything wider, `NSHostingView` CENTRES the browser
    /// (which pins itself to `StudioTokens.browserWidth`) and every frame comes
    /// back offset by half the slack — the first draft of this file hosted at
    /// 420 pt and read a perfectly-laid-out row as 106 pt over the edge. A
    /// coordinate space whose origin is not where you think it is will fail and
    /// pass for reasons that have nothing to do with the pane.
    private func controlFrames(
        _ view: some View,
        hostWidth: CGFloat = StudioTokens.browserWidth,
        hostHeight: CGFloat = 1400
    ) -> [CGRect] {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: hostWidth, height: hostHeight)
        host.layoutSubtreeIfNeeded()
        host.layout()
        host.layoutSubtreeIfNeeded()
        var out: [CGRect] = []
        func walk(_ v: NSView) {
            let name = String(describing: type(of: v))
            if name.contains("HitTesting") || name.contains("AppKitButton") {
                out.append(v.convert(v.bounds, to: host))
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        return out
    }

    private func bootedModel() async throws -> StudioViewModel {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        for _ in 0..<200 {
            if model.snapshot != nil { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        _ = try XCTUnwrap(model.snapshot, "the mock project never arrived")
        return model
    }

    /// Rename every stem to something long. This is not a contrived string: a
    /// track imported from a library song is named after the SONG, and "Open in
    /// Studio" then splits it into layers that keep long names.
    private func renameStemsLong(_ model: StudioViewModel) async {
        for track in StudioBrowserView.stemTracks(in: model.snapshot) {
            model.renameTrack(track.id, name: "Lead Vocal Doubles Take Three")
        }
        for _ in 0..<200 {
            let names = StudioBrowserView.stemTracks(in: model.snapshot).map(\.name)
            if names.allSatisfy({ $0.hasPrefix("Lead Vocal") }) { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    // MARK: - 1. THE ONE. The controls have to be INSIDE the rail.

    func testALongStemNameDoesNotPushTheChipsOutOfTheRail() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let library = LibraryStore()
        await renameStemsLong(model)

        let stems = StudioBrowserView.stemTracks(in: model.snapshot)
        XCTAssertGreaterThanOrEqual(stems.count, 2, "no stems to measure")
        XCTAssertTrue(stems.contains { $0.name.count > 20 },
                      "the rename did not take, so this measures the short-name case and proves nothing")

        let rail = StudioTokens.browserWidth
        let frames = controlFrames(
            StudioBrowserView(model: model, initialSection: .stems).environmentObject(library))
        XCTAssertGreaterThan(frames.count, stems.count,
                             "the pane drew fewer controls than it has stems, so it is not drawing rows")

        let escaped = frames.filter { $0.maxX > rail + 0.5 }
        XCTAssertTrue(
            escaped.isEmpty,
            """
            \(escaped.count) of \(frames.count) controls in the Stems pane sit past the \
            \(rail) pt rail (right edges: \(escaped.map { Int($0.maxX) })). The pane is \
            inside a vertical ScrollView, which CLIPS — so those controls are not \
            small, they are not on screen at all. That is "stems is missing the \
            controls to do anything": a `fixedSize()` on the stem name takes its \
            ideal width whatever the proposal, and shoves everything after it out.
            """)
    }

    /// A target you can hit from a sofa. The chips were 18x16 = 288 pt²; the
    /// mixer's own are 22x16 = 352, which is no better and is why "match the
    /// mixer" was not the answer.
    ///
    /// COUNTED, not sampled, and the count is per ROW: four controls of at
    /// least the floor area for every stem. A minimum over every hit-test view
    /// would be the wrong measure — SwiftUI materialises a `_NSShapeHitTestingView`
    /// for the glyph INSIDE each button (a "+" is 8x8) and for the colour dot,
    /// so the smallest thing in the pane is 16 pt² however big the buttons are.
    /// The first draft asserted that minimum and would have failed a perfectly
    /// good pane.
    func testEveryStemRowCarriesFourTargetsYouCanHitFromASofa() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let library = LibraryStore()

        let stems = StudioBrowserView.stemTracks(in: model.snapshot)
        XCTAssertGreaterThanOrEqual(stems.count, 2, "no stems to measure")

        let frames = controlFrames(
            StudioBrowserView(model: model, initialSection: .stems).environmentObject(library))
        // Full-rail controls are the four section buttons (Songs / Sounds /
        // Takes / Stems); the row controls are the narrow ones.
        let bigEnough = frames.filter {
            $0.width < 100 && $0.width * $0.height >= StudioBrowserView.stemChipMinimumArea
        }
        XCTAssertEqual(
            bigEnough.count, stems.count * 4,
            """
            \(stems.count) stems drew \(bigEnough.count) controls of at least \
            \(Int(StudioBrowserView.stemChipMinimumArea)) pt², not the \(stems.count * 4) a Solo, \
            a Mute and two level steps per row comes to. The shipped chips were \
            18x16 = 288 pt², which the owner could not hit on a 4K television at \
            couch distance — that is the complaint, not a nicety.
            """)
        // The floor itself has to be a real claim about the real chips, or the
        // count above passes on a pane of 1x1 buttons and a generous floor.
        XCTAssertGreaterThanOrEqual(
            StudioBrowserView.stemChipWidth * StudioBrowserView.stemChipHeight,
            StudioBrowserView.stemChipMinimumArea,
            "the declared chip size is below the floor the test pins, so one of the two is wrong")
        XCTAssertGreaterThan(
            StudioBrowserView.stemChipMinimumArea, 352,
            "the floor is at or under the mixer's own 22x16 chip, which is the size that was already too small")
    }

    // MARK: - 2. Level: the thing solo and mute cannot say

    func testTheLevelStepperReachesEngineTruth() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let track = try XCTUnwrap(StudioBrowserView.stemTracks(in: model.snapshot).first)
        let before = track.volumeDB

        StudioBrowserStemActions.nudgeLevel(model, track, by: -1)
        for _ in 0..<200 {
            if let t = model.snapshot?.tracks.first(where: { $0.id == track.id }),
               abs(t.volumeDB - before) > 0.001 { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let after = try XCTUnwrap(model.snapshot?.tracks.first(where: { $0.id == track.id }))
        XCTAssertEqual(
            after.volumeDB, before - 1, accuracy: 0.01,
            "the Stems row's level step did not reach engine truth (was \(before), now \(after.volumeDB))")
    }

    /// One press is one command is one undo step — the house rule, and the
    /// reason this is a stepper rather than a drag: a drag would have to decide
    /// when a gesture ends, and this pane is 172 pt wide.
    func testOneLevelStepIsOneCommand() async throws {
        let spy = PaletteSpyEngine()
        let model = StudioViewModel(engine: spy)
        model.startPolling()
        defer { model.stopPolling() }
        for _ in 0..<200 {
            if model.snapshot != nil { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let track = try XCTUnwrap(StudioBrowserView.stemTracks(in: model.snapshot).first)

        StudioBrowserStemActions.nudgeLevel(model, track, by: +1)
        for _ in 0..<200 {
            if await spy.names().contains("mix.gain") { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let sent = await spy.names().filter { $0 == "mix.gain" }
        XCTAssertEqual(sent.count, 1,
                       "one press of + sent \(sent.count) mix.gain commands, so one press is \(sent.count) presses of Cmd-Z")
    }

    /// The step clamps to the SAME range the palette's own `mix.gain` row
    /// declares. Two ranges for one parameter is how a control ends up able to
    /// send a value the command refuses.
    func testTheLevelRangeIsThePaletteRowsOwnRange() throws {
        let row = try XCTUnwrap(StudioPaletteCommands.all.first { $0.name == "mix.gain" })
        guard case .number(_, _, let range)? = row.argument else {
            return XCTFail("mix.gain no longer asks for a number, so this pane's stepper needs re-reading")
        }
        XCTAssertEqual(
            StudioBrowserStemActions.levelRange, range,
            """
            the Stems stepper clamps to \(StudioBrowserStemActions.levelRange) and ⌘K's \
            own mix.gain row to \(range). One of the two can send a value the other \
            cannot, which is a control that lies about what it can do.
            """)
    }

    func testTheLevelStepperDoesNotSendAtTheEndsOfItsRange() async throws {
        let spy = PaletteSpyEngine()
        let model = StudioViewModel(engine: spy)
        model.startPolling()
        defer { model.stopPolling() }
        for _ in 0..<200 {
            if model.snapshot != nil { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        var track = try XCTUnwrap(StudioBrowserView.stemTracks(in: model.snapshot).first)
        model.setTrackGain(track.id, gainDB: StudioBrowserStemActions.levelRange.upperBound)
        for _ in 0..<200 {
            if let t = model.snapshot?.tracks.first(where: { $0.id == track.id }),
               t.volumeDB >= StudioBrowserStemActions.levelRange.upperBound - 0.001 {
                track = t
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(track.volumeDB, StudioBrowserStemActions.levelRange.upperBound, accuracy: 0.01,
                       "could not park the track at the top of its range; the assertion below would be vacuous")

        let before = await spy.names().filter { $0 == "mix.gain" }.count
        StudioBrowserStemActions.nudgeLevel(model, track, by: +1)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let after = await spy.names().filter { $0 == "mix.gain" }.count
        XCTAssertEqual(
            after, before,
            "pressing + at the top of the range journalled a command that changes nothing, which is an undo step that undoes nothing")
    }

    // MARK: - 3. An empty pane that says WHY

    func testAnEmptyStemsPaneExplainsWhichEmptyItIs() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let real = try XCTUnwrap(model.snapshot)

        // The three empty situations, built by REMOVING tracks from a real
        // snapshot rather than by constructing one. `role` is derived from
        // clips and devices and there is no field to set — a fixture that could
        // set it would be testing a shape the app does not have.
        let loading = try XCTUnwrap(StudioBrowserView.stemsEmptyReason(in: nil))

        var bare = real
        bare.tracks = []
        let noTracks = try XCTUnwrap(StudioBrowserView.stemsEmptyReason(in: bare))

        // The mock project is entirely audio, so the non-audio tracks have to
        // be MADE. `track.add` is the command the mock implements and it is
        // the one the app's own "add a track" sends; the resulting tracks carry
        // no recording, which is the state this sentence is about.
        var made: [UUID] = []
        for i in 0..<3 {
            let id = UUID()
            made.append(id)
            model.sendFromPalette(.trackAdd(
                trackID: id.uuidString, name: "Keys \(i + 1)",
                index: (model.snapshot?.tracks.count ?? 0) + i))
        }
        for _ in 0..<200 {
            let landed = made.allSatisfy { id in
                model.snapshot?.tracks.contains(where: { $0.id == id }) == true
            }
            if landed { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        var instrumentsOnly = try XCTUnwrap(model.snapshot)
        instrumentsOnly.tracks = instrumentsOnly.tracks.filter { made.contains($0.id) }
        XCTAssertEqual(
            instrumentsOnly.tracks.count, 3,
            "could not build a project with no recordings on it, so the case below is not the one being tested")
        XCTAssertTrue(
            StudioBrowserView.stemTracks(in: instrumentsOnly).isEmpty,
            "the tracks made for this case carry audio after all")
        let allInstruments = try XCTUnwrap(
            StudioBrowserView.stemsEmptyReason(in: instrumentsOnly),
            "a project of instrument tracks reads as HAVING stems")

        // And the negative: a project WITH audio must report no reason at all,
        // or the pane would show an explanation over a list of stems.
        XCTAssertFalse(StudioBrowserView.stemTracks(in: real).isEmpty)
        XCTAssertNil(
            StudioBrowserView.stemsEmptyReason(in: real),
            "a project with audio tracks still claims the Stems pane is empty")

        let all = [loading, allInstruments, noTracks]
        XCTAssertEqual(Set(all).count, 3,
                       "two of the three empty states say the same thing, so the pane cannot tell you which one you are in: \(all)")
        for sentence in all {
            XCTAssertGreaterThanOrEqual(
                sentence.count, 40,
                "\"\(sentence)\" is too short to explain anything")
        }
        // The one that has to name the way out, because it is the one a person
        // hits while holding a song they want split.
        XCTAssertTrue(
            allInstruments.lowercased().contains("open a song in studio"),
            "the all-instruments empty state does not name the gesture that makes stems: \(allInstruments)")
        XCTAssertTrue(
            allInstruments.contains("\(instrumentsOnly.tracks.count)"),
            "the all-instruments empty state does not say how many tracks it looked at, so it reads as a guess: \(allInstruments)")
    }

    /// The empty state is what the pane actually DRAWS. Without this the
    /// sentences above could be perfect and unreferenced — the shape of half
    /// the defects in this codebase.
    func testThePaneDrawsItsEmptyExplanationRatherThanNothing() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("../Sources/Studio/StudioBrowserView.swift")
                .standardizedFileURL,
            encoding: .utf8)
        XCTAssertTrue(
            source.contains("stemsEmptyReason(in: model.snapshot)"),
            "the Stems pane does not call stemsEmptyReason, so the explanations are dead text")
        XCTAssertFalse(
            source.contains("No stems yet. Open a song in Studio"),
            "the one-size-fits-all empty sentence is still in the pane")
    }
}
