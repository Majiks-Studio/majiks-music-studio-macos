import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - The Sounds section of the browser
//
// WHAT A PERSON CAN DO HERE THAT THEY COULD NOT BEFORE.
//
// Find a sound by typing part of its name, hear it without changing anything,
// narrow the list to the kinds and tempos that will actually fit the song, and
// drag one onto a track. Before this the only route to a sample was a file
// picker — which is a fine gesture for the file you already know the name of
// and a useless one against a library of fourteen thousand.
//
// THREE RULES THIS VIEW IS BUILT AROUND, all of them scars.
//
//  1. THE LIST IS LAZY. The Songs list two hundred lines up carries the comment
//     "Cap the rendered rows (this list isn't lazy); filtering narrows the set"
//     and a `.prefix(60)`. That is an honest workaround for a library of
//     hundreds; put fourteen thousand rows through it and the app stops. So
//     this section owns its OWN ScrollView + LazyVStack rather than borrowing
//     the shared one, and there is no cap: every sound is reachable by
//     scrolling, which is what a browser is for.
//
//  2. NOTHING TOUCHES THE FILESYSTEM IN A BODY. A concurrent lane is fixing a
//     P0 where `BrigadeConfig.isConfigured` — a computed property that reads
//     like a free field access — did a synchronous XPC round trip to
//     `securityd` on every view-body evaluation and pegged the main thread for
//     eight hours. A file-scanning browser is the single most likely place in
//     this app to repeat that with a slower syscall. So: the scan happens in
//     `.task`, off the main actor, once; the FILTER happens in the model when
//     the query changes, not per body; and the body reads two already-correct
//     arrays. `StudioSoundsVaultTests` renders this view repeatedly and fails
//     if either count moves.
//
//  3. NO HORIZONTAL SCROLLVIEW ANYWHERE NEAR THE CHIPS. On macOS a horizontal
//     ScrollView silently eats Button clicks, and a row of filter chips in a
//     172-point rail is exactly the shape that tempts one. The chips wrap onto
//     two fixed rows instead.
//
// AUDITION IS NOT AN EDIT, and that is enforced rather than intended: the
// audition path does not hold the view model, cannot reach the engine, and the
// tests assert that a click leaves `StudioMockEngine.journal` exactly where it
// was. Forty snares auditioned is zero undo steps.

// MARK: - The actions, named so a test can drive exactly what a row does
//
// Both gestures go through functions rather than closures written inline in the
// view, because "the view is wired to the thing that was tested" is otherwise
// unassertable without launching a GUI — and this repo has shipped a command
// palette listing 71 commands and wiring 11.

enum StudioSoundsBrowserActions {

    /// Hear a sound. Deliberately takes ONLY the player: this function could not
    /// journal a command if someone wanted it to, because it has nothing to
    /// journal through.
    @MainActor
    static func audition(_ asset: StudioSoundAsset, player: StudioSoundAuditionPlayer) {
        if player.auditioningID == asset.id {
            player.stop()
        } else {
            player.audition(asset)
        }
    }

    /// The drag payload.
    ///
    /// A namespaced plain string rather than a file URL, ON PURPOSE. The
    /// timeline's drop handler checks for a file URL FIRST and routes it to
    /// `model.importAudio(path:)`, which ignores the drop position and mints a
    /// NEW TRACK — two commands (`track.add` + `import.audio`) and therefore
    /// two undo steps for one gesture. A sound dragged to a spot on a track
    /// should land at that spot on that track, as ONE command. So the payload
    /// is distinguishable and the timeline routes it before the file-URL branch.
    static let dragPrefix = "majiks-sound:"

    static func dragPayload(for asset: StudioSoundAsset) -> String {
        dragPrefix + asset.path
    }

    /// nil when the payload is not one of ours (a take id, say), which is how
    /// the timeline tells the two string drags apart.
    static func soundPath(fromDrag payload: String) -> String? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        let path = String(payload.dropFirst(dragPrefix.count))
        return path.isEmpty ? nil : path
    }
}

