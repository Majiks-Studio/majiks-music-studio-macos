import XCTest
@testable import MajiksMusicStudio

// Lane L5: pure-function coverage for the timeline shell.
// Snap math, trim/split, zoom, selection model, row layout, tile scheme.

final class StudioShellMathTests: XCTestCase {

    private let sig = StudioTimeSignature.fourFour          // 3840 ticks/bar
    private let waltz = StudioTimeSignature(beatsPerBar: 3, beatUnit: 4)
    private let sixEight = StudioTimeSignature(beatsPerBar: 6, beatUnit: 8)

    // MARK: Time signature ticks

    func testTicksPerBeatAndBar() {
        XCTAssertEqual(sig.ticksPerBeat, 960)
        XCTAssertEqual(sig.ticksPerBar, 3840)
        XCTAssertEqual(waltz.ticksPerBar, 2880)
        XCTAssertEqual(sixEight.ticksPerBeat, 480)     // eighth note
        XCTAssertEqual(sixEight.ticksPerBar, 2880)
    }

    // MARK: Grid + snap

    func testGridTicksPerMode() {
        XCTAssertNil(StudioTimelineMath.gridTicks(mode: .off, timeSignature: sig))
        XCTAssertEqual(StudioTimelineMath.gridTicks(mode: .bar, timeSignature: sig), 3840)
        XCTAssertEqual(StudioTimelineMath.gridTicks(mode: .beat, timeSignature: sig), 960)
        XCTAssertEqual(StudioTimelineMath.gridTicks(mode: .division, timeSignature: sig), 240)
    }

    func testNearestGridLineRoundsToCloserSide() {
        XCTAssertEqual(StudioTimelineMath.nearestGridLine(100, gridTicks: 960), 0)
        XCTAssertEqual(StudioTimelineMath.nearestGridLine(500, gridTicks: 960), 960)
        XCTAssertEqual(StudioTimelineMath.nearestGridLine(960, gridTicks: 960), 960)
        // Exact midpoint goes down (<= comparison).
        XCTAssertEqual(StudioTimelineMath.nearestGridLine(480, gridTicks: 960), 0)
    }

    func testMagneticSnapPullsOnlyWithinThreshold() {
        // 0.1 px per tick: 8 px threshold = 80 ticks.
        let pxPerTick: CGFloat = 0.1
        // 50 ticks from the bar line: inside the magnet, snaps.
        XCTAssertEqual(
            StudioTimelineMath.snap(3890, mode: .bar, timeSignature: sig, pxPerTick: pxPerTick),
            3840)
        // 300 ticks away: outside the magnet, stays raw.
        XCTAssertEqual(
            StudioTimelineMath.snap(3540, mode: .bar, timeSignature: sig, pxPerTick: pxPerTick),
            3540)
        // Snap off: always raw.
        XCTAssertEqual(
            StudioTimelineMath.snap(3890, mode: .off, timeSignature: sig, pxPerTick: pxPerTick),
            3890)
    }

    func testMagneticSnapScalesWithZoom() {
        // Very zoomed in (10 px per tick): 8 px = 0.8 ticks, so 50 ticks
        // from the line is nowhere near the magnet.
        XCTAssertEqual(
            StudioTimelineMath.snap(3890, mode: .bar, timeSignature: sig, pxPerTick: 10),
            3890)
    }

    func testHardSnapAlwaysLands() {
        XCTAssertEqual(
            StudioTimelineMath.hardSnap(3540, mode: .bar, timeSignature: sig), 3840)
        XCTAssertEqual(
            StudioTimelineMath.hardSnap(100, mode: .beat, timeSignature: sig), 0)
    }

    // MARK: Pixel conversions

