import Foundation

// MARK: - Time model
//
// Musical time is integer ticks at 960 PPQ (02-ARCHITECTURE section 3: beat
// time as rational ticks, no float beat math). All snap/selection math runs
// on ticks; pixels only exist at the view edge.

enum StudioTick {
    /// Pulses per quarter note. Locked by 02-ARCHITECTURE section 3.
    static let ppq: Int64 = 960
}

struct StudioTimeSignature: Sendable, Equatable, Hashable {
    var beatsPerBar: Int
    var beatUnit: Int   // 4 = quarter, 8 = eighth

    static let fourFour = StudioTimeSignature(beatsPerBar: 4, beatUnit: 4)

    /// Ticks in one beat of this signature (a "beat" is the denominator unit).
    var ticksPerBeat: Int64 {
        StudioTick.ppq * 4 / Int64(beatUnit)
    }

    var ticksPerBar: Int64 {
        ticksPerBeat * Int64(beatsPerBar)
    }
}

// MARK: - Snapshot value types (mirror the read surface in 02-ARCH section 4:
// project.snapshot, transport.state, engine.stats, takes.list)

enum StudioStemKind: String, Sendable, CaseIterable, Codable {
    case vocals, drums, bass, other, imported

    /// The word for this material, in prose: the track header's badge, the
    /// VoiceOver summary, the hover text.
    ///
    /// Until this existed the kind was consumed EXACTLY once in the whole app —
    /// `StudioTokens.stemColor`, an 8 pt dot — so a project split into Vocals,
    /// Drums, Bass and Other showed the user four coloured dots and the word
    /// "Instrument" four times. A colour is not a name: nobody learns from a
    /// swatch which of two pink-ish dots is the vocal.
    ///
    /// `.imported` reads "Audio" rather than "Imported", because what the user
    /// needs to know is what the track HOLDS, not how it got here — the
    /// inspector's lineage panel owns provenance (`StudioClipOrigin`), and
    /// duplicating it in a 9 pt badge would say the same thing twice in the two
    /// places least able to spare the width.
    var label: String {
        switch self {
        case .vocals: return "Vocals"
        case .drums: return "Drums"
        case .bass: return "Bass"
        case .other: return "Other"
        case .imported: return "Audio"
        }
    }

    /// Whether this material is one PART of a song that was taken apart, rather
    /// than a whole recording standing on its own.
    ///
    /// The four stem kinds arrive TOGETHER, from one split, and are only
    /// meaningful next to each other — muting the Drums is a statement about
    /// the song the other three are also from. `.imported` is a track someone
    /// dropped in; it has no siblings. That is a real difference in what the
    /// row means, and it is why the badge is tinted per stem but neutral for
    /// an import.
    var isStem: Bool { self != .imported }
}

enum StudioSectionRole: String, Sendable, Codable {
    case neutral, verse, chorus, bridge
}

struct StudioSectionSnapshot: Identifiable, Sendable, Equatable {
    /// The ENGINE's section id, not a surrogate.
    ///
    /// This was a `UUID` the snapshot builder MINTED — `id: UUID()`, freshly on
    /// every poll — while `section.set` / `section.remove` address a section by
    /// the string id the engine holds (`Section { id: String, … }`). So
    /// "Remove Section" sent a UUID the engine had never seen, and the two
    /// spaces could never meet: unlike a track or a clip, there was no map to
    /// translate through, because nothing ever read the engine's id in the
    /// first place. Carrying the engine's own id is what makes the gesture
    /// addressable, and it also stops SwiftUI re-identifying every section on
    /// every snapshot.
    var id: String
    var name: String        // "INTRO", "VERSE 1", ...
    var startBar: Int       // 0-based
    /// Derived, not stored: the engine models a section as a START only, and
    /// its length is the distance to the next one. `section.set` has no length
    /// parameter for exactly that reason.
    var lengthBars: Int
    /// Derived from `name`, the same way the engine's readers derive it. Not a
    /// wire field — `section.set`'s schema has no `role`, and sending one was
    /// an `additionalProperties: false` violation.
    var role: StudioSectionRole
}

/// The eight colours the track header's swatch menu offers.
///
/// A TYPE rather than the eight bare strings it used to be, because
/// `track.setColor`'s contract is `"color": {"pattern": "^#[0-9A-Fa-f]{6}$"}`
/// and the menu was sending `"blue"`. Both parameter NAMES were right, so the
/// call site read as correct at every review — and the engine refused all eight
/// swatches, every time, silently. A free-form `String` in a slot the contract
/// constrains is a hole somebody has to remember to fill; this one stayed
/// unfilled for the whole life of the feature, so the hole is closed at the
/// type instead.
enum StudioTrackColor: String, CaseIterable, Sendable, Equatable {
    case blue, orange, green, purple, pink, yellow, teal, gray

    /// The wire value — exactly what `track.setColor`'s pattern accepts.
    var hex: String {
        switch self {
        case .blue:   return "#4C8DFF"
        case .orange: return "#FF9F0A"
        case .green:  return "#32D74B"
        case .purple: return "#BF5AF2"
        case .pink:   return "#FF6482"
        case .yellow: return "#FFD60A"
        case .teal:   return "#40C8E0"
        case .gray:   return "#8E8E93"
        }
    }

    /// What the menu row says.
    var label: String { rawValue.capitalized }

    /// The palette entry a stored colour names, or nil for a colour that came
    /// from somewhere else (an imported project, a future picker). Case
    /// insensitive because the pattern accepts either case.
    static func named(_ stored: String) -> StudioTrackColor? {
        allCases.first { $0.hex.caseInsensitiveCompare(stored) == .orderedSame }
    }
}

/// How a clip came to exist, as the inspector's lineage panel states it.
///
/// All four are now the export manifest's terms
/// (`provenance-manifest.schema.json` -> generated | imported | recorded |
/// authored), and the raw values are the manifest's wire strings, so the engine
/// hands this straight across in the snapshot's per-clip `origin`. `authored`
/// used to be a UI-only word the manifest had no equivalent of; it is a
/// first-class manifest term as of `fix/provenance-clip-origin`.
enum StudioClipOrigin: String, CaseIterable, Sendable, Equatable {
    /// Landed from a music model (a `gen.landed` record carries its hash).
    case generated
    /// Audio that arrived from outside this project.
    case imported
    /// Captured from an input: audio through record.stop, or a MIDI take
    /// played on a controller.
    case recorded
    /// Notes written here, in the piano roll. No asset, no capture, no model.
    case authored

    var label: String {
        switch self {
        case .generated: return "Generated"
        case .imported: return "Imported"
        case .recorded: return "Recorded"
        case .authored: return "Authored"
        }
    }
}

struct StudioClipSnapshot: Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var startTicks: Int64
    var lengthTicks: Int64
    /// Where this clip's window starts inside its source material. A leading
    /// trim or a split moves this, so waveforms stay put under edits.
    var sourceOffsetTicks: Int64 = 0
    var fadeInTicks: Int64 = 0
    var fadeOutTicks: Int64 = 0
    var gainDB: Double = 0
    var muted: Bool = false
    var generative: Bool    // drives the AI badge (shimmer rule)
    var waveformSeed: UInt64
    /// E1: a note-backed clip, not audio. Drives whether "Open in Piano Roll"
    /// is offered — a roll opened on an audio clip would draw an empty grid
    /// that is indistinguishable from a MIDI clip with no notes in it.
    var isMidi: Bool = false
    /// The engine's OWN classification, straight off the snapshot's per-clip
    /// `origin`. This is the same `classify_clip` the exported provenance
    /// manifest is built from, so what the inspector and the export preview say
    /// cannot drift from what the shipped artifact says. Nil only where the
    /// engine did not supply one (the mock engine, and any snapshot predating
    /// the field), which is what `origin` falls back for.
    var engineOrigin: StudioClipOrigin? = nil

    var endTicks: Int64 { startTicks + lengthTicks }

    /// How this clip came to exist. The engine's answer when it gave one.
    ///
    /// The fallback reads the two provenance bits a snapshot always carries, and
    /// cannot see the authored/recorded distinction — only the journal can, and
    /// only the engine has it. `isMidi` is the engine's `kind: "midi"`
    /// discriminator, and a note clip can only be reached through
    /// `clip.placeMidi`; there is no .mid file import into the timeline, so a
    /// note clip was necessarily written in this app and `imported` was false
    /// for it under any reading.
    var origin: StudioClipOrigin {
        if let engineOrigin { return engineOrigin }
        if generative { return .generated }
        return isMidi ? .authored : .imported
    }
}

/// What `addInstrumentTrack` produced: the new track, and the empty MIDI clip
/// on it that the piano roll opens onto.
struct StudioInstrumentTrackOutcome: Sendable, Equatable {
    var ok: Bool
    var trackID: UUID?
    var clipID: UUID?
    var message: String?
}

enum StudioTakeState: Sendable, Equatable {
    case rendered(seed: UInt64)
    case rendering
}

struct StudioTakeSnapshot: Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String        // "Take 1"
    var state: StudioTakeState
    var picked: Bool
}

struct StudioTakeLaneSnapshot: Identifiable, Sendable, Equatable {
    var id: UUID
    var regionStartTicks: Int64
    var regionLengthTicks: Int64
    var takes: [StudioTakeSnapshot]
}

// MARK: - Mixer + automation value types (L12)
//
// One typed mirror per piece of engine mixer/automation truth. The catalog
// commands mix.* / autopoint.* drive it; the snapshot reads it back. dB and
// pan match the catalog ranges (mix.gain -60..12, mix.pan -1..1, mix.eq freq
// 20..20000 / gain -24..24, mix.send 0..1).

