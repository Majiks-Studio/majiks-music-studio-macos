import XCTest
@testable import MajiksMusicStudio

// The on-screen keyboard: the no-hardware path to "press a key, hear a note".
//
// Two halves, same split as the piano roll's tests:
//   1. Pure geometry and the computer-key map — the parts that decide WHICH
//      NOTE a gesture means, which is where keyboard bugs actually live.
//   2. The controller driven the way a pointer and a keyboard drive it, with
//      every note it emits captured, so "a glissando strands a held note" and
//      "hiding the pane leaves a key droning" are catchable rather than
//      something a human has to notice by ear.
//
// What these deliberately do NOT claim: that the keys sound. Sound is asserted
// on rendered buffers in the engine (`render/tests/note_audition.rs`) and the
// control path is asserted on real journal state in
// `agent-surface/tests/play_a_note.rs`. A Swift test that "verified audio" by
// checking a closure fired would be a green signal on the wrong axis.

@MainActor
final class StudioOnScreenKeyboardTests: XCTestCase {

    private func layout(
        base: UInt8 = 48,
        octaves: Int = 3,
        size: CGSize = CGSize(width: 840, height: 120)
    ) -> StudioKeyboardLayout {
        StudioKeyboardLayout(basePitch: base, octaves: octaves, size: size)
    }

    /// A controller with every emitted note recorded, so the tests assert on
    /// what the ONE note path was actually told, not on internal state.
    private func recordingController() -> (StudioKeyboardController, () -> [(UInt8, Int, String)]) {
        let controller = StudioKeyboardController()
        let box = NoteBox()
        controller.onNote = { pitch, velocity, gate in
            box.notes.append((pitch, velocity, gate.wire))
        }
        return (controller, { box.notes })
    }

    private final class NoteBox {
        var notes: [(UInt8, Int, String)] = []
    }

    // MARK: - 1. Geometry

    func testTheKeyboardIsLaidOutLikeAKeyboard() {
        let l = layout()
        XCTAssertEqual(l.whiteCount, 21, "three octaves is 21 white keys")
        XCTAssertEqual(l.whiteKeys.count, 21)
        XCTAssertEqual(l.blackKeys.count, 15, "five black keys per octave")
        XCTAssertEqual(l.whiteKeys.first?.pitch, 48, "the window starts on a C")
        XCTAssertEqual(l.topPitch, 83, "C3 + 3 octaves - 1 semitone = B5")

        // White keys tile the full width with no gap and no overlap.
        let widths = l.whiteKeys.map(\.rect.width)
        XCTAssertEqual(widths.reduce(0, +), l.size.width, accuracy: 0.001)
        for (a, b) in zip(l.whiteKeys, l.whiteKeys.dropFirst()) {
            XCTAssertEqual(a.rect.maxX, b.rect.minX, accuracy: 0.001, "no gap between white keys")
        }
    }

    func testWhiteKeysAreTheWhiteNotesAndBlackKeysTheBlackOnes() {
        let l = layout()
        for key in l.whiteKeys {
            XCTAssertFalse(
                StudioPitchName.isAccidental(key.pitch),
                "\(StudioPitchName.label(key.pitch)) is drawn as a white key but is an accidental")
        }
        for key in l.blackKeys {
            XCTAssertTrue(
                StudioPitchName.isAccidental(key.pitch),
                "\(StudioPitchName.label(key.pitch)) is drawn as a black key but is a natural")
        }
    }

    func testClickingABlackKeyPlaysTheBlackKeyNotTheWhiteOneUnderIt() {
        // Black keys are drawn ON TOP of the white keys they overlap. Hit-testing
        // white first would make the upper two-thirds of every black key play the
        // white note beneath it, which is a keyboard that cannot play in a flat
        // key at all.
        let l = layout()
        guard let cSharp = l.blackKeys.first(where: { $0.pitch == 49 }) else {
            return XCTFail("C#3 must be drawn")
        }
        let nearTheTop = CGPoint(x: cSharp.rect.midX, y: cSharp.rect.minY + 4)
        XCTAssertEqual(l.pitch(at: nearTheTop), 49, "the top of a black key is that black key")

        // And below the black key's bottom edge, the same x is the white key.
        let belowIt = CGPoint(x: cSharp.rect.midX, y: l.size.height - 4)
        let there = l.pitch(at: belowIt)
        XCTAssertTrue(
            there == 48 || there == 50,
            "below a black key's bottom edge, that x belongs to a white key, got \(String(describing: there))")
    }

