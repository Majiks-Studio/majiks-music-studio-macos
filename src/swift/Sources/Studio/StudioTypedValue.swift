import Foundation

// MARK: - Typing a number into the Studio
//
// WHY THIS EXISTS.
//
// Every numeric control in the mixer, the routing/FX pane and the instrument
// panel was DRAG-ONLY. `StudioKnob` and `StudioFaderControl` between them reach
// all 38 `FX_PARAM_KEYS` and the instrument's `DEVICE_PARAM_KEYS`, and the only
// way to move any of them was to put a pointer on a 30 pt circle and drag. The
// owner's words: "knobs are hard on a screen, we can still have them though".
//
// He is right, and it is worse than a preference. Nobody dials an EQ band to
// 2.5 kHz or a compressor threshold to −18 dB by dragging — a semitone of
// frequency is under a pixel of travel at the top of a 20 Hz–20 kHz range — and
// on a 4K TV at couch distance, which is where this product is actually used,
// a 30 pt knob is close to unhittable.
//
// So: keep the knob, add a typed value and arrows. This file is the part that
// has no SwiftUI in it — the same math / controller / view split the piano roll
// and the on-screen keyboard use, and for the same reason: everything a test
// needs to drive lives somewhere a test can import without a window.
//
// THE ONE CONVENTION, stated once and applied everywhere: the editable text is
// exactly what the control already PRINTS under itself. `format:` is not
// re-invented here — it is passed in, and the parser is written to read back
// every string the existing formatters produce ("C", "L40", "45%", "-inf",
// "+3.5 dB", "2500 Hz", "4.0 :1", "0.005 s"). A field a user has to retype in
// some other notation than the one on screen is a second convention, and two
// conventions is how "typed 2.5k, got 2.5 Hz" happens.

// MARK: - What kind of number this is

/// The unit a parameter is expressed in, which decides two things a range and a
/// format string cannot: how big ONE arrow press is, and how a typed string
/// becomes a number.
///
/// This is a KIND, not a suffix. `Hz` is here because a frequency does not step
/// additively — 1 Hz is a third of an octave at 20 Hz and inaudible at 10 kHz —
/// and `%` and `pan` are here because their DISPLAY domain (0…100, L/C/R) is
/// not their VALUE domain (0…1, −1…1). Getting either of those wrong produces a
/// control that appears to work and quietly writes the wrong number, which is
/// the defect class this whole epic exists to kill.
enum StudioParamUnit: String, Sendable, Hashable, CaseIterable {
    /// Decibels. Steps 1 dB, the smallest move most people can hear on a fader.
    case decibels
    /// Frequency in Hz. Steps by a SEMITONE, because that is the smallest
    /// musically meaningful move and it is the same size at every pitch.
    case hertz
    /// Milliseconds.
    case milliseconds
    /// Seconds — the instrument envelope's own unit. Accepts `ms` too.
    case seconds
    /// A 0…1 value shown as 0…100 %.
    case percent
    /// A compression ratio, printed `4.0 :1`.
    case ratio
    /// A −1…1 pan position shown as `L40` / `C` / `R40`.
    case pan
    /// A bare number with no unit: mix, Q, width, feedback, sustain.
    case plain

    /// The unit for an `StudioFxParamSpec.unit` string. ONE mapping for all 38
    /// `FX_PARAM_KEYS`, derived from the table the engine's own DSP rows are
    /// transcribed into — so a parameter added to that table gets sensible
    /// typing and stepping without anyone touching this file.
    static func forSpecUnit(_ unit: String) -> StudioParamUnit {
        switch unit.trimmingCharacters(in: .whitespaces).lowercased() {
        case "db", "dbtp", "dbfs": return .decibels
        case "hz", "khz": return .hertz
        case "ms": return .milliseconds
        case "s", "sec": return .seconds
        case "%": return .percent
        case ":1": return .ratio
        default: return .plain
        }
    }

    // MARK: Stepping

