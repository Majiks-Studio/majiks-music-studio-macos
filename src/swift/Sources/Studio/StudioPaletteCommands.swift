import Foundation

// MARK: - What ⌘K can actually reach
//
// WHY THIS FILE EXISTS.
//
// The palette listed ELEVEN of the catalog's 119 commands. Quantize, every one
// of the nine effects, the whole mixer, routing, note editing and input-channel
// assignment could not be found from it at all. The history is worth stating
// because it explains the shape of what follows: the palette once listed 71 and
// wired 11, so selecting most of them did nothing, and the fix at the time was
// to HIDE the unwired ones. That was right — a menu item that does nothing is
// worse than an absent one — but it left the honest fix undone, and the palette
// has been decoration ever since.
//
// The honest fix is not "unhide them". It is a table where every row states, in
// one place:
//
//   * the catalog name it sends, verbatim, so the palette cannot claim a verb
//     it does not send;
//   * what it needs from the app before it can run, as a SENTENCE (`block`),
//     because "reachable but inert" is the defect class this codebase produces
//     most — a row the user can highlight and press Return on to no effect is
//     the same bug the 71-listed/11-wired palette had, wearing a different hat;
//   * the ONE value it has to ask for, if any, in the unit the rest of the app
//     already types in (`StudioParamUnit`, from the typed-input work) rather
//     than a second notation invented here;
//   * whether it destroys something, because a FUZZY-MATCHED list is not a
//     context menu. `deleteTrack`'s own comment argues (correctly) that undo is
//     the safety net for a context-menu delete on a track the user pointed at.
//     A palette is different in kind: the user typed three letters and pressed
//     Return, and the row that was highlighted may not be the row they meant.
//     So anything that removes an object asks a second time. One extra Return
//     against a mis-fired delete is a trade worth making.
//
// And a second table, `excluded`, which names EVERY catalog command the palette
// deliberately does not offer and why. Together the two partition all 119: a
// test asserts that, so a command added to the catalog cannot slip through
// unconsidered — it has to be offered or refused in writing.
//
// NO NEW COMMANDS. Every capability below already exists in the catalog; this
// file is reach, not vocabulary.

// MARK: - What the palette can see

/// Everything a palette row reads when it decides whether it can run, and what
/// to send.
///
/// The two controllers are optional because they are `@StateObject`s on
/// `StudioRootView` and a test (or a preview) may drive the palette without
/// them. Optional rather than force-unwrapped, and every row that needs one
/// says so in its `block` sentence — an absent controller must read as "the
/// piano roll is not open", never as a crash and never as silence.
@MainActor
struct StudioPaletteContext {
    let model: StudioViewModel
    let pianoRoll: StudioPianoRollController?
    let routing: StudioRoutingController?

    init(model: StudioViewModel,
         pianoRoll: StudioPianoRollController? = nil,
         routing: StudioRoutingController? = nil) {
        self.model = model
        self.pianoRoll = pianoRoll
        self.routing = routing
    }

    var snapshot: StudioProjectSnapshot? { model.snapshot }

    /// Where the play head is right now, interpolated the same way the timeline
    /// draws it — so a command that lands "at the play head" lands where the
    /// user is looking rather than at the last polled revision.
    var playheadTicks: Int64 {
        model.playheadTicks(now: ProcessInfo.processInfo.systemUptime)
    }

    /// The clip a clip-scoped command acts on: the first selected clip, in
    /// timeline order so a multi-clip selection resolves the same way twice.
    var targetClip: StudioClipSnapshot? {
        guard let snapshot else { return nil }
        let selected = snapshot.tracks
            .flatMap(\.clips)
            .filter { model.selection.clipIDs.contains($0.id) }
        return selected.min { $0.startTicks < $1.startTicks }
    }

    /// Every selected clip, in timeline order. `clip.crossfade.set` is the only
    /// caller that needs more than one.
    var selectedClips: [StudioClipSnapshot] {
        guard let snapshot else { return [] }
        return snapshot.tracks
            .flatMap(\.clips)
            .filter { model.selection.clipIDs.contains($0.id) }
            .sorted { $0.startTicks < $1.startTicks }
    }

    /// The track a track-scoped command acts on.
    ///
    /// There is no "selected track" in this app — `StudioSelection` holds clips
    /// and a time region, nothing else — and inventing one here would create a
    /// piece of state that only the palette writes and only the palette reads,
    /// which is how dead state is born. So the target is DERIVED: the track
    /// holding the selected clip, else the single track a region selection
    /// covers. When neither is true the row is blocked and says which of the
    /// two to do, rather than guessing at track 0 and mixing the wrong thing.
    var targetTrack: StudioTrackSnapshot? {
        guard let snapshot else { return nil }
        if let clip = targetClip,
           let track = snapshot.tracks.first(where: { $0.clips.contains(where: { $0.id == clip.id }) }) {
            return track
        }
        if let region = model.selection.region, region.trackIDs.count == 1,
           let id = region.trackIDs.first {
            return snapshot.tracks.first(where: { $0.id == id })
        }
        return nil
    }

    /// The one sentence every track-scoped row uses when there is no target, so
    /// the remedy is worded identically wherever it appears.
    static let noTrackReason = "Select a clip on the track first, or drag across one track in the bar numbers."
    static let noClipReason = "Select a clip on the timeline first."
    static let noRollReason = "Open the piano roll on a MIDI clip first."
    static let noNotesReason = "Select some notes in the piano roll first."
    static let noEffectsReason = "Open the Effects panel first."
}

// MARK: - Can it run

/// Whether a row can run, and — when it cannot — WHY, in words the person
/// reading it can act on.
///
/// Two cases, deliberately. There is no third "listed but does nothing" state,
/// which is exactly the state the old palette shipped 60 of.
enum StudioPaletteAvailability: Equatable {
    case ready
    case blocked(String)

    var isReady: Bool { self == .ready }

    var reason: String? {
        if case .blocked(let why) = self { return why }
        return nil
    }
}

// MARK: - The one value a row has to ask for

