import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// The whole chain, end to end: an engine holding a MIDI clip with notes in it,
// through the 30 Hz poll, through the note store, through `drawClipBody`'s kind
// branch, onto rasterized pixels of the REAL `StudioTimelineCanvas`.
//
// StudioMidiClipRenderTests proves the note layer draws what it should. This
// file proves the arrangement ASKS it to — the one-line `if clip.isMidi` in
// `drawClipBody` is exactly the sort of wiring a renderer test cannot see, and
// the bug being fixed WAS a wiring bug: `drawWaveform` was called
// unconditionally, ran happily, and produced nothing for a note clip.
//
// StudioMockEngine cannot serve this: it has no note seam and never produces a
// MIDI clip, so a MIDI clip is unreachable through it in a mock build. The fake
// below is not a shortcut around the production path — the model polls it with
// the real `startPolling`, the canvas draws from the real snapshot, and the
// store fetches over the real `StudioNoteEngineProtocol`.

// MARK: - A project with one MIDI clip on one track
//
// File scope rather than nested in the (main-actor) test case: a @MainActor
// class isolates its own statics, and an actor cannot read those.

private let fixtureTrackID = UUID()
private let fixtureClipID = UUID()
private let fixtureClipLengthTicks: Int64 = 4 * StudioTimeSignature.fourFour.ticksPerBar

private func fixtureNote(_ pitch: Int, _ beat: Double, _ length: Double = 0.5) -> StudioNote {
    StudioNote(
        id: String(format: "A%03d%04d", pitch, Int(beat * 100)),
        startTicks: Int64(beat * Double(StudioTick.ppq)),
        lengthTicks: Int64(length * Double(StudioTick.ppq)),
        pitch: StudioNote.clampPitch(pitch),
        velocity: 100)
}

/// An engine that serves ONE fixed project and the note seam for its clip.
/// Everything the arrangement reads is engine truth here, exactly as it is on
/// the real engine (where the two protocols are likewise one actor).
private actor FakeMidiEngine: StudioEngineProtocol, StudioNoteEngineProtocol {
    private let notes: [StudioNote]
    private let revision: UInt64 = 7

    init(notes: [StudioNote]) { self.notes = notes }

    func snapshot(ifNewerThan clientRevision: UInt64?) async -> StudioProjectSnapshot? {
        if let clientRevision, clientRevision >= revision { return nil }
        return StudioProjectSnapshot(
            revision: revision,
            name: "midi probe",
            tempoBPM: 120,
            timeSignature: .fourFour,
            key: "C min",
            lengthBars: 8,
            sections: [],
            tracks: [StudioTrackSnapshot(
                id: fixtureTrackID,
                name: "piano",
                kind: .other,
                clips: [StudioClipSnapshot(
                    id: fixtureClipID,
                    name: "piano",
                    startTicks: 0,
                    lengthTicks: fixtureClipLengthTicks,
                    generative: false,
                    waveformSeed: 0,
                    isMidi: true,
                    engineOrigin: .recorded)],
                takeLane: nil)],
            transport: StudioTransportSnapshot(
                isPlaying: false, positionTicks: 0, capturedAtHostTime: 0, loopRegion: nil),
            stats: StudioEngineStats(
                callbackP95Millis: 1, underruns: 0, engineLabel: "Fake engine"),
            master: StudioMasterSnapshot(),
            provenanceSummary: "100% recorded")
    }

    func noteSession(clipID: UUID, ifNewerThan revision: UInt64?) async -> StudioNoteSessionSnapshot? {
        guard clipID == fixtureClipID else { return nil }
        if let revision, revision >= self.revision { return nil }
        return StudioNoteSessionSnapshot(
            revision: self.revision,
            clip: StudioMidiClipSnapshot(
                id: clipID, trackID: fixtureTrackID, name: "piano",
                startTicks: 0, lengthTicks: fixtureClipLengthTicks,
                notes: StudioNote.sorted(notes), kind: .other),
            barGrid: StudioBarGrid(timeSignature: .fourFour),
            tempoMap: .constant(bpm: 120),
            transport: StudioTransportSnapshot(
                isPlaying: false, positionTicks: 0, capturedAtHostTime: 0, loopRegion: nil))
    }

    // The rest of the seam: this engine exists to be READ.
    func send(_ command: StudioEngineCommand) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: "read-only fixture")
    }
    func send(_ command: StudioNoteCommand) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: "read-only fixture")
    }
    func setMetronome(enabled: Bool?, levelDB: Double?, countInBeats: Int?) async {}
    func importAudio(path: String, trackID: UUID?, startTicks: Int64) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: "read-only fixture")
    }
    func undo() async -> Bool { false }
    func redo() async -> Bool { false }
    /// There is no audio anywhere in this project, which is the point: an
    /// arrangement still routing MIDI clips through the waveform path would
    /// have nothing at all to draw, exactly as the shipped build did.
    func waveformTile(_ key: StudioTileKey) async -> StudioWaveformTile? { nil }
    func openInStudio(_ request: StudioLandingRequest) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: "read-only fixture")
    }
}

