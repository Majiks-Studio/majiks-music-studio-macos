import Testing
import Foundation
@testable import MajiksMusicStudio

// CAN A PERSON GET TO STEM SEPARATION?
//
// The feature worked and could not be reached. The owner opened the Stems tab,
// looked for "split this song into its parts", and found a pane whose empty
// state told him to go and do it somewhere else. These tests are about the
// question he actually asked, so they are about REACH: from each place a person
// looks, does the gesture arrive at the shipped separator, and does it say
// something when it cannot?
//
// ⚠️ WHAT WOULD MAKE THESE TESTS WORTHLESS, stated so the next reader can check
// they did not happen:
//
//  * asserting a closure was assigned. Every one of the behavioural tests below
//    drives the join and then asks a RECORDING separator whether it was handed
//    the song. A wiring that assigns an action and never calls it fails on
//    "the separator was never asked for anything".
//  * a source scan satisfied by a comment ABOUT the line it polices. This file
//    strips `//` comments before every scan, and it quotes the call sites it
//    checks in its own prose, so an unstripped scan here would pass on the
//    paragraph explaining what it looks for.
//  * proving the refusal with a message this test wrote. The refusal fixtures
//    below are the engine's and the backend's OWN sentences, copied from
//    `landing.rs` and from the RPC error shape, and the assertion is that those
//    words survive to the person — which is the thing the old code broke by
//    replacing the whole payload with "Install Demucs: pip install demucs".

// MARK: - Doubles

/// A separator that records what it was asked and answers with four parts.
///
/// It writes REAL files, because `StemSessionStore.createSession` copies each
/// stem in and skips any it cannot read — a double that returned paths to
/// nothing would produce an empty session and the tests would be asserting
/// against the store's skip path rather than against separation.
private final class RecordingSeparator: StemSeparating, @unchecked Sendable {
    private(set) var askedFor: [String] = []
    private(set) var wroteUnder: [String] = []
    let parts: [String]
    private let root: URL

    init(root: URL, parts: [String] = ["vocals", "drums", "bass", "other"]) {
        self.root = root
        self.parts = parts
    }

    func separateIntoStems(sourceAudioPath: String, outputDir: String) async throws -> [String: String] {
        askedFor.append(sourceAudioPath)
        wroteUnder.append(outputDir)
        let dir = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [String: String] = [:]
        for part in parts {
            let url = dir.appendingPathComponent("\(part).wav")
            try StemSeparationFixtures.writeTone(to: url)
            out[part] = url.path
        }
        return out
    }
}

/// A separator that refuses, in the words the real one refuses with.
private final class RefusingSeparator: StemSeparating, @unchecked Sendable {
    private(set) var wasAsked = false
    let error: Error
    init(error: Error) { self.error = error }
    func separateIntoStems(sourceAudioPath: String, outputDir: String) async throws -> [String: String] {
        wasAsked = true
        throw error
    }
}

enum StemSeparationFixtures {
    /// The engine's OWN refusal, verbatim from
    /// `agent-surface/src/landing.rs::preflight`. Copied rather than paraphrased
    /// so a test that claims "the reason survives" is checking the reason that
    /// actually exists.
    static let engineRefusal = """
        stem separation is unavailable: `/usr/bin/python3` cannot import demucs \
        (ModuleNotFoundError: No module named 'demucs').
        Fix: /usr/bin/python3 -m pip install demucs
        (demucs does NOT install numpy as a dependency but imports it at load, so \
        install numpy too if it is missing.)
        No fallback was used: the unusable-stem stand-in exists for tests only, and \
        landing refuses rather than hand you stems that screech when soloed.
        """

    /// A real, decodable 1-second 16-bit mono WAV. The real engine has to be
    /// able to import these, so they cannot be `Data("fake".utf8)`.
    static func writeTone(to url: URL, seconds: Int = 1) throws {
        let rate = 48_000
        var body = Data()
        for i in 0..<(rate * seconds) {
            let v = sin(2 * .pi * 440 * Double(i) / Double(rate)) * 0.6
            var s = Int16(max(-1, min(1, v)) * 32_000)
            withUnsafeBytes(of: &s) { body.append(contentsOf: $0) }
        }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8)
        wav += le32(36 + body.count)
        wav += Data("WAVEfmt ".utf8)
        wav += le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        wav += Data("data".utf8) + le32(body.count) + body
        try wav.write(to: url)
    }
}