    func testPixelTickRoundTrip() {
        let pxPerTick: CGFloat = 0.025    // 96 px per 4/4 bar
        let px = StudioTimelineMath.ticksToPx(7680, pxPerTick: pxPerTick, scrollTicks: 3840)
        XCTAssertEqual(px, 96, accuracy: 0.001)
        XCTAssertEqual(
            StudioTimelineMath.pxToTicks(px, pxPerTick: pxPerTick, scrollTicks: 3840), 7680)
    }

    // MARK: Move / trim / split

    func testClampedMoveKeepsClipInsideProject() {
        XCTAssertEqual(
            StudioTimelineMath.clampedMoveStart(
                proposedStartTicks: -500, lengthTicks: 1000, projectLengthTicks: 10000),
            0)
        XCTAssertEqual(
            StudioTimelineMath.clampedMoveStart(
                proposedStartTicks: 9990, lengthTicks: 1000, projectLengthTicks: 10000),
            9000)
        XCTAssertEqual(
            StudioTimelineMath.clampedMoveStart(
                proposedStartTicks: 4000, lengthTicks: 1000, projectLengthTicks: 10000),
            4000)
    }

    func testTrimLeadingClampsToMinLengthAndZero() {
        // Clip [1000, 5000): trim leading to 4900 would leave < min 240.
        let trimmed = StudioTimelineMath.trimmed(
            start: 1000, length: 4000, edge: .leading, toTicks: 4900, minLengthTicks: 240)
        XCTAssertEqual(trimmed.start, 4760)
        XCTAssertEqual(trimmed.length, 240)
        // Leading edge never goes below zero.
        let low = StudioTimelineMath.trimmed(
            start: 100, length: 400, edge: .leading, toTicks: -50, minLengthTicks: 240)
        XCTAssertEqual(low.start, 0)
        XCTAssertEqual(low.length, 500)
    }

    func testTrimTrailingClampsToMinLength() {
        let trimmed = StudioTimelineMath.trimmed(
            start: 1000, length: 4000, edge: .trailing, toTicks: 1100, minLengthTicks: 240)
        XCTAssertEqual(trimmed.start, 1000)
        XCTAssertEqual(trimmed.length, 240)
        let grown = StudioTimelineMath.trimmed(
            start: 1000, length: 4000, edge: .trailing, toTicks: 9000, minLengthTicks: 240)
        XCTAssertEqual(grown.length, 8000)
    }

    func testSplitLengthsOnlyInsideClip() {
        XCTAssertNil(StudioTimelineMath.splitLengths(start: 100, length: 400, atTicks: 100))
        XCTAssertNil(StudioTimelineMath.splitLengths(start: 100, length: 400, atTicks: 500))
        XCTAssertNil(StudioTimelineMath.splitLengths(start: 100, length: 400, atTicks: 700))
        let split = StudioTimelineMath.splitLengths(start: 100, length: 400, atTicks: 250)
        XCTAssertEqual(split?.left, 150)
        XCTAssertEqual(split?.right, 250)
    }

    // MARK: Zoom

    func testZoomToFitMatchesViewport() {
        let length: Int64 = 92 * 3840
        let pxPerTick = StudioTimelineMath.zoomToFit(
            projectLengthTicks: length, viewportWidth: 1000)
        XCTAssertEqual(CGFloat(length) * pxPerTick, 1000, accuracy: 0.5)
    }

    func testZoomClampBounds() {
        XCTAssertEqual(
            StudioTimelineMath.clampZoom(1_000_000), StudioTimelineMath.maxPxPerTick)
        XCTAssertEqual(
            StudioTimelineMath.clampZoom(0), StudioTimelineMath.minPxPerTick)
    }

    func testZoomAnchorKeepsTickUnderCursor() {
        let oldPxPerTick: CGFloat = 0.025
        let newPxPerTick: CGFloat = 0.05
        let oldScroll: Int64 = 3840
        let anchorPx: CGFloat = 200      // tick under cursor = 3840 + 8000
        let newScroll = StudioTimelineMath.scrollPreservingAnchor(
            anchorPx: anchorPx, oldPxPerTick: oldPxPerTick,
            newPxPerTick: newPxPerTick, oldScrollTicks: oldScroll)
        let tickBefore = CGFloat(oldScroll) + anchorPx / oldPxPerTick
        let tickAfter = CGFloat(newScroll) + anchorPx / newPxPerTick
        XCTAssertEqual(tickBefore, tickAfter, accuracy: 1.0)
    }

