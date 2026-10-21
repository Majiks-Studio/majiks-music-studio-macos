import XCTest
import Foundation
@testable import MajiksMusicStudio

// A CENSUS OF WHAT THE PREVIEW ENGINE CAN ACTUALLY DO, and a guard that makes
// the answer impossible to change in silence.
//
// # Why this file exists
//
// `StudioEngineProtocol` has 27 requirements. TWENTY of them carry a default
// implementation in a protocol extension — `StudioReviseModel`, `StudioTakesModel`,
// `StudioExportModel` and `StudioEngineModel` between them — and every one of
// those defaults is a SOFT FAILURE: `ok: false` with a sentence, an empty list,
// a nil, or (twice) `ok: true` for a step that did nothing at all.
//
// Those defaults are right. An engine that cannot do a thing must say so rather
// than appear to succeed. What is NOT right is that a soft failure is invisible
// from inside a test:
//
//   * `MAJIKS_ENGINE=mock swift test` — gate 6, the suite every lane runs — is
//     the ONLY gate that executes Swift tests against `StudioMockEngine`.
//   * A capability the mock does not override falls through to the default and
//     answers `ok: false`. A test whose SETUP made that call then has nothing to
//     assert on, and the cheapest way out of that is an early `return` or a
//     skip. Both read as green.
//   * A lane hit exactly this: its first stems test used `addInstrumentTrack`,
//     got `ok: false`, and skipped — a green line asserting nothing. It rewrote
//     the test around the two commands the mock does implement and left the
//     warning in `StudioBrowserPanesTests`. That warning is a comment, and a
//     comment does not fail.
//
// It is not a hypothetical either. Removing the mock's `revise` override — one
// `func`, no other change — left `StudioReviseTests`'s discard test GREEN through
// a capability that had stopped existing: "the take lanes are clear" is vacuously
// true of a project where no lane was ever armed. The same mutation ALSO killed
// the XCTest runner outright — an `XCTAssertTrue(outcome.ok)` records and
// continues, and the `variants[1]` two lines later is `Index out of range` — so
// 219 of 590 cases never started and nothing named one of them; the log simply
// ends. Both are fixed there. This file is the general form.
//
// Same family as the two holes `engine/contracts/GATES.md` already records:
// real-engine tests that compiled but never ran (gate 7 exists because of that),
// and a mock that resolved track ids against its OWN id space so a real
// id-translation bug was invisible — "a mock cannot see a defect it shares."
// Here the mock does not share a defect; it shares a SILENCE.
//
// # How the census decides
//
// `BareEngine` below conforms to `StudioEngineProtocol` implementing ONLY the
// seven requirements that have no default. Its behaviour for the other twenty IS
// the default implementation, by construction, EXECUTED rather than described —
// so nothing here is a copy of a message that goes stale the day someone rewords
// it.
//
// Every row carries ONE positive predicate — a lane cleared, a clip placed, a
// list with something in it — and the census runs it against both engines:
//
//   * `BareEngine` must FAIL it, always. That is what stops a predicate that
//     really only asks "did the call return" from classifying every engine as
//     implemented.
//   * A row marked IMPLEMENTED must PASS it on a staged mock; a row marked
//     INHERITED must fail it there too, because the mock is running the same
//     default `BareEngine` is.
//
// ⚠️ The positive predicate is the load-bearing half, and the first draft of this
// file did not have it. It compared fingerprints — mock's answer vs bare's — and
// called them different-therefore-implemented. That SURVIVED deleting the mock's
// `discardRevise` override: the probe stages itself with `revise` first,
// `BareEngine` cannot stage at all, so the two answers differed for a reason that
// had nothing to do with the capability under test. Every state-dependent row was
// being decided by the staging rather than by the thing. A predicate that names
// what the capability produced cannot be satisfied by a control that did nothing.
//
// # What it does NOT do
//
// It does not make the mock more capable. Five capabilities are inherited today
// and this file records that as a FACT, with what each one costs — it does not
// paper over them. A mock that agreed with a contract it had not implemented is
// how the id-translation and parameter-name bugs stayed hidden from every gate at
// once; see `StudioCatalogSchema.swift`, which chose fidelity over convenience
// for exactly that reason.

@MainActor
final class StudioMockCapabilityCensusTests: XCTestCase {

    // MARK: - The bare engine: the defaults, executed