// MARK: - Reaching the separator from the Stems tab / the Library

@MainActor
@Suite("Separation — the gesture reaches the separator", .serialized)
struct StemSeparationReachTests {

    private func makeStore() throws -> (store: StemSessionStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemSeparationReach-\(UUID().uuidString)", isDirectory: true)
        let stemsDir = root.appendingPathComponent("StemSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: stemsDir, withIntermediateDirectories: true)
        return (StemSessionStore(directory: stemsDir,
                                 indexURL: root.appendingPathComponent("stem_sessions.json")),
                root)
    }

    @Test("the run hands the song to the separator and lands the parts in the Stems tab")
    func theRunReachesTheSeparatorAndOpensTheTab() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("Neon Getaway.wav")
        try StemSeparationFixtures.writeTone(to: song)

        let separator = RecordingSeparator(root: root)
        let coordinator = StudioCoordinator()
        coordinator.selectedTab = 2   // the Library, i.e. NOT the Stems tab
        let run = StemSeparationRun()

        let id = await run.separateIntoSession(
            source: song, title: "Neon Getaway", using: separator,
            store: store, coordinator: coordinator, outputRoot: root)

        // THE REACH CLAIM. Not "an action was assigned": the separator was
        // handed this song's path.
        #expect(separator.askedFor == [song.path],
                "the separator was never asked for this song — the gesture reaches nothing")

        let sessionID = try #require(id, "no session came back: \(run.failure ?? "and no reason either")")
        let doc = try #require(store.session(id: sessionID))
        #expect(doc.stems.count == 4, "the four parts did not land in the session")
        #expect(doc.stems.map(\.displayName) == ["Vocals", "Drums", "Bass", "Other"],
                "the parts are not in mixer order, got \(doc.stems.map(\.displayName))")
        #expect(doc.name == "Neon Getaway — Stems")

        // …and the person is taken to them.
        #expect(coordinator.selectedTab == 4, "the Stems tab did not come forward")
        #expect(coordinator.pendingStemSessionID == sessionID,
                "the Stems tab was opened on nothing in particular")
        #expect(run.isRunning == false)
        #expect(run.failure == nil)
    }

    /// The output directory is per-run. Two separations sharing one directory is
    /// how demucs' `<out>/htdemucs/<track>/` layout lets song B's vocals be read
    /// back as song A's.
    @Test("each run writes under its own directory")
    func eachRunHasItsOwnOutputDirectory() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("A.wav")
        try StemSeparationFixtures.writeTone(to: song)
        let separator = RecordingSeparator(root: root)
        let run = StemSeparationRun()

        _ = await run.separateIntoSession(source: song, title: "A", using: separator,
                                          store: store, coordinator: nil, outputRoot: root)
        _ = await run.separateIntoSession(source: song, title: "A", using: separator,
                                          store: store, coordinator: nil, outputRoot: root)
        #expect(separator.wroteUnder.count == 2)
        #expect(separator.wroteUnder[0] != separator.wroteUnder[1],
                "two runs shared an output directory, so one can read back the other's parts")
    }

    // MARK: The refusal

    @Test("a refused separation says why, in the separator's own words")
    func aRefusalReachesThePerson() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("Song.wav")
        try StemSeparationFixtures.writeTone(to: song)

        let separator = RefusingSeparator(
            error: StemSeparationTestError(StemSeparationFixtures.engineRefusal))
        let coordinator = StudioCoordinator()
        coordinator.selectedTab = 4
        let run = StemSeparationRun()

        let id = await run.separateIntoSession(
            source: song, title: "Song", using: separator,
            store: store, coordinator: coordinator, outputRoot: root)

        #expect(separator.wasAsked, "the refusal path never even reached the separator")
        #expect(id == nil)
        let shown = try #require(run.failure, "a refused separation said nothing at all")
        // The whole point: the engine's own sentence survives to the screen.
        #expect(shown.contains("cannot import demucs"),
                "the reason was rewritten: \(shown)")
        #expect(shown.contains("screech when soloed"),
                "the tail of the refusal — the part that says why there is no fallback — was cut off")
        #expect(shown.contains("pip install demucs"),
                "the fix went missing, so the person is told it failed and not how to fix it")
    }

    @Test("a refused separation leaves nothing half-landed")
    func aRefusalLandsNothing() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("Song.wav")
        try StemSeparationFixtures.writeTone(to: song)
        _ = store.createSession(name: "Something I already had")
        let before = store.sessions.map(\.id)

        let coordinator = StudioCoordinator()
        coordinator.selectedTab = 2
        let run = StemSeparationRun()
        _ = await run.separateIntoSession(
            source: song, title: "Song",
            using: RefusingSeparator(error: StemSeparationTestError(StemSeparationFixtures.engineRefusal)),
            store: store, coordinator: coordinator, outputRoot: root)

        #expect(store.sessions.map(\.id) == before,
                "a failed separation created a session anyway — an empty set of parts that looks like it worked")
        #expect(run.lastSessionID == nil)
        #expect(coordinator.selectedTab == 2,
                "a failed separation still yanked the person to the Stems tab, where there is nothing to see")
        #expect(run.isRunning == false, "the progress state never cleared, so the button stays dead")
    }

    /// The mutation this guards: `ProjectHeaderView` used to match RPC -32001
    /// and REPLACE the payload with "Install Demucs: pip install demucs" —
    /// advice that is wrong whenever the missing package is numpy or torch, and
    /// which threw away the interpreter path.
    @Test("the missing-dependency hint is added to the reason, never substituted for it")
    func theHintIsAddedNotSubstituted() {
        let backendSaid = "Server error (-32001): Stem export failed: Demucs failed: "
            + "ModuleNotFoundError: No module named 'numpy'\nDetail: /opt/py/bin/python3"
        let shown = StemSeparationRefusal.message(for: StemSeparationTestError(backendSaid))
        #expect(shown.hasPrefix(backendSaid),
                "the backend's own words were replaced rather than kept: \(shown)")
        #expect(shown.contains("numpy"), "the package that is actually missing is no longer named")
        #expect(shown.contains("/opt/py/bin/python3"),
                "the interpreter path went missing, and it is half of every real diagnosis")
        #expect(shown.contains(StemSeparationRefusal.installHint))
    }

    @Test("an unrelated failure is passed through without a dependency hint that does not apply")
    func anUnrelatedFailureGetsNoHint() {
        let shown = StemSeparationRefusal.message(
            for: StemSeparationTestError("Audio file not found: /Volumes/gone/song.wav"))
        #expect(shown == "Audio file not found: /Volumes/gone/song.wav")
        #expect(!shown.contains(StemSeparationRefusal.installHint),
                "a missing FILE was blamed on a missing package")
    }

    @Test("a separator that returns nothing is a failure, not an empty session")
    func noPartsIsAFailure() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("Song.wav")
        try StemSeparationFixtures.writeTone(to: song)
        let run = StemSeparationRun()
        let id = await run.separateIntoSession(
            source: song, title: "Song",
            using: RecordingSeparator(root: root, parts: []),
            store: store, coordinator: nil, outputRoot: root)
        #expect(id == nil)
        #expect(run.failure != nil, "an empty result was reported as success")
        #expect(store.sessions.isEmpty)
    }
}

