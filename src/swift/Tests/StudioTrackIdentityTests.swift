import XCTest
import SwiftUI
@testable import MajiksMusicStudio

// A TRACK SHOULD SAY WHAT IT IS.
//
// The bug these tests exist to keep dead, in the owner's words: "it also says
// everything is an instrument instead of vocals, track, drums, etc."
//
// He had a finished song open, split into four audio stems — Vocals, Drums,
// Bass, Other. `StudioTrackSnapshot.needsInstrument` was `devices.isEmpty`,
// which conflates "has no instrument" with "WANTS one". An audio track that
// plays a recording has no devices and never wants any, so all four stems
// offered "+ Instrument". That affordance took width in a 150 pt column, so the
// names truncated to "Vo…", "Dr…", "Ba…", "Ot…" — and the only fully legible
// word on a vocal track was "Instrument".
//
// Two halves, tested two ways. The PREDICATE is a table over track shapes, and
// the empty-track row is the regression guard: a brand-new track must still be
// able to become an instrument track, or this trades a cosmetic bug for a dead
// "add an instrument and play it" path. The HEADER is measured in rasterized
// pixels through ImageRenderer — the deterministic, no-window path
// StudioMixerDockTests, StudioPaneSizingTests and StudioMidiClipRenderTests
// already use — because a property assertion cannot see a chip wired to a
// constant, and truncation is not a property, it is ink.
@MainActor
final class StudioTrackIdentityTests: XCTestCase {

    // MARK: - Fixtures

    private func audioClip(midi: Bool = false) -> StudioClipSnapshot {
        StudioClipSnapshot(
            id: UUID(), name: "part", startTicks: 0, lengthTicks: 3840,
            generative: false, waveformSeed: 7, isMidi: midi)
    }

    private func track(
        _ name: String,
        kind: StudioStemKind = .other,
        clips: [StudioClipSnapshot] = [],
        devices: [StudioDeviceSnapshot] = []
    ) -> StudioTrackSnapshot {
        StudioTrackSnapshot(
            id: UUID(), name: name, kind: kind, clips: clips, takeLane: nil, devices: devices)
    }

    // MARK: - 1. The predicate
    //
    // Every expectation below is a HARDCODED literal, never a re-derivation of
    // the property under test. `#expect(t.needsInstrument == t.devices.isEmpty)`
    // would be a restatement of the bug.

    func testWhichTrackShapesOfferAnInstrument() {
        // (description, track, expected role, expected canHost, expected needs)
        let cases: [(String, StudioTrackSnapshot, StudioTrackRole, Bool, Bool)] = [
            ("an audio-clip track — a recording, nothing to play",
             track("Vocals", kind: .vocals, clips: [audioClip()]),
             .audio, false, false),

            ("a MIDI track with a synth on it",
             track("Keys", clips: [audioClip(midi: true)],
                   devices: [StudioDeviceSnapshot(id: "d1", kind: "synth")]),
             .instrument, true, false),

            // THE REGRESSION GUARD. See the named test below as well; this row
            // is here so the table itself cannot drift away from it.
            ("a brand-new empty track",
             track("Track 5"),
             .empty, true, true),

            ("a MIDI track whose instrument was removed — the way back",
             track("Keys", clips: [audioClip(midi: true)]),
             .instrument, true, true),

            ("an empty track that already has a synth",
             track("Keys", devices: [StudioDeviceSnapshot(id: "d1", kind: "synth")]),
             .instrument, true, false),

            ("a stem track: vocals",
             track("Vocals", kind: .vocals, clips: [audioClip()]), .audio, false, false),
            ("a stem track: drums",
             track("Drums", kind: .drums, clips: [audioClip()]), .audio, false, false),
            ("a stem track: bass",
             track("Bass", kind: .bass, clips: [audioClip()]), .audio, false, false),
            ("a stem track: other",
             track("Other", kind: .other, clips: [audioClip()]), .audio, false, false),
            ("a whole imported recording",
             track("VO (imported)", kind: .imported, clips: [audioClip()]), .audio, false, false),

            // An audio track the engine would let you stack a device onto.
            // Nothing in this app creates one; a project written by an agent
            // can. It is still an audio track — the recording is what it is for.
            ("an audio track with a device stacked on it",
             track("Vocals", kind: .vocals, clips: [audioClip()],
                   devices: [StudioDeviceSnapshot(id: "d1", kind: "synth")]),
             .audio, false, false),
        ]

        for (what, t, role, canHost, needs) in cases {
            XCTAssertEqual(t.role, role, "role of \(what)")
            XCTAssertEqual(t.canHostInstrument, canHost, "canHostInstrument for \(what)")
            XCTAssertEqual(t.needsInstrument, needs, "needsInstrument for \(what)")
        }
    }