    func testEveryPitchInTheWindowIsReachableByAClick() {
        // A key that is drawn but cannot be hit is worse than a key that is not
        // drawn: it looks playable and is not.
        let l = layout()
        for key in l.whiteKeys + l.blackKeys {
            let p = CGPoint(x: key.rect.midX, y: key.rect.midY)
            XCTAssertEqual(
                l.pitch(at: p), key.pitch,
                "\(StudioPitchName.label(key.pitch)) is drawn but clicking its centre gives something else")
        }
    }

    func testAClickOutsideTheKeysIsNotANote() {
        let l = layout()
        XCTAssertNil(l.pitch(at: CGPoint(x: -5, y: 10)))
        XCTAssertNil(l.pitch(at: CGPoint(x: l.size.width + 5, y: 10)))
        XCTAssertNil(l.pitch(at: CGPoint(x: 10, y: l.size.height + 5)))
    }

    // MARK: - 2. Velocity

    func testClickingLowerOnAKeyIsLouder() {
        // A mouse has no pressure axis, so the vertical position stands in for
        // one: striking nearer the front edge of a real key gives more leverage.
        let height: CGFloat = 120
        let soft = StudioKeyboardVelocity.from(y: 2, keyHeight: height)
        let mid = StudioKeyboardVelocity.from(y: 60, keyHeight: height)
        let loud = StudioKeyboardVelocity.from(y: 118, keyHeight: height)
        XCTAssertLessThan(soft, mid)
        XCTAssertLessThan(mid, loud)
        XCTAssertGreaterThanOrEqual(soft, StudioKeyboardVelocity.minimum)
        XCTAssertLessThanOrEqual(loud, StudioKeyboardVelocity.maximum)
    }

    func testTheSoftestClickIsStillAudiblyAKey() {
        // Velocity 3 reads as a broken key rather than a quiet one.
        XCTAssertGreaterThanOrEqual(
            StudioKeyboardVelocity.from(y: 0, keyHeight: 120),
            StudioKeyboardVelocity.minimum)
        XCTAssertGreaterThan(StudioKeyboardVelocity.minimum, 16)
    }

    func testVelocitySurvivesAZeroHeightKey() {
        // A pane mid-animation can hand a zero height through. Dividing by it
        // would produce a NaN velocity and then a clamped 0 = a silent note.
        XCTAssertEqual(StudioKeyboardVelocity.from(y: 10, keyHeight: 0), StudioKeyboardVelocity.default)
    }

    // MARK: - 3. Musical typing

    func testTheHomeRowIsTheWhiteKeysAndTheRowAboveIsTheBlackOnes() {
        // The Logic / GarageBand layout, deliberately: it is the one a person
        // arriving from another DAW already has in their hands.
        let base: UInt8 = 48
        let expected: [(Character, UInt8)] = [
            ("a", 48), ("s", 50), ("d", 52), ("f", 53),
            ("g", 55), ("h", 57), ("j", 59), ("k", 60),
            ("w", 49), ("e", 51), ("t", 54), ("y", 56), ("u", 58),
        ]
        for (character, pitch) in expected {
            XCTAssertEqual(
                StudioMusicalTyping.pitch(for: character, basePitch: base), pitch,
                "'\(character)' must play \(StudioPitchName.label(pitch))")
        }
    }

    func testMusicalTypingIsCaseInsensitive() {
        XCTAssertEqual(StudioMusicalTyping.pitch(for: "A", basePitch: 48), 48)
        XCTAssertEqual(StudioMusicalTyping.pitch(for: "W", basePitch: 48), 49)
    }

