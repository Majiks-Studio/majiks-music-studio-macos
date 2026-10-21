import Testing
import Foundation
import SwiftUI
@testable import MajiksMusicStudio

// The Stems tab as a BREAKOUT of one song: what each part is, where it draws,
// what Solo does to the set, and the route out to the Studio.
//
// Everything asserted here is against hardcoded expected values. A test like
// `#expect(playheadX <= width)` would pass for every implementation including
// one that returns zero, which is the shape of a tautology this repo has
// shipped before.

@Suite("Stem breakout — identity, layout, solo policy")
struct StemBreakoutTests {

    // MARK: - What kind of part is this?

    @Test("the four parts a song splits into get the suite's four stem colours")
    func canonicalFourStemsClassify() {
        #expect(StemKindInference.kind(displayName: "Vocals") == .vocals)
        #expect(StemKindInference.kind(displayName: "Drums") == .drums)
        #expect(StemKindInference.kind(displayName: "Bass") == .bass)
        #expect(StemKindInference.kind(displayName: "Other") == .other)
    }

    @Test("the colour a part gets here is the colour the Studio gives it")
    func coloursMatchTheStudio() {
        // The actual defect this closes: the Stems tab coloured rows from a
        // rotating palette by ROW INDEX, so the same vocal was a different
        // colour in a 4-stem and a 5-stem session, and neither matched the
        // Studio. These are the suite-wide constants, shared with Majik's DJ.
        #expect(StudioTokens.stemColor(StemKindInference.kind(displayName: "Vocals"))
                == StudioTokens.stemVocals)
        #expect(StudioTokens.stemColor(StemKindInference.kind(displayName: "Drums"))
                == StudioTokens.stemDrums)
        #expect(StudioTokens.stemColor(StemKindInference.kind(displayName: "Bass"))
                == StudioTokens.stemBass)
        #expect(StudioTokens.stemColor(StemKindInference.kind(displayName: "Other"))
                == StudioTokens.stemOther)

        // And the four are distinct, or the breakout is a monochrome list.
        let colours = [StudioTokens.stemVocals, StudioTokens.stemDrums,
                       StudioTokens.stemBass, StudioTokens.stemOther]
        #expect(Set(colours.map { "\($0)" }).count == 4)
    }

    @Test("the names an extract and a Demucs export actually produce")
    func realWorldNamesClassify() {
        // What `openExtractResultsAsStemSession` and
        // `openDemucsStemsAsStemSession` write into displayName.
        #expect(StemKindInference.kind(displayName: "Vocals (Take 2)") == .vocals)
        #expect(StemKindInference.kind(displayName: "Backing Vocals") == .vocals)
        #expect(StemKindInference.kind(displayName: "Lead Vox") == .vocals)
        #expect(StemKindInference.kind(displayName: "Percussion") == .drums)
        #expect(StemKindInference.kind(displayName: "808") == .bass)
        // Demucs six-stem mode: guitar and piano are "other" in the four-stem
        // taxonomy the Studio and the DJ both speak.
        #expect(StemKindInference.kind(displayName: "Guitar") == .other)
        #expect(StemKindInference.kind(displayName: "Piano") == .other)
        #expect(StemKindInference.kind(displayName: "Instrumental") == .other)
    }

    @Test("a bass drum is a drum, not a bass")
    func resolutionOrderIsLoadBearing() {
        // "bassdrum" and "kick drum" contain both fragments; drums wins.
        #expect(StemKindInference.kind(displayName: "Bass Drum") == .drums)
        #expect(StemKindInference.kind(displayName: "bassdrum") == .drums)
        #expect(StemKindInference.kind(displayName: "Kick") == .drums)
        // But a plain bass part is still bass.
        #expect(StemKindInference.kind(displayName: "Bass") == .bass)
        #expect(StemKindInference.kind(displayName: "Sub Bass") == .bass)
    }

    @Test("the file name is the fallback when the display name says nothing")
    func fileNameFallback() {
        #expect(StemKindInference.kind(displayName: "Take 3",
                                       fileName: "a1b2c3d4_vocals.wav") == .vocals)
        // Display name wins when it DOES classify.
        #expect(StemKindInference.kind(displayName: "Drums",
                                       fileName: "a1b2c3d4_vocals.wav") == .drums)
    }

    @Test("an unclassifiable part is grey and says Audio, not a wrong colour")
    func unknownIsImported() {
        #expect(StemKindInference.kind(displayName: "Take 3", fileName: "clip7.wav") == .imported)
        #expect(StemKindInference.kind(displayName: "") == .imported)
        #expect(StudioTokens.stemColor(.imported) == StudioTokens.stemImported)
        #expect(StemKindInference.label(.imported) == "Audio")
    }

    @Test("badge labels are words, not the wire strings")
    func badgeLabels() {
        #expect(StemKindInference.label(.vocals) == "Vocals")
        #expect(StemKindInference.label(.drums) == "Drums")
        #expect(StemKindInference.label(.bass) == "Bass")
        #expect(StemKindInference.label(.other) == "Other")
    }

    // MARK: - Lane geometry

    @Test("the playhead is the same x on every lane, at hardcoded positions")
    func playheadMath() {
        // A 210 s (3:30) song in a 900 pt lane — the owner's actual case.
        #expect(StemBreakoutLayout.playheadX(time: 0, duration: 210, width: 900) == 0)
        #expect(StemBreakoutLayout.playheadX(time: 105, duration: 210, width: 900) == 450)
        #expect(StemBreakoutLayout.playheadX(time: 210, duration: 210, width: 900) == 900)
        #expect(StemBreakoutLayout.playheadX(time: 52.5, duration: 210, width: 900) == 225)
    }

    @Test("a seek past either end cannot draw off the lane")
    func playheadClamps() {
        #expect(StemBreakoutLayout.playheadX(time: -30, duration: 210, width: 900) == 0)
        #expect(StemBreakoutLayout.playheadX(time: 9_999, duration: 210, width: 900) == 900)
        // Zero-length or zero-width session: no divide, no NaN.
        #expect(StemBreakoutLayout.playheadX(time: 10, duration: 0, width: 900) == 0)
        #expect(StemBreakoutLayout.playheadX(time: 10, duration: 210, width: 0) == 0)
    }

    @Test("clicking a lane lands on the moment under the cursor")
    func seekMathIsTheInverse() {
        #expect(StemBreakoutLayout.time(atX: 0, duration: 210, width: 900) == 0)
        #expect(StemBreakoutLayout.time(atX: 450, duration: 210, width: 900) == 105)
        #expect(StemBreakoutLayout.time(atX: 900, duration: 210, width: 900) == 210)
        // Clamped, so a drag off the edge does not seek past the end.
        #expect(StemBreakoutLayout.time(atX: -100, duration: 210, width: 900) == 0)
        #expect(StemBreakoutLayout.time(atX: 1_500, duration: 210, width: 900) == 210)
    }

    @Test("ruler labels land on round numbers, not on 26.25 s")
    func rulerLadder() {
        #expect(StemBreakoutLayout.rulerStep(duration: 210) == 30)     // 3:30 song
        #expect(StemBreakoutLayout.rulerStep(duration: 20) == 5)       // short loop
        #expect(StemBreakoutLayout.rulerStep(duration: 600) == 120)    // long piece
        #expect(StemBreakoutLayout.rulerStep(duration: 3_600) == 300)  // off the ladder: clamps
    }

    @Test("the columns are fixed, which is what makes one playhead honest")
    func fixedColumns() {
        // If these ever became per-lane the shared playhead would silently
        // start lying about where in the song each lane is.
        #expect(StemBreakoutLayout.headerWidth == 180)
        #expect(StemBreakoutLayout.mixWidth == 176)
        #expect(StemBreakoutLayout.laneHeight == 76)
        // Wider than the Studio's track header, on purpose (viewing distance).
        #expect(StemBreakoutLayout.headerWidth > StudioTokens.trackHeaderWidth)
        // And a lane is materially taller than the 36 pt strip it replaced.
        #expect(StemBreakoutLayout.laneHeight >= 72)
    }

    // MARK: - Solo policy

    private func stems(_ spec: [(String, Bool)]) -> [SessionStem] {
        spec.map { SessionStem(fileName: "\($0.0).wav", displayName: $0.0, solo: $0.1) }
    }

    @Test("a plain click on Solo means: JUST this part")
    func plainClickIsExclusive() {
        let set = stems([("Vocals", false), ("Drums", true), ("Bass", true), ("Other", false)])
        let changes = StemSoloPlan.changes(stems: set, tapped: set[0].id, additive: false)

        // Vocals on, and BOTH previously-soloed parts off — in one plan.
        #expect(changes.count == 3)
        #expect(changes.contains(StemSoloPlan.Change(id: set[0].id, solo: true)))
        #expect(changes.contains(StemSoloPlan.Change(id: set[1].id, solo: false)))
        #expect(changes.contains(StemSoloPlan.Change(id: set[2].id, solo: false)))
        // Other was already un-soloed: not in the plan, so not an undo entry.
        #expect(!changes.contains { $0.id == set[3].id })
    }

    @Test("clicking the only soloed part turns solo off — the button is still a toggle")
    func clickingTheOnlySoloedStemClearsIt() {
        let set = stems([("Vocals", true), ("Drums", false)])
        let changes = StemSoloPlan.changes(stems: set, tapped: set[0].id, additive: false)
        #expect(changes == [StemSoloPlan.Change(id: set[0].id, solo: false)])
    }

    @Test("clicking a soloed part while others are soloed narrows to just it")
    func clickingASoloedStemAmongOthersNarrows() {
        let set = stems([("Vocals", true), ("Drums", true)])
        let changes = StemSoloPlan.changes(stems: set, tapped: set[0].id, additive: false)
        // Vocals stays on (no change emitted for it), Drums goes off.
        #expect(changes == [StemSoloPlan.Change(id: set[1].id, solo: false)])
    }

    @Test("option-click adds to the solo set instead of replacing it")
    func optionClickIsAdditive() {
        let set = stems([("Vocals", true), ("Drums", false), ("Bass", false)])
        let changes = StemSoloPlan.changes(stems: set, tapped: set[1].id, additive: true)
        #expect(changes == [StemSoloPlan.Change(id: set[1].id, solo: true)])

        // And additive on an already-soloed part removes just that one.
        let off = StemSoloPlan.changes(stems: set, tapped: set[0].id, additive: true)
        #expect(off == [StemSoloPlan.Change(id: set[0].id, solo: false)])
    }

    @Test("a stem that is not in the set produces no writes")
    func unknownStemIsANoOp() {
        let set = stems([("Vocals", false)])
        #expect(StemSoloPlan.changes(stems: set, tapped: UUID(), additive: false).isEmpty)
    }

    @Test("the undo step is named for the gesture, not for the writes")
    func actionNaming() {
        let set = stems([("Vocals", false), ("Drums", true)])
        let on = StemSoloPlan.changes(stems: set, tapped: set[0].id, additive: false)
        #expect(StemSoloPlan.actionName(changes: on, stemName: "Vocals") == "Solo Vocals")

        let solo = stems([("Vocals", true)])
        let off = StemSoloPlan.changes(stems: solo, tapped: solo[0].id, additive: false)
        #expect(StemSoloPlan.actionName(changes: off, stemName: "Vocals") == "Unsolo Vocals")
    }
}

