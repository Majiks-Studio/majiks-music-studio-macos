import SwiftUI

// MARK: - The Studio help layer
//
// Every control in the Studio says what it DOES, on hover, in words a person
// who has never opened a DAW already has.
//
// This exists because the same failure kept recurring: a feature shipped, was
// on screen, and was reported missing. The on-screen keyboard "reverted to an
// old version" (its toggle carried a QWERTY glyph). Deleting a track "was not
// possible" (it is a context menu). Adding an instrument "was not possible"
// (it is a labelled button in the toolbar). None of those were missing
// features; all of them were the control failing to say what it was. A tooltip
// is the cheapest possible fix for that class, and unlike a manual it is
// attached to the thing it explains.
//
// Three rules the catalog is held to by StudioHelpTests:
//
//  1. `teaching` says what the control DOES, not what it IS. "Solo" is not
//     help. "Hear only this track" is.
//  2. Where a DAW word is unavoidable (send, bus, tap, sidechain, LUFS) the
//     tooltip is where that concept gets taught, in one sentence. Assume the
//     reader has never used Ableton.
//  3. `teaching` never merely repeats `terse` or the on-screen label, and is
//     never empty. A help string that restates the glyph is worse than none:
//     it looks like coverage and teaches nothing.
//
// Coverage is a TEST, not a promise: StudioHelpTests scans the covered source
// files, and a Button / Toggle / Picker / Menu with neither a `.studioHelp`
// nor an explicit `// help-exempt:` marker fails the build.

// MARK: - The preference

/// How much the Studio explains itself.
///
/// The DEFAULT is `.teaching`, deliberately, and the reasoning is worth stating
/// because it is the whole point of the lane: the person who owns this product
/// cannot use a DAW. A default of "terse" would serve someone who already knows
/// what a pre-fader send is, i.e. the one reader who does not need help at all.
///
/// "Optional" is read here as a VERBOSITY choice rather than a plain on/off,
/// because macOS tooltips are already hover-delayed and unobtrusive — the thing
/// an experienced user actually objects to is a paragraph where a word would
/// do, not the existence of a tooltip. `.off` is still offered, because the ask
/// was literally "which we can make optional".
enum StudioHelpVerbosity: String, CaseIterable, Identifiable, Sendable {
    /// What the control does, plus the concept behind it. The default.
    case teaching
    /// The control's name and nothing else.
    case terse
    /// No tooltips. VoiceOver is NOT silenced (see `StudioHelpResolution`).
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .teaching: return "Explain everything"
        case .terse: return "Just the names"
        case .off: return "No tooltips"
        }
    }

    /// Shown next to the choice in the menu, so picking one is not itself a
    /// guess about what it does.
    var blurb: String {
        switch self {
        case .teaching: return "Hovering a control tells you what it does."
        case .terse: return "Hovering a control tells you its name only."
        case .off: return "Nothing appears on hover. VoiceOver still describes every control."
        }
    }

    static let `default` = StudioHelpVerbosity.teaching

    /// Versioned, so a future change of meaning gets a new key rather than
    /// silently reinterpreting a stored value.
    static let storageKey = "studio.helpVerbosity.v1"

    static func from(_ raw: String) -> StudioHelpVerbosity {
        StudioHelpVerbosity(rawValue: raw) ?? .default
    }
}

// MARK: - One entry

/// One control's help. `control` is what is printed on it (the glyph name, the
/// letter, the word), and exists so a coverage report can be read next to the
/// screen; `terse` is the control's NAME; `teaching` is what it does.
struct StudioHelpEntry: Identifiable, Hashable, Sendable {
    let id: String
    let control: String
    let terse: String
    let teaching: String

    init(_ id: String, control: String, terse: String, teaching: String) {
        self.id = id
        self.control = control
        self.terse = terse
        self.teaching = teaching
    }
}

/// What a control should show for a given verbosity.
///
/// `accessibilityHint` is NOT gated on the preference. A sighted user turning
/// tooltips off is saying "stop showing me these"; it is not a statement about
/// what VoiceOver should read, and silencing assistive technology as a side
/// effect of a visual preference would be a regression. So `.off` drops the
/// tooltip and keeps the teaching text on the accessibility hint.
struct StudioHelpResolution: Equatable, Sendable {
    /// nil = show no tooltip at all (never an empty one).
    var tooltip: String?
    var accessibilityHint: String
}

// MARK: - The catalog

enum StudioHelpCatalog {
    static func entry(_ id: String) -> StudioHelpEntry? { byID[id] }

    static func resolve(_ id: String, verbosity: StudioHelpVerbosity) -> StudioHelpResolution? {
        guard let entry = byID[id] else { return nil }
        return resolve(entry, verbosity: verbosity)
    }

    static func resolve(_ entry: StudioHelpEntry, verbosity: StudioHelpVerbosity) -> StudioHelpResolution {
        switch verbosity {
        case .teaching: return .init(tooltip: entry.teaching, accessibilityHint: entry.teaching)
        case .terse: return .init(tooltip: entry.terse, accessibilityHint: entry.teaching)
        case .off: return .init(tooltip: nil, accessibilityHint: entry.teaching)
        }
    }

    static let byID: [String: StudioHelpEntry] = {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }()

    // MARK: Toolbar (the strip along the top of the Studio)

    static let toolbar: [StudioHelpEntry] = [
        // Lists what is actually in the rail. It used to promise "files", which
        // was a fifth section whose rows could not be dragged and were not files
        // — `StudioBrowserPanesTests` now fails if this sentence and
        // `StudioBrowserView.Section` ever disagree again.
        .init("toolbar.browser.show", control: "sidebar.left",
              terse: "Show the browser",
              teaching: "Show the left panel: your songs, sounds, takes and stems, ready to drag onto the timeline."),
        .init("toolbar.browser.hide", control: "sidebar.left",
              terse: "Hide the browser",
              teaching: "Close the left panel and give the timeline the space."),
        .init("toolbar.import", control: "Import",
              terse: "Import audio",
              teaching: "Bring an audio file in from your disk and drop it onto the selected track."),
        .init("toolbar.instrument", control: "Instrument",
              terse: "Add an instrument track",
              teaching: "Make a new track with a playable sound on it, plus an empty clip to write notes in, and open the piano roll on it. This is how you start a song from nothing."),
        .init("toolbar.instrument.synth", control: "Synth",
              terse: "Add a Synth",
              teaching: "Add a track that makes its sound electronically, ready for notes in the piano roll."),
        .init("toolbar.instrument.sampler", control: "Sampler",
              terse: "Add a Sampler",
              teaching: "Pick one recording and play it across the keyboard at different pitches."),
        .init("toolbar.instrument.drumRack", control: "Drum Rack",
              terse: "Add a Drum Rack",
              teaching: "Pick recordings for separate drum pads, then play each hit from its own key."),
        .init("toolbar.pianoRoll.show", control: "pianokeys",
              terse: "Show the piano roll",
              teaching: "Open the note editor: a grid where each row is a pitch and each bar you draw is a note. This is where you write a melody by hand."),
        .init("toolbar.pianoRoll.hide", control: "pianokeys",
              terse: "Hide the piano roll",
              teaching: "Close the note editor. Nothing you wrote is lost."),
        .init("toolbar.routing.show", control: "Effects",
              terse: "Show effects",
              teaching: "Open the panel where you add EQ, reverb, delay and six other effects to any track, bus or the master, and where sound is sent from one place to another. This is the word Effects in the top strip."),
        .init("toolbar.routing.hide", control: "Effects",
              terse: "Hide effects",
              teaching: "Close the effects panel. Every bus, send and effect keeps working; only the editor goes away."),
        .init("toolbar.keys.show", control: "Keys",
              terse: "Show the on-screen keyboard",
              teaching: "Show a piano you can play with the mouse or your computer keys, so you can make a sound without owning any hardware. It also appears on its own when a MIDI keyboard starts playing."),
        .init("toolbar.keys.hide", control: "Keys",
              terse: "Hide the on-screen keyboard",
              teaching: "Put the on-screen piano away. It stays hidden until you ask for it again."),
        .init("toolbar.inspector.show", control: "sidebar.right",
              terse: "Show the inspector",
              teaching: "Show the right panel, which describes whatever you have selected: the project, a clip's history, or the bars you are about to revise."),
        .init("toolbar.inspector.hide", control: "sidebar.right",
              terse: "Hide the inspector",
              teaching: "Close the right panel and give the timeline the space."),
        .init("toolbar.help", control: "questionmark.circle",
              terse: "Tooltip detail",
              teaching: "Choose how much every control in the Studio explains itself when you hover it. Leave it on \"Explain everything\" until the app feels familiar."),
    ]

    // MARK: Transport (play, position, tempo, snap, export, generate)

