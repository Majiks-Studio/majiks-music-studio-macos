import Testing
import Foundation
@testable import MajiksMusicStudio

// The metronome's SWIFT-side contract.
//
// The audio itself is proved in Rust (`engine/render/tests/metronome.rs`)
// against rendered buffers — a transient at every computed beat frame, nothing
// in a bounce, nothing in a recorded take. Nothing here can or should assert
// on sound: the mock engine is silent by definition.
//
// What these tests DO pin is the seam that would make all of that invisible:
// that the toggle reaches the engine and comes BACK as engine truth rather
// than a UI-local flag, and that starting a count-in asks the engine for
// audible clicks instead of only counting down on screen.
@MainActor
@Suite("Studio metronome")
struct StudioMetronomeTests {

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

    /// Poll an actor-isolated condition (the spy's recorded calls).
    private func waitFor(
        timeout: TimeInterval = 3.0,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("The click toggle round-trips through the engine, not a UI-local flag")
    func toggleRoundTripsThroughTheEngine() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        #expect(model.metronomeEnabled == false, "the click starts off")

        model.toggleMetronome()
        await wait(model) { $0.metronomeEnabled }
        #expect(
            model.metronomeEnabled,
            """
            The toggle never came back from the engine. `metronomeEnabled` reads \
            snapshot truth on purpose: if the transport bar kept its own copy, \
            an agent or a MIDI binding could turn the click on and the button \
            would still say off.
            """)

