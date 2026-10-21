import XCTest
import SwiftUI
import AVFoundation
@testable import MajiksMusicStudio

// The sounds vault browser's gates.
//
// What is actually at risk here, in the order it would hurt:
//
//  1. SCALE. A browser that works on twenty files and dies on fourteen
//     thousand is the defect, not the feature. The list next door in
//     `StudioBrowserView` carries the comment "this list isn't lazy" and a
//     `.prefix(60)` to survive; putting the vault through that shape would
//     stop the app. So the row count SwiftUI actually builds is MEASURED
//     against a 14,000-row fixture, not eyeballed.
//
//  2. THE MAIN THREAD. A concurrent lane is fixing a P0 where a computed
//     property that read like a field access did a synchronous XPC round trip
//     on every view-body evaluation. A file-scanning browser is the most
//     likely place in this app to repeat that. Two things are asserted: the
//     scan reports it did not run on the main thread, and rendering the view
//     over and over never scans and never filters.
//
//  3. AUDITION IS NOT AN EDIT. Asserted on both halves — that it makes real
//     SIGNAL (measured, not "a play method was called"), and that it leaves
//     the journal exactly where it was.
//
//  4. ONE GESTURE, ONE UNDO STEP. A dropped sound is exactly one journaled
//     command and undo puts the project back byte for byte.
//
//  5. THE FEED LINE. Every lane on this repo so far has had a survivor, and
//     the commonest shape is every component proven and the single line in the
//     view that feeds it unasserted. The last section is nothing but feed
//     lines.
//
// Nothing here launches a window and nothing here makes a noise: rendering is
// `ImageRenderer` (the deterministic no-window path `StudioMidiClipRenderTests`
// and `StudioPaneSizingTests` already use) and audition runs the SAME graph in
// manual rendering mode, so the frames land in a buffer instead of the output
// device.

final class StudioSoundsVaultTests: XCTestCase {

    // MARK: - Fixtures

    private func asset(
        _ name: String, pack: String = "Kit",
        kind: StudioSoundKind = .oneShot, bpm: Double? = nil, key: String? = nil,
        metadata: StudioSoundMetadataSource = .absent, path: String = "/tmp/x.wav"
    ) -> StudioSoundAsset {
        StudioSoundAsset(
            id: "\(pack)/\(name).wav", name: name, path: path, pack: pack,
            kind: kind, bpm: bpm, key: key, metadata: metadata)
    }

    /// Fourteen thousand sounds, in the shape the real catalogue has: mostly
    /// one-shots and loops, a minority of stems, and — as is true today —
    /// almost none of them carrying a tempo.
    private func vaultScaleFixture(_ count: Int = 14_000) -> [StudioSoundAsset] {
        (0..<count).map { i in
            let kind: StudioSoundKind = i % 3 == 0 ? .oneShot : (i % 3 == 1 ? .loop : .stem)
            let named = i % 500 == 0 ? "Hip-Hop Kick \(i)" : "Sound \(i)"
            // Only every hundredth carries tempo, which is generous next to a
            // vault that today carries it on none of them.
            let bpm: Double? = (kind != .oneShot && i % 100 == 0) ? 120 : nil
            return asset(named, pack: "Pack \(i / 100)", kind: kind, bpm: bpm,
                         metadata: bpm == nil ? .absent : .index)
        }
    }

