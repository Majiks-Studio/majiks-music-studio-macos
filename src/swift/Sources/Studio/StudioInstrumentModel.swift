import Foundation

// MARK: - Sampler / drum-rack facts, as pure functions
//
// The arithmetic behind the pad grid and the sampler card, factored out of the
// views so it is unit-testable without a view hierarchy. Nothing here talks to
// an engine; every rule it states is a rule the ENGINE enforces, restated in
// one place so the UI cannot offer a gesture the engine will refuse.

enum StudioDrumRack {
    /// The rack is sixteen keys IN A ROW. Not "sixteen pads anywhere": the
    /// engine's `DrumKit` is a fixed sixteen-slot grid whose slot is
    /// `pitch - base`, and `build_drum_kit` refuses a kit that spans wider
    /// rather than dropping the pads that do not fit. Mirrored from
    /// `render::dsp::drum::RACK_PADS`.
    static let padCount = 16

    /// General MIDI puts the kick on 36 and the ride on 51; 36..=49 is the
    /// bottom fourteen of that and fits the rack exactly, so this is the base a
    /// new rack starts at. Someone who has never used a DAW should get a
    /// standard kit layout without knowing what one is.
    static let defaultBaseKey = 36

    /// The keys a rack based at `baseKey` covers, low to high.
    static func keys(baseKey: Int = defaultBaseKey) -> [Int] {
        (0..<padCount).map { baseKey + $0 }
    }

    /// The base key for a set of already-bound pads: the lowest one, because
    /// that is what `build_drum_kit` uses. An empty set gets the GM default.
    static func baseKey(forBoundKeys keys: [Int]) -> Int {
        keys.min() ?? defaultBaseKey
    }

    /// Whether adding a pad on `key` keeps the whole kit inside one rack.
    /// The check the engine makes, made BEFORE the gesture, so the grid can
    /// simply not offer a key that would be refused.
    static func fits(newKey: Int, existingKeys: [Int]) -> Bool {
        guard (0...127).contains(newKey) else { return false }
        guard !existingKeys.contains(newKey) else { return false }
        let all = existingKeys + [newKey]
        guard let lo = all.min(), let hi = all.max() else { return true }
        return hi - lo < padCount
    }
}

extension StudioPitchName {
    /// `label` for an `Int` pitch, which is the shape everything on this path
    /// carries (the model's zone bounds are integers, not `UInt8`).
    ///
    /// An extension on the EXISTING type rather than a second naming helper:
    /// the pad grid and the piano roll gutter must print the same key the same
    /// way, and two independent name functions is exactly how they drift.
    static func name(_ pitch: Int) -> String {
        guard (0...127).contains(pitch) else { return "—" }
        return label(UInt8(pitch))
    }
}

// MARK: - What the synth SOUNDS like
//
// The synth has had four waveforms, a resonant low-pass and a full ADSR since
// E2. Every one of them was automatable through
// `track.device.<deviceId>.<paramKey>` and NONE of them was settable: no
// catalog command wrote `Device.params`, so the app's only instrument sound was
// `Waveform::Saw` — the harshest of the four — for everyone, permanently. The
// panel next door literally says "NOT a waveform editor".
//
// `device.param.set` is the command that fixes that. This is the vocabulary on
// top of it.
//
// NAMED SOUNDS FIRST, NUMBERS SECOND. The person this is for does not know what
// a sawtooth is and should not have to. He asked for "something nicer, like
// piano, so I can actually play something" — the answer to that is a button
// that says Electric Piano, not four sliders and a waveform enum. The raw
// controls are underneath for anyone who wants them.
//
// AND NOTHING HERE IS A PIANO. This app ships no instrument samples at all —
// the sounds vault is 13,971 assets, and every one of them is a drum hit, a
// loop or a stem: 5,943 one-shots (5,888 of them drums), 5,814 loops, 2,214
// stems, and not a single melodic instrument recording. (This comment used to
// say the vault "is 5,888 drum one-shots and stems", which read as the whole
// library and understated it by 8,083 — 5,888 is the drum one-shot SUBSET.
// `StudioInstrumentView` had it right.) So a real acoustic piano is not
// something a preset can be. "Electric Piano" is the honest name for a
// synthesized approximation of one, and the panel says so in words.

