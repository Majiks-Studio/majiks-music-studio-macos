import XCTest
import SwiftUI
import AppKit
@testable import MajiksMusicStudio

// The browser rail's two dishonest panes.
//
// FILES said, in `StudioHelp.swift`: "Audio files on your disk that you can drag
// straight onto a track." Both halves were false. The rows were a plain `HStack`
// with no `.onDrag` and no gesture of any kind, so nothing could be dragged; and
// what they listed was the NAMES OF CLIPS already imported into this project,
// not files on a disk. It also filtered on `track.kind == .imported`, and
// `StudioTrackSnapshot.role` says in its own comment why that is not a thing to
// gate an affordance on: `kind` is guessed from the track's NAME and flips when
// somebody renames a track. Renaming an imported track to "Bass" emptied the
// pane. The pane is gone; the case is argued in the lane report and in
// `StudioBrowserView`'s own comment.
//
// STEMS ran `ForEach(snapshot.tracks)` over EVERY track — including MIDI
// instrument tracks, which have no stem at all — and drew each as an inert
// `HStack`. A list of the song's layers that listed things that are not layers,
// and did nothing when pressed.
//
// The general lesson, and the reason the first test below is written the way it
// is: a pane's WORDS and a pane's CODE drift apart silently. Nothing in the
// suite could tell that "you can drag" was false, because no test compared the
// two. `testEverySectionsPromiseIsBackedByAGestureThatExists` does, for every
// section, in a form that fails whichever half moves.

@MainActor
final class StudioBrowserPanesTests: XCTestCase {

    private static let sourcesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../Sources")
        .standardizedFileURL