    static let transport: [StudioHelpEntry] = [
        .init("transport.returnToStart", control: "backward.end.fill",
              terse: "Return to start",
              teaching: "Jump the play head back to the very beginning of the song. Nothing plays until you press Play."),
        .init("transport.rewind", control: "Back",
              terse: "Back one bar",
              teaching: "Move the play head back one bar. A bar is one group of beats — four of them in most songs — and it is the block the bar numbers along the top of the timeline are counting. Press Back again to keep stepping. To jump a long way at once, click or drag the white handle on the bar numbers."),
        .init("transport.fastForward", control: "Fwd",
              terse: "Forward one bar",
              teaching: "Move the play head forward one bar, so you can walk up to the part you want to hear. It keeps playing if the song is already playing. To jump a long way, click or drag the white handle on the bar numbers instead."),
        .init("transport.play", control: "play.fill",
              terse: "Play",
              teaching: "Start playing from where the play head is. The play head is the vertical line that moves across the timeline."),
        .init("transport.pause", control: "pause.fill",
              terse: "Pause",
              teaching: "Stop where you are. Pressing Play again carries on from this exact spot rather than the start."),
        .init("transport.stop", control: "stop.fill",
              terse: "Stop",
              teaching: "Stop playing and send the play head back to the beginning."),
        .init("transport.metronome.off", control: "metronome",
              terse: "Turn the click on",
              teaching: "A metronome is a steady click on every beat that you play along to so your timing stays even. Turn it on and you will hear a click on each beat, with a louder one on the first beat of every bar so you know where the bar starts."),
        .init("transport.metronome.on", control: "metronome",
              terse: "Turn the click off",
              teaching: "Stop the click. It is only ever a guide for you while you play — it is never recorded onto a track and never appears in a song you export."),
        .init("transport.metronome.level", control: "chevron.down",
              terse: "How loud the click is",
              teaching: "Set the click quieter or louder so it sits under what you are playing without getting lost. This changes only what you hear, never the song itself."),
        .init("transport.record", control: "red dot",
              terse: "Record",
              teaching: "Capture what you play onto the track you armed. Arm a track with the round red button on its header first."),
        .init("transport.record.blocked", control: "red dot",
              terse: "Record (no armed track)",
              teaching: "Nothing is set up to record onto yet. Press the round red button on a track's header to arm it, then this lights up."),
        .init("transport.position", control: "POSITION",
              terse: "Play head position",
              teaching: "Where the play head is, as bar.beat.division. Bar 9, beat 1 reads 9.1.0 — musicians count in bars, not minutes. To move it, press Back or Fwd for one bar, or click the bar numbers at the top of the timeline (drag the white handle to scrub)."),
        .init("transport.volume", control: "VOLUME",
              terse: "Master volume",
              teaching: "How loud the whole mix is. Drag the short bar, or double-click it to reset to zero. Every track still has its own fader under MIXER at the bottom — this one is the last step before the speakers."),
        .init("transport.bpm", control: "BPM",
              terse: "Tempo",
              teaching: "The song's speed, in beats per minute. 60-80 is a slow ballad, 90-120 is pop or rock, 120-140 is dance. Click the number and type a new value; every edit is undoable."),
        .init("transport.key", control: "KEY",
              terse: "Musical key",
              teaching: "The set of notes the song is built from. Major sounds bright, minor sounds darker. It is detected from the audio when a song is opened here. Click the text and type a new key; every edit is undoable."),
        .init("transport.timeSignature", control: "TIME",
              terse: "Time signature",
              teaching: "How many beats are in a bar. 4/4 is nearly all pop, rock and electronic music; 3/4 is a waltz; 6/8 is a ballad or a jig. Click it to choose a different time signature; every change is undoable."),
        .init("transport.snap", control: "Snap",
              terse: "Snap division",
              teaching: "What clips and edits line up to when you drag them. Set it to Beat and things land on beats instead of anywhere; Bar is coarser, 1/16 is finer, and Off is free placement."),
        .init("transport.follow", control: "arrow.right.to.line",
              terse: "Follow the play head",
              teaching: "Scroll the timeline along with the play head while the song plays, so the moment being played stays on screen."),
        .init("transport.loop.off", control: "repeat",
              terse: "Repeat a section",
              teaching: "Make a stretch of the song play over and over so you can practise or play along to it. Press this and it loops the bars you have selected — or, with nothing selected, the section the play head is sitting in. You can also draw a loop by dragging in the thin strip just under the bar numbers."),
        .init("transport.loop.on", control: "repeat",
              terse: "Stop repeating",
              teaching: "A loop is running: the play head jumps back to the start of it every time it reaches the end. Press this to turn the loop off and let the song play straight through. Nothing you recorded or edited is affected either way."),
        .init("transport.meters", control: "master meter",
              terse: "Master output level",
              teaching: "How loud the finished mix is right now. The filled body is the average level and the thin white line is the loudest recent moment. Green is fine; when the line reaches the red at the top it is too loud and will distort, so pull the master fader down. This is one bar, not two, because the engine reports one number for the whole mix rather than a separate left and right — an empty bar with no fill means the engine has not reported a level at all yet."),
        .init("transport.engine", control: "engine",
              terse: "Audio engine status",
              teaching: "Health of the audio engine: which one is running, how long it takes to fill a buffer, and how many times it failed to (underruns). Underruns are what clicks and dropouts sound like. With the metronome switched on this also counts the clicks the engine has actually sounded — the click is kept out of the meters on purpose so it can never land in a recording, so this number is the only way to see it. If it is climbing and you hear nothing, the sound is being made and something after the engine is swallowing it."),
        .init("transport.export", control: "square.and.arrow.up",
              terse: "Export",
              teaching: "Write the song out as an audio file — the whole mix, the separate stems, or just the bars you selected — with a manifest that discloses what was AI generated."),
        .init("transport.generate", control: "Generate",
              terse: "Generate",
              teaching: "Make new music with a model. In this build generation lives on the Create tab; the Studio timeline wires into it in a later one."),
    ]

    // MARK: Piano roll toolbar (the note editor)

    static let pianoRoll: [StudioHelpEntry] = [
        .init("pianoRoll.tool", control: "arrow / pencil",
              terse: "Select or Draw",
              teaching: "Arrow picks up notes that already exist; pencil draws new ones. Press B to swap between them without leaving the mouse."),
        .init("pianoRoll.grid", control: "Grid",
              terse: "Note grid",
              teaching: "The smallest note length you can draw or move to. 1/8 gives you eighth notes. Hold Command while dragging to ignore it for one move; [ and ] step it."),
        .init("pianoRoll.zoomOut", control: "minus.magnifyingglass",
              terse: "Zoom out",
              teaching: "See more bars at once. Nothing about the music changes, only how much of it fits on screen."),
        .init("pianoRoll.zoomIn", control: "plus.magnifyingglass",
              terse: "Zoom in",
              teaching: "See fewer bars, bigger. Zoom in when notes are too small to grab."),
        .init("pianoRoll.shorterRows", control: "arrow.down.and.up",
              terse: "Shorter rows",
              teaching: "Squeeze the pitch rows so more of the keyboard range fits on screen at once."),
        .init("pianoRoll.tallerRows", control: "arrow.up.and.down",
              terse: "Taller rows",
              teaching: "Make the pitch rows taller so individual notes are easier to hit with the mouse."),
        .init("pianoRoll.undo", control: "arrow.uturn.backward",
              terse: "Undo the last note edit",
              teaching: "Take back the last thing you did to the notes. Safe to lean on: every edit in here is undoable."),
        .init("pianoRoll.redo", control: "arrow.uturn.forward",
              terse: "Redo the note edit",
              teaching: "Put back the edit you just undid."),
        .init("pianoRoll.duplicate", control: "square.on.square",
              terse: "Duplicate the selected notes",
              teaching: "Copy the selected notes and drop the copy straight after them. This is how a one-bar pattern becomes a four-bar one."),
        .init("pianoRoll.delete", control: "trash",
              terse: "Delete the selected notes",
              teaching: "Remove the selected notes. Undo brings them back."),
        .init("pianoRoll.quantize", control: "align.horizontal.left",
              terse: "Quantize the timing",
              teaching: "Nudge the selected notes onto the grid so they land in time. Amount decides how far: 100% is dead on the beat and can sound robotic, 50-80% tightens the playing while it still sounds like a person. It only ever runs when you pick one of the two commands in this menu, and Undo puts the notes back exactly where you played them."),
        .init("pianoRoll.velocityLane", control: "Velocity",
              terse: "Velocity lane",
              teaching: "Show a strip under the notes where each note's loudness lives. Drag a bar up and that note is hit harder."),
        .init("pianoRoll.selectionCount", control: "n of m notes",
              terse: "Notes in this clip",
              teaching: "How many notes this clip holds, and how many of them you have selected right now."),
    ]

    // MARK: Mixer dock (levels, pan, sends, mute, solo)

