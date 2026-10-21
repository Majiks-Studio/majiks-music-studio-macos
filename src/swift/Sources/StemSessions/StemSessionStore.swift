import Foundation
import SwiftUI

/// Errors thrown by stem-session document operations.
enum StemSessionStoreError: LocalizedError {
    case sessionNotFound
    case noReadableStems

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Stem session not found."
        case .noReadableStems:
            return "None of the selected files could be added as stems."
        }
    }
}

/// Owns stem-session documents: flat-JSON persistence (stem_sessions.json,
/// atomic writes, ISO-8601 dates — same conventions as SessionStore) plus
/// UndoManager-backed mutation methods.
///
/// Ownership model: stems are COPIED into `StemSessions/<sessionID>/` when
/// added. Removing a stem removes only the document entry (the audio file is
/// kept until the whole session is deleted) so that undo of a remove never
/// depends on a file that has already been unlinked.
///
/// Undo design: every mutating op takes an optional UndoManager and registers
/// its exact inverse. Parameter ops (gain/mute/solo/master/rename) only touch
/// the document — the engine re-applies volumes from the document, so undoing
/// them never rebuilds the audio graph.
@MainActor
final class StemSessionStore: ObservableObject {
    @Published private(set) var sessions: [StemSessionDocument] = []
    /// Last persistence error, surfaced as a toast by StemSessionsView
    /// (same pattern as LibraryStore.lastSaveError).
    @Published private(set) var lastError: String?

    func clearLastError() {
        lastError = nil
    }

    /// Directory holding per-session stem audio (default: FileStore's StemSessions/).
    private let directory: URL
    /// Flat JSON index of all sessions (default: FileStore's stem_sessions.json).
    private let indexURL: URL

    /// - Parameters:
    ///   - directory: Override for tests (hermetic temp dir). Defaults to FileStore.
    ///   - indexURL: Override for tests. Defaults to FileStore.
    init(directory: URL? = nil, indexURL: URL? = nil) {
        self.directory = directory ?? FileStore.shared.stemSessionsDirectory
        self.indexURL = indexURL ?? FileStore.shared.stemSessionsURL
        load()
    }

    // MARK: - Resolution

    /// Absolute audio URL for a stem. Resolution lives on the store (not the
    /// model) so tests can run against a temp directory instead of the real
    /// Application Support tree.
    func audioURL(for stem: SessionStem) -> URL {
        directory.appendingPathComponent(stem.fileName)
    }

    func session(id: UUID) -> StemSessionDocument? {
        sessions.first { $0.id == id }
    }

    // MARK: - Persistence

    func load() {
        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([FailableDecodable<StemSessionDocument>].self, from: data)
            sessions = decoded.compactMap { $0.value }.sorted { $0.updatedAt > $1.updatedAt }
            print("[StemSessionStore] Loaded \(sessions.count) stem sessions")
        } catch {
            sessions = []
            print("[StemSessionStore] No stem sessions file found or decode error: \(error)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sessions)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            lastError = "Could not save stem sessions: \(error.localizedDescription)"
            print("[StemSessionStore] Error saving stem sessions: \(error)")
        }
    }

    // MARK: - Session Lifecycle

    /// Creates an empty stem session (not undoable — deletion is the confirmed,
    /// destructive inverse).
    @discardableResult
    func createSession(name: String) -> StemSessionDocument {
        var doc = StemSessionDocument(name: name)
        doc.originOps.append(StemOriginOp(action: StemOriginOp.actionCreated, detail: "Created \"\(name)\""))
        sessions.insert(doc, at: 0)
        save()
        print("[StemSessionStore] Created stem session: \(doc.id)")
        return doc
    }

