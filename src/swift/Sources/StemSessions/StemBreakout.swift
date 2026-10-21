import SwiftUI

// MARK: - Stem breakout: identity, layout and solo policy (pure)
//
// The Stems tab shows ONE song, broken into its parts. That is a much harder
// constraint than the Studio timeline's, and a much more useful one: every
// stem starts at zero, every stem is the same length, and the set never grows
// while you are listening to it. Everything in this file exists because of
// that constraint —
//
//   * the whole song fits the width, so there is no zoom, no horizontal
//     scroll, and no ruler negotiation: one time axis, N lanes, one playhead;
//   * the lanes are fixed-height rows in a fixed-width grid, so a playhead at
//     x on lane 1 is the same instant as x on lane 4 without any arithmetic
//     per lane;
//   * "just the vocal" is a single click rather than four.
//
// Kept out of the view so all three are unit-testable without AVFoundation and
// without a window.

// MARK: - What kind of part is this?

/// Maps a stem's human name / file name onto the suite's stem taxonomy so the
/// Stems tab can colour a part the SAME as the Studio does.
///
/// This exists because the two surfaces disagreed. The Stems tab coloured rows
/// from a rotating eight-colour palette by ROW INDEX, so the vocal was purple
/// in a four-stem session and pink in a five-stem one, while the Studio has
/// always drawn vocals `StudioTokens.stemVocals` (#FF5FA2) because the stem
/// colours are suite-wide constants shared with Majik's DJ. Same four stems of
/// the same song, two different colour schemes, one screen apart.
///
/// `.imported` (grey) is the honest answer for a name we cannot classify — it
/// is what the Studio uses for audio that arrived from outside, and a grey lane
/// reads as "this is just a file" rather than miscolouring it as a drum part.
enum StemKindInference {

    /// Word fragments that identify each kind, in resolution order. Order is
    /// load-bearing: "bassdrum" and "kick drum" are DRUMS, so drums is tested
    /// before bass. Demucs' six-stem mode emits guitar and piano, which the
    /// four-stem taxonomy calls `other`.
    private static let table: [(kind: StudioStemKind, fragments: [String])] = [
        (.vocals, ["vocal", "vox", "voice", "acapella", "acappella", "sing", "lead"]),
        (.drums, ["drum", "percussion", "perc", "kick", "snare", "hat", "beat"]),
        (.bass, ["bass", "sub", "808"]),
        (.other, ["other", "instrumental", "instrument", "inst", "backing", "melody",
                  "guitar", "piano", "keys", "synth", "string", "horn", "pad"]),
    ]

    /// The kind of a stem, from what it is called. `displayName` wins because
    /// it is what the user (or the extract that made it) called the part;
    /// the file name is the fallback for a stem that was renamed to something
    /// unclassifiable but still lives in `..._vocals.wav`.
    static func kind(displayName: String, fileName: String = "") -> StudioStemKind {
        if let hit = kind(in: displayName) { return hit }
        if let hit = kind(in: fileName) { return hit }
        return .imported
    }

    private static func kind(in text: String) -> StudioStemKind? {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return nil }
        for entry in table where entry.fragments.contains(where: { lowered.contains($0) }) {
            return entry.kind
        }
        return nil
    }

    /// The badge printed on the lane header. Not `kind.rawValue`: the raw
    /// values are wire strings, and "imported" is not what a person calls a
    /// part they dragged in.
    static func label(_ kind: StudioStemKind) -> String {
        switch kind {
        case .vocals: return "Vocals"
        case .drums: return "Drums"
        case .bass: return "Bass"
        case .other: return "Other"
        case .imported: return "Audio"
        }
    }
}

// MARK: - Lane geometry

/// Fixed metrics for the breakout grid. Constants rather than a layout pass
/// because every lane MUST use the identical column widths — the moment two
/// lanes disagree by a point, the shared playhead stops being shared and the
/// view silently starts lying about where in the song you are.
enum StemBreakoutLayout {

    /// The lane header column: colour key, name, kind badge, Solo and Mute.
    ///
    /// Wider than `StudioTokens.trackHeaderWidth` (150) on purpose. The Studio's
    /// header carries a name and small toggles for someone sitting at a desk;
    /// this one carries the two controls the whole surface exists for, at a
    /// size meant to be hit from a sofa. 180 is what a 5-character stem name at
    /// 13 pt plus two 30 pt buttons needs without the name eliding.
    static let headerWidth: CGFloat = 180

    /// The trailing mix column: gain, level, pan.
    static let mixWidth: CGFloat = 176

    /// One lane. Three times the old 36 pt waveform strip: the waveform is the
    /// evidence that a part is playing, and at 36 pt on a 4K panel a snare is a
    /// smudge. See the header comment on `headerWidth` about viewing distance.
    static let laneHeight: CGFloat = 76

    /// The shared time ruler above the lanes — ONE ruler for the whole set,
    /// which is the affordance the fixed-length constraint buys.
    static let rulerHeight: CGFloat = 18