/// v1 automation lane targets (catalog `autopoint.add` targets).
enum StudioAutoTarget: String, Sendable, Codable, CaseIterable, Hashable {
    case volume, pan

    /// Catalog wire value ("track.volume" / "track.pan").
    var wireName: String {
        switch self {
        case .volume: return "track.volume"
        case .pan: return "track.pan"
        }
    }

    var label: String { self == .volume ? "volume" : "pan" }
}

/// A destination send bus (catalog `mix.send` bus "a"/"b"; A = reverb, B = delay).
enum StudioSendBus: String, Sendable, Codable, Hashable {
    case a, b
}

/// Identifies one automation lane (a track + a target) for view-state such as
/// lane visibility.
struct StudioAutoLaneKey: Hashable, Sendable {
    var trackID: UUID
    var target: StudioAutoTarget
}

/// One authored automation breakpoint (value is dB for volume, -1...1 for pan).
struct StudioAutoPoint: Identifiable, Sendable, Equatable {
    var id: String          // engine point id (catalog `pointId`)
    var positionTicks: Int64
    var value: Double
}

enum StudioEqBandKind: Sendable, Equatable { case lowShelf, bell, highShelf }

/// One of the channel EQ's 4 bands (catalog `mix.eq` band 0-3). The band layout
/// mirrors the engine's EqBank: 0 low shelf, 1-2 bell, 3 high shelf.
struct StudioEqBand: Identifiable, Sendable, Equatable {
    var index: Int
    var freqHz: Double
    var gainDB: Double
    var q: Double

    var id: Int { index }
    var kind: StudioEqBandKind {
        switch index {
        case 0: return .lowShelf
        case 3: return .highShelf
        default: return .bell
        }
    }

    /// The engine's default band frequencies (timeline-core `EQ_DEFAULT_FREQS`).
    static let defaults: [StudioEqBand] = [
        .init(index: 0, freqHz: 80, gainDB: 0, q: 1),
        .init(index: 1, freqHz: 250, gainDB: 0, q: 1),
        .init(index: 2, freqHz: 2500, gainDB: 0, q: 1),
        .init(index: 3, freqHz: 8000, gainDB: 0, q: 1),
    ]
}

/// Per-track peak + block-RMS meter, dBFS with a -120 floor (silence).
struct StudioChannelMeter: Sendable, Equatable {
    var peakDB: Double
    var rmsDB: Double
    static let silent = StudioChannelMeter(peakDB: -120, rmsDB: -120)
}

/// Master meter: peak, block RMS, true peak, and positive dB of limiter gain
/// reduction. dBFS / dBTP, -120 floor.
struct StudioMasterMeter: Sendable, Equatable {
    var peakDB: Double
    var rmsDB: Double
    var truePeakDB: Double
    var gainReductionDB: Double
    static let silent = StudioMasterMeter(peakDB: -120, rmsDB: -120, truePeakDB: -120, gainReductionDB: 0)
}

/// Live audio-input meter (dBFS, mirrors StudioChannelMeter) plus capture
/// progress. Present only while an input stream is actually open (recording
/// OR opt-in record.inputListen). Arming alone never opens the mic, so this
/// is nil until one of those two acts. Per-channel meters let you tell which
/// mic is which on a multi-input interface before committing a take.
struct StudioInputMeter: Sendable, Equatable {
    var peakDB: Double
    var rmsDB: Double
    /// Engine-latched over indicator: stays true after a full-scale sample until
    /// the stream restarts or the user clears it. A one-frame flash is useless.
    var clipLatched: Bool = false
    /// Total frames captured so far (0 while listen-only).
    var capturedFrames: Int64
    /// Ring overflow count (0 on a healthy device); nonzero warns of dropouts.
    var dropped: Int
    /// The capture device's sample rate.
    var sampleRate: Int
    /// Discrete hardware channels currently being metered (empty on older engines).
    var channels: [StudioChannelMeter] = []
    static let silent = StudioInputMeter(peakDB: -120, rmsDB: -120, clipLatched: false, capturedFrames: 0, dropped: 0, sampleRate: 48_000)

    /// Seconds captured so far (for the transport's record timer).
    var capturedSeconds: Double { sampleRate > 0 ? Double(capturedFrames) / Double(sampleRate) : 0 }
}

/// ONE sound inside a sampler or a drum rack, as the snapshot reports it.
///
/// This is the model's `DeviceZone`, unchanged: `sourceID` is the SAME
/// content-addressed asset id a clip carries, and the UI never learns a file
/// path for it — only the engine's `loadedSources` read surface can say which
/// file a hash came from, and only while that asset is loaded.
struct StudioZoneSnapshot: Identifiable, Sendable, Equatable {
    /// Engine id, sent back verbatim on `device.zone.remove`.
    var id: String
    var sourceID: String
    /// The key the recording sounds at. A drum rack ignores it.
    var rootPitch: Int
    var loPitch: Int
    var hiPitch: Int
    var gainDB: Double = 0
    var pan: Double = 0

    /// A drum PAD is a zone that covers exactly one key — the engine refuses
    /// any other shape on a drum device, so this is a fact about the data and
    /// not a UI convention.
    var isSingleKey: Bool { loPitch == hiPitch }

    /// True when this zone answers every key on the keyboard: the common case
    /// the "load one sound" gesture creates, and the one the inspector labels
    /// differently because "0–127" means nothing to a beginner.
    var isFullRange: Bool { loPitch == 0 && hiPitch == 127 }
}

/// An instrument (E1/E2 `device.add`) on a track, as the snapshot reports it.
/// `id` is the ENGINE's string id — it goes back out verbatim on
/// `device.remove`, so it is never laundered through a UUID map.
struct StudioDeviceSnapshot: Identifiable, Sendable, Equatable {
    var id: String
    /// The E2 vocabulary: "synth" / "sampler" / "drum".
    var kind: String
    /// The device's source bindings, sorted by the engine's own `(loPitch, id)`
    /// order. Empty for a synth, which synthesizes and reads no audio — and
    /// NEVER empty for a live sampler or drum rack, because the engine refuses
    /// to compile one that has nothing to play.
    var zones: [StudioZoneSnapshot] = []

    /// The instrument's AUTHORED parameters — what it sounds like — keyed by
    /// the engine's own `DEVICE_PARAM_KEYS` token, which is the same token an
    /// automation lane addresses (`track.device.<id>.<key>`).
    ///
    /// SPARSE, and that is load-bearing rather than an optimisation: an absent
    /// key means "the DSP default", so a brand-new synth carries an EMPTY map
    /// and undoing the first `device.param.set` returns the key to absent
    /// rather than writing a default over it. The panel reads a missing key as
    /// `StudioInstrumentTone.dspDefaults`, never as zero.
    var params: [String: Double] = [:]

    /// Whether this instrument plays RECORDINGS rather than synthesizing.
    /// Drives every "load a sound" affordance: offering one on a synth would
    /// hand the user a refusal they cannot act on.
    var playsSamples: Bool { kind == "sampler" || kind == "drum" }

    /// Whether this instrument MAKES its own sound, and therefore has a tone to
    /// choose. The complement of `playsSamples` today, written as its own
    /// property rather than `!playsSamples` because the two answer different
    /// questions and a fourth device kind would not necessarily be both.
    var makesItsOwnSound: Bool { kind == "synth" }

    /// Whether the instrument panel has anything to show for this device.
    /// Until the tone controls landed this was `playsSamples`, which is why a
    /// synth track had NO route into the panel at all — the chip was not a
    /// button and the context menu had no "Edit Synth…" item.
    var hasAnEditablePanel: Bool { playsSamples || makesItsOwnSound }

    /// What the track header's instrument chip says. Title-case of the engine's
    /// own word — NOT a new vocabulary: the header, the context menu and the
    /// toasts must all call the thing what the engine calls it, or a person
    /// reading the menu cannot tell which chip it is talking about. An unknown
    /// kind shows verbatim rather than being laundered into "Instrument".
    var instrumentLabel: String {
        switch kind {
        case "synth": return "Synth"
        case "sampler": return "Sampler"
        case "drum": return "Drums"
        default: return kind.isEmpty ? "Instrument" : kind.capitalized
        }
    }
}

/// What a track is FOR, as distinct from what material is on it (`kind`).
///
/// Three states and not two, because "cannot take an instrument" and "does not
/// have one yet" are different facts about a track and the header has to draw
/// them differently. Collapsing them is the bug this type exists to keep dead.
enum StudioTrackRole: String, Sendable, Equatable, CaseIterable {
    /// Plays back a recording. The keys do not reach it.
    case audio
    /// Is played: it carries an instrument, or notes for one.
    case instrument
    /// Brand new. Neither yet, and free to become either.
    case empty
}

/// Why a track is in the project, when the answer is something the person did
/// not ask for by name.
///
/// This is NOT a taxonomy of every way a track can come to exist. It is the
/// list of tracks the app CREATED ON ITS OWN, which is exactly the list the app
/// owes the user a sentence about. A track someone made by pressing "add track"
/// carries no origin at all — absence is the honest shape, it is what every
/// project written before this existed decodes as, and it is what keeps the
/// header quiet about the ordinary case.
///
/// The four tracks "Open in Studio" builds and the clip "Keep" lands carry no
/// origin either, deliberately: those gestures plainly ask for what they make
/// and already say what they made. A note explaining a thing the user just
/// requested is noise wearing provenance's clothes.
///
/// The raw values are the snapshot's wire strings (`host.rs`
/// `TRACK_ORIGIN_*`), and the engine derives each from the journal — the
/// `actor` on `track.add`, or the `reason` on the transaction around it —
/// rather than from a flag anyone has to remember to set.
enum StudioTrackOrigin: String, CaseIterable, Sendable, Equatable {
    /// The app made this track because a key was pressed on a project that had
    /// no instrument to play. Nobody asked for a track; they asked for a sound.
    case played
    /// Add a Layer (Shift+R) puts its new part on a track of its own rather
    /// than on top of what is already there. Nobody asked for a track; they
    /// asked for a layer.
    case layered
    /// Importing a folder of stems gives every file after the first a track of
    /// its own, so the parts of one song stay separable. Nobody asked for four
    /// tracks; they asked for four files.
    case imported