    static let mixer: [StudioHelpEntry] = [
        .init("mixer.collapse", control: "MIXER",
              terse: "Hide the mixer",
              teaching: "Fold the mixer away. The strip keeps saying MIXER · VOLUME so you can still find it, and the master level stays in the top bar as VOLUME."),
        .init("mixer.expand", control: "MIXER · VOLUME",
              terse: "Show the mixer",
              teaching: "Open the row of channel strips: one per track, plus the master. This is where you set how loud each part is against the others. The whole-mix VOLUME control also lives permanently in the top bar."),
        .init("mixer.undo", control: "arrow.uturn.backward",
              terse: "Undo",
              teaching: "Take back the last change, including fader, knob and automation moves. Command-Z does the same."),
        .init("mixer.redo", control: "arrow.uturn.forward",
              terse: "Redo",
              teaching: "Put back the change you just undid. Shift-Command-Z does the same."),
        // The two chevrons that replaced the mixer's horizontal ScrollView.
        // They are worded as CHANNELS moving, not as scrolling: "scroll left"
        // is ambiguous about whether the view or the content moves, and the
        // person these tooltips are written for has no reason to know which.
        .init("mixer.scrollLeft", control: "chevron.left",
              terse: "Show earlier channels",
              teaching: "Slide the row of channel strips to bring the tracks nearer the top of the song list back into view. Nothing about the mix changes — only which strips you can see."),
        .init("mixer.scrollRight", control: "chevron.right",
              terse: "Show later channels",
              teaching: "Slide the row of channel strips the other way, towards the master strip at the far end. Use this when a session has more tracks than fit across the window."),
        .init("mixer.masterMini", control: "VOLUME readout",
              terse: "Master volume summary",
              teaching: "The finished mix's level in decibels, plus its loudness reading, kept visible while the mixer is folded away. Open MIXER · VOLUME to reach every track's fader."),
        .init("mixer.strip.eq", control: "EQ curve",
              terse: "EQ",
              teaching: "Turn parts of the frequency range up or down on this track. Drag a dot left for bass, right for treble, up to boost, down to cut. Cutting is usually the tidier fix."),
        .init("mixer.strip.pan", control: "PAN",
              terse: "Pan",
              teaching: "Place this track between the left and right speakers. Centre is the default; double-click the knob to snap back to it."),
        .init("mixer.strip.sendA", control: "REV",
              terse: "Reverb send",
              teaching: "How much of this track is copied off to the shared reverb. A send is a copy, not a move: the dry track keeps playing. Turn it up for a roomier, further-away sound."),
        .init("mixer.strip.sendB", control: "DLY",
              terse: "Delay send",
              teaching: "How much of this track is copied off to the shared echo. Same idea as the reverb send: a copy is treated, the original stays put."),
        .init("mixer.strip.fader", control: "fader",
              terse: "Track volume",
              teaching: "How loud this track sits in the mix. 0 dB is untouched; double-click to snap back there. Mixing is mostly this control."),
        .init("mixer.strip.meter", control: "meter",
              terse: "Track level",
              teaching: "How loud this track is right now. If it is pinned at the top in red, pull the fader down."),
        .init("mixer.strip.gainReadout", control: "0.0 dB",
              terse: "Fader position",
              teaching: "The fader's exact position in decibels — click it and type a number, or use the arrows to move a decibel at a time. Negative is quieter than the recording, positive is louder."),
        .init("mixer.mute", control: "M",
              terse: "Mute",
              teaching: "Silence this track without deleting anything. Press it again to bring it back."),
        .init("mixer.unmute", control: "M",
              terse: "Unmute",
              teaching: "Bring this track back into the mix."),
        .init("mixer.solo", control: "S",
              terse: "Solo",
              teaching: "Hear ONLY this track and mute everything else, so you can check one part on its own. Press it again to hear the whole mix."),
        .init("mixer.unsolo", control: "S",
              terse: "Unsolo",
              teaching: "Stop isolating this track and go back to hearing the whole mix."),
        .init("mixer.master.lufs", control: "LUFS",
              terse: "Perceived loudness",
              teaching: "How loud the whole mix FEELS, not how tall its peaks are. Streaming services aim for about -14; a big I number means a loud master."),
        .init("mixer.master.correlation", control: "CORR",
              terse: "Stereo correlation",
              teaching: "Whether the left and right channels agree. Near +1 is safely mono-compatible; below 0 means parts will cancel out and vanish on a phone speaker."),
        .init("mixer.master.limiter.on", control: "LIM",
              terse: "Turn the limiter off",
              teaching: "The limiter is a ceiling the mix cannot go above, so nothing distorts. Turning it off means loud moments can clip."),
        .init("mixer.master.limiter.off", control: "LIM",
              terse: "Turn the limiter on",
              teaching: "Put a ceiling on the mix so nothing gets loud enough to distort. Leave this on unless you have a reason not to."),
        .init("mixer.master.ceiling", control: "CEIL",
              terse: "Limiter ceiling",
              teaching: "The loudest the mix is allowed to get, in decibels. -1 is the usual choice: it leaves a little headroom so MP3 encoding cannot push it over."),
        .init("mixer.master.release", control: "REL",
              terse: "Limiter release",
              teaching: "How quickly the limiter lets go after it catches a loud moment, in milliseconds. Fast can pump and breathe; slow is smoother but ducks more."),
        .init("mixer.master.gainReduction", control: "GR",
              terse: "Gain reduction",
              teaching: "How many decibels the limiter is holding back this instant. A little is normal; constantly several dB means the mix is being squashed."),
        .init("mixer.master.fader", control: "fader",
              terse: "Master volume",
              teaching: "The level of the finished mix, after every track. Use track faders to balance parts; use this one for the whole thing."),
        .init("mixer.master.meter", control: "meters",
              terse: "Master level",
              teaching: "The finished mix's level, plus a true-peak reading — the level after the file is decoded back to sound, which can be higher than the sample values suggest."),
        .init("mixer.master.readout", control: "dB / TP",
              terse: "Master level readout",
              teaching: "The master fader's exact position in decibels — click it and type a number, or step it with the arrows. The TP figure beside the strip is the highest true peak seen; keep it at or under the limiter ceiling."),
    ]

    // MARK: The shared numeric entry
    //
    // Three entries, applied ONCE inside `StudioTypedValueField`, which every
    // knob, fader and instrument slider embeds. That is why there are three
    // strings here rather than fifty: the control is shared, so its help is
    // too. The per-parameter meaning still comes from the knob's own entry —
    // these say what the FIELD does, which is the part that is the same
    // everywhere.

    static let typedValueEntries: [StudioHelpEntry] = [
        .init("control.typedValue", control: "the number",
              terse: "Type a value",
              teaching: "Click this number and type the one you want, then press Return. Out-of-range numbers are pulled back to the nearest allowed value and shown that way, and anything that is not a number puts the old value back. Units come along for the ride: 2.5k means 2500 Hz, 50% and -6 dB both work."),
        .init("control.stepUp", control: "chevron.up",
              terse: "Nudge up",
              teaching: "Move this setting up by one sensible step — a decibel for volumes, a semitone for frequencies, a tenth for ratios and Q. Easier than aiming at a knob, and each press is its own undo step."),
        .init("control.stepDown", control: "chevron.down",
              terse: "Nudge down",
              teaching: "Move this setting down by one sensible step — a decibel for volumes, a semitone for frequencies, a tenth for ratios and Q. Each press is its own undo step."),
    ]

    // MARK: Track headers (the column down the left of the timeline)
    //
    // The single largest gap the first help pass could not close: the header
    // column was owned by a concurrent lane and shipped with ZERO help. It is
    // also the exact surface where "I can't find how to delete a track" came
    // from — the destructive affordances live in a context menu, and a context
    // menu on macOS advertises itself to nobody.
    //
    // So `trackHeader.row` is the load-bearing entry here, not the button
    // tooltips: it is attached to the whole row, which means hovering ANY dead
    // space on a track header says how to delete it. That is the one hover a
    // lost user is most likely to perform.
    //
    // M and S deliberately reuse `mixer.mute` / `mixer.solo` rather than
    // minting `trackHeader.mute`: they are the same control doing the same
    // thing to the same track, and two copies of one sentence is two places to
    // fix when the wording is improved. Copying them was considered and
    // rejected on exactly that ground.

    static let trackHeader: [StudioHelpEntry] = [
        .init("trackHeader.row", control: "track header row",
              terse: "This track",
              teaching: "Right-click this row to delete the track or to remove its instrument — the two things the row itself cannot show you. Both are one undo step, so Cmd-Z brings the track back with its clips, its sound and its automation."),
        .init("trackHeader.origin.played", control: "Made when you played",
              terse: "This track made itself when you played",
              teaching: "You pressed a key on a project that had nothing to play it with, so this track and its instrument were made for you rather than leaving the keyboard silent. It is an ordinary track — rename it, record onto it, or delete it from the right-click menu. Cmd-Z right after it appears takes it back."),
        .init("trackHeader.origin.layered", control: "Made for a layer",
              terse: "This track holds a layer you asked for",
              teaching: "Add a Layer puts its new part on a row of its own instead of on top of what was already there, so you can turn the layer down, move it, or delete it without disturbing the rest of the song. It is an ordinary track in every other way. Undoing takes the layer off first, and undoing again takes this track away."),
        .init("trackHeader.origin.imported", control: "Made when you imported",
              terse: "This track holds one imported file",
              teaching: "Stems are the separate parts of one song — the vocal, the drums, the bass — saved as separate files. Each one gets a row of its own so you can balance them against each other, which is the whole point of having them apart. Delete the row from the right-click menu if you do not want that part."),
        .init("trackHeader.arm", control: "record dot",
              terse: "Arm for recording",
              teaching: "Choose this track as the one that will receive what you play. Record does nothing until a track is armed."),
        .init("trackHeader.disarm", control: "record dot",
              terse: "Disarm",
              teaching: "Stop this track being the recording target."),
        .init("trackHeader.automation", control: "A",
              terse: "Automation lanes",
              teaching: "Show a strip under the track where volume or pan can change over time — turn the chorus up without touching the fader by hand."),
        .init("trackHeader.volume", control: "volume sliver",
              terse: "Track volume",
              teaching: "How loud this track sits in the mix. Drag the mixer's fader to change it; this is a read-out."),
        .init("trackHeader.takes.show", control: "chevron.right",
              terse: "Show takes",
              teaching: "Open every recorded pass on this track so you can pick a different one."),
        .init("trackHeader.takes.hide", control: "takes",
              terse: "Hide takes",
              teaching: "Fold the take lane away. Nothing is deleted."),
        .init("trackHeader.automation.clear", control: "xmark",
              terse: "Clear this automation",
              teaching: "Delete every point on this lane and go back to a fixed value. Undo restores them."),
        .init("trackHeader.automation.hide", control: "eye.slash",
              terse: "Hide this lane",
              teaching: "Put the lane away. A lane with points on it stays shown, because hiding it would hide the fact that it is moving."),
        .init("trackHeader.instrument.add", control: "+ Instrument",
              terse: "Add an instrument",
              teaching: "This track has no instrument, so playing the keys makes no sound on it. Pick one: a Synth builds a sound from scratch, a Sampler plays a recording you choose across every key, and a Drum Rack puts a different sound on each of sixteen keys. The two that play recordings ask you for the file straight away. Cmd-Z undoes it."),
        .init("trackHeader.color", control: "color swatch",
              terse: "Track colour",
              teaching: "Pick a colour for this track's header and clips, so you can tell it apart from the others at a glance."),
        .init("trackHeader.height", control: "height H",
              terse: "Track height",
              teaching: "Make this track's row taller or shorter in the timeline. A taller track shows more waveform detail; a shorter one fits more tracks on screen."),
    ]

