import Foundation

// MARK: - The on-screen keyboard's held state
//
// Split out of StudioOnScreenKeyboard.swift so the surface has the same three
// parts the piano roll has: pure math (StudioKeyboardMath), a controller that
// can be driven without a view (here), and the view. Everything below is
// reachable from a test with no SwiftUI in the room.
//
// This owns nothing the engine owns. The authoritative "what is sounding" comes
// back on the snapshot; this tracks what THIS surface is holding down, so it can
// send the matching note-offs even if the engine is slow or absent — plus the
// two things a raw snapshot cannot give a human eye, both explained where they
// are defined: a minimum lit time, and a key window that fits the instrument
// actually plugged in.

/// Held state for the on-screen keyboard.
@MainActor
final class StudioKeyboardController: ObservableObject {
    /// Whether the keyboard pane is shown.
    @Published var isShown = false

    // MARK: Show on hardware play (discoverability)
    //
    // On any real project the pane starts hidden, and the only way back used
    // to be one small toolbar glyph — which read as "the keyboard was
    // removed". So: a hardware MIDI note arriving while the pane is hidden
    // SHOWS it. Hardware plays → keyboard appears is self-explaining, and it
    // never runs the other way (nothing here ever auto-hides).
    //
    // The rule for not fighting the user: the moment they hide the pane
    // themselves (the toolbar toggle), hardware notes stop auto-showing it
    // for the REST OF THE SESSION — not "once more", because the next note
    // often lands milliseconds after the hide, and reopening it even once
    // right then is the app overriding a choice it just watched them make.
    // The toggle still works, and a fresh session starts re-armed.

    /// True once the user has explicitly hidden the pane this session.
    private(set) var manuallyHiddenThisSession = false
    /// The last hardware-event seq adopted, so each event triggers at most
    /// once however many times the same snapshot is observed.
    private var lastHardwareEventSeq: Int?

    /// The toolbar toggle. Routing the gesture through here (rather than
    /// flipping `isShown` at the call site) is what lets a manual hide be
    /// told apart from an auto-show.
    func toggleShownByUser() {
        if isShown {
            releaseAll()
            manuallyHiddenThisSession = true
            isShown = false
        } else {
            isShown = true
        }
    }

    /// Adopt the CURRENT hardware event without acting on it. Called once when
    /// the surface appears, so an event that happened before Studio was even
    /// on screen cannot pop the pane open on arrival.
    func seedHardwareEvent(_ event: StudioMidiLastEvent?) {
        lastHardwareEventSeq = event?.seq
    }

    /// A snapshot's `midi.lastEvent` changed. A FRESH hardware noteOn while
    /// the pane is hidden shows the pane — unless the user manually hid it
    /// this session. Knob turns and CCs never trigger it, and nothing played
    /// on this surface can (screen keys are not MIDI-port events).
    func observeHardwareEvent(_ event: StudioMidiLastEvent?) {
        guard let event, event.seq != lastHardwareEventSeq else { return }
        lastHardwareEventSeq = event.seq
        guard event.type == "noteOn" else { return }
        guard !isShown, !manuallyHiddenThisSession else { return }
        isShown = true
    }
    /// Lowest C drawn.
    @Published private(set) var basePitch: UInt8 = StudioKeyboardOctave.defaultBase
    /// How many octaves the window spans.
    @Published private(set) var octaves: Int = StudioKeyboardSpan.default
    /// Velocity used by computer keys (a mouse gets its own, from click position).
    @Published var typingVelocity: Int = StudioKeyboardVelocity.default
    /// Pitches this surface is holding down (mouse and computer keys alike).
    @Published private(set) var held: Set<UInt8> = []

    /// Widen the window to cover any pitch that arrives from OUTSIDE this
    /// surface — which in practice means the keys of the MIDI instrument that is
    /// plugged in. On by default; see `observeSounding`.
    @Published var fitsToHardware = true

    /// Pitches to draw lit from the ENGINE, with the minimum lifetime applied.
    /// `lit` (this ∪ `held`) is what the view draws.
    @Published private(set) var enginePitches: Set<UInt8> = []

    /// The lowest and highest pitch ever received from outside this surface, or
    /// nil before anything has been played on hardware. Shown in the rail so the
    /// fit is visible rather than mysterious.
    @Published private(set) var learnedRange: ClosedRange<UInt8>?

    /// Wired by StudioRootView to the engine's one note path. `nil` on a build
    /// without the real engine, in which case the keyboard draws and responds but
    /// is honestly labelled as silent rather than pretending.
    var onNote: ((UInt8, Int, StudioNoteAuditionGate) -> Void)?

    var isWired: Bool { onNote != nil }

    /// Everything drawn lit: what the engine says is sounding, plus what this
    /// surface is holding (drawn from the local press so a click has no poll
    /// latency of its own).
    var lit: Set<UInt8> { enginePitches.union(held) }

    /// Highest pitch drawn.
    var topPitch: UInt8 { StudioKeyboardSpan.top(base: basePitch, octaves: octaves) }

    var window: ClosedRange<UInt8> { basePitch...max(basePitch, topPitch) }

    // MARK: Playing

    func press(_ pitch: UInt8, velocity: Int) {
        guard !held.contains(pitch) else { return }
        held.insert(pitch)
        onNote?(pitch, velocity, .on)
    }

    func release(_ pitch: UInt8) {
        guard held.remove(pitch) != nil else { return }
        onNote?(pitch, 0, .off)
    }