    /// Creates a session pre-populated from external stem files (extract results,
    /// Demucs exports, arbitrary audio). Files are copied into the session
    /// directory; unreadable/uncopyable inputs are skipped.
    @discardableResult
    func createSession(
        name: String,
        stems inputs: [(displayName: String, url: URL)],
        sourceTrackId: UUID?,
        generationParams: GenerationParams?,
        originAction: String,
        originDetail: String
    ) throws -> StemSessionDocument {
        var doc = StemSessionDocument(name: name)
        doc.originOps.append(StemOriginOp(action: originAction, detail: originDetail))

        for input in inputs {
            let stemID = UUID()
            do {
                let fileName = try copyStemFile(from: input.url, sessionID: doc.id, stemID: stemID)
                let stem = SessionStem(
                    id: stemID,
                    fileName: fileName,
                    displayName: input.displayName,
                    sourceTrackId: sourceTrackId,
                    generationParams: generationParams
                )
                doc.stems.append(stem)
                doc.originOps.append(StemOriginOp(
                    action: StemOriginOp.actionAddedExtractedStem,
                    detail: "Added \"\(input.displayName)\" from \(input.url.lastPathComponent)"
                ))
            } catch {
                print("[StemSessionStore] Skipped stem \(input.url.lastPathComponent): \(error)")
            }
        }

        guard !doc.stems.isEmpty else {
            // Nothing usable — clean up the (possibly created) session directory.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(doc.id.uuidString, isDirectory: true))
            throw StemSessionStoreError.noReadableStems
        }

        sessions.insert(doc, at: 0)
        save()
        print("[StemSessionStore] Created stem session from \(doc.stems.count) stems: \(doc.id)")
        return doc
    }

    /// Renames a session (undoable).
    func renameSession(id: UUID, to newName: String, undoManager: UndoManager? = nil) {
        guard let index = sessionIndex(id) else { return }
        let oldName = sessions[index].name
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }

        registerUndo(undoManager, actionName: "Rename Session") { store in
            store.renameSession(id: id, to: oldName, undoManager: undoManager)
        }

