import Testing
import Foundation
@testable import MajiksMusicStudio

// MARK: - StemSessionStore Tests (hermetic: temp directory, no FileStore)

@MainActor
@Suite("StemSessionStore", .serialized)
struct StemSessionStoreTests {

    /// Creates a store rooted in a unique temp directory plus two fake stem
    /// source files (the store only copies files — it never decodes audio).
    private func makeStore() throws -> (store: StemSessionStore, root: URL, sourceA: URL, sourceB: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        let stemsDir = root.appendingPathComponent("StemSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: stemsDir, withIntermediateDirectories: true)

        let sourceA = root.appendingPathComponent("vocals take 1.wav")
        let sourceB = root.appendingPathComponent("drums.wav")
        try Data("fake-audio-a".utf8).write(to: sourceA)
        try Data("fake-audio-b".utf8).write(to: sourceB)

        let store = StemSessionStore(
            directory: stemsDir,
            indexURL: root.appendingPathComponent("stem_sessions.json")
        )
        return (store, root, sourceA, sourceB)
    }

    /// UndoManager without a run loop: manage groups explicitly so each op is
    /// its own undoable step (matching one-op-per-event behavior in the app).
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

    // MARK: Persistence

    @Test("create, persist, and reload from disk")
    func persistenceRoundTrip() throws {
        let (store, root, sourceA, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let doc = store.createSession(name: "Persisted")
        _ = try store.addStems(fileURLs: [sourceA], to: doc.id)
        store.setMasterGain(in: doc.id, gainDB: -3)

        // A second store instance reading the same index sees the same state.
        let reloaded = StemSessionStore(
            directory: root.appendingPathComponent("StemSessions", isDirectory: true),
            indexURL: root.appendingPathComponent("stem_sessions.json")
        )
        let loadedDoc = reloaded.session(id: doc.id)
        #expect(loadedDoc != nil)
        #expect(loadedDoc?.name == "Persisted")
        #expect(loadedDoc?.stems.count == 1)
        #expect(loadedDoc?.masterGainDB == -3)
        // The copied stem audio actually exists where the document points.
        if let stem = loadedDoc?.stems.first {
            #expect(FileManager.default.fileExists(atPath: reloaded.audioURL(for: stem).path))
        }
    }

    @Test("createSession(from stems:) copies files and seeds provenance")
    func createFromExtractedStems() throws {
        let (store, root, sourceA, sourceB) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceTrackId = UUID()
        var params = MusicParameters()
        params.generationMode = .extract
        params.extractStems = ["vocals"]

        let doc = try store.createSession(
            name: "From Extract",
            stems: [("Vocals", sourceA), ("Drums", sourceB)],
            sourceTrackId: sourceTrackId,
            generationParams: params.toGenerationParams(),
            originAction: StemOriginOp.actionCreatedFromExtract,
            originDetail: "Extracted vocals from \"Song\""
        )

        #expect(doc.stems.count == 2)
        #expect(doc.stems.allSatisfy { $0.sourceTrackId == sourceTrackId })
        #expect(doc.stems.allSatisfy { $0.generationParams != nil })
        #expect(doc.originOps.first?.action == StemOriginOp.actionCreatedFromExtract)
        for stem in doc.stems {
            #expect(FileManager.default.fileExists(atPath: store.audioURL(for: stem).path))
        }
        // Filenames are sanitized (no spaces) and namespaced by session ID.
        #expect(doc.stems[0].fileName.hasPrefix("\(doc.id.uuidString)/"))
        #expect(!doc.stems[0].fileName.contains(" "))
    }

    @Test("deleting a session removes its audio directory")
    func deleteRemovesAudio() throws {
        let (store, root, sourceA, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let doc = store.createSession(name: "Doomed")
        _ = try store.addStems(fileURLs: [sourceA], to: doc.id)
        let sessionDir = root
            .appendingPathComponent("StemSessions", isDirectory: true)
            .appendingPathComponent(doc.id.uuidString, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: sessionDir.path))

        store.deleteSession(id: doc.id)
        #expect(store.session(id: doc.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: sessionDir.path))
    }

    // MARK: Undo / Redo

    @Test("undo/redo across gain, mute, solo, rename, master, add, and remove")
    func undoRedoAcrossOps() throws {
        let (store, root, sourceA, sourceB) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let um = makeUndoManager()

        let doc = store.createSession(name: "Undo Lab")
        let id = doc.id

        // Op 1: add two stems.
        perform(um) { _ = try? store.addStems(fileURLs: [sourceA, sourceB], to: id, undoManager: um) }
        let stems = try #require(store.session(id: id)?.stems)
        #expect(stems.count == 2)
        let stemA = stems[0].id
        let stemB = stems[1].id

        // Op 2..8: the whole mixer surface.
        perform(um) { store.setStemGain(id: stemA, in: id, gainDB: -4.5, undoManager: um) }
        perform(um) { store.setStemPan(id: stemA, in: id, pan: -0.5, undoManager: um) }
        perform(um) { store.setStemMuted(id: stemA, in: id, muted: true, undoManager: um) }
        perform(um) { store.setStemSolo(id: stemB, in: id, solo: true, undoManager: um) }
        perform(um) { store.renameStem(id: stemB, in: id, to: "Drum Bus", undoManager: um) }
        perform(um) { store.setMasterGain(in: id, gainDB: -6, undoManager: um) }
        perform(um) { store.removeStem(id: stemA, from: id, undoManager: um) }
        perform(um) { store.renameSession(id: id, to: "Undo Lab 2", undoManager: um) }

        // Final state sanity.
        var current = try #require(store.session(id: id))
        #expect(current.name == "Undo Lab 2")
        #expect(current.stems.count == 1)
        #expect(current.stems[0].id == stemB)
        #expect(current.stems[0].displayName == "Drum Bus")
        #expect(current.stems[0].solo)
        #expect(current.masterGainDB == -6)

        // Unwind everything.
        um.undo()  // rename session back
        #expect(store.session(id: id)?.name == "Undo Lab")

        um.undo()  // restore removed stem A at its original position
        current = try #require(store.session(id: id))
        #expect(current.stems.count == 2)
        #expect(current.stems[0].id == stemA)
        #expect(current.stems[0].muted)          // still muted (that op is later in history)
        #expect(current.stems[0].gainDB == -4.5)
        #expect(current.stems[0].pan == -0.5)    // pan survived remove/restore

        um.undo()  // master gain back to 0
        #expect(store.session(id: id)?.masterGainDB == 0)

        um.undo()  // stem B name back
        #expect(store.session(id: id)?.stems[1].displayName == "drums")

        um.undo()  // stem B solo off
        #expect(store.session(id: id)?.stems[1].solo == false)

        um.undo()  // stem A unmuted
        #expect(store.session(id: id)?.stems[0].muted == false)

        um.undo()  // stem A pan back to center
        #expect(store.session(id: id)?.stems[0].pan == 0)

        um.undo()  // stem A gain back to 0
        #expect(store.session(id: id)?.stems[0].gainDB == 0)

        um.undo()  // stems removed (undo of add)
        #expect(store.session(id: id)?.stems.isEmpty == true)

        // Replay everything.
        #expect(um.canRedo)
        while um.canRedo { um.redo() }
        current = try #require(store.session(id: id))
        #expect(current.name == "Undo Lab 2")
        #expect(current.stems.count == 1)
        #expect(current.stems[0].id == stemB)
        #expect(current.stems[0].displayName == "Drum Bus")
        #expect(current.stems[0].solo)
        #expect(current.masterGainDB == -6)
    }

    @Test("removing a stem keeps its audio on disk so undo is always safe")
    func removeKeepsFile() throws {
        let (store, root, sourceA, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let um = makeUndoManager()

        let doc = store.createSession(name: "Keep Files")
        perform(um) { _ = try? store.addStems(fileURLs: [sourceA], to: doc.id, undoManager: um) }
        let stem = try #require(store.session(id: doc.id)?.stems.first)
        let audioPath = store.audioURL(for: stem).path

        perform(um) { store.removeStem(id: stem.id, from: doc.id, undoManager: um) }
        #expect(store.session(id: doc.id)?.stems.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: audioPath))  // file survives

        um.undo()
        let restored = try #require(store.session(id: doc.id)?.stems.first)
        #expect(restored.id == stem.id)
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: restored).path))
    }