/// A plain error carrying an exact sentence, so a refusal fixture is the words
/// the real thing says and not `NSError`'s rendering of a code.
struct StemSeparationTestError: LocalizedError {
    let said: String
    init(_ said: String) { self.said = said }
    var errorDescription: String? { said }
}

// MARK: - The call sites: is each entry point still attached?

@MainActor
@Suite("Separation — every entry point is still wired", .serialized)
struct StemSeparationWiringTests {

    private static let sourcesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../Sources")
        .standardizedFileURL

    /// The source with every `//` comment removed.
    ///
    /// ⚠️ Load-bearing. This file's own prose names `separateIntoSession(` and
    /// `separateIntoStems(`, and the files it scans explain themselves at
    /// length; an unstripped scan would be satisfied by a paragraph rather than
    /// by a call. That mutation — a guard matched by a comment about the line
    /// it polices — shipped in this repo.
    static func code(_ relativePath: String) throws -> String {
        let url = sourcesDirectory.appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// `code(_:)` with every `func` DECLARATION line dropped as well.
    ///
    /// ⚠️ ALSO LOAD-BEARING, and also written only after a mutation defeated
    /// the version without it. Tearing the whole separation call out of
    /// `LibraryView` left the entry-point scan GREEN, because the private
    /// method that used to contain it is spelled
    /// `private func separateIntoStems(_ track: Track)` — the needle matched
    /// the method's own definition. That is the second guard-shape this repo
    /// has shipped (the first was a guard matched by a comment about the line
    /// it policed, which `code(_:)` above handles).
    ///
    /// A declaration line cannot also be a call site in Swift: it ends in `{`
    /// or in a return type. Dropping those lines is what makes "this file
    /// CALLS something that separates" a claim rather than "this file
    /// MENTIONS the word".
    static func callSites(_ relativePath: String) throws -> String {
        try code(relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("func ") }
            .joined(separator: "\n")
    }

    /// `callSites(_:)` with ALL whitespace removed.
    ///
    /// ⚠️ THE THIRD SHAPE, and the third one a mutation had to find. The
    /// needles below name a call WITH ITS FIRST ARGUMENT LABEL, because the
    /// bare method name is ambiguous: `LibraryView` used to carry a private
    /// helper called `separateIntoStems(_ track:)`, and tearing the real call
    /// out of its body left the scan green on the helper's own call site one
    /// screen away. A label cannot be faked by a same-named local.
    ///
    /// Squeezing is what makes that workable at all: every one of these calls
    /// is wrapped across lines, so `.separateIntoStems(sourceAudioPath:` is
    /// never contiguous in the source. Removing whitespace is safe here
    /// precisely because the needles are labelled call prefixes, which cannot
    /// be produced by two unrelated tokens meeting.
    static func squeezed(_ relativePath: String) throws -> String {
        try callSites(relativePath).filter { !$0.isWhitespace }
    }

    /// Where a person can start a separation, and the file that wires it.
    ///
    /// This table is what makes `ManageModelsView`'s sentence checkable rather
    /// than a guess: a tab named there with no call site here is exactly the
    /// false claim this lane found ("It is used by the Stems tab", while
    /// `StemSessionsView.swift` contained no separation call of any kind).
    ///
    /// The needle for each is a call that reaches the shipped separator —
    /// either directly (`separateIntoStems`, the `StemSeparating` protocol
    /// method `BackendViewModel` implements with `export_stems`) or through the
    /// join (`separateIntoSession`, which the behavioural suite above proves
    /// calls it).
    static let entryPoints: [(tab: String, file: String)] = [
        ("Stems", "StemSessions/StemSessionsView.swift"),
        ("Library", "LibraryView.swift"),
        ("Studio", "Studio/StudioViewModel.swift"),
        ("Create", "EnhancedStudioView.swift"),
    ]

    /// A call that reaches the shipped separator, NAMED WITH ITS FIRST LABEL.
    ///
    /// Either the join (`StemSeparationRun.separateIntoSession`, which the
    /// behavioural suite above proves calls the separator) or the protocol
    /// method itself (`StemSeparating.separateIntoStems`, which
    /// `BackendViewModel` implements with `export_stems` ->
    /// `python -m demucs -n htdemucs`).
    ///
    /// Matched against `squeezed(_:)`, so these carry no spaces.
    static let reachNeedles = ["separateIntoSession(source:", ".separateIntoStems(sourceAudioPath:"]

    @Test("every entry point in the table still calls something that separates")
    func everyEntryPointIsAttached() throws {
        for (tab, file) in Self.entryPoints {
            let text = try Self.squeezed(file)
            #expect(text.count > 500, "\(file) did not load, so this checks nothing")
            #expect(Self.reachNeedles.contains(where: { text.contains($0) }),
                    "the \(tab) entry point is gone: \(file) no longer calls anything that separates")
        }
    }

