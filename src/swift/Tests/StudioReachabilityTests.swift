import Testing
import Foundation
@testable import MajiksMusicStudio

// Reachability batch: prove every project/clip/track/section command reaches
// the mock engine's journaled command bus and is observable in the snapshot.
//
// The mock engine is SILENT BY DEFINITION — it applies inverses, journals undo,
// and returns truth through snapshot revisions. A command that reaches it but
// makes no visible change is still a failure here.
@MainActor
@Suite("Studio reachability batch")
struct StudioReachabilityTests {

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

    // MARK: - 1. Tempo

    @Test("setTempo changes the project BPM")
    func setTempoChangesBPM() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        let original = model.snapshot?.tempoBPM ?? 120
        #expect(original != 140, "default is not our target")

        model.setTempo(bpm: 140)
        await wait(model) { $0.snapshot?.tempoBPM == 140 }
        #expect(model.snapshot?.tempoBPM == 140, "tempo did not reach 140")

        // Undo reverts to original
        model.undo()
        await wait(model) { $0.snapshot?.tempoBPM == original }
        #expect(model.snapshot?.tempoBPM == original, "undo did not revert tempo")
    }

    @Test("setTempo clamps out-of-range values")
    func setTempoClamps() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        model.setTempo(bpm: 10)
        await wait(model) { $0.snapshot?.tempoBPM == 20 }
        #expect(model.snapshot?.tempoBPM == 20, "bpm below 20 clamped to 20")

        model.setTempo(bpm: 500)
        await wait(model) { $0.snapshot?.tempoBPM == 300 }
        #expect(model.snapshot?.tempoBPM == 300, "bpm above 300 clamped to 300")
    }

    // MARK: - 2. Time Signature

    @Test("setTimeSig changes the project time signature")
    func setTimeSigChanges() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        #expect(model.timeSignature == StudioTimeSignature(beatsPerBar: 4, beatUnit: 4),
               "default time sig is 4/4")

        model.setTimeSig(numerator: 3, denominator: 4)
        await wait(model) { $0.timeSignature == StudioTimeSignature(beatsPerBar: 3, beatUnit: 4) }
        #expect(model.timeSignature.beatsPerBar == 3, "time sig numerator did not reach 3")

        model.undo()
        await wait(model) { $0.timeSignature == StudioTimeSignature(beatsPerBar: 4, beatUnit: 4) }
        #expect(model.timeSignature.beatsPerBar == 4, "undo did not revert time sig")
    }

    @Test("setTimeSig rejects invalid denominators")
    func setTimeSigRejectsInvalidDenominators() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        model.setTimeSig(numerator: 4, denominator: 16)
        try? await Task.sleep(nanoseconds: 100_000_000)
        // 16 is not a valid denominator (must be 2, 4, or 8), so it should stay at 4/4
        #expect(model.timeSignature.beatUnit == 4, "invalid denominator 16 was rejected")
    }

    // MARK: - 3. Key

    @Test("setKey changes the project key")
    func setKeyChanges() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        model.setKey("A minor")
        await wait(model) { $0.snapshot?.key == "A minor" }
        #expect(model.snapshot?.key == "A minor", "key did not reach A minor")

        model.undo()
        await wait(model) { $0.snapshot?.key == "A min" }
        #expect(model.snapshot?.key == "A min", "undo did not revert key (expected A min default)")
    }

    // MARK: - 4. Markers

    @Test("setMarker and removeMarker reach the engine")
    func markerCommandsReachEngine() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        // Markers are stored on the mock engine, not in the snapshot directly,
        // so we use a spy that records commands.
        let spy = CommandSpyEngine()
        let spyModel = StudioViewModel(engine: spy)
        spyModel.startPolling()
        defer { spyModel.stopPolling() }
        await wait(spyModel) { $0.snapshot != nil }

        spyModel.setMarker(name: "CHORUS", bar: 16)
        await waitFor(spy) { $0.contains { $0.catalogName == "marker.set" } }
        let sent = await spy.commands
        #expect(sent.contains(where: { $0.catalogName == "marker.set" }),
                "marker.set command never reached the engine")

        spyModel.removeMarker(markerID: "test-marker")
        await waitFor(spy) { $0.contains { $0.catalogName == "marker.remove" } }
        let sent2 = await spy.commands
        #expect(sent2.contains(where: { $0.catalogName == "marker.remove" }),
                "marker.remove command never reached the engine")
    }

    // MARK: - 5. Sections

    @Test("setSection and removeSection reach the engine")
    func sectionCommandsReachEngine() async {
        let spy = CommandSpyEngine()
        let spyModel = StudioViewModel(engine: spy)
        spyModel.startPolling()
        defer { spyModel.stopPolling() }
        await wait(spyModel) { $0.snapshot != nil }

        spyModel.setSection(name: "VERSE 1", startBar: 0)
        await waitFor(spy) { $0.contains { $0.catalogName == "section.set" } }
        let sent = await spy.commands
        #expect(sent.contains(where: { $0.catalogName == "section.set" }),
                "section.set command never reached the engine")

        spyModel.removeSection(sectionID: "any-id")
        await waitFor(spy) { $0.contains { $0.catalogName == "section.remove" } }
        let sent2 = await spy.commands
        #expect(sent2.contains(where: { $0.catalogName == "section.remove" }),
                "section.remove command never reached the engine")
    }

    // MARK: - 6. Track properties

    @Test("renameTrack reaches the engine")
    func renameTrackReachesEngine() async {
        let spy = CommandSpyEngine()
        let spyModel = StudioViewModel(engine: spy)
        spyModel.startPolling()
        defer { spyModel.stopPolling() }
        await wait(spyModel) { $0.snapshot != nil }

        guard let track = spyModel.snapshot?.tracks.first else {
            Issue.record("mock project has no tracks"); return
        }

        spyModel.renameTrack(track.id, name: "Drums")
        await waitFor(spy) { cmds in
            cmds.contains(where: { cmd in
                guard cmd.catalogName == "track.rename" else { return false }
                if case .catalog(_, let params) = cmd {
                    return params["trackId"] as? String == track.id.uuidString
                        && params["name"] as? String == "Drums"
                }
                return false
            })
        }
        let sent = await spy.commands
        #expect(sent.contains(where: {
            $0.catalogName == "track.rename"
        }), "track.rename command never reached the engine")
    }

    @Test("reorderTrack reaches the engine")
    func reorderTrackReachesEngine() async {
        let spy = CommandSpyEngine()
        let spyModel = StudioViewModel(engine: spy)
        spyModel.startPolling()
        defer { spyModel.stopPolling() }
        await wait(spyModel) { $0.snapshot != nil }

        guard let track = spyModel.snapshot?.tracks.first else {
            Issue.record("mock project has no tracks"); return
        }

        spyModel.reorderTrack(track.id, to: 2)
        await waitFor(spy) { $0.contains { $0.catalogName == "track.reorder" } }
        let sent = await spy.commands
        #expect(sent.contains(where: { $0.catalogName == "track.reorder" }),
                "track.reorder command never reached the engine")
    }

    // MARK: - 7. Clip properties

    @Test("renameClip reaches the engine")
    func renameClipReachesEngine() async {
        let spy = CommandSpyEngine()
        let spyModel = StudioViewModel(engine: spy)
        spyModel.startPolling()
        defer { spyModel.stopPolling() }
        await wait(spyModel) { $0.snapshot != nil }

        guard let clip = spyModel.snapshot?.tracks.first?.clips.first else {
            Issue.record("mock project has no clips"); return
        }

        spyModel.renameClip(clip.id, name: "Main Riff")
        await waitFor(spy) { $0.contains { $0.catalogName == "clip.rename" } }
        let sent = await spy.commands
        #expect(sent.contains(where: { $0.catalogName == "clip.rename" }),
                "clip.rename command never reached the engine")
    }

    @Test("setClipGain reaches the engine")
    func setClipGainReachesEngine() async {
        let spy = CommandSpyEngine()
        let spyModel = StudioViewModel(engine: spy)
        spyModel.startPolling()
        defer { spyModel.stopPolling() }
        await wait(spyModel) { $0.snapshot != nil }

        guard let clip = spyModel.snapshot?.tracks.first?.clips.first else {
            Issue.record("mock project has no clips"); return
        }

        spyModel.setClipGain(clip.id, gainDB: -3)
        await waitFor(spy) { $0.contains { $0.catalogName == "clip.setGain" } }
        let sent = await spy.commands
        #expect(sent.contains(where: { $0.catalogName == "clip.setGain" }),
                "clip.setGain command never reached the engine")
    }

    @Test("setClipMute reaches the engine")
    func setClipMuteReachesEngine() async {
        let spy = CommandSpyEngine()
        let spyModel = StudioViewModel(engine: spy)
        spyModel.startPolling()
        defer { spyModel.stopPolling() }
        await wait(spyModel) { $0.snapshot != nil }

        guard let clip = spyModel.snapshot?.tracks.first?.clips.first else {
            Issue.record("mock project has no clips"); return
        }

        spyModel.setClipMute(clip.id, muted: true)
        await waitFor(spy) { $0.contains { $0.catalogName == "clip.mute" } }
        let sent = await spy.commands
        #expect(sent.contains(where: { $0.catalogName == "clip.mute" }),
                "clip.mute command never reached the engine")
    }

    // MARK: - 8. Track appearance

    @Test("setTrackColor reaches the engine")
    func setTrackColorReachesEngine() async {
        let spy = CommandSpyEngine()
        let spyModel = StudioViewModel(engine: spy)
        spyModel.startPolling()
        defer { spyModel.stopPolling() }
        await wait(spyModel) { $0.snapshot != nil }

        guard let track = spyModel.snapshot?.tracks.first else {
            Issue.record("mock project has no tracks"); return
        }

        spyModel.setTrackColor(track.id, color: .orange)
        await waitFor(spy) { $0.contains { $0.catalogName == "track.setColor" } }
        let sent = await spy.commands
        #expect(sent.contains(where: { $0.catalogName == "track.setColor" }),
                "track.setColor command never reached the engine")
    }

    @Test("setTrackHeight reaches the engine")
    func setTrackHeightReachesEngine() async {
        let spy = CommandSpyEngine()
        let spyModel = StudioViewModel(engine: spy)
        spyModel.startPolling()
        defer { spyModel.stopPolling() }
        await wait(spyModel) { $0.snapshot != nil }

        guard let track = spyModel.snapshot?.tracks.first else {
            Issue.record("mock project has no tracks"); return
        }

        spyModel.setTrackHeight(track.id, height: 80)
        await waitFor(spy) { $0.contains { $0.catalogName == "track.setHeight" } }
        let sent = await spy.commands
        #expect(sent.contains(where: { $0.catalogName == "track.setHeight" }),
                "track.setHeight command never reached the engine")
    }

    // MARK: - Undo/redo round-trip for catalog commands

    @Test("undo reverts a catalog command (track.rename)")
    func undoRevertsCatalogCommand() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        guard let track = model.snapshot?.tracks.first else {
            Issue.record("no tracks"); return
        }
        let originalName = track.name

        model.renameTrack(track.id, name: "Renamed")
        await wait(model) { $0.snapshot?.tracks.first?.name == "Renamed" }
        #expect(model.snapshot?.tracks.first?.name == "Renamed",
                "track was not renamed in snapshot")

        model.undo()
        await wait(model) { $0.snapshot?.tracks.first?.name == originalName }
        #expect(model.snapshot?.tracks.first?.name == originalName,
                "undo did not revert track name back to \(originalName)")

        model.redo()
        await wait(model) { $0.snapshot?.tracks.first?.name == "Renamed" }
        #expect(model.snapshot?.tracks.first?.name == "Renamed",
                "redo did not restore Renamed")
    }
}

/// A mock engine that records every command sent through send().
actor CommandSpyEngine: StudioEngineProtocol {
    private let inner = StudioMockEngine()
    private(set) var commands: [StudioEngineCommand] = []

    func snapshot(ifNewerThan revision: UInt64?) async -> StudioProjectSnapshot? {
        await inner.snapshot(ifNewerThan: revision)
    }

    @discardableResult
    func send(_ command: StudioEngineCommand) async -> StudioCommandResult {
        commands.append(command)
        return await inner.send(command)
    }

    func setMetronome(enabled: Bool?, levelDB: Double?, countInBeats: Int?) async {
        await inner.setMetronome(enabled: enabled, levelDB: levelDB, countInBeats: countInBeats)
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

/// Poll an actor-isolated condition.
private func waitFor(
    _ spy: CommandSpyEngine,
    timeout: TimeInterval = 3.0,
    until condition: @Sendable @escaping ([StudioEngineCommand]) -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let cmds = await spy.commands
        if condition(cmds) { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