    @MainActor
    private func renderedSize<V: View>(_ view: V) -> CGSize? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        return CGSize(width: cg.width, height: cg.height)
    }

    /// A real audio file on disk, written once per call. 440 Hz at 0.5
    /// amplitude, which gives an RMS of about 0.354 — a number the audition
    /// test can compare against instead of "greater than zero".
    private func writeTone(amplitude: Float, seconds: Double = 1.0) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audition-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            channel[frame] = amplitude * sinf(2 * .pi * 440 * Float(frame) / 44_100)
        }
        try file.write(from: buffer)
        return url
    }

    /// A directory of real (tiny, silent) audio files, for the scan tests.
    private func writeVault(files: Int, packs: Int = 4) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-\(UUID().uuidString)")
        let fm = FileManager.default
        for pack in 0..<packs {
            try fm.createDirectory(
                at: root.appendingPathComponent("Pack \(pack)"), withIntermediateDirectories: true)
        }
        // A one-byte file is not decodable audio and does not need to be: the
        // scan reads names and extensions, never contents. That is the point of
        // it being fast.
        for i in 0..<files {
            let url = root
                .appendingPathComponent("Pack \(i % packs)")
                .appendingPathComponent("Sound \(i).wav")
            try Data([0]).write(to: url)
        }
        // Two decoys that must NOT be counted.
        try Data([0]).write(to: root.appendingPathComponent("readme.txt"))
        try Data([0]).write(to: root.appendingPathComponent("artwork.png"))
        return root
    }

    // MARK: - 1. What the vault knows, and what it does not

    /// Tempo is READ from a name only in the one form that cannot mean
    /// anything else. Everything wider would be inventing values, and a browser
    /// that says "120 BPM" about the 120th snare in a pack is worse than one
    /// that says nothing.
    func testTempoIsReadFromANameOnlyWhenItIsUnambiguous() {
        XCTAssertEqual(StudioSoundNameMetadata.bpm(fromName: "Loop_128bpm_Fmin"), 128)
        XCTAssertEqual(StudioSoundNameMetadata.bpm(fromName: "house 125 BPM stab"), 125)
        XCTAssertEqual(StudioSoundNameMetadata.bpm(fromName: "drums-bpm140-a"), 140)

        // The refusals. Each of these is a plausible number in a name that is
        // almost certainly not a tempo.
        XCTAssertNil(StudioSoundNameMetadata.bpm(fromName: "Snare_120"),
                     "a bare number was read as a tempo; that is inventing a value")
        XCTAssertNil(StudioSoundNameMetadata.bpm(fromName: "Kick 808 01"))
        XCTAssertNil(StudioSoundNameMetadata.bpm(fromName: "hat_01"))
        // Out of range even with the marker.
        XCTAssertNil(StudioSoundNameMetadata.bpm(fromName: "weird_9000bpm"))
    }

    func testKeyIsReadFromANameOnlyWithAnExplicitQuality() {
        XCTAssertEqual(StudioSoundNameMetadata.key(fromName: "Bass_Fmin_01"), "F min")
        XCTAssertEqual(StudioSoundNameMetadata.key(fromName: "pad-C#maj-loop"), "C# maj")
        XCTAssertEqual(StudioSoundNameMetadata.key(fromName: "lead_Gm_04"), "G min")

        XCTAssertNil(StudioSoundNameMetadata.key(fromName: "Fmt_kick"),
                     "a word beginning with a note letter was read as a key")
        XCTAssertNil(StudioSoundNameMetadata.key(fromName: "clap_01"))
    }

    /// The honest row. A loop nobody has measured says so; a one-shot does not,
    /// because a kick genuinely has no tempo and printing "tempo unknown" on
    /// 5,943 drum hits would be noise rather than information.
    func testARowSaysTempoUnknownForALoopAndNothingForAHit() {
        XCTAssertTrue(
            asset("Break", kind: .loop).metaLine.contains("tempo unknown"),
            "a loop with no measured tempo showed nothing, which reads as 'no tempo'")
        XCTAssertFalse(
            asset("Kick", kind: .oneShot).metaLine.contains("tempo unknown"),
            "a drum hit was labelled 'tempo unknown'; a hit has no tempo to know")
        XCTAssertEqual(
            asset("Break", kind: .loop, bpm: 128, metadata: .index).metaLine,
            "loop · 128 BPM · Kit")
        // A value READ off a name is marked as a reading, not stated as fact.
        XCTAssertEqual(
            asset("Break", kind: .loop, bpm: 128, metadata: .filename).metaLine,
            "loop · 128 BPM? · Kit")
    }

    // MARK: - 2. Search

    /// The multi-word bug, fixed at the source. "hip hop" and "hip-hop" must
    /// find the same rows; the storefront's own search still returns 0 for the
    /// first and thousands for the second.
    func testATwoWordQueryFindsAHyphenatedName() {
        let assets = [
            asset("Hip-Hop Kick", pack: "Boom Bap"),
            asset("Techno Kick", pack: "Rave"),
            asset("Hop Scotch", pack: "Odd"),
        ]
        func names(_ q: String) -> [String] {
            StudioSoundsSearch.filter(
                assets, filter: StudioSoundFilter(query: q), projectBPM: 120, projectKey: nil
            ).map(\.name)
        }
        XCTAssertEqual(names("hip hop"), ["Hip-Hop Kick"])
        XCTAssertEqual(names("hip-hop"), ["Hip-Hop Kick"])
        XCTAssertEqual(names("hop hip"), ["Hip-Hop Kick"], "token order should not matter")
        XCTAssertEqual(names("kick"), ["Hip-Hop Kick", "Techno Kick"])
        XCTAssertEqual(names("boom"), ["Hip-Hop Kick"], "the pack name is searchable too")
    }

    /// THE mutation check for search: make `filter` ignore its query and this
    /// fails, because an empty query and "zzzz" must not return the same list.
    func testSearchActuallyNarrowsTheList() {
        let assets = vaultScaleFixture(1_000)
        let all = StudioSoundsSearch.filter(
            assets, filter: StudioSoundFilter(), projectBPM: 120, projectKey: nil)
        let none = StudioSoundsSearch.filter(
            assets, filter: StudioSoundFilter(query: "zzzznotathing"),
            projectBPM: 120, projectKey: nil)
        XCTAssertEqual(all.count, 1_000)
        XCTAssertEqual(none.count, 0, "a query that matches nothing returned rows")
    }

    /// The asymmetry that makes the tempo filter honest, and it is worth
    /// reading twice: a HIT passes, because it is tempo-free and fits any song;
    /// a LOOP whose tempo nobody has measured FAILS, because letting it through
    /// would be the browser saying "this fits" about something unmeasured.
    func testInTempoKeepsHitsAndDropsUnmeasuredLoops() {
        let assets = [
            asset("Kick", kind: .oneShot),                                    // no tempo, fits
            asset("Loop 120", kind: .loop, bpm: 120, metadata: .index),       // on tempo
            asset("Loop 140", kind: .loop, bpm: 140, metadata: .index),       // off tempo
            asset("Loop ???", kind: .loop),                                   // unmeasured
        ]
        let kept = StudioSoundsSearch.filter(
            assets, filter: StudioSoundFilter(inTempo: true), projectBPM: 120, projectKey: nil)
        XCTAssertEqual(kept.map(\.name), ["Kick", "Loop 120"])
        XCTAssertEqual(
            StudioSoundsSearch.hiddenForUnknownTempo(
                assets, filter: StudioSoundFilter(inTempo: true)),
            1,
            "the count of sounds hidden for MISSING tempo is what turns a dead end into an explanation")
    }

    func testInKeyMatchesAcrossSpellings() {
        XCTAssertTrue(StudioSoundsSearch.keysAgree("F min", "Fmin"))
        XCTAssertTrue(StudioSoundsSearch.keysAgree("F minor", "F min"))
        XCTAssertFalse(StudioSoundsSearch.keysAgree("F min", "F maj"))
        XCTAssertFalse(StudioSoundsSearch.keysAgree("F min", "G min"))

        let assets = [asset("Bass", kind: .loop, key: "F min", metadata: .index),
                      asset("Pad", kind: .loop, key: "A maj", metadata: .index),
                      asset("Stab", kind: .loop)]
        let kept = StudioSoundsSearch.filter(
            assets, filter: StudioSoundFilter(inKey: true), projectBPM: 120, projectKey: "Fmin")
        XCTAssertEqual(kept.map(\.name), ["Bass"])
    }

    // MARK: - 3. Scale

    /// Fourteen thousand assets, filtered, with a hardcoded expected count so
    /// the assertion cannot pass for every value the way a self-comparison can.
    func testSearchingFourteenThousandSoundsStaysResponsive() {
        let assets = vaultScaleFixture(14_000)
        XCTAssertEqual(assets.count, 14_000)

        let started = Date()
        let hits = StudioSoundsSearch.filter(
            assets, filter: StudioSoundFilter(query: "hip hop"),
            projectBPM: 120, projectKey: nil)
        let elapsed = Date().timeIntervalSince(started)

        // Every 500th of 14,000 is named "Hip-Hop Kick n": indices 0, 500, …,
        // 13,500 — twenty-eight of them.
        XCTAssertEqual(hits.count, 28, "the fixture's own arithmetic changed, or the filter did")
        XCTAssertLessThan(
            elapsed, 0.20,
            "filtering the vault took \(String(format: "%.3f", elapsed))s; at that cost a keystroke is a stutter")
    }

    // MARK: - 4. The scan does not run on the main thread

    /// Asserted on the ARTIFACT: the scan records where it actually executed,
    /// inside its enumeration loop, and returns it as data. Make the scanner
    /// `@MainActor` and this fails by name.
    @MainActor
    func testTheScanDoesNotRunOnTheMainThread() async throws {
        let root = try writeVault(files: 400)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(StudioVaultScanner.isOnMainThread(),
                      "this test is on the main actor, so the scan below has somewhere to hop off")

        let result = await StudioVaultScanner.scan(root: root)

        XCTAssertFalse(
            result.ranOnMainThread,
            "the vault walk ran on the MAIN THREAD. 14,000 stat calls there is the same bug as the "
            + "synchronous securityd round trip in a view body, with a slower syscall.")
        XCTAssertEqual(result.assets.count, 400, "the .txt and .png decoys were counted, or files were missed")
        XCTAssertFalse(result.rootMissing)
        XCTAssertNil(result.truncatedAt)
        XCTAssertEqual(result.assets.first?.pack, "Pack 0", "the containing folder is not reaching the asset")
    }

    /// The property a user actually feels: the app keeps answering while the
    /// scan runs. Measured by racing a main-actor hop against a live scan.
    @MainActor
    func testTheMainActorKeepsRunningWhileAScanIsInFlight() async throws {
        let root = try writeVault(files: 3_000, packs: 12)
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = Task { await StudioVaultScanner.scan(root: root) }

        // If the scan held the main actor, none of these would get a turn until
        // it finished.
        var hops = 0
        let deadline = Date().addingTimeInterval(2.0)
        while !scan.isCancelled, Date() < deadline, hops < 50 {
            await Task.yield()
            hops += 1
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let result = await scan.value

        XCTAssertGreaterThanOrEqual(
            hops, 50,
            "the main actor only got \(hops) turns while a 3,000-file scan ran; it was being blocked")
        XCTAssertEqual(result.assets.count, 3_000)
        XCTAssertFalse(result.ranOnMainThread)
    }

    /// A root that is not there is a DIFFERENT state from a root that is empty,
    /// and the browser says something different for each.
    @MainActor
    func testAMissingRootIsReportedRatherThanReadAsAnEmptyVault() async {
        let result = await StudioVaultScanner.scan(
            root: URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString)"))
        XCTAssertTrue(result.rootMissing)
        XCTAssertTrue(result.assets.isEmpty)
    }

    // MARK: - 5. The list is lazy, and the body does no work

    /// THE scale gate.
    ///
    /// 14,000 rows are handed to the browser and the number SwiftUI actually
    /// builds is counted. Replace the `LazyVStack` with a `VStack` and this
    /// fails by name with the real number.
    @MainActor
    func testTheListIsLazyAtVaultScale() throws {
        let vault = StudioSoundsVaultModel()
        vault.adoptForTesting(vaultScaleFixture(14_000))
        XCTAssertEqual(vault.visible.count, 14_000, "the fixture did not reach the model")

        let model = StudioViewModel(engine: StudioMockEngine())
        StudioSoundRowRenderCounter.shared.arm()
        defer { StudioSoundRowRenderCounter.shared.disarm() }

        _ = renderedSize(
            StudioSoundsBrowser(model: model, injected: vault)
                .frame(width: StudioTokens.browserWidth, height: 600))

        let built = StudioSoundRowRenderCounter.shared.count
        XCTAssertGreaterThan(
            built, 0,
            "no row was built at all, so this test is measuring nothing — the list is not rendering")
        XCTAssertLessThan(
            built, 400,
            "SwiftUI built \(built) of 14,000 sound rows for a 600 pt tall list. The list is NOT lazy; "
            + "at vault scale that is the app stopping.")
    }

    /// The `BrigadeConfig.isConfigured` shape, guarded directly: no view-body
    /// evaluation may filter the vault. Move the filter into the body and this
    /// fails with the count of times it ran.
    @MainActor
    func testRenderingTheBrowserNeverFiltersTheVault() throws {
        let vault = StudioSoundsVaultModel()
        vault.adoptForTesting(vaultScaleFixture(14_000))
        let model = StudioViewModel(engine: StudioMockEngine())

        StudioSoundsSearch.resetFilterCallCount()
        for _ in 0..<10 {
            _ = renderedSize(
                StudioSoundsBrowser(model: model, injected: vault)
                    .frame(width: StudioTokens.browserWidth, height: 600))
        }

        XCTAssertEqual(
            StudioSoundsSearch.filterCallCount, 0,
            "rendering the browser ten times filtered 14,000 assets "
            + "\(StudioSoundsSearch.filterCallCount) time(s). Filtering belongs in the model, when the "
            + "query changes — not in a body that re-evaluates at display rate.")
    }

    /// The same guard for the far more expensive half. A directory walk started
    /// from a view body is the exact failure this whole file is shaped around.
    ///
    /// THE AWAIT AT THE END IS THE TEST. The first version of this asserted
    /// immediately after rendering and a mutation SURVIVED it: a `rescan()`
    /// planted in the body starts its walk inside a `Task`, so nothing had run
    /// yet when the assertion fired and the count was still 0 — a browser
    /// spawning ten concurrent 14,000-file walks, with a green suite. Draining
    /// the pending work before asserting is what makes this measure the
    /// artifact (a scan happened) instead of the timing.
    @MainActor
    func testRenderingTheBrowserNeverTouchesTheFilesystem() async throws {
        let vault = StudioSoundsVaultModel()
        vault.adoptForTesting(vaultScaleFixture(2_000))
        let model = StudioViewModel(engine: StudioMockEngine())

        StudioVaultScanner.resetScanCallCount()
        for _ in 0..<10 {
            _ = renderedSize(
                StudioSoundsBrowser(model: model, injected: vault)
                    .frame(width: StudioTokens.browserWidth, height: 600))
        }
        // Let anything a body scheduled actually run.
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        XCTAssertEqual(
            StudioVaultScanner.scanCallCount, 0,
            "rendering the browser started \(StudioVaultScanner.scanCallCount) filesystem walk(s). "
            + "Ten renders is ten concurrent walks of the whole vault.")
    }

    // MARK: - 6. Audition makes sound, and changes nothing

    /// Signal, measured, against numbers that are derived rather than observed.
    ///
    /// The source is a MONO 0.5-amplitude sine. `mainMixerNode` fans mono out
    /// to stereo with an equal-power pan law, which is −3 dB per channel — a
    /// factor of 1/√2. So the peak that comes out is 0.5/√2 = 0.354, and the
    /// RMS of a sine is its peak over √2 again: 0.354/√2 = 0.250. Both of those
    /// fall out of the mixer's documented behaviour, and the first run of this
    /// test is what proved the audition graph really is a mixer and not a
    /// passthrough.
    ///
    /// Silence through the same graph is asserted too, because a test that only
    /// checked the tone would pass a probe that returned a constant — which is
    /// the `abs(sin(t))` meter this repo actually shipped.
    @MainActor
    func testAuditionProducesRealAudio() throws {
        let tone = try writeTone(amplitude: 0.5)
        let quiet = try writeTone(amplitude: 0)
        defer {
            try? FileManager.default.removeItem(at: tone)
            try? FileManager.default.removeItem(at: quiet)
        }

        let player = StudioSoundAuditionPlayer(audible: false)
        StudioSoundsBrowserActions.audition(
            asset("Tone", path: tone.path), player: player)
        XCTAssertNil(player.failure, "the audition refused the file: \(player.failure ?? "")")
        let heard = try player.probe(seconds: 0.4)

        XCTAssertGreaterThan(heard.frames, 15_000, "almost nothing was rendered")
        XCTAssertEqual(heard.peak, 0.354, accuracy: 0.01,
                       "a 0.5-amplitude mono tone through an equal-power pan should peak at "
                       + "0.5/√2 = 0.354; got \(heard.peak)")
        XCTAssertEqual(heard.rms, 0.250, accuracy: 0.01,
                       "the RMS of that sine should be its peak over √2 = 0.250; got \(heard.rms)")

        // The discriminator: the same path, a silent file, and the numbers must
        // collapse. Without this the assertions above would pass a probe that
        // returned a constant.
        let silentPlayer = StudioSoundAuditionPlayer(audible: false)
        StudioSoundsBrowserActions.audition(
            asset("Quiet", path: quiet.path), player: silentPlayer)
        let nothing = try silentPlayer.probe(seconds: 0.4)
        XCTAssertLessThan(nothing.peak, 0.001,
                          "a silent file measured \(nothing.peak); the probe is not measuring the audio")
    }

    /// Auditioning is not editing. Forty snares auditioned is zero undo steps.
    @MainActor
    func testAuditionJournalsNothingAndCreatesNoTrack() async throws {
        let tone = try writeTone(amplitude: 0.5, seconds: 0.2)
        defer { try? FileManager.default.removeItem(at: tone) }

        let engine = StudioMockEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        defer { model.stopPolling() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let tracksBefore = try XCTUnwrap(model.snapshot?.tracks.count)
        let clipsBefore = try XCTUnwrap(model.snapshot?.tracks.reduce(0) { $0 + $1.clips.count })
        let journalBefore = await engine.journal.count

        let player = StudioSoundAuditionPlayer(audible: false)
        for i in 0..<10 {
            StudioSoundsBrowserActions.audition(
                asset("Snare \(i)", path: tone.path), player: player)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let journalAfter = await engine.journal.count
        XCTAssertEqual(
            journalAfter, journalBefore,
            "ten auditions put \(journalAfter - journalBefore) command(s) in the journal. "
            + "Previewing is not editing; every one of those would be an undo step between the user "
            + "and their last real change.")
        XCTAssertEqual(model.snapshot?.tracks.count, tracksBefore, "an audition created a track")
        XCTAssertEqual(
            model.snapshot?.tracks.reduce(0) { $0 + $1.clips.count }, clipsBefore,
            "an audition created a clip")
    }

    /// Clicking the sounding row again stops it, rather than restarting it.
    @MainActor
    func testClickingTheSoundingRowAgainStopsIt() throws {
        let tone = try writeTone(amplitude: 0.5, seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: tone) }
        let player = StudioSoundAuditionPlayer(audible: false)
        let one = asset("Tone", path: tone.path)

        StudioSoundsBrowserActions.audition(one, player: player)
        XCTAssertEqual(player.auditioningID, one.id)
        StudioSoundsBrowserActions.audition(one, player: player)
        XCTAssertNil(player.auditioningID, "a second click did not stop it")
    }

    // MARK: - 7. One drag, one command, one undo step

    @MainActor
    func testDroppingASoundIsExactlyOneJournaledCommand() async throws {
        let engine = StudioMockEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        defer { model.stopPolling() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let track = try XCTUnwrap(model.snapshot?.tracks.first)
        let clipsBefore = track.clips.count
        let tracksBefore = try XCTUnwrap(model.snapshot?.tracks.count)
        let mark = await engine.journal.count

        model.placeSound(path: "/tmp/vault/Boom Bap/Kick 03.wav",
                         onTrack: track.id, atTicks: 3_840)
        try await Task.sleep(nanoseconds: 400_000_000)

        let added = await engine.journal.dropFirst(mark).map(\.catalogName)
        XCTAssertEqual(
            added, ["import.audio"],
            "one drag produced \(added.count) journaled command(s): \(added). A dropped sound must be "
            + "ONE undo step, which is why this does not go through importAudio(path:) — that mints a "
            + "track first (track.add + import.audio).")

        let after = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(after.tracks.count, tracksBefore, "placing a sound on a track created another track")
        let landed = try XCTUnwrap(after.tracks.first(where: { $0.id == track.id }))
        XCTAssertEqual(landed.clips.count, clipsBefore + 1)
        let clip = try XCTUnwrap(landed.clips.last)
        XCTAssertEqual(clip.name, "Kick 03", "the clip is not named from the sound")
        XCTAssertEqual(clip.startTicks, 3_840, "the sound did not land where it was dropped")
        XCTAssertFalse(clip.generative, "a placed sound is not a generated clip")
    }

    /// Undo puts the project back exactly — not approximately.
    @MainActor
    func testUndoTakesTheSoundBackOffExactly() async throws {
        let engine = StudioMockEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        defer { model.stopPolling() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let before = try XCTUnwrap(model.snapshot)
        let track = try XCTUnwrap(before.tracks.first)
        let clipIDsBefore = before.tracks.flatMap { $0.clips.map(\.id) }

        model.placeSound(path: "/tmp/vault/Boom Bap/Snare 01.wav",
                         onTrack: track.id, atTicks: 1_920)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(
            model.snapshot?.tracks.flatMap { $0.clips }.count, clipIDsBefore.count + 1,
            "the sound never landed, so undoing it proves nothing")

        model.undo()
        try await Task.sleep(nanoseconds: 400_000_000)

        let after = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(
            after.tracks.flatMap { $0.clips.map(\.id) }, clipIDsBefore,
            "one Undo did not restore the project exactly: the clip set differs")
        XCTAssertEqual(after.tracks.count, before.tracks.count)
    }

    // MARK: - 8. The feed lines
    //
    // Every lane on this repo so far has shipped a survivor, and the commonest
    // shape by far is every component proven and the ONE line in the view that
    // feeds it left unasserted. These are those lines.

    /// The section exists, is offered, and its help id is registered.
    func testTheBrowserOffersASoundsSection() {
        XCTAssertTrue(
            StudioBrowserView.Section.allCases.contains(.sounds),
            "the Sounds tab is not in the browser's section list, so nothing can select it")
        XCTAssertEqual(StudioBrowserView.Section.sounds.rawValue, "Sounds")
        XCTAssertEqual(StudioBrowserView.Section.sounds.helpID, "browser.sounds")
        XCTAssertNotNil(
            StudioHelpCatalog.entry("browser.sounds"),
            "the Sounds tab asks for a help id that does not exist, so hovering it says nothing")
        XCTAssertTrue(
            StudioBrowserView.Section.sounds.scrollsItself,
            "Sounds was routed back into the shared ScrollView, where its LazyVStack cannot be trusted")
        XCTAssertFalse(StudioBrowserView.Section.songs.scrollsItself)
    }

    /// THE feed line: selecting Sounds actually reaches the sounds browser.
    ///
    /// Both halves are rendered through the REAL `StudioBrowserView`, not
    /// through `StudioSoundsBrowser` directly. That distinction is the whole
    /// test, and it was learned the hard way: the first version of this rendered
    /// the sounds browser standalone, and replacing the shell's
    /// `StudioSoundsBrowser(model:)` with an `EmptyView()` left all 26 tests
    /// GREEN — a Sounds tab that opens onto nothing, with a suite saying it
    /// works. That is the half-wiring this repo keeps shipping (a palette
    /// listing 71 commands and wiring 11), and this is the assertion that
    /// catches it.
    @MainActor
    func testSelectingSoundsRendersTheSoundsBrowser() async throws {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let vault = StudioSoundsVaultModel()
        vault.adoptForTesting(vaultScaleFixture(500))

        StudioSoundRowRenderCounter.shared.arm()
        defer { StudioSoundRowRenderCounter.shared.disarm() }

        // The control: the SONGS section of the same shell, holding the same
        // vault, must build no sound rows. Without this the assertion below
        // would pass a shell that showed sounds in every section.
        _ = renderedSize(
            StudioBrowserView(model: model, initialSection: .songs, injectedVault: vault)
                .environmentObject(LibraryStore())
                .frame(height: 600))
        XCTAssertEqual(
            StudioSoundRowRenderCounter.shared.count, 0,
            "the Songs section built sound rows, so this test cannot tell the two sections apart")

        // And the real thing: Sounds selected, through the shell's own switch.
        StudioSoundRowRenderCounter.shared.arm()
        _ = renderedSize(
            StudioBrowserView(model: model, initialSection: .sounds, injectedVault: vault)
                .environmentObject(LibraryStore())
                .frame(height: 600))
        XCTAssertGreaterThan(
            StudioSoundRowRenderCounter.shared.count, 0,
            "selecting Sounds in the browser rendered NO sound rows with 500 sounds loaded: the "
            + "section is wired to nothing, so the tab opens onto an empty pane")
    }

    /// The drag payload round-trips, and is not confused with a take id.
    func testTheDragPayloadIsDistinguishableFromATakeID() {
        let one = asset("Kick 03", path: "/tmp/vault/Boom Bap/Kick 03.wav")
        let payload = StudioSoundsBrowserActions.dragPayload(for: one)
        XCTAssertEqual(
            StudioSoundsBrowserActions.soundPath(fromDrag: payload),
            "/tmp/vault/Boom Bap/Kick 03.wav")
        XCTAssertNil(
            StudioSoundsBrowserActions.soundPath(fromDrag: "take_1a2b3c"),
            "a take id was read as a sound path; the timeline would place the wrong thing")
        XCTAssertNil(StudioSoundsBrowserActions.soundPath(fromDrag: ""))
        XCTAssertNil(StudioSoundsBrowserActions.soundPath(
            fromDrag: StudioSoundsBrowserActions.dragPrefix),
            "an empty path behind the prefix must not be treated as a sound")
    }

    /// The other end of that wire. Asserted by reading the timeline's source,
    /// which is the only way to see a `.onDrop` branch without a window — and
    /// it is the branch that decides whether one drag is one undo step or two.
    func testTheTimelineRoutesASoundDragToPlaceSoundAndNotToImport() throws {
        let text = try String(
            contentsOf: Self.sourcesDirectory
                .appendingPathComponent("Studio/StudioTimelineView.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            text.contains("StudioSoundsBrowserActions.soundPath(fromDrag:"),
            "the timeline no longer recognises a sound drag; a dropped sound would fall through to "
            + "the take path and silently do nothing")
        XCTAssertTrue(
            text.contains("model.placeSound(path:"),
            "the timeline recognises a sound drag but does not place it")
        XCTAssertTrue(
            text.contains("model.dropTake(takeID:"),
            "the take drop was lost while the sound drop was added")
    }

    /// The row's two gestures are the ones that were tested.
    func testTheRowIsWiredToAuditionAndToTheDragPayload() throws {
        let text = try String(
            contentsOf: Self.sourcesDirectory
                .appendingPathComponent("Studio/StudioSoundsBrowser.swift"),
            encoding: .utf8)
        XCTAssertTrue(text.contains("StudioSoundsBrowserActions.audition("),
                      "the row's click no longer goes through the tested audition path")
        XCTAssertTrue(text.contains("StudioSoundsBrowserActions.dragPayload(for:"),
                      "the row's drag no longer vends the tested payload")
        XCTAssertTrue(text.contains("LazyVStack"),
                      "the sounds list stopped being lazy")
        // The whole filtered set, uncapped. The Songs list next door caps at 60
        // because it is not lazy; a capped SOUNDS list would mean 13,911 of the
        // vault unreachable by scrolling, which is the feature failing quietly.
        XCTAssertTrue(
            text.contains("ForEach(live.visible)"),
            "the sounds list no longer iterates the whole filtered set — a cap here puts most of the "
            + "vault out of reach")
        // The macOS trap: a horizontal ScrollView silently eats Button clicks,
        // and a row of filter chips in a 172 pt rail is what tempts one.
        XCTAssertFalse(text.contains(".horizontal)"),
                       "a horizontal ScrollView appeared near the filter chips; macOS will eat their clicks")
    }

    /// The filter chips fit the rail they live in.
    ///
    /// Two rows of chips in a 172 pt column is a real risk of overflow, and
    /// overflow here is not cosmetic: the browser sits against a divider, so a
    /// chip that runs past the edge is a control a person cannot click. Measured
    /// at the view's NATURAL width (no width frame), which is the width the
    /// chips actually demand.
    @MainActor
    func testTheFilterChipsFitTheBrowserRail() throws {
        let vault = StudioSoundsVaultModel()
        vault.adoptForTesting(vaultScaleFixture(50))
        let model = StudioViewModel(engine: StudioMockEngine())

        let size = try XCTUnwrap(renderedSize(
            StudioSoundsBrowser(model: model, injected: vault).frame(height: 400)))

        // StudioBrowserView pads the rail by 10 on each side.
        let available = StudioTokens.browserWidth - 20
        XCTAssertLessThanOrEqual(
            size.width, available,
            "the sounds section wants \(size.width) pt but the browser rail gives it "
            + "\(available) pt. Whatever runs past the edge is a control nobody can click.")
    }

    // MARK: - 9. The empty state

    /// Four causes, four sentences. "Nothing here" is a dead end; the whole
    /// point of an empty state is that it names the next step.
    @MainActor
    func testEachEmptyCauseSaysSomethingDifferent() {
        let idle = StudioSoundsVaultModel(root: URL(fileURLWithPath: "/tmp/v"))
        let idleMessage = try? XCTUnwrap(idle.emptyMessage)

        let missing = StudioSoundsVaultModel(root: URL(fileURLWithPath: "/tmp/v"))
        missing.adopt(StudioVaultScanResult(
            root: URL(fileURLWithPath: "/tmp/v"), assets: [], indexed: 0,
            rootMissing: true, truncatedAt: nil, ranOnMainThread: false, duration: 0))

        let emptyFolder = StudioSoundsVaultModel()
        emptyFolder.adoptForTesting([])

        let noMatch = StudioSoundsVaultModel()
        noMatch.adoptForTesting([asset("Kick")])
        noMatch.filter.query = "zzzz"

        let unknownTempo = StudioSoundsVaultModel()
        unknownTempo.adoptForTesting([asset("Break", kind: .loop)])
        unknownTempo.filter.inTempo = true

        let messages = [idleMessage ?? "", missing.emptyMessage ?? "",
                        emptyFolder.emptyMessage ?? "", noMatch.emptyMessage ?? "",
                        unknownTempo.emptyMessage ?? ""]
        XCTAssertEqual(Set(messages).count, 5,
                       "two different reasons for an empty list say the same thing: \(messages)")
        for message in messages {
            XCTAssertFalse(message.isEmpty)
        }

        XCTAssertTrue(
            missing.emptyMessage?.contains(StudioSoundsVaultLocation.storefront) == true,
            "the no-folder empty state does not say where sounds come from")
        XCTAssertTrue(
            unknownTempo.emptyMessage?.contains("tempo") == true,
            "an in-tempo filter that hid everything for MISSING tempo did not say so, which reads as "
            + "'the vault has nothing' rather than 'the vault has no tempo data'")
        // And the other direction: a model with rows to show has NO empty
        // message, so the list is never captioned "nothing here" above content.
        let listed = StudioSoundsVaultModel()
        listed.adoptForTesting([asset("Kick")])
        XCTAssertNil(listed.emptyMessage,
                     "an empty-state message was shown above a list that has rows in it")
    }

    /// The summary line above the list tells the truth about what is on screen,
    /// including the uncomfortable half: when nothing in the folder carries
    /// tempo, it SAYS "no tempo data" rather than letting a person conclude the
    /// filters are broken. That is the state the whole vault is in today.
    @MainActor
    func testTheSummaryLineSaysHowMuchOfTheVaultIsShowing() {
        let vault = StudioSoundsVaultModel()
        vault.adoptForTesting(vaultScaleFixture(14_000))
        XCTAssertEqual(vault.summary, "14000 sounds")
        vault.filter.query = "hip hop"
        XCTAssertEqual(vault.summary, "28 of 14000")

        // A folder with no sidecar index at all — the shape every vault on
        // disk has today, because no export writes one yet.
        let bare = StudioSoundsVaultModel()
        bare.adoptForTesting([asset("Kick"), asset("Snare")])
        XCTAssertEqual(bare.summary, "2 sounds · no tempo data")
    }

    // MARK: - Helpers

    /// `Sources/`, found from this file rather than from a bundle, the same way
    /// `StudioHelpTests` finds it.
    ///
    /// No longer private: `StudioSoundsDownloaderTests` asserts the feed lines
    /// of the SAME view and must read the same file. Sharing one accessor
    /// rather than copying the path walk is deliberate — a coverage test that
    /// carries its own copy of the thing it polices leaves both green when the
    /// real one is deleted, and this repo has shipped exactly that.
    static let sourcesDirectory: URL = {
        URL(fileURLWithPath: #filePath)          // …/Tests/StudioSoundsVaultTests.swift
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/swift
            .appendingPathComponent("Sources")
    }()
}