    /// One arrow press, in the parameter's own value domain.
    ///
    /// Frequency is deliberately absent from this switch — it has no additive
    /// step at all (see `stepped`). Everything else is derived from the RANGE
    /// rather than hardcoded per call site, so a new parameter cannot arrive
    /// with an arrow that moves 1/2000th of its travel.
    func step(in range: ClosedRange<Double>) -> Double {
        switch self {
        case .decibels: return 1
        case .ratio: return 0.1
        case .percent: return 0.01           // one percentage point
        case .pan: return 0.05               // five points of pan
        case .seconds: return 0.01           // 10 ms, on a 0…4 s envelope
        case .milliseconds:
            // Range-derived, because "ms" spans the chorus's 0…9 and the
            // delay's 1…2000 with the same suffix.
            if range.upperBound <= 10 { return 0.1 }
            if range.upperBound <= 200 { return 1 }
            return 10
        case .hertz:
            // Never used: `stepped` handles frequency multiplicatively. Kept
            // sane rather than fatal so a future caller cannot get a zero.
            return max(1, range.lowerBound)
        case .plain:
            let span = range.upperBound - range.lowerBound
            if span <= 4 { return 0.05 }     // mix, width, feedback, sustain
            if range.upperBound <= 100 { return 0.1 }   // Q
            return 1
        }
    }

    /// The value one arrow press away from `v`, clamped into `range`.
    ///
    /// Two properties matter more than the arithmetic:
    ///
    ///  1. It SNAPS TO THE GRID. From 0.37 with a 0.05 step, up is 0.40, not
    ///     0.42 — so repeated presses walk round numbers instead of carrying a
    ///     drag's arbitrary remainder forever.
    ///  2. It never STALLS. Rounding a semitone at 0.01 Hz, or grid-snapping a
    ///     value that is already on the grid, can both land back on the input;
    ///     an arrow that visibly does nothing reads as a broken control, so
    ///     both paths fall through to a guaranteed minimum move.
    func stepped(_ v: Double, by direction: Int, in range: ClosedRange<Double>) -> Double {
        guard direction != 0 else { return Self.clamp(v, into: range) }
        let start = Self.clamp(v, into: range)

        if self == .hertz {
            // A semitone. `pow(2, 1/12)` is the same ratio the keyboard uses,
            // so holding the arrow walks the parameter up the chromatic scale.
            let ratio = pow(2.0, 1.0 / 12.0)
            var next = Self.roundFrequency(direction > 0 ? start * ratio : start / ratio)
            if abs(next - start) < 1e-9 {
                next = start + Double(direction) * Self.frequencyGrain(start)
            }
            return Self.clamp(Self.tidy(next), into: range)
        }

        let s = step(in: range)
        let n = v / s
        // `n.rounded()` within a whisker of an integer means "already on the
        // grid", and float dust (0.35 / 0.05 == 6.999…) must not count as off
        // it — that dust is exactly what makes an arrow stall.
        let onGrid = abs(n - n.rounded()) < 1e-6
        let index = onGrid ? n.rounded() : (direction > 0 ? n.rounded(.down) : n.rounded(.up))
        return Self.clamp(Self.tidy((index + Double(direction)) * s), into: range)
    }

    // MARK: Reading a typed string

    /// Parse text the way this unit PRINTS it, in the parameter's own value
    /// domain. Returns nil for anything that is not a number — rubbish reverts,
    /// it is never read as zero.
    ///
    /// Deliberately strict about trailing junk: "12abc" is nil, not 12. A
    /// lenient prefix parse turns a typo into a silent write, which is worse
    /// than making the user retype.
    func parse(_ raw: String, in range: ClosedRange<Double>) -> Double? {
        var s = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            // Typographic minus and en-dash: what a copy-paste from anywhere
            // outside a code editor actually contains.
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
        guard !s.isEmpty else { return nil }

        switch self {
        case .decibels:
            // "-inf" is what a send at zero PRINTS. It has to read back, or
            // the one value a user most wants to retype is the one they cannot.
            if ["-inf", "-∞", "inf", "-infinity", "off", "-inf db"].contains(s) {
                return range.lowerBound
            }
            s = Self.strip(s, ["dbtp", "dbfs", "db"])
            return Self.number(s)

        case .hertz:
            let kilo = s.contains("k")
            s = Self.strip(s, ["khz", "hz", "k"])
            guard let n = Self.number(s) else { return nil }
            return kilo ? n * 1000 : n

        case .milliseconds:
            // "0.5 s" is a legal way to say 500 ms; "ms" must be stripped
            // BEFORE "s" or every "ms" loses only its tail.
            if s.contains("ms") { return Self.number(Self.strip(s, ["msec", "ms"])) }
            if s.hasSuffix("s") { return Self.number(Self.strip(s, ["sec", "s"])).map { $0 * 1000 } }
            return Self.number(s)

        case .seconds:
            if s.contains("ms") { return Self.number(Self.strip(s, ["msec", "ms"])).map { $0 / 1000 } }
            return Self.number(Self.strip(s, ["sec", "s"]))

        case .percent:
            return Self.number(Self.strip(s, ["%"])).map { $0 / 100 }

        case .ratio:
            return Self.number(Self.strip(s, [":1"]))

        case .pan:
            if ["c", "centre", "center", "0"].contains(s) { return 0 }
            var sign = 1.0
            if s.hasPrefix("l") { sign = -1; s.removeFirst() }
            else if s.hasPrefix("r") { s.removeFirst() }
            guard let n = Self.number(s) else { return nil }
            // Bare numbers are read as the PERCENTAGE the control prints, so
            // "40" is the same place as "R40". A raw −1…1 fraction would be a
            // second notation for one control.
            return sign * n / 100

        case .plain:
            return Self.number(s)
        }
    }

