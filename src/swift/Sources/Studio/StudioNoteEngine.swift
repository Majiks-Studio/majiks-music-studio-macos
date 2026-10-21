import Foundation

// MARK: - The note editing seam (E1-ui <-> E1-engine)
//
// E1-engine owns the Rust `Note`, the catalog commands and the `.mstudio`
// serialization; this file is the Swift side of the same seam, defined here so
// the piano roll can be built, exercised and unit-tested before the engine lands
// its half. It is NOT a stub that pretends to work: `StudioMockNoteEngine` below
// really applies edits, really journals them, and really reverses them, so the
// UI is driven against honest behaviour. When the engine lands, the mock is
// replaced by a client that serializes the same command shapes and nothing in
// the piano roll changes.
//
// THE HOUSE RULE, unconditional here: the UI never mutates a note. Every single
// edit — draw, move, resize, delete, duplicate, velocity, even a keyboard nudge
// — leaves as one journaled command on this bus. That is what buys undo/redo and
// agent parity for free, and it is why there is no `notes[i].pitch = ...`
// anywhere in the piano roll.

// MARK: Snapshot

/// A note-backed (MIDI) clip. `startTicks` is absolute on the timeline; the
/// notes inside it are clip-relative, exactly as the engine stores them.
struct StudioMidiClipSnapshot: Identifiable, Sendable, Equatable {
    var id: UUID
    var trackID: UUID
    var name: String
    var startTicks: Int64
    var lengthTicks: Int64
    /// Sorted by the engine's total order `(start_ticks, pitch, id)`.
    var notes: [StudioNote]
    /// Stem colour family for drawing (the track's kind).
    var kind: StudioStemKind = .other

    var endTicks: Int64 { startTicks + lengthTicks }

    func note(_ id: String) -> StudioNote? { notes.first(where: { $0.id == id }) }
}

/// Everything the piano roll needs to draw a grid that matches the project's
/// beat-tracked bars and a play head that matches the audio clock.
struct StudioNoteSessionSnapshot: Sendable, Equatable {
    var revision: UInt64
    var clip: StudioMidiClipSnapshot
    var barGrid: StudioBarGrid
    var tempoMap: StudioTempoMap
    var transport: StudioTransportSnapshot
    /// Depth of the undo / redo stacks, so the UI can disable what is not there.
    var undoDepth: Int = 0
    var redoDepth: Int = 0
}

// MARK: Commands

/// One note edit, in the batch-first shape the piano roll needs.
///
/// Batch-first is load-bearing, not a convenience: dragging a 6-note chord must
/// be ONE journal entry and ONE undo step. A per-note command shape would make
/// Cmd-Z peel a chord apart note by note, which is exactly the behaviour that
/// makes an editor feel broken.
enum StudioNoteCommand: Sendable, Equatable {
    /// Add one note. `note.id` is minted UI-side (ULID-shaped), the same way
    /// automation point ids already are, so the add is idempotent under replay.
    case add(clipID: UUID, notes: [StudioNote])
    case remove(clipID: UUID, noteIDs: [String])
    /// Move a group by one delta. Relative offsets are preserved by definition.
    case move(clipID: UUID, noteIDs: [String], deltaTicks: Int64, deltaPitch: Int)
    case resize(clipID: UUID, noteIDs: [String], edge: StudioNoteEdit.Edge, deltaTicks: Int64)
    case setVelocity(clipID: UUID, noteIDs: [String], deltaVelocity: Int)
    /// Duplicate a group at an offset. `newIDs` is positionally paired with
    /// `noteIDs` and minted UI-side so undo/redo is deterministic.
    case duplicate(clipID: UUID, noteIDs: [String], newIDs: [String], deltaTicks: Int64, deltaPitch: Int)
    /// Set ABSOLUTE start/length for a batch. The only non-delta member of the
    /// family, and it exists so quantize has an inverse that names where the
    /// performance WAS rather than approximating its way back.
    case setTiming(clipID: UUID, timings: [StudioNoteTiming])
    /// Pull a batch toward `gridTicks` at `strengthPercent` (0-100).
    ///
    /// ⚠️ EXPLICIT ONLY. Nothing in this app may issue this on capture, on
    /// load, on import, or as a side effect of another edit. The owner's own
    /// take was recorded with the tempo map fitted to his playing, so it is
    /// deliberately off the grid; an automatic quantize would not tidy that
    /// performance up, it would delete it. The only callers are the toolbar
    /// button and the ⌘U shortcut, both acting on a selection the user made.
    case quantize(clipID: UUID, noteIDs: [String], gridTicks: Int64, strengthPercent: Int, quantizeEnds: Bool)