    // MARK: Position formatting

    func testPositionStringBarsBeatsDivisions() {
        XCTAssertEqual(StudioTimelineMath.positionString(ticks: 0, timeSignature: sig), "1.1.1")
        // Bar 33 beat 1 div 1 = 32 bars in.
        XCTAssertEqual(
            StudioTimelineMath.positionString(ticks: 32 * 3840, timeSignature: sig), "33.1.1")
        // One beat + one division (240 ticks) into bar 2.
        XCTAssertEqual(
            StudioTimelineMath.positionString(ticks: 3840 + 960 + 240, timeSignature: sig),
            "2.2.2")
        // 3/4: bar length 2880.
        XCTAssertEqual(
            StudioTimelineMath.positionString(ticks: 2880, timeSignature: waltz), "2.1.1")
    }

    // MARK: Selection model

    func testRegionSelectionNormalizesAndNames() {
        let region = StudioRegionSelection(rawStart: 48 * 3840, rawEnd: 32 * 3840)
        XCTAssertEqual(region?.startTicks, 32 * 3840)
        XCTAssertEqual(region?.endTicks, 48 * 3840)
        XCTAssertEqual(region?.barRange(timeSignature: sig), 33...48)
        XCTAssertNil(StudioRegionSelection(rawStart: 100, rawEnd: 100))
    }

    func testRulerRegionSnapsToBarsAndKeepsMinimumOneBar() {
        let region = StudioSelectionOps.rulerRegion(
            fromTicks: 3841, toTicks: 3900, timeSignature: sig)
        XCTAssertEqual(region?.startTicks, 3840)
        XCTAssertEqual(region?.endTicks, 3840 + 3840)
    }

    func testClickSelectionReplaceAndShiftToggle() {
        let a = UUID(), b = UUID()
        var selection = StudioSelection.empty
        selection = StudioSelectionOps.clicked(selection, clipID: a, shift: false)
        XCTAssertEqual(selection.clipIDs, [a])
        selection = StudioSelectionOps.clicked(selection, clipID: b, shift: true)
        XCTAssertEqual(selection.clipIDs, [a, b])
        selection = StudioSelectionOps.clicked(selection, clipID: a, shift: true)
        XCTAssertEqual(selection.clipIDs, [b])
        selection = StudioSelectionOps.clicked(selection, clipID: a, shift: false)
        XCTAssertEqual(selection.clipIDs, [a])
    }

    func testClickReplacesRegionSelection() {
        var selection = StudioSelection.empty
        selection.region = StudioRegionSelection(rawStart: 0, rawEnd: 3840)
        selection = StudioSelectionOps.clicked(selection, clipID: UUID(), shift: false)
        XCTAssertNil(selection.region)
    }

    func testRubberBandIntersectionAndShiftUnion() {
        let a = UUID(), b = UUID(), c = UUID()
        let frames: [(id: UUID, frame: CGRect)] = [
            (a, CGRect(x: 0, y: 0, width: 100, height: 50)),
            (b, CGRect(x: 200, y: 0, width: 100, height: 50)),
            (c, CGRect(x: 0, y: 100, width: 100, height: 50)),
        ]
        let band = CGRect(x: 50, y: 10, width: 200, height: 20)
        var selection = StudioSelectionOps.rubberBand(
            .empty, rect: band, clipFrames: frames, shift: false)
        XCTAssertEqual(selection.clipIDs, [a, b])
        // Shift extends with a second band over c.
        let band2 = CGRect(x: 10, y: 90, width: 50, height: 40)
        selection = StudioSelectionOps.rubberBand(
            selection, rect: band2, clipFrames: frames, shift: true)
        XCTAssertEqual(selection.clipIDs, [a, b, c])
    }