/// One named starting point: a set of `device.param.set` values.
struct StudioInstrumentPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// What it sounds like, for someone who has never used a DAW. Shown on
    /// hover, and carried into the help catalog.
    let blurb: String
    /// `DEVICE_PARAM_KEYS` -> value. A key that is ABSENT reads as the DSP
    /// default, because instrument params are sparse engine-side; every preset
    /// here writes the same seven keys so switching between two of them never
    /// leaves a stray value behind from the previous one.
    let params: [String: Double]

    /// The wire commands this preset IS. One `device.param.set` per key, sorted
    /// so the journal a preset writes is identical every time it is applied.
    func commands(trackID: UUID, deviceID: String) -> [StudioEngineCommand] {
        params.keys.sorted().map { key in
            .catalog(name: "device.param.set", params: [
                "trackId": trackID.uuidString,
                "deviceId": deviceID,
                "key": key,
                "value": params[key]!,
            ])
        }
    }

    /// Whether a device's stored params ARE this preset. Used to light the
    /// button that is currently in force — and only exact equality counts, so
    /// nudging one raw control below un-lights it rather than leaving a preset
    /// name attached to a sound that is no longer it.
    func matches(_ stored: [String: Double]) -> Bool {
        guard stored.count == params.count else { return false }
        for (k, v) in params {
            guard let s = stored[k], abs(s - v) < 1e-6 else { return false }
        }
        return true
    }
}

enum StudioInstrumentTone {
    /// THE preset table.
    ///
    /// ⚠️ MIRRORED, and the mirror is TESTED. The canonical values live in
    /// `engine/contracts/instrument-presets.v1.json`, which the Rust proof
    /// (`engine/agent-surface/tests/instrument_tone.rs`) renders through the
    /// real command bus to assert every one of these is an audibly distinct
    /// sound. `StudioInstrumentToneTests.testThePresetTableMatchesTheContract`
    /// reads that same file and fails if this table drifts from it by so much
    /// as a decimal place. Change the contract, then change this — never one
    /// alone.
    static let presets: [StudioInstrumentPreset] = [
        StudioInstrumentPreset(
            id: "electricPiano",
            name: "Electric Piano",
            blurb: "Bell-like and percussive. Loudest the instant you press the key, then it " +
                "fades on its own — like a struck key rather than a held note.",
            params: ["waveform": 3, "cutoff": 3800, "resonance": 0.1,
                     "attack": 0.002, "decay": 0.85, "sustain": 0.12,
                     "release": 0.35, "gain": -4]),
        StudioInstrumentPreset(
            id: "softPad",
            name: "Soft Pad",
            blurb: "Slow and warm. It swells in over about half a second and hangs on after " +
                "you let go, so a held chord becomes a bed for everything else.",
            params: ["waveform": 1, "cutoff": 1200, "resonance": 0.08,
                     "attack": 0.4, "decay": 0.6, "sustain": 0.75,
                     "release": 1.1, "gain": -10]),
        StudioInstrumentPreset(
            id: "pluck",
            name: "Pluck",
            blurb: "Short and bright, like a plucked string. Gone in a fifth of a second " +
                "however long you hold the key, so fast parts stay clear instead of turning " +
                "to mush.",
            params: ["waveform": 1, "cutoff": 3200, "resonance": 0.22,
                     "attack": 0.001, "decay": 0.2, "sustain": 0,
                     "release": 0.16, "gain": -6]),
        StudioInstrumentPreset(
            id: "bass",
            name: "Bass",
            blurb: "Dark and round, made for the bottom two octaves. The bright half of the " +
                "sound is filtered away so it sits under everything else instead of " +
                "fighting it.",
            params: ["waveform": 2, "cutoff": 700, "resonance": 0.18,
                     "attack": 0.004, "decay": 0.3, "sustain": 0.6,
                     "release": 0.12, "gain": -5]),
        StudioInstrumentPreset(
            id: "organ",
            name: "Organ",
            blurb: "Holds dead steady for as long as you hold the key, and stops almost the " +
                "moment you let go. No fade in, no fade out — the sound is either on or off.",
            params: ["waveform": 2, "cutoff": 5200, "resonance": 0.02,
                     "attack": 0.006, "decay": 0.006, "sustain": 1,
                     "release": 0.05, "gain": -9]),
    ]