    /// Conforms to `StudioEngineProtocol` with the seven requirements that have
    /// NO default and nothing else. Every other member it answers is the
    /// protocol extension's default running unmodified.
    ///
    /// ⚠️ If a new requirement is added WITHOUT a default this stops compiling —
    /// which is the correct place to find out, and is why the completeness test
    /// below can trust the extension scan.
    private actor BareEngine: StudioEngineProtocol {
        func snapshot(ifNewerThan revision: UInt64?) async -> StudioProjectSnapshot? { nil }
        @discardableResult
        func send(_ command: StudioEngineCommand) async -> StudioCommandResult {
            StudioCommandResult(ok: false, message: "bare engine")
        }
        func setMetronome(enabled: Bool?, levelDB: Double?, countInBeats: Int?) async {}
        @discardableResult func undo() async -> Bool { false }
        @discardableResult func redo() async -> Bool { false }
        func waveformTile(_ key: StudioTileKey) async -> StudioWaveformTile? { nil }
        @discardableResult
        func openInStudio(_ request: StudioLandingRequest) async -> StudioCommandResult {
            StudioCommandResult(ok: false, message: "bare engine")
        }
    }

    // MARK: - The census

    private enum Verdict: String {
        /// `StudioMockEngine` overrides it: gate 6 exercises real behaviour.
        case implemented
        /// `StudioMockEngine` does not override it: gate 6 sees the protocol
        /// extension's soft failure, and any test that needs it is fictional
        /// unless it asserts the REFUSAL.
        case inheritedDefault
    }

    private struct Row {
        let name: String
        let verdict: Verdict
        /// Why this is acceptable (inherited) or what it buys (implemented).
        /// Prose, so a change of verdict forces a change of sentence.
        let note: String
        /// DID THE CAPABILITY DO ITS WORK? A positive fact about what the engine
        /// produced, never "the call returned". Must be false on `BareEngine`.
        let did: @Sendable (any StudioEngineProtocol, Stage) async -> Bool
    }

    /// Ids captured from a staged mock, so a probe can name a real clip, track
    /// or take. Without this every probe would degenerate into asking about an
    /// id no engine has, and two refusals compare equal.
    private struct Stage: Sendable {
        var trackID: UUID
        var clipID: UUID
        var clipStart: Int64
        var clipEnd: Int64
        var stem: StudioStemKind
        var takeID: String
        var layerTrackID: String
        var extendTakeID: String
    }

