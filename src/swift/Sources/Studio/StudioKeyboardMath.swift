import CoreGraphics
import Foundation

// MARK: - On-screen keyboard: the pure half
//
// Geometry and the computer-key mapping live here, with no SwiftUI and no
// engine, for the same reason StudioPianoRollMath does: the parts that decide
// WHICH NOTE a gesture means are the parts most worth testing, and a test that
// has to stand up a view to ask "what pitch is at x = 210?" tests the view.
//
// ── Why there is no ScrollView in the keyboard, either ─────────────────────
//
// A full 128-key keyboard is very wide, which is exactly the shape that tempts
// a horizontal ScrollView, and on macOS a horizontal ScrollView's hit-testing
// is unreliable: it silently eats Button clicks and makes controls feel dead
// (SettingsView.swift documents the tab strip that cost days, and the piano
// roll was deliberately built with explicit transforms instead). An on-screen
// keyboard whose keys do not respond to clicks would be a perfect reproduction
// of that bug — it is a keyboard, its entire job is responding to clicks.
//
// So the keyboard shows a WINDOW of octaves and pans it with an explicit
// integer octave control. `StudioKeyboardLayout` computes that window's key
// rects directly; the view draws them into a Canvas and hit-tests them with one
// DragGesture. No scroll view, no transform stack, no 128 Buttons.

// MARK: - Layout

/// The geometry of the visible key window. Everything is derived from the
/// available width, the number of octaves shown, and the bottom octave.
struct StudioKeyboardLayout: Equatable {
    /// Lowest pitch drawn — always a C.
    let basePitch: UInt8
    /// How many octaves are visible.
    let octaves: Int
    let size: CGSize

    /// White-key semitone offsets inside one octave.
    static let whiteOffsets: [Int] = [0, 2, 4, 5, 7, 9, 11]
    /// Black keys, as (semitone offset, index of the white key it sits after).
    static let blackOffsets: [(semitone: Int, afterWhite: Int)] = [
        (1, 0), (3, 1), (6, 3), (8, 4), (10, 5),
    ]

    /// A black key is this fraction of a white key's width, and of its height.
    static let blackWidthRatio: CGFloat = 0.62
    static let blackHeightRatio: CGFloat = 0.62

    var whiteCount: Int { octaves * Self.whiteOffsets.count }

    var whiteWidth: CGFloat {
        guard whiteCount > 0, size.width > 0 else { return 0 }
        return size.width / CGFloat(whiteCount)
    }

    /// Highest pitch drawn (the B at the top of the last octave).
    var topPitch: UInt8 {
        UInt8(min(127, Int(basePitch) + octaves * 12 - 1))
    }

    var pitchRange: ClosedRange<UInt8> { basePitch...max(basePitch, topPitch) }

    /// Rect of the white key at `index` (0 = leftmost).
    func whiteRect(at index: Int) -> CGRect {
        CGRect(x: CGFloat(index) * whiteWidth, y: 0, width: whiteWidth, height: size.height)
    }

    /// Rect of a black key, centred on the boundary between two white keys.
    func blackRect(octave: Int, afterWhite: Int) -> CGRect {
        let boundary = CGFloat(octave * Self.whiteOffsets.count + afterWhite + 1) * whiteWidth
        let w = whiteWidth * Self.blackWidthRatio
        return CGRect(
            x: boundary - w / 2, y: 0,
            width: w, height: size.height * Self.blackHeightRatio)
    }

    /// Every white key as (pitch, rect), left to right.
    var whiteKeys: [(pitch: UInt8, rect: CGRect)] {
        var out: [(UInt8, CGRect)] = []
        for octave in 0..<octaves {
            for (i, semitone) in Self.whiteOffsets.enumerated() {
                let raw = Int(basePitch) + octave * 12 + semitone
                guard raw <= 127 else { continue }
                out.append((UInt8(raw), whiteRect(at: octave * Self.whiteOffsets.count + i)))
            }
        }
        return out
    }

    /// Every black key as (pitch, rect), left to right.
    var blackKeys: [(pitch: UInt8, rect: CGRect)] {
        var out: [(UInt8, CGRect)] = []
        for octave in 0..<octaves {
            for spec in Self.blackOffsets {
                let raw = Int(basePitch) + octave * 12 + spec.semitone
                guard raw <= 127 else { continue }
                out.append((UInt8(raw), blackRect(octave: octave, afterWhite: spec.afterWhite)))
            }
        }
        return out
    }