    /// Catalog v2 name. New semantics get NEW names (E0 §9.2): none of these
    /// extend an existing command.
    var catalogName: String {
        switch self {
        case .add: return "note.add"
        case .remove: return "note.remove"
        case .move: return "note.move"
        case .resize: return "note.resize"
        case .setVelocity: return "note.velocity.set"
        case .duplicate: return "note.duplicate"
        case .setTiming: return "note.timing.set"
        case .quantize: return "note.quantize"
        }
    }

    var clipID: UUID {
        switch self {
        case .add(let id, _), .remove(let id, _), .move(let id, _, _, _),
             .resize(let id, _, _, _), .setVelocity(let id, _, _), .duplicate(let id, _, _, _, _),
             .setTiming(let id, _), .quantize(let id, _, _, _, _):
            return id
        }
    }

    /// True when the command would change nothing — the UI drops these rather
    /// than writing a no-op into the journal (an undo step that does nothing is
    /// worse than no undo step).
    var isNoOp: Bool {
        switch self {
        case .add(_, let notes): return notes.isEmpty
        case .remove(_, let ids): return ids.isEmpty
        case .move(_, let ids, let dt, let dp): return ids.isEmpty || (dt == 0 && dp == 0)
        case .resize(_, let ids, _, let dt): return ids.isEmpty || dt == 0
        case .setVelocity(_, let ids, let dv): return ids.isEmpty || dv == 0
        case .duplicate(_, let ids, let newIDs, _, _): return ids.isEmpty || ids.count != newIDs.count
        case .setTiming(_, let timings): return timings.isEmpty
        // A 0% quantize moves nothing, and a grid of zero has no lines. Both
        // would journal an undo step that does nothing, which is worse than no
        // undo step at all.
        case .quantize(_, let ids, let grid, let strength, _):
            return ids.isEmpty || grid <= 0 || strength <= 0
        }
    }
}

/// One entry in a `note.timing.set` batch: absolute clip-relative position and
/// length for a note that already exists.
struct StudioNoteTiming: Sendable, Equatable {
    var noteID: String
    var startTicks: Int64
    var lengthTicks: Int64
}

// MARK: Protocol

/// The engine surface the piano roll needs. Deliberately small: three reads and
/// one write, plus the undo pair that already exists on `StudioEngineProtocol`.
protocol StudioNoteEngineProtocol: Sendable {
    /// Latest note session, or nil when `ifNewerThan` is already current
    /// (change-conditional adoption, the same contract `StudioEngineProtocol`
    /// uses).
    func noteSession(clipID: UUID, ifNewerThan revision: UInt64?) async -> StudioNoteSessionSnapshot?

    /// Send one journaled note command.
    @discardableResult
    func send(_ command: StudioNoteCommand) async -> StudioCommandResult

    @discardableResult
    func undo() async -> Bool
    @discardableResult
    func redo() async -> Bool
}

/// Minting note ids UI-side (the automation-point precedent). ULID-shaped:
/// lexicographically sortable, so `(start, pitch, id)` stays stable and a burst
/// of notes drawn in one gesture keeps its authored order.
enum StudioNoteIDMinter {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func mint(now: Date = Date(), random: () -> UInt8 = { UInt8.random(in: 0..<32) }) -> String {
        var out = ""
        var ms = UInt64(now.timeIntervalSince1970 * 1000)
        var timeChars = [Character]()
        for _ in 0..<10 {
            timeChars.append(alphabet[Int(ms % 32)])
            ms /= 32
        }
        out.append(contentsOf: timeChars.reversed())
        for _ in 0..<16 { out.append(alphabet[Int(random() % 32)]) }
        return out
    }

    /// A deterministic minter for tests and replay evidence.
    static func sequence(prefix: String, count: Int) -> [String] {
        (0..<count).map { "\(prefix)\(String(format: "%04d", $0))" }
    }
}

// MARK: - Mock engine
//
// A real, honest implementation of the seam: it applies every command, keeps a
// journal with a computed inverse per entry, and undo/redo walks that journal.
// It is what the piano roll runs against until E1-engine lands, and it is what
// the interaction tests assert through, so "undo restored the note" is proven
// against behaviour rather than against a comment.