    private static let census: [Row] = [

        // MARK: Inherited — gate 6 cannot exercise these at all

        Row(name: "addInstrumentTrack", verdict: .inheritedDefault,
            note: """
            THE ONE THAT COST SOMETHING. Under gate 6 there is no way to create a \
            MIDI clip at all, so nothing about instrument-track creation is \
            provable there. `RealStudioNoteEngine` composes track.add + device.add \
            + clip.placeMidi and gate 7 is the only gate that runs it. The mock \
            implements `clip.placeMidi` nowhere — not as a typed case and not as a \
            catalog arm — so implementing this here would mean writing MIDI-clip \
            placement semantics that nothing can check against the engine: the \
            mock agreeing with a contract it had not implemented. The refusal is \
            asserted instead, in StudioInstrumentRefusalTests.
            """,
            did: { engine, _ in
                let o = await engine.addInstrumentTrack(name: "Keys", lengthTicks: 3840 * 4)
                return o.ok && o.trackID != nil && o.clipID != nil
            }),

        Row(name: "exportAudio", verdict: .inheritedDefault,
            note: """
            Bouncing needs a renderer and the preview engine is SILENT BY \
            DEFINITION — no audio framework imports, no output, ever. Gate 6 can \
            prove the export dialog and the provenance preview, both of which read \
            the snapshot, and nothing about the bounce itself.
            """,
            did: { engine, _ in
                let o = await engine.exportAudio(StudioExportRequest(
                    scope: .master, format: .wav, loudness: .none,
                    includeManifest: false, outputPath: "/tmp/majiks-census.wav"))
                return o.ok && o.outputPath != nil
            }),

        Row(name: "writeManifest", verdict: .inheritedDefault,
            note: """
            The AI-disclosure manifest is written from the engine's own journal, \
            which the preview engine does not keep on disk. Its CONTENT is \
            provable under gate 6 through StudioProvenancePreview, which is \
            computed from the snapshot; the write is not.
            """,
            did: { engine, _ in
                let o = await engine.writeManifest(outputPath: "/tmp/majiks-census.json")
                return o.ok && o.outputPath != nil
            }),

        Row(name: "publishToMajiks", verdict: .inheritedDefault,
            note: """
            Publishing uploads a bounce that does not exist on this engine, so \
            there is nothing here a preview engine could honestly do. Nothing in \
            gate 6 reaches the publisher path.
            """,
            did: { engine, _ in
                await engine.publishToMajiks(StudioPublishRequest(title: "Census")).ok
            }),

        Row(name: "finalizeRevise", verdict: .inheritedDefault,
            note: """
            THIS ROW USED TO RECORD THE DANGEROUS SHAPE AND IT IS NOW FIXED: the \
            default returned `ok: TRUE` for a full-quality re-render it never ran, \
            alone among the inherited defaults in saying yes. \
            `StudioViewModel.commitAudition` reads `swap.ok` and re-adopts on true, \
            so the background swap "succeeded" having done nothing, and any \
            assertion on this call's `ok` would have been equally true of an engine \
            that had deleted the feature. `StudioReviseModel` now refuses with a \
            sentence. A preview engine has no commit rung to swap to, so the \
            capability stays absent under gate 6 — only gate 7 reaches the real \
            two-phase finalize — but it no longer LIES about it.
            """,
            did: { engine, stage in
                // Both halves are kept deliberately. `r.ok` alone would now be a
                // valid discriminator, and that is exactly why it is not enough:
                // should the default ever drift back to `ok: true, message: nil`,
                // the `message != nil` half still fails on the bare engine and
                // this row keeps working. A predicate that only holds while the
                // current default happens to say no is a predicate that stops
                // policing the moment the defect returns.
                let r = await engine.finalizeRevise(draftTakeIDs: [stage.takeID])
                return r.ok && r.message != nil
            }),

        // MARK: Implemented — gate 6 exercises real behaviour

        Row(name: "importAudio", verdict: .implemented,
            note: """
            The mock decodes nothing but really places a clip, so the arrangement's \
            import path — new track vs named track, start ticks, the adoption that \
            follows — is exercised end to end under gate 6 (StudioImportTests).
            """,
            did: { engine, stage in
                await engine.importAudio(
                    path: "/tmp/majiks-census.wav", trackID: stage.trackID, startTicks: 0).ok
            }),

        Row(name: "bindSamples", verdict: .implemented,
            note: """
            Sampler and drum-rack zone binding is real in the mock — it creates the \
            device, removes the named zones and adds the new ones inside one undo \
            unit — so the sounds browser's whole gesture, including its atomicity, \
            is provable under gate 6.
            """,
            did: { engine, stage in
                let o = await engine.bindSamples(StudioSampleBindRequest(
                    trackID: stage.trackID, deviceID: nil, kind: "sampler",
                    bindings: [StudioSampleBinding(
                        sourcePath: "/tmp/majiks-census.wav",
                        rootPitch: 60, loPitch: 48, hiPitch: 72)],
                    reason: "census"))
                return o.ok && o.createdDevice && o.zoneIDs.count == 1
            }),

        Row(name: "revise", verdict: .implemented,
            note: """
            Variants, take lanes on the scoped tracks and joined lineage all \
            materialise, so the audition flow is real under gate 6 rather than \
            mimed. This is the capability whose removal left a discard test green \
            while proving nothing.
            """,
            did: { engine, stage in
                let o = await engine.revise(StudioReviseRequest(
                    clipIDs: [stage.clipID], regionStartTicks: stage.clipStart,
                    regionEndTicks: stage.clipEnd, scope: [stage.stem], allStems: false,
                    instruction: "census", variants: 3, keepLyrics: false,
                    crossfadeMs: 20, seed: 7))
                let armed = await engine.snapshot(ifNewerThan: nil)?.tracks
                    .first { $0.clips.contains { $0.id == stage.clipID } }?
                    .takeLane != nil
                return o.ok && o.variants.count == 3 && armed
            }),

        Row(name: "commitRevise", verdict: .implemented,
            note: """
            Commit folds the take into the clip — the clip reads generated, the \
            take lane clears, the take record becomes promoted lineage — and the \
            mock does all three, so the commit half is asserted on state and not \
            on a return value.
            """,
            did: { engine, stage in
                let r = await engine.commitRevise(
                    [StudioPromotion(takeID: stage.takeID, clipID: stage.clipID, stem: stage.stem)],
                    reason: "census")
                let folded = await engine.snapshot(ifNewerThan: nil)?
                    .tracks.flatMap(\.clips).first { $0.id == stage.clipID }?.generative ?? false
                return r.ok && folded
            }),

        Row(name: "discardRevise", verdict: .implemented,
            note: """
            ⚠️ ASSERTED BY SIDE EFFECT, and that is not fussiness: the mock's \
            discard returns `ok: true, message: nil` and so does the default, so \
            the two are INDISTINGUISHABLE through the result. This probe stages a \
            revise (which arms take lanes), discards, and requires the lanes to \
            have been armed AND to be gone. A default that did nothing leaves them \
            armed. This is the row the fingerprint draft of this file missed.
            """,
            did: { engine, stage in
                // ⚠️ Scoped to the STAGED CLIP'S track, not "any track with a
                // lane". `StudioMockEngine.revise` starts by clearing the set of
                // tracks it is tracking, so the layer track `stagedMock` prepared
                // keeps a lane that no later discard is responsible for. A probe
                // that looked project-wide read that orphan as "discard did not
                // work" and failed on correct code.
                func armed() async -> Bool {
                    await engine.snapshot(ifNewerThan: nil)?.tracks
                        .first { $0.clips.contains { $0.id == stage.clipID } }?
                        .takeLane != nil
                }
                _ = await engine.revise(StudioReviseRequest(
                    clipIDs: [stage.clipID], regionStartTicks: stage.clipStart,
                    regionEndTicks: stage.clipEnd, scope: [stage.stem], allStems: false,
                    instruction: "census", variants: 2, keepLyrics: false,
                    crossfadeMs: 20, seed: 7))
                let before = await armed()
                _ = await engine.discardRevise(takeIDs: [stage.takeID])
                let after = await armed()
                return before && !after
            }),

        Row(name: "extendClip", verdict: .implemented,
            note: """
            Tail variants are produced against a REAL clip and an unknown clip is \
            refused, so Extend's audition and its validation are both provable \
            under gate 6.
            """,
            did: { engine, stage in
                let o = await engine.extendClip(
                    clipID: stage.clipID, addedSeconds: 4, instruction: "census", variants: 2)
                let refusedNonsense = await engine.extendClip(
                    clipID: UUID(), addedSeconds: 4, instruction: "census", variants: 2)
                return o.ok && o.takes.count == 2 && !refusedNonsense.ok
            }),

        Row(name: "commitExtend", verdict: .implemented,
            note: """
            The mock really inserts the tail clip after its anchor and grows the \
            project length to fit, so the seam and the arrangement's new end are \
            provable rather than assumed.
            """,
            did: { engine, stage in
                let before = await engine.snapshot(ifNewerThan: nil)?
                    .tracks.flatMap(\.clips).count ?? 0
                let r = await engine.commitExtend(takeID: stage.extendTakeID, clipID: stage.clipID)
                let after = await engine.snapshot(ifNewerThan: nil)?
                    .tracks.flatMap(\.clips).count ?? 0
                return r.ok && after == before + 1
            }),

        Row(name: "addLayer", verdict: .implemented,
            note: """
            A prepared track with a take lane really appears in the project, so \
            Add-a-Layer's staging — and the track-count change the arrangement \
            has to absorb — is provable under gate 6.
            """,
            did: { engine, _ in
                let before = await engine.snapshot(ifNewerThan: nil)?.tracks.count ?? 0
                let o = await engine.addLayer(
                    instruction: "census", regionStartTicks: 0, regionEndTicks: 3840 * 2,
                    contextClipID: nil, stem: .other, variants: 2)
                let after = await engine.snapshot(ifNewerThan: nil)?.tracks.count ?? 0
                return o.ok && o.takes.count == 2 && o.targetTrackID != nil && after == before + 1
            }),

        Row(name: "commitLayer", verdict: .implemented,
            note: """
            The layer's clip lands ON the prepared track and its lane clears, so \
            the commit half is asserted where the user would see it instead of on \
            an `ok` flag.
            """,
            did: { engine, stage in
                let r = await engine.commitLayer(
                    takeID: "census", targetTrackID: stage.layerTrackID, regionStartTicks: 0)
                let placed = await engine.snapshot(ifNewerThan: nil)?
                    .tracks.first { $0.id.uuidString == stage.layerTrackID }?
                    .clips.isEmpty == false
                return r.ok && placed == true
            }),

        Row(name: "takes", verdict: .implemented,
            note: """
            The browser reads a real list with real joined lineage — prompt, seed, \
            model, region — so its filters are exercised against data the engine \
            produced rather than a fixture shaped to pass them.
            """,
            did: { engine, _ in
                let items = await engine.takes(query: StudioTakesQuery())
                return !items.isEmpty && items.allSatisfy { $0.lineage != nil }
            }),

        Row(name: "auditionMix", verdict: .implemented,
            note: """
            ⚠️ Its default is `ok: true, message: nil` — the shape finalizeRevise \
            has just been taken OUT of, and the last one still in it. So the \
            predicate asks about a take that does NOT exist: the mock refuses an \
            unknown take, the default says yes to everything. The capability being \
            asserted here is the VALIDATION — a preview engine that is silent by \
            definition has nothing else to offer, and "it answered" would be true \
            of the default too. It stays because auditioning nothing IS a no-op; \
            re-rendering nothing was not.
            """,
            did: { engine, stage in
                let real = await engine.auditionMix(takeID: stage.takeID, stems: ["vocals"])
                let nonsense = await engine.auditionMix(takeID: "no-such-take", stems: ["vocals"])
                return real.ok && !nonsense.ok
            }),

        Row(name: "purgeTakes", verdict: .implemented,
            note: """
            Purge really flips candidates offline and KEEPS the record as lineage, \
            which is the whole distinction the feature exists to make, so the \
            reclaim/lineage split is provable under gate 6.
            """,
            did: { engine, _ in
                let r = await engine.purgeTakes(scope: .all)
                let survived = await engine.takes(query: StudioTakesQuery())
                return r.ok && r.purgedCount > 0 && !survived.isEmpty
            }),

        Row(name: "placeTake", verdict: .implemented,
            note: """
            Drag-to-timeline promotes into the dropped-on clip, and the mock \
            validates BOTH the take and the clip, so a drop on empty space is \
            refused for the reason the real engine refuses it.
            """,
            did: { engine, stage in
                let r = await engine.placeTake(takeID: stage.takeID, ontoClipID: stage.clipID)
                let offTarget = await engine.placeTake(takeID: stage.takeID, ontoClipID: UUID())
                return r.ok && !offTarget.ok
            }),

        Row(name: "routingTrackID", verdict: .implemented,
            note: """
            ⚠️ Implemented, and the one capability here whose FIDELITY gate 6 \
            cannot check: the mock answers `t<n>` by POSITION while the real \
            engine answers its own minted id. That is the id-space conflation \
            GATES.md records, and gate 7 is the only gate that can see it. This \
            row asserts the map exists and rejects an unknown track; it makes no \
            claim about the shape of the id.
            """,
            did: { engine, stage in
                let known = await engine.routingTrackID(stage.trackID)
                let unknown = await engine.routingTrackID(UUID())
                return known != nil && unknown == nil
            }),

        Row(name: "routingState", verdict: .implemented,
            note: """
            The routing DAG and every insert chain are real in the mock and really \
            reverse, so undo over a routing edit is provable under gate 6 — which \
            a surface tested against an engine that only said "ok" could never be.
            """,
            did: { engine, _ in
                await engine.routingState() != nil
            }),
    ]

