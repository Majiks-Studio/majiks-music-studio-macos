import Foundation

// MARK: - Splitting a song into its parts, from where a person actually looks
//
// WHY THIS FILE EXISTS.
//
//   "We don't have the ability to break out an audio file to different stems?
//    I don't see that option in the stems section"
//
// Separation worked the whole time. htdemucs runs, it produces real vocals,
// drums, bass and other, and the owner's own master had been split with it an
// hour before he asked that question. What did not exist was a way to ASK for
// it from anywhere a person would look:
//
//   * the Stems tab — the place he looked — could not separate anything. Its
//     empty state said so out loud: "Create one here, or extract stems in the
//     Studio and open them as a session." A pane that tells you to go somewhere
//     else is the same defect as a missing feature, one apology louder.
//   * the one working button lived in the Create tab's export menu and only
//     ever acted on a variant you had just GENERATED. A song already in the
//     Library could not be separated at all.
//
// So the separation half and the "what do I do with four files" half are lifted
// out of that one button into named functions here, and every entry point calls
// THESE. That is the shape `StemSoloAction` was pulled into for the same reason:
// planning correctly and committing correctly are worth nothing if nothing
// calls both, and a join that lives in a private method on a SwiftUI view is a
// join no test can reach.
//
// ⚠️ WHAT THIS DELIBERATELY DOES NOT DO.
//
//   * It does not touch `import.audio`'s `separate` flag. That parameter is
//     declared in the catalog and implemented by nothing — `host.rs` answers
//     `ok: true`, places one ordinary clip, and names the ignored flag in the
//     result. Implementing it there would mean widening a journaled command
//     that replay has to keep accepting.
//   * It does not send `gen.separate`. That command's own catalog description
//     says it "RECORDS the request on the bus and returns; it does not itself
//     call a backend", and `ASSESSMENT-inert-controls.md` lists it as having no
//     submit site anywhere. A palette row pointed at it would be a button onto
//     nothing, which is worse than the state this lane found.
//
// The path used here is the one the app already ships and already runs:
// `export_stems` on the Python backend -> `ACEGenerator.export_stems` ->
// `python -m demucs -n htdemucs`. Real separation, real four parts.

// MARK: - What actually separates

/// The one thing a separation entry point needs: give me a song, give me back
/// its parts.
///
/// A protocol with a single method, and it exists for the REFUSAL rather than
/// for the success. Separation legitimately fails — demucs is not installed
/// until the first run downloads it, and the interpreter a GUI-launched app
/// inherits has no torch — and until this lane there was no way to exercise
/// that path from a test, because the only implementation was a live subprocess
/// on a 210-second song.
///
/// `AnyObject` because the only real conformer is `BackendViewModel`, which is
/// a class, and because the Studio holds one weakly-ish (see
/// `StudioViewModel.stemSeparator`) rather than owning it.
///
/// `Sendable` because the call crosses actors: the caller is on the main actor
/// and `separateIntoStems` is a nonisolated `async` method that runs a
/// subprocess for minutes. `BackendViewModel` satisfies it for free (it is a
/// `@MainActor final class`); a test double declares `@unchecked Sendable` and
/// says so.
protocol StemSeparating: AnyObject, Sendable {
    /// Split `sourceAudioPath` into parts written under `outputDir`.
    ///
    /// - Returns: part name (`"vocals"`, `"drums"`, …) -> absolute file path.
    /// - Throws: whatever refused, with ITS OWN words. Never a rewritten
    ///   summary: the interpreter's last stderr line is frequently the only
    ///   thing in the whole chain that says which package is missing.
    func separateIntoStems(sourceAudioPath: String, outputDir: String) async throws -> [String: String]
}

extension BackendViewModel: StemSeparating {
    /// The shipped separator. `export_stems` is `python -m demucs -n htdemucs`
    /// on the bundled runtime — the same four-stem separation the Gen Protocol
    /// `separate` op and the engine's `HtdemucsSeparator` both reach.
    func separateIntoStems(sourceAudioPath: String, outputDir: String) async throws -> [String: String] {
        try await exportStems(filePath: sourceAudioPath, outputDir: outputDir)
    }
}

// MARK: - Saying why it could not