    // MARK: Helpers

    private static func strip(_ s: String, _ suffixes: [String]) -> String {
        var out = s
        for suffix in suffixes {
            out = out.replacingOccurrences(of: suffix, with: "")
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Strict: the WHOLE remaining string has to be a number.
    private static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != "-", t != "+", t != "." else { return nil }
        return Double(t)
    }

    static func clamp(_ v: Double, into range: ClosedRange<Double>) -> Double {
        guard v.isFinite else { return range.lowerBound }
        return Swift.min(range.upperBound, Swift.max(range.lowerBound, v))
    }

    /// Kill the float dust a grid multiply leaves behind (0.05 * 8 is
    /// 0.4000000000000001), so a committed value equals the number the user
    /// was shown rather than something that only prints the same.
    static func tidy(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

    /// How precisely a frequency is worth stating at that frequency. An LFO at
    /// 0.8 Hz needs hundredths; a 12 kHz shelf does not need units.
    static func roundFrequency(_ f: Double) -> Double {
        if f < 10 { return (f * 100).rounded() / 100 }
        if f < 1000 { return f.rounded() }
        return (f / 10).rounded() * 10
    }

    static func frequencyGrain(_ f: Double) -> Double {
        if f < 10 { return 0.01 }
        if f < 1000 { return 1 }
        return 10
    }
}

// MARK: - What happened when the user pressed Return

/// The result of committing a typed string. Four outcomes, all of them
/// VISIBLE — the requirement being that out-of-range input is clamped and shown
/// clamped, and rubbish reverts, neither silently accepted nor silently
/// dropped.
enum StudioTypedOutcome: Equatable, Sendable {
    /// In range, different from what is there: send it.
    case accepted(Double)
    /// Out of range: the clamped value is sent AND is what the field now shows,
    /// so the user sees where their number actually landed.
    case clamped(Double)
    /// Parsed to the value already in the engine: no command. This is what
    /// makes Return-then-blur ONE journal entry rather than two.
    case unchanged(Double)
    /// Not a number. The field reverts to the previous value; nothing is sent.
    case rejected

    /// The value to hand the command bus, or nil when nothing should be sent.
    var committedValue: Double? {
        switch self {
        case .accepted(let v), .clamped(let v): return v
        case .unchanged, .rejected: return nil
        }
    }

    /// What the field should read after this commit. nil means "put back what
    /// was there", which is the visible half of rejecting rubbish.
    var displayValue: Double? {
        switch self {
        case .accepted(let v), .clamped(let v), .unchanged(let v): return v
        case .rejected: return nil
        }
    }
}

/// The ONE place a typed string turns into a decision. No SwiftUI, no state:
/// the field calls this, and so does every test that proves the field.
enum StudioTypedEntry {

    /// - Parameters:
    ///   - current: engine truth (or the value under a live drag) — what the
    ///     field was showing before the edit.
    ///   - format: the control's OWN formatter. Used to decide "same value",
    ///     which is the honest definition here: if the committed number PRINTS
    ///     identically to what is already there, the user has not changed
    ///     anything and no journal entry should exist. Comparing raw doubles
    ///     instead would put a command on the bus every time someone clicked
    ///     into a field showing "0.0 dB" over an engine value of 0.037 and
    ///     clicked away again.
    static func outcome(
        text: String,
        unit: StudioParamUnit,
        range: ClosedRange<Double>,
        current: Double,
        format: (Double) -> String
    ) -> StudioTypedOutcome {
        guard let parsed = unit.parse(text, in: range) else { return .rejected }
        guard parsed.isFinite else { return .rejected }
        let clamped = StudioParamUnit.tidy(StudioParamUnit.clamp(parsed, into: range))
        if format(clamped) == format(current) { return .unchanged(clamped) }
        return abs(parsed - clamped) > 1e-9 ? .clamped(clamped) : .accepted(clamped)
    }
}