    func testKeysThatAreNotPartOfTheLayoutAreLeftAlone() {
        // The piano roll owns single letters of its own (b = draw tool,
        // v = velocity lane, [ and ] = grid). Swallowing every keystroke would
        // break them the moment the keyboard has focus.
        for character: Character in ["b", "v", "[", "]", "1", "/", " "] {
            XCTAssertNil(
                StudioMusicalTyping.pitch(for: character, basePitch: 48),
                "'\(character)' must not be a note")
        }
    }

    func testAKeyThatWouldRunOffTheTopOfMidiIsNotANote() {
        XCTAssertNil(
            StudioMusicalTyping.pitch(for: "'", basePitch: 120),
            "pitch 137 does not exist and must not wrap")
    }

    // MARK: - 4. The controller: held notes and their releases

    func testAHeldKeySendsExactlyOneNoteOnAndOneNoteOff() {
        let (c, notes) = recordingController()
        c.press(60, velocity: 90)
        c.press(60, velocity: 90)   // key repeat: must NOT retrigger
        c.release(60)
        c.release(60)               // spurious second up: must be ignored
        XCTAssertEqual(notes().map(\.2), ["on", "off"])
        XCTAssertEqual(notes().first?.1, 90, "the velocity that was pressed is the one sent")
        XCTAssertTrue(c.held.isEmpty)
    }

    func testHidingTheKeyboardReleasesEveryHeldKey() {
        // A note-on with no matching note-off is a key that drones until the app
        // is quit. This is the single most likely way this surface can go wrong.
        let (c, notes) = recordingController()
        c.press(60, velocity: 100)
        c.press(64, velocity: 100)
        c.press(67, velocity: 100)
        c.releaseAll()
        XCTAssertEqual(notes().filter { $0.2 == "off" }.count, 3, "every held key is released")
        XCTAssertTrue(c.held.isEmpty)
    }

    func testChangingOctaveReleasesHeldKeysFirst() {
        // Moving the window under held fingers would leave their note-offs
        // addressing pitches that are no longer under the pointer.
        let (c, notes) = recordingController()
        c.press(60, velocity: 100)
        c.shiftOctave(1)
        XCTAssertTrue(notes().contains { $0.0 == 60 && $0.2 == "off" }, "the held key is released")
        XCTAssertEqual(c.basePitch, 60, "and the window moved up an octave")
        XCTAssertTrue(c.held.isEmpty)
    }

    func testTheOctaveWindowCannotRunOffEitherEndOfTheKeyboard() {
        let c = StudioKeyboardController()
        for _ in 0..<20 { c.shiftOctave(-1) }
        XCTAssertGreaterThanOrEqual(c.basePitch, StudioKeyboardOctave.lowest)
        for _ in 0..<40 { c.shiftOctave(1) }
        XCTAssertLessThanOrEqual(c.basePitch, StudioKeyboardOctave.highest)
    }

    func testTypingAKeyPlaysItAndReleasingItStopsIt() {
        let (c, notes) = recordingController()
        XCTAssertTrue(c.handleTyping("a", isDown: true))
        XCTAssertTrue(c.handleTyping("a", isDown: false))
        XCTAssertEqual(notes().map { ($0.0, $0.2) }.map { "\($0.0)-\($0.1)" }, ["48-on", "48-off"])
    }

    func testAutoRepeatDoesNotMachineGunTheSameNote() {
        // Holding a computer key fires .down over and over. Without the guard,
        // one held key becomes dozens of retriggers a second.
        let (c, notes) = recordingController()
        for _ in 0..<25 { c.handleTyping("a", isDown: true) }
        c.handleTyping("a", isDown: false)
        XCTAssertEqual(notes().filter { $0.2 == "on" }.count, 1, "one key, one note")
        XCTAssertEqual(notes().filter { $0.2 == "off" }.count, 1)
    }

    func testZAndXMoveTheOctaveAndPlayNothing() {
        let (c, notes) = recordingController()
        let base = c.basePitch
        XCTAssertTrue(c.handleTyping("x", isDown: true))
        XCTAssertEqual(c.basePitch, StudioKeyboardOctave.shifted(base, byOctaves: 1))
        XCTAssertTrue(c.handleTyping("z", isDown: true))
        XCTAssertEqual(c.basePitch, base)
        XCTAssertTrue(notes().isEmpty, "the octave keys are not notes")
    }