    // MARK: Routing and effects (the densest jargon in the app)

    static let routing: [StudioHelpEntry] = [
        .init("routing.addBus", control: "+ BUS",
              terse: "Add a bus",
              teaching: "A bus is a shared destination you can send copies of tracks to — one reverb fed by six tracks instead of six reverbs. The tracks keep their own direct path to the master."),
        .init("routing.addGroup", control: "+ GROUP",
              terse: "Add a group",
              teaching: "A group is a submix: tracks routed into it stop going to the master directly and go through the group instead, so one fader controls all the drums at once."),
        .init("routing.host", control: "row",
              terse: "Pick what to work on",
              teaching: "Choose the track, bus or master whose effects and connections you want to see. The number on the right is how many effects it already has."),
        .init("routing.busMeter", control: "bar",
              terse: "Level on this bus",
              teaching: "How much sound is actually reaching this bus. If it is flat while the song plays, nothing is being sent here yet."),
        .init("routing.remove", control: "REMOVE",
              terse: "Remove this bus",
              teaching: "Delete this bus. Undo restores it with its whole effect chain and every connection intact."),
        .init("routing.busFader", control: "FADER",
              terse: "Bus level",
              teaching: "How loud everything arriving at this bus comes out. If a volume automation lane exists on the bus, that lane wins while it plays."),
        .init("routing.connect", control: "CONNECT TO…",
              terse: "Send this somewhere",
              teaching: "Point this track or bus at another destination. Destinations that would create a loop, or that are not allowed, are listed with the reason and cannot be picked."),
        .init("routing.sendLevel", control: "LEVEL",
              terse: "How much is sent",
              teaching: "How much sound is copied down this connection. -inf sends nothing, 0 dB sends it at full strength."),
        .init("routing.tap", control: "PRE / POST",
              terse: "Where the send is taken from",
              teaching: "POST takes the copy AFTER this channel's fader, so pulling the fader down takes the effect with it. PRE takes it before the fader, so the effect keeps going when you pull the fader down — but PRE here is also before the EQ."),
        .init("routing.disconnect", control: "xmark",
              terse: "Disconnect",
              teaching: "Remove this connection. Undo restores it with its level and its pre/post setting."),
        .init("routing.chainScrollLeft", control: "chevron.left",
              terse: "Earlier in the chain",
              teaching: "Slide the effect chain to show the slots nearer the start of the signal path."),
        .init("routing.chainScrollRight", control: "chevron.right",
              terse: "Later in the chain",
              teaching: "Slide the effect chain to show the slots nearer the end of the signal path."),
        .init("routing.fxAdd", control: "+ Effect",
              terse: "Add an effect",
              teaching: "Insert an effect here. The menu lists every kind this build can run: EQ, Compressor, Gate, Delay, Reverb, Saturator, Chorus, Utility and Limiter. Sound flows through the chain left to right, so an EQ before a compressor is a different result from the other way round. Drag a slot to reorder it."),
        .init("routing.fxCatalog", control: "effects list",
              terse: "What effects exist",
              teaching: "The nine effects this Studio can put on a track, bus or the master. Use + Effect on the chain above to add one of them."),
        .init("routing.fxBypass.active", control: "ACTIVE",
              terse: "Bypass this effect",
              teaching: "Switch the effect off without removing it, so you can hear what it was actually doing. Its settings are kept."),
        .init("routing.fxBypass.bypassed", control: "BYPASSED",
              terse: "Switch this effect back on",
              teaching: "Bring the effect back into the signal path with every setting where you left it."),
        .init("routing.fxDelete", control: "DELETE",
              terse: "Remove this effect",
              teaching: "Take the effect out of the chain. Undo restores it at the same position with every parameter."),
        .init("routing.sidechain", control: "KEY",
              terse: "Sidechain key",
              teaching: "Which signal this effect LISTENS to, as opposed to which it processes. Keying a compressor off the kick is what makes a bass duck on every kick hit. The key contributes no sound of its own."),
        .init("routing.fxParamClear", control: "clear",
              terse: "Back to the default",
              teaching: "Forget your setting for this knob so the effect uses its own default again. That is different from dialling the default in by hand."),
    ]

    // MARK: Effect parameters
    //
    // The knobs inside an effect are the sharpest end of the jargon problem:
    // THRESH, RATIO, KNEE, ATK, DET mean nothing at all to someone who has not
    // used a compressor, and there is no way to work out what they do by
    // turning them (the effect of a wrong threshold is "nothing happens").
    //
    // Keyed by the engine's own wire key, so one entry covers a parameter
    // wherever it appears — `release` reads the same on the compressor, the
    // gate and the limiter. The four EQ bands collapse onto three entries
    // (`band0Freq` … `band3Freq` are all the same idea).
    // `testEveryEffectParameterHasHelp` walks every kind's parameter table and
    // fails on a key with no entry, so a new DSP parameter cannot land silent.

    static let fxParams: [StudioHelpEntry] = [
        .init("fx.param.bandFreq", control: "LO f / LM f / HM f / HI f",
              terse: "Band frequency",
              teaching: "Which part of the sound this band works on, in hertz. Low numbers are bass, high numbers are treble; 1000 Hz is roughly where a voice sits."),
        .init("fx.param.bandGain", control: "LO / LM / HM / HI",
              terse: "Band gain",
              teaching: "How much to turn this part of the sound up or down, in decibels. Cutting what you dislike usually sounds better than boosting what you like."),
        .init("fx.param.bandQ", control: "LO Q / LM Q / HM Q / HI Q",
              terse: "Band width",
              teaching: "How wide a slice of frequencies this band affects. Low numbers are a broad, gentle shape; high numbers are a narrow surgical notch."),
        .init("fx.param.threshold", control: "THRESH",
              terse: "Threshold",
              teaching: "The level at which the effect starts acting. Anything louder than this gets worked on and anything quieter is left alone."),
        .init("fx.param.ratio", control: "RATIO",
              terse: "Ratio",
              teaching: "How hard the compressor pushes back once the sound passes the threshold. 2:1 is gentle levelling, 10:1 and above is clamping it down."),
        .init("fx.param.knee", control: "KNEE",
              terse: "Knee",
              teaching: "How abruptly compression starts at the threshold. 0 is a hard corner you can hear; a wider knee eases in and sounds more natural."),
        .init("fx.param.attack", control: "ATK",
              terse: "Attack",
              teaching: "How fast the effect reacts once the sound crosses the threshold, in thousandths of a second. Fast catches the initial hit; slow lets it through and keeps the punch."),
        .init("fx.param.release", control: "REL",
              terse: "Release",
              teaching: "How long the effect keeps working after the sound drops back below the threshold. Too fast can pump audibly; too slow leaves it holding the sound down."),
        .init("fx.param.hold", control: "HOLD",
              terse: "Hold",
              teaching: "How long the gate stays open after the sound falls below the threshold, so a note's tail is not chopped off."),
        .init("fx.param.range", control: "RANGE",
              terse: "Range",
              teaching: "How far down the gate pushes the sound when it closes. -96 dB is fully silent; a smaller number leaves the quiet parts audible but reduced."),
        .init("fx.param.makeup", control: "MAKEUP",
              terse: "Makeup gain",
              teaching: "Turn the whole thing back up after compression has pulled it down, so you compare like for like instead of just hearing it get quieter."),
        .init("fx.param.mix", control: "MIX",
              terse: "Dry/wet mix",
              teaching: "How much of the treated sound is blended with the untouched original. 0 is no effect at all, 1 is fully treated."),
        .init("fx.param.detector", control: "DET",
              terse: "Detector",
              teaching: "What the effect measures to decide when to act. PEAK reacts to the sharpest instant; RMS reacts to average loudness and behaves more like an ear."),
        .init("fx.param.time", control: "TIME",
              terse: "Delay time",
              teaching: "How long until the echo comes back, in thousandths of a second. At 120 BPM one beat is 500 ms, so 375 ms is a dotted eighth — the classic pulsing delay."),
        .init("fx.param.feedback", control: "FDBK",
              terse: "Feedback",
              teaching: "How much of the echo is fed back in to echo again. Low gives one or two repeats; near the top it repeats almost forever."),
        .init("fx.param.tone", control: "TONE",
              terse: "Tone",
              teaching: "How bright the repeats are. Darker repeats sit behind the original instead of competing with it."),
        .init("fx.param.damping", control: "DAMP",
              terse: "Damping",
              teaching: "How fast the high frequencies die away in the reverb tail — the difference between a tiled bathroom and a carpeted room."),
        .init("fx.param.size", control: "SIZE",
              terse: "Room size",
              teaching: "How big the imaginary space is. Small is a room, large is a hall with a long tail."),
        .init("fx.param.drive", control: "DRIVE",
              terse: "Drive",
              teaching: "How hard the sound is pushed into the saturator. More drive means more warmth and grit, and eventually distortion."),
        .init("fx.param.gain", control: "GAIN / OUT",
              terse: "Output level",
              teaching: "Turn the sound up or down as it leaves this effect, in decibels."),
        .init("fx.param.rate", control: "RATE",
              terse: "Rate",
              teaching: "How fast the chorus wobbles, in cycles per second. Slow is a gentle drift; fast is a wobbling, seasick sound."),
        .init("fx.param.depth", control: "DEPTH",
              terse: "Depth",
              teaching: "How far the chorus detunes the copy it adds. More depth is a thicker, more obviously processed sound."),
        .init("fx.param.spread", control: "SPREAD",
              terse: "Stereo spread",
              teaching: "How differently the left and right sides are treated. More spread makes the sound feel wider than the speakers."),
        .init("fx.param.pan", control: "PAN",
              terse: "Pan",
              teaching: "Move the sound between the left and right speakers. 0 is centre."),
        .init("fx.param.width", control: "WIDTH",
              terse: "Stereo width",
              teaching: "How far apart the left and right sides sit. 0 collapses to mono, 1 is untouched, above 1 pushes them further apart than they were recorded."),
        .init("fx.param.polarity", control: "POL",
              terse: "Polarity",
              teaching: "Flip the waveform upside down. It sounds identical on its own, but flipping one of two similar tracks can stop them cancelling each other out."),
        .init("fx.param.ceiling", control: "CEIL",
              terse: "Ceiling",
              teaching: "The loudest this effect will let anything through, in decibels. Nothing gets past it, so nothing distorts."),
    ]

