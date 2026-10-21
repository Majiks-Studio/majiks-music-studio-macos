import XCTest
import SwiftUI
@testable import MajiksMusicStudio

/// THE FOUR THINGS THE APP DID WITHOUT SAYING SO.
///
/// A previous lane fixed the first instance — a played key creating a track —
/// and left four more standing to keep its diff tight. This is that follow-up.
/// Each of them CREATES SOMETHING and reported either nothing or a number:
///
///  1. Add a Layer (Shift+R) makes a TRACK and said "Added a layer."
///  2. Loading a sound makes a Sampler or a Drum Rack DEVICE and said only
///     that the sound was loaded.
///  3. `performImport(newTrack:)` makes a TRACK and said "Imported <file>".
///  4. A stem import makes one TRACK PER FILE and reported a COUNT.
///
/// The shape of every test below is the same, and the SECOND assertion in each
/// is the one that matters: the app must say so when it did it, and must stay
/// quiet when the USER did the same thing. A message wired to fire always is
/// the same defect as no message at all, and a fixture that ships with the
/// expected thing already in it will pass a badly-written version of the first
/// assertion without the code under test running at all.
@MainActor
final class StudioSaysWhatItMadeTests: XCTestCase {

    // MARK: Helpers

    private func track(_ name: String, origin: StudioTrackOrigin? = nil) -> StudioTrackSnapshot {
        var t = StudioTrackSnapshot(
            id: UUID(), name: name, kind: .other, clips: [], takeLane: nil, devices: [])
        t.origin = origin
        return t
    }

    private func bootedModel(_ engine: StudioMockEngine) async -> StudioViewModel {
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        for _ in 0..<80 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return model
    }

    private func waitFor(_ seconds: Double = 2.0, _ predicate: () -> Bool) async {
        let steps = Int(seconds / 0.05)
        for _ in 0..<steps {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Every origin has a sentence, and only the app-made ones do

    /// Three cases, three distinct lines, and `nil` for a track the user made.
    ///
    /// The expectations are HARDCODED literals rather than `origin.note`, which
    /// would be a restatement of the property under test and would pass against
    /// an implementation that returned the same string for all three.
    func testEveryOriginExplainsItselfDifferentlyAndAHandMadeTrackDoesNot() {
        XCTAssertEqual(track("Instrument 1", origin: .played).originNote,
                       "Made when you played")
        XCTAssertEqual(track("Layer", origin: .layered).originNote,
                       "Made for a layer")
        XCTAssertEqual(track("drums", origin: .imported).originNote,
                       "Made when you imported")

        // `nil`, not an empty string: the header must draw NO line, not a blank
        // one, on the overwhelmingly common case.
        XCTAssertNil(track("Bass").originNote,
                     "a track the user made must carry no explanation")

        // Three DIFFERENT sentences. A switch that fell through to one string
        // would satisfy every assertion above if they were written loosely.
        let notes = Set(StudioTrackOrigin.allCases.map(\.note))
        XCTAssertEqual(notes.count, StudioTrackOrigin.allCases.count,
                       "two origins share a sentence, so the header cannot tell them apart")

        // And each is a fact about the past, not an instruction. The person is
        // playing or importing when this appears.
        for origin in StudioTrackOrigin.allCases {
            XCTAssertTrue(origin.note.hasPrefix("Made "),
                          "\(origin.rawValue) reads as something other than a fact: \(origin.note)")
        }
    }

    /// The glyph and the help key come off the SAME case as the sentence, so a
    /// fourth origin cannot ship with two of the three filled in.
    func testEveryOriginCarriesItsOwnGlyphAndItsOwnHelp() {
        let symbols = Set(StudioTrackOrigin.allCases.map(\.symbolName))
        XCTAssertEqual(symbols.count, StudioTrackOrigin.allCases.count,
                       "two origins draw the same glyph, so the lines are indistinguishable at a glance")
        for origin in StudioTrackOrigin.allCases {
            XCTAssertEqual(origin.helpKey, "trackHeader.origin.\(origin.rawValue)")
            XCTAssertNotNil(StudioHelpCatalog.entry(origin.helpKey),
                            "\(origin.rawValue) has no help entry, so hovering its line shows nothing")
        }
    }

    // MARK: - The header draws each of them, and draws nothing without one

    private struct Raster {
        let width: Int, height: Int, bytes: [UInt8]
        /// Total absolute channel difference against `other` inside a band.
        func mass(against other: Raster, rows: Range<Int>) -> Int {
            guard width == other.width, height == other.height else { return .max }
            var total = 0
            for y in rows where y < height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    // Channels 1..3 only. The buffer is `premultipliedFirst`,
                    // so channel 0 is ALPHA — uniformly opaque here, but Core
                    // Graphics leaves a unit or two of dither in it that has
                    // nothing to do with what is drawn. Including it put a
                    // permanent residue of 1-5 into a comparison that should
                    // read exactly zero, which would have had to be paid for
                    // with a tolerance. `StudioTrackIdentityTests.Raster` skips
                    // it for the same reason and reads 0.
                    for c in 1..<4 { total += abs(Int(bytes[i + c]) - Int(other.bytes[i + c])) }
                }
            }
            return total
        }
    }