/// `note.quantize` needs a strength. `track.setInputChannel` needs a channel.
/// A row that needs an argument asks for it in the palette's own field, using
/// the SAME parser every typed control in the app uses (`StudioParamUnit`), so
/// "2.5k", "-6 dB", "50%" and "L40" mean here exactly what they mean on a knob.
enum StudioPaletteArgument {
    /// A number, in the parameter's own value domain.
    case number(label: String, unit: StudioParamUnit, range: ClosedRange<Double>)
    /// Free text — a name, a key, a time signature, an effect kind.
    case text(label: String, placeholder: String)

    var label: String {
        switch self {
        case .number(let label, _, _): return label
        case .text(let label, _): return label
        }
    }
}

/// A parsed argument, ready for the row that asked for it.
///
/// The empty case is `nothing`, NOT `none`. `return .none` inside a function
/// returning `StudioPaletteValue?` resolves to `Optional.none` — nil — and the
/// first run of `StudioPaletteReachTests` caught exactly that: every row with no
/// argument read as "that is not a value" and sent nothing. A case name that can
/// be silently mistaken for nil has no business on a type whose whole job is to
/// distinguish "no argument" from "bad argument".
enum StudioPaletteValue: Equatable {
    case nothing
    case number(Double)
    case text(String)

    var number: Double { if case .number(let v) = self { return v }; return 0 }
    var int: Int { Int(number.rounded()) }
    var text: String { if case .text(let s) = self { return s }; return "" }
}

// MARK: - One row

/// One catalog command the palette offers.
struct StudioPaletteCommand {
    /// The catalog name, verbatim. This is what the row CLAIMS to send, and the
    /// round-trip test holds it to that claim against the command bus.
    let name: String
    /// What it does, in words a person who has never opened a DAW already has.
    /// The catalog name is still shown next to it — an agent and a person read
    /// the same list — but the sentence is what the list is searched on.
    let title: String
    /// The shortcut, where one exists elsewhere in the app. Teaching, not doing.
    let keys: String?
    let argument: StudioPaletteArgument?
    /// Removes something the user made. Asks a second time (see the file header).
    let destructive: Bool
    /// Why this cannot run right now, or nil when it can.
    let block: @MainActor (StudioPaletteContext) -> String?
    /// Send it. The only thing a row is allowed to do.
    let perform: @MainActor (StudioPaletteContext, StudioPaletteValue) -> Void

    init(_ name: String,
         _ title: String,
         keys: String? = nil,
         argument: StudioPaletteArgument? = nil,
         destructive: Bool = false,
         block: @escaping @MainActor (StudioPaletteContext) -> String? = { _ in nil },
         perform: @escaping @MainActor (StudioPaletteContext, StudioPaletteValue) -> Void) {
        self.name = name
        self.title = title
        self.keys = keys
        self.argument = argument
        self.destructive = destructive
        self.block = block
        self.perform = perform
    }

    @MainActor
    func availability(in context: StudioPaletteContext) -> StudioPaletteAvailability {
        // No project yet means no command can land. Said once here rather than
        // in 69 `block` closures.
        guard context.snapshot != nil else {
            return .blocked("The project is still loading.")
        }
        if let why = block(context) { return .blocked(why) }
        return .ready
    }

    /// What the field should already contain when this row asks for its value.
    ///
    /// Pre-filled with the CURRENT value wherever there is one, which is the
    /// convention every typed control in the app follows: the editable text is
    /// what the control already prints. Typing over it is one gesture; being
    /// handed an empty box and asked to remember the tempo is two.
    @MainActor
    func initialText(in context: StudioPaletteContext) -> String {
        guard let argument else { return "" }
        switch argument {
        case .number(_, let unit, _):
            return StudioPaletteFormat.text(initialNumber?(context) ?? 0, unit: unit)
        case .text(_, let placeholder):
            return initialString?(context) ?? placeholder
        }
    }

    /// Where the pre-fill comes from. Set through `prefilled(number:)` /
    /// `prefilled(text:)` so the initializer above stays readable.
    fileprivate var initialNumber: (@MainActor (StudioPaletteContext) -> Double)? = nil
    fileprivate var initialString: (@MainActor (StudioPaletteContext) -> String)? = nil

    func prefilled(number: @escaping @MainActor (StudioPaletteContext) -> Double) -> StudioPaletteCommand {
        var out = self
        out.initialNumber = number
        return out
    }

    func prefilled(text: @escaping @MainActor (StudioPaletteContext) -> String) -> StudioPaletteCommand {
        var out = self
        out.initialString = text
        return out
    }

    /// Read the typed string. nil means "that is not a value" — the palette
    /// says so and stays put, exactly as `StudioTypedEntry` rejects rubbish
    /// rather than reading it as zero.
    func parse(_ raw: String) -> StudioPaletteValue? {
        guard let argument else { return StudioPaletteValue.nothing }
        switch argument {
        case .number(_, let unit, let range):
            guard let v = unit.parse(raw, in: range) else { return nil }
            return .number(StudioParamUnit.tidy(StudioParamUnit.clamp(v, into: range)))
        case .text:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .text(trimmed)
        }
    }
}

/// How a pre-filled number is printed into the field. Deliberately the same
/// shape the controls print, so what is offered for editing reads back through
/// the same parser that produced it.
enum StudioPaletteFormat {
    static func text(_ v: Double, unit: StudioParamUnit) -> String {
        switch unit {
        case .decibels: return String(format: "%.1f dB", v)
        case .hertz: return v >= 1000 ? String(format: "%.1f kHz", v / 1000) : String(format: "%.0f Hz", v)
        case .milliseconds: return String(format: "%.0f ms", v)
        case .seconds: return String(format: "%.3f s", v)
        case .percent: return String(format: "%.0f%%", v * 100)
        case .ratio: return String(format: "%.1f :1", v)
        case .pan:
            if abs(v) < 0.005 { return "C" }
            return (v < 0 ? "L" : "R") + String(format: "%.0f", abs(v) * 100)
        case .plain: return v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
        }
    }
}

// MARK: - One press of Return, resolved

/// Where the palette is between "typing" and "done".
enum StudioPaletteStage: Equatable {
    case browsing
    /// Waiting for the one value this command needs.
    case argument(name: String)
    /// Destructive: waiting for a deliberate second Return.
    case confirming(name: String)
}