    func testAnUnrelatedKeyIsNotConsumed() {
        let c = StudioKeyboardController()
        XCTAssertFalse(c.handleTyping("b", isDown: true), "the roll's draw-tool key must pass through")
        XCTAssertFalse(c.handleTyping("[", isDown: true), "the roll's grid keys must pass through")
    }

    func testTypingUsesTheChosenVelocity() {
        let (c, notes) = recordingController()
        c.typingVelocity = 42
        c.handleTyping("a", isDown: true)
        XCTAssertEqual(notes().first?.1, 42)
    }

    func testAKeyboardWithNoEngineIsHonestAboutIt() {
        // On a build without the real engine the keys still draw and respond —
        // but the pane says "Silent build" rather than pretending. Pretending is
        // what shipped a piano roll wired to a mock.
        let c = StudioKeyboardController()
        XCTAssertFalse(c.isWired)
        c.onNote = { _, _, _ in }
        XCTAssertTrue(c.isWired)
    }

    // MARK: - 5. What the snapshot says is sounding

    func testAnEmptyPerformanceHasNothingToKeep() {
        XCTAssertFalse(StudioPerformanceSnapshot.idle.hasSomethingToKeep)
        XCTAssertTrue(StudioPerformanceSnapshot.idle.sounding.isEmpty)
    }

    func testAPerformanceWithNotesOffersToKeepThem() {
        let p = StudioPerformanceSnapshot(
            keepableNotes: 7, sounding: [60, 64], startTicks: 960, endTicks: 4800)
        XCTAssertTrue(p.hasSomethingToKeep)
        XCTAssertEqual(p.sounding, [60, 64])
    }

    // MARK: - 6. A hardware key must LIGHT an on-screen key
    //
    // The reported bug. Note carefully what these can and cannot prove: they
    // prove the controller lights from the engine's set and holds it long enough
    // to see. They do NOT prove the set ever arrives — that is the seam the bug
    // actually lived in, and it is asserted against the real engine in section 8.

    func testAKeyThisSurfaceNeverTouchedStillLightsUp() {
        // A hardware key is not in `held` — nothing on screen pressed it. If the
        // drawing only ever read `held`, a USB keyboard could never light a key.
        let c = StudioKeyboardController()
        c.observeSounding([60, 64])
        XCTAssertTrue(c.lit.contains(60))
        XCTAssertTrue(c.lit.contains(64))
        XCTAssertTrue(c.held.isEmpty, "and it did so without pretending this surface played them")
    }

    func testAKeySeenInOnlyOnePollStaysLitLongEnoughToBeSeen() {
        // 30 Hz sampling of a 60 ms staccato note can catch it exactly once. One
        // frame of purple is not a highlight, it is a glitch. The floor makes a
        // seen key visible; it cannot make an unseen one appear.
        let c = StudioKeyboardController()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        c.observeSounding([72], now: t0)
        c.observeSounding([], now: t0.addingTimeInterval(0.033))
        XCTAssertTrue(
            c.lit.contains(72),
            "a key seen in one poll and gone by the next must still be drawn")
    }

    func testTheHighlightDoesNotStickOnForever() {
        // The other half: a latch with no expiry leaves the last key of a phrase
        // lit until something else happens to redraw, which is a keyboard that
        // looks jammed.
        let c = StudioKeyboardController()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        c.observeSounding([72], now: t0)
        c.observeSounding([], now: t0.addingTimeInterval(0.001))
        c.pruneLit(now: t0.addingTimeInterval(StudioKeyboardController.minimumLitSeconds + 0.01))
        XCTAssertFalse(c.lit.contains(72), "the latch must run out")
        XCTAssertTrue(c.lit.isEmpty)
    }

    func testAHeldHardwareKeyStaysLitForAsLongAsItIsHeld() {
        // The latch must not be the only thing keeping a key lit: a pedal tone
        // held for ten seconds is `sounding` in every poll.
        let c = StudioKeyboardController()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        for tick in 0..<300 {
            c.observeSounding([48], now: t0.addingTimeInterval(Double(tick) * 0.033))
        }
        XCTAssertTrue(c.lit.contains(48))
    }

    // MARK: - 7. Matching the physical keyboard