    // MARK: - Staging

    /// A mock staged far enough that every probe has something real to name: a
    /// track with a clip, a landed take, a prepared layer track and an extend
    /// take. Fresh per row, because the probes mutate.
    private func stagedMock() async throws -> (StudioMockEngine, Stage) {
        let engine = StudioMockEngine()
        let snapOrNil = await engine.snapshot(ifNewerThan: nil)
        let snap = try XCTUnwrap(snapOrNil,
                                 "the mock produced no project, so nothing below can be staged")
        let track = try XCTUnwrap(snap.tracks.first(where: { !$0.clips.isEmpty }),
                                  "the mock's synthetic project has no clip to stage from")
        let clip = try XCTUnwrap(track.clips.first)

        let revised = await engine.revise(StudioReviseRequest(
            clipIDs: [clip.id], regionStartTicks: clip.startTicks, regionEndTicks: clip.endTicks,
            scope: [track.kind], allStems: false, instruction: "stage", variants: 2,
            keepLyrics: false, crossfadeMs: 20, seed: 1))
        XCTAssertTrue(revised.ok, "staging needs a landed take: \(revised.message ?? "no message")")
        let takeID = try XCTUnwrap(revised.variants.first?.promotions.first?.takeID,
                                   "staging landed no take, so every probe below would be asking about an id that does not exist")

        let layer = await engine.addLayer(
            instruction: "stage", regionStartTicks: 0, regionEndTicks: 3840 * 2,
            contextClipID: nil, stem: .other, variants: 1)
        let layerTrackID = try XCTUnwrap(layer.targetTrackID, "staging needs a prepared layer track")

        let extended = await engine.extendClip(
            clipID: clip.id, addedSeconds: 2, instruction: "stage", variants: 1)
        let extendTakeID = try XCTUnwrap(extended.takes.first?.takeID, "staging needs a tail take")

        return (engine, Stage(
            trackID: track.id, clipID: clip.id,
            clipStart: clip.startTicks, clipEnd: clip.endTicks, stem: track.kind,
            takeID: takeID, layerTrackID: layerTrackID, extendTakeID: extendTakeID))
    }