    /// The one line the track header shows, forever, to explain a row nobody
    /// typed.
    ///
    /// Deliberately all the same shape — "Made when you …" — because the header
    /// is read at a glance, ten minutes later, by someone scanning a column of
    /// rows. A reader who has learnt one of these has learnt all three, and the
    /// only word that changes is the one that matters.
    ///
    /// Deliberately a fact about the past and not an instruction: the person is
    /// usually playing or importing when this appears, and a row that tells
    /// them to do something is an interruption in a small font.
    ///
    /// ⚠️ SHORT, and measured rather than judged. The header column is 150 pt
    /// wide and the line is drawn at 9.5 pt after an 8 pt glyph, which leaves
    /// room for about twenty-two characters. The first drafts here were "Made
    /// when you added a layer" and "Made when you imported stems", and the
    /// raster test caught what reading them could not: they overflowed the
    /// column, which pushed the CONTROL ROW ABOVE them sideways. That is the
    /// same failure mode as the "+ Instrument" bug that once truncated four
    /// stem names to two letters each — an explanation paid for out of the
    /// track name's width. `StudioSaysWhatItMadeTests` re-measures every one of
    /// these, so a longer wording fails rather than shipping a bent header.
    var note: String {
        switch self {
        case .played:   return "Made when you played"
        case .layered:  return "Made for a layer"
        case .imported: return "Made when you imported"
        }
    }

    /// The header glyph. One per case so the three lines are distinguishable
    /// without reading, and all three are SF Symbols 1 (macOS 11) so none of
    /// them renders as an empty box on the oldest machine this ships to.
    var symbolName: String {
        switch self {
        case .played:   return "pianokeys"
        case .layered:  return "square.stack.3d.up"
        case .imported: return "square.and.arrow.down"
        }
    }

    /// `StudioHelp` key for the hover explanation on that line.
    ///
    /// Spelled out rather than interpolated from `rawValue`, even though the
    /// two agree today. `StudioHelpTests.testEveryCatalogEntryIsAttachedToAControl`
    /// finds an unused help entry by looking for its id as a LITERAL in the
    /// sources, and an id that only ever exists at runtime is invisible to it —
    /// so an interpolated key would take three catalog entries out of the net
    /// that catches "this tooltip is attached to nothing" for everything else.
    var helpKey: String {
        switch self {
        case .played:   return "trackHeader.origin.played"
        case .layered:  return "trackHeader.origin.layered"
        case .imported: return "trackHeader.origin.imported"
        }
    }

    /// What the app SAYS at the moment the tracks appear, naming them.
    ///
    /// Separate from `note` on purpose, and the split is the whole design: the
    /// header answers "what is this row?" for as long as the project exists,
    /// and this answers "what just happened?" once and then fades. Neither can
    /// do the other's job, and both are derived from the same `origin`, so they
    /// cannot disagree about whether it happened.
    ///
    /// Takes the WHOLE list rather than one name, because a stem import makes
    /// several tracks in a single adoption and one sentence naming four rows is
    /// help where four sentences in a row is nagging.
    func announcement(namingTracks names: [String]) -> String {
        let list = StudioTrackOrigin.list(names)
        switch self {
        case .played:
            return "You played, and there was nothing to play it with — so \(list) was made " +
                   "for you, down in the arrangement. Keep playing; Cmd-Z takes it back."
        case .layered:
            return "The layer went onto a track of its own: \(list). Keeping it separate is " +
                   "what lets you mute it, move it or delete it without disturbing what was " +
                   "already there. Cmd-Z takes the track back."
        case .imported:
            let tracksWord = names.count == 1 ? "a track" : "tracks"
            return "Importing those stems made \(tracksWord) to hold them: \(list). Each file " +
                   "stays on its own row so you can balance them against each other. " +
                   "Cmd-Z takes them back."
        }
    }

    /// "A", "A and B", "A, B and C", "A, B, C and 2 more".
    ///
    /// Capped rather than complete: a toast is read in the two seconds before
    /// it fades, and a dozen names in it is the same as no names at all. The
    /// arrangement is where the full list lives, and every one of those rows is
    /// carrying `note` when the reader gets there.
    static func list(_ names: [String], showing limit: Int = 3) -> String {
        guard !names.isEmpty else { return "a new track" }
        if names.count <= limit {
            guard names.count > 1 else { return names[0] }
            return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        let shown = names.prefix(limit).joined(separator: ", ")
        let rest = names.count - limit
        return "\(shown) and \(rest) more"
    }
}

struct StudioTrackSnapshot: Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var kind: StudioStemKind
    var muted: Bool = false
    var soloed: Bool = false
    /// Record-enabled: the capture target for record.start (catalog track.arm).
    /// Arming does NOT open the microphone — that happens at record.start
    /// (or opt-in record.inputListen).
    var armed: Bool = false
    /// 0-based hardware input channel this track records from
    /// (`track.setInputChannel`). Default 0 = first mic on the interface.
    var inputChannel: Int = 0
    var volumeDB: Double = 0
    var pan: Double = 0     // -1...1
    var clips: [StudioClipSnapshot]
    var takeLane: StudioTakeLaneSnapshot?
    var hasVolumeAutomation: Bool = false
    /// Instruments on this track (engine `devices`, omitted-when-empty on the
    /// wire). Defaulted so existing constructors keep compiling; drives the
    /// header's "Remove Instrument" affordance.
    var devices: [StudioDeviceSnapshot] = []

    // Mixer + automation truth (L12). Defaulted so existing constructors and
    // the L8 landing path keep compiling; the engines fill them in.
    var eq: [StudioEqBand] = StudioEqBand.defaults
    var sendA: Double = 0
    var sendB: Double = 0
    var volumeAutomation: [StudioAutoPoint] = []
    var panAutomation: [StudioAutoPoint] = []
    var hasPanAutomation: Bool = false
    var meter: StudioChannelMeter = .silent
    /// Track header colour key (e.g. "blue", "orange") set via track.setColor.
    /// Empty string means the default (stem-based) colour.
    var color: String = ""
    /// Track row height in points, set via track.setHeight. 0 means the default.
    var height: Int = 0

    /// How this track came to exist, when the app is the one that made it.
    /// `nil` for every track a person created themselves, and for every engine
    /// that does not report it. Defaulted so existing constructors keep
    /// compiling.
    var origin: StudioTrackOrigin?

    /// The one line the header shows to explain a track nobody asked for, or
    /// `nil` when there is nothing to explain.
    ///
    /// On the SNAPSHOT, next to the fact it is derived from, and not inside the
    /// SwiftUI row — the same reason `instrumentChipLabel` and
    /// `accessibilitySummary` live here. A sentence computed inside a view body
    /// can only be checked by a human looking at a window, and the whole
    /// complaint this answers is that nobody was looking.
    ///
    /// Deliberately reads as a fact about the past, not an instruction: the
    /// person is playing when this appears, and a row that tells them to do
    /// something is an interruption wearing a small font.
    ///
    /// The sentences themselves live on `StudioTrackOrigin` next to the wire
    /// word each is derived from, so a new origin cannot be added without
    /// writing its line — the compiler asks for it.
    var originNote: String? { origin?.note }

    func automation(_ target: StudioAutoTarget) -> [StudioAutoPoint] {
        target == .volume ? volumeAutomation : panAutomation
    }

    /// What the track header's instrument slot shows: the chip's text, or `nil`
    /// when the slot is the "+ Instrument" affordance instead.
    ///
    /// A property on the SNAPSHOT rather than a private computed var inside the
    /// SwiftUI row, so the rule "the chip is present exactly when a device is"
    /// is testable without a view hierarchy. A chip wired to a constant would
    /// pass every screenshot and fail here.
    var instrumentChipLabel: String? {
        guard let first = devices.first else { return nil }
        let extra = devices.count - 1
        return extra > 0 ? "\(first.instrumentLabel) +\(extra)" : first.instrumentLabel
    }

    /// What this track IS, read off what it actually CARRIES.
    ///
    /// Deliberately NOT read off `kind`. `kind` is a guess the Swift side makes
    /// from the track's NAME (`RealStudioEngine.stemKind`) — the engine's
    /// project model has no track kind at all — so it flips when a user renames
    /// a track. Hanging behaviour on it would mean renaming "Bass" to "Low End"
    /// silently changed what the track is allowed to do. `kind` is fit to
    /// choose a colour and a word; it is not fit to gate an affordance.
    ///
    /// Clips and devices are engine truth, and they answer the question
    /// directly: a track with a recording on it plays that recording, and a
    /// track with notes or an instrument on it is played.
    var role: StudioTrackRole {
        // Audio first, and it is the strong test: a recording is the thing the
        // track exists to play back. A device stacked on top of one (the engine
        // permits it; nothing in this app creates it) does not turn a vocal
        // take into a playable instrument.
        if clips.contains(where: { !$0.isMidi }) { return .audio }
        // Notes count even with no device on the track. Removing the instrument
        // from a MIDI track leaves the notes behind, and that track is still an
        // instrument track — one that has gone silent, which is exactly the
        // state "+ Instrument" is the way back out of.
        if !devices.isEmpty || clips.contains(where: \.isMidi) { return .instrument }
        return .empty
    }