    func testTheWindowIsTheSmallestWholeOctaveSpanCoveringWhatWasPlayed() {
        // A 61-key controller is C2..C7 (MIDI 36..96). Anchored on a C, that
        // needs six octaves — the top C is one key into the sixth.
        let fitted = StudioKeyboardSpan.window(containing: 36...96)
        XCTAssertEqual(fitted.base, 36)
        XCTAssertEqual(fitted.octaves, 6)
        XCTAssertLessThanOrEqual(fitted.base, 36)
        XCTAssertGreaterThanOrEqual(StudioKeyboardSpan.top(base: fitted.base, octaves: fitted.octaves), 96)
    }

    func testTheWindowAlwaysStartsOnACAndNeverDrawsAKeyThatCannotExist() {
        // A window whose top ran past 127 draws keys that are visible and
        // unplayable, which is worse than not drawing them.
        for low in stride(from: 0, through: 120, by: 7) {
            for high in stride(from: low, through: 127, by: 11) {
                let f = StudioKeyboardSpan.window(containing: UInt8(low)...UInt8(high))
                XCTAssertEqual(Int(f.base) % 12, 0, "the window must start on a C, got \(f.base)")
                XCTAssertLessThanOrEqual(
                    Int(f.base) + f.octaves * 12 - 1, 127,
                    "window \(f) runs past the top of MIDI")
                XCTAssertGreaterThanOrEqual(f.octaves, StudioKeyboardSpan.minimum)
                XCTAssertLessThanOrEqual(f.octaves, StudioKeyboardSpan.maximum)
            }
        }
    }

    func testAFull88KeyControllerFitsOnScreen() {
        // The largest thing anyone plugs in: A0..C8. Anchored on a C that is nine
        // octaves, which is why the cap is nine and not seven — an 88 is exactly
        // the controller a seven-octave cap would truncate.
        let f = StudioKeyboardSpan.window(containing: 21...108)
        let window = f.base...StudioKeyboardSpan.top(base: f.base, octaves: f.octaves)
        XCTAssertTrue(window.contains(21), "A0 must be on screen")
        XCTAssertTrue(window.contains(108), "C8 must be on screen")
        XCTAssertLessThanOrEqual(f.octaves, StudioKeyboardSpan.maximum)
    }

    func testAPitchAboveEveryRealInstrumentStillLeavesALegalWindow() {
        // A transposed controller or a fuzzed stream can ask for pitches above
        // B8, which no whole-octave window inside MIDI can reach. The answer must
        // be the widest legal window, not a broken one.
        let f = StudioKeyboardSpan.window(containing: 4...126)
        XCTAssertEqual(f.octaves, StudioKeyboardSpan.maximum)
        XCTAssertEqual(Int(f.base) % 12, 0)
        XCTAssertEqual(
            StudioKeyboardSpan.top(base: f.base, octaves: f.octaves), 119,
            "the top of the highest window a whole-octave layout can legally draw")
    }

    func testPlayingTheEndsOfAHardwareKeyboardWidensTheOnScreenOne() {
        // The whole point: no dialog, no key-count setting, no question the user
        // could answer wrongly. Play your lowest and highest key; the screen
        // covers them.
        let c = StudioKeyboardController()
        XCTAssertFalse(c.window.contains(36), "precondition: C2 is off screen by default")
        c.observeSounding([36])
        c.observeSounding([])
        c.observeSounding([96])
        XCTAssertTrue(c.window.contains(36), "the lowest key played must be on screen")
        XCTAssertTrue(c.window.contains(96), "and so must the highest")
        XCTAssertEqual(c.learnedRange, 36...96)
    }

    func testTheKeyboardNeverNarrowsOnItsOwn() {
        // Absence of a note is not evidence that a key is absent. Shrinking
        // during a quiet passage would take keys away mid-performance.
        let c = StudioKeyboardController()
        c.observeSounding([36])
        c.observeSounding([96])
        let wide = c.window
        for _ in 0..<20 { c.observeSounding([60]) }
        XCTAssertEqual(c.window, wide, "a middle-of-the-keyboard passage must not shrink the window")
    }