/// Turns a refusal into the sentence a person reads.
///
/// ⚠️ THE OLD BEHAVIOUR WAS TO THROW THE REASON AWAY. `ProjectHeaderView`
/// matched RPC code -32001 and replaced the entire payload with the seven words
/// "Install Demucs: pip install demucs" — advice that is WRONG whenever the
/// missing package is numpy or torch (demucs does not depend on numpy and
/// imports it at load, which is the exact case `landing.rs` documents), and
/// that hides the interpreter path, which is the other half of every real
/// diagnosis on this machine.
///
/// So the separator's own message is carried verbatim and the fix is APPENDED,
/// never substituted. The engine side already reasons this way — its refusal
/// ends "landing refuses rather than hand you stems that screech when soloed"
/// and names the interpreter and the pip line — and this is the same policy on
/// the Python side of the same feature.
enum StemSeparationRefusal {

    /// Appended when the message looks like a missing-dependency refusal. Not a
    /// replacement for what the backend said, and never shown on its own.
    static let installHint =
        "The separator is not installed on the Python runtime this app is using. "
        + "It normally downloads itself the first time you separate a song; if it "
        + "cannot, install it with: python3 -m pip install demucs numpy "
        + "(demucs does not install numpy as a dependency but imports it at load)."

    /// Words that mean "the thing that separates is not there".
    private static let missingDependencyMarkers = [
        "modulenotfounderror", "no module named", "import demucs", "cannot import",
        "demucs failed", "stem export failed", "-32001",
    ]

    static func message(for error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let said = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = said.isEmpty ? "The separator refused without saying why." : said
        let lowered = body.lowercased()
        guard missingDependencyMarkers.contains(where: { lowered.contains($0) }) else {
            return body
        }
        return "\(body)\n\n\(installHint)"
    }
}

// MARK: - Four files -> one stem session

/// The parts-into-a-session half, shared by every entry point that lands in the
/// Stems tab.
enum StemSeparation {

    /// What the Stems tab calls this gesture, in one place. It is the button,
    /// the menu item, the progress line's subject and the session's provenance
    /// note, and four spellings of one verb is how a feature stops looking like
    /// one feature.
    static let verb = "Split into Stems"

    /// Mixer order, vocals first. htdemucs' four plus the two its six-stem mode
    /// adds, so a future six-stem run does not sort alphabetically into
    /// bass/drums/guitar/other/piano/vocals — which reads as a directory
    /// listing rather than as a mixer.
    static let canonicalOrder = ["vocals", "drums", "bass", "guitar", "piano", "other"]

    /// The separator's `name -> path` map as ordered, display-named inputs.
    static func orderedInputs(_ stems: [String: String]) -> [(displayName: String, url: URL)] {
        stems
            .sorted { lhs, rhs in
                let li = canonicalOrder.firstIndex(of: lhs.key.lowercased()) ?? canonicalOrder.count
                let ri = canonicalOrder.firstIndex(of: rhs.key.lowercased()) ?? canonicalOrder.count
                return li == ri ? lhs.key < rhs.key : li < ri
            }
            .map { (displayName: $0.key.capitalized, url: URL(fileURLWithPath: $0.value)) }
    }

    /// The session name for a song called `title`.
    static func sessionName(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Separated Stems" : "\(trimmed) — Stems"
    }

    /// Build the stem session. Throws what the store threw — an empty session
    /// is never created, because a session with no parts in it is the "it
    /// worked" screen for a run that produced nothing.
    @MainActor
    @discardableResult
    static func makeSession(
        from stems: [String: String],
        title: String,
        sourceTrackID: UUID?,
        generationParams: GenerationParams?,
        detail: String,
        store: StemSessionStore
    ) throws -> StemSessionDocument {
        let inputs = orderedInputs(stems)
        guard !inputs.isEmpty else { throw StemSessionStoreError.noReadableStems }
        return try store.createSession(
            name: sessionName(for: title),
            stems: inputs,
            sourceTrackId: sourceTrackID,
            generationParams: generationParams,
            originAction: StemOriginOp.actionCreatedFromExtract,
            originDetail: detail)
    }
}

// MARK: - The whole gesture, with a progress state and a refusal