    // MARK: - 1. The census itself

    /// THE GUARD. Every defaulted capability is classified by RUNNING it, and the
    /// verdict must match the table.
    ///
    /// Delete any `func` from `StudioMockEngine` that the table calls
    /// `implemented` and this fails BY NAME, saying which capability went silent
    /// — which is the point: this class of defect arrives as a capability quietly
    /// stopping, not as a test quietly changing.
    func testEveryDefaultedCapabilityIsClassifiedByWhatItActuallyDoes() async throws {
        let bare = BareEngine()
        var seen: Set<String> = []

        for row in Self.census {
            XCTAssertTrue(seen.insert(row.name).inserted, "\(row.name) is listed twice in the census")

            // A FRESH staged mock per row: the probes mutate (commit folds a clip
            // in, purge flips candidates offline), and a shared engine would make
            // the verdicts depend on table order.
            let (mock, stage) = try await stagedMock()
            let mockDidIt = await row.did(mock, stage)

            // The control, and it is not decoration: a predicate the DEFAULT can
            // satisfy classifies everything as implemented, including a mock with
            // the override deleted. `BareEngine` cannot stage, so this rejects any
            // predicate that is really asking "did the call return".
            let defaultDidIt = await row.did(bare, stage)
            XCTAssertFalse(
                defaultDidIt,
                """
                `\(row.name)`'s census predicate is satisfied by the protocol extension's \
                DEFAULT, which does nothing. It therefore classifies every engine as \
                implemented and cannot detect the capability going away. Assert what the \
                capability PRODUCED — a clip placed, a lane cleared, a list with something \
                in it — not that the call returned.
                """)

            switch row.verdict {
            case .implemented:
                XCTAssertTrue(
                    mockDidIt,
                    """
                    `\(row.name)` is recorded as implemented by StudioMockEngine and it no \
                    longer does the work. Either the override was removed — in which case \
                    the protocol extension's soft failure is now what gate 6 sees, and every \
                    test that leans on this capability is asserting against an engine that \
                    stopped doing it — or the behaviour changed and the row must say so. \
                    What it was for: \(row.note)
                    """)
            case .inheritedDefault:
                XCTAssertFalse(
                    mockDidIt,
                    """
                    `\(row.name)` is recorded as NOT implemented by StudioMockEngine and it \
                    now does the work. If the mock genuinely gained the capability that is \
                    good news and this row moves to `.implemented` — but read \
                    `StudioCatalogSchema.swift` first: a mock that is MORE capable than the \
                    engine, or capable in a different SHAPE, is how the id-translation and \
                    parameter-name bugs stayed hidden from every gate at once. Why it was \
                    absent: \(row.note)
                    """)
            }
        }

        // `Executed 0` has passed on this repo before, and a `for` over an empty
        // table is the same shape one level up.
        XCTAssertEqual(seen.count, Self.census.count)
        XCTAssertGreaterThan(seen.count, 15, "the census stopped covering the protocol")
    }