    /// The catalog id for an effect parameter's wire key. The four EQ bands
    /// share three entries; everything else is its key.
    static func fxParamHelpID(_ key: String) -> String {
        if key.hasPrefix("band") {
            if key.hasSuffix("Freq") { return "fx.param.bandFreq" }
            if key.hasSuffix("Gain") { return "fx.param.bandGain" }
            if key.hasSuffix("Q") { return "fx.param.bandQ" }
        }
        return "fx.param.\(key)"
    }

    // MARK: Inspector (project, clip lineage, revise)

    static let inspector: [StudioHelpEntry] = [
        .init("inspector.retake", control: "Retake",
              terse: "Generate this part again",
              teaching: "Ask the model for another go at this clip, with the same settings. Wires into generation in a later build."),
        .init("inspector.moreLikeThis", control: "More like this",
              terse: "Use this as a starting point",
              teaching: "Fill a new generation's prompt in from this clip, so the next one lands in the same territory. Wires into generation in a later build."),
        .init("inspector.revise.instruction", control: "Describe the change",
              terse: "What to change",
              teaching: "Say in plain words what you want different about these bars — \"heavier drums\", \"drop the guitar\". This is the instruction the model is given."),
        .init("inspector.revise.scope", control: "Vocals / Drums / Bass / Other",
              terse: "Which parts to change",
              teaching: "Pick which layers of the sound get regenerated. Anything left off is kept exactly as it is, so you can rewrite the drums without touching the vocal."),
        .init("inspector.revise.variants", control: "Variants",
              terse: "How many versions to make",
              teaching: "How many different attempts the model makes. More gives you more to choose between and takes proportionally longer."),
        .init("inspector.revise.keepLyrics", control: "Keep lyrics",
              terse: "Keep the same words",
              teaching: "Regenerate the singing but keep the existing words. Turn this off to let the model write new ones."),
        .init("inspector.revise.seed", control: "Seed",
              terse: "Random seed",
              teaching: "The number that fixes the model's randomness. The same seed and the same settings produce the same result; leave it on auto for something new each time."),
        .init("inspector.revise.crossfade", control: "Crossfade",
              terse: "Join length",
              teaching: "How long, in thousandths of a second, the new audio fades into the old at each edge. A few milliseconds hides the join; too much smears the downbeat."),
        .init("inspector.revise.cancel", control: "Cancel",
              terse: "Cancel",
              teaching: "Drop the selection and leave these bars alone."),
        .init("inspector.revise.generate", control: "Generate n takes",
              terse: "Generate the takes",
              teaching: "Send the instruction to the model and get your versions back to listen to. Nothing is written into the song until you commit one."),
        .init("inspector.audition.take", control: "Take n",
              terse: "Listen to this take",
              teaching: "Play this version in place of the original so you can compare it in context. The number keys pick takes and A returns to the original."),
        .init("inspector.audition.discard", control: "Discard",
              terse: "Throw the takes away",
              teaching: "Drop every version and leave the song exactly as it was."),
        .init("inspector.audition.commit", control: "Commit",
              terse: "Keep this take",
              teaching: "Write the version you are listening to into the song, crossfaded at both edges, as a single undo step."),
    ]

    // MARK: Record bar (the cockpit that appears when a track is armed)

    static let record: [StudioHelpEntry] = [
        .init("record.start", control: "red circle",
              terse: "Start recording",
              teaching: "Capture what you play onto the armed track. If the song is stopped, Record seeks to your punch region (if any), counts in, and rolls the song before it captures. If the song is already playing, capture begins right where the playhead is."),
        .init("record.stop", control: "red square",
              terse: "Stop and keep the take",
              teaching: "Stop recording. What you played is landed on the track as a take you can keep, replace or delete."),
        .init("record.armed", control: "ARMED",
              terse: "The track being recorded onto",
              teaching: "Which track will receive what you play. Arm a different one from the round red button on its header."),
        .init("record.punch", control: "PUNCH",
              terse: "Record only these bars",
              teaching: "You have bars selected, so recording starts and stops itself at their edges and leaves the rest of the track untouched."),
        .init("record.device", control: "mic",
              terse: "Input device",
              teaching: "Which microphone or interface the sound is captured from. If you hear nothing on the meter, this is the first thing to check."),
        .init("record.inputOpen", control: "MIC OPEN",
              terse: "Microphone is open",
              teaching: "The app is listening through your interface right now. Arming a track does not open the mic — Record does, or the Listen button. When this light is off, nothing is hearing the room."),
        .init("record.inputChannel", control: "In 1",
              terse: "Which input this track records",
              teaching: "On an interface with several microphones, pick which physical input this track captures. Set track 1 to Input 1, track 2 to Input 2, arm them all, and press Record once to capture every mic together."),
        .init("record.inputListen", control: "Listen",
              terse: "Open the mic without recording",
              teaching: "Turn the meter on so you can set levels and see which mic is which, without starting a take. This is the only way the mic opens before you press Record."),
        .init("record.channelMeters", control: "1 2 3 4",
              terse: "Per-input levels",
              teaching: "One level bar per hardware input. Talk into each mic to see which number moves — that is how you know Input 1 is the vocal mic and Input 2 is the guitar."),
        .init("record.countIn", control: "COUNT-IN",
              terse: "Count-in beats",
              teaching: "How many beats of clicks you hear before recording starts, so you can come in on time. The first click is louder — that is beat one. Off starts instantly."),
        .init("record.loop", control: "Loop",
              terse: "Loop record",
              teaching: "Keep recording round and round over the selected bars. Every pass is kept as its own take so you can pick the best one afterwards. Loop record does not start the song."),
        // Open Microphone Settings is the recovery action for denied access.
        .init("record.microphoneSettings", control: "Open Microphone Settings",
              terse: "Open microphone settings",
              teaching: "Open macOS Privacy settings to allow Majik's Music Studio to use the microphone."),
        .init("record.meter", control: "level meter",
              terse: "Input level",
              teaching: "How loud your input is BEFORE recording. Aim for the level to sit in the green with peaks short of the top; red means it is too hot and will distort."),
        .init("record.scope", control: "scope",
              terse: "Input waveform",
              teaching: "The last moment of your input drawn as a wave, so you can see that sound is arriving even when it is too quiet to move the meter much."),
        .init("record.timer", control: "0:00",
              terse: "Recording time",
              teaching: "How long this take has been running."),
        .init("record.clip", control: "CLIP",
              terse: "Input is clipping",
              teaching: "Your input went past the maximum and was chopped flat, which sounds like crackle and cannot be repaired afterwards. Turn the source down and click to clear this."),
        .init("record.buildAround", control: "Build around this",
              terse: "Build an arrangement around this take",
              teaching: "Hand what you just played to the model and let it write the rest of the song around it, instead of you playing every part."),
    ]