    /// The pitch under `point`, or nil when the point misses every key.
    ///
    /// Black keys are tested FIRST because they are drawn on top and overlap the
    /// white keys beneath them. Testing white first would make the top two-thirds
    /// of every black key play the white key it sits on — which is the bug a real
    /// keyboard cannot have.
    func pitch(at point: CGPoint) -> UInt8? {
        for key in blackKeys where key.rect.contains(point) { return key.pitch }
        for key in whiteKeys where key.rect.contains(point) { return key.pitch }
        return nil
    }
}

// MARK: - Velocity

/// How hard a click or a computer key hits.
enum StudioKeyboardVelocity {
    /// Softest and loudest a click can produce. Not 0..127: a click that
    /// produced velocity 3 reads as a broken key, and 127 is a shout.
    static let minimum = 32
    static let maximum = 118

    /// Velocity from WHERE on the key the pointer landed.
    ///
    /// A mouse has no pressure axis, so something has to stand in for one. The
    /// vertical position on the key is the standard answer (GarageBand's
    /// on-screen keyboard does exactly this) and it is the right one here:
    /// striking nearer the front edge of a real key gives more leverage and a
    /// louder note, so "lower is louder" matches the instrument being imitated
    /// rather than being an arbitrary convention to memorise. It is also
    /// self-teaching — you discover it by clicking twice in different places.
    ///
    /// `y` is measured from the TOP of the key, `height` is that key's own
    /// height (a black key is shorter, so its full range still spans its face).
    static func from(y: CGFloat, keyHeight: CGFloat) -> Int {
        guard keyHeight > 0 else { return `default` }
        let t = max(0, min(1, y / keyHeight))
        return minimum + Int((CGFloat(maximum - minimum) * t).rounded())
    }

    /// A computer key has no analog axis at all, so it gets a stable, adjustable
    /// value rather than a guess. Guessing a velocity from, say, how long the key
    /// was held would make repeated presses of the same key produce different
    /// notes for no reason the player can see.
    static let `default` = 100
}

// MARK: - Musical typing

/// The computer-keyboard → pitch map.
///
/// This is the Logic / GarageBand "Musical Typing" layout, deliberately, because
/// it is the one a person arriving from another DAW already has in their hands:
/// the home row is the white keys and the row above holds the black keys in the
/// gaps where they physically sit.
///
///     W E   T Y U   O P        ← C# D#   F# G# A#   C# D#
///    A S D F G H J K L         ← C  D  E  F  G  A  B  C  D
///
/// Z and X move down and up an octave.
enum StudioMusicalTyping {
    /// Semitone offset above the keyboard's base C, per character.
    static let semitones: [Character: Int] = [
        "a": 0, "w": 1, "s": 2, "e": 3, "d": 4, "f": 5, "t": 6,
        "g": 7, "y": 8, "h": 9, "u": 10, "j": 11,
        "k": 12, "o": 13, "l": 14, "p": 15, ";": 16, "'": 17,
    ]

    static let octaveDown: Character = "z"
    static let octaveUp: Character = "x"

    /// The pitch a character plays, relative to `basePitch`. nil for every
    /// character that is not part of the layout, so the roll's own single-letter
    /// shortcuts and normal typing are never swallowed.
    static func pitch(for character: Character, basePitch: UInt8) -> UInt8? {
        guard let semitone = semitones[Character(character.lowercased())] else { return nil }
        let raw = Int(basePitch) + semitone
        guard (0...127).contains(raw) else { return nil }
        return UInt8(raw)
    }

    /// True for the two octave-shift keys, which are handled but play nothing.
    static func isOctaveShift(_ character: Character) -> Bool {
        let c = Character(character.lowercased())
        return c == octaveDown || c == octaveUp
    }
}

// MARK: - Octave window

/// Where the visible key window sits, and how far it may be moved.
enum StudioKeyboardOctave {
    /// C-2 .. C8 in MIDI numbers, stepping by octave.
    static let lowest: UInt8 = 0
    /// Highest base that still shows a full octave.
    static let highest: UInt8 = 108

    /// C3 (MIDI 48) under the Ableton/Yamaha naming this app already uses, so a
    /// 3-octave window spans C3..B5 with middle C (60) comfortably in the middle
    /// of it. A keyboard that opened somewhere a player has to travel to before
    /// they can play a tune is the same defect as a piano roll that opens at C8.
    static let defaultBase: UInt8 = 48