    /// Release everything. Called when the pane hides, the window loses focus, or
    /// the octave moves — any of which can otherwise strand a note-on with no
    /// matching note-off and leave a key droning.
    func releaseAll() {
        for pitch in held { onNote?(pitch, 0, .off) }
        held.removeAll()
    }

    // MARK: The visible range

    func shiftOctave(_ delta: Int) {
        // Moving the window under held fingers would make their note-offs
        // address pitches that are no longer under the pointer.
        releaseAll()
        basePitch = StudioKeyboardSpan.clampBase(
            Int(basePitch) + delta * 12, octaves: octaves)
    }

    /// Widen or narrow the window by whole octaves. Same release-first rule: a
    /// narrower window can pull a key out from under a finger.
    func setOctaves(_ count: Int) {
        let next = min(max(count, StudioKeyboardSpan.minimum), StudioKeyboardSpan.maximum)
        guard next != octaves else { return }
        releaseAll()
        octaves = next
        basePitch = StudioKeyboardSpan.clampBase(Int(basePitch), octaves: next)
    }

    /// Put the window back where it opens for someone with no MIDI gear.
    func resetRange() {
        releaseAll()
        octaves = StudioKeyboardSpan.default
        basePitch = StudioKeyboardOctave.defaultBase
    }

    // MARK: What the engine says is sounding

    /// A key the engine reported stays lit for at least this long.
    ///
    /// The snapshot poll runs at 30 Hz, so a key that goes down and comes up
    /// inside 33 ms can be entirely absent from every sample — and a key seen in
    /// exactly one sample flashes for one frame, which reads as nothing at all.
    /// Ordinary staccato playing is 60-120 ms, so without this the highlight is a
    /// flicker precisely when someone is playing fast. This is a floor on how
    /// long a seen key is DRAWN; it does not touch how long anything sounds, and
    /// it cannot conjure a key the poll never sampled. See the report: a note
    /// shorter than one poll interval remains invisible, and no unit test can see
    /// that — it needs a human and a real keyboard.
    static let minimumLitSeconds: TimeInterval = 0.09

    private var litUntil: [UInt8: Date] = [:]
    private var lastSounding: Set<UInt8> = []
    private var expiryTask: Task<Void, Never>?

    /// Adopt one snapshot's `sounding` set. Called from the pane whenever the
    /// snapshot's performance block changes.
    ///
    /// Two jobs, both deliberately driven from the ENGINE's set rather than from
    /// a parallel UI guess: light the keys, and — for pitches that did not come
    /// from this surface — widen the window so a 61-key controller's keys are all
    /// actually on screen.
    func observeSounding(_ sounding: Set<UInt8>, now: Date = Date()) {
        for pitch in sounding {
            litUntil[pitch] = now.addingTimeInterval(Self.minimumLitSeconds)
        }
        // LEARN THE INSTRUMENT. MIDI does not advertise a key count, so nothing
        // can be asked; but every pitch that arrives is proof that a key exists
        // there. `held` is subtracted because a pitch this surface is playing
        // says nothing about the hardware — and because a widen while a mouse is
        // down would move the key out from under the pointer.
        let external = sounding.subtracting(held)
        if !external.isEmpty {
            let low = external.min()!
            let high = external.max()!
            learnedRange = learnedRange.map {
                min($0.lowerBound, low)...max($0.upperBound, high)
            } ?? low...high
            if fitsToHardware, held.isEmpty, let learned = learnedRange,
               !(window.contains(learned.lowerBound) && window.contains(learned.upperBound)) {
                let fitted = StudioKeyboardSpan.window(containing: learned)
                basePitch = fitted.base
                octaves = fitted.octaves
            }
        }
        recomputeLit(sounding, now: now)
    }

    /// Drop expired latches and republish. Split out so a test can advance time
    /// by hand instead of sleeping.
    func pruneLit(now: Date = Date()) {
        recomputeLit(lastSounding, now: now)
    }

    private func recomputeLit(_ sounding: Set<UInt8>, now: Date) {
        lastSounding = sounding
        litUntil = litUntil.filter { $0.value > now }
        let next = sounding.union(litUntil.keys)
        if next != enginePitches { enginePitches = next }
        scheduleExpiry(now: now)
    }

    /// Wake once, at the moment the earliest latch runs out, to clear it. Without
    /// this the last key of a phrase stays lit forever: the poll stops delivering
    /// changes the instant nothing is sounding, so nothing would ever redraw.
    private func scheduleExpiry(now: Date) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let soonest = litUntil.values.min() else { return }
        let delay = max(0, soonest.timeIntervalSince(now))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000) + 2_000_000)
            guard !Task.isCancelled else { return }
            await self?.pruneLit()
        }
    }

    // MARK: Musical typing

    /// Handle one computer key. Returns true when the keyboard consumed it, so
    /// unrelated keys still reach the rest of the UI.
    @discardableResult
    func handleTyping(_ character: Character, isDown: Bool) -> Bool {
        if StudioMusicalTyping.isOctaveShift(character) {
            guard isDown else { return true }
            shiftOctave(Character(character.lowercased()) == StudioMusicalTyping.octaveUp ? 1 : -1)
            return true
        }
        guard let pitch = StudioMusicalTyping.pitch(for: character, basePitch: basePitch) else {
            return false
        }
        if isDown {
            press(pitch, velocity: typingVelocity)
        } else {
            release(pitch)
        }
        return true
    }
}
