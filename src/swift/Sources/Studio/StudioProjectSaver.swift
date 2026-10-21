import Foundation
import SwiftUI

// MARK: - Studio project saver
//
// THE DEFECT THIS EXISTS FOR
//
// `project.save` shipped in catalog v1 and had ZERO call sites in the app.
// There was no File ▸ Save, no ⌘S, no autosave, and no quit hook. A 92-note
// performance lived in RAM and `~/Library/.../Studio.mstudio/project.json` sat
// at 482 bytes with `tracks: []` and a two-week-old mtime.
//
// THE SAVE MODEL, AND WHY
//
// Aaron's words: "I don't really know how to use a DAW." So the model is
// IMPLICIT and there is no ceremony:
//
//   * ONE project. `StudioEngineFactory.defaultProjectPath()` names it and the
//     engine's `open_or_create` reopens it every launch. There is no New/Open
//     dialog to get wrong, no "do you want to save?" to answer wrong, and no
//     file to lose track of. Work just comes back.
//   * The JOURNAL is the durability mechanism, not the save button. Every
//     command is written through to `journal.jsonl` at submit time (see
//     `FileJournal::append`), so a crash, a Force Quit, or a power-off loses at
//     most the command in flight -- WITHOUT the user having pressed anything.
//   * `project.save` writes a CHECKPOINT (`project.json`) so the next open is a
//     fast checkpoint read instead of a full replay of every command ever
//     issued. That is a performance and integrity affordance, not the thing
//     that keeps the user's work alive.
//
// Because of that split, ⌘S is a REASSURANCE, not a requirement, and this class
// never blocks the user or nags:
//
//   * autosave on a 20 s idle cadence (checkpoint only when something changed);
//   * a checkpoint when the Studio tab goes to the background or the app
//     resigns active, which is when a user typically walks away;
//   * a checkpoint on quit, silently -- ⌘Q does not throw up a dialog, because
//     the honest answer to "do you want to save?" here is "it is already
//     saved". A dialog would teach a false model of a system that cannot lose
//     the work.
//
// It deliberately does NOT create the engine. `StudioEngineFactory.shared` is
// lazy and touching it opens the `.mstudio` package; a saver that forced that
// on a plain launch would undo `StudioMCPServer`'s care not to.

@MainActor
final class StudioProjectSaver: ObservableObject {

    enum Status: Equatable {
        /// Nothing to write: every command is journaled and the checkpoint is
        /// current.
        case saved(Date?)
        /// Journaled (already safe on disk) but the checkpoint is behind.
        case pendingCheckpoint
        case saving
        /// A checkpoint write failed. The journal is still the truth, so the
        /// work is NOT lost -- but the user should know the package is degraded.
        case failed(String)
    }

    static let shared = StudioProjectSaver()

    @Published private(set) var status: Status = .saved(nil)

    /// The engine revision the last successful checkpoint covered. `nil` until
    /// the first snapshot arrives, so a launch never reports "unsaved" for a
    /// project nobody has touched.
    private var checkpointedRevision: UInt64?
    private var latestRevision: UInt64?
    private var engine: (any StudioEngineProtocol)?
    private var autosaveTask: Task<Void, Never>?
    private var inFlight = false

    /// How long the session may sit dirty before a checkpoint is written.
    /// Short enough that a reopen never replays much, long enough that a drag
    /// gesture does not write a file per frame.
    static let autosaveInterval: Duration = .seconds(20)

    private init() {}

    /// True when work exists that the CHECKPOINT does not cover. Never means
    /// "work that could be lost" -- see the note above.
    var hasUncheckpointedWork: Bool {
        guard let latest = latestRevision else { return false }
        return latest != checkpointedRevision
    }

    /// Bind to the engine the Studio tab is already running on. Idempotent, and
    /// never constructs one.
    func attach(_ engine: any StudioEngineProtocol) {
        guard self.engine == nil else { return }
        self.engine = engine
        startAutosave()
    }

    /// Engine truth arrived. Called from `StudioViewModel`'s snapshot poll, so
    /// dirtiness is derived from the ENGINE's revision rather than from the UI
    /// guessing which of its own gestures mutated anything.
    func noteRevision(_ revision: UInt64) {
        latestRevision = revision
        if checkpointedRevision == nil {
            // First snapshot of the session: the package on disk already
            // reflects it (we just opened it), so this is not unsaved work.
            checkpointedRevision = revision
        }
        refreshStatus()
    }

    private func refreshStatus() {
        if inFlight { return }
        if case .failed = status { return }
        if hasUncheckpointedWork {
            status = .pendingCheckpoint
        } else if case .pendingCheckpoint = status {
            status = .saved(Date())
        }
    }

    // MARK: Saving