// MARK: - Getting sounds, and giving the ones you have their tempos
//
// The browser below was built and shipped against a vault that does not exist
// on any machine: the masters live on the server, nothing downloaded them, and
// no exporter wrote the sidecar index, so the honest empty state it shows was
// the whole of what a person saw. These two actions are the pipe.
//
// THEY ARE DELIBERATELY SEPARATE, and the separation is the design:
//
//  * "Update tempos" reads the PUBLIC catalogue. No key, no account, no
//    licensing question — listing what a pack contains and what tempo it runs
//    at is not a licensed act, and the storefront serves all of it
//    unauthenticated (measured, not assumed). It is the half worth having on
//    its own: a folder of sounds somebody already had becomes a filterable
//    library, and every "tempo unknown" that has a known answer gets it.
//    It matches files BY BASENAME against the pack whose folder they sit in,
//    so it describes sounds that arrived by rsync or by hand and not only the
//    ones this app downloaded — and it reports the misses by count, because
//    "412 of 500 matched, 88 not in the catalogue" is a person's next step and
//    "tempos updated" is not.
//
//  * "Get sounds" fetches MASTERS, which are gated behind the person's own
//    key. Nothing is embedded in this app, and premium content is refused
//    outright rather than attempted. See `StudioSoundsDownloader`.
//
// Both go through named functions rather than closures written inline, for the
// same reason `audition` and `dragPayload` do: otherwise "the button is wired
// to the thing that was tested" is unassertable without launching a GUI, and
// this repo has shipped a command palette listing 71 commands and wiring 11.

extension StudioSoundsBrowserActions {

    /// Fetch a pack into the folder the browser is currently showing, then
    /// rescan it so the new sounds appear WITH the tempos the download just
    /// wrote beside them.
    ///
    /// The rescan is the line that makes this feel like it worked. Without it a
    /// person gets a success toast and an unchanged empty list — the "Publish
    /// button that made no network call" failure with the halves the other way
    /// round.
    ///
    /// Journals nothing, and could not: this function holds no engine and no
    /// view model. Downloading is not a project mutation, exactly as
    /// auditioning is not.
    @MainActor
    static func getPack(
        _ slug: String, get: StudioSoundsGetModel, vault: StudioSoundsVaultModel
    ) {
        let root = vault.root
        get.download(slug: slug, into: root) { outcome in
            ToastManager.shared.show(
                outcome.summary, style: outcome.failed.isEmpty ? .success : .warning)
            vault.rescan(root: root)
        }
    }

    /// Give every sound already on disk its tempo and key, from the public
    /// catalogue.
    ///
    /// Takes the paths the SCAN found rather than the packs the catalogue has,
    /// so it only ever describes files that are actually there — and so it asks
    /// about the two packs somebody holds instead of pulling all 739.
    @MainActor
    static func refreshTempos(get: StudioSoundsGetModel, vault: StudioSoundsVaultModel) {
        get.refreshTempos(
            vaultAt: vault.root,
            present: Set(vault.assets.map(\.id))
        ) { root in
            vault.rescan(root: root)
        }
    }
}

// MARK: - Placing a sound: ONE command, one undo step

extension StudioViewModel {