    // MARK: Browser (left rail)

    static let browser: [StudioHelpEntry] = [
        .init("browser.songs", control: "Songs",
              terse: "Songs",
              teaching: "The song open here plus everything in your library. Double-click or drag one to load it onto the timeline."),
        .init("browser.takes", control: "Takes",
              terse: "Takes",
              teaching: "Every recorded pass in this project, including the ones you did not keep, so nothing you played is ever lost."),
        .init("browser.stems", control: "Stems",
              terse: "Stems",
              teaching: "The song split into separate layers — vocals, drums, bass, everything else. Mute a layer to hear the song without it, or solo one to hear only it."),
        // The two chips on a stem row. Written for someone who has never used a
        // DAW, because "S" and "M" are the two most important controls in this
        // pane and neither word appears on screen.
        .init("browser.stem.solo", control: "S",
              terse: "Hear only this layer",
              teaching: "Play just this part of the song and silence the rest, so you can hear what it is actually doing. Press it again to bring everything back."),
        .init("browser.stem.mute", control: "M",
              terse: "Silence this layer",
              teaching: "Take this part out and play everything else, which is how you find out whether a layer is helping the song. Press it again to bring it back."),
        // Level. Solo and mute are all-or-nothing; "a bit less drums" is the
        // next thing anybody wants and the only way to it used to be finding
        // the track in the mixer.
        .init("browser.stem.level", control: "0.0 dB",
              terse: "How loud this layer is",
              teaching: "How loud this part of the song is compared with the rest. 0 means untouched; a negative number means you have turned it down. The minus and plus beside it move it one step at a time."),
        .init("browser.stem.level.step", control: "− / +",
              terse: "Turn this layer down or up",
              teaching: "Move this part one step quieter or louder — about one decibel, which is roughly the smallest change you can hear. Each press is one step and one press of Cmd-Z, so you can always walk it back."),

        // There WAS a "Files" section here, and its sentence read "Audio files
        // on your disk that you can drag straight onto a track." Both halves
        // were false: the rows had no drag gesture at all, and what they listed
        // was the names of clips already imported into this project. The pane is
        // gone; see StudioBrowserView's header for why deleting beat repairing.
        .init("browser.search", control: "Search songs…",
              terse: "Search your library",
              teaching: "Filter the library list as you type. The list is capped, so searching is how you reach a song in a big library."),

        // The sounds vault. Every one of these is written for someone who has
        // never used a DAW, because the words a sample library uses — one-shot,
        // loop, stem, key — are exactly the ones that stop a person cold.
        .init("browser.sounds", control: "Sounds",
              terse: "Your sound library",
              teaching: "Drum hits, loops and stems you have downloaded. Click one to hear it — that changes nothing — and drag it onto a track to use it."),
        .init("sounds.search", control: "Search sounds",
              terse: "Find a sound by name",
              teaching: "Type any part of a name and the list narrows as you go. Two words find sounds with both in them, in any order."),
        .init("sounds.kind", control: "All",
              terse: "Show every kind of sound",
              teaching: "Turns the kind filters off so hits, loops and stems are all listed together."),
        .init("sounds.kind.hits", control: "Hits",
              terse: "Single drum hits",
              teaching: "One sound, played once — a kick, a snare, a hand clap. There is no tempo to match, so a hit fits any song."),
        .init("sounds.kind.loops", control: "Loops",
              terse: "Bars that repeat",
              teaching: "A few bars of music built to be played over and over. A loop is recorded at one speed, so its tempo has to suit your song."),
        .init("sounds.kind.stems", control: "Stems",
              terse: "One layer of a song",
              teaching: "A whole song with everything but one part removed — just the drums, or just the bass — so you can build on that layer alone."),
        .init("sounds.inTempo", control: "In tempo",
              terse: "Only sounds at your song's speed",
              teaching: "Hides loops recorded at a different speed from your song, which would drift out of time. Single hits stay, because they have no speed."),
        .init("sounds.inKey", control: "In key",
              terse: "Only sounds in your song's key",
              teaching: "A key is the set of notes a song is built from. This hides sounds built from a different set, which would clash against yours."),
        .init("sounds.row", control: "A sound",
              terse: "Click to hear it, drag to use it",
              teaching: "Clicking plays it and changes nothing in your song. Dragging it onto a track drops it where you let go, and one Undo takes it back off."),
        .init("sounds.row.loadSampler", control: "Load into Sampler",
              terse: "Load this into a Sampler",
              teaching: "Make a Sampler track with this recording across the keyboard, ready to play from your MIDI keys."),
        .init("sounds.folder", control: "Choose sounds folder…",
              terse: "Point this at your sounds",
              teaching: "Pick the folder your downloaded sound packs are in, and everything inside it becomes searchable here."),
        .init("sounds.get", control: "Get more sounds…",
              terse: "Browse packs you can download",
              teaching: "Shows the sound packs available to you. Picking one copies its sounds onto this computer so you can use them in a song."),
        .init("sounds.pack", control: "A sound pack",
              terse: "Download this pack",
              teaching: "Copies every sound in this pack onto your computer. The number beside it is how many sounds you will get."),
        .init("sounds.key", control: "Sounds account key",
              terse: "Your own key from the sounds site",
              teaching: "Sound packs belong to your account, so this needs a key from the sounds website to know they are yours. Nothing is shared."),
        .init("sounds.key.save", control: "Save",
              terse: "Keep this key on this computer",
              teaching: "Stores the key in your Mac's keychain, where only you and this app can read it. You only have to do this once."),
        .init("sounds.stop", control: "Stop",
              terse: "Stop the download",
              teaching: "Halts what is downloading now. Sounds already copied stay, and starting again picks up where this left off."),
        .init("sounds.tempos", control: "Update tempos",
              terse: "Look up the speed of every sound you have",
              teaching: "Asks the sounds website how fast each loop was recorded, so the list can say a real number instead of \"tempo unknown\". It matches your files by name, works for sounds you copied in yourself, needs no account, and tells you how many it could not find."),
    ]

    // MARK: The pane dividers (drag an edge to resize)
    //
    // The one control in the Studio whose teaching has to explain that the
    // control EXISTS. Every other entry here describes something with a glyph
    // or a word printed on it; a divider is a hairline, and the whole reason it
    // needs help is that a person who has never met a resizable pane does not
    // know an edge is draggable. So each of these says the gesture first, what
    // it changes second, and the double-click escape hatch last — because
    // "drag, and if you make a mess, double-click" is the entire model.
    //
    // Named per pane rather than one shared "divider" entry: hovering the edge
    // between the timeline and the mixer should say what the MIXER is, which is
    // a second chance to learn the pane for someone who never opened it.

    static let layout: [StudioHelpEntry] = [
        .init("layout.divider.browser", control: "browser edge",
              terse: "Resize the browser",
              teaching: "Drag this edge to make the song and file list on the left wider or narrower; the timeline takes back whatever you give up. Double-click to put it back to its normal width."),
        .init("layout.divider.inspector", control: "inspector edge",
              terse: "Resize the inspector",
              teaching: "Drag this edge to change how much room the panel on the right gets for describing what you have selected. Double-click to put it back to its normal width."),
        .init("layout.divider.copilot", control: "Sterling edge",
              terse: "Resize Sterling's console",
              teaching: "Drag this edge to give the assistant you chat with more or less room. Widen it while you are reading a long answer, narrow it while you are arranging. Double-click to put it back."),
        .init("layout.divider.pianoRoll", control: "piano roll edge",
              terse: "Resize the piano roll",
              teaching: "Drag this edge up to make the note editor taller, which shows more pitches at once, or down to give the arrangement above it more room. Double-click to put it back to its normal height."),
        .init("layout.divider.routing", control: "routing edge",
              terse: "Resize the routing panel",
              teaching: "Drag this edge to change how tall the routing and effects panel is, so more of the effect list and its controls fit without scrolling. Double-click to put it back."),
        .init("layout.divider.mixer", control: "mixer edge",
              terse: "Resize the mixer",
              teaching: "Drag this edge to change how tall the mixer is. It will not go shorter than one full channel strip, because a strip that is cut off has buttons you cannot click. Double-click to put it back."),
        .init("layout.divider.keyboard", control: "keyboard edge",
              terse: "Resize the on-screen keyboard",
              teaching: "Drag this edge up to make the piano keys taller and easier to hit, or down to win the space back for the arrangement. Double-click to put it back to its normal height."),
    ]

    // MARK: Settings tabs
    //
    // The Settings window is a separate surface, but it is the same failure
    // mode: nine icons and two-word titles, several of which mean nothing
    // without context ("Server Pool", "MCP / API").

