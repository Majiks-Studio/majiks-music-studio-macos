import Testing
import Foundation
import CoreGraphics
@testable import MajiksMusicStudio

// MOVING THE PLAY HEAD.
//
// The report was "I can't fastforward or rewind, I can't drag that playing bar
// thing", on a 114-bar song where the only navigation was Return-to-start —
// which means you cannot get to the chorus.
//
// Two separate defects sat behind that sentence, and they need separate tests.
//
//  1. The scrub drag EXISTED. `StudioTimelineView.beginDrag` has owned a
//     `.playheadScrub` kind for the bar-numbers band the whole time. What it
//     did not have was a way to find: the play head's only visible handle was a
//     7 pt triangle drawn at y = 0, which is inside the SECTIONS band, whose
//     drag selects bars. So the one part that looked grabbable was the one part
//     that did something else, and the play head did not move. The handle is
//     now drawn across the band that owns the gesture.
//
//  2. The drag sent a `transport.seek` PER MOUSE-MOVE. That is a command storm
//     at pointer rate, and on the audio thread every seek is a transport
//     discontinuity — so the stream of them was audible. It now moves a local
//     draft and commits exactly ONE command on release, the same idiom the loop
//     drag already used.
//
// There was no fast-forward or rewind at all; there are now, and they are a BAR
// nudge (see `nudgePlayhead(bars:)` for why a bar and not a shuttle).
//
// The assertions are on COMMANDS OBSERVED AT THE ENGINE and on the model's own
// published state, never on "a SwiftUI property changed".
@MainActor
@Suite("Play-head navigation")
struct StudioPlayheadNavigationTests {

    private func wait(
        _ model: StudioViewModel,
        timeout: TimeInterval = 3.0,
        until condition: @MainActor (StudioViewModel) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(model) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func settle(_ spy: CommandSpyEngine, ticks: Int = 12) async {
        for _ in 0..<ticks { try? await Task.sleep(nanoseconds: 20_000_000) }
        _ = await spy.commands
    }

    private func startedModel(_ engine: any StudioEngineProtocol)
        async -> StudioViewModel
    {
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        await wait(model) { $0.snapshot != nil }
        return model
    }

    private func seeks(_ commands: [StudioEngineCommand]) -> [Int64] {
        commands.compactMap {
            if case .transportSeek(let t) = $0 { return t }
            return nil
        }
    }

    private static let sourcesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../Sources")
        .standardizedFileURL

    private func source(_ name: String) throws -> String {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: Self.sourcesDirectory, includingPropertiesForKeys: nil)
        for case let url as URL in enumerator! where url.lastPathComponent == name {
            return try String(contentsOf: url, encoding: .utf8)
        }
        Issue.record("source file \(name) not found under \(Self.sourcesDirectory.path)")
        return ""
    }

    /// A source file with its line comments removed, so a guard that asserts a
    /// construct is ABSENT does not fire on the comment explaining why.
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // =====================================================================
    // MARK: - 1. A scrub drag is ONE command, on release
    // =====================================================================

    /// THE COMMAND-STORM PROOF.
    ///
    /// Sixty draft updates — roughly a second of pointer movement — must
    /// produce ZERO commands. Then one release produces exactly one seek, at
    /// the LAST position, not the first.
    ///
    /// Counting is the whole assertion. "A seek was sent" passes on the broken
    /// version too, because the broken version sent sixty of them.
    @Test("a scrub drag sends no command until release, then exactly one")
    func scrubDragCommitsOnce() async {
        let spy = CommandSpyEngine()
        let model = await startedModel(spy)
        await settle(spy)
        let before = await spy.commands.count

        var drag = StudioDragState()
        drag.kind = .playheadScrub
        model.beginDrag(drag)

        for i in 0..<60 {
            model.playheadDraft = model.clampedPlayhead(Int64(i) * 480)
        }
        // Nothing has left the model yet.
        await settle(spy)
        let during = await spy.commands
        #expect(during.count == before,
                "a scrub drag must send NOTHING while the button is down; saw \(during.count - before) command(s)")

        let last = model.playheadDraft
        #expect(last == Int64(59 * 480), "the draft tracks the pointer locally")