    /// How this track describes ITSELF, in one phrase: the badge's word, said
    /// in prose for the header's VoiceOver summary.
    ///
    /// On the SNAPSHOT and not inside the SwiftUI row, for the same reason
    /// `instrumentChipLabel` is: it is the one thing a blind user is told about
    /// what this row is, and a phrase computed inside a view body can only be
    /// checked by a human with a screen reader. The summary used to open with
    /// "no instrument" on every track — true of a vocal stem, and useless: it
    /// describes a track by something it was never going to have, and left a
    /// VoiceOver user no way to tell the vocal from the bass.
    var roleSummary: String {
        switch role {
        case .audio:
            // The stem / whole-recording distinction, spoken. "Vocals stem"
            // says the thing an "Audio audio track" reading could not: that
            // this row is one PART of a song and has siblings.
            return kind.isStem ? "\(kind.label) stem" : "audio track"
        case .instrument:
            return devices.isEmpty
                ? "instrument track, no instrument"
                : "instrument \(devices.map(\.instrumentLabel).joined(separator: " and "))"
        case .empty:
            return "empty track, no instrument"
        }
    }

    /// Whether an instrument on this track could ever make a sound.
    ///
    /// An audio track's clips are played back by the mixer; the keys do not
    /// reach them, and an instrument added here would be a device nothing ever
    /// triggers. Everything else — including a BRAND-NEW EMPTY TRACK — can host
    /// one, which is the load-bearing half: the whole "add an instrument and
    /// play it" path starts on a track with nothing on it, and a predicate that
    /// got this backwards would trade a cosmetic bug for a dead app.
    var canHostInstrument: Bool { role != .audio }

    /// True when playing the keys sounds NOTHING on this track AND an
    /// instrument would fix that. Drives the header's "+ Instrument" affordance
    /// and the context menu's Add item, so the two can never disagree about
    /// whether the track needs one.
    ///
    /// This was `devices.isEmpty` alone, and that conflated "has no instrument"
    /// with "wants one". Every imported stem has no devices and never wants
    /// any, so a song split into Vocals / Drums / Bass / Other offered "Add
    /// Synth" on all four — and the affordance ate enough of a 150 pt column
    /// that the names truncated to "Vo…", "Dr…", "Ba…", "Ot…". The only fully
    /// legible word on a vocal track was "Instrument".
    var needsInstrument: Bool { devices.isEmpty && canHostInstrument }
}

struct StudioTransportSnapshot: Sendable, Equatable {
    var isPlaying: Bool
    /// Position at `capturedAtHostTime`. While playing, the view interpolates:
    /// position = positionTicks + elapsed * ticksPerSecond(tempo).
    var positionTicks: Int64
    var capturedAtHostTime: TimeInterval
    var loopRegion: ClosedRange<Int64>?
    /// True while an input capture is running (record.start .. record.stop).
    var recording: Bool = false
    /// The track being captured onto while `recording`.
    var recordingTrackID: UUID?
    /// Privacy indicator: true when an input device stream is actually open
    /// (capturing OR opt-in listen). Arming alone leaves this false. The UI
    /// must show this — a DAW that opens the mic without saying so is a bug.
    var inputOpen: Bool = false
    /// True when opt-in record.inputListen is open (metering without landing).
    var inputListening: Bool = false
    /// True when the metronome click is on. ENGINE TRUTH, like `isPlaying` —
    /// the UI never keeps its own copy, so an agent, a MIDI binding and the
    /// button in the transport bar can never disagree about it.
    /// Defaulted so every existing constructor still compiles.
    var metronomeEnabled: Bool = false

    func interpolatedTicks(now: TimeInterval, tempoBPM: Double) -> Int64 {
        guard isPlaying else { return positionTicks }
        let ticksPerSecond = tempoBPM / 60.0 * Double(StudioTick.ppq)
        let elapsed = max(0, now - capturedAtHostTime)
        return positionTicks + Int64(elapsed * ticksPerSecond)
    }
}

struct StudioEngineStats: Sendable, Equatable {
    var callbackP95Millis: Double
    var underruns: Int
    var engineLabel: String   // "Mock engine" until L6 lands

    /// Metronome clicks the engine has SOUNDED since the stream opened.
    ///
    /// The click is deliberately kept out of the master bus, the meters and
    /// the capture tap so it can never print itself onto a take — which also
    /// means no meter on screen can ever show it. This number is the only
    /// thing in the app that can. It is diagnostic, not musical: if it climbs
    /// while you hear nothing, the click is being made and something between
    /// the engine and the speakers is eating it; if it does not climb, the
    /// engine was never asked to click.
    ///
    /// Defaulted so every existing construction site (and the mock engine,
    /// which has no device) stays valid and honest at zero.
    var metronomeClicks: Int = 0
    /// Frames the output device callback actually copied out of the render
    /// buffer. Zero while the engine is rendering silently on purpose (no
    /// audible opt-in), whatever the rest of these numbers say.
    var deviceFramesAudible: Int = 0
}

struct StudioMasterSnapshot: Sendable, Equatable {
    var volumeDB: Double = 0
    var lufsIntegrated: Double?
    var limiterCeilingDBTP: Double = -1.0

    // Limiter + loudness truth (L12). Defaulted for existing constructors.
    var limiterEnabled: Bool = false
    var limiterReleaseMs: Double = 50
    var lufsShortTerm: Double?
    /// Stereo phase correlation, -1...1 (nil when the master is silent).
    var correlation: Double?
    var meter: StudioMasterMeter = .silent
}

// MARK: - MIDI snapshot types (spec 6, 7.2)

struct StudioMidiControl: Sendable, Equatable {
    var type: String
    var channel: Int
    var number: Int?
}

enum StudioMidiTargetKind: String, Sendable, Codable {
    case command, builtin, sterling
}

struct StudioMidiTarget: @unchecked Sendable, Equatable {
    var kind: StudioMidiTargetKind
    var name: String?
    var params: [String: AnyHashable]?
    var instruction: String?
}

struct StudioMidiBinding: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    var match: StudioMidiControl
    var target: StudioMidiTarget
    var targetSummary: String?
    var enabled: Bool
    /// The controller port this binding belongs to (engine emits it per
    /// binding, spec 6). Used as the `device` when re-sending binding.set /
    /// binding.clear so multi-controller edits target the right overlay map.
    var port: String = ""
    /// True when this binding is on a NOTE and its port's role is `instrument`,
    /// so the key plays the instrument and this binding does NOT fire.
    ///
    /// Reported rather than hidden: a list that says "16 active bindings" while
    /// all 16 are being swallowed reads as a hardware fault, and sends someone
    /// hunting a cable.
    var suppressedByRole: Bool = false
}

struct StudioMidiPort: Identifiable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var connected: Bool
    var map: String?
    var mapKey: String?
    var source: String?
    var tested: Bool?
    var unsupportedReason: String?
    var override: String?
    /// What this port's KEYS do: "instrument" (the default — notes play the
    /// selected instrument track) or "control" (notes fire the map's bindings).
    /// See `midi.port.role.set`. Defaults to instrument when an older engine
    /// omits it.
    var role: String = "instrument"
}

struct StudioMidiMap: Identifiable, Sendable, Equatable {
    var id: String { key }
    var key: String
    var name: String
    var source: String
    var tested: Bool
    var bindingCount: Int
    var loadError: String?
}

struct StudioMidiLearnState: @unchecked Sendable, Equatable {
    var active: Bool
    var device: String?
    var ageSeconds: Double?
    var captured: [String: AnyHashable]?
    var current: [String: AnyHashable]?
}

struct StudioMidiLastEvent: Sendable, Equatable {
    var seq: Int
    var port: String
    var type: String
    var channel: Int
    var number: Int?
    var value: Int
}

struct StudioMidiSterlingItem: Sendable, Equatable {
    var seq: Int
    var instruction: String
    var bindingId: String
    var port: String
}

struct StudioSterlingState: Sendable, Equatable {
    var nextSeq: Int
    var pending: [StudioMidiSterlingItem]
}

struct StudioMidiSnapshot: Sendable, Equatable {
    var enabled: Bool
    var ports: [StudioMidiPort]
    var maps: [StudioMidiMap]
    var activeBindings: [StudioMidiBinding]
    var learn: StudioMidiLearnState
    var lastEvent: StudioMidiLastEvent?
    var sterling: StudioSterlingState?
}

/// The difference between HEARING and KEEPING, in the one place the UI can read
/// it from.
///
/// Everything played on an instrument is held in a bounded rolling buffer
/// whether or not anything was armed or recording, because people find out that
/// something was worth keeping only after they have played it. `keepableNotes`
/// is how much is in there; `studio_performance_keep` lands it.
struct StudioPerformanceSnapshot: Sendable, Equatable {
    /// Notes finished and keepable right now.
    var keepableNotes: Int
    /// Pitches whose keys are DOWN, ascending. What the on-screen keyboard and
    /// the roll's gutter light up.
    var sounding: [UInt8]
    /// Absolute tick of the earliest keepable note, nil when nothing is buffered.
    var startTicks: Int64?
    /// Absolute tick the buffered performance currently ends at.
    var endTicks: Int64?

    static let idle = StudioPerformanceSnapshot(
        keepableNotes: 0, sounding: [], startTicks: nil, endTicks: nil)

    var hasSomethingToKeep: Bool { keepableNotes > 0 }
}