    static let settings: [StudioHelpEntry] = [
        .init("settings.tab.agents", control: "Agents",
              terse: "Agents",
              teaching: "The assistants that can work on your music: who they are, what they are allowed to do, and which model each one thinks with."),
        .init("settings.tab.sterling", control: "Sterling",
              terse: "Sterling",
              teaching: "Sterling is the engineer you talk to inside the Studio. This is where its voice, behaviour and permissions live."),
        .init("settings.tab.llm", control: "LLM & Models",
              terse: "LLM and models",
              teaching: "Which language model reads your prompts, and where it runs — on this machine or through a service you have a key for."),
        .init("settings.tab.models", control: "Models",
              terse: "Model downloads",
              teaching: "Download and manage the music-generation models. Bigger models sound better and need more memory and disk."),
        .init("settings.tab.libraryLocation", control: "Library Location",
              terse: "Where songs are stored",
              teaching: "The folder your finished songs and their audio live in. Point it at an external drive if your startup disk is filling up."),
        .init("settings.tab.libraryBackup", control: "Library Backup",
              terse: "Library backup",
              teaching: "Keep a second copy of your library somewhere else, so a failed disk does not take your songs with it."),
        .init("settings.tab.serverPool", control: "Server Pool",
              terse: "Generation machines",
              teaching: "Other machines that can do the generating for you. Add one and heavy work runs there instead of on this computer."),
        .init("settings.tab.midi", control: "MIDI",
              terse: "MIDI hardware",
              teaching: "Your physical keyboards and control surfaces: which are connected, and what their knobs and keys are mapped to."),
        .init("settings.tab.mcp", control: "MCP / API",
              terse: "Outside access",
              teaching: "Let other programs and assistants drive this app. MCP is the protocol agents use to call an app's features as tools."),

        // The two chevrons that replaced the tab row's overflow ScrollView.
        // They are always shown (greyed out at the ends) rather than appearing
        // only when the row is too wide: a control that comes and goes is one
        // nobody learns, and see SettingsTabStrip for the mechanical reason.
        .init("settings.tab.scrollLeft", control: "chevron.left",
              terse: "Show earlier settings tabs",
              teaching: "Slide the row of settings tabs back towards Agents. Nothing is changed by this — only which tabs are wide enough to show."),
        .init("settings.tab.scrollRight", control: "chevron.right",
              terse: "Show later settings tabs",
              teaching: "Slide the row of settings tabs the other way, towards MCP at the far end. Use this when the window is too narrow to show all nine at once."),
    ]

    /// Every entry, in surface order. `StudioHelpTests` holds this to the three
    /// rules at the top of this file, and cross-checks it against the
    /// `.studioHelp("…")` call sites in the covered source files, so an id here
    /// with no control (or a control with no id) is a red test.
    // MARK: The command palette (Cmd-K)

    static let palette: [StudioHelpEntry] = [
        .init("palette.search", control: "Type a command",
              terse: "Find any command",
              teaching: "Type a few letters of what you want to do — \"beat\", \"volume\", \"reverb\" — and press Return on the line you want. Everything the Studio can do is in this list, including the things that have no button. A greyed line tells you what to do first."),
        .init("palette.argument", control: "the value",
              terse: "Type the value",
              teaching: "This command needs one number or word. What is already in the box is what the Studio is using now, so you can type over it. Units come along for the ride: 50%, -6 dB and 2.5k all work, and anything that is not a value puts the old one back."),
        .init("palette.confirm", control: "Return",
              terse: "Go ahead, or change your mind",
              teaching: "Press Return to go ahead and Escape to back out without doing anything. Anything that deletes asks here first, because you got to this line by typing a few letters and the line you meant may not be the line that was highlighted."),
    ]

    static let entries: [StudioHelpEntry] =
        toolbar + transport + pianoRoll + trackHeader + mixer + typedValueEntries
            + routing + fxParams + palette
            + inspector + record + browser + layout + settings + instrument + stems

    // MARK: The Stems tab — one song, broken into its parts
    //
    // The densest teaching outside the routing pane, and for the same reason:
    // solo and mute are the two ideas this whole surface exists for, and both
    // are DAW words that mean nothing to someone who has only ever pressed play
    // on a finished song. So neither tooltip says "solo" or "mute" as an
    // explanation of itself — each says what you will HEAR.

    static let stems: [StudioHelpEntry] = [
        .init("stems.session.new", control: "plus",
              terse: "New stem session",
              teaching: "Start an empty set of parts. A stem session is one song split into the pieces it is made of — the singing on one lane, the drums on another — so you can listen to them apart."),
        .init("stems.session.new.empty", control: "New Empty Session",
              terse: "New stem session",
              teaching: "Start an empty set of parts, then add audio files of your own to it one at a time. If what you want is one song pulled apart, use Split into Stems above instead — it does the pulling apart for you."),

        // The two that answer the question this whole tab was failing:
        // "we don't have the ability to break out an audio file to different
        // stems? I don't see that option in the stems section". Neither
        // tooltip says the word "stem" as an explanation of itself, for the
        // same reason Solo and Mute do not: each says what you will HEAR.
        .init("stems.separate", control: "Split into Stems",
              terse: "Split a song into its parts",
              teaching: "Pick a song from your computer and this pulls it apart into four separate recordings — just the singing, just the drums, just the bass, and everything else — and puts each one on its own lane here, with its own volume. Your original file is not touched. It takes a few minutes for a full song, and the very first time it also downloads what it needs."),
        .init("stems.separate.empty", control: "Split into Stems",
              terse: "Split a song into its parts",
              teaching: "This is the one that fills this empty screen. Choose a song and it comes back as four parts you can listen to on their own — the singing, the drums, the bass, and the rest — so you can hear the song without the vocal, or the vocal without the song. A few minutes for a full song; the first run also downloads the model that does the splitting."),

        .init("stems.solo", control: "SOLO",
              terse: "Hear only this part",
              teaching: "Mutes every other part so you hear this one on its own — the fastest way to check whether a vocal is in tune or a bass line is right. Click another part to move the spotlight there; hold Option to listen to two at once. Click this again to hear the whole song."),
        .init("stems.solo.off", control: "SOLO",
              terse: "Stop listening to this part alone",
              teaching: "Bring the rest of the song back. Nothing about the mix changed while you were listening to this part alone; solo only decides what reaches your speakers."),
        .init("stems.mute", control: "MUTE",
              terse: "Silence this part",
              teaching: "Take this part out and leave everything else playing — this is how you hear the song WITHOUT the vocal, or check what the drums are actually holding up. It silences the part, it does not delete it."),
        .init("stems.mute.off", control: "MUTE",
              terse: "Bring this part back",
              teaching: "Let this part be heard again, exactly as it was. Its level and position are untouched."),

        .init("stems.gain", control: "level slider",
              terse: "How loud this part is",
              teaching: "Sets how loud this part sits against the others. Louder here does not make a better mix — the useful move is usually to turn something DOWN until the part you care about can be heard."),
        .init("stems.gain.reset", control: "dB readout",
              terse: "Double-click to reset to 0 dB",
              teaching: "How loud this part is, in decibels. 0 dB is the part exactly as it was recorded; double-click this number to go back there after experimenting."),
        .init("stems.pan", control: "pan slider",
              terse: "Left-to-right position",
              teaching: "Places this part across the stereo picture — hard left, hard right, or anywhere between. Spreading parts apart is how a mix stops sounding like everything is crammed into one spot. Vocals and bass usually stay in the middle."),
        .init("stems.pan.center", control: "pan readout",
              terse: "Double-click to centre",
              teaching: "Where this part sits left to right: L is left, R is right, C is dead centre. Double-click to put it back in the middle."),
        .init("stems.meter", control: "level meter",
              terse: "How loud this part is right now",
              teaching: "Moves with the sound actually coming out of this part while it plays. The floating tick is the loudest moment since a moment ago, and it turns red if the part is too loud and starts distorting."),

        .init("stems.lane", control: "waveform lane",
              terse: "This part's sound over time",
              teaching: "The shape of this part from the start of the song to the end — tall where it is loud, flat where there is nothing. Click or drag anywhere in it to jump the play head there; every lane moves together, because they are all the same song."),
        .init("stems.ruler", control: "time ruler",
              terse: "Where you are in the song",
              teaching: "Minutes and seconds across the whole song. Click or drag to jump to a moment. Because every part starts at the same instant and runs the same length, one ruler is true for every lane below it."),
        .init("stems.row.menu", control: "ellipsis.circle",
              terse: "More for this part",
              teaching: "Open this part in the Studio on its own track, reset its level or position, or take it out of the session. Removing is undoable and never deletes the audio file."),

        .init("stems.transport.play", control: "play.fill",
              terse: "Play",
              teaching: "Play every part together from the play head, exactly in step. The spacebar does the same thing while you are on this tab."),
        .init("stems.transport.pause", control: "pause.fill",
              terse: "Pause",
              teaching: "Stop where you are. Playing again carries on from this exact spot rather than the start."),
        .init("stems.transport.stop", control: "stop.fill",
              terse: "Stop",
              teaching: "Stop playing and send the play head back to the beginning of the song."),
        .init("stems.transport.returnToStart", control: "backward.end.fill",
              terse: "Back to the start",
              teaching: "Jump the play head to the very beginning without stopping what you were doing."),
        .init("stems.transport.seek", control: "position slider",
              terse: "Move through the song",
              teaching: "Drag to move the play head anywhere in the song. Every part follows together — you cannot pull one out of step with the others."),

        .init("stems.master.gain", control: "master slider",
              terse: "How loud everything is",
              teaching: "The volume of the finished mix — every part at once, after their own levels. Use this to make the whole thing quieter or louder without changing the balance you have found between the parts."),
        .init("stems.master.reset", control: "master dB readout",
              terse: "Double-click to reset to 0 dB",
              teaching: "How loud the finished mix is, in decibels. Double-click this number to put it back to 0 dB, which is the mix at its natural loudness."),
        .init("stems.master.meter", control: "master meter",
              terse: "How loud the finished mix is right now",
              teaching: "The level of everything combined. If the tick at the right turns red the mix is too loud and will distort when you bounce it — turn parts down until it stops."),

        .init("stems.add", control: "Add Stems from Files…",
              terse: "Add audio files as parts",
              teaching: "Pick audio files from your disk and add each as its own lane. They are copied into the session, so moving or deleting the originals later cannot break it."),
        .init("stems.add.empty", control: "Add Stems from Files…",
              terse: "Add audio files as parts",
              teaching: "Pick audio files from your disk to fill this empty session — one lane per file. They are copied in, so the session keeps working even if you move the originals."),
        .init("stems.bounce", control: "Bounce",
              terse: "Save this mix as one audio file",
              teaching: "Write everything you can currently hear — the levels, the positions, whatever is muted or soloed — into a single audio file you can play anywhere. Choose .wav to keep the full quality or .m4a for a smaller file."),
        .init("stems.openAll", control: "Open All in Studio",
              terse: "Send every part to the Studio",
              teaching: "Put each part on its own track in the Studio, where you can cut them up, move sections around and add effects. This is the step from balancing the parts to arranging them; nothing here is changed or lost."),
    ]