    /// Put a vault sound on the arrangement at the point it was dropped.
    ///
    /// EXACTLY ONE journaled command — `import.audio`, whose catalogued inverse
    /// is `clip.remove` — so one drag is one undo step. That is why this does
    /// not call `importAudio(path:)`: that entry mints a track first, which is
    /// right for "load a whole song onto its own track" and wrong here, where
    /// the person has already said which track and where by dropping.
    ///
    /// No new command name was needed. `import.audio` already carries a source
    /// path, a target track and a start position, which is the whole of what
    /// placing a sound is; widening an existing command would have been the
    /// dangerous move, and inventing a `sound.place` alongside it would have
    /// been a second name for one act.
    ///
    /// The snapshot refresh rides the existing 30 Hz poll rather than a private
    /// `adoptFresh`, so this lives here in the vault lane's own file and adds
    /// no lines to `StudioViewModel.swift`.
    ///
    /// IT LANDS ON THE GRID, like every other placement in the arrangement.
    ///
    /// `atTicks` arrives as the raw pixel-derived pointer position, and this
    /// used to use it verbatim — making the browser drop the ONLY positioning
    /// gesture on that canvas that ignored the Snap control. Clip move, clip
    /// trim, automation points and the playhead all go through `snapMode`
    /// (`StudioTimelineView.updateDrag`), and the ruler's region and loop drags
    /// reach the same grid through `StudioSelectionOps.rulerRegion`. So a loop
    /// dragged out of the vault landed wherever the hand happened to be, while
    /// the transport bar sat there reading "Snap: Bar" — the default.
    ///
    /// The size of it: at the default zoom (`24.0 / ppq` px per tick, ~96 px to
    /// the bar) three or four pixels of ordinary hand error is about an eighth
    /// of a beat — ~60 ms at 120 BPM. That is not "slightly loose", it is
    /// audibly not in time, and "drag a sound in and have it play in time" is
    /// the entire point of the vault. On a TV at sofa distance the error is
    /// larger, not smaller.
    ///
    /// WHY HERE AND NOT AT THE CALL SITE. Putting it in the view would fix the
    /// one drop path that exists today and leave the next caller to rediscover
    /// the rule — this repo's "recurrence means a missing primitive" lesson.
    /// The view model already holds `snapMode`, `timeSignature` and
    /// `phaseAnchorTicks`, so the grid decision belongs with the project state
    /// that defines the grid. It is also the difference between a test that
    /// reads the view's source for a call and one that drops a sound at a
    /// deliberately off-grid tick and asserts where the clip actually landed.
    ///
    /// `hardSnap`, not the magnetic `snap` the clip drags use. A clip MOVE
    /// adjusts something that already has a position the user chose, so pulling
    /// only within a few pixels of a line is right there. A drop from the
    /// browser is a CREATION: there is no prior position to preserve, so a
    /// pointer 20 px off the bar line means "aimed roughly at that bar", not
    /// "chose 47 ticks past it". `hardSnap` passes the tick through untouched
    /// when `snapMode == .off`, so the Snap control still governs this exactly
    /// as it governs every other gesture.
    func placeSound(path: String, onTrack trackID: UUID, atTicks: Int64) {
        guard snapshot != nil else {
            ToastManager.shared.show(
                "Create or open a project before adding a sound.", style: .warning)
            return
        }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let landing = max(0, StudioTimelineMath.hardSnap(
            atTicks, mode: snapMode, timeSignature: timeSignature,
            phaseAnchorTicks: phaseAnchorTicks))
        Task { @MainActor [engine] in
            let result = await engine.importAudio(
                path: path, trackID: trackID, startTicks: landing)
            ToastManager.shared.show(
                result.ok
                    ? "Added \(name). Undo takes it straight back off."
                    : (result.message ?? "Could not add \(name)."),
                style: result.ok ? .success : .warning)
        }
    }
}

// MARK: - The section

struct StudioSoundsBrowser: View {
    @ObservedObject var model: StudioViewModel

    /// Owned here rather than on `StudioViewModel`: a sample library is not
    /// project state, it does not belong in a snapshot, and putting it on the
    /// view model would have put a filesystem scan behind the 30 Hz poll.
    @StateObject private var vault = StudioSoundsVaultModel()
    @StateObject private var player = StudioSoundAuditionPlayer()
    /// The pipe. Owned here for the same reason the vault is: a catalogue is
    /// not project state and a download is not a project edit.
    @StateObject private var get = StudioSoundsGetModel()

    /// Whether the Get panel is open. `@State`, so opening it is a view-local
    /// gesture that starts nothing on its own — the catalogue read hangs off
    /// the button's action, never off a body.
    @State private var showGet = false
    @State private var keyDraft = ""

    /// Test seam: hand in a prepared model so a fixture of fourteen thousand
    /// sounds can be rendered without a disk anywhere. Defaulted to nil, so
    /// every real call site is unchanged.
    var injected: StudioSoundsVaultModel?
    var injectedGet: StudioSoundsGetModel?