    /// The Stems tab is called out on its own because it is the one the owner
    /// looked in, and because "the button is there but its action is empty" is
    /// the shape this repo ships. The button has to reach the JOIN — not the
    /// store, not a toast.
    @Test("the Stems tab's own button routes through the run, and the empty state offers it too")
    func theStemsTabOffersIt() throws {
        let text = try Self.squeezed("StemSessions/StemSessionsView.swift")
        #expect(text.contains("separateIntoSession(source:"),
                "the Stems tab no longer reaches the separation run — its button sends nothing")
        let helpText = try Self.callSites("StemSessions/StemSessionsView.swift")
        #expect(helpText.contains("\"stems.separate\""),
                "the Stems sidebar's Split button lost its help, or the button is gone")
        #expect(helpText.contains("\"stems.separate.empty\""),
                "the empty state no longer offers separation, which is the exact screen the owner was looking at")
    }

    /// The Library's half needs BOTH halves of its wire, and until a mutation
    /// went looking it had neither guarded.
    ///
    /// Deleting the whole "Split into Stems" Button out of `LibraryTrackRow`
    /// left every test green: the handler in `LibraryView` was still there and
    /// still correct, and nothing anywhere asserted that a person could press
    /// anything to reach it. That is this repo's own signature defect — a
    /// working capability with no way in — reproduced inside the lane that
    /// exists to fix it.
    @Test("the Library's song menu offers the split, and it is wired to the handler")
    func theLibraryRowOffersIt() throws {
        let row = try Self.callSites("LibraryTrackRow.swift")
        #expect(row.contains("Button(action: onSeparateIntoStems)"),
                "the Library song menu no longer offers Split into Stems — the handler is unreachable")
        #expect(row.contains("Split into Stems"),
                "the menu item lost its label, so it is a blank row in the menu")

        let list = try Self.callSites("LibraryView.swift")
        #expect(list.contains("onSeparateIntoStems:"),
                "the Library list never hands the row a handler, so the menu item does nothing")
    }

    /// The Studio's half lands FOUR TRACKS, so its call site is the bracket, not
    /// the session builder.
    @Test("the Studio's separation is bracketed as one gesture")
    func theStudioSeparationIsBracketed() throws {
        let text = try Self.squeezed("Studio/StudioViewModel.swift")
        #expect(text.contains(".separateIntoStems(sourceAudioPath:"),
                "the Studio no longer asks the separator for anything")
        #expect(text.contains("StudioViewModel.separateReason") || text.contains("Self.separateReason"),
                "the Studio's separation no longer opens its own txn bracket, so four tracks are four undo steps")
    }

    /// ⌘K and the Track menu, from one row. The menu file is DERIVED from the
    /// palette table and may name no catalog command of its own — so the row is
    /// a `studio.*` view row, and the menu places it by id.
    @Test("separation is offered by the palette and lands in exactly one menu")
    func theRowIsOfferedAndPlaced() {
        let row = StudioPaletteCatalog.entries().first { $0.id == StudioMenuPlan.separateViewRowID }
        #expect(row != nil, "⌘K no longer offers separation at all")
        #expect(!CatalogNames.names.contains(StudioMenuPlan.separateViewRowID),
                "the view row borrowed a catalog command's name, which is the drift the menu file forbids")
        #expect(StudioMenuPlan.viewRowMenu(StudioMenuPlan.separateViewRowID) == .track,
                "the separation row is not in the Track menu")
        let inTrack = StudioMenuPlan.viewRows(in: .track).map(\.id)
        #expect(inTrack.contains(StudioMenuPlan.separateViewRowID),
                "the row is placed in the Track menu by the function and absent from the menu's own list")
    }

    /// THE ⌘K / TRACK-MENU REACH CLAIM, end to end.
    ///
    /// Not "a closure was assigned": this pulls the action OUT of the palette
    /// row — the same closure `StudioMenuBridge.runViewRow` and the palette's
    /// own Return key invoke — runs it, and then asks a recording separator
    /// whether it was handed the song the chooser answered with. Break the row
    /// (make its action a no-op, point it at the wrong method, forget to await
    /// the Task) and this fails on "the separator was never asked".
    ///
    /// The file chooser is the injected `songChooser`, which is why this is
    /// driveable at all: an `NSOpenPanel` opened inside the gesture would hang
    /// the whole test bundle with no output.
    @Test("pressing the palette / Track-menu row runs the real separation")
    func theRowReachesTheSeparator() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemSeparationRow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("Neon Getaway.wav")
        try StemSeparationFixtures.writeTone(to: song)

        let engine = StudioMockEngine()
        let vm = StudioViewModel(engine: engine)
        vm.startPolling()
        for _ in 0..<200 where vm.snapshot == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        vm.stopPolling()

        let separator = RecordingSeparator(root: root)
        vm.stemSeparator = separator
        vm.songChooser = { song }

        let row = try #require(
            StudioPaletteCatalog.entries().first { $0.id == StudioMenuPlan.separateViewRowID })
        #expect(row.viewBlock?(StudioPaletteContext(model: vm)) == nil,
                "the row is blocked with everything it needs in place")

        guard case .view(let action) = row.kind else {
            Issue.record("the separation row is not a view row, so the menu cannot place it")
            return
        }
        action(vm)

        // The action fires a Task; wait for the separator to be asked rather
        // than for a fixed interval.
        for _ in 0..<400 where separator.askedFor.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(separator.askedFor == [song.path],
                "the ⌘K / Track-menu row does not reach the separator: it is a button onto nothing")

        for _ in 0..<400 where vm.separating {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(vm.separationError == nil, "the split refused: \(vm.separationError ?? "")")
        let after = try #require(await engine.snapshot(ifNewerThan: nil))
        #expect(after.tracks.suffix(4).map(\.name) == ["Vocals", "Drums", "Bass", "Other"],
                "the row ran but the parts never became tracks")
    }

    /// Cancelling the chooser is a real answer, not a failure. An error dialog
    /// for "I changed my mind" is its own kind of lie.
    @Test("cancelling the file chooser leaves no error and no work")
    func cancellingIsNotAnError() async throws {
        let vm = StudioViewModel(engine: StudioMockEngine())
        vm.startPolling()
        for _ in 0..<200 where vm.snapshot == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        vm.stopPolling()
        let root = FileManager.default.temporaryDirectory
        let separator = RecordingSeparator(root: root)
        vm.stemSeparator = separator
        vm.songChooser = { nil }

        vm.chooseSongAndSeparate()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(vm.separationError == nil, "cancelling produced an error: \(vm.separationError ?? "")")
        #expect(separator.askedFor.isEmpty)
        #expect(vm.separating == false)
    }

    /// A row that a person can highlight and press Return on to no effect is
    /// the defect the palette exists to prevent. Every way this row can be
    /// inert has to produce its OWN reason.
    ///
    /// ⚠️ THIS TEST WAS WRITTEN WRONG THE FIRST TIME and a mutation caught it,
    /// which is why it is a table now. It used to set `stemSeparator = nil`,
    /// leave everything else unset, and assert only that SOME reason came back
    /// and that it was over thirty characters. Deleting the `stemSeparator ==
    /// nil` guard entirely left it green — the NEXT guard (`songChooser == nil`,
    /// which the same unconfigured fixture also tripped) answered instead, and
    /// the assertion could not tell the two apart. A guard satisfied by a
    /// different guard is the same shape as a clamp test satisfied by the
    /// default value.
    ///
    /// So each row below sets up exactly ONE missing thing, with everything
    /// else present, and asserts the exact sentence. Delete any one branch of
    /// the `viewBlock` and the matching case fails naming it.
    @Test("every way the row can be inert produces its own reason")
    func theRowRefusesForTheRightReason() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemSeparationBlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("Song.wav")
        try StemSeparationFixtures.writeTone(to: song)

        let row = try #require(
            StudioPaletteCatalog.entries().first { $0.id == StudioMenuPlan.separateViewRowID })

        /// A view model with EVERYTHING the row needs, so a test can then take
        /// away exactly one thing.
        func readyModel() async throws -> StudioViewModel {
            let vm = StudioViewModel(engine: StudioMockEngine())
            vm.startPolling()
            for _ in 0..<200 where vm.snapshot == nil { try await Task.sleep(nanoseconds: 20_000_000) }
            vm.stopPolling()
            vm.stemSeparator = RecordingSeparator(root: root)
            vm.songChooser = { song }
            return vm
        }

        // The control: fully staged, the row is READY. Without this the four
        // cases below would all pass against a row that is blocked always.
        let ready = try await readyModel()
        #expect(row.viewBlock?(StudioPaletteContext(model: ready)) == nil,
                "the row is blocked with everything it needs, so it can never run")

        // 1. Nothing to separate with.
        let noSeparator = try await readyModel()
        noSeparator.stemSeparator = nil
        #expect(row.viewBlock?(StudioPaletteContext(model: noSeparator))
                == StudioViewModel.noSeparatorReason,
                "the row does not refuse when there is nothing behind it to separate with")

        // 2. No way to ask which song.
        let noChooser = try await readyModel()
        noChooser.songChooser = nil
        #expect(row.viewBlock?(StudioPaletteContext(model: noChooser))
                == StudioViewModel.noChooserReason,
                "the row does not refuse when it cannot ask for a song")

        // 3. Nowhere for the parts to land. The model is constructed WITHOUT
        //    polling, so it genuinely has no snapshot.
        let noProject = StudioViewModel(engine: StudioMockEngine())
        noProject.stemSeparator = RecordingSeparator(root: root)
        noProject.songChooser = { song }
        #expect(noProject.snapshot == nil, "the fixture polled after all, so this case proves nothing")
        #expect(row.viewBlock?(StudioPaletteContext(model: noProject))
                == StudioViewModel.noProjectReason,
                "the row does not refuse with no project open")

        // 4. One at a time. Two demucs subprocesses is how a laptop stops
        //    responding, and a second press must say so rather than queue.
        let busy = try await readyModel()
        let started = Task { @MainActor in
            await busy.separateIntoStemTracks(
                path: song.path, named: "Song", outputRoot: root)
        }
        for _ in 0..<400 where !busy.separating { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(busy.separating, "the split never started, so the busy case proves nothing")
        #expect(row.viewBlock?(StudioPaletteContext(model: busy))
                == StemSeparationRun.alreadyRunningRefusal,
                "a second press during a split is not refused")
        await started.value

        // Every reason is long enough to act on, and they are all DIFFERENT —
        // four branches answering one sentence would be the same defect.
        let reasons = [
            StudioViewModel.noSeparatorReason, StudioViewModel.noChooserReason,
            StudioViewModel.noProjectReason, StemSeparationRun.alreadyRunningRefusal,
        ]
        for reason in reasons {
            #expect(reason.count >= 30, "\"\(reason)\" is too short to be a reason")
        }
        #expect(Set(reasons).count == reasons.count,
                "two of the row's refusals say the same thing, so one of them names the wrong problem")
    }
}