    func testBandRectNormalizesCorners() {
        let rect = StudioSelectionOps.bandRect(
            from: CGPoint(x: 100, y: 80), to: CGPoint(x: 20, y: 10))
        XCTAssertEqual(rect, CGRect(x: 20, y: 10, width: 80, height: 70))
    }

    // MARK: Clip lineage

    func testAnAuthoredMidiClipDoesNotClaimItWasImported() {
        func clip(generative: Bool, isMidi: Bool) -> StudioClipSnapshot {
            StudioClipSnapshot(
                id: UUID(), name: "cm_CD2F0C17", startTicks: 0, lengthTicks: 3840,
                generative: generative, waveformSeed: 0, isMidi: isMidi)
        }
        // The Instrument button's clip: track.add + device.add + clip.placeMidi.
        // Nothing was imported, and saying so in the panel that exists to report
        // provenance is worse than saying nothing.
        XCTAssertEqual(clip(generative: false, isMidi: true).origin, .authored)
        XCTAssertEqual(clip(generative: false, isMidi: true).origin.label, "Authored")
        // The two cases that were already right stay right.
        XCTAssertEqual(clip(generative: false, isMidi: false).origin, .imported)
        XCTAssertEqual(clip(generative: true, isMidi: false).origin, .generated)
        // A generated clip stays generated even if it is note-backed: the AI
        // badge outranks how the notes are stored.
        XCTAssertEqual(clip(generative: true, isMidi: true).origin, .generated)
    }

    /// The engine's classification wins over the derived fallback. `.recorded`
    /// is the proof: no combination of `generative` + `isMidi` can produce it,
    /// so seeing it means the snapshot's `origin` was actually read. Only the
    /// journal knows a note clip was PLAYED rather than written, and only the
    /// engine has the journal.
    func testTheEnginesOriginOutranksTheDerivedFallback() {
        func clip(engineOrigin: StudioClipOrigin?, generative: Bool = false, isMidi: Bool = true) -> StudioClipSnapshot {
            StudioClipSnapshot(
                id: UUID(), name: "c", startTicks: 0, lengthTicks: 3840,
                generative: generative, waveformSeed: 0, isMidi: isMidi,
                engineOrigin: engineOrigin)
        }
        XCTAssertEqual(clip(engineOrigin: .recorded).origin, .recorded)
        XCTAssertEqual(clip(engineOrigin: .recorded).origin.label, "Recorded")
        // The engine can also correct the fallback outright.
        XCTAssertEqual(clip(engineOrigin: .imported, isMidi: true).origin, .imported)
        XCTAssertEqual(clip(engineOrigin: .authored, generative: true).origin, .authored)
        // No engine answer: the derived fallback still applies (mock engine).
        XCTAssertEqual(clip(engineOrigin: nil).origin, .authored)
    }

    /// The UI's vocabulary IS the manifest's vocabulary. `StudioClipOrigin`'s
    /// raw values are what the snapshot's `origin` string is decoded through,
    /// so if the engine ever renames a term this lookup starts returning nil and
    /// the UI silently falls back to guessing — the exact failure this lane
    /// removed. Checked against the contract file itself, not a copy of it.
    func testClipOriginCasesMatchTheManifestSchemaEnum() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // swift
            .deletingLastPathComponent()   // src
            .deletingLastPathComponent()   // repo root
        let schemaURL = repoRoot
            .appendingPathComponent("engine/contracts/provenance-manifest.schema.json")
        let data = try Data(contentsOf: schemaURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        func dict(_ node: Any?, _ key: String) -> [String: Any]? {
            (node as? [String: Any])?[key] as? [String: Any]
        }
        let clipProps = dict(dict(dict(dict(json, "properties"), "clips"), "items"), "properties")
        let schemaOrigins = try XCTUnwrap(
            (clipProps?["origin"] as? [String: Any])?["enum"] as? [String],
            "manifest schema has no clips[].origin enum")

        XCTAssertEqual(
            Set(schemaOrigins), Set(StudioClipOrigin.allCases.map(\.rawValue)),
            "StudioClipOrigin and the manifest's origin enum have drifted")
    }