    /// THE REGRESSION GUARD, named so a future reader cannot mistake it for a
    /// detail. Gating the instrument offer must never close the door on a track
    /// with nothing on it: "add a track, add an instrument, play it" is the
    /// whole point of the piano roll and was itself a hard-won fix.
    func testABrandNewEmptyTrackCanStillBecomeAnInstrumentTrack() {
        let fresh = track("Instrument 1")
        XCTAssertTrue(fresh.clips.isEmpty)
        XCTAssertTrue(fresh.devices.isEmpty)
        XCTAssertEqual(fresh.role, .empty)
        XCTAssertTrue(
            fresh.canHostInstrument,
            "a track with nothing on it must be allowed to become an instrument track")
        XCTAssertTrue(
            fresh.needsInstrument,
            "the '+ Instrument' affordance must still be offered on a new track, or the "
            + "only path from an empty project to a playable instrument is gone")
    }

    /// The other direction of the same door: an audio track must be refused,
    /// and refused because of what it CARRIES rather than what it is called.
    /// `kind` is a guess made from the track's name (`RealStudioEngine.stemKind`)
    /// — the engine model has no track kind — so a rename must not change what
    /// a track is allowed to do.
    func testRenamingATrackDoesNotChangeWhatItCanDo() {
        let named = track("Bass", kind: .bass, clips: [audioClip()])
        let renamed = track("Low End", kind: .other, clips: [audioClip()])
        XCTAssertFalse(named.needsInstrument)
        XCTAssertFalse(
            renamed.needsInstrument,
            "the same audio track under a different name must still be an audio track")

        let emptyCalledBass = track("Bass", kind: .bass)
        XCTAssertTrue(
            emptyCalledBass.needsInstrument,
            "a track is not barred from taking an instrument because someone typed 'Bass'")
    }

    // MARK: - 2. The words

    func testEachKindHasItsOwnWord() {
        XCTAssertEqual(StudioStemKind.vocals.label, "Vocals")
        XCTAssertEqual(StudioStemKind.drums.label, "Drums")
        XCTAssertEqual(StudioStemKind.bass.label, "Bass")
        XCTAssertEqual(StudioStemKind.other.label, "Other")
        // Not "Imported": the badge says what the track HOLDS. Provenance is the
        // inspector's lineage panel, and it says it in full sentences there.
        XCTAssertEqual(StudioStemKind.imported.label, "Audio")

        XCTAssertEqual(Set(StudioStemKind.allCases.map(\.label)).count, 5,
                       "two kinds share a word, so the badge cannot tell them apart")
    }

    func testAStemIsDistinguishedFromAWholeRecording() {
        XCTAssertTrue(StudioStemKind.vocals.isStem)
        XCTAssertTrue(StudioStemKind.drums.isStem)
        XCTAssertTrue(StudioStemKind.bass.isStem)
        XCTAssertTrue(StudioStemKind.other.isStem)
        XCTAssertFalse(StudioStemKind.imported.isStem,
                       "an imported recording arrived whole; it is not one part of a split")
    }