        model.endDrag()
        await settle(spy)
        let after = await spy.commands
        let sent = Array(after.dropFirst(before))
        #expect(sent.count == 1,
                "release must commit exactly one command, saw \(sent.count): \(sent)")
        #expect(seeks(sent) == [Int64(59 * 480)],
                "the one command must be a seek to where the drag ENDED")
        #expect(model.playheadDraft == nil,
                "the draft hands back to engine truth once committed")
    }

    /// A cancelled drag commits nothing and leaves no ghost play head behind.
    @Test("a cancelled scrub sends nothing and clears the draft")
    func cancelledScrubCommitsNothing() async {
        let spy = CommandSpyEngine()
        let model = await startedModel(spy)
        await settle(spy)
        let before = await spy.commands.count

        var drag = StudioDragState()
        drag.kind = .playheadScrub
        model.beginDrag(drag)
        model.playheadDraft = 9_600
        model.cancelDrag()
        await settle(spy)

        #expect(await spy.commands.count == before, "a cancelled scrub sends nothing")
        #expect(model.playheadDraft == nil, "and leaves no ghost play head")
    }

    /// While a drag is running the timeline must draw the DRAFT, not engine
    /// truth — that is what makes the line follow the pointer at display rate
    /// instead of at snapshot-poll rate, and "it does not follow me" is half
    /// the original report.
    @Test("the timeline draws the draft while scrubbing and engine truth otherwise")
    func draftIsWhatGetsDrawn() async {
        let model = await startedModel(StudioMockEngine())
        let now = ProcessInfo.processInfo.systemUptime
        let truth = model.playheadTicks(now: now)

        model.playheadDraft = truth + 19_200
        #expect(model.effectivePlayheadTicks(now: now) == truth + 19_200,
                "a live draft wins over the engine's position")

        model.playheadDraft = nil
        #expect(model.effectivePlayheadTicks(now: now) == model.playheadTicks(now: now),
                "with no draft the timeline draws engine truth")
    }

    /// The VIEW half. The model above cannot see whether the gesture handler
    /// still calls `model.seek` per mouse-move — that lives in the canvas, which
    /// has no test seam. So this reads the source: the `.playheadScrub` arm of
    /// `updateDrag` must set the draft and must NOT send a command.
    @Test("the scrub gesture writes a draft, not a command")
    func scrubGestureDoesNotSeekPerMove() throws {
        let code = codeOnly(try source("StudioTimelineView.swift"))
        guard let scrubArm = code.range(of: "case .playheadScrub:") else {
            Issue.record("the scrub arm of updateDrag has disappeared")
            return
        }
        // The arm runs until the next `case ` at the same level.
        let rest = code[scrubArm.upperBound...]
        let arm = rest.range(of: "\n        case ").map { String(rest[..<$0.lowerBound]) }
            ?? String(rest)
        #expect(arm.contains("playheadDraft"),
                "the scrub drag must move the local draft")
        #expect(!arm.contains("model.seek("),
                "the scrub drag must NOT send a seek per mouse-move: that is a command storm, and on the audio thread each one is a transport discontinuity")
    }

    // =====================================================================
    // MARK: - 2. The grab handle is in the band that scrubs
    // =====================================================================

    /// The affordance and the gesture must be the same pixels.
    ///
    /// `StudioRulerBand.at(y:)` is the single source of truth for which drag a
    /// press starts. This asserts that the y range the play head's handle is
    /// drawn over resolves to `.bars` — the band whose drag scrubs — rather than
    /// to `.sections`, whose drag selects bars and was where the old triangle
    /// lived.
    @Test("the play head's grab handle sits in the band whose drag scrubs")
    func grabHandleIsInTheScrubBand() {
        let top = StudioTokens.sectionRulerHeight
        let bottom = StudioRulerBand.loopStripY
        #expect(bottom > top, "the bars band must have height to grab")
        // Every y the handle occupies belongs to the scrub band.
        var y = top
        while y < bottom {
            #expect(StudioRulerBand.at(y: y) == .bars,
                    "y=\(y) is inside the drawn handle but resolves to \(StudioRulerBand.at(y: y)), not .bars")
            y += 1
        }
        // And the OLD handle position did not: this is the defect, pinned.
        #expect(StudioRulerBand.at(y: 0) == .sections,
                "y=0 (where the handle used to be drawn) selects bars, not scrub")
    }

    /// The drawing code actually uses that band. A handle that is only
    /// *described* as being in the bars band is the bug again.
    @Test("the play head is drawn from the draft and its handle from the bars band")
    func playheadDrawingUsesTheDraftAndTheBarsBand() throws {
        let code = codeOnly(try source("StudioTimelineView.swift"))
        guard let start = code.range(of: "private func drawPlayhead(") else {
            Issue.record("drawPlayhead has disappeared")
            return
        }
        let rest = code[start.upperBound...]
        let body = rest.range(of: "\n    private func ").map { String(rest[..<$0.lowerBound]) }
            ?? String(rest)
        #expect(body.contains("effectivePlayheadTicks"),
                "the play head must be drawn from the draft-aware position")
        #expect(body.contains("StudioTokens.sectionRulerHeight")
                && body.contains("StudioRulerBand.loopStripY"),
                "the grab handle must be laid out against the bars band's own bounds, so it cannot drift out of the band that scrubs")
    }

    // =====================================================================
    // MARK: - 3. Rewind and fast-forward
    // =====================================================================

    /// One press, one bar, one command — and the arithmetic is checked against
    /// the ticks-per-bar the model reports, not against a number typed twice.
    @Test("fast-forward advances exactly one bar and sends one seek")
    func fastForwardAdvancesOneBar() async {
        let spy = CommandSpyEngine()
        let model = await startedModel(spy)
        await settle(spy)
        let before = await spy.commands.count

        let tpb = Int64(model.timeSignature.ticksPerBar)
        #expect(tpb > 0, "the model must know how long a bar is")
        let start = model.playheadTicks(now: ProcessInfo.processInfo.systemUptime)
        model.nudgePlayhead(bars: 1)
        await settle(spy)

        let sent = Array(await spy.commands.dropFirst(before))
        #expect(sent.count == 1, "one press, one command, saw \(sent.count)")
        let landed = seeks(sent).first
        #expect(landed == (start / tpb + 1) * tpb,
                "forward must land on the NEXT bar line from \(start)")
        #expect(landed.map { $0 % tpb == 0 } == true,
                "and on a bar line, not an arbitrary offset")
    }

    /// Rewind from mid-bar lands on the bar you are IN (what a rewind button
    /// does everywhere else); rewind from exactly a bar line goes back a whole
    /// bar. These are different answers and the code has to give both.
    @Test("rewind snaps to the current bar, then walks back a bar at a time")
    func rewindSnapsThenWalks() async {
        let spy = CommandSpyEngine()
        let model = await startedModel(spy)
        await settle(spy)
        let tpb = Int64(model.timeSignature.ticksPerBar)

        // Park mid-bar, deterministically, by committing a scrub there.
        let midBar = tpb * 5 + tpb / 3
        var drag = StudioDragState()
        drag.kind = .playheadScrub
        model.beginDrag(drag)
        model.playheadDraft = midBar
        model.endDrag()
        await wait(model) { $0.playheadTicks(now: ProcessInfo.processInfo.systemUptime) == midBar }

        let here = model.playheadTicks(now: ProcessInfo.processInfo.systemUptime)
        guard here == midBar else {
            Issue.record("the engine did not adopt the scrub (\(here) != \(midBar))")
            return
        }
        let before = await spy.commands.count
        model.nudgePlayhead(bars: -1)
        await settle(spy)
        #expect(seeks(Array(await spy.commands.dropFirst(before))) == [tpb * 5],
                "from mid-bar, rewind lands on the start of THIS bar")

        await wait(model) { $0.playheadTicks(now: ProcessInfo.processInfo.systemUptime) == tpb * 5 }
        let before2 = await spy.commands.count
        model.nudgePlayhead(bars: -1)
        await settle(spy)
        #expect(seeks(Array(await spy.commands.dropFirst(before2))) == [tpb * 4],
                "from a bar line, rewind goes back a whole bar")
    }

    /// Rewind at the very start cannot go negative; the engine would reject a
    /// negative tick and the UI must not send one.
    @Test("rewind is clamped at the start of the song")
    func rewindClampsAtZero() async {
        let spy = CommandSpyEngine()
        let model = await startedModel(spy)
        await settle(spy)
        model.returnToStart()
        await wait(model) { $0.playheadTicks(now: ProcessInfo.processInfo.systemUptime) == 0 }
        // `returnToStart` is itself a seek, dispatched on a Task. Let it land
        // BEFORE the count is taken, or it shows up in this test's window and
        // the assertion below reads [0, 0].
        await settle(spy)

        let before = await spy.commands.count
        model.nudgePlayhead(bars: -1)
        await settle(spy)
        #expect(seeks(Array(await spy.commands.dropFirst(before))) == [0],
                "rewind at bar 1 stays at bar 1")
    }

    /// Fast-forward cannot run off the end of the project.
    @Test("fast-forward is clamped at the end of the song")
    func fastForwardClampsAtTheEnd() async {
        let model = await startedModel(StudioMockEngine())
        let end = model.projectLengthTicks
        #expect(end > 0, "the fixture project must have a length to clamp to")
        #expect(model.clampedPlayhead(end + 1_000_000) == end,
                "past the end clamps to the end")
        #expect(model.clampedPlayhead(-5) == 0, "before the start clamps to zero")
    }

    // =====================================================================
    // MARK: - 4. The controls exist and explain themselves
    // =====================================================================

    /// The transport bar must actually carry the two buttons and route them at
    /// the nudge, and both must carry help. A control that exists but is not
    /// wired is the failure mode this whole lane is about.
    @Test("the transport bar carries rewind and fast-forward, wired and explained")
    func transportBarCarriesTheNudgeButtons() throws {
        let code = codeOnly(try source("StudioTransportBar.swift"))
        #expect(code.contains("model.nudgePlayhead(bars: -1)"), "rewind is wired")
        #expect(code.contains("model.nudgePlayhead(bars: 1)"), "fast-forward is wired")
        #expect(code.contains("\"transport.rewind\""), "rewind carries a help id")
        #expect(code.contains("\"transport.fastForward\""), "fast-forward carries one")

        for id in ["transport.rewind", "transport.fastForward"] {
            let entry = StudioHelpCatalog.entry(id)
            #expect(entry != nil, "\(id) must have a help catalog entry")
            // The catalog's own table-driven tests police the teaching copy;
            // what is asserted here is that these two ids resolve at all, since
            // a `.studioHelp` on an id with no entry is a silent no-tooltip.
        }
    }
}