    /// The five that are absent today, stated as a set rather than left to be
    /// counted off the table by eye.
    ///
    /// GROWING this is a decision: one more capability gate 6 cannot exercise,
    /// and the row's note has to say what that costs. SHRINKING it means the mock
    /// gained something, and the same note has to say why the mock can be
    /// faithful there.
    func testTheCapabilitiesGate6CannotExerciseAreTheFiveThatAreKnown() {
        let absent = Self.census.filter { $0.verdict == .inheritedDefault }.map(\.name).sorted()
        XCTAssertEqual(
            absent,
            ["addInstrumentTrack", "exportAudio", "finalizeRevise", "publishToMajiks", "writeManifest"],
            "the set of capabilities `MAJIKS_ENGINE=mock swift test` cannot exercise has changed")
    }

    /// Every row carries its OWN sentence about what its verdict costs. A row
    /// added with an empty note is a row nobody had to think about, and a row
    /// added with the note above it copied is the same thing with more words —
    /// which is why this asserts DISTINCTNESS and not just length. A `contains`
    /// check for some approved phrase would be true of every row in the file the
    /// moment one row had it.
    func testEveryCensusRowSaysWhatItsVerdictCostsInItsOwnWords() {
        for row in Self.census {
            XCTAssertGreaterThan(
                row.note.count, 60,
                "\(row.name)'s census note is \(row.note.count) characters; say what the verdict costs")
        }
        let notes = Self.census.map(\.note)
        XCTAssertEqual(
            Set(notes).count, notes.count,
            "two census rows carry the same note, so at least one of them was filled in rather than thought about")
    }