    private func source(_ name: String) throws -> String {
        let fm = FileManager.default
        let enumerator = try XCTUnwrap(
            fm.enumerator(at: Self.sourcesDirectory, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return try String(contentsOf: url, encoding: .utf8)
        }
        XCTFail("\(name) is not under Sources")
        return ""
    }

    // MARK: - 1. The words and the pane must agree

    // ⚠️ THIS IS SECTION-GRANULAR ON PURPOSE, and the first version was not.
    //
    // It searched whole FILES, and against that detector the Files pane's lie
    // would have passed: `files` lived in `StudioBrowserView.swift`, and so does
    // `StudioLibrarySongRow`, which has a perfectly real `.onDrag`. A file-level
    // search would have found that `.onDrag`, credited it to Files, and reported
    // the pane honest. A net that cannot catch the bug it was written for is
    // worse than no net, because it is also a claim that there is one.
    //
    // So each section names the exact DECLARATION that draws its rows, and the
    // search is scoped to that declaration's braces.

    /// The declarations that draw each section's rows: a file, and the names of
    /// the declarations inside it that make up the pane. An EMPTY list means the
    /// whole file, which is right only when the section is one view type of its
    /// own — `StudioSoundsBrowser` and `StudioTakesBrowser` are.
    ///
    /// Listing more than one is not a loophole, it is the shape of the code: a
    /// pane is a list property plus the row builder it calls, and a gesture may
    /// honestly live in either. What the scoping rules out is crediting a pane
    /// with a gesture belonging to a DIFFERENT pane that shares its file, which
    /// is exactly what let the Files pane read as honest.
    private static let implementedIn: [StudioBrowserView.Section: (file: String, decls: [String])] = [
        // The rows are `StudioLibrarySongRow`; the `songs` property is only the
        // list around them, so the ROW is what has to hold the gestures.
        .songs: ("StudioBrowserView.swift", ["struct StudioLibrarySongRow"]),
        .sounds: ("StudioSoundsBrowser.swift", []),
        .takes: ("StudioTakesBrowser.swift", []),
        .stems: ("StudioBrowserView.swift", ["private var stems", "private func stemChip"]),
    ]

    /// A gesture a tooltip can promise, and the code that has to exist in that
    /// section's own declaration for the promise to be true.
    ///
    /// These are deliberately the exact claims the Files pane made and could not
    /// keep, plus the two the Stems pane now makes. A pane may of course do MORE
    /// than it says; saying more than it does is the failure.
    private static let claims: [(word: String, needle: String, gesture: String)] = [
        ("drag", ".onDrag", "a drag source"),
        ("double-click", ".onTapGesture(count: 2)", "a double-click gesture"),
        ("mute", "toggleMute", "a mute control"),
        ("solo", "toggleSolo", "a solo control"),
    ]

    /// The body of `decl` in `text`, braces matched, so a search can be scoped to
    /// ONE pane rather than to whichever file it happens to share.
    ///
    /// Deliberately dumb about strings and comments: a stray `{` inside either
    /// would over-run the span, which fails SAFE here — an over-long span can
    /// only make this test more permissive at the edges, never blind, and the
    /// calibration below is what proves it is not blind.
    private func declaration(_ decl: String, in text: String) throws -> String {
        let head = try XCTUnwrap(text.range(of: decl),
                                 "\(decl) is gone; the section it draws is now unchecked")
        var depth = 0
        var started = false
        var out = ""
        for ch in text[head.lowerBound...] {
            if ch == "{" { depth += 1; started = true }
            if started { out.append(ch) }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return out }
            }
        }
        XCTFail("\(decl) has unbalanced braces")
        return out
    }

    private func implementation(of section: StudioBrowserView.Section) throws -> (name: String, code: String) {
        let entry = try XCTUnwrap(Self.implementedIn[section],
                                  "\(section.rawValue) is not in the implementedIn map, so its promises are unchecked")
        let text = try source(entry.file)
        guard !entry.decls.isEmpty else { return (entry.file, text) }
        let code = try entry.decls.map { try declaration($0, in: text) }.joined(separator: "\n")
        return ("\(entry.file) / \(entry.decls.joined(separator: " + "))", code)
    }

    func testEverySectionsPromiseIsBackedByAGestureThatExists() throws {
        var promisesChecked = 0

        for section in StudioBrowserView.Section.allCases {
            let entry = try XCTUnwrap(
                StudioHelpCatalog.entry(section.helpID),
                "\(section.rawValue) has no help entry \(section.helpID)")
            let impl = try implementation(of: section)
            let teaching = entry.teaching.lowercased()

            for claim in Self.claims where teaching.contains(claim.word) {
                promisesChecked += 1
                XCTAssertTrue(
                    impl.code.contains(claim.needle),
                    """
                    \(section.helpID) tells the user "\(entry.teaching)" — it promises \
                    \(claim.gesture) — and \(impl.name) contains no `\(claim.needle)`. That \
                    is the Files pane's bug exactly: a tooltip describing a gesture the \
                    pane does not have. Either wire it or change the words.
                    """)
            }
        }

        // Non-vacuity. If no section's teaching mentioned any gesture, the loop
        // above would be a green no-op — the shape of a coverage test that
        // policed nothing.
        XCTAssertGreaterThanOrEqual(
            promisesChecked, 4,
            "only \(promisesChecked) gesture promises were found across every browser section, so this net is checking almost nothing")
    }

    /// CALIBRATION, and the reason the detector above is scoped rather than
    /// file-wide: run it against the Files pane exactly as it shipped, in the
    /// file it shipped in, and it must report the lie.
    ///
    /// The `files` body below is a verbatim copy of the deleted one. Keeping it
    /// here is the only way to prove this net would have caught the bug it was
    /// written for — the code itself is gone, so there is nothing else left to
    /// point the detector at.
    func testTheDetectorWouldHaveCaughtTheFilesPaneItWasWrittenFor() throws {
        let theOldSentence = "Audio files on your disk that you can drag straight onto a track."
        let theOldPane = """
            private var files: some View {
                header("Imported files")
                Button {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK, let url = panel.url { model.importAudio(path: url.path) }
                } label: {
                    Label("Import audio…", systemImage: "plus")
                }
                ForEach(imported, id: \\.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                        Text(name)
                    }
                    .padding(.horizontal, 8)
                }
            }
            """
        // The whole FILE it lived in — which is what the first version of this
        // test searched, and why that version was worthless.
        let wholeFile = try source("StudioBrowserView.swift")

        let drag = try XCTUnwrap(Self.claims.first(where: { $0.word == "drag" }))
        XCTAssertTrue(theOldSentence.lowercased().contains(drag.word),
                      "the detector no longer recognises the word the Files pane lied with")
        XCTAssertFalse(
            theOldPane.contains(drag.needle),
            "the detector thinks the Files pane had a drag source, so it would have passed the pane it exists to catch")
        XCTAssertTrue(
            wholeFile.contains(drag.needle),
            """
            StudioBrowserView.swift no longer contains `.onDrag` anywhere, which makes \
            this calibration meaningless: the point is that a FILE-WIDE search finds a \
            real drag here (StudioLibrarySongRow's) and would have credited it to the \
            Files pane. If the song rows lost their drag, fix that first.
            """)
    }

    /// The scoping itself, shown working on live code rather than on a string
    /// literal: the Stems declaration must not be able to see the song row's
    /// drag, which sits a few hundred lines below it in the same file.
    func testTheScopedSearchCannotSeeAnotherPanesGestures() throws {
        let stems = try implementation(of: .stems)
        XCTAssertFalse(
            stems.code.contains(".onDrag"),
            "the Stems declaration's span reaches StudioLibrarySongRow's `.onDrag`, so the scoping is not scoping and this file is back to a file-wide search")
        XCTAssertTrue(stems.code.contains("toggleSolo"),
                      "the Stems span does not contain its own solo chip, so the extractor is cutting the declaration short")
        XCTAssertLessThan(
            stems.code.count, try source("StudioBrowserView.swift").count / 2,
            "the extracted Stems span is more than half the file, so it is not a declaration")
    }

    // MARK: - 2. Files is gone, in BOTH places

    /// Deleting a lying pane means deleting its words too. A leftover catalog
    /// entry is a tooltip attached to nothing (`StudioHelpTests` catches that
    /// half); a leftover section with no entry is a tab with no explanation.
    /// This asserts the two moved together.
    func testTheFilesPaneAndItsHelpEntryAreBothGone() {
        XCTAssertFalse(
            StudioBrowserView.Section.allCases.contains { $0.rawValue == "Files" },
            "the Files section is back in the browser; if it is genuinely wanted it needs rows that do what its tooltip claims")
        XCTAssertNil(
            StudioHelpCatalog.entry("browser.files"),
            "browser.files still describes a pane that no longer exists")
        XCTAssertEqual(
            Set(StudioBrowserView.Section.allCases.map(\.rawValue)),
            ["Songs", "Sounds", "Takes", "Stems"])
    }

    /// The other place the word "files" was a promise: the toolbar's tooltip
    /// for the button that opens this rail listed what is inside it.
    func testTheToolbarNoLongerPromisesAFilesPane() throws {
        let entry = try XCTUnwrap(StudioHelpCatalog.entry("toolbar.browser.show"))
        for section in StudioBrowserView.Section.allCases {
            XCTAssertTrue(
                entry.teaching.lowercased().contains(section.rawValue.lowercased()),
                "the browser's own tooltip does not mention \(section.rawValue), so it under-describes the rail it opens")
        }
        XCTAssertFalse(
            entry.teaching.lowercased().contains("files"),
            "the toolbar still tells the user the rail holds \"files\"; that pane is gone")
    }

    /// Importing audio is what the Files pane's one working control did, and it
    /// must not have gone with it.
    func testImportingAudioIsStillReachableFromTheToolbar() throws {
        let root = try source("StudioRootView.swift")
        XCTAssertTrue(root.contains("chooseAudioFile"),
                      "the toolbar's Import no longer opens a file panel, so deleting the Files pane took the last import route with it")
        XCTAssertNotNil(StudioHelpCatalog.entry("toolbar.import"))
    }

    // MARK: - 3. Stems lists layers, not every track

    private func bootedModel() async throws -> StudioViewModel {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        for _ in 0..<120 {
            if let s = model.snapshot, !s.tracks.isEmpty { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        _ = try XCTUnwrap(model.snapshot?.tracks.first, "the mock project never arrived")
        return model
    }

    /// Through the REAL bus, not a hand-built snapshot shaped to pass: add a
    /// track, then put a synth on it, and watch the Stems pane refuse both
    /// states.
    ///
    /// ⚠️ `StudioViewModel.addInstrumentTrack` cannot be used here and that is
    /// not a gap in the test: `StudioEngineProtocol`'s default REFUSES it with
    /// "instrument tracks need the on-device engine", and only `RealStudioEngine`
    /// overrides it — so under gate 6 there is no such thing as a MIDI clip. The
    /// first draft of this test used it, got `ok: false`, and SKIPPED. A skipped
    /// test proves nothing, so the probe is built out of the two commands the
    /// mock does implement (`track.add`, `device.add`), which produce the other
    /// two non-audio roles. The MIDI-clip case is covered by
    /// `testTheStemFilterReadsRoleAndNotKind` below, over the real function.
    func testATrackWithNoAudioOnItIsNotListedAsAStem() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        let before = StudioBrowserView.stemTracks(in: model.snapshot)
        XCTAssertFalse(before.isEmpty, "the mock project has no audio tracks, so this test cannot tell the two apart")
        let tracksBefore = try XCTUnwrap(model.snapshot?.tracks.count)

        let newID = UUID()
        model.sendFromPalette(.trackAdd(trackID: newID.uuidString, name: "Keys", index: tracksBefore))
        for _ in 0..<200 {
            if model.snapshot?.tracks.contains(where: { $0.id == newID }) == true { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let added = try XCTUnwrap(model.snapshot?.tracks.first(where: { $0.id == newID }),
                                  "track.add never reached the snapshot, so there is nothing to exclude")
        XCTAssertEqual(added.role, .empty)

        XCTAssertFalse(
            StudioBrowserView.stemTracks(in: model.snapshot).contains(where: { $0.id == newID }),
            "\"Keys\" is a brand-new track with nothing on it and the Stems pane lists it as one of the song's layers")

        // Now make it a real instrument track — a synth, no audio.
        await model.addInstrument(trackID: newID)?.value
        for _ in 0..<200 {
            if model.snapshot?.tracks.first(where: { $0.id == newID })?.devices.isEmpty == false { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let played = try XCTUnwrap(model.snapshot?.tracks.first(where: { $0.id == newID }))
        XCTAssertEqual(played.role, .instrument, "the synth did not land, so this is still the empty-track case")

        let stems = StudioBrowserView.stemTracks(in: model.snapshot)
        XCTAssertFalse(
            stems.contains(where: { $0.id == newID }),
            """
            "\(played.name)" is an instrument track with no audio on it and the Stems \
            pane lists it as one of the song's layers. That is the \
            ForEach-over-every-track this lane removed.
            """)
        XCTAssertEqual(stems.map(\.id), before.map(\.id),
                       "adding an instrument track changed which tracks the project calls stems")
    }

    /// The MIDI-clip case, which the mock engine cannot produce, asserted over
    /// the REAL filter function with a snapshot carrying one of each role.
    ///
    /// This is also where "reads `role`, not `kind`" is actually proven: the
    /// instrument track below is deliberately called "Drums" and carries
    /// `kind: .drums`, so a filter that trusted `kind` would list it.
    func testTheStemFilterReadsRoleAndNotKind() throws {
        func track(_ name: String, _ kind: StudioStemKind,
                   clips: [StudioClipSnapshot], devices: [StudioDeviceSnapshot] = []) -> StudioTrackSnapshot {
            StudioTrackSnapshot(id: UUID(), name: name, kind: kind, clips: clips, devices: devices)
        }
        func clip(_ name: String, midi: Bool) -> StudioClipSnapshot {
            StudioClipSnapshot(id: UUID(), name: name, startTicks: 0, lengthTicks: 3840,
                               generative: false, waveformSeed: 1, isMidi: midi)
        }

        let audio = track("Vocals", .vocals, clips: [clip("v", midi: false)])
        // A MIDI track wearing a stem's name and a stem's colour.
        let midi = track("Drums", .drums, clips: [clip("d", midi: true)])
        let empty = track("Keys", .other, clips: [])
        let snapshot = StudioProjectSnapshot(
            revision: 1, name: "T", tempoBPM: 120, timeSignature: .fourFour,
            key: "C major", lengthBars: 8, sections: [], tracks: [audio, midi, empty],
            transport: StudioTransportSnapshot(
                isPlaying: false, positionTicks: 0, capturedAtHostTime: 0,
                loopRegion: nil, recording: false, recordingTrackID: nil),
            stats: StudioEngineStats(callbackP95Millis: 0, underruns: 0, engineLabel: "test"),
            master: StudioMasterSnapshot(),
            provenanceSummary: "")

        let stems = StudioBrowserView.stemTracks(in: snapshot)
        XCTAssertEqual(
            stems.map(\.name), ["Vocals"],
            """
            the Stems pane listed \(stems.map(\.name)). "Drums" is a MIDI clip with no \
            audio behind it — it only LOOKS like a stem because its name made \
            `kind` say `.drums`, which is the guess `StudioTrackSnapshot.role` \
            exists to stop anything gating on.
            """)
        XCTAssertTrue(StudioBrowserView.stemTracks(in: nil).isEmpty,
                      "no project at all must list no stems rather than crashing")
    }

    /// The filter reads `role`, which is derived from clips and devices —
    /// engine truth — and NOT `kind`, which `StudioTrackSnapshot.role`'s own
    /// comment says is guessed from the track's name and flips on a rename.
    /// This is the half a text search cannot see.
    func testRenamingATrackDoesNotChangeWhetherItIsAStem() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        let track = try XCTUnwrap(StudioBrowserView.stemTracks(in: model.snapshot).first)
        model.renameTrack(track.id, name: "Low End")
        for _ in 0..<120 {
            if model.snapshot?.tracks.first(where: { $0.id == track.id })?.name == "Low End" { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let stems = StudioBrowserView.stemTracks(in: model.snapshot)
        XCTAssertTrue(
            stems.contains(where: { $0.id == track.id }),
            "renaming a track dropped it out of the Stems pane, so the filter is reading `kind` (a guess from the name) rather than `role`")
    }

    // MARK: - 4. A stem row is not inert

    func testAStemRowsSoloAndMuteReachEngineTruth() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let track = try XCTUnwrap(StudioBrowserView.stemTracks(in: model.snapshot).first)

        StudioBrowserStemActions.toggleMute(model, track)
        StudioBrowserStemActions.toggleSolo(model, track)
        for _ in 0..<200 {
            if let t = model.snapshot?.tracks.first(where: { $0.id == track.id }),
               t.muted != track.muted, t.soloed != track.soloed { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let after = try XCTUnwrap(model.snapshot?.tracks.first(where: { $0.id == track.id }))
        XCTAssertNotEqual(after.muted, track.muted, "the Stems row's mute did not reach engine truth")
        XCTAssertNotEqual(after.soloed, track.soloed, "the Stems row's solo did not reach engine truth")
    }

    // MARK: - 5. The chips are actually DRAWN, per row

    // The actions above could be perfect and the pane still inert — that is the
    // half-wiring this repo keeps shipping. So the rows are rendered through the
    // REAL `StudioBrowserView` (its `initialSection` seam exists for exactly
    // this), and the claim is made in a form an empty pane cannot satisfy: the
    // number of controls has to GROW with the number of stems.

    private func controlCount(_ view: some View, width: CGFloat = 240, height: CGFloat = 700) -> Int {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        host.layout()
        host.layoutSubtreeIfNeeded()
        func walk(_ v: NSView) -> Int {
            let name = String(describing: type(of: v))
            let self_ = (name.contains("HitTesting") || name.contains("AppKitButton")) ? 1 : 0
            return v.subviews.reduce(self_) { $0 + walk($1) }
        }
        return walk(host)
    }

    /// Nothing here is a pinned number, deliberately. How many AppKit hit-test
    /// views one SwiftUI Button materialises is not a fact this file should be
    /// asserting — the first draft pinned "two per row", measured three, and
    /// would have been wrong again the next time a chip was restyled. What IS a
    /// real claim is that the count is LINEAR in the number of stems with a
    /// slope of at least two: two chips per row, every row.
    func testTheStemsPaneDrawsControlsPerRowRatherThanInertText() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let library = LibraryStore()

        func stemsNow() -> Int { StudioBrowserView.stemTracks(in: model.snapshot).count }
        func renderStems() -> Int {
            controlCount(StudioBrowserView(model: model, initialSection: .stems)
                .environmentObject(library))
        }
        func trim(to wanted: Int) async {
            while stemsNow() > wanted {
                guard let last = StudioBrowserView.stemTracks(in: model.snapshot).last else { break }
                await model.deleteTrack(last.id)?.value
            }
        }

        XCTAssertGreaterThanOrEqual(stemsNow(), 8, "not enough stems in the mock project to measure a slope")

        var samples: [(stems: Int, controls: Int)] = []
        for wanted in [8, 5, 2] {
            await trim(to: wanted)
            XCTAssertEqual(stemsNow(), wanted, "could not reach \(wanted) stems; the slope below would be measured on the wrong shape")
            samples.append((wanted, renderStems()))
        }

        let dropA = samples[0].controls - samples[1].controls
        let dropB = samples[1].controls - samples[2].controls
        XCTAssertEqual(
            dropA, dropB,
            """
            removing three stems cost \(dropA) controls once and \(dropB) the next time \
            (\(samples)). The pane's controls are not a fixed number per row, so they are \
            not the rows' controls.
            """)
        let perRow = dropA / 3
        XCTAssertGreaterThanOrEqual(
            perRow, 2,
            """
            each stem row is worth \(perRow) control(s) (\(samples)). A row needs a Mute AND \
            a Solo; fewer than two means the rows are drawing as inert text, which is the \
            pane this lane was sent to fix.
            """)
    }

    /// The claim above, shown rejecting a pane whose rows draw nothing. The
    /// SONGS section of the SAME shell is the control: same four section
    /// buttons, no stem chips — so its count must not move when stems are
    /// removed. Without this, "the count follows the stems" could be true of
    /// any pane whose control count happened to track the project.
    func testTheSongsSectionsControlCountDoesNotFollowTheStemCount() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }
        let library = LibraryStore()

        func renderSongs() -> Int {
            controlCount(StudioBrowserView(model: model, initialSection: .songs)
                .environmentObject(library))
        }

        let before = renderSongs()
        while StudioBrowserView.stemTracks(in: model.snapshot).count > 2 {
            guard let last = StudioBrowserView.stemTracks(in: model.snapshot).last else { break }
            await model.deleteTrack(last.id)?.value
        }
        XCTAssertEqual(
            renderSongs(), before,
            "the Songs section's control count moved when stems were deleted, so the Stems slope above is measuring the shell rather than the stem rows")
    }
}