// MARK: - The arrangement

@MainActor
final class StudioMidiArrangementTests: XCTestCase {

    private let canvasWidth: CGFloat = 900
    private let canvasHeight: CGFloat = 320

    private func bootedModel(notes: [StudioNote]) async throws -> StudioViewModel {
        let model = StudioViewModel(engine: FakeMidiEngine(notes: notes))
        XCTAssertNotNil(
            model.noteEngine,
            "the fixture engine conforms to the note seam but the view model did not find it, so the arrangement could never read a note")
        model.startPolling()
        for _ in 0..<200 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(model.snapshot, "the fixture project never arrived")
        return model
    }

    /// Rasterize the real timeline canvas. Renders TWICE: the first pass is
    /// what arms the note read (the store is filled from the draw pass, the way
    /// waveform tiles are), so a single render would always catch the clip
    /// mid-fetch.
    private func raster(_ model: StudioViewModel) async throws -> [UInt8] {
        _ = try renderOnce(model)
        for _ in 0..<200 {
            if !model.midiNotes.hasPendingReads { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return try renderOnce(model)
    }

    private func renderOnce(_ model: StudioViewModel) throws -> [UInt8] {
        let view = StudioTimelineCanvas(model: model)
            .frame(width: canvasWidth, height: canvasHeight)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.cgImage, "the timeline canvas did not rasterize at all")
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return bytes
    }

    private func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count, !a.isEmpty else { return .max }
        var count = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 1..<4 where abs(Int(a[i + c]) - Int(b[i + c])) > 2 {
                count += 1
                break
            }
        }
        return count
    }

    // MARK: The bug, at the level it was reported

    func testTheArrangementDrawsAMidiClipsNotesAndNotABlankRectangle() async throws {
        let performance = (0..<28).map { i in
            fixtureNote(48 + (i * 5) % 25, Double(i) * 0.5, 0.45)
        }
        let full = try await raster(try await bootedModel(notes: performance))
        let empty = try await raster(try await bootedModel(notes: []))

        let changed = differing(full, empty)
        XCTAssertGreaterThan(
            changed, 800,
            "a 28-note MIDI clip and an empty one rendered only \(changed) differing pixels in the ARRANGEMENT: drawClipBody is not routing note clips to the note layer, so every MIDI clip is still a flat coloured rectangle with a name on it")
    }

    func testABusyMidiClipReadsDifferentlyFromASparseOne() async throws {
        var busy: [StudioNote] = []
        for slot in 0..<32 {
            for voice in 0..<3 {
                busy.append(fixtureNote(50 + voice * 7 + (slot % 3), Double(slot) * 0.5, 0.4))
            }
        }
        let sparse = [fixtureNote(60, 0, 2), fixtureNote(64, 4, 2)]

        let busyPixels = try await raster(try await bootedModel(notes: busy))
        let sparsePixels = try await raster(try await bootedModel(notes: sparse))
        XCTAssertGreaterThan(
            differing(busyPixels, sparsePixels), 800,
            "a 96-note passage and a two-note one look the same in the arrangement: you cannot tell a busy part from an almost-empty one at a glance, which is the reason to draw notes at all")
    }

    func testTheStoreIsFilledFromTheArrangementsOwnDrawPass() async throws {
        // Drawing the canvas should be all it takes to populate the note store
        // — waveform tiles work this way and notes must too, or a clip scrolled
        // into view stays blank until something else happens to poke it.
        let model = try await bootedModel(notes: [fixtureNote(60, 0, 1), fixtureNote(67, 1, 1)])
        XCTAssertEqual(model.midiNotes.cachedClipCount, 0, "nothing has drawn yet")
        _ = try await raster(model)
        guard case .notes(let held) = model.midiNotes.content(for: fixtureClipID) else {
            return XCTFail("drawing the arrangement did not fetch the clip's notes")
        }
        XCTAssertEqual(held.notes.count, 2)
    }
}