    // MARK: - 1b. Which defaults still SAY YES

    /// Every defaulted requirement that answers a `StudioCommandResult`, run on
    /// `BareEngine` — the defaults executing, not described.
    ///
    /// The list is written out because it cannot be derived: `defaultedRequirements()`
    /// reads names off the source, and a name cannot be called. The completeness
    /// assertion below ties it back to that scan so a probe for something that
    /// stopped being defaulted is caught.
    private static let commandResultDefaults:
        [(String, @Sendable (any StudioEngineProtocol) async -> StudioCommandResult)] = [
        ("commitRevise",    { await $0.commitRevise([], reason: "census") }),
        ("finalizeRevise",  { await $0.finalizeRevise(draftTakeIDs: ["census"]) }),
        ("discardRevise",   { await $0.discardRevise(takeIDs: ["census"]) }),
        ("commitExtend",    { await $0.commitExtend(takeID: "census", clipID: UUID()) }),
        ("commitLayer",     { await $0.commitLayer(takeID: "census", targetTrackID: "census",
                                                   regionStartTicks: 0) }),
        ("auditionMix",     { await $0.auditionMix(takeID: "census", stems: []) }),
        ("placeTake",       { await $0.placeTake(takeID: "census", ontoClipID: UUID()) }),
        ("publishToMajiks", { await $0.publishToMajiks(StudioPublishRequest(title: "Census")) }),
        ("importAudio",     { await $0.importAudio(path: "/tmp/census.wav", trackID: nil,
                                                   startTicks: 0) }),
    ]

    /// THE GAP THE CENSUS ITSELF CANNOT SEE, and it is worth saying why.
    ///
    /// Every census predicate above is written so a soft-failing default fails
    /// it. That is right for classification and blind in one direction: a
    /// default that flips from `ok: false` to `ok: TRUE` still fails those
    /// predicates, so the row stays green while the engine starts claiming
    /// success for work it did not do. `finalizeRevise` sat in exactly that
    /// blind spot — `StudioCommandResult(ok: true, message: nil)`, read by
    /// `StudioViewModel.commitAudition` as a completed background re-render —
    /// and the row above could only warn about it in prose.
    ///
    /// So the set of defaults that answer YES is pinned by name. Two remain, and
    /// both are genuine no-ops rather than unperformed work:
    ///
    ///   * `discardRevise` — throwing away takes an engine never made is done
    ///     the moment it is asked.
    ///   * `auditionMix` — a preview engine is silent by definition, so there is
    ///     no mix to solo and nothing was skipped.
    ///
    /// Anything else joining them is a capability reporting success it did not
    /// earn, and it fails here BY NAME.
    func testTheOnlyDefaultsThatAnswerYesAreTheTwoThatAreRealNoOps() async {
        let bare = BareEngine()
        var claiming: [String] = []
        for (name, probe) in Self.commandResultDefaults where await probe(bare).ok {
            claiming.append(name)
        }
        XCTAssertEqual(
            claiming.sorted(),
            ["auditionMix", "discardRevise"],
            """
            The set of protocol-extension defaults that answer `ok: true` has changed. \
            A default that reports success for work it did not perform is the defect this \
            file was written for: the caller cannot tell it apart from an engine that did \
            the work, and no assertion on `ok` can either. Either the capability became a \
            real no-op — say so in its census note — or it should refuse with a sentence, \
            the way `finalizeRevise` and every other inherited default now do.
            """)
    }