/// What pressing Return should do next.
enum StudioPaletteStep: Equatable {
    case blocked(String)
    case askForArgument(label: String, initial: String)
    case askForConfirmation(prompt: String)
    /// Send it, with this value.
    case commit(StudioPaletteValue)
    /// The typed value is not a value. Say so; send nothing.
    case rejected(String)
}

/// The decision, with no SwiftUI in it. The palette view calls this and so does
/// every test that proves the palette — the same split the piano roll, the
/// on-screen keyboard and the typed-value work already use, and for the same
/// reason: everything a test needs to drive lives somewhere it can import
/// without a window.
enum StudioPaletteFlow {

    @MainActor
    static func step(
        for command: StudioPaletteCommand,
        stage: StudioPaletteStage,
        typed: String,
        in context: StudioPaletteContext
    ) -> StudioPaletteStep {
        // Availability is checked at EVERY step, not only the first. A confirm
        // that sat on screen while the selection changed underneath must not
        // fire into a state that no longer supports it.
        if case .blocked(let why) = command.availability(in: context) {
            return .blocked(why)
        }

        // Destructive rows ask first. Ordered before the argument prompt because
        // no row is currently both, and if one ever is, the question "are you
        // sure" belongs before "how much".
        if command.destructive, stage != .confirming(name: command.name) {
            return .askForConfirmation(prompt: "Press Return again to \(command.title.lowercased()).")
        }

        if let argument = command.argument, stage != .argument(name: command.name) {
            return .askForArgument(
                label: argument.label,
                initial: command.initialText(in: context))
        }

        guard let value = command.parse(typed) else {
            return .rejected("\(typed.isEmpty ? "That" : typed) is not a \(command.argument?.label.lowercased() ?? "value").")
        }
        return .commit(value)
    }

    /// What the palette should already be showing when a MENU sent the user
    /// here, rather than the browsing list.
    ///
    /// The menu bar is built from this same table, and a menu item cannot ask
    /// for a tempo or ask "are you sure" — so the rows that need a value or a
    /// second Return carry an ellipsis and open ⌘K on the question. This is the
    /// function that decides what that question is.
    ///
    /// Pure, and it reuses `step` rather than re-deriving the decision: the
    /// question a menu opens must be the SAME question Return would have asked,
    /// or the two surfaces have drifted in the one place a user would notice.
    ///
    /// nil for a row that is blocked, absent, or needs nothing — the caller
    /// falls back to the ordinary browsing list, which is what a row that can
    /// simply run should have done from the menu in the first place.
    @MainActor
    static func seeded(
        _ name: String,
        in context: StudioPaletteContext
    ) -> (stage: StudioPaletteStage, prompt: String, typed: String)? {
        guard let command = StudioPaletteCommands.all.first(where: { $0.name == name }) else {
            return nil
        }
        switch step(for: command, stage: .browsing, typed: "", in: context) {
        case .askForConfirmation(let prompt):
            return (.confirming(name: name), prompt, "")
        case .askForArgument(let label, let initial):
            return (.argument(name: name), "\(command.title). \(label)?", initial)
        case .blocked, .rejected, .commit:
            return nil
        }
    }
}

// MARK: - The table
//
// WHAT IS OFFERED, AND WHAT IS NOT.
//
// A row is offered only when the palette can send it CORRECTLY. That is a
// higher bar than "a view-model method exists", and it is the bar this lane was
// written to, because listing a verb that lands nowhere is the exact defect the
// 71-listed/11-wired palette shipped.
//
// Three send paths are correct, and nothing else is:
//
//   1. A TYPED `StudioEngineCommand` case. The real engine translates the UI's
//      UUIDs into its own `t1` / `clip_…` ids on the way through
//      (`RealStudioEngine.engineTrack` / `uuidClip`), so the command that
//      arrives is addressed to a real object.
//   2. A `.catalog` envelope with NO id parameter — `midi.reload`,
//      `project.setPhaseAnchor`, `project.save`. There is nothing to translate,
//      so passing the params verbatim is correct.
//   3. `StudioRoutingController` / `StudioPianoRollController`, which build
//      their commands from ENGINE-NATIVE ids they already hold.
//
// A `.catalog` envelope carrying a UI UUID is NOT a correct send, and this file
// deliberately offers none. `StudioViewModel.renameTrack`, `reorderTrack`,
// `setTrackColor`, `setTrackHeight`, `renameClip`, `setClipGain`, `setClipMute`,
// `setMarker`, `removeMarker`, `setSection` and `removeSection` all take that
// path today from the track-header and clip context menus; they also use the
// MOCK engine's parameter names rather than the catalog schema's (`gain` for
// `gainDb`, `height` for `heightPx`, `index` for `newIndex`, `name`/`bar` for
// `label`/`positionTicks`). `StudioViewModel.send` discards the engine's result,
// so a refusal is silent. Those eleven are listed in `excluded` with that
// reason: ⌘K must not multiply a wrong contract, and the fix belongs in the one
// place the contract is written, not in sixty-nine palette rows.

enum StudioPaletteCommands {

    // MARK: Small builders
    //
    // These exist so the table below reads as DATA. Each one is a shape that
    // recurs — "a track-scoped toggle", "a number on the selected clip" — and
    // naming the shape once is what keeps 56 rows from becoming 56 bespoke
    // closures nobody will re-read.

    /// Blocked unless a track can be derived from the selection.
    @MainActor
    private static func needsTrack(_ context: StudioPaletteContext) -> String? {
        context.targetTrack == nil ? StudioPaletteContext.noTrackReason : nil
    }

    /// Blocked unless a clip is selected.
    @MainActor
    private static func needsClip(_ context: StudioPaletteContext) -> String? {
        context.targetClip == nil ? StudioPaletteContext.noClipReason : nil
    }

    /// Blocked unless the piano roll is open on a clip.
    @MainActor
    private static func needsRoll(_ context: StudioPaletteContext) -> String? {
        guard let roll = context.pianoRoll, roll.clip != nil else {
            return StudioPaletteContext.noRollReason
        }
        return nil
    }

    /// Blocked unless notes are selected in the piano roll.
    @MainActor
    private static func needsNotes(_ context: StudioPaletteContext) -> String? {
        if let why = needsRoll(context) { return why }
        return context.pianoRoll!.selection.isEmpty ? StudioPaletteContext.noNotesReason : nil
    }