    @Test("pan clamps to −1…+1 and persists across reload")
    func panClampAndPersist() throws {
        let (store, root, sourceA, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let doc = store.createSession(name: "Pan")
        _ = try store.addStems(fileURLs: [sourceA], to: doc.id)
        let stem = try #require(store.session(id: doc.id)?.stems.first)

        store.setStemPan(id: stem.id, in: doc.id, pan: 3.0)
        #expect(store.session(id: doc.id)?.stems.first?.pan == 1.0)
        store.setStemPan(id: stem.id, in: doc.id, pan: -2.0)
        #expect(store.session(id: doc.id)?.stems.first?.pan == -1.0)
        store.setStemPan(id: stem.id, in: doc.id, pan: -0.33)

        let reloaded = StemSessionStore(
            directory: root.appendingPathComponent("StemSessions", isDirectory: true),
            indexURL: root.appendingPathComponent("stem_sessions.json")
        )
        #expect(reloaded.session(id: doc.id)?.stems.first?.pan == -0.33)
    }

    @Test("origin ops log is append-only across ops and undo")
    func originOpsAppendOnly() throws {
        let (store, root, sourceA, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let um = makeUndoManager()

        let doc = store.createSession(name: "Log")
        var previousOps = try #require(store.session(id: doc.id)?.originOps)

        func expectAppendOnly() throws {
            let ops = try #require(store.session(id: doc.id)?.originOps)
            #expect(ops.count >= previousOps.count)
            #expect(Array(ops.prefix(previousOps.count)) == previousOps)  // history never rewritten
            previousOps = ops
        }

        perform(um) { _ = try? store.addStems(fileURLs: [sourceA], to: doc.id, undoManager: um) }
        try expectAppendOnly()

        let stem = try #require(store.session(id: doc.id)?.stems.first)
        perform(um) { store.removeStem(id: stem.id, from: doc.id, undoManager: um) }
        try expectAppendOnly()

        um.undo()  // restore appends a compensating entry instead of rewriting
        try expectAppendOnly()
        let ops = try #require(store.session(id: doc.id)?.originOps)
        #expect(ops.last?.action == StemOriginOp.actionRestoredStem)
    }

    @Test("filename sanitization")
    func sanitization() {
        #expect(StemSessionStore.sanitizedBaseName("vocals take 1") == "vocals_take_1")
        #expect(StemSessionStore.sanitizedBaseName("weird/../name!?") == "weird____name")  // "/", ".", "!", "?" → "_"
        #expect(StemSessionStore.sanitizedBaseName("___") == "stem")
        #expect(StemSessionStore.sanitizedBaseName(String(repeating: "x", count: 100)).count == 40)
    }
}
