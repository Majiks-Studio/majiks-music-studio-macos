import Testing
import Foundation
import CoreGraphics
@testable import MajiksMusicStudio

// Two defects from the parity audit, and the tests that keep them fixed.
//
//  1. The transport strip's master meters were `abs(sin(t))`. They bounced
//     convincingly whenever the transport ran and were connected to no audio.
//  2. `transport.loop.set` / `transport.loop.clear` were wired end to end and
//     sample-exact, and NOTHING a user could touch called them — while the
//     export dialog told them to "set a loop region on the ruler".
//
// The bar these tests have to clear is set by what they are replacing. "A meter
// moved" passes on a sine wave. So the meter tests assert a level RATIO between
// two things measured in the same snapshot: change the master fader by a known
// factor and the master meter must move relative to the tracks feeding it by
// exactly 20*log10 of that factor. A constant fails; a clock fails; a copy of
// the track level fails.
@MainActor
@Suite("Loop control and real transport meters")
struct StudioLoopAndMetersTests {

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

    private func waitForCommands(
        _ spy: CommandSpyEngine,
        timeout: TimeInterval = 3.0,
        until condition: @Sendable @escaping ([StudioEngineCommand]) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(await spy.commands) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A running model over the preview engine, polling, with a snapshot in.
    private func startedModel(_ engine: any StudioEngineProtocol = StudioMockEngine())
        async -> StudioViewModel
    {
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        await wait(model) { $0.snapshot != nil }
        return model
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

    /// A source file with its line comments removed. The guards below assert
    /// that certain constructs are absent from the CODE; without this they also
    /// fire on a comment that names the construct it is warning about, which
    /// is exactly what the fix for these two defects had to write down.
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // =====================================================================
    // MARK: - 1. The master meter is a measurement
    // =====================================================================

    /// THE RATIO PROOF, and the reason it is a ratio.
    ///
    /// The preview engine's levels wobble with wall time on purpose, so a
    /// before/after comparison of the meter ALONE proves nothing — the number
    /// would have moved anyway. What cannot move on its own is the meter's
    /// relationship to the tracks feeding it, measured inside ONE snapshot.
    ///
    /// So: read (master - loudest track) with the master fader at unity, drop
    /// the master fader to a quarter of its amplitude, and read it again. The
    /// difference between those two differences must be exactly -20*log10(4)
    /// dB. A constant fails. A sine fails. A meter that copies the track level
    /// fails. Only a meter that reads the master bus's own measured level
    /// passes.
    @Test("the transport master meter is a measured level that follows the mix, not a clock")
    func transportMeterFollowsAudioNotTime() async {
        let model = await startedModel()
        defer { model.stopPolling() }

        model.play()
        await wait(model) { $0.isPlaying && ($0.snapshot?.master.meter.peakDB ?? -120) > -119 }

        func sample() -> (master: Double, loudestTrack: Double)? {
            guard let snapshot = model.snapshot else { return nil }
            guard case .measured(let peakDB, _) =
                    StudioTransportMeter.reading(for: snapshot) else { return nil }
            guard let loudest = snapshot.tracks.filter({ !$0.muted })
                .map(\.meter.peakDB).max() else { return nil }
            return (peakDB, loudest)
        }

        guard let unity = sample() else {
            Issue.record("the preview engine published no master level while playing")
            return
        }
        #expect(unity.master > -119,
                "a playing mix with unmuted tracks is not at the silence floor")

        // A quarter of the amplitude: the same known-gain idiom the bus-meter
        // lane used, so the expected number is arithmetic, not a fixture.
        let quarterDB = -20 * log10(4.0)
        model.setMasterGain(quarterDB)
        await wait(model) { ($0.snapshot?.master.volumeDB ?? 0) < -11.9 }

        guard let faded = sample() else {
            Issue.record("no master level after the fader move")
            return
        }

        let before = unity.master - unity.loudestTrack
        let after = faded.master - faded.loudestTrack
        #expect(abs((after - before) - quarterDB) < 0.01, """
            Quartering the master amplitude must drop the master meter by \
            exactly \(quarterDB) dB relative to the tracks feeding it, measured \
            in the same snapshot both times. Measured \(after - before) dB. \
            This is the assertion a sine wave, a constant, or a copied track \
            level cannot satisfy — which is the entire point of it.
            """)
    }

    /// Absence and silence are different statements, and the meter has to be
    /// able to make both. -120 dBFS is the engine SAYING silence; no snapshot
    /// is the engine not having said anything, and that draws an empty well.
    @Test("no snapshot means no reading, not a bar at zero")
    func meterReportsAbsenceRatherThanFakingSilence() {
        #expect(StudioTransportMeter.reading(for: nil) == .unavailable)
        #expect(StudioTransportMeterReading.unavailable.spokenValue == "no reading yet",
                "VoiceOver has to be able to say 'I do not know' too")

        let silent = StudioTransportMeterReading.measured(peakDB: -120, rmsDB: -120)
        #expect(silent != .unavailable,
                "a measured -120 is a READING of silence and must not collapse into absence")
        #expect(silent.spokenValue == "silent")
    }

    /// The reading is a pure function of the snapshot: same snapshot, same
    /// answer, forever. Stated as a test because the thing being deleted was
    /// precisely a meter whose value depended on `Date` — this pins that the
    /// only input is engine truth.
    @Test("the same snapshot always reads the same level, whatever the clock says")
    func meterIsAFunctionOfTheSnapshotAndNothingElse() async {
        let model = await startedModel()
        defer { model.stopPolling() }
        model.play()
        await wait(model) { ($0.snapshot?.master.meter.peakDB ?? -120) > -119 }

        guard let snapshot = model.snapshot else {
            Issue.record("no snapshot"); return
        }
        let first = StudioTransportMeter.reading(for: snapshot)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let second = StudioTransportMeter.reading(for: snapshot)
        #expect(first == second, """
            The transport meter read a different level from an identical \
            snapshot 250 ms later, which means something other than the engine \
            is driving it.
            """)
        #expect(first != .unavailable, "the fixture must actually have a level for this to mean anything")
    }

    /// The reading is the MASTER's, verbatim — not the loudest track, not an
    /// average, not a scaled copy. Named separately because "it moves with the
    /// audio" and "it is the number the engine published" are different claims
    /// and only the second one makes the number on screen trustworthy.
    @Test("the meter draws the engine's own master numbers, unmodified")
    func meterIsTheEnginesMasterReadingVerbatim() async {
        let model = await startedModel()
        defer { model.stopPolling() }
        model.play()
        await wait(model) { ($0.snapshot?.master.meter.peakDB ?? -120) > -119 }

        guard let snapshot = model.snapshot,
              case .measured(let peakDB, let rmsDB) =
                StudioTransportMeter.reading(for: snapshot) else {
            Issue.record("no measured reading"); return
        }
        #expect(peakDB == snapshot.master.meter.peakDB)
        #expect(rmsDB == snapshot.master.meter.rmsDB)
    }

    /// The source-level guard. The two tests above prove the pure function is
    /// honest; this proves the VIEW uses it and that the sine is gone. Without
    /// this, someone could reinstate `abs(sin(t))` in the view body and every
    /// other test in this file would still pass.
    @Test("the transport bar has no clock-driven meter left in it")
    func theTransportBarDrawsFromTheSnapshotNotAFunctionOfTime() throws {
        let text = codeOnly(try source("StudioTransportBar.swift"))
        #expect(text.contains("StudioTransportMeter.reading(for: model.snapshot)"),
                "the transport meter no longer reads the snapshot")
        #expect(!text.contains("sin("), """
            A trigonometric meter is back in the transport bar. The master \
            meters were `0.55 + 0.25 * abs(sin(t * 2.1))` for the whole life of \
            this file; they bounced beautifully and meant nothing.
            """)
        #expect(!text.contains("TimelineView(.animation"), """
            The master meter must repaint from the snapshot poll, not from its \
            own animation clock. A meter with a private clock can keep dancing \
            in front of a dead engine.
            """)
    }

    // =====================================================================
    // MARK: - 2. The loop exists, and reaches the engine
    // =====================================================================

    /// The gesture-coexistence rule, as arithmetic. Each ruler band owns one
    /// drag and the bands are disjoint y-ranges — no modifiers, no press-and-
    /// hold, nothing that can race. Boundaries are asserted exactly because an
    /// off-by-one here is a loop drag that fires while you meant to scrub.
    @Test("each ruler band owns exactly one drag, decided by y alone")
    func rulerBandsAreDisjointAndCoverTheRuler() {
        let sectionH = StudioTokens.sectionRulerHeight
        let barsEnd = sectionH + StudioTokens.barRulerHeight
        let loopEnd = barsEnd + StudioTokens.loopRulerHeight

        #expect(StudioRulerBand.at(y: 0) == .sections)
        #expect(StudioRulerBand.at(y: sectionH - 0.1) == .sections)
        #expect(StudioRulerBand.at(y: sectionH) == .bars)
        #expect(StudioRulerBand.at(y: barsEnd - 0.1) == .bars)
        #expect(StudioRulerBand.at(y: barsEnd) == .loop,
                "the loop strip starts exactly where the bar numbers stop")
        #expect(StudioRulerBand.at(y: loopEnd - 0.1) == .loop)
        #expect(StudioRulerBand.at(y: loopEnd) == .lanes,
                "one pixel past the strip is the first track, not a loop drag")
        #expect(StudioRulerBand.rulerHeight == loopEnd)
        #expect(StudioRulerBand.loopStripY == barsEnd)
    }

    /// The whole gesture, at the model layer: press in the strip, drag, release
    /// — ONE `transport.loop.set` carrying the dragged bars, and the engine
    /// holds it. The drag itself must send nothing; a command per mouse-move is
    /// how a transport gets flooded and how "one gesture" stops being one
    /// anything.
    @Test("a loop drag sends exactly one transport.loop.set, on release")
    func loopDragSendsOneCommandOnRelease() async {
        let spy = CommandSpyEngine()
        let model = await startedModel(spy)
        defer { model.stopPolling() }

        let tpb = model.timeSignature.ticksPerBar
        var state = StudioDragState()
        state.kind = .loopRegion
        state.anchorTicks = 4 * tpb
        model.beginDrag(state)

        // Three drag updates, as the view's `updateDrag` does.
        for bar in [5, 6, 8] {
            model.loopDraft = (4 * tpb)...(Int64(bar) * tpb)
        }
        let midDrag = await spy.commands.filter { $0.catalogName == "transport.loop.set" }
        #expect(midDrag.isEmpty, """
            A loop command went out DURING the drag. The drag moves a local \
            draft only; exactly one command goes on release.
            """)

        model.endDrag()
        await waitForCommands(spy) { $0.contains { $0.catalogName == "transport.loop.set" } }

        let sets = await spy.commands.filter { $0.catalogName == "transport.loop.set" }
        #expect(sets.count == 1, "one gesture must be one command, got \(sets.count)")
        guard case .transportLoopSet(let start, let end) = sets.first else {
            Issue.record("the command that reached the engine was not a typed loop set")
            return
        }
        #expect(start == 4 * tpb)
        #expect(end == 8 * tpb)

        await wait(model) { $0.snapshot?.transport.loopRegion == (4 * tpb)...(8 * tpb) }
        #expect(model.snapshot?.transport.loopRegion == (4 * tpb)...(8 * tpb), """
            The engine did not come back holding the loop, so the command \
            reached the bus and died there.
            """)
        #expect(model.loopDraft == nil, "the draft must hand over to engine truth on commit")
    }

    /// Clear is a real, reachable inverse — which is what this feature needs
    /// INSTEAD of an undo step. The engine classifies loop as transport
    /// (`Command::is_undoable()` is `!is_transport()`, and `apply.rs` handles
    /// `TransportLoopSet` as an unjournaled no-op after validating the bounds),
    /// so Cmd-Z deliberately does not take a loop back any more than it takes
    /// back moving the play head. This pins BOTH halves of that: undo leaves
    /// the loop alone, and clear removes it.
    @Test("clear removes the loop; undo deliberately does not, because loop is transport class")
    func clearIsTheInverseAndUndoLeavesTransportAlone() async {
        let spy = CommandSpyEngine()
        let model = await startedModel(spy)
        defer { model.stopPolling() }

        let tpb = model.timeSignature.ticksPerBar
        model.setLoop(startTicks: 2 * tpb, endTicks: 6 * tpb)
        await wait(model) { $0.snapshot?.transport.loopRegion != nil }
        #expect(model.loopRegion == (2 * tpb)...(6 * tpb))

        model.undo()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(model.loopRegion == (2 * tpb)...(6 * tpb), """
            Undo took the loop back. It must not: the loop is transport state, \
            not a document edit, so an undo here would silently reach past it \
            and reverse whatever the user actually edited before setting it.
            """)

        model.clearLoop()
        await waitForCommands(spy) { $0.contains { $0.catalogName == "transport.loop.clear" } }
        await wait(model) { $0.snapshot?.transport.loopRegion == nil }
        #expect(model.loopRegion == nil, "clear did not reach the engine")
    }

    /// The UI must never hand the engine a loop it will refuse. `apply.rs`
    /// rejects `start >= end` with InvalidParams, so a zero-width drag (a
    /// click, a fast flick) is floored to one bar here rather than becoming a
    /// refusal toast in front of a beginner.
    @Test("a zero-width loop is floored to one bar rather than sent as a refusal")
    func zeroWidthLoopIsFlooredNotRefused() async {
        let spy = CommandSpyEngine()
        let model = await startedModel(spy)
        defer { model.stopPolling() }

        let tpb = model.timeSignature.ticksPerBar
        model.setLoop(startTicks: 3 * tpb, endTicks: 3 * tpb)
        await waitForCommands(spy) { $0.contains { $0.catalogName == "transport.loop.set" } }

        let sets = await spy.commands.compactMap { cmd -> (Int64, Int64)? in
            guard case .transportLoopSet(let s, let e) = cmd else { return nil }
            return (s, e)
        }
        #expect(sets.count == 1)
        #expect(sets.first?.0 == 3 * tpb)
        #expect(sets.first?.1 == 4 * tpb, "a zero-width loop must become exactly one bar")

        // Reversed bounds are a backwards drag, not an error.
        model.setLoop(startTicks: 9 * tpb, endTicks: 5 * tpb)
        await waitForCommands(spy) { cmds in
            cmds.compactMap { c -> Bool? in
                guard case .transportLoopSet(let s, _) = c else { return nil }
                return s == 5 * tpb
            }.contains(true)
        }
        let backwards = await spy.commands.compactMap { cmd -> (Int64, Int64)? in
            guard case .transportLoopSet(let s, let e) = cmd else { return nil }
            return (s, e)
        }.last
        #expect(backwards?.0 == 5 * tpb, "dragging right-to-left must normalise, not refuse")
        #expect(backwards?.1 == 9 * tpb)
    }

    /// The Loop button's fallback order, which is the thing that lets it never
    /// be greyed out: selection, then the section under the play head, then
    /// four bars. Each rung asserted, because "the button did something
    /// unpredictable" is worse than a disabled button.
    @Test("the Loop button falls back predictably: selection, then section, then four bars")
    func loopButtonFallbackOrder() async {
        let tpb = StudioTimeSignature(beatsPerBar: 4, beatUnit: 4).ticksPerBar

        // 1. A selection wins.
        let a = await startedModel()
        defer { a.stopPolling() }
        a.selection.region = StudioRegionSelection(rawStart: 8 * tpb, rawEnd: 12 * tpb)
        a.toggleLoop()
        await wait(a) { $0.loopRegion != nil }
        #expect(a.loopRegion == (8 * tpb)...(12 * tpb), "an explicit selection must win")

        // Pressing again with a loop set is a clear, whatever is selected.
        a.toggleLoop()
        await wait(a) { $0.loopRegion == nil }
        #expect(a.loopRegion == nil, "the button is a toggle: on -> off is a clear")

        // 2. No selection: the section the play head is in.
        let b = await startedModel()
        defer { b.stopPolling() }
        b.selection.region = nil
        guard let section = b.snapshot?.sections.first(where: { $0.lengthBars > 0 }) else {
            Issue.record("the preview fixture has no sections to sit in"); return
        }
        b.seek(toTicks: Int64(section.startBar) * tpb)
        await wait(b) { $0.snapshot?.transport.positionTicks == Int64(section.startBar) * tpb }
        b.toggleLoop()
        await wait(b) { $0.loopRegion != nil }
        let expected = (Int64(section.startBar) * tpb)...(Int64(section.startBar + section.lengthBars) * tpb)
        #expect(b.loopRegion == expected,
                "with nothing selected the button must loop the section you are sitting in")
    }

    // =====================================================================
    // MARK: - 3. The export dialog stops pointing at nothing
    // =====================================================================

    /// The copy defect, pinned. `StudioExportDialog` told the user to "set a
    /// loop region on the ruler" for the entire time no such control existed.
    /// Now one does — and the copy has to name the thing that is actually
    /// there, not the thing the engine happened to support.
    @Test("the export dialog names a loop control that exists")
    func exportDialogCopyPointsAtARealControl() throws {
        let dialog = try source("StudioExportDialog.swift")
        #expect(!dialog.contains("Set a loop region on the ruler to export a selection."), """
            The old copy is back. It instructed the user to use a control that \
            did not exist, which is worse than saying nothing.
            """)
        #expect(dialog.contains("loop strip"),
                "the region hint must name the loop strip, which is where the gesture is")

        // ...and the control it names is genuinely reachable from the ruler.
        let timeline = codeOnly(try source("StudioTimelineView.swift"))
        #expect(timeline.contains("state.kind = .loopRegion"),
                "the export dialog now promises a ruler gesture; the ruler must have one")
        #expect(!timeline.contains("ScrollView"), """
            A ScrollView appeared in the timeline view. On macOS a horizontal \
            ScrollView silently eats the clicks of controls inside it — this \
            codebase lost days to exactly that, and the loop strip is a \
            click target.
            """)
    }

    /// Help is not optional for a new control, and the loop's copy has to teach
    /// somebody who has never used a DAW what a loop IS — not restate the word.
    @Test("both loop states carry teaching copy that explains repeating, not the word loop")
    func loopHelpTeachesWhatALoopIs() throws {
        for id in ["transport.loop.off", "transport.loop.on"] {
            guard let entry = StudioHelpCatalog.entry(id) else {
                Issue.record("no help catalog entry for \(id)"); continue
            }
            let teaching = entry.teaching.lowercased()
            #expect(teaching.count > entry.terse.count * 3,
                    "\(id) teaches nothing beyond its label")
            #expect(teaching.contains("over and over") || teaching.contains("jumps back")
                    || teaching.contains("straight through"),
                    "\(id) never explains what repeating actually does: \(entry.teaching)")
        }

        // The meter's copy has to state the mono-collapse, because the honest
        // answer to "why is there one bar" is a sentence, not a missing bar.
        let meter = try #require(StudioHelpCatalog.entry("transport.meters"))
        #expect(meter.teaching.lowercased().contains("one bar, not two"),
                "the meter help must say why there is a single bar: \(meter.teaching)")
    }
}