actor StudioMockNoteEngine: StudioNoteEngineProtocol {

    private var clip: StudioMidiClipSnapshot
    private var barGrid: StudioBarGrid
    private var tempoMap: StudioTempoMap
    private var transport: StudioTransportSnapshot
    private var revision: UInt64 = 1

    /// Journal: each entry is (applied command, its inverse). Undo applies the
    /// inverse and moves the entry to the redo stack.
    private var undoStack: [(command: StudioNoteCommand, inverse: StudioNoteCommand)] = []
    private var redoStack: [(command: StudioNoteCommand, inverse: StudioNoteCommand)] = []

    /// Every command that was accepted, in order — the evidence trail the
    /// interaction tests assert on ("the drag emitted exactly one move").
    private(set) var journal: [StudioNoteCommand] = []

    init(
        clip: StudioMidiClipSnapshot,
        barGrid: StudioBarGrid = StudioBarGrid(),
        tempoMap: StudioTempoMap = .constant(bpm: 120),
        transport: StudioTransportSnapshot = StudioTransportSnapshot(
            isPlaying: false, positionTicks: 0, capturedAtHostTime: 0, loopRegion: nil)
    ) {
        self.clip = clip
        self.barGrid = barGrid
        self.tempoMap = tempoMap
        self.transport = transport
    }

    func noteSession(clipID: UUID, ifNewerThan revision: UInt64?) async -> StudioNoteSessionSnapshot? {
        guard clipID == clip.id else { return nil }
        if let revision, revision >= self.revision { return nil }
        return StudioNoteSessionSnapshot(
            revision: self.revision, clip: clip, barGrid: barGrid, tempoMap: tempoMap,
            transport: transport, undoDepth: undoStack.count, redoDepth: redoStack.count)
    }

    func commandLog() -> [StudioNoteCommand] { journal }

    func setTransport(_ transport: StudioTransportSnapshot) {
        self.transport = transport
        revision += 1
    }

    @discardableResult
    func send(_ command: StudioNoteCommand) async -> StudioCommandResult {
        guard command.clipID == clip.id else {
            return StudioCommandResult(ok: false, message: "No such clip.")
        }
        guard !command.isNoOp else {
            return StudioCommandResult(ok: false, message: "No-op command was not journaled.")
        }
        guard let inverse = inverse(of: command) else {
            return StudioCommandResult(ok: false, message: "Command does not apply to this clip.")
        }
        guard apply(command) else {
            return StudioCommandResult(ok: false, message: "Command was rejected.")
        }
        journal.append(command)
        undoStack.append((command, inverse))
        redoStack.removeAll()
        revision += 1
        return StudioCommandResult(ok: true, message: nil)
    }

    @discardableResult
    func undo() async -> Bool {
        guard let entry = undoStack.popLast() else { return false }
        _ = apply(entry.inverse)
        redoStack.append(entry)
        revision += 1
        return true
    }

    @discardableResult
    func redo() async -> Bool {
        guard let entry = redoStack.popLast() else { return false }
        _ = apply(entry.command)
        undoStack.append(entry)
        revision += 1
        return true
    }

    // MARK: Apply / invert

    private func apply(_ command: StudioNoteCommand) -> Bool {
        switch command {
        case .add(_, let notes):
            for note in notes where clip.note(note.id) == nil {
                clip.notes.append(note)
            }
        case .remove(_, let ids):
            let set = Set(ids)
            clip.notes.removeAll { set.contains($0.id) }
        case .move(_, let ids, let dt, let dp):
            mutate(ids) { note in
                note.startTicks = max(0, note.startTicks + dt)
                note.pitch = StudioNote.clampPitch(Int(note.pitch) + dp)
            }
        case .resize(_, let ids, let edge, let dt):
            mutate(ids) { note in
                switch edge {
                case .trailing:
                    note.lengthTicks = max(1, note.lengthTicks + dt)
                case .leading:
                    note.startTicks = max(0, note.startTicks + dt)
                    note.lengthTicks = max(1, note.lengthTicks - dt)
                }
            }
        case .setVelocity(_, let ids, let dv):
            mutate(ids) { note in note.velocity = StudioNote.clampVelocity(note.velocity + dv) }
        case .duplicate(_, let ids, let newIDs, let dt, let dp):
            var copies: [StudioNote] = []
            for (source, newID) in zip(ids, newIDs) {
                guard let note = clip.note(source) else { continue }
                var copy = note
                copy.id = newID
                copy.startTicks = max(0, note.startTicks + dt)
                copy.pitch = StudioNote.clampPitch(Int(note.pitch) + dp)
                copies.append(copy)
            }
            clip.notes.append(contentsOf: copies)
        case .setTiming(_, let timings):
            let byID = Dictionary(timings.map { ($0.noteID, $0) }, uniquingKeysWith: { a, _ in a })
            for index in clip.notes.indices {
                guard let t = byID[clip.notes[index].id] else { continue }
                clip.notes[index].startTicks = max(0, t.startTicks)
                clip.notes[index].lengthTicks = max(1, t.lengthTicks)
            }
        case .quantize(_, let ids, let grid, let strength, let ends):
            // The mock computes the SAME arithmetic the engine does, from the
            // SAME inputs (clip origin + bar-grid phase anchor). A mock that
            // shortcut this would let a wrong wire payload pass every test.
            //
            // Validate the WHOLE batch first, mutate second — the engine's
            // rule. A partial apply leaves a state no inverse describes.
            let set = Set(ids)
            var planned: [(index: Int, start: Int64, length: Int64)] = []
            for index in clip.notes.indices where set.contains(clip.notes[index].id) {
                let note = clip.notes[index]
                let startAbs = clip.startTicks + note.startTicks
                let startShift = StudioNoteEdit.quantizeShift(
                    position: startAbs, anchor: barGrid.phaseAnchorTicks,
                    gridTicks: grid, strengthPercent: strength)
                let newStart = note.startTicks + startShift
                var newLength = note.lengthTicks
                if ends {
                    let endShift = StudioNoteEdit.quantizeShift(
                        position: startAbs + note.lengthTicks, anchor: barGrid.phaseAnchorTicks,
                        gridTicks: grid, strengthPercent: strength)
                    newLength = note.lengthTicks + endShift - startShift
                }
                // Refused whole, never clamped: a clamped note has no exact
                // way back, and the way back is the point.
                guard newStart >= 0, newLength >= 1 else { return false }
                planned.append((index, newStart, newLength))
            }
            for step in planned {
                clip.notes[step.index].startTicks = step.start
                clip.notes[step.index].lengthTicks = step.length
            }
        }
        clip.notes = StudioNote.sorted(clip.notes)
        return true
    }

    private func mutate(_ ids: [String], _ body: (inout StudioNote) -> Void) {
        let set = Set(ids)
        for index in clip.notes.indices where set.contains(clip.notes[index].id) {
            body(&clip.notes[index])
        }
    }

    /// The inverse of a command, computed against the CURRENT state (which is
    /// why it is taken before `apply`). Every one of these is exact, not
    /// approximate — undo must restore pre-state byte for byte.
    private func inverse(of command: StudioNoteCommand) -> StudioNoteCommand? {
        switch command {
        case .add(let clipID, let notes):
            return .remove(clipID: clipID, noteIDs: notes.map(\.id))
        case .remove(let clipID, let ids):
            let existing = ids.compactMap { clip.note($0) }
            guard !existing.isEmpty else { return nil }
            return .add(clipID: clipID, notes: existing)
        case .move(let clipID, let ids, let dt, let dp):
            return .move(clipID: clipID, noteIDs: ids, deltaTicks: -dt, deltaPitch: -dp)
        case .resize(let clipID, let ids, let edge, let dt):
            return .resize(clipID: clipID, noteIDs: ids, edge: edge, deltaTicks: -dt)
        case .setVelocity(let clipID, let ids, let dv):
            return .setVelocity(clipID: clipID, noteIDs: ids, deltaVelocity: -dv)
        case .duplicate(let clipID, _, let newIDs, _, _):
            return .remove(clipID: clipID, noteIDs: newIDs)
        case .setTiming(let clipID, let timings):
            let prior = timings.compactMap { t -> StudioNoteTiming? in
                guard let note = clip.note(t.noteID) else { return nil }
                return StudioNoteTiming(
                    noteID: note.id, startTicks: note.startTicks, lengthTicks: note.lengthTicks)
            }
            guard prior.count == timings.count else { return nil }
            return .setTiming(clipID: clipID, timings: prior)
        case .quantize(let clipID, let ids, _, _, _):
            // The EXACT prior positions, never a reverse quantize. Quantizing
            // back lands on the grid; the performance was not on the grid.
            let prior = ids.compactMap { id -> StudioNoteTiming? in
                guard let note = clip.note(id) else { return nil }
                return StudioNoteTiming(
                    noteID: note.id, startTicks: note.startTicks, lengthTicks: note.lengthTicks)
            }
            guard prior.count == ids.count else { return nil }
            return .setTiming(clipID: clipID, timings: prior)
        }
    }

    // MARK: Fixtures

    /// Stable id for the demo clip so the UI can open it without a round trip.
    static let demoClipID = UUID(uuidString: "5E1A0000-0000-4000-8000-000000000001")!

    /// A demo clip so the piano roll has something musical to open onto: a
    /// four-bar Am -> F -> C -> G progression with a syncopated top line. Built
    /// with a deliberate lead-in phase anchor (half a bar) so the bar grid is
    /// exercised against a NON-ZERO anchor rather than the trivial case.
    static func demoSession() -> StudioMockNoteEngine {
        let sig = StudioTimeSignature.fourFour
        let bar = sig.ticksPerBar
        let beat = sig.ticksPerBeat
        let eighth = beat / 2

        var notes: [StudioNote] = []
        var counter = 0
        func add(_ pitch: Int, _ start: Int64, _ length: Int64, _ velocity: Int) {
            counter += 1
            notes.append(StudioNote(
                id: String(format: "DEMO%04d", counter),
                startTicks: start, lengthTicks: length,
                pitch: StudioNote.clampPitch(pitch), velocity: velocity))
        }

        // Chords, one per bar (A minor, F, C, G) as held triads.
        let chords: [[Int]] = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]
        for (index, chord) in chords.enumerated() {
            for pitch in chord {
                add(pitch, Int64(index) * bar, bar - eighth, 78)
            }
        }
        // A syncopated top line over the top, so velocity + short notes are both
        // exercised the moment the roll opens.
        let melody: [(Int, Int64, Int64, Int)] = [
            (72, 0, eighth, 118), (74, eighth * 3, eighth, 92), (76, beat * 2, beat, 104),
            (74, bar + eighth, eighth, 96), (72, bar + beat, eighth * 3, 110),
            (69, bar * 2, beat, 100), (71, bar * 2 + beat * 2, eighth, 88),
            (72, bar * 2 + beat * 3, eighth, 94), (74, bar * 3, beat * 2, 112),
            (76, bar * 3 + beat * 2, beat * 2, 120),
        ]
        for (pitch, start, length, velocity) in melody { add(pitch, start, length, velocity) }

        let clip = StudioMidiClipSnapshot(
            id: demoClipID, trackID: UUID(), name: "Keys",
            startTicks: bar * 4, lengthTicks: bar * 4,
            notes: StudioNote.sorted(notes), kind: .other)

        return StudioMockNoteEngine(
            clip: clip,
            // Half-bar lead-in: bar 1 begins at 1920 ticks, not at 0. A grid that
            // ignores this draws every bar line in the wrong place for a landed
            // generative song.
            barGrid: StudioBarGrid(timeSignature: sig, phaseAnchorTicks: bar / 2),
            tempoMap: .constant(bpm: 96),
            transport: StudioTransportSnapshot(
                isPlaying: false, positionTicks: bar * 4, capturedAtHostTime: 0, loopRegion: nil))
    }

    /// A synthetic clip of `count` notes for the performance harness.
    static let stressClipID = UUID(uuidString: "5E1A0000-0000-4000-8000-000000000002")!

    static func stressSession(count: Int, bars: Int = 64) -> StudioMockNoteEngine {
        let sig = StudioTimeSignature.fourFour
        let bar = sig.ticksPerBar
        let span = Int64(bars) * bar
        var notes: [StudioNote] = []
        notes.reserveCapacity(count)
        var seed: UInt64 = 0x5EED_1234
        func next() -> UInt64 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return seed
        }
        for index in 0..<count {
            let start = Int64(next() % UInt64(max(1, span - 240)))
            notes.append(StudioNote(
                id: String(format: "STRESS%06d", index),
                startTicks: start - start % 120,
                lengthTicks: Int64(120 + next() % 480),
                pitch: StudioNote.clampPitch(36 + Int(next() % 60)),
                velocity: Int(40 + next() % 88)))
        }
        let clip = StudioMidiClipSnapshot(
            id: stressClipID, trackID: UUID(), name: "Stress",
            startTicks: 0, lengthTicks: span,
            notes: StudioNote.sorted(notes), kind: .other)
        return StudioMockNoteEngine(clip: clip, tempoMap: .constant(bpm: 120))
    }
}

// MARK: - Note audition gate
//
// Lives HERE, on the always-compiled note seam, rather than beside the real
// engine: the on-screen keyboard needs it to express a held key, and that
// keyboard is compiled on every build (it draws and responds on a mock build,
// honestly labelled as silent, rather than vanishing).

/// How long an auditioned note sounds for.
enum StudioNoteAuditionGate: Sendable {
    /// Releases itself. The UI case: a click has no key-up.
    case oneShot
    /// Sounds until an explicit `.off`. The held-key case.
    case on
    case off

    var wire: String {
        switch self {
        case .oneShot: return "oneShot"
        case .on: return "on"
        case .off: return "off"
        }
    }
}