    /// Blocked unless the effects panel's controller is present.
    @MainActor
    private static func needsRouting(_ context: StudioPaletteContext) -> String? {
        context.routing == nil ? StudioPaletteContext.noEffectsReason : nil
    }

    // MARK: Every row

    static let all: [StudioPaletteCommand] = [

        // ---- The project ----

        StudioPaletteCommand(
            "project.save", "Save the project", keys: "Cmd S",
            perform: { _, _ in
                Task { @MainActor in await StudioProjectSaver.shared.save(force: true) }
            }),

        StudioPaletteCommand(
            "project.setTempo", "Set the song's speed",
            argument: .number(label: "Beats per minute", unit: .plain, range: 20...300),
            perform: { ctx, v in ctx.model.setTempo(bpm: v.number) })
            .prefilled(number: { $0.snapshot?.tempoBPM ?? 120 }),

        // One text field rather than two numbers, because "3/4" is how a time
        // signature is written everywhere else in music and asking for a
        // numerator and a denominator separately would be a second notation.
        StudioPaletteCommand(
            "project.setTimeSig", "Set how many beats are in a bar",
            argument: .text(label: "Time signature", placeholder: "4/4"),
            block: { _ in nil },
            perform: { ctx, v in
                guard let sig = StudioPaletteParse.timeSignature(v.text) else { return }
                ctx.model.setTimeSig(numerator: sig.beatsPerBar, denominator: sig.beatUnit)
            })
            .prefilled(text: { ctx in
                let sig = ctx.model.timeSignature
                return "\(sig.beatsPerBar)/\(sig.beatUnit)"
            }),

        StudioPaletteCommand(
            "project.setKey", "Set the song's key",
            argument: .text(label: "Key", placeholder: "A minor"),
            perform: { ctx, v in ctx.model.setKey(v.text) })
            .prefilled(text: { $0.snapshot?.key ?? "C major" }),

        // Where bar 1 begins. A recording that starts mid-bar makes every bar
        // line wrong until this is moved, and there is no other control for it
        // anywhere in the app.
        StudioPaletteCommand(
            "project.setPhaseAnchor", "Make bar 1 start at the play head",
            perform: { ctx, _ in
                ctx.model.sendFromPalette(.catalog(
                    name: "project.setPhaseAnchor",
                    params: ["anchorTicks": ctx.playheadTicks]))
            }),

        // ---- Getting around ----

        StudioPaletteCommand(
            "transport.play", "Play, or pause where you are", keys: "Space",
            perform: { ctx, _ in _ = ctx.model.togglePlayback() }),

        StudioPaletteCommand(
            "transport.stop", "Stop and go back to the beginning",
            perform: { ctx, _ in ctx.model.stop() }),

        StudioPaletteCommand(
            "transport.seek", "Jump the play head to a bar",
            argument: .number(label: "Bar", unit: .plain, range: 1...10_000),
            perform: { ctx, v in
                // Bars are 1-based on screen and 0-based in ticks. Off by one
                // here would land every jump a bar early, which reads as "seek
                // is broken" rather than "seek is off by one".
                let bar = max(1, v.int) - 1
                ctx.model.seek(toTicks: ctx.model.barGrid.tickForBarIndex(Int64(bar)))
            })
            .prefilled(number: { ctx in
                Double(ctx.model.barGrid.barNumber(at: ctx.playheadTicks))
            }),

        StudioPaletteCommand(
            "transport.loop.set", "Play the selected bars over and over",
            block: { ctx in
                ctx.model.selection.region == nil
                    ? "Drag across the bar numbers at the top to choose the bars first."
                    : nil
            },
            perform: { ctx, _ in
                guard let region = ctx.model.selection.region else { return }
                ctx.model.setLoop(startTicks: region.startTicks, endTicks: region.endTicks)
            }),

        StudioPaletteCommand(
            "transport.loop.clear", "Stop looping and play straight through",
            block: { ctx in
                ctx.model.effectiveLoopRegion == nil ? "Nothing is looping right now." : nil
            },
            perform: { ctx, _ in ctx.model.clearLoop() }),

        StudioPaletteCommand(
            "transport.metronome", "Turn the click on or off",
            perform: { ctx, _ in ctx.model.toggleMetronome() }),

        // ---- Tracks ----

        StudioPaletteCommand(
            "track.add", "Add an empty track",
            argument: .text(label: "Track name", placeholder: "Track"),
            perform: { ctx, v in
                // The id is minted here, exactly as `trackAdd`'s own comment
                // says it must be: the track does not exist yet, so there is
                // nothing for the engine to name.
                ctx.model.sendFromPalette(.trackAdd(
                    trackID: "trk_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))",
                    name: v.text,
                    index: ctx.snapshot?.tracks.count ?? 0))
            }),

        StudioPaletteCommand(
            "track.remove", "Delete the track and everything on it",
            destructive: true, block: needsTrack,
            perform: { ctx, _ in
                guard let track = ctx.targetTrack else { return }
                _ = ctx.model.deleteTrack(track.id)
            }),

        StudioPaletteCommand(
            "track.mute", "Silence this track, or bring it back",
            block: needsTrack,
            perform: { ctx, _ in
                guard let track = ctx.targetTrack else { return }
                ctx.model.setTrackMute(track.id, muted: !track.muted)
            }),

        StudioPaletteCommand(
            "track.solo", "Hear only this track, or stop",
            block: needsTrack,
            perform: { ctx, _ in
                guard let track = ctx.targetTrack else { return }
                ctx.model.setTrackSolo(track.id, soloed: !track.soloed)
            }),

        StudioPaletteCommand(
            "track.arm", "Make this the track recording captures onto",
            block: needsTrack,
            perform: { ctx, _ in
                guard let track = ctx.targetTrack else { return }
                ctx.model.setTrackArm(track.id, armed: !track.armed)
            }),

        StudioPaletteCommand(
            "track.setInputChannel", "Choose which microphone socket this track records from",
            argument: .number(label: "Input number", unit: .plain, range: 1...64),
            block: needsTrack,
            perform: { ctx, v in
                guard let track = ctx.targetTrack else { return }
                // Sockets are numbered from 1 on the hardware and from 0 on the
                // wire. The person reading the back of their interface sees 1.
                ctx.model.setInputChannel(trackID: track.id, channel: max(0, v.int - 1))
            })
            .prefilled(number: { ctx in Double((ctx.targetTrack?.inputChannel ?? 0) + 1) }),

        // ---- Instruments ----

        StudioPaletteCommand(
            "device.add", "Put a playable sound on this track",
            block: { ctx in
                if let why = needsTrack(ctx) { return why }
                return ctx.targetTrack!.devices.isEmpty
                    ? nil
                    : "This track already has an instrument on it."
            },
            perform: { ctx, _ in
                guard let track = ctx.targetTrack else { return }
                _ = ctx.model.addInstrument(trackID: track.id)
            }),

        StudioPaletteCommand(
            "device.remove", "Take the instrument off this track",
            destructive: true,
            block: { ctx in
                if let why = needsTrack(ctx) { return why }
                return ctx.targetTrack!.devices.isEmpty
                    ? "This track has no instrument on it."
                    : nil
            },
            perform: { ctx, _ in
                guard let track = ctx.targetTrack, let device = track.devices.first else { return }
                _ = ctx.model.removeInstrument(trackID: track.id, deviceID: device.id)
            }),

        // ---- Recording ----

        StudioPaletteCommand(
            "record.start", "Start recording", keys: "Cmd R",
            block: { ctx in
                if ctx.model.isRecording { return "Already recording." }
                return ctx.model.firstArmedTrack == nil
                    ? "Arm a track first — the round red button on its header."
                    : nil
            },
            perform: { ctx, _ in ctx.model.toggleRecord() }),

        StudioPaletteCommand(
            "record.rotate", "Keep what you just played and start a fresh take",
            block: { ctx in ctx.model.isRecording ? nil : "Nothing is recording right now." },
            perform: { ctx, _ in ctx.model.sendFromPalette(.recordRotate) }),

        StudioPaletteCommand(
            "record.stop", "Stop recording and keep the take",
            block: { ctx in ctx.model.isRecording ? nil : "Nothing is recording right now." },
            perform: { ctx, _ in ctx.model.stopRecording() }),

        StudioPaletteCommand(
            "record.cancel", "Stop recording and throw the take away",
            destructive: true,
            block: { ctx in ctx.model.isRecording ? nil : "Nothing is recording right now." },
            perform: { ctx, _ in ctx.model.cancelRecording() }),

        StudioPaletteCommand(
            "record.inputListen", "Listen to the microphone without recording",
            block: { ctx in
                ctx.model.isRecording ? "Stop recording first." : nil
            },
            perform: { ctx, _ in ctx.model.toggleInputListen() }),

        // ---- MIDI hardware ----

        StudioPaletteCommand(
            "midi.learn.start", "Learn a knob: move one on your controller to bind it",
            perform: { ctx, _ in
                ctx.model.sendFromPalette(.catalog(name: "midi.learn.start", params: [:]))
            }),

        StudioPaletteCommand(
            "midi.learn.stop", "Stop learning controller knobs",
            perform: { ctx, _ in
                ctx.model.sendFromPalette(.catalog(name: "midi.learn.stop", params: [:]))
            }),

        StudioPaletteCommand(
            "midi.reload", "Look for MIDI keyboards that were plugged in since launch",
            perform: { ctx, _ in
                ctx.model.sendFromPalette(.catalog(name: "midi.reload", params: [:]))
            }),

        // ---- Clips ----

        StudioPaletteCommand(
            "clip.split", "Cut the clip in two at the play head", keys: "Cmd E",
            block: { ctx in
                guard let snapshot = ctx.snapshot else { return "The project is still loading." }
                let targets = StudioSelectionOps.splitTargets(
                    atTicks: ctx.playheadTicks, selection: ctx.model.selection,
                    tracks: snapshot.tracks)
                return targets.isEmpty
                    ? "Put the play head inside a clip first — the cut happens where the line is."
                    : nil
            },
            perform: { ctx, _ in ctx.model.splitAtPlayhead() }),

        StudioPaletteCommand(
            "clip.duplicate", "Make a copy of the clip right after it", keys: "Cmd D",
            block: needsClip,
            perform: { ctx, _ in ctx.model.duplicateSelection() }),

        StudioPaletteCommand(
            "clip.remove", "Delete the selected clip", keys: "Delete",
            destructive: true, block: needsClip,
            perform: { ctx, _ in _ = ctx.model.deleteSelection() }),

        StudioPaletteCommand(
            "clip.move", "Move the selected clip to the play head",
            block: { ctx in
                if let why = needsClip(ctx) { return why }
                return ctx.targetClip!.startTicks == ctx.playheadTicks
                    ? "The clip already starts at the play head."
                    : nil
            },
            perform: { ctx, _ in
                guard let clip = ctx.targetClip, let track = ctx.targetTrack else { return }
                ctx.model.sendFromPalette(.clipMove(
                    clipID: clip.id, toTrackID: track.id, toStartTicks: ctx.playheadTicks))
            }),

        StudioPaletteCommand(
            "clip.trim", "Shorten the clip so it ends at the play head",
            block: { ctx in
                if let why = needsClip(ctx) { return why }
                let clip = ctx.targetClip!
                return (ctx.playheadTicks > clip.startTicks && ctx.playheadTicks < clip.endTicks)
                    ? nil
                    : "Put the play head inside the clip first — that is where the new end goes."
            },
            perform: { ctx, _ in
                guard let clip = ctx.targetClip else { return }
                ctx.model.sendFromPalette(.clipTrim(
                    clipID: clip.id,
                    newStartTicks: clip.startTicks,
                    newLengthTicks: ctx.playheadTicks - clip.startTicks))
            }),

        StudioPaletteCommand(
            "clip.fade.set", "Fade the clip in from silence",
            argument: .number(label: "Fade length in beats", unit: .plain, range: 0...32),
            block: needsClip,
            perform: { ctx, v in
                guard let clip = ctx.targetClip else { return }
                ctx.model.sendFromPalette(.clipFadeSet(
                    clipID: clip.id,
                    fadeInTicks: Int64(v.number * Double(StudioTick.ppq)),
                    fadeOutTicks: clip.fadeOutTicks))
            })
            .prefilled(number: { ctx in
                Double(ctx.targetClip?.fadeInTicks ?? 0) / Double(StudioTick.ppq)
            }),

        // ---- The mixer ----

        StudioPaletteCommand(
            "mix.gain", "Set this track's volume",
            argument: .number(label: "Volume", unit: .decibels, range: -60...12),
            block: needsTrack,
            perform: { ctx, v in
                guard let track = ctx.targetTrack else { return }
                ctx.model.setTrackGain(track.id, gainDB: v.number)
            })
            .prefilled(number: { $0.targetTrack?.volumeDB ?? 0 }),

        StudioPaletteCommand(
            "mix.pan", "Move this track left or right in the stereo picture",
            argument: .number(label: "Position", unit: .pan, range: -1...1),
            block: needsTrack,
            perform: { ctx, v in
                guard let track = ctx.targetTrack else { return }
                ctx.model.setTrackPan(track.id, pan: v.number)
            })
            .prefilled(number: { $0.targetTrack?.pan ?? 0 }),

        StudioPaletteCommand(
            "mix.send", "Send a copy of this track to effect bus A",
            argument: .number(label: "How much", unit: .percent, range: 0...1),
            block: needsTrack,
            perform: { ctx, v in
                guard let track = ctx.targetTrack else { return }
                ctx.model.setTrackSend(track.id, bus: .a, amount: v.number)
            })
            .prefilled(number: { $0.targetTrack?.sendA ?? 0 }),

        StudioPaletteCommand(
            "mix.master.gain", "Set the volume of the whole song",
            argument: .number(label: "Volume", unit: .decibels, range: -60...12),
            perform: { ctx, v in ctx.model.setMasterGain(v.number) })
            .prefilled(number: { $0.snapshot?.master.volumeDB ?? 0 }),

        StudioPaletteCommand(
            "mix.limiter.set", "Turn the safety catch on the final volume on or off",
            perform: { ctx, _ in
                let master = ctx.snapshot?.master
                ctx.model.setLimiter(
                    enabled: !(master?.limiterEnabled ?? false),
                    ceilingDB: master?.limiterCeilingDBTP ?? -1.0,
                    releaseMs: master?.limiterReleaseMs ?? 50)
            }),

        // ---- Automation ----

        StudioPaletteCommand(
            "autolane.show", "Show or hide this track's volume curve",
            block: needsTrack,
            perform: { ctx, _ in
                guard let track = ctx.targetTrack else { return }
                ctx.model.setAutoLaneVisible(
                    track.id, target: .volume,
                    visible: !ctx.model.isAutoLaneShown(track, target: .volume))
            }),

        StudioPaletteCommand(
            "autopoint.add", "Pin this track's volume where the play head is",
            block: needsTrack,
            perform: { ctx, _ in
                guard let track = ctx.targetTrack else { return }
                ctx.model.addAutoPoint(
                    track.id, target: .volume, id: ctx.model.mintAutoPointID(),
                    positionTicks: ctx.playheadTicks, value: track.volumeDB)
            }),

        StudioPaletteCommand(
            "autolane.clear", "Throw away this track's whole volume curve",
            destructive: true, block: needsTrack,
            perform: { ctx, _ in
                guard let track = ctx.targetTrack else { return }
                ctx.model.clearAutoLane(track.id, target: .volume)
            }),

        // ---- Notes (the piano roll) ----
        //
        // Everything here goes through the roll's controller, which holds the
        // note ids, the grid and the selection. Sending note commands from the
        // view model instead would mean re-deriving all three somewhere they do
        // not live, and getting the grid wrong is how a quantize lands on the
        // wrong lines.

        StudioPaletteCommand(
            "note.quantize", "Pull the selected notes onto the beat", keys: "Cmd U",
            argument: .number(label: "How far, as a percentage", unit: .percent, range: 0...1),
            block: { ctx in
                if let why = needsNotes(ctx) { return why }
                return ctx.pianoRoll!.quantizeGridTicks == nil
                    ? "The piano roll's grid is set to Off, so there are no lines to pull the notes to."
                    : nil
            },
            perform: { ctx, v in
                guard let roll = ctx.pianoRoll else { return }
                roll.quantizeStrengthPercent = max(0, min(100, Int((v.number * 100).rounded())))
                roll.quantizeSelection()
            })
            .prefilled(number: { ctx in
                Double(ctx.pianoRoll?.quantizeStrengthPercent ?? 80) / 100
            }),

        StudioPaletteCommand(
            "note.remove", "Delete the selected notes",
            destructive: true, block: needsNotes,
            perform: { ctx, _ in ctx.pianoRoll?.deleteSelection() }),

        StudioPaletteCommand(
            "note.duplicate", "Copy the selected notes one grid step later",
            block: needsNotes,
            perform: { ctx, _ in ctx.pianoRoll?.duplicateSelection() }),

        StudioPaletteCommand(
            "note.move", "Nudge the selected notes earlier or later",
            argument: .number(label: "Grid steps (negative is earlier)", unit: .plain, range: -64...64),
            block: needsNotes,
            perform: { ctx, v in
                ctx.pianoRoll?.nudgeSelection(gridSteps: v.int, semitones: 0)
            })
            .prefilled(number: { _ in 1 }),

        // Moved out of `excluded`, where its reason read "Reachable only by
        // dragging a note's edge today — see the lane report." That was an
        // accurate description of a defect, not a decision: the only way to
        // change a note's length was a fine-motor grab on a 3 pt edge, which is
        // not a gesture at all from a couch. There is a Shift-arrow binding now
        // and this row is the other half — Cmd-K, type "longer", Return.
        StudioPaletteCommand(
            "note.resize", "Make the selected notes longer or shorter", keys: "Shift \u{2190} / Shift \u{2192}",
            argument: .number(label: "Grid steps (negative is shorter)", unit: .plain, range: -64...64),
            block: { ctx in
                if let why = needsNotes(ctx) { return why }
                return ctx.pianoRoll!.quantizeGridTicks == nil
                    ? "The piano roll's grid is set to Off, so there is no step to make a note longer by."
                    : nil
            },
            perform: { ctx, v in ctx.pianoRoll?.resizeSelection(gridSteps: v.int) })
            .prefilled(number: { _ in 1 }),

        StudioPaletteCommand(
            "note.velocity.set", "Make the selected notes harder or softer",
            argument: .number(label: "Change (negative is softer)", unit: .plain, range: -127...127),
            block: needsNotes,
            perform: { ctx, v in ctx.pianoRoll?.nudgeVelocity(by: v.int) })
            .prefilled(number: { _ in 10 }),

        // ---- Buses and effects ----
        //
        // Through the routing controller, which is the only thing that knows
        // the engine's own node ids and mints new ones in the shape the wire
        // requires.

        StudioPaletteCommand(
            "route.node.add", "Make a new effect bus",
            argument: .text(label: "Bus name", placeholder: "Reverb bus"),
            block: needsRouting,
            perform: { ctx, v in _ = ctx.routing?.addBus(kind: .bus, name: v.text) }),

        StudioPaletteCommand(
            "route.node.remove", "Delete the bus the effects panel is showing",
            destructive: true,
            block: { ctx in
                if let why = needsRouting(ctx) { return why }
                guard case .bus = ctx.routing!.focus else {
                    return "Open a bus in the Effects panel first — the master and the tracks cannot be deleted."
                }
                return nil
            },
            perform: { ctx, _ in
                guard case .bus(let id) = ctx.routing?.focus else { return }
                ctx.routing?.removeBus(id)
            }),

        StudioPaletteCommand(
            "route.node.set", "Set the volume of the bus the effects panel is showing",
            argument: .number(label: "Volume", unit: .decibels, range: -60...12),
            block: { ctx in
                if let why = needsRouting(ctx) { return why }
                guard case .bus = ctx.routing!.focus else {
                    return "Open a bus in the Effects panel first."
                }
                return nil
            },
            perform: { ctx, v in
                guard case .bus(let id) = ctx.routing?.focus else { return }
                ctx.routing?.setNodeGain(id, gainDB: v.number)
            })
            .prefilled(number: { ctx in
                guard case .bus(let id) = ctx.routing?.focus,
                      let node = ctx.routing?.state.node(id) else { return 0 }
                return node.gainDB
            }),

        StudioPaletteCommand(
            "fx.add", "Add an effect to whatever the Effects panel is showing",
            argument: .text(label: "Effect", placeholder: "reverb"),
            block: needsRouting,
            perform: { ctx, v in
                guard let routing = ctx.routing,
                      let kind = StudioPaletteParse.fxKind(v.text) else { return }
                _ = routing.addFx(to: routing.focus, kind: kind)
            }),

        StudioPaletteCommand(
            "fx.remove", "Take the selected effect off",
            destructive: true,
            block: { ctx in
                if let why = needsRouting(ctx) { return why }
                return ctx.routing!.selectedFxID == nil
                    ? "Click an effect in the Effects panel first."
                    : nil
            },
            perform: { ctx, _ in
                guard let routing = ctx.routing, let id = routing.selectedFxID else { return }
                routing.removeFx(from: routing.focus, id: id)
            }),

        StudioPaletteCommand(
            "fx.move", "Move the selected effect earlier or later in the chain",
            argument: .number(label: "Position in the chain", unit: .plain, range: 1...32),
            block: { ctx in
                if let why = needsRouting(ctx) { return why }
                return ctx.routing!.selectedFxID == nil
                    ? "Click an effect in the Effects panel first."
                    : nil
            },
            perform: { ctx, v in
                guard let routing = ctx.routing, let id = routing.selectedFxID else { return }
                routing.moveFx(on: routing.focus, id: id, toIndex: max(0, v.int - 1))
            })
            .prefilled(number: { ctx in
                guard let routing = ctx.routing, let id = routing.selectedFxID,
                      let index = routing.state.chain(for: routing.focus)
                          .firstIndex(where: { $0.id == id }) else { return 1 }
                return Double(index + 1)
            }),

        StudioPaletteCommand(
            "fx.sidechain.clear", "Stop this effect listening to another track",
            block: { ctx in
                if let why = needsRouting(ctx) { return why }
                guard let routing = ctx.routing, let id = routing.selectedFxID else {
                    return "Click an effect in the Effects panel first."
                }
                return routing.state.fx(on: routing.focus, id: id)?.sidechain == nil
                    ? "This effect is not listening to anything."
                    : nil
            },
            perform: { ctx, _ in
                guard let routing = ctx.routing, let id = routing.selectedFxID else { return }
                routing.clearSidechain(on: routing.focus, id: id)
            }),
    ]