/// A named marker at a bar position (a timeline landmark).
struct StudioMarker: Identifiable, Sendable, Equatable {
    /// The ENGINE's marker id (`Marker { id: String, … }`), for the same reason
    /// `StudioSectionSnapshot.id` is one: `marker.remove` addresses a marker by
    /// that string, and a minted `UUID` names nothing the engine holds.
    var id: String
    /// The engine's `label`. Called `name` here because that is what the ruler
    /// draws and what the person typed; `label` is the wire spelling.
    var name: String
    var bar: Int
}

struct StudioProjectSnapshot: Sendable, Equatable {
    var revision: UInt64
    var name: String
    var tempoBPM: Double
    /// Measured tempo confidence from the engine's landing analysis. Zero is
    /// the engine's explicit "could not detect" value, not a 120 BPM reading.
    var tempoConfidence: Double = 1
    /// The segmented map used to advance the playhead.
    var tempoMap: StudioTempoMap = .constant(bpm: 120)
    var timeSignature: StudioTimeSignature
    var key: String
    var lengthBars: Int
    var sections: [StudioSectionSnapshot]
    var tracks: [StudioTrackSnapshot]
    var transport: StudioTransportSnapshot
    var stats: StudioEngineStats
    var master: StudioMasterSnapshot
    /// Plain-language provenance summary for the empty inspector, e.g.
    /// "71% generated, 29% imported".
    var provenanceSummary: String
    /// Available audio input device names (for the record device picker).
    var inputDevices: [String] = []
    /// Live input meter + capture progress while recording; nil otherwise.
    var inputMeter: StudioInputMeter?
    /// MIDI state (spec 6). nil when the engine has no midi subsystem (older
    /// engine builds); the default keeps all existing constructors compiling.
    var midi: StudioMidiSnapshot?

    /// Measured routing-node (bus/group) meters, keyed by the engine's node id
    /// (E5 §8: `MeterBank` node slots, exposed on the host's meters read as
    /// `nodes`). Empty when the engine publishes none — an OLDER engine build,
    /// not "every bus is silent"; the routing pane draws no meter for an absent
    /// id rather than a fabricated silent one. The default keeps all existing
    /// constructors compiling.
    var nodeMeters: [String: StudioChannelMeter] = [:]

    /// What is SOUNDING right now versus what is KEEPABLE. Read from the engine's
    /// retro-capture buffer, which is the same buffer the audio came from — so a
    /// lit key means "this is making sound", not "we think we sent one".
    var performance: StudioPerformanceSnapshot = .idle

    /// Project markers (arrangement landmarks, distinct from sections).
    var markers: [StudioMarker] = []

    /// Which content-addressed assets are LOADED right now, and the file each
    /// came from: the engine's own `sources` map, exposed as a read.
    ///
    /// A `sourceID` is 64 hex characters. Nobody can read a drum pad labelled
    /// `9f3c1a…`, so this is how a bound sound gets a NAME. It is also how a
    /// MISSING one shows as missing: an id absent from this map is an asset the
    /// engine could not load, which is a hard compile error rather than
    /// silence — and the pad says so instead of looking bound.
    var loadedSources: [String: String] = [:]