/// Separate a song and land it in the Stems tab, as one observable run.
///
/// ⚠️ SEPARATION TAKES MINUTES and downloads model weights the first time, so
/// three things are non-negotiable here and all three are why this is an object
/// rather than a free function:
///
///  1. NOTHING BLOCKS. `separate` is `await`ed, so the main actor is free for
///     the whole run; the only main-actor work is publishing the status. A P0
///     on this codebase the same day was a computed property doing a blocking
///     XPC round trip per view-body pass, and a minutes-long subprocess in that
///     position would freeze the app outright.
///  2. IT IS VISIBLE. `isRunning` and `status` drive a progress line that says
///     what is happening AND that the first run is slower, because an app that
///     looks frozen for four minutes has already lost.
///  3. A REFUSAL IS SHOWN, not swallowed. `failure` holds the separator's own
///     words and is presented in an alert (not a toast — a toast that lives 2.4
///     seconds at the far corner of a 4K TV is a message nobody read).
///
/// One run at a time, and re-entry is refused rather than queued: two demucs
/// subprocesses on one machine is how a laptop stops responding.
@MainActor
final class StemSeparationRun: ObservableObject {

    @Published private(set) var isRunning = false
    /// What is happening right now, or nil. Published so a view can show it.
    @Published private(set) var status: String?
    /// Why the last run refused, or nil. Settable so a dismissed alert clears.
    @Published var failure: String?
    /// The session the last successful run produced.
    @Published private(set) var lastSessionID: UUID?

    /// The progress line. Written once because it appears in two places and it
    /// has to promise the same thing in both.
    static let runningLine =
        "Splitting the song into vocals, drums, bass and other. This takes a few "
        + "minutes for a full song, and the very first time it also downloads the "
        + "separation model. You can keep using the rest of the app."

    static let alreadyRunningRefusal =
        "A song is already being split. Separation uses the whole machine, so it runs one at a time — this one will finish first."

    /// What a surface says when there is nothing behind the button. A REAL
    /// state (the Python backend has not started, or failed to), and it has to
    /// read as "not right now" rather than as "this app cannot do that".
    static let noSeparatorReason =
        "Splitting needs the audio engine, which has not started yet. Give it a moment after launch and try again — if it keeps saying this, check Settings ▸ Models."

    /// The app-wide run, so the surface that STARTS a split and the surface
    /// that SHOWS it can be different ones.
    ///
    /// A person who splits a song from the Library is taken to the Stems tab
    /// immediately and watches it work there; without a shared object the
    /// Library would have to grow its own progress bar and its own alert for a
    /// result that belongs on another screen. Same reasoning as
    /// `ToastManager.shared` and `StudioMenuBridge.shared`: the lifetime is the
    /// process's, not one view's.
    ///
    /// Tests construct their own — sharing this one between them is how a
    /// `.serialized` suite starts depending on its own order.
    static let shared = StemSeparationRun()

    init() {}

    /// The whole thing: separate `source`, land the parts as a stem session,
    /// and bring the Stems tab forward on that session.
    ///
    /// - Returns: the new session's id, or nil if nothing landed. A nil return
    ///   ALWAYS has `failure` set — "it did nothing and said nothing" is the
    ///   state this whole lane exists to remove.
    @discardableResult
    func separateIntoSession(
        source: URL,
        title: String,
        sourceTrackID: UUID? = nil,
        using separator: StemSeparating,
        store: StemSessionStore,
        coordinator: StudioCoordinator?,
        outputRoot: URL
    ) async -> UUID? {
        guard !isRunning else {
            failure = Self.alreadyRunningRefusal
            return nil
        }
        isRunning = true
        failure = nil
        status = Self.runningLine
        defer {
            isRunning = false
            status = nil
        }

        let outputDir = outputRoot
            .appendingPathComponent("stems_\(UUID().uuidString.prefix(8))", isDirectory: true)

        let stems: [String: String]
        do {
            stems = try await separator.separateIntoStems(
                sourceAudioPath: source.path, outputDir: outputDir.path)
        } catch {
            // NOTHING HALF-LANDED: no session was created before this point, so
            // there is nothing to roll back. The person gets the reason.
            failure = StemSeparationRefusal.message(for: error)
            return nil
        }

        guard !stems.isEmpty else {
            failure = "The separator finished but produced no parts, so there is nothing to open. "
                + "Nothing was added to the Stems tab."
            return nil
        }

        do {
            let doc = try StemSeparation.makeSession(
                from: stems,
                title: title,
                sourceTrackID: sourceTrackID,
                generationParams: nil,
                detail: "Split \"\(title)\" into \(StemSeparation.orderedInputs(stems).map(\.displayName).joined(separator: ", ")) with htdemucs",
                store: store)
            lastSessionID = doc.id
            coordinator?.openStemSessions(sessionID: doc.id)
            return doc.id
        } catch {
            failure = "The song was split, but the parts could not be saved as a session: "
                + "\(error.localizedDescription)"
            return nil
        }
    }
}