    // MARK: - 3. The header, in pixels
    //
    // Everything below rasterizes the REAL `StudioTrackHeaderRow` at the
    // SHIPPED column width. There is no second drawing path for a test to be
    // green against.

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        /// Total per-channel departure from `other`, over a band of columns.
        ///
        /// MASS, not a pixel count: Core Graphics antialiasing keeps a count of
        /// "pixels that changed at all" nearly flat while the content under
        /// them becomes unreadable. Mass is coverage, which is what the eye is
        /// actually given. Identical regions contribute exactly zero, so a band
        /// containing controls that are the same in both renders costs nothing
        /// but also hides nothing.
        func mass(against other: Raster, columns: Range<Int>, rows: Range<Int>? = nil) -> Int {
            guard height == other.height else { return .max }
            var mass = 0
            for y in rows ?? 0..<height {
                for x in columns where x < width && x < other.width {
                    let i = (y * width + x) * 4
                    let j = (y * other.width + x) * 4
                    for c in 1..<4 {
                        mass += abs(Int(bytes[i + c]) - Int(other.bytes[j + c]))
                    }
                }
            }
            return mass
        }

        private func columnHasInk(_ x: Int, rows: Range<Int>, background: (UInt8, UInt8, UInt8)) -> Bool {
            for y in rows {
                let i = (y * width + x) * 4
                if abs(Int(bytes[i + 1]) - Int(background.0)) > 6
                    || abs(Int(bytes[i + 2]) - Int(background.1)) > 6
                    || abs(Int(bytes[i + 3]) - Int(background.2)) > 6 {
                    return true
                }
            }
            return false
        }

        /// The left edge of the IDENTITY SLOT: the rightmost run of ink in the
        /// header's first row, found by walking in from the trailing edge until
        /// three clear columns separate it from the track name.
        ///
        /// GEOMETRY, which a colour cannot fake. The Spacer pins the slot to the
        /// row's trailing edge, so its left edge sits at (trailing edge − its own
        /// width): a longer word starts further left. A slot wired to one
        /// constant string is the same width for every track and every left edge
        /// lands on the same column — exactly the mutation this measures. Found
        /// from the right rather than scanned from a fixed x, so the track name's
        /// own length cannot be mistaken for the slot.
        func slotLeftEdge(rows: Range<Int>, background: (UInt8, UInt8, UInt8)) -> Int? {
            var x = width - 1
            while x >= 0 && !columnHasInk(x, rows: rows, background: background) { x -= 1 }
            guard x >= 0 else { return nil }
            var gap = 0
            while x >= 0 {
                if columnHasInk(x, rows: rows, background: background) {
                    gap = 0
                } else {
                    gap += 1
                    if gap == 3 { return x + 3 }
                }
                x -= 1
            }
            return 0
        }