    /// The file name to print for a bound sound, or nil when this build cannot
    /// know it. Deliberately nil rather than a hash: a hex string in the slot
    /// where a name belongs reads as a bug, and "Sound not found" is the honest
    /// thing to say about an asset that is not loaded.
    func sourceName(_ sourceID: String) -> String? {
        guard let path = loadedSources[sourceID], !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Ticks at which bar 1 begins (engine `project.setPhaseAnchor`,
    /// `project.schema.json:phaseAnchorTicks`). 0 is the v1 behaviour. A
    /// non-bar-aligned lead-in shifts EVERY bar line, and nothing downstream
    /// can reconstruct it, so it has to ride on the snapshot.
    var phaseAnchorTicks: Int64 = 0

    /// The one bar grid the arrangement draws, snaps and labels from. Same type
    /// the piano roll uses, so the two views cannot disagree about where bar 1
    /// is.
    var barGrid: StudioBarGrid {
        StudioBarGrid(timeSignature: timeSignature, phaseAnchorTicks: phaseAnchorTicks)
    }

    var lengthTicks: Int64 { Int64(lengthBars) * timeSignature.ticksPerBar }
}

enum StudioTempoTruth {
    static func messages(confidence: Double, timeSignature: StudioTimeSignature) -> [String] {
        var out: [String] = []
        if confidence <= 0 { out.append("Tempo not detected — grid at 120 BPM") }
        if timeSignature != .fourFour {
            out.append("Grid is 4/4 (v1); song requested \(timeSignature.beatsPerBar)/\(timeSignature.beatUnit)")
        }
        return out
    }
}

// MARK: - Commands
//
// Typed command surface for the UI. Each case maps to a catalog v1 name
// (engine/contracts/command-catalog.v1.json); L6's FFI layer serializes the
// same shapes. The UI never mutates a snapshot directly: it sends a command
// and adopts the next snapshot (DJ AppModel pattern).

/// The `.catalog` param names that carry a UI-minted `UUID` rather than an
/// engine-native id, and therefore have to be translated on the way to the
/// engine.
///
/// Named ONCE, here, in a file both builds compile, because the list is a
/// contract between three places that cannot see each other: the call sites in
/// `StudioViewModel` / `StudioInstrumentModel` that put a `uuidString` into a
/// `.catalog` param, `RealStudioEngine.resolvingUIIDs` which translates it, and
/// `StudioMockEngine` which reads it back as a UUID because the mock's own
/// track ids ARE those UUIDs. That last coincidence is why the translation
/// could go missing for the whole of the real build's life with every mock test
/// green — so `StudioShellMathTests` holds the `.catalog` call sites to this
/// list rather than to anyone's memory.
/// THE LIST WENT STALE THE FIRST TIME IT WAS WRITTEN, which is the reason it
/// now looks like this. It started as `[trackId, clipId]`, and a concurrent
/// lane routing `import.audio` through `.catalog` with the contract's own
/// `targetTrackId` was refused on the real engine — correct call site, short
/// list. A sweep of `command-catalog.v2.json` found four more keys naming
/// EXISTING objects that nothing translated, and one that must NEVER be
/// translated. So the completeness of this classification is no longer a thing
/// anybody remembers: `StudioCatalogIDCoverageTests` derives every `…Id`
/// parameter the catalog declares and fails by name if one is missing from all
/// three lists below.
enum StudioEngineIDParam {
    static let trackID = "trackId"
    static let clipID = "clipId"

    /// Params naming an EXISTING TRACK, resolved through `uuidTrack`.
    static let trackKeys = [trackID, "targetTrackId"]

    /// Params naming an EXISTING CLIP, resolved through `uuidClip`.
    static let clipKeys = [clipID, "clipIdA", "clipIdB", "contextClipId",
                           "referenceClipId", "targetClipId"]

    /// In the order the resolver walks them. Adding a name here is not enough
    /// on its own: it has to go in `trackKeys` or `clipKeys` so
    /// `resolvingUIIDs` knows which map to look it up in.
    static let uiMinted = trackKeys + clipKeys

    /// Every OTHER `…Id` parameter the catalog declares, and why the resolver
    /// leaves it alone.
    ///
    /// The reasons live here rather than in a test because they are the
    /// decision, not a check on it — and because one of them is load-bearing in
    /// a way that is easy to get backwards. Read `newClipId` before adding
    /// anything.
    static let notTranslated: [String: String] = [
        // ⚠️ THE ONE THAT MUST STAY UNTRANSLATED. `clip.duplicate` and
        // `clip.split` MINT this id UI-side for a clip that does not exist in
        // the engine yet, exactly as `track.add` mints `trackId`. There is
        // nothing to look up, and "completing" the list by adding it would make
        // both commands throw "that clip is no longer in the project" — the
        // duplicate and split gestures would stop working.
        "newClipId": "UI-minted for a clip the engine has not seen yet; there is nothing to resolve",
        "newNoteIds": "UI-minted ids for notes that do not exist yet, the note-editing twin of newClipId",
        "noteId": "note ids are minted UI-side and kept verbatim by the engine; the note seam owns them",
        "noteIds": "as noteId, in the batch form the note commands take",
        "deviceId": "minted UI-side at device.add and kept by the engine; never a track/clip surrogate",
        "zoneId": "minted UI-side at device.zone.add, like deviceId",
        "sourceId": "a content-addressed asset hash, not an object this app mints ids for",
        "pointId": "minted UI-side at autopoint.add and kept by the engine",
        "fxId": "an effect's own id in the routing graph, minted UI-side at fx.add",
        "nodeId": "a routing node's own id, minted UI-side at route.node.add",
        "edgeId": "a routing edge's own id, minted UI-side at route.connect",
        "markerId": "the engine's own marker id; the snapshot carries it verbatim, so it arrives native",
        "sectionId": "the engine's own section id; the snapshot carries it verbatim, so it arrives native",
        "takeId": "the engine's take id, read out of the takes list rather than minted here",
        "draftTakeId": "a take id from the generation surface, as takeId",
        "sourceTakeId": "a take id from the generation surface, as takeId",
        "requestId": "a generation request id, minted by the gen protocol and not an object in the project",
        "stemSessionId": "a stem-session id owned by the stems surface, not the timeline's id space",
        "txnId": "a transaction bracket's id; it names no object at all",
    ]
}

enum StudioEngineCommand: @unchecked Sendable, Equatable {
    case transportPlay
    case transportStop
    case transportSeek(ticks: Int64)
    case transportLoopSet(start: Int64, end: Int64)
    case transportLoopClear
    /// Turn the metronome click on or off. The enable flag stays a CATALOG
    /// command so an agent, a MIDI binding and the button all drive one verb;
    /// level and count-in are monitor state and go through `setMetronome`.
    case transportMetronome(enabled: Bool)

    case clipMove(clipID: UUID, toTrackID: UUID, toStartTicks: Int64)
    case clipTrim(clipID: UUID, newStartTicks: Int64, newLengthTicks: Int64)
    case clipSplit(clipID: UUID, atTicks: Int64)
    case clipDuplicate(clipID: UUID)
    case clipRemove(clipID: UUID)
    case clipFadeSet(clipID: UUID, fadeInTicks: Int64, fadeOutTicks: Int64)

    case trackMute(trackID: UUID, muted: Bool)
    case trackSolo(trackID: UUID, soloed: Bool)
    case trackArm(trackID: UUID, armed: Bool)
    /// Which hardware input channel this track records from (0-based).
    case trackSetInputChannel(trackID: UUID, channel: Int)
    /// Create a new track. Routes through the generic catalog bus (no new FFI,
    /// same path as record.*): the id is minted UI-side, so a fresh/empty
    /// project can auto-create a track to import or record onto. `index` is the
    /// insert position (append when it is past the end).
    case trackAdd(trackID: String, name: String, index: Int)
    /// Remove a track. The engine refuses while the track still has clips
    /// (track_not_empty), so the delete-track gesture removes the clips first,
    /// inside one txn — see StudioViewModel.deleteTrack.
    case trackRemove(trackID: UUID)
    /// Remove an instrument from a track. `deviceID` is the engine's string id
    /// straight off the snapshot (StudioDeviceSnapshot.id).
    case deviceRemove(trackID: UUID, deviceID: String)
    /// Put an instrument on a track. `deviceID` is minted UI-side (the device
    /// does not exist yet, exactly like `trackAdd`); `kind` is the E2
    /// vocabulary. A TYPED case rather than a `.catalog` envelope because the
    /// UI only has the track's Swift UUID and the engine needs its own id —
    /// resolving that is the routing layer's job, and it is where `deviceRemove`
    /// already does it.
    case deviceAdd(trackID: UUID, deviceID: String, kind: String)

    // Recording (L19). Transport-class session verbs; the take + clip that
    // recordStop lands is the journaled, undoable unit.
    case recordStart(trackID: UUID, deviceID: String?, startTicks: Int64?, punchOutTicks: Int64?)
    case recordRotate
    case recordStop
    case recordCancel
    /// Opt-in input open for metering without landing a take.
    case recordInputListen(enabled: Bool, deviceID: String?)

    case projectSetTempo(bpm: Double)
    case projectSetTimeSig(numerator: Int, denominator: Int)
    case projectSetKey(key: String)

    // Mixer (L12): every strip control is one journaled + undoable command.
    case mixGain(trackID: UUID, gainDB: Double)
    case mixPan(trackID: UUID, pan: Double)
    case mixEq(trackID: UUID, band: Int, freqHz: Double, gainDB: Double, q: Double)
    case mixSend(trackID: UUID, bus: StudioSendBus, amount: Double)
    case mixMasterGain(gainDB: Double)
    case mixLimiterSet(enabled: Bool, ceilingDB: Double, releaseMs: Double)

    // Automation (L12). autolane.show is a non-journaled view toggle; the
    // autopoint.* edits are journaled + undoable.
    case autolaneShow(trackID: UUID, target: StudioAutoTarget, visible: Bool)
    case autopointAdd(trackID: UUID, target: StudioAutoTarget, pointID: String, positionTicks: Int64, value: Double)
    case autopointMove(trackID: UUID, target: StudioAutoTarget, pointID: String, positionTicks: Int64, value: Double)
    case autopointRemove(trackID: UUID, target: StudioAutoTarget, pointID: String)
    case autolaneClear(trackID: UUID, target: StudioAutoTarget)

    /// Generic catalog envelope for config-plane verbs (midi.*). The typed cases
    /// stay for timeline/mixer verbs the UI builds from geometry; config verbs
    /// carry ready wire params (spec 7.2).
    ///
    /// ⚠️ A `.catalog` param that names a track or a clip must use one of
    /// `StudioEngineIDParam.uiMinted` and carry the UI's `UUID`. The real engine
    /// resolves exactly those keys into its own id space on the way out
    /// (`RealStudioEngine.resolvingUIIDs`); a param under any OTHER name goes to
    /// the engine verbatim and names a track it has never heard of.
    case catalog(name: String, params: [String: AnyHashable])

    /// Catalog v1 name for journal/palette parity.
    var catalogName: String {
        switch self {
        case .catalog(let name, _): return name
        case .transportPlay: return "transport.play"
        case .transportStop: return "transport.stop"
        case .transportSeek: return "transport.seek"
        case .transportLoopSet: return "transport.loop.set"
        case .transportLoopClear: return "transport.loop.clear"
        case .transportMetronome: return "transport.metronome"
        case .clipMove: return "clip.move"
        case .clipTrim: return "clip.trim"
        case .clipSplit: return "clip.split"
        case .clipDuplicate: return "clip.duplicate"
        case .clipRemove: return "clip.remove"
        case .clipFadeSet: return "clip.fade.set"
        case .trackMute: return "track.mute"
        case .trackSolo: return "track.solo"
        case .trackArm: return "track.arm"
        case .trackSetInputChannel: return "track.setInputChannel"
        case .trackAdd: return "track.add"
        case .trackRemove: return "track.remove"
        case .deviceRemove: return "device.remove"
        case .deviceAdd: return "device.add"
        case .recordStart: return "record.start"
        case .recordRotate: return "record.rotate"
        case .recordStop: return "record.stop"
        case .recordCancel: return "record.cancel"
        case .recordInputListen: return "record.inputListen"
        case .projectSetTempo: return "project.setTempo"
        case .projectSetTimeSig: return "project.setTimeSig"
        case .projectSetKey: return "project.setKey"
        case .mixGain: return "mix.gain"
        case .mixPan: return "mix.pan"
        case .mixEq: return "mix.eq"
        case .mixSend: return "mix.send"
        case .mixMasterGain: return "mix.master.gain"
        case .mixLimiterSet: return "mix.limiter.set"
        case .autolaneShow: return "autolane.show"
        case .autopointAdd: return "autopoint.add"
        case .autopointMove: return "autopoint.move"
        case .autopointRemove: return "autopoint.remove"
        case .autolaneClear: return "autolane.clear"
        }
    }
}

/// What a Keep actually did, and — the part that was missing — WHERE.
///
/// A Keep used to report only a note count. That is exactly enough information
/// to write a cheerful toast about a 56-note passage that landed at bar 1,076,
/// off screen, which is what happened: the transport had been rolling for about
/// 36 minutes and the take was stamped at the play head. Carrying the position
/// out of the engine is what lets the caller put the person's eyes on the notes
/// they just played.
struct StudioKeepOutcome: Sendable, Equatable {
    var noteCount: Int
    var startTicks: Int64 = 0
    var lengthTicks: Int64 = 0
    /// The engine moved the take back to the music because the position it was
    /// played at was past everything the project contains. Surfaced rather than
    /// silent: relocating someone's work without telling them is the same class
    /// of bug as putting it out of sight.
    var snapped: Bool = false
    /// Where the runaway clock said it was, when `snapped`.
    var playedAtTicks: Int64?

    var kept: Bool { noteCount > 0 }
}

struct StudioCommandResult: Sendable, Equatable {
    var ok: Bool
    var message: String?
}

// MARK: - Loading a sound into a sampler / drum rack
//
// Why this is not a `StudioEngineCommand` case.
//
// Every case above maps 1:1 onto ONE catalog command. This gesture is not one
// command: it is a file ingest (which mints the `sourceId` nothing else can
// produce) followed by `device.add` + `device.zone.add`, and the whole set has
// to be ONE undo step. The engine host does that bracketing — v1 transactions
// do not nest, so the UI cannot wrap `import.audio` itself — and it does it
// with the commands the catalog already has. Nothing new was added to the
// catalog (113) or to the MCP tool set (137).
//
// The other half of the reason is the empty state. A sampler with no zones is
// a HARD COMPILE ERROR in the engine, by design: an instrument that could only
// render silence is not a state the project is allowed to reach. So creating
// the instrument and binding its first sound cannot be two gestures, and this
// type is what makes them one.

/// One sound, and where on the keyboard it answers.
struct StudioSampleBinding: Sendable, Equatable {
    /// A local file. The picker's URL, a Finder drop, or — later — a vault
    /// asset downloaded to a cache; the engine only ever sees a path, so a
    /// remote library can be added without changing anything below this line.
    var sourcePath: String
    /// The key the recording sounds at. Playback rate is 2^((pitch-root)/12),
    /// so this is what puts a sampled instrument IN TUNE.
    var rootPitch: Int
    var loPitch: Int
    var hiPitch: Int
    var gainDB: Double?
    var pan: Double?

    /// The common case, and the easy path: one sound answering every key.
    static func acrossTheKeyboard(_ path: String, rootPitch: Int = 60) -> StudioSampleBinding {
        StudioSampleBinding(sourcePath: path, rootPitch: rootPitch, loPitch: 0, hiPitch: 127,
                            gainDB: nil, pan: nil)
    }

    /// One drum pad: exactly one key, which is what the engine enforces for a
    /// drum device (`loPitch == hiPitch`, refused loudly otherwise).
    static func pad(_ path: String, key: Int) -> StudioSampleBinding {
        StudioSampleBinding(sourcePath: path, rootPitch: key, loPitch: key, hiPitch: key,
                            gainDB: nil, pan: nil)
    }
}

struct StudioSampleBindRequest: Sendable, Equatable {
    var trackID: UUID
    /// An existing instrument to bind into, or nil to create one.
    var deviceID: String?
    /// "sampler" or "drum". Required when creating; ignored otherwise.
    var kind: String?
    /// Zones removed BEFORE the additions land, in the same undo unit — how a
    /// pad's sound is CHANGED without a moment where two sounds share a key.
    var removeZoneIDs: [String] = []
    var bindings: [StudioSampleBinding] = []
    /// What this undo step is called.
    var reason: String
}

struct StudioSampleBindOutcome: Sendable, Equatable {
    var ok: Bool
    var message: String?
    var deviceID: String?
    var kind: String?
    var createdDevice: Bool = false
    var zoneIDs: [String] = []

    static func failed(_ message: String) -> StudioSampleBindOutcome {
        StudioSampleBindOutcome(ok: false, message: message)
    }
}

// MARK: - Open in Studio (the L8 landing bridge)
//
// A finished song (a library/generated track) becomes a bar-aligned, stem-split
// session. The engine does analysis + separation + placement + lineage; the UI
// only supplies the song and its generation context.

struct StudioLandingRequest: Sendable, Equatable {
    /// Absolute path to the finished-song mix (WAV).
    var sourceAudioPath: String
    /// The generation prompt (recorded on every clip's lineage).
    var prompt: String
    /// Tag/declared BPM, if known. A tie-break hint only; the measured tempo
    /// is the grid (generated audio drifts 1.2-2.9% off its tag, per P0-A).
    var declaredBPM: Double?
    /// Declared key ("A minor" shape), if known.
    var key: String?
    /// Ordered section names parsed from the lyrics ([verse]/[chorus]/...).
    var sectionTags: [String]
    /// Generation seed / model, for lineage.
    var seed: Int?
    var genModel: String?
    /// Project display name (defaults to the track title).
    var projectName: String?
}

// MARK: - Open in Studio (the Stems-tab bridge)

/// A stem session (or one stem of one) on its way into the Studio.
///
/// Distinct from `StudioLandingRequest` on purpose. A landing hands the engine
/// a finished MIX and asks it to analyse, separate and place — none of which
/// applies here, because these files are ALREADY separated parts and running
/// htdemucs over a vocal stem to obtain a vocal stem would be absurd. This
/// request is just "put these files on their own tracks", which is the plain
/// `track.add` + `import.audio` pair the browser's double-click already uses.
struct StudioStemImportRequest: Sendable, Equatable {
    struct Stem: Sendable, Equatable {
        /// What to call the track. The stem's display name, not its file name:
        /// stems on disk are `1a2b3c4d_vocals.wav`, and a track called
        /// "1a2b3c4d_vocals" helps nobody.
        var name: String
        var path: String
    }

    /// The session these came from, for the status line.
    var sessionName: String
    var stems: [Stem]
}

// MARK: - Waveform tiles
//
// DJ WaveformView pattern: the engine renders peak arrays per zoom bucket,
// asynchronously; the UI draws arrays and never touches raw audio.

/// Tiles are keyed in SOURCE space (seed + source-tick tile index), not clip
/// space: a trim, split, or duplicate reuses the same tiles, and waveforms
/// stay put under edits.
struct StudioTileKey: Sendable, Hashable {
    /// The clip's waveform seed (identifies the source material).
    var seed: UInt64
    /// Zoom bucket index; bucket b covers ticksPerBin = baseTicksPerBin << b.
    var bucket: Int
    /// Tile index in source space: tile n covers source ticks
    /// [n * ticksPerTile, (n + 1) * ticksPerTile).
    var tileIndex: Int
}

struct StudioWaveformTile: Sendable, Equatable {
    var key: StudioTileKey
    /// Peak amplitude per bin, 0...1. Always `binsPerTile` bins.
    var peaks: [Float]
    var ticksPerBin: Int64
}

enum StudioTileScheme {
    /// Finest bucket: one bin per 1/8 beat at 960 PPQ.
    static let baseTicksPerBin: Int64 = StudioTick.ppq / 8
    static let binsPerTile = 256

    /// Pick the coarsest bucket that still gives >= ~1 bin per pixel.
    static func bucket(forPxPerTick pxPerTick: CGFloat) -> Int {
        var bucket = 0
        while bucket < 12 {
            let ticksPerBin = baseTicksPerBin << bucket
            if CGFloat(ticksPerBin) * pxPerTick <= 1.5 { bucket += 1 } else { break }
        }
        return bucket
    }

    static func ticksPerBin(bucket: Int) -> Int64 {
        baseTicksPerBin << bucket
    }

    static func ticksPerTile(bucket: Int) -> Int64 {
        ticksPerBin(bucket: bucket) * Int64(binsPerTile)
    }

    /// Tile indexes intersecting a source-space tick range.
    static func tileRange(bucket: Int, sourceTicks: Range<Int64>) -> ClosedRange<Int> {
        let perTile = ticksPerTile(bucket: bucket)
        guard sourceTicks.upperBound > 0, perTile > 0 else { return 0...0 }
        let lo = max(Int64(0), sourceTicks.lowerBound) / perTile
        let hi = max(Int64(0), sourceTicks.upperBound - 1) / perTile
        return Int(lo)...Int(max(lo, hi))
    }
}

// MARK: - Tick lattice -> engine sample lattice
//
// THE UNIT CONFLATION, and why this type exists rather than a cast at the call
// site.
//
// `StudioTileScheme` counts in TICKS: bucket b is `120 << b` ticks per bin at
// 960 PPQ, because the timeline is drawn in ticks and a tile has to keep its
// place under a tempo the user can change. `StudioHost::waveform` counts in
// SAMPLES: its `zoom` argument means `256 << zoom` samples per bin, because
// audio is samples and the engine has no view of the timeline. They are the
// same SHAPE — a base times a power of two — which is exactly why passing one
// through as the other compiled, ran, returned real peaks and looked plausible.
//
// They are not the same QUANTITY. At the owner's 130.125 BPM / 48 kHz one tick
// is 23.05 samples, so a bucket-2 bin is 11066 samples while a zoom-2 bin is
// 1024: a factor of 10.8, constant across buckets because both sides scale by
// the same power of two. The four tiles that cover a 3.5-minute clip therefore
// read the first 21.8 seconds of it and drew that across the whole clip. The
// arrangement showed the song's INTRO, stretched, for three and a half minutes
// — never blank, never obviously broken, just quieter and sparser than the
// music it claimed to be.
//
// So the conversion is named, pure and testable, and it lives HERE rather than
// in `RealStudioEngine` because `Sources/Engine` is excluded from the mock
// build and this arithmetic is the one part of the seam a mock-only gate can
// still check.
enum StudioEngineTileFetch {

    /// `agent_surface::host::WAVEFORM_MAX_BINS`. The engine clamps to this; we
    /// never ask for more, so a request is never silently truncated.
    static let engineMaxBins = 2048

    /// Samples per tick for a constant-tempo project — the v1 tempo model
    /// (`TempoMap::single`), and the only one `project.setTempo` can build.
    /// Mirrors `TempoMap::tick_to_frame`: frames = ticks * rate * 60 / (PPQ * bpm).
    static func samplesPerTick(sampleRate: Double, bpm: Double) -> Double {
        guard sampleRate > 0, bpm > 0 else { return 25 }
        return sampleRate * 60 / (bpm * Double(StudioTick.ppq))
    }

    /// The COARSEST engine zoom whose bin still fits inside one UI bin.
    ///
    /// Fitting inside matters: it makes every UI bin a true max over whole
    /// engine bins, so the drawn peak is the real peak of the span it covers
    /// and never a sample of a window wider than it draws. It also bounds the
    /// request — `samplesPerEngineBin` is within a factor of two of the UI bin,
    /// so a 256-bin tile is always 256...512 engine bins, well under the cap.
    static func zoom(forSamplesPerUIBin samplesPerUIBin: Double) -> Int {
        var z = 0
        while z < 16 && Double(256 << (z + 1)) <= samplesPerUIBin { z += 1 }
        return z
    }

    struct Plan: Equatable {
        var zoom: Int
        var samplesPerEngineBin: Double
        /// First engine bin to request. Engine bin 0 is the clip's source
        /// offset, not source tick 0, so this is already clip-relative.
        var startBin: Int
        var maxBins: Int
        /// Where this tile's first UI bin begins, in samples relative to the
        /// clip's source offset. Negative for the part of a tile that lies
        /// before the clip's origin.
        var firstSample: Double
    }

    static func plan(
        tileIndex: Int,
        binsPerTile: Int,
        samplesPerUIBin: Double,
        sourceOffsetSamples: Double
    ) -> Plan {
        let z = zoom(forSamplesPerUIBin: samplesPerUIBin)
        let perEngineBin = Double(256 << z)
        let first = Double(tileIndex) * Double(binsPerTile) * samplesPerUIBin - sourceOffsetSamples
        let last = first + Double(binsPerTile) * samplesPerUIBin
        let lo = max(0, Int((first / perEngineBin).rounded(.down)))
        let hi = max(lo + 1, Int((last / perEngineBin).rounded(.up)))
        return Plan(
            zoom: z,
            samplesPerEngineBin: perEngineBin,
            startBin: lo,
            maxBins: min(engineMaxBins, hi - lo),
            firstSample: first)
    }

    /// Reduce the engine's bins onto the UI's lattice by MAX.
    ///
    /// Max, not mean: a waveform exists to show transients, and averaging the
    /// engine's peaks would erase the one thing the drawing is for. Bins that
    /// fall before the clip's source origin, or past the end of what the engine
    /// returned, read zero — nothing is invented at either edge.
    static func resample(
        enginePeaks: [Float],
        plan: Plan,
        binsPerTile: Int,
        samplesPerUIBin: Double
    ) -> [Float] {
        var out = [Float](repeating: 0, count: binsPerTile)
        guard plan.samplesPerEngineBin > 0 else { return out }
        let base = Double(plan.startBin) * plan.samplesPerEngineBin
        for i in 0..<binsPerTile {
            let lo = (plan.firstSample + Double(i) * samplesPerUIBin - base) / plan.samplesPerEngineBin
            let hi = (plan.firstSample + Double(i + 1) * samplesPerUIBin - base) / plan.samplesPerEngineBin
            if hi <= 0 { continue }
            var j = max(0, Int(lo.rounded(.down)))
            let end = max(j + 1, Int(hi.rounded(.up)))
            var peak: Float = 0
            while j < end {
                if j < enginePeaks.count { peak = max(peak, enginePeaks[j]) }
                j += 1
            }
            out[i] = peak
        }
        return out
    }
}

// MARK: - Engine protocol
//
// The Swift-side seam. StudioMockEngine implements it now; L6's FFI-backed
// engine client implements the same protocol when it lands (the view model
// only knows this protocol).

protocol StudioEngineProtocol: Sendable {
    /// Latest snapshot, or nil when `ifNewerThan` is already current
    /// (change-conditional adoption, DJ pattern).
    func snapshot(ifNewerThan revision: UInt64?) async -> StudioProjectSnapshot?

    @discardableResult
    func send(_ command: StudioEngineCommand) async -> StudioCommandResult

    /// Metronome MONITOR state: the click's level, and an audible count-in.
    ///
    /// Not a `StudioEngineCommand` because it is not a catalog command — none
    /// of it is journaled, undoable or part of the project, and a bounce is
    /// bit-identical whether the click was on or off. It is the same family as
    /// `previewNote`: feedback, never an edit. The on/off flag still goes
    /// through `transport.metronome` so agents and MIDI bindings keep working.
    ///
    /// `countInBeats` sounds that many clicks starting NOW, accented on the
    /// first, whether or not the transport is rolling.
    func setMetronome(enabled: Bool?, levelDB: Double?, countInBeats: Int?) async

    /// Decode/analyze/import on the engine's background host queue. The UI
    /// never reads or mutates the project directly.
    func importAudio(path: String, trackID: UUID?, startTicks: Int64) async -> StudioCommandResult

    /// Load sounds into a sampler / drum rack — creating the instrument if it
    /// does not exist yet — as ONE journaled, undoable gesture.
    ///
    /// Not `send(_:)`, because this is not one catalog command: it is the asset
    /// ingest plus `device.add` + `device.zone.remove` + `device.zone.add`
    /// inside one txn bracket. See `StudioSampleBindRequest` for why that has
    /// to be atomic.
    func bindSamples(_ request: StudioSampleBindRequest) async -> StudioSampleBindOutcome

    /// Undo / redo the most recent journaled unit. Returns whether anything
    /// moved. Mixer + automation edits journal like every other command, so
    /// this reverses a fader move or an automation edit (L12 acceptance).
    @discardableResult
    func undo() async -> Bool
    @discardableResult
    func redo() async -> Bool

    /// Async peak tile fetch. Never blocks the UI thread; never raw audio.
    func waveformTile(_ key: StudioTileKey) async -> StudioWaveformTile?

    /// Create an instrument track (a track + a synth device + an empty MIDI
    /// clip) and hand back the ids, so the piano roll has something real to
    /// open onto.
    ///
    /// This exists because there was NO way to get from an empty project to a
    /// MIDI clip in the GUI at all: no Track menu, no right-click on the track
    /// area, nothing. A piano roll with no way to create the thing it edits is
    /// not usable, however good the roll is.
    ///
    /// Default implementation reports honest failure (see the protocol
    /// extension in StudioReviseModel.swift's neighbours), so an engine that
    /// cannot do it says so rather than appearing to succeed.
    func addInstrumentTrack(name: String, lengthTicks: Int64) async -> StudioInstrumentTrackOutcome

    /// Land a finished song as a bar-aligned stem session and make it the
    /// active project (L8 "Open in Studio"). The next snapshot is the landed
    /// session. Returns the result (ok + a message on failure).
    @discardableResult
    func openInStudio(_ request: StudioLandingRequest) async -> StudioCommandResult

    // MARK: Revise / Extend / Add-a-Layer (L9). Default impls in
    // StudioReviseModel.swift; the concrete engines override them.

    /// Generate N draft variants for a region (per scoped stem) and land them as
    /// candidate takes. The returned variants each carry the promotions to
    /// commit; the audition loop is the region with pre-roll.
    func revise(_ request: StudioReviseRequest) async -> StudioReviseOutcome

    /// Commit a chosen variant: promote its take(s) as one undo transaction.
    @discardableResult
    func commitRevise(_ promotions: [StudioPromotion], reason: String) async -> StudioCommandResult

    /// Re-render committed draft take(s) at the commit rung and swap in place
    /// (the draft/commit two-phase, background).
    @discardableResult
    func finalizeRevise(draftTakeIDs: [String]) async -> StudioCommandResult

    /// Discard an audition (takes stay as candidates in the Takes history).
    @discardableResult
    func discardRevise(takeIDs: [String]) async -> StudioCommandResult

    /// Extend a clip past its end: generate variant tails as candidate takes.
    func extendClip(clipID: UUID, addedSeconds: Double, instruction: String, variants: Int) async -> StudioGenOutcome

    /// Commit a chosen extend tail (crossfaded seam + section).
    @discardableResult
    func commitExtend(takeID: String, clipID: UUID) async -> StudioCommandResult

    /// Add a Layer (lego): generate an instrument that fits a context region on
    /// a prepared new track.
    func addLayer(instruction: String, regionStartTicks: Int64, regionEndTicks: Int64, contextClipID: UUID?, stem: StudioStemKind, variants: Int) async -> StudioGenOutcome

    /// Commit a chosen layer take onto its prepared track.
    @discardableResult
    func commitLayer(takeID: String, targetTrackID: String, regionStartTicks: Int64) async -> StudioCommandResult

    // MARK: Takes browser (L10). Default impls in StudioTakesModel.swift; the
    // concrete engines override them. These read `takes.list` and drive
    // `take.auditionMix` / purge, the same commands an agent uses.

    /// Every generative take in the project (the Takes browser list), each with
    /// its kind + joined lineage, optionally filtered (clip/request/kind/...).
    func takes(query: StudioTakesQuery) async -> [StudioTakeBrowserItem]

    /// Preview which stems of a take are audible while auditioning (per-stem
    /// mixing). Drives `take.auditionMix`; not a committed mutation.
    @discardableResult
    func auditionMix(takeID: String, stems: [String]) async -> StudioCommandResult

    /// Reclaim disk by purging candidate take audio (records stay as lineage).
    @discardableResult
    func purgeTakes(scope: StudioPurgeScope) async -> StudioPurgeResult

    /// Drag-to-timeline: use a take here by promoting it into the dropped-on
    /// clip (the same `take.promote` a commit runs).
    @discardableResult
    func placeTake(takeID: String, ontoClipID: UUID) async -> StudioCommandResult

    // MARK: Export + provenance (L13). Default impls in StudioExportModel.swift;
    // the concrete engines override them (RealStudioEngine routes export.* +
    // the manifest through the same command bus, so every export is journaled).

    /// Export a deliverable (master/stems/region) through the offline bounce:
    /// 24-bit WAV or AAC, optional loudness target, optional provenance manifest.
    func exportAudio(_ request: StudioExportRequest) async -> StudioExportOutcome

    /// Write the standalone AI-disclosure provenance manifest to `outputPath`.
    func writeManifest(outputPath: String) async -> StudioExportOutcome

    /// Publish the current master to majiks.online through the EXISTING publisher
    /// path (server-side cert minting, untouched); the manifest travels with it.
    @discardableResult
    func publishToMajiks(_ request: StudioPublishRequest) async -> StudioCommandResult

    // MARK: Routing + effects (E5)
    //
    // Two small reads the routing surface needs and nothing else does. Both have
    // a default that reports ABSENCE rather than fabricating an answer: an
    // engine that cannot address its own nodes must say so, because a guessed
    // `track.<id>` produces a refusal the user has no way to act on.

    /// The engine's OWN id for a UI track UUID, as it appears in the NodeRef
    /// wire grammar (`track.<id>`) that `route.connect` and `fx.add` address by.
    ///
    /// Named `routingTrackID` rather than `engineTrackID` on purpose: the
    /// FFI-backed engine already has a synchronous `engineTrackID(_:)` and an
    /// identically-named `async` requirement makes every existing call site
    /// ambiguous. This forwards to that one map — there is no second id map.
    func routingTrackID(_ id: UUID) async -> String?

    /// The routing DAG plus every insert chain (track, bus/group, master).
    ///
    /// Read separately from `snapshot` on purpose: `StudioProjectSnapshot` is
    /// the 30 Hz timeline/mixer read and routing changes at gesture rate, so
    /// widening it would make every poll carry a graph nothing was looking at.
    func routingState() async -> StudioRoutingState?
}

extension StudioEngineProtocol {
    func importAudio(path: String, trackID: UUID?, startTicks: Int64) async -> StudioCommandResult {
        StudioCommandResult(ok: false, message: "Audio import is unavailable in this engine.")
    }

    /// No id map: the surface reports that tracks are not addressable rather
    /// than inventing an id.
    func routingTrackID(_ id: UUID) async -> String? { nil }

    /// No routing read: the surface shows an empty graph AND says the engine
    /// did not publish one, which are different statements and must not be
    /// collapsed into "there is nothing here".
    func routingState() async -> StudioRoutingState? { nil }
}