    // MARK: Export provenance preview

    private func previewSnapshot(_ clips: [StudioClipSnapshot]) -> StudioProjectSnapshot {
        StudioProjectSnapshot(
            revision: 1, name: "P", tempoBPM: 120, timeSignature: sig,
            key: "C", lengthBars: 8, sections: [],
            tracks: [StudioTrackSnapshot(id: UUID(), name: "t", kind: .other, clips: clips)],
            transport: StudioTransportSnapshot(
                isPlaying: false, positionTicks: 0, capturedAtHostTime: 0,
                loopRegion: nil, recording: false, recordingTrackID: nil),
            stats: StudioEngineStats(callbackP95Millis: 0, underruns: 0, engineLabel: "test"),
            master: StudioMasterSnapshot(),
            provenanceSummary: "")
    }

    /// The pre-export preview must not contradict the manifest the very same
    /// dialog is about to write. It used to sort every non-generated clip into
    /// "imported", so a note clip written in the piano roll and a take the user
    /// performed both showed up as imported files.
    func testExportPreviewBucketsByTheManifestsOwnTerms() {
        func clip(_ origin: StudioClipOrigin, _ len: Int64) -> StudioClipSnapshot {
            StudioClipSnapshot(
                id: UUID(), name: "c", startTicks: 0, lengthTicks: len,
                generative: origin == .generated, waveformSeed: 0,
                isMidi: origin == .authored || origin == .recorded,
                engineOrigin: origin)
        }
        let preview = StudioProvenancePreview.from(previewSnapshot(
            [clip(.generated, 400), clip(.imported, 300), clip(.recorded, 200), clip(.authored, 100)]))
        XCTAssertEqual(preview.clipCount, 4)
        XCTAssertEqual(preview.generatedClips, 1)
        XCTAssertEqual(preview.importedClips, 1)
        XCTAssertEqual(preview.recordedClips, 1)
        XCTAssertEqual(preview.authoredClips, 1)
        // Exactly ONE clip is imported — the previous code would have said three.
        XCTAssertEqual(preview.generatedPct, 40)
        XCTAssertEqual(preview.importedPct, 30)
        XCTAssertEqual(preview.recordedPct, 20)
        XCTAssertEqual(preview.authoredPct, 10)
        // Same wording, same order as the engine's Composition::summary_line.
        XCTAssertEqual(preview.summaryLine, "40% generated / 30% imported / 20% recorded / 10% authored")
        XCTAssertTrue(preview.hasGeneratedContent)
        XCTAssertEqual(preview.buckets.filter { $0.clips > 0 }.count, 4)
    }

    func testExportPreviewOfANoteClipProjectNamesNothingImported() {
        let preview = StudioProvenancePreview.from(previewSnapshot([
            StudioClipSnapshot(
                id: UUID(), name: "c", startTicks: 0, lengthTicks: 3840,
                generative: false, waveformSeed: 0, isMidi: true, engineOrigin: .authored)]))
        XCTAssertEqual(preview.importedClips, 0)
        XCTAssertEqual(preview.importedPct, 0)
        XCTAssertEqual(preview.summaryLine, "100% authored")
        XCTAssertFalse(preview.hasGeneratedContent)
    }