// MARK: - Solo through the store: one gesture, one undo step

@MainActor
@Suite("Stem breakout — solo is journalled document state", .serialized)
struct StemSoloJournalTests {

    private func makeStore() throws -> (store: StemSessionStore, root: URL, sources: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemSoloJournalTests-\(UUID().uuidString)", isDirectory: true)
        let stemsDir = root.appendingPathComponent("StemSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: stemsDir, withIntermediateDirectories: true)

        var sources: [URL] = []
        for name in ["vocals", "drums", "bass", "other"] {
            let url = root.appendingPathComponent("\(name).wav")
            try Data("fake-\(name)".utf8).write(to: url)
            sources.append(url)
        }
        let store = StemSessionStore(
            directory: stemsDir,
            indexURL: root.appendingPathComponent("stem_sessions.json"))
        return (store, root, sources)
    }

    private func makeUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    private func perform(_ um: UndoManager, _ op: () -> Void) {
        um.beginUndoGrouping()
        op()
        um.endUndoGrouping()
    }

    /// Solo/mute here are DOCUMENT state, journalled and undoable — matching
    /// how the Studio treats them (`track.mute` / `track.solo` are catalog
    /// commands on the journalled bus, not monitor-only flags). They persist
    /// with the session, so reopening it plays back what you left.
    @Test("an exclusive solo across four parts is ONE undo step")
    func exclusiveSoloIsOneUndoStep() throws {
        let (store, root, sources) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let um = makeUndoManager()

        let doc = store.createSession(name: "Song — Stems")
        _ = try store.addStems(fileURLs: sources, to: doc.id)

        // Start from drums + bass soloed.
        var stems = try #require(store.session(id: doc.id)?.stems)
        perform(um) { store.setStemSolo(id: stems[1].id, in: doc.id, solo: true, undoManager: nil) }
        perform(um) { store.setStemSolo(id: stems[2].id, in: doc.id, solo: true, undoManager: nil) }
        stems = try #require(store.session(id: doc.id)?.stems)
        #expect(stems.filter(\.solo).count == 2)

        // ONE click on Vocals' Solo.
        let plan = StemSoloPlan.changes(stems: stems, tapped: stems[0].id, additive: false)
        perform(um) {
            store.applySoloPlan(plan, in: doc.id,
                                actionName: StemSoloPlan.actionName(changes: plan, stemName: "vocals"),
                                undoManager: um)
        }

        let after = try #require(store.session(id: doc.id)?.stems)
        #expect(after.map(\.solo) == [true, false, false, false])
        #expect(um.undoActionName == "Solo vocals")

        // ONE ⌘Z restores ALL THREE, not one of them.
        um.undo()
        let undone = try #require(store.session(id: doc.id)?.stems)
        #expect(undone.map(\.solo) == [false, true, true, false])

        // And redo puts the whole gesture back.
        um.redo()
        let redone = try #require(store.session(id: doc.id)?.stems)
        #expect(redone.map(\.solo) == [true, false, false, false])
    }

    @Test("the solo set decides what is actually silent")
    func soloSetDrivesEffectiveGain() throws {
        let (store, root, sources) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let doc = store.createSession(name: "Song — Stems")
        _ = try store.addStems(fileURLs: sources, to: doc.id)
        var stems = try #require(store.session(id: doc.id)?.stems)

        let plan = StemSoloPlan.changes(stems: stems, tapped: stems[0].id, additive: false)
        store.applySoloPlan(plan, in: doc.id, actionName: "Solo vocals")

        let document = try #require(store.session(id: doc.id))
        let gains = StemMix.effectiveLinearGains(for: document)
        stems = document.stems
        // The soloed part passes at unity; the other three are hard silent.
        #expect(gains[stems[0].id] == 1)
        #expect(gains[stems[1].id] == 0)
        #expect(gains[stems[2].id] == 0)
        #expect(gains[stems[3].id] == 0)
    }

    @Test("a plan that changes nothing writes nothing and adds no undo step")
    func noOpPlanIsIgnored() throws {
        let (store, root, sources) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let um = makeUndoManager()

        let doc = store.createSession(name: "Song — Stems")
        _ = try store.addStems(fileURLs: [sources[0]], to: doc.id)
        let stems = try #require(store.session(id: doc.id)?.stems)

        // No `perform` wrapper here on purpose: an empty undo GROUP is itself
        // undoable, which would mask exactly what this test is checking — that
        // the store registered nothing at all.
        store.applySoloPlan(
            [StemSoloPlan.Change(id: stems[0].id, solo: false)],
            in: doc.id, actionName: "Unsolo vocals", undoManager: um)
        #expect(um.canUndo == false)
    }
}

// MARK: - The wiring the mutation check found missing

/// Planning a solo correctly and committing it correctly are worth nothing if
/// nothing calls both.
///
/// Two mutations survived the first pass of this lane's tests: making the Solo
/// button's action send NOTHING, and making it write each stem's solo
/// separately (so one click became four undo steps). Both were green, because
/// every test aimed at `StemSoloPlan.changes` or at
/// `StemSessionStore.applySoloPlan` and nothing at the code joining them — which
/// lived in a private method on a SwiftUI view no test can reach.
///
/// The join is now `StemSoloAction.apply`. These tests exercise it against a
/// real store, and pin that the button still routes through it.
@MainActor
@Suite("Stem breakout — the Solo button's wiring", .serialized)
struct StemBreakoutWiringTests {