// MARK: - Does the app's own documentation still match the app?

@MainActor
@Suite("Separation — what Manage Models claims is what the app does", .serialized)
struct StemSeparationClaimTests {

    /// THE ONE THIS LANE EXISTS FOR.
    ///
    /// `ManageModelsView` stated, in the shipped build: "The htdemucs model
    /// splits a track into vocals, drums, bass, and other parts. **It is used by
    /// the Stems tab.**" The Stems tab could not separate anything — its own
    /// empty state told you to go elsewhere. Same family as the Files pane help
    /// that promised drag-and-drop for rows carrying no gesture.
    ///
    /// So the sentence is now a named constant, and this reads it and checks
    /// every surface it names against `StemSeparationWiringTests.entryPoints`.
    /// Put the old sentence back with the Stems button removed and this fails
    /// naming "Stems".
    @Test("every tab the stem-model blurb names really can start a separation")
    func theBlurbNamesOnlyRealEntryPoints() throws {
        let blurb = ManageModelsView.stemModelBlurb
        let byTab = Dictionary(uniqueKeysWithValues:
            StemSeparationWiringTests.entryPoints.map { ($0.tab, $0.file) })

        var named: [String] = []
        for tab in StudioSection.allCases.map(\.title) where blurb.contains(tab) {
            named.append(tab)
            let file = try #require(
                byTab[tab],
                "the blurb sends people to the \(tab) tab and nothing in this build wires separation there")
            let text = try StemSeparationWiringTests.squeezed(file)
            #expect(StemSeparationWiringTests.reachNeedles.contains(where: { text.contains($0) }),
                    "the blurb says the \(tab) tab starts a separation; \(file) calls nothing that separates")
        }

        #expect(named.count >= 2,
                "the blurb names \(named) — it has to send a person somewhere, or it is the old dead end in new words")
        #expect(named.contains("Stems"),
                "the Stems tab is the place the owner looked and the blurb no longer names it")
    }

    /// The constant has to be the thing actually on screen. A blurb that is
    /// correct in a `static let` and stale in the view body is the same lie one
    /// indirection further away.
    @Test("the blurb is what Manage Models renders")
    func theBlurbIsRendered() throws {
        let text = try StemSeparationWiringTests.code("ManageModelsView.swift")
        #expect(text.contains("Text(Self.stemModelBlurb)"),
                "Manage Models renders some other sentence than the one this suite checks")
        #expect(!text.contains("It is used by the Stems tab."),
                "the false sentence is back")
    }

    /// The Stems tab's own empty state used to be the dead end: "Create one
    /// here, or extract stems in the Studio and open them as a session." It has
    /// to offer the thing instead of pointing at another tab.
    @Test("the Stems empty state no longer sends people to another tab")
    func theEmptyStateNoLongerDeflects() throws {
        let text = try StemSeparationWiringTests.code("StemSessions/StemSessionsView.swift")
        #expect(!text.contains("extract stems in the Studio and open them as a session"),
                "the Stems tab still tells you to do it somewhere else")
    }
}