    func testSplitTargetsPrefersSelection() {
        let sig = self.sig
        func clip(_ id: UUID, start: Int64, len: Int64) -> StudioClipSnapshot {
            StudioClipSnapshot(
                id: id, name: "clip", startTicks: start, lengthTicks: len,
                generative: true, waveformSeed: 1)
        }
        let a = UUID(), b = UUID(), c = UUID()
        let tracks = [
            StudioTrackSnapshot(
                id: UUID(), name: "One", kind: .vocals,
                clips: [clip(a, start: 0, len: 4 * sig.ticksPerBar)]),
            StudioTrackSnapshot(
                id: UUID(), name: "Two", kind: .drums,
                clips: [clip(b, start: 0, len: 4 * sig.ticksPerBar),
                        clip(c, start: 8 * sig.ticksPerBar, len: 4 * sig.ticksPerBar)]),
        ]
        let at = 2 * sig.ticksPerBar
        // No selection: every clip under the playhead splits.
        XCTAssertEqual(
            Set(StudioSelectionOps.splitTargets(atTicks: at, selection: .empty, tracks: tracks)),
            [a, b])
        // Selection restricts.
        var selection = StudioSelection.empty
        selection.clipIDs = [b]
        XCTAssertEqual(
            StudioSelectionOps.splitTargets(atTicks: at, selection: selection, tracks: tracks),
            [b])
        // Selected clip not under the tick: nothing splits.
        selection.clipIDs = [c]
        XCTAssertTrue(
            StudioSelectionOps.splitTargets(atTicks: at, selection: selection, tracks: tracks)
                .isEmpty)
    }

    // MARK: Row layout

    func testRowLayoutWithTakeLanesAndAutomation() {
        let takeTrack = StudioTrackSnapshot(
            id: UUID(), name: "Drums", kind: .drums, clips: [],
            takeLane: StudioTakeLaneSnapshot(
                id: UUID(), regionStartTicks: 0, regionLengthTicks: 3840,
                takes: [
                    StudioTakeSnapshot(id: UUID(), name: "Take 1", state: .rendering, picked: false),
                    StudioTakeSnapshot(id: UUID(), name: "Take 2", state: .rendering, picked: true),
                ]))
        let autoTrack = StudioTrackSnapshot(
            id: UUID(), name: "VO", kind: .imported, clips: [], hasVolumeAutomation: true,
            volumeAutomation: [StudioAutoPoint(id: "p", positionTicks: 0, value: 0)])

        // Collapsed: no take-lane row.
        var rows = StudioRowLayoutBuilder.rows(
            tracks: [takeTrack, autoTrack], expandedTakeLanes: [])
        XCTAssertEqual(rows.count, 3)   // track, track, automation (volume)
        XCTAssertEqual(rows[0].height, StudioTokens.trackHeightDefault)
        XCTAssertEqual(rows[2].kind, .automation(trackID: autoTrack.id, target: .volume))

        // Expanded: take lane inserts directly under its track.
        rows = StudioRowLayoutBuilder.rows(
            tracks: [takeTrack, autoTrack], expandedTakeLanes: [takeTrack.id])
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[1].kind, .takeLane(trackID: takeTrack.id))
        XCTAssertEqual(rows[1].height, 2 * StudioTokens.takeRowHeight + 6)
        XCTAssertEqual(rows[1].y, StudioTokens.trackHeightDefault)
        // Later rows shift down by the lane height.
        XCTAssertEqual(rows[2].y, rows[1].maxY)
        XCTAssertEqual(
            StudioRowLayoutBuilder.totalHeight(rows), rows[3].maxY)