    func testTurningTheFitOffLeavesTheWindowWhereTheUserPutIt() {
        let c = StudioKeyboardController()
        c.fitsToHardware = false
        let before = c.window
        c.observeSounding([24])
        c.observeSounding([108])
        XCTAssertEqual(c.window, before, "with the fit off, nothing moves the window but the user")
        XCTAssertEqual(c.learnedRange, 24...108, "though what the hardware plays is still noticed")
    }

    func testThisSurfacesOwnKeysTeachItNothingAboutTheHardware() {
        // An on-screen or typed note is echoed back in `sounding` too. Learning
        // from it would be learning from itself, and widening while a mouse is
        // down would move the key out from under the pointer mid-drag.
        let (c, _) = recordingController()
        let before = c.window
        c.press(60, velocity: 100)
        c.observeSounding([60])
        XCTAssertNil(c.learnedRange, "the mouse is not a MIDI keyboard")
        XCTAssertEqual(c.window, before)
    }

    func testWithNoHardwareTheKeyboardOpensWhereItAlwaysDid() {
        // The fallback, stated as a test so it cannot drift: someone with no MIDI
        // gear sees exactly the three-octave C3 window, which is what the
        // computer-key map spans.
        let c = StudioKeyboardController()
        XCTAssertEqual(c.basePitch, StudioKeyboardOctave.defaultBase)
        XCTAssertEqual(c.octaves, StudioKeyboardSpan.default)
        XCTAssertNil(c.learnedRange)
        XCTAssertTrue(
            c.window.contains(StudioMusicalTyping.pitch(for: "'", basePitch: c.basePitch) ?? 0),
            "every key of the typing map must be drawn")
    }

    func testNarrowingTheSpanReleasesHeldKeysFirst() {
        // Same hazard as the octave control: a key can be pulled out from under
        // a finger, and its note-off would then address a pitch nobody is on.
        let (c, notes) = recordingController()
        c.press(60, velocity: 100)
        c.setOctaves(1)
        XCTAssertTrue(notes().contains { $0.0 == 60 && $0.2 == "off" })
        XCTAssertTrue(c.held.isEmpty)
        XCTAssertEqual(c.octaves, 1)
    }

    func testTheSpanCannotBeSetToSomethingUnplayable() {
        let c = StudioKeyboardController()
        c.setOctaves(-4)
        XCTAssertEqual(c.octaves, StudioKeyboardSpan.minimum)
        c.setOctaves(99)
        XCTAssertEqual(c.octaves, StudioKeyboardSpan.maximum)
        XCTAssertLessThanOrEqual(Int(c.basePitch) + c.octaves * 12 - 1, 127)
    }

    func testResettingTheRangePutsItBackWhereItOpens() {
        let c = StudioKeyboardController()
        c.observeSounding([24])
        c.setOctaves(7)
        c.resetRange()
        XCTAssertEqual(c.basePitch, StudioKeyboardOctave.defaultBase)
        XCTAssertEqual(c.octaves, StudioKeyboardSpan.default)
    }
}