        model.toggleMetronome()
        await wait(model) { !$0.metronomeEnabled }
        #expect(model.metronomeEnabled == false, "and back off again")
    }

    /// The count-in must ASK FOR CLICKS. This is the regression test for the
    /// exact defect this work fixed: a count-in that counted down on screen in
    /// total silence, so you had no idea when to come in.
    @Test("Starting a count-in asks the engine for audible clicks")
    func countInRequestsAudibleClicks() async {
        let engine = MetronomeSpyEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        // Arm a track so record actually starts, and ask for a 4-beat count-in.
        guard let track = model.snapshot?.tracks.first else {
            Issue.record("the mock project has no tracks")
            return
        }
        model.setTrackArm(track.id, armed: true)
        await wait(model) { $0.firstArmedTrack != nil }
        model.countInBeats = 4

        model.toggleRecord()
        await waitFor { await engine.countInRequests.isEmpty == false }

        let requests = await engine.countInRequests
        #expect(
            requests.first == 4,
            """
            The count-in did not ask the engine to click. A silent count-in is \
            a number counting down with no sound behind it — it tells you \
            nothing about when to come in. Requests seen: \(requests)
            """)
    }

    @Test("Cancelling a count-in silences it as well as clearing the number")
    func cancellingACountInSilencesIt() async {
        let engine = MetronomeSpyEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        guard let track = model.snapshot?.tracks.first else {
            Issue.record("the mock project has no tracks")
            return
        }
        model.setTrackArm(track.id, armed: true)
        await wait(model) { $0.firstArmedTrack != nil }
        model.countInBeats = 4

        model.toggleRecord()
        await wait(model) { $0.isCountingIn }
        model.toggleRecord() // press again: cancels the count-in

        await waitFor { await engine.countInRequests.contains(0) }
        let requests = await engine.countInRequests
        #expect(
            requests.contains(0),
            """
            A cancelled count-in must tell the engine to stop clicking, or the \
            clicks carry on after the number on screen has gone. Requests: \
            \(requests)
            """)
    }

    // MARK: The click's one observable signal
    //
    // The metronome is deliberately excluded from the master bus, the meters,
    // the true-peak detector and the capture tap — which is what keeps it out
    // of a recorded take, and also what left the running app with NO way to
    // show that it is clicking. The owner reporting "one chirp and then
    // silence" had no reading to take. `StudioEngineStats.metronomeClicks`
    // (engine `metronomeClicks`) is that reading, and the engine chip in the
    // transport bar is where he takes it, so these pin what the chip says.

    /// A snapshot with the engine chip's inputs set and nothing else that
    /// matters — the chip is a pure function of exactly these three values.
    private func chipSnapshot(
        metronomeEnabled: Bool,
        clicks: Int,
        underruns: Int = 0
    ) -> StudioProjectSnapshot {
        StudioProjectSnapshot(
            revision: 1, name: "P", tempoBPM: 120,
            timeSignature: .fourFour, key: "C", lengthBars: 8, sections: [],
            tracks: [],
            transport: StudioTransportSnapshot(
                isPlaying: true, positionTicks: 0, capturedAtHostTime: 0,
                loopRegion: nil, recording: false, recordingTrackID: nil,
                metronomeEnabled: metronomeEnabled),
            stats: StudioEngineStats(
                callbackP95Millis: 1.25, underruns: underruns,
                engineLabel: "engine (live)", metronomeClicks: clicks),
            master: StudioMasterSnapshot(),
            provenanceSummary: "")
    }

    @Test("The engine chip shows the click count while the metronome is armed")
    func theChipShowsTheClickCount() {
        let armed = StudioEngineChip.text(for: chipSnapshot(metronomeEnabled: true, clicks: 8))
        #expect(
            armed.contains("8 clicks"),
            """
            The click count is not on screen. The metronome is kept out of \
            every meter on purpose, so this number is the ONLY thing in the \
            app that can distinguish "the engine is still clicking and \
            something after it is eating the sound" from "the engine stopped \
            clicking". Chip read: \(armed)
            """)
        #expect(armed.contains("underruns"), "the chip lost its existing engine truth")
    }

    /// ZERO IS A READING. While the metronome is armed the chip must show
    /// "0 clicks" rather than hiding the segment — an absent number is
    /// indistinguishable from a chip that does not report clicks at all, and
    /// "the number is not moving" is precisely half the diagnosis.
    @Test("An armed metronome that has not clicked still shows a zero")
    func anArmedMetronomeShowsZeroRatherThanNothing() {
        let text = StudioEngineChip.text(for: chipSnapshot(metronomeEnabled: true, clicks: 0))
        #expect(
            text.contains("0 clicks"),
            "an armed metronome with no clicks must READ zero, not go quiet: \(text)")
    }

    /// And it costs nothing when the metronome is off, so the transport bar's
    /// resting width is unchanged.
    @Test("With the click off and never used, the chip is exactly as it was")
    func theChipIsUnchangedWhenTheClickWasNeverUsed() {
        let text = StudioEngineChip.text(for: chipSnapshot(metronomeEnabled: false, clicks: 0))
        #expect(!text.contains("clicks"), "the chip grew when there was nothing to say: \(text)")
        #expect(text == "engine (live), 1.2 ms p95, 0 underruns", "chip read: \(text)")
    }

    /// A count-in clicks with the metronome switched OFF, so a nonzero count
    /// has to survive the toggle being off — otherwise the count-in, which is
    /// the other thing that can be silently broken, stays unobservable.
    @Test("A count-in's clicks stay visible after the metronome is off")
    func aCountInsClicksStayVisible() {
        let text = StudioEngineChip.text(for: chipSnapshot(metronomeEnabled: false, clicks: 4))
        #expect(
            text.contains("4 clicks"),
            "clicks already sounded but the chip hid them: \(text)")
    }

    /// VoiceOver hears it too. The chip is 10-point monospaced digits in a
    /// crowded strip; someone reading the app by ear must get the same number.
    @Test("VoiceOver speaks the click count")
    func voiceOverSpeaksTheClickCount() {
        let spoken = StudioEngineChip.spokenValue(
            for: chipSnapshot(metronomeEnabled: true, clicks: 8))
        #expect(spoken.contains("8 clicks"), "spoken: \(spoken)")
    }

    /// Before the engine has said anything, the chip says so. "starting" and
    /// "0 clicks" are different statements and only one of them is true.
    @Test("With no snapshot the chip says starting, not zero")
    func noSnapshotIsNotZero() {
        #expect(StudioEngineChip.text(for: nil) == "starting")
        #expect(StudioEngineChip.spokenValue(for: nil) == "starting")
    }

    /// THE ONE SEAM THIS SUITE CANNOT MEASURE, GUARDED AT SOURCE LEVEL.
    ///
    /// Everything above feeds `StudioEngineChip` a snapshot built by hand.
    /// The step BEFORE that — `RealStudioEngine` lifting `metronomeClicks` out
    /// of the engine's JSON — only exists behind `#if REAL_ENGINE`, which is
    /// compiled out of this run (`MAJIKS_ENGINE=mock swift test`), so no
    /// assertion here can execute it. Deleting that one line would leave every
    /// test in this file green and the number on screen frozen at zero, which
    /// is the same class of silent hole this whole lane exists to close.
    ///
    /// This is a source guard, not a measurement, and it is weaker than every
    /// other test here — it proves the key is READ FOR, not that the value
    /// arrives. The value's arrival is proved on the Rust side
    /// (`engine_stats_json_carries_the_real_click_count`), which asserts the
    /// same string carries a real count of 8.
    @Test("The real engine reads the click count out of the engine's stats")
    func theRealEngineParsesTheClickCount() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Engine/RealStudioEngine.swift")
            .standardizedFileURL
        let text = try String(contentsOf: sources, encoding: .utf8)
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(
            code.contains("\"metronomeClicks\""),
            """
            RealStudioEngine no longer reads `metronomeClicks` from the engine \
            stats. The chip would keep drawing a number and the number would \
            always be zero — a dead reading is worse than no reading, because \
            it answers the question wrongly.
            """)
        #expect(
            code.contains("metronomeClicks:"),
            "the parsed value is not being handed to StudioEngineStats")
    }

    @Test("Setting the click level reaches the engine")
    func levelReachesTheEngine() async {
        let engine = MetronomeSpyEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        model.metronomeLevelDB = 6
        await waitFor { await engine.levelRequests.isEmpty == false }
        let levels = await engine.levelRequests
        #expect(levels.contains(6), "level did not reach the engine: \(levels)")
    }
}