        // Hit test agrees with layout.
        let hit = StudioRowLayoutBuilder.row(
            at: StudioTokens.trackHeightDefault + 5, rows: rows)
        XCTAssertEqual(hit?.kind, .takeLane(trackID: takeTrack.id))
        XCTAssertNil(StudioRowLayoutBuilder.row(at: -1, rows: rows))
    }

    // MARK: Tile scheme

    func testTileBucketCoarsensAsZoomShrinks() {
        // Zoomed in: fine bucket.
        XCTAssertEqual(StudioTileScheme.bucket(forPxPerTick: 0.2), 0)
        // Way zoomed out: coarser buckets, monotonically.
        let mid = StudioTileScheme.bucket(forPxPerTick: 0.01)
        let far = StudioTileScheme.bucket(forPxPerTick: 0.001)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertGreaterThanOrEqual(far, mid)
    }

    func testTileRangeCoversSourceWindow() {
        let bucket = 0
        let perTile = StudioTileScheme.ticksPerTile(bucket: bucket)
        let range = StudioTileScheme.tileRange(
            bucket: bucket, sourceTicks: (perTile / 2)..<(perTile * 2 + 1))
        XCTAssertEqual(range, 0...2)
        // Empty-ish range clamps sanely.
        XCTAssertEqual(
            StudioTileScheme.tileRange(bucket: bucket, sourceTicks: 0..<1), 0...0)
    }

    func testMockTileGenerationIsDeterministicAndBounded() {
        let key = StudioTileKey(seed: 42, bucket: 1, tileIndex: 3)
        let a = StudioMockEngine.generateTile(key)
        let b = StudioMockEngine.generateTile(key)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.peaks.count, StudioTileScheme.binsPerTile)
        XCTAssertTrue(a.peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
        // Different seed, different waveform.
        let c = StudioMockEngine.generateTile(StudioTileKey(seed: 43, bucket: 1, tileIndex: 3))
        XCTAssertNotEqual(a.peaks, c.peaks)
    }

    // MARK: Palette matching

    @MainActor
    func testPaletteFuzzyMatchRanksPrefixFirst() {
        let entries = StudioPaletteCatalog.entries()
        let results = StudioPaletteCatalog.matches("clip.s", in: entries)
        // Only wired commands appear in entries; clip.split is wired, clip.setGain is not.
        XCTAssertTrue(results.contains { $0.id == "clip.split" })
        // Scatter match still hits.
        let scatter = StudioPaletteCatalog.matches("tplay", in: entries)
        XCTAssertTrue(scatter.contains { $0.id == "transport.play" })

        // Catalog parity. This count went stale multiple times: the palette once
        // had the old v1 list of 71, then 74, and is NOW driven from
        // command-catalog.v2.json (119) via CatalogNames.swift so it cannot
        // drift again. Only wired commands are shown as palette entries; the
        // name list itself is the full catalog.
        let names = StudioPaletteCatalog.catalogNames
        XCTAssertEqual(Set(names).count, names.count, "palette command names must be unique")
        for expected in ["transport.play", "transport.stop", "clip.split",
                         "record.start", "record.stop", "record.cancel",
                         "track.setInputChannel", "record.inputListen",
                         "note.timing.set", "note.quantize"] {
            XCTAssertTrue(names.contains(expected), "palette lost \(expected)")
        }
        XCTAssertEqual(names.count, 119, "palette command count changed - regenerate CatalogNames.swift from command-catalog.v2.json")
    }

    // MARK: - The `.catalog` id contract
    //
    // "error on changing synth type" was one line: the generic `.catalog`
    // command forwarded its params to the engine verbatim, so a `trackId`
    // carrying the UI's surrogate `UUID` named a track the engine had never
    // heard of and every `device.param.set` was refused. The fix translates the
    // param keys in `StudioEngineIDParam.uiMinted` on the way out
    // (`RealStudioEngine.resolvingUIIDs`).
    //
    // WHICH LEAVES A LIVE EDGE. That resolver knows two key NAMES. A future
    // lane writing `.catalog(name: "clip.move", params: ["toTrackId": …])`
    // reintroduces the whole bug in one line, silently, and every mock test
    // stays green — because the mock resolves ids by parsing whatever key it
    // happens to read. So the call sites are held to the list here, in a build
    // that actually runs (`swift test` is mock-only; the real-engine proof in
    // `StudioInstrumentRealEngineTests` compiles under gate 5 and runs under
    // neither `swift test` nor any of the six gates).

    /// Param keys a `.catalog` call site may carry that name a track or a clip.
    /// Anything else spelled `…trackId` / `…clipId` is a UI id the resolver will
    /// not translate.
    private func catalogParamKeys(in text: String) throws -> [String] {
        let call = try NSRegularExpression(pattern: #"\.catalog\(name:"#)
        let key = try NSRegularExpression(pattern: #""([A-Za-z0-9_]+)"\s*:"#)
        var keys: [String] = []
        let ns = text as NSString
        for match in call.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // The params literal that follows. Bounded rather than brace-matched:
            // every `.catalog` literal in this codebase is well under this, and a
            // bound that overshoots can only ever ADD keys to the check.
            let start = match.range.location
            let span = NSRange(location: start, length: min(700, ns.length - start))
            for k in key.matches(in: text, range: span) {
                keys.append(ns.substring(with: k.range(at: 1)))
            }
        }
        return keys
    }

    func testEveryCatalogSiteNamesATrackOrClipWithTheKeyTheResolverTranslates() throws {
        let sources = try appSourcesForCatalogScan()
        var offenders: [String] = []
        var sitesScanned = 0

        for (name, text) in sources {
            let keys = try catalogParamKeys(in: text)
            sitesScanned += keys.count
            for k in keys {
                let lower = k.lowercased()
                guard lower.hasSuffix("trackid") || lower.hasSuffix("clipid") else { continue }
                guard !StudioEngineIDParam.uiMinted.contains(k) else { continue }
                offenders.append("\(name): \"\(k)\"")
            }
        }

        XCTAssertGreaterThan(sitesScanned, 20,
                             "the scan found almost no `.catalog` params, so it is not scanning")
        XCTAssertTrue(
            offenders.isEmpty,
            """
            these `.catalog` params name a track or a clip under a key \
            `RealStudioEngine.resolvingUIIDs` does not translate, so on the real engine they \
            reach the engine as the UI's own UUID and are refused: \
            \(offenders.sorted().joined(separator: ", "))
            """)
    }

    /// The resolver's list is the two classifications, in order, and nothing
    /// else. Growing it means teaching `resolvingUIIDs` which map to look the
    /// new key up in — the list alone does nothing.
    ///
    /// This used to pin the literal `["trackId", "clipId"]`, and that pin was
    /// wrong within the hour: `targetTrackId`, `targetClipId`, `contextClipId`,
    /// `referenceClipId`, `clipIdA` and `clipIdB` all name existing objects and
    /// none of them were translated. A frozen literal cannot notice a catalog
    /// key it has never heard of, so COMPLETENESS is now derived from
    /// `command-catalog.v2.json` in `StudioCatalogIDCoverageTests`; what stays
    /// here is the structural claim that `uiMinted` is exactly the union the
    /// resolver walks.
    func testTheResolverWalksExactlyTheClassifiedTrackAndClipKeys() {
        XCTAssertEqual(StudioEngineIDParam.uiMinted,
                       StudioEngineIDParam.trackKeys + StudioEngineIDParam.clipKeys)
        XCTAssertTrue(StudioEngineIDParam.trackKeys.contains(StudioEngineIDParam.trackID))
        XCTAssertTrue(StudioEngineIDParam.clipKeys.contains(StudioEngineIDParam.clipID))
    }

    /// Every `.swift` under `Sources`, for the `.catalog` scan below. A copy of
    /// the enumeration `StudioHelpTests` uses rather than a shared one: the two
    /// nets guard different things and a shared helper would let a change made
    /// for one silently narrow the other.
    private func appSourcesForCatalogScan() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Tests
            .appendingPathComponent("../Sources")
            .standardizedFileURL
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "cannot enumerate \(root.path)")
        var out: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 20, "the source scan found almost nothing")
        return out
    }
}