    /// Every catalog command the palette deliberately does NOT offer, and why.
    ///
    /// This exists so an exclusion is a DECISION with a sentence attached rather
    /// than an omission nobody notices. `StudioPaletteReachTests` asserts that
    /// `all` and `excluded` together name every command in the catalog exactly
    /// once, so a command added later cannot slip past unconsidered — it has to
    /// be offered or refused in writing.
    static let excluded: [String: String] = [
        // Need a file the palette cannot name.
        "project.new": "Creating a package needs a save panel to choose where it goes.",
        "project.open": "Opening a project needs a file panel.",
        "import.audio": "Needs a file to import; the Import button opens the picker.",
        "import.stems": "Needs a folder of stems; the browser opens the picker.",
        "export.master": "Needs somewhere to write to; the palette opens the export panel instead.",
        "export.stems": "Needs somewhere to write to; the palette opens the export panel instead.",
        "export.region": "Needs somewhere to write to; the palette opens the export panel instead.",
        "export.manifest": "Needs somewhere to write to; the palette opens the export panel instead.",
        "midi.map.import": "Needs a mapping file; MIDI settings opens the picker.",
        "midi.map.export": "Needs somewhere to write to; MIDI settings opens the picker.",

        // Carry an id or an object only another surface can produce.
        "clip.place": "The asset hash is minted by an import; there is nothing to type.",
        "publish.track": "Needs an asset hash and a metadata block from a finished export.",
        "studio.importStemSession": "Needs a stem session id; the browser is where one is chosen.",
        "device.zone.add": "Needs a sound file's asset hash, which only loading a sound produces.",
        "device.zone.remove": "Needs a zone id; the drum pad grid is where a pad is chosen.",
        "device.param.set": "A parameter and a value are two choices; the instrument panel names them.",
        "device.param.clear": "A parameter is a choice from the instrument's own list.",
        "fx.param.set": "A parameter and a value are two choices; the effects panel types both.",
        "fx.param.clear": "A parameter is a choice from the effect's own list.",
        "fx.sidechain.set": "Needs a source node as well as a target; the effects panel picks both.",
        "route.connect": "Needs two endpoints; the effects panel is where both are chosen.",
        "route.disconnect": "Needs a connection id; the effects panel is where one is clicked.",
        "route.edge.set": "Needs a connection id; the effects panel is where one is clicked.",
        "autopoint.move": "Needs a point id; a curve point is dragged where it is drawn.",
        "autopoint.remove": "Needs a point id; a curve point is deleted where it is drawn.",
        "midi.device.select": "The device name comes from the list of what is plugged in.",
        "midi.port.role.set": "Needs a port name from the list of what is plugged in.",
        "midi.binding.set": "Needs the control's own message; that is what MIDI learn captures.",
        "midi.binding.clear": "Needs the control's own message; MIDI settings lists the bindings.",
        "take.promote": "Needs a take id; the takes browser is where a take is chosen.",
        "take.discard": "Needs a take id; the takes browser is where a take is chosen.",
        "take.purge": "Needs a take id; the takes browser is where a take is chosen.",
        "take.restore": "Needs a take id; the takes browser is where a take is chosen.",
        "take.auditionMix": "Needs a take id and a stem set; the takes browser owns both.",
        "note.add": "A note is a pitch, a place and a length; the piano roll is where it is drawn.",
        "note.timing.set": "Carries an absolute position for every note at once — it is what a quantize computes, not something a person types.",
        "clip.placeMidi": "The empty-clip gesture is the Instrument button, which also opens the roll.",

        // More than one value, where a second notation would have to be invented.
        "mix.eq": "A band, a frequency, a gain and a Q are four choices; the mixer's EQ has all four.",
        "clip.crossfade.set": "Needs two clips and a length; the overlap is made by dragging.",
        "clip.warp.set": "Needs a mode and a ratio; the clip's own menu is where both are set.",
        "clip.phaseAnchor.set": "Per-clip anchoring is an import-time correction, not a live edit.",

        // The generation surface builds a whole request object.
        "gen.song": "The whole request — style, length, lyrics — is built in Generate.",
        "gen.revise": "The request is built in the Revise panel; the palette opens it.",
        "gen.extend": "The request is built in the Revise panel.",
        "gen.layer": "The request is built in the Revise panel.",
        "gen.retake": "Needs a take id and a request; the takes browser owns both.",
        "gen.autocomplete": "The request is built in the Revise panel.",
        "gen.cover": "The request is built in the Revise panel.",
        "gen.separate": "Needs a clip and an engine choice; the clip's own menu offers it.",
        "gen.cancel": "Needs the id of the request in flight; the queue has a Cancel on each row.",
        "gen.finalize": "Needs a draft take and a quality rung; the audition bar offers it.",
        "gen.landed": "Written by the engine when a generation lands. Never authored by a person.",

        // Brackets, not actions.
        "txn.begin": "A bracket around other commands. Firing one alone would leave the journal open.",
        "txn.commit": "A bracket around other commands. There is nothing to commit on its own.",

        // Reachable only through a send that carries the wrong contract.
        //
        // These eleven have a view-model gesture and a context menu, but that
        // gesture sends a `.catalog` envelope carrying the UI's UUID and the
        // MOCK engine's parameter names (`gain` for `gainDb`, `height` for
        // `heightPx`, `index` for `newIndex`, `name`/`bar` for
        // `label`/`positionTicks`). The real engine addresses `t1` / `clip_…`
        // and validates the schema, and `StudioViewModel.send` discards the
        // result — so on a real-engine build they are refused silently. The
        // palette will not multiply that; see the lane report.
        "track.rename": "Its only path sends a UI id and mock-shaped parameters — see the lane report.",
        "track.reorder": "Its only path sends a UI id and mock-shaped parameters — see the lane report.",
        "track.setColor": "Its only path sends a UI id and mock-shaped parameters — see the lane report.",
        "track.setHeight": "Its only path sends a UI id and mock-shaped parameters — see the lane report.",
        "clip.rename": "Its only path sends a UI id and mock-shaped parameters — see the lane report.",
        "clip.setGain": "Its only path sends a UI id and mock-shaped parameters — see the lane report.",
        "clip.mute": "Its only path sends a UI id and mock-shaped parameters — see the lane report.",
        "marker.set": "Its only path sends mock-shaped parameters — see the lane report.",
        "marker.remove": "Its only path sends a UI id — see the lane report.",
        "section.set": "Its only path sends mock-shaped parameters — see the lane report.",
        "section.remove": "Its only path sends a UI id — see the lane report.",
    ]
}

// MARK: - Reading the two typed strings that are not numbers

/// The two text arguments that mean something specific. Separate from the
/// entries so they can be unit-tested without a view model, and strict for the
/// same reason `StudioParamUnit.parse` is: a typo must revert, never be read as
/// a default.
enum StudioPaletteParse {

    /// "3/4", "6/8", "4 / 4". nil for anything the engine would refuse — the
    /// denominator has to be a power of two, which is what the catalog's own
    /// enum says.
    static func timeSignature(_ raw: String) -> StudioTimeSignature? {
        let parts = raw.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2,
              let numerator = Int(parts[0]), let denominator = Int(parts[1]),
              numerator >= 1, numerator <= 32,
              [1, 2, 4, 8, 16, 32].contains(denominator) else { return nil }
        return StudioTimeSignature(beatsPerBar: numerator, beatUnit: denominator)
    }

    /// "reverb", "Reverb", "EQ". Matched against the nine kinds by raw value
    /// and by the label printed on the chain slot, because both are on screen.
    static func fxKind(_ raw: String) -> StudioFxKind? {
        let needle = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return StudioFxKind.allCases.first {
            $0.rawValue == needle || $0.label.lowercased() == needle
        }
    }
}