/// A mock engine that records what the metronome seam asked for.
///
/// Subclassing isn't available (the mock is an `actor`), so this wraps one and
/// forwards everything, intercepting only `setMetronome`.
actor MetronomeSpyEngine: StudioEngineProtocol {
    private let inner = StudioMockEngine()
    private(set) var countInRequests: [Int] = []
    private(set) var levelRequests: [Double] = []

    func setMetronome(enabled: Bool?, levelDB: Double?, countInBeats: Int?) async {
        if let countInBeats { countInRequests.append(countInBeats) }
        if let levelDB { levelRequests.append(levelDB) }
        await inner.setMetronome(enabled: enabled, levelDB: levelDB, countInBeats: countInBeats)
    }

    func snapshot(ifNewerThan revision: UInt64?) async -> StudioProjectSnapshot? {
        await inner.snapshot(ifNewerThan: revision)
    }

    @discardableResult
    func send(_ command: StudioEngineCommand) async -> StudioCommandResult {
        await inner.send(command)
    }

    func importAudio(path: String, trackID: UUID?, startTicks: Int64) async -> StudioCommandResult {
        await inner.importAudio(path: path, trackID: trackID, startTicks: startTicks)
    }

    @discardableResult
    func undo() async -> Bool { await inner.undo() }

    @discardableResult
    func redo() async -> Bool { await inner.redo() }

    func waveformTile(_ key: StudioTileKey) async -> StudioWaveformTile? {
        await inner.waveformTile(key)
    }

    func addInstrumentTrack(name: String, lengthTicks: Int64) async -> StudioInstrumentTrackOutcome {
        await inner.addInstrumentTrack(name: name, lengthTicks: lengthTicks)
    }

    func openInStudio(_ request: StudioLandingRequest) async -> StudioCommandResult {
        await inner.openInStudio(request)
    }
}