    // MARK: The instrument panel — a sampler's sound, and the drum pads
    //
    // The densest teaching in the app after the routing pane, because a sampler
    // is where two ideas a beginner has never met collide: a recording can be a
    // whole instrument, and WHICH KEY you press changes how fast it plays. Both
    // sentences below say that in words, not in DAW vocabulary.

    static let instrument: [StudioHelpEntry] = [
        .init("instrument.sampler.replace", control: "Replace…",
              terse: "Swap this sound",
              teaching: "Pick a different recording for this instrument to play. The key range and the original key stay as they are, so a swap is a change of sound, not a change of tuning. Cmd-Z puts the old one back."),
        .init("instrument.sampler.rootKey", control: "Original key",
              terse: "The key this recording sounds at",
              teaching: StudioSampler.rootExplanation),
        .init("instrument.pad.empty", control: "empty pad",
              terse: "Put a sound on this key",
              teaching: "This key has no sound yet, so playing it makes nothing. Click to pick a file, or drop one straight onto the pad. Each pad is one key: press that key and the sound plays once, all the way through, whatever the note's length."),
        .init("instrument.pad.loaded", control: "loaded pad",
              terse: "The sound on this key",
              teaching: "Press this key and you hear this sound, once, from the top — a drum rack does not stretch a sound to match the key, which is why a kick stays a kick everywhere. Click to pick a different file, drop one on to replace it, or right-click to empty the pad."),
        .init("instrument.drum.loadKit", control: "Load Drum Kit",
              terse: "Fill the whole rack at once",
              teaching: "Pick a folder of drum one-shots and every file becomes a pad, starting at C1 — kick, snare, hat, clap, all the way up. The rack holds sixteen sounds; any extras beyond that are left behind. Cmd-Z undoes the whole kit."),

        // The tone controls. A Synth builds its sound from scratch instead of
        // playing a recording, and until these landed there was no way to
        // change that sound at all: it was one raw, buzzy waveform for
        // everybody. The named sounds carry their own descriptions inline (a
        // static entry cannot hold "Bell-like and percussive"); these three
        // cover the raw controls underneath them, and every one of them is
        // written for someone who has never heard the words "waveform",
        // "cutoff" or "envelope".
        .init("instrument.tone.raw", control: "Shape it yourself",
              terse: "The individual controls",
              teaching: "Opens the pieces the sounds above are made of, so you can build your own. There are two: WHAT the sound is made of (its tone), and HOW it behaves over time after you press a key (how fast it arrives, how it fades, how long it rings on after you let go). You cannot break anything — Cmd-Z undoes each change, and picking a named sound again resets all of them."),
        .init("instrument.tone.waveform", control: "Tone",
              terse: "What the sound is made of",
              teaching: "The raw material, before anything is done to it. Soft is a single pure tone and the roundest of the four; Bright contains every overtone at once and is the buzziest; Hollow sounds woody, like a clarinet; Round is soft with a bit more body. Everything else here shapes whichever of these you pick."),
        .init("instrument.tone.cutoff", control: "Brightness",
              terse: "How much of the high end you hear",
              teaching: "A filter that removes the top of the sound. Turn it down and the sound gets darker and rounder, as if it were being played in the next room; turn it up and every bit of edge comes back. It is the single biggest difference between a bass that sits under a song and one that fights it."),
        .init("instrument.tone.envelope", control: "Fade in / Fall to / Hold at / Fade out",
              terse: "How the sound behaves over time",
              teaching: "Four numbers that describe one key press. FADE IN is how long the sound takes to arrive — instant for a piano, half a second for a pad. FALL TO is how long it then takes to drop back. HOLD AT is how loud it stays while your finger is still down: at 1 it never fades, at 0 it dies away like a plucked string. FADE OUT is how long it rings on after you let go. These four are the difference between an organ and a bell far more than the tone above is."),
    ]
}

// MARK: - Applying help to a control

/// Reads the stored verbosity. `@AppStorage` rather than an environment value
/// on purpose: the Studio panes are hosted from several places (the root view,
/// pop-out windows, the Settings window) and an environment value would have to
/// be injected at every one of them, which is exactly the kind of wiring that
/// gets forgotten and silently drops the preference on one surface.
private struct StudioCatalogHelpModifier: ViewModifier {
    let id: String
    @AppStorage(StudioHelpVerbosity.storageKey) private var raw = StudioHelpVerbosity.default.rawValue

    func body(content: Content) -> some View {
        StudioHelpApply(
            resolution: StudioHelpCatalog.resolve(id, verbosity: .from(raw)),
            content: content)
    }
}

/// The dynamic variant, for a control whose help depends on live state (an
/// engine refusal, a learned MIDI range, which way a two-state button is
/// pointing). Not catalog-backed and so not coverage-checked, but it obeys the
/// same preference.
private struct StudioInlineHelpModifier: ViewModifier {
    let terse: String
    let teaching: String
    @AppStorage(StudioHelpVerbosity.storageKey) private var raw = StudioHelpVerbosity.default.rawValue

    func body(content: Content) -> some View {
        StudioHelpApply(
            resolution: StudioHelpCatalog.resolve(
                StudioHelpEntry("_inline", control: "", terse: terse, teaching: teaching),
                verbosity: .from(raw)),
            content: content)
    }
}

/// One place where a resolution becomes modifiers, so the tooltip and the
/// VoiceOver hint can never drift apart.
///
/// The `if let` here does change view identity when the preference flips, which
/// would reset a gesture in progress. That is deliberate: the alternative is
/// `.help("")`, and an empty tooltip is a small grey box that appears on hover
/// and says nothing — the exact opposite of the point. Flipping the preference
/// is a rare, explicit act; dragging a fader at the same instant is not a case
/// worth designing for.
private struct StudioHelpApply<C: View>: View {
    let resolution: StudioHelpResolution?
    let content: C

    var body: some View {
        if let resolution {
            if let tooltip = resolution.tooltip {
                content.help(tooltip)
            } else {
                // Tooltips off: the sighted reader asked for silence, VoiceOver
                // did not.
                content.accessibilityHint(resolution.accessibilityHint)
            }
        } else {
            // An id with no catalog entry. Rendered untouched rather than
            // crashing a shipping build; StudioHelpTests fails on it instead.
            content
        }
    }
}

extension View {
    /// Attach the catalog entry for `id` as this control's hover help.
    func studioHelp(_ id: String) -> some View {
        modifier(StudioCatalogHelpModifier(id: id))
    }

    /// Attach help that is computed at run time. Use only where the text genuinely
    /// depends on live state; prefer a catalog id, which is coverage-tested.
    func studioHelp(terse: String, teaching: String) -> some View {
        modifier(StudioInlineHelpModifier(terse: terse, teaching: teaching))
    }
}

// MARK: - The control that makes it optional

/// The verbosity picker. It lives in the Studio's own toolbar rather than in
/// the Settings window, and that is a considered choice: this whole lane exists
/// because things that were on screen could not be found, and burying the
/// help control behind a ninth tab of a separate window would repeat the bug it
/// is meant to fix. It sits next to the panel toggles it governs.
struct StudioHelpMenu: View {
    @AppStorage(StudioHelpVerbosity.storageKey) private var raw = StudioHelpVerbosity.default.rawValue

    private var verbosity: StudioHelpVerbosity { .from(raw) }

    var body: some View {
        Menu {
            Picker("Tooltips", selection: $raw) {
                ForEach(StudioHelpVerbosity.allCases) { level in
                    Text(level.label).tag(level.rawValue)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Text(verbosity.blurb)
        } label: {
            Image(systemName: verbosity == .off ? "questionmark.circle" : "questionmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(verbosity == .off ? StudioTokens.faint : StudioTokens.text)
                .frame(width: 30, height: 38)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Deliberately a plain .help, not .studioHelp: the one control that can
        // turn tooltips off must keep explaining itself after they are off, or
        // there is no way back except guessing.
        .help(StudioHelpCatalog.entry("toolbar.help")?.teaching ?? "")
        .accessibilityLabel("Tooltip detail")
        .accessibilityValue(verbosity.label)
    }
}