    /// Solo / Mute buttons. Square-ish and large; these are the controls a
    /// stem view is FOR.
    static let toggleWidth: CGFloat = 30
    static let toggleHeight: CGFloat = 24

    /// Level meter thickness (the master meter in the transport uses 5).
    static let meterHeight: CGFloat = 6

    /// Playhead x for a position in a lane of `width`. Clamped both ends so a
    /// seek past the end (or a zero-length session) cannot draw off-lane.
    static func playheadX(time: Double, duration: Double, width: CGFloat) -> CGFloat {
        guard duration > 0, width > 0 else { return 0 }
        let fraction = min(max(time / duration, 0), 1)
        return width * CGFloat(fraction)
    }

    /// Inverse of `playheadX` — where a click at `x` lands in the song.
    static func time(atX x: CGFloat, duration: Double, width: CGFloat) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        return min(max(Double(x / width) * duration, 0), duration)
    }

    /// Label interval for the shared ruler, in seconds. A 3:30 song at ~900 pt
    /// of lane wants a label every 30 s; a 20 s loop wants one every 5.
    /// Chosen from a fixed ladder so the labels never land on ugly numbers.
    static func rulerStep(duration: Double) -> Double {
        let ladder: [Double] = [5, 10, 15, 30, 60, 120, 300]
        // Aim for roughly 8 labels across the song.
        let ideal = duration / 8
        return ladder.first { $0 >= ideal } ?? ladder[ladder.count - 1]
    }
}

// MARK: - Solo policy

/// What clicking Solo on one stem should do to the WHOLE solo set.
///
/// The Studio timeline treats solo as a per-track toggle, which is right there:
/// an arrangement has arbitrarily many tracks and you build a solo set up over
/// several clicks. Here the set is four parts of one song, and the thing a
/// person wants ~every time is "let me hear JUST this" — which under a plain
/// per-stem toggle costs one click plus one un-click per other soloed stem, and
/// leaves you silently listening to vocals+bass when you meant vocals.
///
/// So a plain click is EXCLUSIVE (solo this, un-solo everything else) and
/// ⌥-click is additive (the DAW convention for "add to the solo set"), which
/// is the same pair of gestures Logic and Ableton offer, in the order that
/// suits a fixed part set. Clicking the only soloed stem clears the solo, so
/// the button is still a toggle and the way back is the same button.
///
/// Returns only the stems that actually CHANGE, so the caller can register one
/// undo step and skip a no-op entirely.
enum StemSoloPlan {

    struct Change: Equatable {
        let id: UUID
        let solo: Bool
    }

    static func changes(
        stems: [SessionStem],
        tapped tappedID: UUID,
        additive: Bool
    ) -> [Change] {
        guard let tapped = stems.first(where: { $0.id == tappedID }) else { return [] }

        if additive {
            return [Change(id: tappedID, solo: !tapped.solo)]
        }

        let soloed = stems.filter(\.solo).map(\.id)

        // Already the only soloed stem: the click means "stop soloing".
        if tapped.solo && soloed.count == 1 {
            return [Change(id: tappedID, solo: false)]
        }

        var out: [Change] = []
        if !tapped.solo {
            out.append(Change(id: tappedID, solo: true))
        }
        for id in soloed where id != tappedID {
            out.append(Change(id: id, solo: false))
        }
        return out
    }

    /// Human name for the undo step the changes above amount to. The action
    /// name is what appears in Edit ▸ Undo, so it has to describe the GESTURE
    /// ("Solo Drums") and not the N writes it expands into.
    static func actionName(changes: [Change], stemName: String) -> String {
        guard let tapped = changes.first else { return "Solo Stem" }
        return tapped.solo ? "Solo \(stemName)" : "Unsolo \(stemName)"
    }
}

/// What the Solo BUTTON does, end to end: plan the change to the set, then
/// commit it as one journalled undo step.
///
/// Lifted out of the view because a mutation check found the hole. Breaking the
/// button — making its action send nothing at all, or making it write each
/// stem's solo separately so ⌘Z walks back through three states nobody asked
/// for — left every test in this lane green, because the tests exercised
/// `StemSoloPlan.changes` and `StemSessionStore.applySoloPlan` while the code
/// that JOINS them lived in a private method on a SwiftUI view that no test can
/// reach. Planning correctly and committing correctly are worth nothing if
/// nothing calls both.
///
/// So the join is a function with a name, tested against a real store, and
/// `StemBreakoutWiringTests` pins that the button still calls it.
enum StemSoloAction {

    @MainActor
    static func apply(
        tapped stem: SessionStem,
        in stems: [SessionStem],
        sessionID: UUID,
        additive: Bool,
        store: StemSessionStore,
        undoManager: UndoManager?
    ) {
        let changes = StemSoloPlan.changes(stems: stems, tapped: stem.id, additive: additive)
        guard !changes.isEmpty else { return }
        store.applySoloPlan(
            changes,
            in: sessionID,
            actionName: StemSoloPlan.actionName(changes: changes, stemName: stem.displayName),
            undoManager: undoManager
        )
    }
}