// MARK: - 8. THE JOIN: does `sounding` ever reach the app at all?
//
// Everything above, and every engine test in `agent-surface/tests/play_a_note.rs`,
// was green while a hardware keyboard lit nothing on screen.
//
// Both halves were telling the truth. The engine really does populate
// `performance.sounding` from the same buffer the audio came from, on the
// hardware path, and proves it. The pane really does draw from it. What nobody
// owned was the call BETWEEN them: `StudioViewModel.pollOnce` asks
// `engine.snapshot(ifNewerThan: lastAdoptedRevision)`, and that gate returned nil
// whenever the journal seq had not advanced and the transport was stopped.
//
// Playing a note is deliberately journal-silent (noodling must not fill the undo
// stack) and deliberately does not roll the transport
// (`playing_never_starts_the_transport`). Both decisions are right. Together they
// meant the app never adopted a snapshot while a human was playing — so the keys
// lit only if you happened to have pressed Play first.
//
// Every Swift test that ever "proved" the performance block called
// `snapshot(ifNewerThan: nil)` — the UNGATED call the app does not use. That is
// why the whole class was invisible to the suite. These use the app's call.
#if REAL_ENGINE
@MainActor
final class StudioOnScreenKeyboardEngineJoinTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("majiks-keyboard-join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A real engine over a real package with one instrument track, so the first
    /// played note does NOT create a track (which would bump the journal seq and
    /// let the snapshot through for the wrong reason — the exact accident that
    /// makes `testAnOnScreenKeyOnAnEmptyProjectCreatesSomethingToPlay` pass).
    private func makeEngine() async throws -> (RealStudioEngine, UInt64) {
        let engine = try RealStudioEngine(
            dataDir: tempDir.appendingPathComponent("Keys.mstudio").path, audible: false)
        let outcome = await engine.addInstrumentTrack(name: "Keys", lengthTicks: 3840 * 4)
        XCTAssertTrue(outcome.ok, "addInstrumentTrack: \(outcome.message ?? "no message")")
        let adoptedOrNil = await engine.snapshot(ifNewerThan: nil)
        let adopted = try XCTUnwrap(adoptedOrNil)
        XCTAssertEqual(adopted.tracks.count, 1)
        XCTAssertFalse(adopted.transport.isPlaying, "precondition: the transport is stopped")
        return (engine, adopted.revision)
    }

    func testAHeldKeyOnAStoppedTransportReachesTheUiThroughTheGatedPollTheAppUses() async throws {
        let (engine, revision) = try await makeEngine()

        _ = await engine.previewNote(trackID: nil, pitch: 60, velocity: 100, gate: .on)

        // THE APP'S CALL. Not `ifNewerThan: nil`.
        let freshOrNil = await engine.snapshot(ifNewerThan: revision)
        let fresh = try XCTUnwrap(
            freshOrNil,
            "a key going down must deliver a snapshot: this is the poll the on-screen keyboard lights from, and returning nil here is a hardware key that lights nothing")
        XCTAssertEqual(
            Set(fresh.performance.sounding), [60],
            "the held key must be reported sounding to the UI")
        XCTAssertFalse(
            fresh.transport.isPlaying,
            "and without having started the transport to get there")

        _ = await engine.previewNote(trackID: nil, pitch: 60, velocity: 0, gate: .off)
        let releasedOrNil = await engine.snapshot(ifNewerThan: fresh.revision)
        let released = try XCTUnwrap(
            releasedOrNil,
            "a key coming UP must deliver a snapshot too, or the on-screen key stays lit after the finger left")
        XCTAssertTrue(
            released.performance.sounding.isEmpty,
            "a released key must stop being lit")
    }

    func testKeepsLiveCountAlsoReachesTheUiWhileTheTransportIsStopped() async throws {
        // The same gate hid the Keep button's count, which is the affordance that
        // tells someone their playing was captured at all. "Keep 3 notes" that
        // never counts up reads as "nothing was recorded".
        let (engine, revision) = try await makeEngine()
        var since = revision
        var counts: [Int] = []
        for pitch: UInt8 in [60, 64, 67] {
            _ = await engine.previewNote(trackID: nil, pitch: pitch, velocity: 100, gate: .on)
            _ = await engine.previewNote(trackID: nil, pitch: pitch, velocity: 0, gate: .off)
            let freshOrNil = await engine.snapshot(ifNewerThan: since)
            let fresh = try XCTUnwrap(
                freshOrNil,
                "the poll must see the performance grow after note \(pitch)")
            since = fresh.revision
            counts.append(fresh.performance.keepableNotes)
        }
        XCTAssertEqual(
            counts, [1, 2, 3],
            "Keep's live count must count up in the UI without a transport roll")
    }

    func testAnIdlePollStillCostsNothing() async throws {
        // The gate is not deleted, only widened. A poll with nothing happening
        // must still early-out, or the UI rebuilds the whole project snapshot 30
        // times a second forever.
        let (engine, revision) = try await makeEngine()
        var since = revision
        if let fresh = await engine.snapshot(ifNewerThan: since) { since = fresh.revision }
        for _ in 0..<5 {
            let idle = await engine.snapshot(ifNewerThan: since)
            XCTAssertNil(
                idle,
                "an idle poll on a stopped transport with nothing played must not deliver a snapshot")
        }
    }
}
#endif