    private func raster(_ model: StudioViewModel, _ t: StudioTrackSnapshot) throws -> Raster {
        let view = StudioTrackHeaderRow(
            model: model, track: t, height: StudioTokens.trackHeightDefault)
            .frame(width: StudioTokens.trackHeaderWidth, height: StudioTokens.trackHeightDefault)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.cgImage, "the header row did not rasterize at all")
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Raster(width: cg.width, height: cg.height, bytes: bytes)
    }

    /// The band the explanation is drawn in: below the second control row,
    /// inside the 90 pt header.
    private var originBand: Range<Int> { 46..<Int(StudioTokens.trackHeightDefault) }
    private var firstRow: Range<Int> { 5..<24 }

    /// INK, where a property assertion cannot see. A `Text` bound to a constant
    /// or an `if` that never fires both pass `originNote` and fail here — and
    /// the three cases must differ from EACH OTHER on screen, not only from the
    /// blank one, which is what catches a view that renders one hardcoded line
    /// for every origin.
    func testTheHeaderDrawsADifferentLineForEachOriginAndNothingWithout() async throws {
        let model = await bootedModel(StudioMockEngine())
        defer { model.stopPolling() }

        // ONE base track, copied — not four separately-constructed ones. The
        // header draws things keyed to the track's identity, so two tracks with
        // different ids differ above the band for reasons that have nothing to
        // do with the origin, and a comparison between them would carry a
        // permanent few units of noise that the assertion would then have to be
        // loosened to tolerate. One field different, and only one.
        let base = track("Bass")
        let plain = try raster(model, base)

        // ⚠️ THE RENDERER'S OWN FLOOR, MEASURED, NOT ASSUMED.
        //
        // `ImageRenderer` is not bit-deterministic: rasterizing the SAME view
        // twice in a row differs by a few channel-units in this band. So a
        // literal `== 0` here is not "the row above did not move", it is "the
        // row above did not move AND the renderer happened to round the same
        // way twice", and the second half is luck. Measured first, compared
        // against, and the margin is stated rather than tuned until green.
        //
        // For scale: the first draft of the layer and import lines really did
        // move this row, and it measured 253,229 — four orders of magnitude
        // above this floor. The bound below is nowhere near tight enough to
        // flake and nowhere near loose enough to miss a moved row.
        let renderNoise = plain.mass(against: try raster(model, base), rows: firstRow)
        XCTAssertLessThan(renderNoise, 64,
                          "the renderer disagrees with itself by \(renderNoise) on identical input, which is too much for this test to say anything")

        var drawn: [StudioTrackOrigin: Raster] = [:]
        for origin in StudioTrackOrigin.allCases {
            var explained = base
            explained.origin = origin
            let r = try raster(model, explained)
            XCTAssertGreaterThan(
                r.mass(against: plain, rows: originBand), 2_000,
                "a \(origin.rawValue) track's header is indistinguishable from one the user made")
            // A NEW LINE, not a rearrangement: the name and the controls above
            // it are untouched, so the explanation is not paid for out of the
            // track name's width — which is how the "+ Instrument" bug once
            // truncated four stem names to two letters each.
            XCTAssertLessThanOrEqual(
                r.mass(against: plain, rows: firstRow), max(renderNoise, 8),
                "adding the \(origin.rawValue) explanation moved the row above it (floor \(renderNoise))")
            drawn[origin] = r
        }

        for a in StudioTrackOrigin.allCases {
            for b in StudioTrackOrigin.allCases where b.rawValue > a.rawValue {
                XCTAssertGreaterThan(
                    try XCTUnwrap(drawn[a]).mass(against: try XCTUnwrap(drawn[b]), rows: originBand),
                    500,
                    "the \(a.rawValue) and \(b.rawValue) headers draw the same pixels, so the line does not depend on the origin")
            }
        }
    }

    // MARK: - What the app SAYS at the moment it happens

    /// Item 4's human half, and the anti-nagging rule.
    ///
    /// A stem import makes several tracks in ONE adoption. Four toasts for one
    /// gesture is worse than none — they queue, the last is the only one still
    /// on screen, and the three underneath were pure interruption. ONE sentence
    /// that NAMES the rows is the same information in one glance.
    func testSeveralTracksArrivingAtOnceProduceOneToastThatNamesThem() async throws {
        let engine = StudioMockEngine()
        let model = await bootedModel(engine)
        defer { model.stopPolling() }
        let tracks = try XCTUnwrap(model.snapshot?.tracks)
        XCTAssertGreaterThanOrEqual(tracks.count, 3, "need three tracks to tell aggregation from repetition")

        // THE USER-MADE CASE FIRST, constructed AFTER boot so it travels the
        // same adoption path as the real case below with one field different.
        // Asserted first, so a message wired to fire always fails HERE rather
        // than being mistaken for the real one.
        ToastManager.shared.currentToast = nil
        _ = await engine.send(.trackAdd(trackID: UUID().uuidString, name: "By hand", index: 0))
        await waitFor { model.snapshot?.tracks.contains { $0.name == "By hand" } == true }
        XCTAssertTrue(model.snapshot?.tracks.contains { $0.name == "By hand" } == true,
                      "the hand-made track never arrived, so the quiet below proves nothing")
        XCTAssertNil(ToastManager.shared.currentToast,
                     "the app announced a track the user made themselves")

        // Now TWO the app made, in a SINGLE adoption — which is the arrival
        // shape a stem import actually has. Setting them one at a time would
        // bump the mock's revision twice, the poll would see two snapshots, and
        // two toasts would be correct behaviour rather than the bug: the test
        // would then be measuring the mock's timing instead of the app's
        // aggregation.
        await engine.setTrackOrigins([tracks[1].id, tracks[2].id], .imported)
        await waitFor { ToastManager.shared.currentToast != nil }
        let said = try XCTUnwrap(ToastManager.shared.currentToast?.message,
                                 "the app made two tracks and never mentioned it")
        XCTAssertTrue(said.contains(tracks[1].name), "the message must name the first track: \(said)")
        XCTAssertTrue(said.contains(tracks[2].name), "the message must name the second track: \(said)")
        XCTAssertTrue(said.lowercased().contains("cmd-z"),
                      "the message must say how to take them back: \(said)")

        // ONE sentence, not two stacked. Nothing else arrived behind it.
        ToastManager.shared.currentToast = nil
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNil(ToastManager.shared.currentToast,
                     "a second toast was queued behind the first for one gesture")
    }

    /// Item 1's human half. The layer announcement must say TRACK — the word
    /// that never appeared anywhere in "Added a layer."
    func testTheLayerAnnouncementSaysATrackWasMadeAndNamesIt() {
        let said = StudioTrackOrigin.layered.announcement(namingTracks: ["Layer"])
        XCTAssertTrue(said.contains("Layer"), "the layer announcement does not name the track: \(said)")
        XCTAssertTrue(said.lowercased().contains("track"),
                      "the whole defect was that the word 'track' never appeared: \(said)")
        XCTAssertTrue(said.lowercased().contains("cmd-z"), said)
    }

    /// The cap. A toast is read in the two seconds before it fades, and a dozen
    /// names in it is the same as no names at all.
    func testTheNameListNamesAFewAndCountsTheRest() {
        XCTAssertEqual(StudioTrackOrigin.list(["A"]), "A")
        XCTAssertEqual(StudioTrackOrigin.list(["A", "B"]), "A and B")
        XCTAssertEqual(StudioTrackOrigin.list(["A", "B", "C"]), "A, B and C")
        XCTAssertEqual(StudioTrackOrigin.list(["A", "B", "C", "D", "E"]), "A, B, C and 2 more")
        // Never an empty fragment dropped into the middle of a sentence.
        XCTAssertFalse(StudioTrackOrigin.list([]).isEmpty)
    }

    // MARK: - Item 2: loading a sound CREATES AN INSTRUMENT

    /// `bind` picks its sentence off `outcome.createdDevice` — the ENGINE's
    /// answer to whether it journaled `device.add` — and not off
    /// `request.deviceID == nil`, which is only what the app asked for.
    ///
    /// The mock's first track has no device, so the first load creates one; the
    /// SECOND load names that device and must not claim to have created
    /// anything. That second case is what catches a message wired to fire
    /// always.
    func testLoadingASoundSaysAnInstrumentWasMadeAndDoesNotSayItTwice() async throws {
        let engine = StudioMockEngine()
        let model = await bootedModel(engine)
        defer { model.stopPolling() }
        let trackID = try XCTUnwrap(model.snapshot?.tracks.first?.id)
        let empty = try XCTUnwrap(model.snapshot?.tracks.first)
        XCTAssertTrue(empty.devices.isEmpty, "precondition: the track has no instrument yet")

        ToastManager.shared.currentToast = nil
        await model.loadSamplerSound(trackID: trackID, path: "/tmp/kick.wav").value
        let creating = try XCTUnwrap(ToastManager.shared.currentToast?.message,
                                     "loading a sound said nothing at all")
        XCTAssertTrue(creating.contains("Sampler"),
                      "an instrument was created on the track and the word never appeared: \(creating)")
        XCTAssertTrue(creating.contains("kick.wav"), creating)
        XCTAssertTrue(creating.contains(empty.name),
                      "the message must name the track it changed: \(creating)")

        // NOW the device exists. Replacing the sound in a zone of an existing
        // instrument creates nothing, and must not say it did.
        let withDevice = try XCTUnwrap(model.snapshot?.tracks.first { $0.id == trackID })
        let deviceID = try XCTUnwrap(withDevice.devices.first?.id,
                                     "the load did not actually create a device, so the quiet below proves nothing")
        let zone = try XCTUnwrap(withDevice.devices.first?.zones.first)
        ToastManager.shared.currentToast = nil
        await model.replaceSamplerSound(trackID: trackID, deviceID: deviceID,
                                        zone: zone, path: "/tmp/snare.wav").value
        let replacing = try XCTUnwrap(ToastManager.shared.currentToast?.message)
        XCTAssertFalse(replacing.contains("Sampler"),
                       "swapping a sound claimed to have created an instrument: \(replacing)")
    }

    /// ⚠️ THE SURVIVOR THIS TEST EXISTS FOR.
    ///
    /// The end-to-end tests above cannot fail when the message is wired to
    /// ALWAYS claim an instrument was created. A mutation that did exactly that
    /// passed the entire suite, because the only two gestures that supply a
    /// creating-sentence both always create (the engine refuses a second
    /// instrument on a track, so `createdDevice == false` is unreachable from
    /// them), and every gesture that does hit `false` supplies no creating
    /// sentence, so both branches produce the same string.
    ///
    /// The decision itself is the only thing that can be asserted, so it is.
    /// Both directions, and the `nil` fallback that a future gesture would hit.
    func testTheInstrumentSentenceIsChosenByWhatTheEngineDidNotByWhatWasAsked() {
        XCTAssertEqual(
            StudioViewModel.bindMessage(createdDevice: true, success: "loaded", successCreating: "made one"),
            "made one",
            "the engine created an instrument and the message did not say so")
        XCTAssertEqual(
            StudioViewModel.bindMessage(createdDevice: false, success: "loaded", successCreating: "made one"),
            "loaded",
            "nothing was created and the message claimed something was")
        XCTAssertEqual(
            StudioViewModel.bindMessage(createdDevice: true, success: "loaded", successCreating: nil),
            "loaded",
            "a gesture with no creating sentence must fall back, not show an empty toast")
    }

    /// The drum rack half of the same rule.
    func testBuildingADrumRackSaysTheInstrumentWasMade() async throws {
        let engine = StudioMockEngine()
        let model = await bootedModel(engine)
        defer { model.stopPolling() }
        let trackID = try XCTUnwrap(model.snapshot?.tracks.first?.id)

        ToastManager.shared.currentToast = nil
        await model.loadDrumRack(trackID: trackID, paths: ["/tmp/kick.wav", "/tmp/snare.wav"]).value
        let said = try XCTUnwrap(ToastManager.shared.currentToast?.message)
        XCTAssertTrue(said.contains("Drum Rack"),
                      "a Drum Rack was created and the message never says so: \(said)")
        XCTAssertTrue(said.lowercased().contains("cmd-z"), said)
    }

    // MARK: - Item 3: importing a file onto a NEW track

    /// `importStemSession` has said "on their own tracks" for as long as it has
    /// existed; the single-file path never got the same courtesy and reported
    /// "Imported <file>" while a row appeared in the arrangement.
    ///
    /// Both directions are asserted, and the overdub one is the load-bearing
    /// half: `newTrack: false` must not claim to have made anything.
    func testImportingOntoANewTrackSaysSoAndAnOverdubDoesNot() async throws {
        let engine = StudioMockEngine()
        let model = await bootedModel(engine)
        defer { model.stopPolling() }
        let before = try XCTUnwrap(model.snapshot?.tracks.count)

        let madeOne = await model.performImport(path: "/tmp/song.wav", newTrack: true)
        XCTAssertTrue(madeOne, "the import failed, so the message proves nothing")
        XCTAssertEqual(model.snapshot?.tracks.count, before + 1,
                       "no track was actually created, so saying one was would be the opposite bug")
        let created = try XCTUnwrap(model.importStatus)
        XCTAssertTrue(created.lowercased().contains("track"),
                      "a track was made and the word never appeared: \(created)")
        XCTAssertTrue(created.contains("song"),
                      "the message must name the track it made: \(created)")

        // THE OVERDUB. Same call, one argument different, onto a track that
        // already exists — nothing is created and nothing may be claimed.
        let onto = try XCTUnwrap(model.snapshot?.tracks.first?.id)
        let after = try XCTUnwrap(model.snapshot?.tracks.count)
        let overdubbed = await model.performImport(path: "/tmp/take2.wav",
                                                   ontoTrackID: onto, newTrack: false)
        XCTAssertTrue(overdubbed)
        XCTAssertEqual(model.snapshot?.tracks.count, after,
                       "precondition: an overdub creates no track")
        let plain = try XCTUnwrap(model.importStatus)
        XCTAssertFalse(plain.lowercased().contains("new track"),
                       "an overdub claimed to have made a track: \(plain)")
    }
}