        sessions[index].name = trimmed
        appendOp(at: index, action: StemOriginOp.actionRenamedSession, detail: "Renamed \"\(oldName)\" to \"\(trimmed)\"")
        touchAndSave(at: index)
    }

    /// Deletes a session and its audio directory. Destructive and confirmed in
    /// the UI — intentionally NOT undoable (audio files are removed from disk),
    /// matching SessionStore.deleteSession semantics.
    func deleteSession(id: UUID) {
        guard let index = sessionIndex(id) else { return }
        sessions.remove(at: index)
        save()
        let sessionDir = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        // Drop cached waveforms for the audio being deleted (the cache is
        // keyed by URL and would otherwise hold them for the process lifetime).
        WaveformData.evictCache(under: sessionDir)
        try? FileManager.default.removeItem(at: sessionDir)
        print("[StemSessionStore] Deleted stem session: \(id)")
    }

    // MARK: - Stem Ops (undoable)

    /// Adds stems from external audio files (copies them in). Undoable as one action.
    @discardableResult
    func addStems(
        fileURLs: [URL],
        to sessionID: UUID,
        sourceTrackId: UUID? = nil,
        generationParams: GenerationParams? = nil,
        undoManager: UndoManager? = nil
    ) throws -> [SessionStem] {
        guard let index = sessionIndex(sessionID) else { throw StemSessionStoreError.sessionNotFound }

        var added: [SessionStem] = []
        for url in fileURLs {
            let stemID = UUID()
            do {
                let fileName = try copyStemFile(from: url, sessionID: sessionID, stemID: stemID)
                added.append(SessionStem(
                    id: stemID,
                    fileName: fileName,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    sourceTrackId: sourceTrackId,
                    generationParams: generationParams
                ))
            } catch {
                print("[StemSessionStore] Skipped stem \(url.lastPathComponent): \(error)")
            }
        }
        guard !added.isEmpty else { throw StemSessionStoreError.noReadableStems }

        let addedIDs = added.map(\.id)
        registerUndo(undoManager, actionName: "Add Stems") { store in
            store.removeStems(ids: addedIDs, from: sessionID, undoManager: undoManager)
        }

        sessions[index].stems.append(contentsOf: added)
        for stem in added {
            appendOp(at: index, action: StemOriginOp.actionAddedFile, detail: "Added \"\(stem.displayName)\"")
        }
        touchAndSave(at: index)
        return added
    }

    /// Removes a single stem from the document (file kept on disk; undoable).
    func removeStem(id stemID: UUID, from sessionID: UUID, undoManager: UndoManager? = nil) {
        removeStems(ids: [stemID], from: sessionID, undoManager: undoManager)
    }

    /// Removes stems from the document (files kept on disk until session delete; undoable).
    func removeStems(ids stemIDs: [UUID], from sessionID: UUID, undoManager: UndoManager? = nil) {
        guard let index = sessionIndex(sessionID) else { return }
        let removed = sessions[index].stems.enumerated()
            .filter { stemIDs.contains($0.element.id) }
            .map { (offset: $0.offset, stem: $0.element) }
        guard !removed.isEmpty else { return }

        registerUndo(undoManager, actionName: removed.count == 1 ? "Remove Stem" : "Remove Stems") { store in
            store.reinsertStems(removed, into: sessionID, undoManager: undoManager)
        }

        sessions[index].stems.removeAll { stemIDs.contains($0.id) }
        for entry in removed {
            appendOp(at: index, action: StemOriginOp.actionRemovedStem, detail: "Removed \"\(entry.stem.displayName)\"")
        }
        touchAndSave(at: index)
    }

    /// Inverse of removeStems — restores stems at their original positions.
    /// Appends a compensating origin op (the log stays append-only).
    private func reinsertStems(
        _ entries: [(offset: Int, stem: SessionStem)],
        into sessionID: UUID,
        undoManager: UndoManager?
    ) {
        guard let index = sessionIndex(sessionID) else { return }

        let ids = entries.map(\.stem.id)
        registerUndo(undoManager, actionName: entries.count == 1 ? "Remove Stem" : "Remove Stems") { store in
            store.removeStems(ids: ids, from: sessionID, undoManager: undoManager)
        }

        for entry in entries.sorted(by: { $0.offset < $1.offset }) {
            let insertAt = min(entry.offset, sessions[index].stems.count)
            sessions[index].stems.insert(entry.stem, at: insertAt)
            appendOp(at: index, action: StemOriginOp.actionRestoredStem, detail: "Restored \"\(entry.stem.displayName)\" (undo)")
        }
        touchAndSave(at: index)
    }

    /// Renames a stem (undoable).
    func renameStem(id stemID: UUID, in sessionID: UUID, to newName: String, undoManager: UndoManager? = nil) {
        guard let (index, stemIndex) = stemIndex(stemID, in: sessionID) else { return }
        let oldName = sessions[index].stems[stemIndex].displayName
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }

        registerUndo(undoManager, actionName: "Rename Stem") { store in
            store.renameStem(id: stemID, in: sessionID, to: oldName, undoManager: undoManager)
        }

        sessions[index].stems[stemIndex].displayName = trimmed
        appendOp(at: index, action: StemOriginOp.actionRenamedStem, detail: "Renamed \"\(oldName)\" to \"\(trimmed)\"")
        touchAndSave(at: index)
    }

    // MARK: - Mixer Ops (undoable, parameter-only)

    /// Sets a stem's gain in dB (undoable). Reads the currently stored value as
    /// the undo baseline — slider drags must preview via the engine and commit
    /// here once on release.
    func setStemGain(id stemID: UUID, in sessionID: UUID, gainDB: Double, undoManager: UndoManager? = nil) {
        guard let (index, stemIndex) = stemIndex(stemID, in: sessionID) else { return }
        let clamped = min(max(gainDB, StemMix.minGainDB), StemMix.maxGainDB)
        let old = sessions[index].stems[stemIndex].gainDB
        guard old != clamped else { return }

        registerUndo(undoManager, actionName: "Stem Gain") { store in
            store.setStemGain(id: stemID, in: sessionID, gainDB: old, undoManager: undoManager)
        }

        sessions[index].stems[stemIndex].gainDB = clamped
        touchAndSave(at: index)
    }

    /// Sets a stem's stereo pan (−1…+1, undoable). Same contract as
    /// setStemGain: knob drags preview via the engine and commit here once on
    /// release, so the stored value is the undo baseline.
    func setStemPan(id stemID: UUID, in sessionID: UUID, pan: Double, undoManager: UndoManager? = nil) {
        guard let (index, stemIndex) = stemIndex(stemID, in: sessionID) else { return }
        let clamped = min(max(pan, StemMix.minPan), StemMix.maxPan)
        let old = sessions[index].stems[stemIndex].pan
        guard old != clamped else { return }

        registerUndo(undoManager, actionName: "Stem Pan") { store in
            store.setStemPan(id: stemID, in: sessionID, pan: old, undoManager: undoManager)
        }

        sessions[index].stems[stemIndex].pan = clamped
        touchAndSave(at: index)
    }

    /// Mutes/unmutes a stem (undoable).
    func setStemMuted(id stemID: UUID, in sessionID: UUID, muted: Bool, undoManager: UndoManager? = nil) {
        guard let (index, stemIndex) = stemIndex(stemID, in: sessionID) else { return }
        let old = sessions[index].stems[stemIndex].muted
        guard old != muted else { return }

        registerUndo(undoManager, actionName: muted ? "Mute Stem" : "Unmute Stem") { store in
            store.setStemMuted(id: stemID, in: sessionID, muted: old, undoManager: undoManager)
        }

        sessions[index].stems[stemIndex].muted = muted
        touchAndSave(at: index)
    }

    /// Solos/unsolos a stem (undoable). The solo SET derives effective mutes —
    /// see StemMix.isEffectivelyMuted.
    func setStemSolo(id stemID: UUID, in sessionID: UUID, solo: Bool, undoManager: UndoManager? = nil) {
        guard let (index, stemIndex) = stemIndex(stemID, in: sessionID) else { return }
        let old = sessions[index].stems[stemIndex].solo
        guard old != solo else { return }

        registerUndo(undoManager, actionName: solo ? "Solo Stem" : "Unsolo Stem") { store in
            store.setStemSolo(id: stemID, in: sessionID, solo: old, undoManager: undoManager)
        }

        sessions[index].stems[stemIndex].solo = solo
        touchAndSave(at: index)
    }

    /// Applies a whole solo PLAN as ONE undo step.
    ///
    /// The breakout view's Solo button is exclusive (see `StemSoloPlan`), so a
    /// single click can be four writes: solo the vocal, un-solo the other
    /// three. Routing that through `setStemSolo` four times would put four
    /// entries on the undo stack, and ⌘Z would walk back through three states
    /// the user never asked for and never saw — the "one gesture = one undo
    /// step" rule this codebase holds every mutation to.
    ///
    /// So the inverse registered here is the WHOLE prior solo set, restored in
    /// one go. `actionName` is the gesture's name ("Solo Drums"), not a
    /// description of the writes.
    func applySoloPlan(
        _ changes: [StemSoloPlan.Change],
        in sessionID: UUID,
        actionName: String,
        undoManager: UndoManager? = nil
    ) {
        guard let index = sessionIndex(sessionID), !changes.isEmpty else { return }

        // Baseline for the inverse: only the stems this plan actually CHANGES,
        // at the value they hold now. Resolved before anything is written, as
        // every other op in this file does.
        var effective: [(stemIndex: Int, solo: Bool)] = []
        var inverse: [StemSoloPlan.Change] = []
        for change in changes {
            guard let stemIdx = sessions[index].stems.firstIndex(where: { $0.id == change.id }) else { continue }
            let old = sessions[index].stems[stemIdx].solo
            guard old != change.solo else { continue }
            effective.append((stemIdx, change.solo))
            inverse.append(StemSoloPlan.Change(id: change.id, solo: old))
        }
        guard !effective.isEmpty else { return }

        registerUndo(undoManager, actionName: actionName) { store in
            store.applySoloPlan(inverse, in: sessionID, actionName: actionName, undoManager: undoManager)
        }

        for entry in effective {
            sessions[index].stems[entry.stemIndex].solo = entry.solo
        }
        touchAndSave(at: index)
    }

    /// Sets the master gain in dB (undoable).
    func setMasterGain(in sessionID: UUID, gainDB: Double, undoManager: UndoManager? = nil) {
        guard let index = sessionIndex(sessionID) else { return }
        let clamped = min(max(gainDB, StemMix.minGainDB), StemMix.maxGainDB)
        let old = sessions[index].masterGainDB
        guard old != clamped else { return }

        registerUndo(undoManager, actionName: "Master Gain") { store in
            store.setMasterGain(in: sessionID, gainDB: old, undoManager: undoManager)
        }

        sessions[index].masterGainDB = clamped
        touchAndSave(at: index)
    }

    // MARK: - Provenance

    /// Records a bounce in the session's origin log (not undoable — it happened).
    func recordBounce(sessionID: UUID, destination: URL) {
        guard let index = sessionIndex(sessionID) else { return }
        appendOp(at: index, action: StemOriginOp.actionBounced, detail: "Bounced to \(destination.lastPathComponent)")
        touchAndSave(at: index)
    }

    /// Records that a bounce was added to the Library as a track — the
    /// provenance chain continues on the track's side in extendedMetadata
    /// (not undoable — the track exists).
    func recordAddedToLibrary(sessionID: UUID, trackTitle: String) {
        guard let index = sessionIndex(sessionID) else { return }
        appendOp(at: index, action: StemOriginOp.actionAddedToLibrary, detail: "Added \"\(trackTitle)\" to Library")
        touchAndSave(at: index)
    }

    // MARK: - Helpers

    private func sessionIndex(_ id: UUID) -> Int? {
        sessions.firstIndex { $0.id == id }
    }

    private func stemIndex(_ stemID: UUID, in sessionID: UUID) -> (session: Int, stem: Int)? {
        guard let sessionIdx = sessionIndex(sessionID),
              let stemIdx = sessions[sessionIdx].stems.firstIndex(where: { $0.id == stemID }) else {
            return nil
        }
        return (sessionIdx, stemIdx)
    }

    private func appendOp(at index: Int, action: String, detail: String) {
        sessions[index].originOps.append(StemOriginOp(action: action, detail: detail))
    }

    private func touchAndSave(at index: Int) {
        sessions[index].updatedAt = Date()
        save()
    }

    /// Registers an undo op on the main actor. AppKit fires undo on the main
    /// thread, so hopping back into the actor with assumeIsolated is safe.
    private func registerUndo(
        _ undoManager: UndoManager?,
        actionName: String,
        _ handler: @escaping @MainActor (StemSessionStore) -> Void
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                handler(target)
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Copies an external audio file into the session's stem directory and
    /// returns the stored relative path ("SESSION-UUID/1a2b3c4d_name.wav").
    private func copyStemFile(from url: URL, sessionID: UUID, stemID: UUID) throws -> String {
        let sessionDir = directory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
        let safeBase = Self.sanitizedBaseName(url.deletingPathExtension().lastPathComponent)
        let fileName = "\(stemID.uuidString.prefix(8).lowercased())_\(safeBase).\(ext)"
        let destination = sessionDir.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: url, to: destination)
        return "\(sessionID.uuidString)/\(fileName)"
    }

    /// Keeps stem filenames shell/Finder-friendly (see CLAUDE.md naming rules).
    /// Pure — nonisolated so non-main-actor callers (library export) can use it.
    nonisolated static func sanitizedBaseName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = name.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
            .replacingOccurrences(of: " ", with: "_")
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = trimmed.isEmpty ? "stem" : trimmed
        return String(base.prefix(40))
    }
}