    /// Write a checkpoint. `force` writes even when nothing changed (⌘S should
    /// do something visible when the user asks for it).
    @discardableResult
    func save(force: Bool = false) async -> Bool {
        guard let engine else { return false }
        guard force || hasUncheckpointedWork else {
            status = .saved(Date())
            return true
        }
        guard !inFlight else { return false }
        inFlight = true
        status = .saving
        // The revision we are about to cover. Captured BEFORE the await so a
        // command that lands mid-save is not falsely marked checkpointed --
        // it will simply be picked up by the next autosave.
        let covered = latestRevision

        // Through the journaled command bus, as the catalog envelope it already
        // is. No new command, no bypass.
        let result = await engine.send(.catalog(name: "project.save", params: [:]))

        inFlight = false
        if result.ok {
            checkpointedRevision = covered
            status = .saved(Date())
            return true
        } else {
            let why = result.message ?? "the engine refused project.save"
            AppLog.error("project.save failed: \(why)")
            status = .failed(why)
            return false
        }
    }

    /// Save and WAIT, for the app-termination path where there is no later
    /// runloop turn to finish an async task in. Returns whether a checkpoint
    /// was written. Bounded so a wedged engine can never hold up a quit: the
    /// journal is already durable, so timing out here costs a slower next
    /// open, never the user's work.
    func saveSynchronouslyForQuit(timeout: TimeInterval = 3.0) -> Bool {
        guard engine != nil, hasUncheckpointedWork else { return false }
        let done = DispatchSemaphore(value: 0)
        let box = SaveOutcome()
        Task { @MainActor in
            box.ok = await self.save(force: true)
            done.signal()
        }
        // The Task above hops to the main actor, and on the termination path we
        // ARE the main thread -- so pumping the runloop (rather than blocking
        // on the semaphore) is what lets it run at all. Blocking here would
        // deadlock exactly the way `applicationShouldTerminate`'s old
        // save-and-quit path did before it moved to `.terminateLater`.
        let deadline = Date().addingTimeInterval(timeout)
        while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return box.ok
    }

    // MARK: Autosave

    private func startAutosave() {
        guard autosaveTask == nil else { return }
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autosaveInterval)
                guard let self else { return }
                // Only when there is something to checkpoint: an idle Studio
                // must not rewrite project.json every 20 seconds forever.
                if await self.hasUncheckpointedWork {
                    await self.save()
                }
            }
        }
    }

    /// The user is walking away (tab switch, app deactivate). Checkpoint now
    /// rather than waiting out the autosave interval.
    func saveOnResignActive() {
        guard hasUncheckpointedWork else { return }
        Task { await save() }
    }

    /// Return to launch state. The saver is a singleton because the
    /// app-termination path has no instance to reach otherwise, which makes it
    /// shared across tests; this is how a test gets a clean one.
    func resetForTesting() {
        autosaveTask?.cancel()
        autosaveTask = nil
        engine = nil
        checkpointedRevision = nil
        latestRevision = nil
        inFlight = false
        status = .saved(nil)
    }

    /// A failed checkpoint should not stick forever; the next successful save
    /// clears it, and so does the user retrying.
    func clearFailure() {
        if case .failed = status {
            status = hasUncheckpointedWork ? .pendingCheckpoint : .saved(nil)
        }
    }
}

/// Tiny mutable box so the quit path can read the async result. Not `Sendable`
/// gymnastics: it is only ever touched on the main actor.
@MainActor
private final class SaveOutcome {
    var ok = false
}

// MARK: - The indicator
//
// Small, quiet, and truthful. It never says "unsaved" in the scary sense,
// because the work is already on disk -- it says whether the fast-open
// checkpoint is current, and it says so in plain language for someone who does
// not know what a checkpoint is.

struct StudioSaveIndicator: View {
    @ObservedObject var saver: StudioProjectSaver

    var body: some View {
        HStack(spacing: 5) {
            icon
            // `lineLimit(1)` + `fixedSize()`, because this chip lives in the
            // transport bar and that row's own header asserts "every Text in
            // this row is lineLimit(1) + fixedSize() already". It was not: this
            // one had neither. A bare Text in a tight HStack does not truncate
            // under width pressure, it WRAPS — at the limit to one character
            // per line, which is exactly how "POSITION" became an 8-line column
            // and blew the toolbar to ~475 pt in 3.4.8.
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(helpText)
    }

    @ViewBuilder
    private var icon: some View {
        switch saver.status {
        case .saving:
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
        case .pendingCheckpoint:
            Circle().fill(Color.secondary.opacity(0.55)).frame(width: 6, height: 6)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var label: String {
        switch saver.status {
        case .saving: return "Saving…"
        case .pendingCheckpoint: return "Saving soon"
        case .failed: return "Save problem"
        case .saved: return "Saved"
        }
    }

    private var helpText: String {
        switch saver.status {
        case .saving:
            return "Writing your project to disk."
        case .pendingCheckpoint:
            return """
                Everything you have done is already written to disk. Majik's is \
                tidying the project file so it opens faster next time — it does \
                this on its own, or press ⌘S now.
                """
        case .failed(let why):
            return """
                Majik's could not tidy the project file: \(why)
                Your work is still safe — every edit was written to disk as you \
                made it. Try ⌘S, and if it keeps failing check that the disk is \
                not full.
                """
        case .saved(let when):
            guard let when else {
                return "Your project is saved. It reopens automatically next time you launch."
            }
            let f = DateFormatter()
            f.timeStyle = .short
            return "Saved at \(f.string(from: when)). It reopens automatically next time you launch."
        }
    }
}