    /// The preset a device's stored params are, or nil for "something else" —
    /// which includes a brand-new synth (no stored params at all) and any hand
    /// edit. Nil is the honest answer and the panel prints it as one.
    static func current(for stored: [String: Double]) -> StudioInstrumentPreset? {
        presets.first { $0.matches(stored) }
    }

    /// What a fresh synth sounds like before anyone has touched it, in words.
    /// Kept next to the presets because it is the answer to "which one am I on
    /// right now" when the answer is none of them.
    static let startingSound =
        "A soft, round tone — a triangle wave with a gentle fade. It is what a new instrument " +
        "starts on. Pick one of the sounds above to change it."

    // MARK: The raw controls
    //
    // The four waveforms, and the four envelope stages, in the vocabulary the
    // ENGINE uses (`DEVICE_PARAM_KEYS`), so a control here and an automation
    // lane drawn in the piano roll name the same parameter.

    /// `waveform` is a rounded index on the wire, not an enum — automation
    /// lanes carry f32. 0 sine, 1 saw, 2 square, 3 triangle, mirrored from
    /// `render::dsp::osc::Waveform::from_param`.
    static let waveforms: [(value: Double, name: String, blurb: String)] = [
        (0, "Soft", "One pure tone and nothing else. The quietest, roundest of the four."),
        (1, "Bright", "Every harmonic at once. The buzziest — good under a filter, harsh on its own."),
        (2, "Hollow", "Woody and hollow, like a clarinet. Sits between the other two."),
        (3, "Round", "Soft like the first but with a little more body. A good default."),
    ]

    static func waveformName(_ value: Double) -> String {
        waveforms.first { abs($0.value - value.rounded()) < 0.001 }?.name ?? "—"
    }

    /// Envelope: how a note starts, falls, holds and ends. `range` is the
    /// slider range; `unit` is what the number means to a reader.
    struct EnvelopeStage: Identifiable, Sendable {
        let id: String          // the DEVICE_PARAM_KEYS token
        let label: String
        let range: ClosedRange<Double>
        let unit: String
    }

    static let envelope: [EnvelopeStage] = [
        .init(id: "attack", label: "Fade in", range: 0...2, unit: "s"),
        .init(id: "decay", label: "Fall to", range: 0...4, unit: "s"),
        .init(id: "sustain", label: "Hold at", range: 0...1, unit: ""),
        .init(id: "release", label: "Fade out", range: 0...4, unit: "s"),
    ]

    /// The value a control shows when the device stores nothing for that key —
    /// the DSP defaults, mirrored from `render::dsp::instrument::
    /// InstrumentParams::default`. A slider that showed 0 for an unset key
    /// would be lying about what is being heard.
    static let dspDefaults: [String: Double] = [
        "waveform": 3, "cutoff": 12000, "resonance": 0.15,
        "attack": 0.005, "decay": 0.12, "sustain": 0.75,
        "release": 0.2, "gain": -6,
    ]

    static func value(_ key: String, in stored: [String: Double]) -> Double {
        stored[key] ?? dspDefaults[key] ?? 0
    }
}

enum StudioSampler {
    /// The root key a freshly loaded sound gets: middle C.
    ///
    /// It is a GUESS, and the UI says so, because nothing in a bare audio file
    /// declares what note it was recorded at. Guessing middle C means a sound
    /// loaded and played at middle C comes out at its original speed — the
    /// least surprising possible default — and the sampler card offers the
    /// control to correct it. Silently guessing and NOT offering the control is
    /// how a sampled instrument ends up permanently out of tune with the song.
    static let defaultRootPitch = 60

    /// The teaching sentence for the root control, kept next to the default it
    /// explains so the two cannot drift apart.
    static let rootExplanation =
        "The key this recording already sounds at. Play that key and you hear the file at " +
        "its original speed; higher keys play it faster and higher, lower keys slower and " +
        "lower. If the instrument sounds out of tune with the song, this is the number to fix."
}