    private var live: StudioSoundsVaultModel { injected ?? vault }
    private var liveGet: StudioSoundsGetModel { injectedGet ?? get }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            searchField
            kindChips
            fitChips
            if !live.summary.isEmpty {
                Text(live.summary)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(StudioTokens.faint)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            if let message = live.emptyMessage {
                emptyNote(message)
                if live.phase == .missingRoot || live.assets.isEmpty {
                    chooseFolderButton
                }
            } else {
                list
            }
            if let failure = player.failure {
                emptyNote(failure)
            }
            getPanel
        }
        // The scan lives HERE and nowhere else. `.task` runs once, after the
        // body, and awaits an off-main scan. Not `.onAppear` (which cannot
        // await), and never anywhere a body can reach.
        .task {
            guard injected == nil, vault.phase == .idle else { return }
            vault.rescan()
        }
        // The project's tempo and key are what "will this fit" is measured
        // against, so they are pushed in rather than read out of the snapshot
        // inside the filter.
        //
        // ⚠️ `initial: true` IS THE WHOLE THING, and without it both fit chips
        // were dead. `.onChange` fires on a CHANGE, and this view is built when
        // the user picks the Sounds section — which is long after the snapshot
        // landed and stopped moving. So neither closure ever ran on the
        // ordinary path: `projectBPM` sat at its 120 default and `projectKey`
        // sat at nil. "In tempo" filtered a 96 BPM song against 120, and
        // "In key" hit `guard let projectKey ... else { return false }` and hid
        // EVERY sound, every time, under an empty-state that blamed the search
        // terms. Leaving Sounds and coming back tore the `@StateObject` down
        // and reset both to the defaults again.
        .onChange(of: model.snapshot?.tempoBPM, initial: true) { _, bpm in
            live.projectBPM = bpm ?? 120
        }
        .onChange(of: model.snapshot?.key, initial: true) { _, key in
            live.projectKey = key
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sounds")
    }

    // MARK: The list