        func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
    }

    private func bootedModel() async throws -> StudioViewModel {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        for _ in 0..<80 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return model
    }

    private func raster(
        _ model: StudioViewModel,
        _ t: StudioTrackSnapshot,
        width: CGFloat = StudioTokens.trackHeaderWidth
    ) throws -> Raster {
        let view = StudioTrackHeaderRow(
            model: model, track: t, height: StudioTokens.trackHeightDefault)
            .frame(width: width, height: StudioTokens.trackHeightDefault)
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

    /// The band the NAME is drawn in: after the 9 pt row padding, the 8 pt stem
    /// dot and the 6 pt gap (so it starts at 23), and stopping at 86 — three
    /// points short of the widest identity badge's left edge, which is 89 for
    /// "VOCALS" at the shipped column width. Measured, not guessed: at 90 this
    /// band caught the badge's own rounded corner and reported 987 units of
    /// "truncation" on a name that was drawn perfectly.
    private let nameBand = 23..<86
    /// The FIRST row of the header — name, dot, identity slot. The second row
    /// (M / S / arm / A / volume / colour / height) begins at y = 26 and its
    /// controls run the full width, so any measurement that does not exclude it
    /// finds their ink instead of the slot's. That is exactly what made the
    /// first draft of these tests report a left edge of 92 for every track.
    private let firstRow = 5..<24
    /// Where to start hunting for the identity slot's left edge. Past any
    /// plausible stem name at 12 pt, short of the 141 pt trailing edge.


    // MARK: A Vocals header must not look like a Drums header

    func testAVocalsHeaderDrawsDifferentlyFromADrumsHeader() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        // ⚠️ THE RENDERER'S OWN FLOOR, MEASURED FIRST, AND IT IS NOT ZERO.
        //
        // `ImageRenderer` is not bit-deterministic on its FIRST rasterization in
        // a process: the same `StudioTrackHeaderRow` VALUE rendered twice differs
        // by 71 channel-units over the whole row (27 of them in the first row) on
        // the first pair, and by exactly 0 on all 59 pairs after it — a glyph
        // cache warmed once. So the `== 0` that used to stand here was not "these
        // two headers are identical", it was "these two headers are identical AND
        // something earlier in the process already paid the warm-up". The second
        // half is test ORDER, and it was load-bearing: at the tip,
        // `swift test --filter StudioTrackIdentityTests/testAVocalsHeaderDraws\
        // DifferentlyFromADrumsHeader` failed with `("71") is not equal to ("0")`.
        // Same family as the process-wide `guard::violations()` and
        // `ToastManager.shared` traps already in GATES.md: a result that depends
        // on what ran before it.
        //
        // Measured HERE, before the fixtures under test, so the warm-up is paid
        // by the calibration rather than by the measurement. For scale, the
        // signal this floor sits under is 171,750 (below) — 2,400x the floor, and
        // 1,340x the bound. Nothing this tolerates can hide a header that stopped
        // saying what its track is.
        let calibration = track("Vocals", kind: .vocals, clips: [audioClip()])
        let calibrationA = try raster(model, calibration)
        let noise = calibrationA.mass(
            against: try raster(model, calibration), columns: 0..<calibrationA.width)
        XCTAssertLessThan(
            noise, 512,
            "the renderer disagrees with itself by \(noise) on identical input, which is too much for this test to say anything")

        let vocals = try raster(model, track("Vocals", kind: .vocals, clips: [audioClip()]))
        let drums = try raster(model, track("Drums", kind: .drums, clips: [audioClip()]))

        // Calibration on the OTHER side: the same track rendered twice must be
        // identical to within the floor above, so any mass below is real content
        // and not renderer noise. Without this the threshold below is a number
        // with no meaning.
        let control = try raster(model, track("Vocals", kind: .vocals, clips: [audioClip()]))
        XCTAssertLessThanOrEqual(
            vocals.mass(against: control, columns: 0..<vocals.width), max(noise, 128),
            "two renders of the same header differ by more than the renderer's own floor (\(noise)), so this probe is not deterministic")

        let differ = vocals.mass(against: drums, columns: 0..<vocals.width)
        XCTAssertGreaterThan(
            differ, 20_000,
            "a Vocals header and a Drums header are near-identical ink (\(differ)): the row is "
            + "not showing what the track is")
    }

    /// The sharp one. Same NAME, same everything, different kind — so the only
    /// thing that can move is the identity badge. A badge wired to a constant
    /// word draws at the same width whatever the track is, and its left edge
    /// lands on the same column.
    func testTheBadgeItselfNamesTheKindRatherThanADeadWord() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        // Deliberately the same, short, kind-free name on both. Short so the
        // name leaves a clear gap before the slot (which is how the slot is
        // located), and identical so the name cannot be the thing that differs.
        let vocals = try raster(model, track("T", kind: .vocals, clips: [audioClip()]))
        let bass = try raster(model, track("T", kind: .bass, clips: [audioClip()]))

        let bg = vocals.pixel(x: vocals.width / 2, y: vocals.height / 2)
        let vocalsEdge = try XCTUnwrap(
            vocals.slotLeftEdge(rows: firstRow, background: bg),
            "nothing is drawn in the identity slot of a Vocals track")
        let bassEdge = try XCTUnwrap(
            bass.slotLeftEdge(rows: firstRow, background: bg),
            "nothing is drawn in the identity slot of a Bass track")

        // "VOCALS" is six characters, "BASS" is four; both are pushed to the
        // same trailing edge, so the wider badge starts measurably further
        // left. 8 pt is under two characters at 9 pt semibold — comfortably
        // above rounding, comfortably below the ~20 pt the two words differ by.
        XCTAssertGreaterThan(
            bassEdge - vocalsEdge, 8,
            "the VOCALS badge (left edge \(vocalsEdge)) and the BASS badge (left edge "
            + "\(bassEdge)) are the same width, so the slot is drawing one dead word rather "
            + "than each track's own")
    }

    /// The badge's COLOUR is the other half of what it says, and it is the half
    /// that carries the stem / whole-recording distinction: the four stem hues
    /// are vivid, `.imported` is the neutral grey they are vivid against.
    ///
    /// This test exists because a mutation survived without it. Pinning the
    /// badge's tint to one constant colour — so every track drew the same teal —
    /// broke NOTHING: the geometry test still saw the words change width and
    /// the word tests still read the model. The colour was drawn by production
    /// code that no assertion touched.
    ///
    /// Sampled at x = 138, inside the badge's trailing padding and clear of the
    /// last glyph, at the vertical centre of the first row. The badge is pinned
    /// to the row's trailing edge at 141 for every kind, so this point is inside
    /// all five.
    func testTheBadgeIsTintedByKindAndAnImportIsNeutral() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        // Measured off the shipped `StudioTokens.stemColor` at 20% over the
        // panel. Hardcoded, so a change to the palette is a decision someone
        // makes here rather than a number that follows silently.
        let expected: [StudioStemKind: (Int, Int, Int)] = [
            .vocals: (70, 38, 60),
            .drums: (70, 54, 34),
            .bass: (47, 38, 76),
            .other: (28, 63, 67),
            .imported: (47, 49, 60),
        ]

        var spreads: [StudioStemKind: Int] = [:]
        for kind in StudioStemKind.allCases {
            let r = try raster(model, track("T", kind: kind, clips: [audioClip()]))
            let (red, green, blue) = r.pixel(x: 138, y: 14)
            let want = try XCTUnwrap(expected[kind])
            XCTAssertEqual(Int(red), want.0, accuracy: 2, "\(kind.rawValue) badge red")
            XCTAssertEqual(Int(green), want.1, accuracy: 2, "\(kind.rawValue) badge green")
            XCTAssertEqual(Int(blue), want.2, accuracy: 2, "\(kind.rawValue) badge blue")
            let channels = [Int(red), Int(green), Int(blue)]
            spreads[kind] = channels.max()! - channels.min()!
        }

        // The distinction the owner asked about, stated as a measurement: a stem
        // badge is CHROMATIC (its channels are far apart), an import's is close
        // to grey. Measured: 32 / 36 / 38 / 39 for the four stems, 13 for the
        // import. The threshold sits in the gap and touches neither end.
        for kind in StudioStemKind.allCases where kind.isStem {
            XCTAssertGreaterThan(
                try XCTUnwrap(spreads[kind]), 22,
                "the \(kind.rawValue) badge is not tinted with its own stem colour")
        }
        XCTAssertLessThan(
            try XCTUnwrap(spreads[.imported]), 22,
            "a whole imported recording should read neutral against the four vivid stem "
            + "hues; it is being drawn as if it were one part of a split song")
    }

    // MARK: The name must be legible

    /// A stem's name must be drawn WHOLE at the shipped column width.
    ///
    /// Measured by rendering the same row into a column wide enough that
    /// truncation is impossible and comparing the name band. The name's origin
    /// is fixed by the layout (padding + dot + gap) and the Spacer absorbs the
    /// extra width, so if the shipped column draws the same glyphs at the same
    /// place the two bands are identical. If it truncated, "Vocals" became
    /// "Vo…" and the band differs.
    func testAStemNameIsNotTruncatedAtTheShippedColumnWidth() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        // The owner's actual project: a finished song split four ways.
        for (name, kind) in [("Vocals", StudioStemKind.vocals), ("Drums", .drums),
                             ("Bass", .bass), ("Other", .other)] {
            let t = track(name, kind: kind, clips: [audioClip()])
            let shipped = try raster(model, t)
            let roomy = try raster(model, t, width: 420)
            let drift = shipped.mass(against: roomy, columns: nameBand, rows: firstRow)
            // 500, not 0. CoreText does not lay a glyph run down byte-identically
            // when the width PROPOSED to it differs, even at an identical origin:
            // "Vocals" measures 16 units of sub-pixel wobble spread one or two
            // units at a time across its own glyphs, and the other three measure
            // 0. Truncating the same name registers 75,197. The floor sits 30x
            // above the noise and 150x below the signal, so it can only be
            // crossed by ink that is actually different.
            XCTAssertLessThan(
                drift, 500,
                "\"\(name)\" is drawn differently at the shipped \(Int(StudioTokens.trackHeaderWidth)) pt "
                + "column than in a column with room to spare (mass \(drift)): it is being truncated")
        }
    }

    /// The calibration that stops the test above from being vacuous.
    ///
    /// If the probe could not SEE truncation, "drift == 0" would pass for a
    /// column showing two letters and an ellipsis — which is precisely the
    /// shipped state it is supposed to fail on. So run the SAME measurement, at
    /// the SAME shipped column width, on a name long enough that truncation is
    /// certain, and require it to react.
    ///
    /// This is also the honest statement of what was NOT fixed: reclaiming the
    /// instrument affordance buys the four stem names and not much more. The
    /// column is a fixed 150 pt token and is not one of the panes
    /// `feat/resizable-panes` made draggable, so a long name still truncates.
    func testTheTruncationProbeCanActuallySeeTruncation() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        let t = track("Vocals Doubled Wide", kind: .vocals, clips: [audioClip()])
        let shipped = try raster(model, t)
        let roomy = try raster(model, t, width: 420)
        let drift = shipped.mass(against: roomy, columns: nameBand, rows: firstRow)
        XCTAssertGreaterThan(
            drift, 20_000,
            "\"Vocals Doubled Wide\" cannot fit a 150 pt column, yet the name band measured "
            + "\(drift): the probe is blind to truncation and every zero it reports is worthless")
    }

    /// The affordance is GONE from an audio track, and still there on a new one
    /// — asserted on the drawn row, not on the predicate the row consults.
    func testTheInstrumentOfferIsDrawnOnlyWhereItCanBeUsed() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        let stem = try raster(model, track("T", kind: .vocals, clips: [audioClip()]))
        let fresh = try raster(model, track("T", kind: .vocals))

        let bg = stem.pixel(x: stem.width / 2, y: stem.height / 2)
        let stemEdge = try XCTUnwrap(stem.slotLeftEdge(rows: firstRow, background: bg))
        let freshEdge = try XCTUnwrap(fresh.slotLeftEdge(rows: firstRow, background: bg))

        // "+ Instrument" is far wider than "VOCALS", so it starts further left.
        // Equal edges would mean the same thing is drawn on both, which is the
        // shipped bug.
        XCTAssertGreaterThan(
            stemEdge - freshEdge, 8,
            "the stem's slot (left edge \(stemEdge)) is the same width as the empty track's "
            + "'+ Instrument' (left edge \(freshEdge)): the offer is still being made to a "
            + "track that plays a recording")
    }

    // MARK: - 4. WHERE A TRACK CAME FROM, when nobody asked for it
    //
    // Playing a key on a project with no instrument CREATES A TRACK
    // (`ensure_instrument_target`). That is the behaviour that lets someone who
    // does not know what a track is sit down and play, and it stays. What did
    // not exist is any way for the person it happens to to find out: a row
    // appeared in the arrangement and the app never mentioned it. Two wrong
    // public claims were made about this behaviour before anyone read the
    // journal — and the journal had the answer the whole time.
    //
    // Three things are pinned here, and the SECOND is the one that matters
    // most: the note must NOT appear on a track the user made themselves. A
    // message wired to fire always is the same defect as no message at all, and
    // it is the failure a one-track test cannot see.
    //
    // The engine half — journal `actor` -> snapshot `origin` — is proven in
    // `engine/agent-surface/tests/play_a_note.rs`. What is proven here is that
    // the app READS it, and turns it into ink and into a sentence.

    func testOnlyATrackTheAppMadeItselfCarriesAnExplanation() {
        var made = track("Instrument 1")
        made.origin = .played
        XCTAssertEqual(made.originNote, "Made when you played")

        // A hand-made track explains nothing, because there is nothing to
        // explain. `nil`, not an empty string: the header must draw NO line,
        // not a blank one.
        XCTAssertNil(track("Instrument 1").originNote,
                     "a track the user made must carry no explanation")
        XCTAssertNil(track("Vocals", kind: .vocals, clips: [audioClip()]).originNote)
    }

    /// The wire word is a CONTRACT with `host.rs` (`TRACK_ORIGIN_PLAYED`). If
    /// the engine ever renames it, this decode returns nil and the header
    /// silently goes quiet again — the exact failure this lane removed — so the
    /// literal is pinned rather than round-tripped through itself.
    func testTheOriginWireWordIsTheOneTheEngineSends() {
        XCTAssertEqual(StudioTrackOrigin.played.rawValue, "played")
        XCTAssertEqual(StudioTrackOrigin(rawValue: "played"), .played)
        XCTAssertNil(StudioTrackOrigin(rawValue: "user"),
                     "an unknown origin must decode to nil, not to a case")
        // 1 -> 3: Add a Layer and a stem import make tracks nobody asked for by
        // name, on the same journal-derived mechanism. RAISED because the set
        // genuinely grew; the guard did its job by failing when it did, which
        // is what a hardcoded count is for.
        XCTAssertEqual(StudioTrackOrigin.allCases.count, 3,
                       "a new origin needs its own sentence in `originNote`")
        XCTAssertEqual(StudioTrackOrigin.layered.rawValue, "layered")
        XCTAssertEqual(StudioTrackOrigin.imported.rawValue, "imported")
    }

    /// The band the explanation is drawn in: below the second control row,
    /// inside the 90 pt header. Measured against the shipped layout, not
    /// guessed — the assertion below that the FIRST row is byte-identical is
    /// what proves the band is in the right place, because a note drawn
    /// anywhere else would have disturbed it.
    private var originBand: Range<Int> { 46..<Int(StudioTokens.trackHeightDefault) }

    func testTheHeaderDrawsTheExplanationAndDrawsNothingWithoutIt() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        let byHand = track("Instrument 1")
        var madeForYou = byHand
        madeForYou.origin = .played

        // THE FLOOR, MEASURED FIRST — same reason as
        // `testAVocalsHeaderDrawsDifferentlyFromADrumsHeader` above, and this
        // site had the same defect: `--filter` this test on its own at the tip
        // and the `== 0` below failed on `ImageRenderer`'s first-render warm-up.
        // Measuring here pays it, and the bound tracks the renderer instead of
        // assuming it.
        //
        // For scale, the break this bound has to catch: making the row
        // `.center` its content instead of pinning it `.top` — which is exactly
        // "the explanation was paid for out of the name's width", the shape that
        // once truncated four stem names to two letters each — moves this band
        // by 136,350. The floor is 27 and the bound is 128, so the break clears
        // it by three orders of magnitude.
        let floorProbe = try raster(model, byHand)
        let plain = try raster(model, byHand)
        let explained = try raster(model, madeForYou)
        let allColumns = 0..<plain.width
        let noise = floorProbe.mass(against: plain, columns: allColumns, rows: firstRow)
        XCTAssertLessThan(
            noise, 512,
            "the renderer disagrees with itself by \(noise) on identical input, which is too much for this test to say anything")

        // INK, where a property assertion cannot see. A `Text` bound to a
        // constant, or an `if` that never fires, both pass `originNote` and
        // fail here.
        XCTAssertGreaterThan(
            explained.mass(against: plain, columns: allColumns, rows: originBand), 2_000,
            "the header of a track the app made itself is indistinguishable from one the user made")

        // And it is a NEW LINE, not a rearrangement: the name, the identity
        // slot and the controls above it are byte-identical. This is what stops
        // the explanation from being paid for out of the track name's width,
        // which is how the "+ Instrument" bug truncated four stems to two
        // letters each.
        XCTAssertLessThanOrEqual(
            explained.mass(against: plain, columns: allColumns, rows: firstRow), max(noise, 128),
            "adding the explanation moved the row above it (renderer floor \(noise), break measures 136,350)")
    }

    // MARK: What the app says at the moment it happens
    //
    // The header keeps answering "where did this come from" forever. It does
    // not answer "what just happened", and the person is PLAYING when this
    // fires — so the second half is a toast, which fades on its own. Not a
    // sheet, not an alert, nothing with a button: an interruption at the exact
    // moment the app finally works is worse than the silence it replaces.

    func testTheAppSaysSoWhenItMakesATrackAndStaysQuietWhenTheUserDoes() async throws {
        let engine = StudioMockEngine()
        let model = StudioViewModel(engine: engine)
        model.startPolling()
        defer { model.stopPolling() }
        for _ in 0..<80 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let tracks = try XCTUnwrap(model.snapshot?.tracks)
        XCTAssertGreaterThanOrEqual(tracks.count, 2, "need two tracks to tell the cases apart")

        // A track the user made, arriving AFTER the first snapshot — the same
        // moment in the same adoption path as the real case below, one field
        // different. Asserted FIRST, so a message wired to fire always fails
        // here rather than being mistaken for the real one.
        ToastManager.shared.currentToast = nil
        _ = await engine.send(.trackAdd(trackID: UUID().uuidString, name: "By hand", index: 0))
        for _ in 0..<40 where model.snapshot?.tracks.contains(where: { $0.name == "By hand" }) != true {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.snapshot?.tracks.contains { $0.name == "By hand" } == true,
                      "the hand-made track never arrived, so the quiet below proves nothing")
        XCTAssertNil(ToastManager.shared.currentToast,
                     "the app announced a track the user made themselves")
        XCTAssertTrue(model.announcedAutoCreatedTracks.isEmpty,
                      "a hand-made track was recorded as one the app made")

        // Now one the APP made. Same adoption path, one field different.
        await engine.setTrackOrigin(tracks[1].id, .played)
        for _ in 0..<40 where ToastManager.shared.currentToast == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let said = try XCTUnwrap(ToastManager.shared.currentToast?.message,
                                 "the app made a track and never mentioned it")
        XCTAssertTrue(said.contains(tracks[1].name),
                      "the message must name the track that appeared: \(said)")
        XCTAssertTrue(said.lowercased().contains("cmd-z"),
                      "the message must say how to take it back: \(said)")
        XCTAssertTrue(model.announcedAutoCreatedTracks.contains(tracks[1].id))

        // ONCE. A message repeated on every 30 Hz poll is a stuck banner.
        ToastManager.shared.currentToast = nil
        await engine.setTrackOrigin(tracks[1].id, .played)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(ToastManager.shared.currentToast,
                     "the same track was announced twice")
    }

    // MARK: What VoiceOver is told

    /// What the header's `accessibilityValue` opens with. It used to be "no
    /// instrument" on every row, which told a VoiceOver user nothing that
    /// distinguished the vocal from the bass.
    func testTheSpokenSummarySaysWhatTheTrackIs() {
        XCTAssertEqual(
            track("Vocals", kind: .vocals, clips: [audioClip()]).roleSummary,
            "Vocals stem")
        XCTAssertEqual(
            track("Drums", kind: .drums, clips: [audioClip()]).roleSummary,
            "Drums stem")
        // A whole recording has no stem word — it is not one part of anything.
        XCTAssertEqual(
            track("VO", kind: .imported, clips: [audioClip()]).roleSummary,
            "audio track")
        XCTAssertEqual(
            track("Keys", devices: [StudioDeviceSnapshot(id: "d", kind: "synth")]).roleSummary,
            "instrument Synth")
        XCTAssertEqual(
            track("Keys", clips: [audioClip(midi: true)]).roleSummary,
            "instrument track, no instrument")
        XCTAssertEqual(track("Track 5").roleSummary, "empty track, no instrument")
    }
}