    /// The probe list is hand-written, so tie it back to the source scan: a
    /// requirement that stopped being defaulted, or was renamed, must not sit
    /// here quietly probing an override.
    func testEveryCommandResultProbeIsStillADefaultedRequirement() throws {
        let defaulted = try defaultedRequirements()
        let probed = Set(Self.commandResultDefaults.map(\.0))
        XCTAssertTrue(
            probed.subtracting(defaulted).isEmpty,
            "\(probed.subtracting(defaulted).sorted()) are probed as defaults but no longer carry one")
        XCTAssertGreaterThan(probed.count, 5, "the yes/no probe list stopped covering the protocol")
    }

    // MARK: - 2. Completeness: a new soft default cannot arrive uncensused

    private static let sourcesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../Sources")
        .standardizedFileURL

    /// Every `func` declared in an `extension StudioEngineProtocol` block
    /// anywhere under Sources — i.e. every requirement that can be inherited
    /// silently.
    ///
    /// Read off the SOURCE rather than off a list in this file, because a list in
    /// this file is the thing that goes stale. Four extension blocks in four
    /// files carry these today and nothing stops a fifth.
    private func defaultedRequirements() throws -> Set<String> {
        let fm = FileManager.default
        let enumerator = try XCTUnwrap(
            fm.enumerator(at: Self.sourcesDirectory, includingPropertiesForKeys: nil),
            "cannot enumerate \(Self.sourcesDirectory.path)")
        var found: Set<String> = []
        var blocks = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            var cursor = text.startIndex
            while let hit = text.range(of: "extension StudioEngineProtocol", range: cursor..<text.endIndex) {
                guard let open = text[hit.upperBound...].firstIndex(of: "{") else { break }
                var depth = 0
                var i = open
                var close = open
                while i < text.endIndex {
                    if text[i] == "{" { depth += 1 }
                    if text[i] == "}" {
                        depth -= 1
                        if depth == 0 { close = i; break }
                    }
                    i = text.index(after: i)
                }
                blocks += 1
                for line in text[open...close].split(separator: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("func ") else { continue }
                    let name = t.dropFirst("func ".count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    if !name.isEmpty { found.insert(String(name)) }
                }
                cursor = close
            }
        }
        // A scanner that found no blocks would report "nothing is defaulted" and
        // the comparison below would pass against an empty census. That is the
        // `running 0 tests ... ok` shape, and it is refused here.
        XCTAssertGreaterThanOrEqual(
            blocks, 4,
            "found \(blocks) `extension StudioEngineProtocol` blocks under Sources; the scan is not reading the files it thinks it is")
        return found
    }

    /// THE OTHER HALF OF THE GUARD. Add a requirement with a soft default and
    /// forget to implement it in the mock, and gate 6 silently loses another
    /// capability — unless this fails first.
    func testTheCensusCoversEveryRequirementThatCanBeInheritedSilently() throws {
        let defaulted = try defaultedRequirements()
        let censused = Set(Self.census.map(\.name))

        XCTAssertTrue(
            defaulted.subtracting(censused).isEmpty,
            """
            \(defaulted.subtracting(censused).sorted()) have a default implementation in an \
            `extension StudioEngineProtocol` and no census row. A defaulted requirement is one \
            `StudioMockEngine` can stop implementing without any gate noticing — decide whether \
            the mock implements it, add the row, and say in its note what gate 6 can and cannot \
            prove about it.
            """)
        XCTAssertTrue(
            censused.subtracting(defaulted).isEmpty,
            """
            \(censused.subtracting(defaulted).sorted()) are censused but no longer carry a \
            default. If the requirement became mandatory the compiler now enforces it and the \
            row is dead weight; if it moved, follow it.
            """)
    }
}