    static func clamp(_ base: Int) -> UInt8 {
        UInt8(max(Int(lowest), min(Int(highest), base)))
    }

    /// Shift by whole octaves, clamped so the window never runs off either end.
    static func shifted(_ base: UInt8, byOctaves delta: Int) -> UInt8 {
        clamp(Int(base) + delta * 12)
    }
}

// MARK: - How WIDE the window is

/// The span of the visible key window, and how it learns the instrument that is
/// plugged in.
///
/// ── Why the range is adjustable, and why it also fits itself ───────────────
///
/// The window used to be a fixed three octaves. Three octaves is the right
/// DEFAULT — the computer-key map spans 17 semitones, so a person with no MIDI
/// gear can reach everything drawn — but it is wrong for someone holding a
/// 61-key controller: two of their five octaves are simply not on screen, so the
/// on-screen keyboard cannot show what they are playing.
///
/// MIDI does not advertise a key count. There is no message to ask a controller
/// how big it is, no standard descriptor, and the same USB product ID ships in
/// several key counts. So the app cannot be TOLD the range. What it can do is
/// notice: every note that arrives is proof that a key exists at that pitch, and
/// the union of everything received is a lower bound on the instrument that is
/// there. Widening to cover that is self-configuring — it costs the user nothing,
/// needs no dialog, cannot be answered wrongly, and is correct within the first
/// few bars of anyone exploring their keyboard.
///
/// It only ever WIDENS. Narrowing on the evidence of a quiet passage would take
/// keys away from someone in the middle of playing, and absence of a note is not
/// evidence that the key is absent. The manual span control is still there for
/// the times the guess is not what someone wants, and `resetRange` puts it back.
///
/// FALLBACK, no hardware: the three-octave C3 window, exactly as before. Nothing
/// about this changes what a person with no MIDI gear sees until a cable is
/// plugged in and played.
enum StudioKeyboardSpan {
    /// One octave is the narrowest thing still recognisable as a keyboard.
    static let minimum = 1
    /// Nine, because that is what a full 88-key controller costs once the window
    /// is anchored on a C: an 88 spans A0..C8, whose bottom A sits in the first
    /// octave and whose top C sits in the ninth. Eight would truncate the most
    /// common large controller there is, which is the exact complaint being
    /// fixed. It is also the practical ceiling — 63 white keys is around 20 px
    /// each on a full-width window, and narrower than that stops being a key.
    ///
    /// A consequence worth stating: a whole-octave window nine octaves wide that
    /// still fits inside MIDI tops out at B8 (119). Pitches above that cannot be
    /// windowed, and nothing is played up there — C9 is above the top note of
    /// every instrument that exists.
    static let maximum = 9
    /// What the pane opens at with no hardware in evidence.
    static let `default` = 3

    /// Highest pitch drawn for a given window, clamped to the top of MIDI.
    static func top(base: UInt8, octaves: Int) -> UInt8 {
        UInt8(min(127, Int(base) + max(1, octaves) * 12 - 1))
    }

    /// Snap a candidate base down to a C and clamp it so the whole window fits
    /// inside 0...127. A window whose top ran past 127 would draw keys that
    /// cannot exist, which is a key that is visible and unplayable.
    static func clampBase(_ candidate: Int, octaves: Int) -> UInt8 {
        let span = min(max(octaves, minimum), maximum)
        let highestBase = (128 - span * 12) / 12 * 12
        let snapped = candidate / 12 * 12
        return UInt8(max(0, min(highestBase, snapped)))
    }

    /// The smallest whole-octave window that contains `range`.
    ///
    /// Anchored to the C at or below the lowest pitch, because a keyboard that
    /// did not start on a C would be unreadable. When the range is wider than the
    /// cap the window slides UP to keep the top covered: the high evidence is the
    /// more recent reason to widen, and a player who has run off the bottom can
    /// still page down.
    static func window(containing range: ClosedRange<UInt8>) -> (base: UInt8, octaves: Int) {
        let low = Int(range.lowerBound) / 12 * 12
        let needed = Int(range.upperBound) - low + 1
        let octaves = min(max((needed + 11) / 12, minimum), maximum)
        if Int(range.upperBound) > low + octaves * 12 - 1 {
            // The cap bit. Slide up so the top pitch is inside the window.
            let base = (Int(range.upperBound) - octaves * 12 + 1 + 11) / 12 * 12
            return (clampBase(base, octaves: octaves), octaves)
        }
        return (clampBase(low, octaves: octaves), octaves)
    }
}