    private func makeStore() throws -> (store: StemSessionStore, root: URL, sources: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemWiringTests-\(UUID().uuidString)", isDirectory: true)
        let stemsDir = root.appendingPathComponent("StemSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: stemsDir, withIntermediateDirectories: true)
        var sources: [URL] = []
        for name in ["vocals", "drums", "bass", "other"] {
            let url = root.appendingPathComponent("\(name).wav")
            try Data("fake-\(name)".utf8).write(to: url)
            sources.append(url)
        }
        return (StemSessionStore(directory: stemsDir,
                                 indexURL: root.appendingPathComponent("stem_sessions.json")),
                root, sources)
    }

    @Test("the Solo action reaches the document and is exclusive")
    func soloActionWritesThrough() throws {
        let (store, root, sources) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let doc = store.createSession(name: "Song — Stems")
        _ = try store.addStems(fileURLs: sources, to: doc.id)
        var stems = try #require(store.session(id: doc.id)?.stems)

        StemSoloAction.apply(tapped: stems[1], in: stems, sessionID: doc.id,
                             additive: false, store: store, undoManager: nil)
        stems = try #require(store.session(id: doc.id)?.stems)
        #expect(stems.map(\.solo) == [false, true, false, false])

        // Exclusive: soloing another part moves the spotlight, it does not add.
        StemSoloAction.apply(tapped: stems[3], in: stems, sessionID: doc.id,
                             additive: false, store: store, undoManager: nil)
        stems = try #require(store.session(id: doc.id)?.stems)
        #expect(stems.map(\.solo) == [false, false, false, true])
    }

    @Test("one click on Solo is one undo step, even when it writes four stems")
    func soloActionIsOneUndoStep() throws {
        let (store, root, sources) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let um = UndoManager()
        um.groupsByEvent = false

        let doc = store.createSession(name: "Song — Stems")
        _ = try store.addStems(fileURLs: sources, to: doc.id)
        var stems = try #require(store.session(id: doc.id)?.stems)
        store.setStemSolo(id: stems[1].id, in: doc.id, solo: true)
        store.setStemSolo(id: stems[2].id, in: doc.id, solo: true)
        stems = try #require(store.session(id: doc.id)?.stems)

        um.beginUndoGrouping()
        StemSoloAction.apply(tapped: stems[0], in: stems, sessionID: doc.id,
                             additive: false, store: store, undoManager: um)
        um.endUndoGrouping()

        #expect(try #require(store.session(id: doc.id)).stems.map(\.solo)
                == [true, false, false, false])
        #expect(um.undoActionName == "Solo vocals")

        // ONE undo restores all three, and there is nothing left to undo after.
        um.undo()
        #expect(try #require(store.session(id: doc.id)).stems.map(\.solo)
                == [false, true, true, false])
        #expect(um.canUndo == false,
                "the click left more than one undo step behind")
    }

    @Test("option-click adds to the solo set through the same action")
    func soloActionAdditive() throws {
        let (store, root, sources) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let doc = store.createSession(name: "Song — Stems")
        _ = try store.addStems(fileURLs: sources, to: doc.id)
        var stems = try #require(store.session(id: doc.id)?.stems)

        StemSoloAction.apply(tapped: stems[0], in: stems, sessionID: doc.id,
                             additive: false, store: store, undoManager: nil)
        stems = try #require(store.session(id: doc.id)?.stems)
        StemSoloAction.apply(tapped: stems[1], in: stems, sessionID: doc.id,
                             additive: true, store: store, undoManager: nil)
        stems = try #require(store.session(id: doc.id)?.stems)
        #expect(stems.map(\.solo) == [true, true, false, false])
    }

    // MARK: The shape that keeps the button attached

    private static let viewSource: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/StemSessions/StemSessionsView.swift")
            .standardizedFileURL
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The Stems view must commit solo through `StemSoloAction` and nowhere
    /// else. Deleting the call (mutation: "Solo sends nothing") or replacing it
    /// with per-stem `setStemSolo` writes (mutation: "one click, four undo
    /// steps") both fail here by name — the two mutations that previously
    /// survived this suite untouched.
    @Test("the Solo button routes through the one-undo-step action, and only that")
    func theViewCommitsSoloThroughTheAction() {
        let source = Self.viewSource
        #expect(!source.isEmpty, "StemSessionsView.swift did not load, so this proves nothing")
        #expect(source.contains("StemSoloAction.apply("),
                "the Stems view no longer commits solo through StemSoloAction — the Solo button sends nothing")
        #expect(!source.contains("setStemSolo("),
                "the Stems view writes solo per stem again, so one click is N undo steps")
        // And the button is still the thing that calls it.
        #expect(source.contains("applySolo(additive:"),
                "the Solo button's action no longer reaches applySolo")
    }

    /// `applySolo` must be a straight-through call and nothing else.
    ///
    /// The looser check above passes if the call is merely PRESENT — a guard
    /// inserted above it ("make Solo send nothing") leaves the text intact and
    /// slips through. So this one reads the function's body and requires it to
    /// be the single call: no early return, no branch.
    ///
    /// A shape check, stated as one. No test in this suite can prove that a
    /// SwiftUI Button's action actually fires; that needs a driven window,
    /// which this lane does not have. What it can do is make the two ways of
    /// silently unhooking the button both fail here, by name.
    @Test("the Solo button's action has no way to return before committing")
    func theSoloActionBodyIsUnconditional() throws {
        let source = Self.viewSource
        let marker = "private func applySolo(additive: Bool) {"
        let start = try #require(source.range(of: marker),
                                 "applySolo is gone or was renamed")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"),
                               "could not find the end of applySolo")
        let body = String(rest[..<end.lowerBound])

        #expect(body.contains("StemSoloAction.apply("),
                "applySolo does not call StemSoloAction.apply, so the Solo button sends nothing")
        #expect(!body.contains("return"),
                "applySolo can return before committing — the Solo button can silently do nothing")
        #expect(!body.contains("if "),
                "applySolo grew a branch; a Solo click must always reach the store")
    }

    /// The lane's four bindings to LIVE state.
    ///
    /// Every component behind these is proven elsewhere in this lane — the
    /// meter's scale by `StemMix.meterFraction`, the waveform by
    /// `StemLaneRenderTests`, the colour by `StemKindInference` — and every one
    /// of them can be correct while the single line that FEEDS it is wrong.
    /// Mutation checks confirmed exactly that: replacing the stem meter's
    /// levels with `.zero`, and replacing the lane colour with a constant, each
    /// left this whole suite green while the surface silently stopped saying
    /// anything true. That is the silent-degradation shape — a component that
    /// renders happily from dead input.
    ///
    /// A shape check, stated as one, for the same reason as the test above:
    /// asserting a SwiftUI view's bindings needs a driven window, which this
    /// lane does not have.
    @Test("every lane is fed live engine state, not a constant")
    func theBreakoutIsWiredToLiveState() {
        let source = Self.viewSource
        #expect(!source.isEmpty, "StemSessionsView.swift did not load, so this proves nothing")

        #expect(source.contains("LevelMeterBar(levels: engine.stemLevels[stem.id] ?? .zero)"),
                "the per-stem meter is no longer fed the engine's published levels — it will render a dead bar while audio plays")
        #expect(source.contains("LevelMeterBar(levels: engine.masterLevels)"),
                "the master meter is no longer fed the engine's published levels")
        #expect(source.contains("StudioTokens.stemColor(kind)"),
                "the lane colour is no longer derived from the stem's kind, so every part draws the same")
        #expect(source.contains("StemKindInference.kind(displayName: stem.displayName, fileName: stem.fileName)"),
                "the lane no longer classifies the stem, so its colour and badge cannot match the Studio")
        #expect(source.contains("url: stemSessionStore.audioURL(for: stem)"),
                "the lane's waveform is no longer pointed at this stem's own audio file")

        // Exactly ONE meter poller: levels arrive through the engine's
        // published properties and nothing here drains an accumulator itself.
        // Comment lines are stripped first — this file's own doc comments talk
        // ABOUT `StemLevelAccumulator.read()`, and a net that a comment can
        // trip is a net that gets deleted.
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains(".read()"),
                "the view drains a level accumulator itself — a second poller steals half of everyone's peaks")
        #expect(!code.contains("StemLevelAccumulator("),
                "the view built its own level accumulator instead of riding the engine's")
    }
}
