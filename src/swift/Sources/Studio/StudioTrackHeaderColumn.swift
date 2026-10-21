import SwiftUI

// MARK: - Track header column
//
// Real SwiftUI views (not canvas) so VoiceOver reads every track header.
// Rows come from the same StudioRowLayoutBuilder the canvas uses, so header
// rows and lanes can never disagree.

struct StudioTrackHeaderColumn: View {
    @ObservedObject var model: StudioViewModel

    private var rulerHeight: CGFloat {
        StudioTokens.sectionRulerHeight + StudioTokens.barRulerHeight
            + StudioTokens.loopRulerHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            corner
            GeometryReader { _ in
                content
                    .offset(y: -model.scrollY)
            }
            .clipped()
        }
        .frame(width: StudioTokens.trackHeaderWidth)
        .background(StudioTokens.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(StudioTokens.strokeSoft).frame(width: 1)
        }
    }

    private var corner: some View {
        HStack {
            Text("TRACKS")
                .font(.system(size: 9, weight: .bold))
                .kerning(1)
                .foregroundStyle(StudioTokens.faint)
            Spacer()
        }
        .padding(.horizontal, 9)
        .frame(height: rulerHeight)
        .background(StudioTokens.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioTokens.strokeSoft).frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = model.snapshot {
            let rows = StudioRowLayoutBuilder.rows(
                tracks: snapshot.tracks, expandedTakeLanes: model.expandedTakeLanes,
                visibleAutomationLanes: model.visibleAutomationLanes)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    switch row.kind {
                    case .track(let trackID):
                        if let track = snapshot.tracks.first(where: { $0.id == trackID }) {
                            StudioTrackHeaderRow(model: model, track: track, height: row.height)
                        }
                    case .takeLane(let trackID):
                        if let track = snapshot.tracks.first(where: { $0.id == trackID }),
                           let lane = track.takeLane {
                            takeLaneHeader(track: track, lane: lane, height: row.height)
                        }
                    case .automation(let trackID, let target):
                        if let track = snapshot.tracks.first(where: { $0.id == trackID }) {
                            automationHeader(track: track, target: target, height: row.height)
                        }
                    }
                }
            }
        }
    }

    private func takeLaneHeader(
        track: StudioTrackSnapshot,
        lane: StudioTakeLaneSnapshot,
        height: CGFloat
    ) -> some View {
        HStack(spacing: 4) {
            Button {
                model.toggleTakeLane(track.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                    Text("takes")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(StudioTokens.dim)
            }
            .buttonStyle(.plain)
            .studioHelp("trackHeader.takes.hide")
            .accessibilityLabel("Takes for \(track.name)")
            .accessibilityValue("\(lane.takes.count) takes, expanded")
            .accessibilityHint("Collapses the take lane")
            Spacer()
        }
        .padding(.leading, 22)
        .frame(height: height, alignment: .top)
        .padding(.top, 0)
        .background(StudioTokens.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioTokens.strokeSoft).frame(height: 1)
        }
    }

    private func automationHeader(track: StudioTrackSnapshot, target: StudioAutoTarget, height: CGFloat) -> some View {
        let points = track.automation(target)
        return HStack(spacing: 4) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(StudioTokens.cyan.opacity(0.85))
            Text(target.label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(StudioTokens.dim)
            Spacer(minLength: 0)
            // The glyphs are 7 pt. Under .buttonStyle(.plain) with no frame or
            // background the clickable area IS the glyph (~8x8 pt), so these
            // read as dead unless clicked dead-centre. The frame + contentShape
            // give them a real target without changing how they look.
            if !points.isEmpty {
                Button {
                    model.clearAutoLane(track.id, target: target)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(StudioTokens.faint)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .studioHelp("trackHeader.automation.clear")
                .accessibilityLabel("Clear \(target.label) automation on \(track.name)")
            }
            Button {
                model.setAutoLaneVisible(track.id, target: target, visible: false)
            } label: {
                Image(systemName: "eye.slash")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(StudioTokens.faint)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!points.isEmpty)   // a lane with points stays shown (engine truth)
            .opacity(points.isEmpty ? 1 : 0.35)
            // The greyed-out state is where this tooltip earns its keep: a 35%
            // eye that does nothing when clicked is otherwise indistinguishable
            // from a broken one, and the teaching text is the only thing that
            // says WHY a lane carrying points refuses to be hidden.
            .studioHelp("trackHeader.automation.hide")
            .accessibilityLabel("Hide \(target.label) automation lane")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(height: height)
        .background(StudioTokens.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioTokens.strokeSoft).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(target.label) automation lane for \(track.name)")
        .accessibilityValue("\(points.count) points")
    }
}

// MARK: - Single track header

struct StudioTrackHeaderRow: View {
    @ObservedObject var model: StudioViewModel
    let track: StudioTrackSnapshot
    let height: CGFloat
    @State private var isEditingTrackName = false
    @State private var editedTrackName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(StudioTokens.stemColor(track.kind))
                    .frame(width: 8, height: 8)
                if isEditingTrackName {
                    TextField("Track name", text: $editedTrackName, onCommit: {
                        model.renameTrack(track.id, name: editedTrackName)
                        isEditingTrackName = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(StudioTokens.text)
                    .frame(maxWidth: 120)
                    .onAppear {
                        editedTrackName = track.name
                    }
                    .onExitCommand {
                        isEditingTrackName = false
                    }
                } else {
                    // `lineLimit(1)` and deliberately NOT `fixedSize()`. This is
                    // the one Text on the row that may be arbitrarily long (it
                    // is user-typed), so refusing to shrink it would push the
                    // identity slot out of the column rather than truncate. The
                    // one-character-per-line failure `fixedSize` guards against
                    // elsewhere cannot happen here because `lineLimit(1)`
                    // already forbids a second line; every FIXED-width Text on
                    // this row carries both.
                    //
                    // No `layoutPriority` either, and that was checked rather
                    // than assumed: a draft of this lane added `layoutPriority(1)`
                    // here on the theory that the name was losing a fair split
                    // with the slot. It renders IDENTICALLY with and without, at
                    // every name length, because the slot beside it carries
                    // `fixedSize()` and therefore never competes for width in
                    // the first place — the name is already the only flexible
                    // child and already gets everything left over. The real fix
                    // for the truncation was upstream: not offering an
                    // instrument to a track that cannot use one.
                    Text(track.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(StudioTokens.text)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            editedTrackName = track.name
                            isEditingTrackName = true
                        }
                }
                if track.takeLane != nil, !model.expandedTakeLanes.contains(track.id) {
                    Button {
                        model.toggleTakeLane(track.id)
                    } label: {
                        // 8 pt chevron: same story as the automation-lane icons,
                        // the bare glyph is a ~9x8 pt target.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(StudioTokens.faint)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .studioHelp("trackHeader.takes.show")
                    .accessibilityLabel("Show takes for \(track.name)")
                }
                Spacer(minLength: 4)
                instrumentSlot
            }
            HStack(spacing: 4) {
                // The help id flips with the state, like the accessibility
                // label already does: a lit M whose tooltip says "Mute" is
                // telling a beginner the opposite of what pressing it will do.
                miniButton(
                    "M", on: track.muted,
                    label: track.muted ? "Unmute \(track.name)" : "Mute \(track.name)",
                    helpID: track.muted ? "mixer.unmute" : "mixer.mute"
                ) {
                    model.setTrackMute(track.id, muted: !track.muted)
                }
                miniButton(
                    "S", on: track.soloed,
                    label: track.soloed ? "Unsolo \(track.name)" : "Solo \(track.name)",
                    helpID: track.soloed ? "mixer.unsolo" : "mixer.solo"
                ) {
                    model.setTrackSolo(track.id, soloed: !track.soloed)
                }
                armButton
                automationMenu
                volumeSliver
                colorMenu
                heightMenu
            }
            originNote
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(height: height, alignment: .top)
        .background(StudioTokens.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioTokens.strokeSoft).frame(height: 1)
        }
        // The destructive affordances. Before this menu existed NOTHING in the
        // GUI could remove a track or an instrument, so every stray click of
        // the Instrument button stacked up forever. Deliberately no
        // confirmation dialog: each action is one journaled undo unit and the
        // engine's undo truthfully restores clips, devices, zones, fx and
        // automation — Cmd-Z is the safety net. A refusal surfaces the
        // engine's own message (it names the remedy).
        //
        // THE tooltip of this lane. Attached to the whole row, above the
        // context menu, so hovering ANY part of a track header — including the
        // dead space beside the name, which is most of it — says how to delete
        // the track. A right-click menu advertises itself to nobody, and "I
        // could not find how to delete a track" is the report that started
        // this; a per-button tooltip would have missed it entirely, because the
        // control the user needed is not a button.
        .studioHelp("trackHeader.row")
        .contextMenu {
            // help-exempt: macOS menu items get no hover tooltip, and their
            // titles are already full sentences ("Remove Instrument (Synth)",
            // "Delete Track"). The teaching for all three lives on
            // `trackHeader.row`, which is the hover that leads a person here.
            ForEach(track.devices) { device in
                Button(track.devices.count == 1
                       ? "Remove Instrument (\(device.instrumentLabel))"
                       : "Remove Instrument (\(device.instrumentLabel))") {
                    model.removeInstrument(trackID: track.id, deviceID: device.id)
                }
            }
            // The panel where a sound gets loaded. In the context menu as well
            // as on the chip, because the chip is 9pt tall: on a 4K TV at couch
            // distance the right-click is the affordance that actually lands.
            //
            // `hasAnEditablePanel`, not `playsSamples`. That predicate is why a
            // Synth track had no route into the panel from anywhere: the chip
            // below was not a button for one either, so the four waveforms and
            // the whole envelope were behind a door with no handle on any side.
            if let device = track.devices.first, device.hasAnEditablePanel {
                Button("Edit \(device.instrumentLabel)…") {
                    model.openInstrumentPanel(trackID: track.id)
                }
            }
            // The way BACK. Before this, removing an instrument was a one-way
            // door: the menu that took it away offered nothing to put it back,
            // and the only "add an instrument" affordance in the whole app made
            // a whole new TRACK.
            //
            // All three kinds now, because a Sampler and a Drum Rack are finally
            // creatable: each one picks its sound in the SAME gesture that makes
            // the instrument, which is not a nicety — an instrument with no
            // sound bound is a hard compile error in the engine, so there is no
            // legal moment between "created" and "has a sound".
            if track.needsInstrument {
                Button("Add Synth") {
                    model.addInstrument(trackID: track.id)
                }
                Button("Add Sampler (pick a sound)…") {
                    guard let path = StudioSoundPicker.pickOne(
                        prompt: "Pick a recording to play across the keyboard.") else { return }
                    model.loadSamplerSound(trackID: track.id, path: path)
                }
                Button("Add Drum Rack (pick sounds)…") {
                    let paths = StudioSoundPicker.pickMany(
                        prompt: "Pick up to \(StudioDrumRack.padCount) sounds, one per pad.")
                    guard !paths.isEmpty else { return }
                    model.loadDrumRack(trackID: track.id, paths: paths)
                }
            }
            Button("Delete Track", role: .destructive) {
                model.deleteTrack(track.id)
            }
            // The one honest pre-guard: deleting the track a capture is
            // landing onto would strand the record session.
            .disabled(model.snapshot?.transport.recordingTrackID == track.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Track \(track.name)")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        // WHAT THE TRACK IS, first — the same fact the badge draws, said in
        // words. Computed on the snapshot so it is testable without a window.
        parts.append(track.roleSummary)
        // WHY it is here, second, when the app is the one that put it here. A
        // sighted user gets this from the line under the row; a VoiceOver user
        // was getting a track appearing out of nowhere with no explanation at
        // all, which is the same complaint with the volume turned up.
        if let note = track.originNote { parts.append(note.lowercased()) }
        parts.append(track.muted ? "muted" : "not muted")
        parts.append(track.soloed ? "soloed" : "not soloed")
        parts.append(String(format: "volume %.1f dB", track.volumeDB))
        parts.append("\(track.clips.count) clips")
        return parts.joined(separator: ", ")
    }

    // MARK: Where this track came from
    //
    // THE APP MAKES A TRACK BY ITSELF in three situations: a key is pressed on a
    // project that has no instrument (`ensure_instrument_target`), Add a Layer
    // puts its new part on a row of its own (`revise::dispatch_layer`), and a
    // stem import gives every file after the first its own row
    // (`import_stems_params`). All three are right — they are what let someone
    // who does not know what a track is sit down and work. What was wrong is
    // that the app then said NOTHING: rows appeared in the arrangement and
    // nothing anywhere explained them.
    //
    // A LINE, not a dialog, and that is the whole design constraint. This fires
    // while the person's hands are on the keys; anything that has to be
    // dismissed interrupts the one moment the app is working. So it sits in the
    // header, under the controls, and it is still there in ten minutes when they
    // finally look down and wonder what "Instrument 1" is.
    //
    // It is derived from `track.origin`, which the engine derives from the
    // journal — the `actor` on `track.add`, or the `reason` on the transaction
    // around it — so it cannot be shown on a track the app did not make, and
    // undoing the creation removes the row and the note together. Nothing here
    // is a separate flag that could drift, and the glyph, the sentence and the
    // help key all come off the SAME enum case, so a fourth origin cannot ship
    // with two of the three filled in.
    @ViewBuilder
    private var originNote: some View {
        if let origin = track.origin {
            let note = origin.note
            HStack(spacing: 3) {
                Image(systemName: origin.symbolName)
                    .font(.system(size: 8))
                    .foregroundStyle(StudioTokens.faint)
                // `lineLimit(1)` + `fixedSize()`, both, like every fixed-width
                // Text on this row: an unconstrained Text in a tight HStack
                // wraps to one character per line.
                //
                // ⚠️ `fixedSize()` means this Text REFUSES to be narrower than
                // its ideal width, so a sentence longer than the 150 pt column
                // pushes the HStack — and the control row above it — sideways
                // rather than truncating. That is not hypothetical: the first
                // draft of the layer and import lines were four and six
                // characters too long, and the raster in
                // `StudioSaysWhatItMadeTests` measured the row above moving by
                // a quarter of a million channel-units. The fence stays here
                // rather than becoming a truncation, because a clipped
                // explanation is an explanation nobody can read, and the test
                // makes "too long" a build failure instead of a bent header.
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(StudioTokens.faint)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .studioHelp(origin.helpKey)
            .accessibilityHidden(true)   // said once, in accessibilitySummary
        }
    }

    // MARK: The identity slot — what this track IS, in one chip
    //
    // WHY THIS EXISTS. Nothing anywhere in the track header said whether a
    // track carried an instrument. So Remove Instrument — which worked, and
    // journaled, and undid correctly — changed NOTHING a person could see, and
    // read as a dead menu item. And the absence it left was equally invisible:
    // the keys went quiet and the only clue was in a context menu you had to
    // already suspect.
    //
    // One slot, THREE states, in the place the eye already goes for this track:
    //   carries an instrument -> a chip naming it. Removal makes it vanish.
    //   carries a recording   -> a badge naming the material: VOCALS, DRUMS,
    //                            BASS, OTHER, AUDIO.
    //   carries neither       -> "+ Instrument", which puts a Synth back.
    //
    // Three and not four: an instrument track does NOT also get a role badge
    // saying "INSTRUMENT". "Synth" / "Sampler" / "Drums" already answers the
    // question, and answers it more precisely — a badge would spend the
    // column's scarcest resource restating a vaguer version of the chip beside
    // it.
    //
    // The second state is what this lane added, and the shipped bug is the
    // argument for it. `needsInstrument` used to be `devices.isEmpty`, so all
    // four stems of a finished song showed "+ Instrument": an offer they could
    // not use, occupying the width the name needed, on a 150 pt column. The
    // names truncated to "Vo…", "Dr…", "Ba…", "Ot…" and the only whole word on
    // a vocal track was "Instrument". Both halves are fixed here — the offer is
    // gone from tracks that cannot take one, and what replaces it is narrower
    // AND finally says what the row is.
    //
    // The empty state stays a BUTTON and not merely blank. A chip that is
    // simply absent is only discoverable by right-clicking something you have
    // no reason to right-click; for someone who says "I don't really know how
    // to use a DAW", that is the same as not existing.
    //
    // Drawn as a Text label, not a Canvas: this is one small piece of text per
    // track, not a dense repeat (the rule that sends the timeline lanes and the
    // keyboard to Canvas). And plainly NOT inside a horizontal ScrollView,
    // which on macOS silently eats Button clicks.
    @ViewBuilder
    private var instrumentSlot: some View {
        if let label = track.instrumentChipLabel, let device = track.devices.first {
            // A sample instrument's chip is a BUTTON onto its panel; a Synth's
            // stays plain text, because a Synth has no sound to load and a
            // button onto an empty panel is worse than no button.
            let chip = Text(label)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(StudioTokens.purple.opacity(0.24)))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(StudioTokens.purple.opacity(0.65), lineWidth: 0.8))
                .foregroundStyle(StudioTokens.text)
            if device.hasAnEditablePanel {
                Button {
                    model.openInstrumentPanel(trackID: track.id)
                } label: {
                    chip.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .studioHelp(
                    terse: "\(device.instrumentLabel): \(soundSummary(device))",
                    teaching: device.makesItsOwnSound
                        ? "This track plays a \(device.instrumentLabel), which makes its own " +
                          "sound rather than playing a recording — \(soundSummary(device)). " +
                          "Click to change what it sounds like: Electric Piano, Soft Pad, " +
                          "Pluck, Bass, Organ. Right-click the track to remove the instrument."
                        : "This track plays a \(device.instrumentLabel) — \(soundSummary(device)). " +
                          "Click to see what it is playing, change it, or load more. " +
                          "Right-click the track to remove the instrument.")
                .accessibilityLabel("Instrument \(device.instrumentLabel)")
                .accessibilityValue(soundSummary(device))
                .accessibilityHint("Open the instrument panel")
            } else {
                chip
                    // Inline rather than a catalog id: the useful half of this
                    // sentence is the device's OWN name, which no static entry
                    // can carry. Moving it off a bare `.help` onto
                    // `.studioHelp` is not cosmetic — a bare `.help` ignored
                    // the verbosity preference, so "No tooltips" left this one
                    // chip still popping up.
                    .studioHelp(
                        terse: track.devices.count == 1
                            ? "Instrument: \(device.instrumentLabel)"
                            : "\(track.devices.count) instruments",
                        teaching: track.devices.count == 1
                            ? "This track plays a \(device.instrumentLabel). Right-click the track to remove it."
                            : "This track carries \(track.devices.count) instruments. Right-click the track to remove one.")
                    .accessibilityLabel("Instrument \(device.instrumentLabel)")
            }
        } else if track.needsInstrument {
            // A MENU, not a button, since a Sampler and a Drum Rack became
            // creatable. Each of the two sample instruments opens a file picker
            // in the SAME gesture that creates it, because the engine refuses
            // an instrument with nothing to play — so "create it now, load a
            // sound later" is not a state that exists.
            Menu {
                // help-exempt: macOS menu items get no hover tooltip. The
                // teaching lives on `trackHeader.instrument.add`, which is the
                // hover that leads a person into this menu.
                Button("Synth — make a sound from nothing") {
                    model.addInstrument(trackID: track.id)
                }
                Button("Sampler — play one recording across the keys…") {
                    guard let path = StudioSoundPicker.pickOne(
                        prompt: "Pick a recording to play across the keyboard.") else { return }
                    model.loadSamplerSound(trackID: track.id, path: path)
                }
                Button("Drum Rack — one sound per pad…") {
                    let paths = StudioSoundPicker.pickMany(
                        prompt: "Pick up to \(StudioDrumRack.padCount) sounds, one per pad.")
                    guard !paths.isEmpty else { return }
                    model.loadDrumRack(trackID: track.id, paths: paths)
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "plus").font(.system(size: 7, weight: .bold))
                    Text("Instrument").font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(StudioTokens.panelHi))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(StudioTokens.stroke, lineWidth: 0.8))
                .foregroundStyle(StudioTokens.dim)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .studioHelp("trackHeader.instrument.add")
            .accessibilityLabel("Add an instrument to \(track.name)")
        } else {
            stemBadge
        }
    }

    /// What an AUDIO track is made of, in the slot an instrument track uses for
    /// its chip. Not a button: there is nothing to open, and a badge that
    /// depressed under the pointer and then did nothing would be worse than a
    /// label.
    ///
    /// Tinted with the SAME `stemColor` as the 8 pt dot two elements to the
    /// left, so the badge teaches what the dot means instead of competing with
    /// it — after a minute of use the colour alone is enough and the word stops
    /// being read, which is the point.
    ///
    /// `lineLimit(1)` + `fixedSize()`, both, and not as boilerplate: this Text
    /// sits in a tight HStack inside a 150 pt column, which is exactly where an
    /// unconstrained Text wraps to ONE CHARACTER PER LINE and blows the row's
    /// height out. "POSITION" and "Generate" each became an 8-line column in the
    /// toolbar in 3.4.8 and squeezed the whole app into the bottom third of the
    /// window. The word here is short and fixed, so `fixedSize` costs nothing
    /// and the name beside it (which carries `layoutPriority`) yields nothing.
    private var stemBadge: some View {
        // The dot's own colour, unconditionally — including for `.imported`,
        // whose `stemColor` is ALREADY the neutral grey the four stem hues are
        // vivid against. Reaching for a different grey here would make the
        // badge and the dot on the same row disagree, which is a worse bug than
        // the one being fixed. So the stem/full-track distinction rides the
        // colour table that already encodes it, plus the word itself.
        let tint = StudioTokens.stemColor(track.kind)
        return Text(track.kind.label.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.4)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.20)))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(tint.opacity(0.65), lineWidth: 0.8))
            .foregroundStyle(StudioTokens.text)
            // Inline rather than a catalog id, for the same reason the plain
            // instrument chip above is: the useful half of the sentence is this
            // track's OWN material, which one static entry cannot carry.
            .studioHelp(
                terse: track.kind.isStem
                    ? "\(track.kind.label) — one stem of a split song"
                    : "Audio — a whole recording",
                teaching: track.kind.isStem
                    ? "This track plays a recording of the \(track.kind.label.lowercased()) " +
                      "on its own, separated out of a finished song. It is one of several " +
                      "parts that belong together, so muting it is a statement about the " +
                      "whole song. It has no instrument and cannot take one — the keys play " +
                      "instruments, not recordings."
                    : "This track plays a recording that arrived whole, rather than one part " +
                      "of a song that was taken apart. It has no instrument and cannot take " +
                      "one — the keys play instruments, not recordings. To play something " +
                      "yourself, add a new track and put an instrument on that.")
            .accessibilityLabel(track.roleSummary)
    }

    /// What the chip's tooltip says the instrument is actually playing. Reading
    /// the ZONES rather than the kind, so a rack with four pads and a rack with
    /// none read differently — the empty case cannot happen through this app,
    /// but a project written by an agent or an older build can hold one.
    private func soundSummary(_ device: StudioDeviceSnapshot) -> String {
        // A synth has no zones and never will; what it "is playing" is its
        // named sound, or the starting one when nobody has picked yet. Saying
        // "no sounds loaded yet" about a synth would be false — it is making a
        // sound right now.
        if device.makesItsOwnSound {
            return StudioInstrumentTone.current(for: device.params)?.name ?? "its starting sound"
        }
        let count = device.zones.count
        if count == 0 { return "no sounds loaded yet" }
        if device.kind == "drum" {
            return "\(count) pad\(count == 1 ? "" : "s") loaded"
        }
        if count == 1, let only = device.zones.first {
            return model.soundName(only.sourceID) ?? "one sound"
        }
        return "\(count) sounds mapped across the keys"
    }

    private func miniButton(
        _ title: String,
        on: Bool,
        label: String,
        helpID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .heavy))
                .frame(width: 20, height: 16)
                .background(on ? StudioTokens.warn : StudioTokens.panelHi)
                .foregroundStyle(on ? Color.black.opacity(0.8) : StudioTokens.dim)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(on ? StudioTokens.warn : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .studioHelp(helpID)
        .accessibilityLabel(label)
    }

    /// Record-arm: a red record dot, filled when armed (the capture target for
    /// Record). Recording energy (the pulse) lives on the transport + record bar.
    private var armButton: some View {
        Button {
            model.toggleArm(track.id)
        } label: {
            Image(systemName: track.armed ? "circle.fill" : "circle")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 16)
                .background(track.armed ? StudioTokens.bad.opacity(0.20) : StudioTokens.panelHi)
                .foregroundStyle(track.armed ? StudioTokens.bad : StudioTokens.dim)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(track.armed ? StudioTokens.bad.opacity(0.7) : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .studioHelp(track.armed ? "trackHeader.disarm" : "trackHeader.arm")
        .accessibilityLabel(track.armed ? "Disarm \(track.name)" : "Arm \(track.name) for recording")
        .accessibilityAddTraits(track.armed ? [.isSelected] : [])
    }

    /// Show/hide the volume + pan automation lanes for this track. A lane with
    /// points stays shown (engine truth) and reads as an always-on toggle.
    private var automationMenu: some View {
        Menu {
            ForEach(StudioAutoTarget.allCases, id: \.self) { target in
                Toggle(
                    "\(target.label.capitalized) automation",
                    isOn: Binding(
                        get: { model.isAutoLaneShown(track, target: target) },
                        set: { model.setAutoLaneVisible(track.id, target: target, visible: $0) }))
            }
        } label: {
            Text("A")
                .font(.system(size: 9, weight: .heavy))
                .frame(width: 20, height: 16)
                .background(automationActive ? StudioTokens.cyan.opacity(0.22) : StudioTokens.panelHi)
                .foregroundStyle(automationActive ? StudioTokens.cyan : StudioTokens.dim)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(automationActive ? StudioTokens.cyan.opacity(0.6) : StudioTokens.stroke, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .studioHelp("trackHeader.automation")
        .accessibilityLabel("Automation lanes for \(track.name)")
    }

    private var automationActive: Bool {
        model.isAutoLaneShown(track, target: .volume) || model.isAutoLaneShown(track, target: .pan)
    }

    /// Live volume indicator; the dock's fader is the control surface.
    private var volumeSliver: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(StudioTokens.stroke).frame(height: 3)
                let norm = max(0, min(1, (track.volumeDB + 24) / 24))
                Circle()
                    .fill(StudioTokens.dim)
                    .frame(width: 9, height: 9)
                    .offset(x: (geo.size.width - 9) * norm)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 16)
        // Applied BEFORE `.accessibilityHidden`, which is what silences the
        // duplicate VoiceOver reading; the tooltip is unaffected, so the one
        // thing on the row that looks like a fader but is not still explains
        // itself on hover.
        .studioHelp("trackHeader.volume")
        .accessibilityHidden(true)   // covered by the header's value summary
    }

    private var colorMenu: some View {
        Menu {
            // The eight swatches, as a TYPE. They used to be eight bare strings
            // — `"blue"`, `"orange"` — and `track.setColor`'s contract is
            // `^#[0-9A-Fa-f]{6}$`, so the engine refused all eight, every time,
            // silently. `StudioTrackColor` carries the hex the wire wants and
            // the word the menu says, so the two cannot come apart again.
            ForEach(StudioTrackColor.allCases, id: \.self) { color in
                Button(color.label) {
                    model.setTrackColor(track.id, color: color)
                }
            }
        } label: {
            Circle()
                .fill(Self.trackColorSwatch(track.color))
                .frame(width: 10, height: 10)
                .padding(.horizontal, 4)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .studioHelp("trackHeader.color")
        .accessibilityLabel("Color for \(track.name)")
    }

    /// The dot's colour for whatever the snapshot stores.
    ///
    /// Hex FIRST, because that is what the engine holds and what the menu now
    /// sends. The eight legacy NAMES still resolve underneath: a project saved
    /// by an older build, or a mock fixture, stores `"blue"`, and a swatch that
    /// silently went grey would look like a bug in the colour feature rather
    /// than in this function.
    private static func trackColorSwatch(_ stored: String) -> Color {
        if let palette = StudioTrackColor.named(stored) {
            switch palette {
            case .blue: return .blue
            case .orange: return .orange
            case .green: return .green
            case .purple: return .purple
            case .pink: return .pink
            case .yellow: return .yellow
            case .teal: return .teal
            case .gray: return .gray
            }
        }
        switch stored {
        case "blue": return .blue
        case "orange": return .orange
        case "green": return .green
        case "purple": return .purple
        case "pink": return .pink
        case "yellow": return .yellow
        case "teal": return .teal
        case "gray": return .gray
        default: return StudioTokens.faint
        }
    }

    private var heightMenu: some View {
        Menu {
            Button("Small") { model.setTrackHeight(track.id, height: 40) }
            Button("Default") { model.setTrackHeight(track.id, height: Int(StudioTokens.trackHeightDefault)) }
            Button("Large") { model.setTrackHeight(track.id, height: 160) }
            Button("X-Large") { model.setTrackHeight(track.id, height: 240) }
        } label: {
            Text("H")
                .font(.system(size: 9, weight: .heavy))
                .frame(width: 16, height: 16)
                .foregroundStyle(StudioTokens.dim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .studioHelp("trackHeader.height")
        .accessibilityLabel("Height for \(track.name)")
    }

    // MARK: Help catalog entries (trackHeader.color, trackHeader.height)
}