    /// Its OWN ScrollView, deliberately.
    ///
    /// `StudioBrowserView` wraps the other three sections in a shared
    /// `ScrollView { VStack { … } }`. A `LazyVStack` nested inside that plain
    /// `VStack` is at the mercy of how the outer stack proposes size, and
    /// "probably still lazy" is not a thing to bet fourteen thousand rows on.
    /// Owning the scroll view makes the laziness structural, and the row-render
    /// counter in `StudioSoundsVaultTests` measures that it actually holds.
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(live.visible) { asset in
                    StudioSoundRow(
                        asset: asset,
                        auditioning: player.auditioningID == asset.id,
                        onAudition: {
                            StudioSoundsBrowserActions.audition(asset, player: player)
                        },
                        onLoadIntoSampler: { model.addSamplerTrack(path: asset.path) })
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(StudioTokens.faint)
            TextField("Search sounds", text: Binding(
                get: { live.filter.query },
                set: { live.filter.query = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(StudioTokens.text)
                .lineLimit(1)
                .accessibilityLabel("Search sounds")
            if !live.filter.query.isEmpty {
                Button {
                    live.filter.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTokens.faint)
                }
                .buttonStyle(.plain)
                // help-exempt: an ✕ inside the search box it only appears in is
                // self-evident, and the box itself carries the tooltip.
                .accessibilityLabel("Clear sound search")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(StudioTokens.bg)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTokens.stroke, lineWidth: 1))
        .studioHelp("sounds.search")
    }

    // MARK: Filters
    //
    // Two fixed rows of chips. NOT a horizontal ScrollView — see the file
    // header. Words chosen for someone who has never used a DAW: "Hits" reads
    // as a drum hit; "one-shot" is jargon and lives in the tooltip.

    private var kindChips: some View {
        HStack(spacing: 4) {
            chip("All", on: live.filter.kind == nil, help: "sounds.kind") {
                live.filter.kind = nil
            }
            chip("Hits", on: live.filter.kind == .oneShot, help: "sounds.kind.hits") {
                live.filter.kind = live.filter.kind == .oneShot ? nil : .oneShot
            }
            chip("Loops", on: live.filter.kind == .loop, help: "sounds.kind.loops") {
                live.filter.kind = live.filter.kind == .loop ? nil : .loop
            }
            chip("Stems", on: live.filter.kind == .stem, help: "sounds.kind.stems") {
                live.filter.kind = live.filter.kind == .stem ? nil : .stem
            }
        }
    }

    private var fitChips: some View {
        HStack(spacing: 4) {
            chip("In tempo", on: live.filter.inTempo, help: "sounds.inTempo") {
                live.filter.inTempo.toggle()
            }
            chip("In key", on: live.filter.inKey, help: "sounds.inKey") {
                live.filter.inKey.toggle()
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(
        _ title: String, on: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(on ? StudioTokens.text : StudioTokens.dim)
                // A chip is the tight-HStack shape that blew the transport row
                // to 475 points: an unconstrained Text in a narrow rail wraps
                // to one character per line. One line, its natural width.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                // 5, not the 6 the Takes chips use. MEASURED: at 6 the four
                // kind chips want 154 pt and the rail gives 152, so "Stems"
                // hung 2 pt past the divider — a control nobody can click.
                // `testTheFilterChipsFitTheBrowserRail` is what found that and
                // is what will find it again if a sixth chip appears.
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(on ? StudioTokens.purple.opacity(0.22) : .clear)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(on ? StudioTokens.purple : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .studioHelp(help)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "on" : "off")
    }

    // MARK: The empty state, and the way out of it

    private var chooseFolderButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Use This Folder"
            panel.message = "Choose the folder your downloaded sounds are in."
            if panel.runModal() == .OK, let url = panel.url {
                StudioSoundsVaultLocation.set(url)
                live.rescan(root: url)
            }
        } label: {
            Label("Choose sounds folder…", systemImage: "folder")
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudioTokens.cyan)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .studioHelp("sounds.folder")
        .accessibilityLabel("Choose sounds folder")
    }

    // MARK: The pipe
    //
    // Everything in here obeys the same three rules as the list above. In
    // particular: NO horizontal ScrollView (the pack list scrolls vertically,
    // which macOS handles without eating clicks), and every `Text` in a tight
    // HStack is `lineLimit(1)` + `fixedSize` — a pack title like "Kitchen Floor
    // Confessions — Lo-Fi Indie Kit" in a 172-point rail is EXACTLY the string
    // that wrapped a toolbar row to 475 points.
    //
    // Nothing in this subtree does IO in a body. The catalogue read hangs off
    // the disclosure button; the keychain is touched only through
    // `StudioSoundsGetModel.hasKey`, which is `StudioKeychainItem`-backed and
    // costs one securityd round trip in the life of the process.

    private var getPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.35)
            Button {
                showGet.toggle()
                // The ONE place a catalogue read starts. Not `.task`, not
                // `.onAppear`: a person who never opens this panel should never
                // make a network call because they clicked Sounds.
                if showGet { liveGet.loadCatalogue() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showGet ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(showGet ? "Hide sound packs" : "Get more sounds…")
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTokens.cyan)
            .padding(.horizontal, 4)
            .studioHelp("sounds.get")
            .accessibilityLabel("Get more sounds")

            if showGet {
                if !liveGet.statusLine.isEmpty {
                    Text(liveGet.statusLine)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(StudioTokens.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                if liveGet.isBusy {
                    stopButton
                } else {
                    if !liveGet.hasKey { keyRow }
                    packList
                }
                temposButton
            }
        }
    }

    /// The pack list. A VERTICAL scroll view — the macOS trap this file's
    /// header names is the HORIZONTAL one, which silently eats Button clicks,
    /// and which a row of packs would have tempted if the titles were laid out
    /// side by side.
    private var packList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(liveGet.packs, id: \.slug) { pack in
                    packRow(pack)
                }
            }
        }
        .frame(maxHeight: 150)
    }

    private func packRow(_ pack: StudioSoundsCatalogPack) -> some View {
        Button {
            StudioSoundsBrowserActions.getPack(pack.slug, get: liveGet, vault: live)
        } label: {
            HStack(spacing: 5) {
                Text(pack.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTokens.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text("\(pack.assetCount)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(StudioTokens.faint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioTokens.panelHi.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .studioHelp("sounds.pack")
        .accessibilityLabel(pack.title)
        .accessibilityValue("\(pack.assetCount) sounds")
    }

    /// Where a person puts their own key. A `SecureField`, because it is one,
    /// and nothing in this app ever ships a key of its own.
    private var keyRow: some View {
        HStack(spacing: 4) {
            SecureField("Paste your \(StudioSoundsVaultLocation.storefront) key", text: $keyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(StudioTokens.text)
                .lineLimit(1)
                .studioHelp("sounds.key")
                .accessibilityLabel("Sounds account key")
            Button {
                StudioSoundsAccount.setKey(keyDraft)
                keyDraft = ""
            } label: {
                Text("Save")
                    .font(.system(size: 9.5, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTokens.cyan)
            .studioHelp("sounds.key.save")
            .accessibilityLabel("Save sounds key")
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(StudioTokens.bg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var stopButton: some View {
        Button { liveGet.cancel() } label: {
            Text("Stop")
                .font(.system(size: 9.5, weight: .bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudioTokens.dim)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .studioHelp("sounds.stop")
        .accessibilityLabel("Stop downloading")
    }

    /// The half that needs no key, and the one worth having on its own.
    private var temposButton: some View {
        Button {
            StudioSoundsBrowserActions.refreshTempos(get: liveGet, vault: live)
        } label: {
            Label("Update tempos", systemImage: "metronome")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(live.assets.isEmpty ? StudioTokens.faint : StudioTokens.cyan)
        .disabled(live.assets.isEmpty || liveGet.isBusy)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .studioHelp("sounds.tempos")
        .accessibilityLabel("Update tempos")
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(StudioTokens.faint)
            .padding(.horizontal, 4).padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - One row
//
// Its own type so the render counter below measures exactly one thing: how many
// rows SwiftUI actually built. Inlining this into the ForEach would make
// "the list is lazy" unmeasurable.

struct StudioSoundRow: View {
    let asset: StudioSoundAsset
    let auditioning: Bool
    let onAudition: () -> Void
    let onLoadIntoSampler: () -> Void

    var body: some View {
        #if DEBUG
        StudioSoundRowRenderCounter.shared.note()
        #endif
        return Button(action: onAudition) {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(auditioning ? StudioTokens.cyan : StudioTokens.stemImported)
                    .frame(width: 6, height: 6)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 1) {
                    // Both of these are single-line by construction. A file name
                    // in a 172-point rail is the exact shape that wraps to one
                    // character per line if left alone; `fixedSize` vertical
                    // pins the height to that one line, and the middle
                    // truncation keeps the END of the name — which is where a
                    // sample pack puts the part that tells one kick from
                    // another.
                    Text(asset.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(auditioning ? StudioTokens.text : StudioTokens.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(asset.metaLine)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(StudioTokens.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(auditioning ? StudioTokens.panelHi : StudioTokens.panelHi.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: StudioSoundsBrowserActions.dragPayload(for: asset) as NSString) }
        .contextMenu {
            Button("Load into Sampler") { onLoadIntoSampler() }
                .studioHelp("sounds.row.loadSampler")
        }
        .studioHelp("sounds.row")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset.name)
        .accessibilityValue(asset.metaLine)
        .accessibilityHint("Click to hear it. Drag it onto a track, or use the context menu to load it into a Sampler.")
    }
}

#if DEBUG
/// How many sound rows SwiftUI actually built.
///
/// This exists because "the list is lazy" is otherwise a claim about a
/// framework's internals that no assertion can reach, and this repo has shipped
/// a meter driven by `abs(sin(t))`, a piano roll wired to a mock and a
/// separator that zeroed 75% of every sample — all with green suites. A
/// fourteen-thousand-row fixture rendered through `ImageRenderer` with this
/// counter armed is the difference between a measured bound and a hope.
///
/// DEBUG only, and inert until a test arms it, so the shipping build pays
/// nothing for it.
final class StudioSoundRowRenderCounter: @unchecked Sendable {
    static let shared = StudioSoundRowRenderCounter()

    private let lock = NSLock()
    private var value = 0
    private var armed = false

    func arm() { lock.lock(); armed = true; value = 0; lock.unlock() }
    func disarm() { lock.lock(); armed = false; value = 0; lock.unlock() }

    func note() {
        lock.lock()
        if armed { value += 1 }
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
#endif
