import SwiftUI

// MARK: - Note store for the arrangement
//
// Where the arrangement's note data comes from, and why it does NOT come from
// the project snapshot.
//
// `StudioProjectSnapshot` is polled at 30 Hz and, while the transport is
// rolling, it is rebuilt on EVERY poll (the seq early-out is deliberately
// bypassed while playing — RealStudioEngine.snapshot). Hanging a note array off
// `StudioClipSnapshot` would therefore mean decoding and allocating every note
// of every MIDI clip thirty times a second, and — worse — `StudioClipSnapshot`
// is `Equatable` and `snapshot` is `@Published`, so every SwiftUI diff of the
// project would become O(notes) as well. That cost has no test that can see it:
// it surfaces as a timeline that stutters during playback, which is precisely
// the class of regression this codebase keeps getting bitten by.
//
// So this is the waveform tile store's pattern, one level up: a cache keyed by
// clip id, filled asynchronously off the note seam the piano roll already uses
// (`StudioNoteEngineProtocol.noteSession`), and invalidated by the project's
// journal revision. Notes only change when a journaled command changes them, so
// the revision IS the correct staleness gate — and a rolling transport does not
// move it, which is exactly the property that makes playback free.

@MainActor
final class StudioMidiNoteStore: ObservableObject {

    /// Bumped when a clip's notes land, so the canvas redraws. Not per-clip
    /// state: the canvas pulls from the cache directly during draw, the same
    /// way it does with waveform tiles.
    @Published private(set) var epoch: UInt64 = 0

    private enum Entry {
        /// Read successfully.
        case notes(StudioClipNotes)
        /// The read came back with nothing — not a MIDI clip as far as the note
        /// seam is concerned, or a clip it does not know. Held with the
        /// revision it was learned at so the store does not ask again every
        /// frame for something the engine has already declined to answer.
        case unavailable(revision: UInt64)

        var revision: UInt64 {
            switch self {
            case .notes(let n): return n.revision
            case .unavailable(let r): return r
            }
        }
    }

    private var cache: [UUID: Entry] = [:]
    private var inFlight: Set<UUID> = []
    /// Access stamps, so eviction is O(1) per hit rather than an array scan —
    /// the tile store's reasoning, for the same reason (a long arrangement
    /// scrolled quickly).
    private var accessStamp: [UUID: UInt64] = [:]
    private var nextAccessStamp: UInt64 = 0
    private var lastRequestedAt: [UUID: TimeInterval] = [:]

    /// Note arrays are small next to peak arrays, but a very long arrangement
    /// is still bounded rather than unbounded.
    private let capacity = 512

    /// Minimum spacing between two reads of the SAME clip.
    ///
    /// The in-flight guard alone does not bound the rate: a gesture that
    /// journals continuously (a fader drag, a note drag in the roll) bumps the
    /// revision on every command, and each bump would arm another read the
    /// instant the previous one returned. On the real engine one `noteSession`
    /// is a whole-project JSON snapshot plus a scan, so that is not free. The
    /// arrangement thumbnail is a glanceable summary; a quarter second behind
    /// the piano roll is invisible, and the roll itself is the surface being
    /// watched while notes are being edited.
    private let minimumRefetchInterval: TimeInterval = 0.25

    // MARK: Read (draw path — must stay allocation-free)

    /// What the canvas should draw for this clip right now.
    func content(for clipID: UUID) -> StudioMidiClipContent {
        switch cache[clipID] {
        case .notes(let n):
            touch(clipID)
            return n.notes.isEmpty ? .empty : .notes(n)
        case .unavailable:
            touch(clipID)
            return .pending
        case nil:
            return .pending
        }
    }

    // MARK: Fetch

    /// Ask the note seam for a clip's notes if what is cached is older than the
    /// project's current revision.
    ///
    /// `engine` is nil on a build with no note seam (StudioMockEngine does not
    /// conform, and it never produces a MIDI clip either) — the call is then a
    /// no-op and the clip keeps drawing its pending mark, which is honest: the
    /// arrangement genuinely does not know what is in it.
    func request(
        _ clipID: UUID,
        projectRevision: UInt64,
        from engine: (any StudioNoteEngineProtocol)?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard let engine else { return }
        guard !inFlight.contains(clipID) else { return }
        let cached = cache[clipID]
        // Fresh enough: what we hold was read at or after the current journal
        // revision, so nothing can have changed it.
        if let cached, cached.revision >= projectRevision { return }
        if let last = lastRequestedAt[clipID], now - last < minimumRefetchInterval { return }

        inFlight.insert(clipID)
        lastRequestedAt[clipID] = now
        // `ifNewerThan` is the seam's own change-conditional contract: nil back
        // means "nothing you do not already have". On the FIRST read we pass
        // nil so that a nil answer unambiguously means "no notes for this
        // clip", not "unchanged".
        let since: UInt64? = cached == nil ? nil : cached?.revision
        Task { [weak self] in
            let session = await engine.noteSession(clipID: clipID, ifNewerThan: since)
            guard let self else { return }
            self.inFlight.remove(clipID)
            self.adopt(session, clipID: clipID, projectRevision: projectRevision)
        }
    }

    private func adopt(
        _ session: StudioNoteSessionSnapshot?,
        clipID: UUID,
        projectRevision: UInt64
    ) {
        guard let session else {
            // Unchanged (we already had it) or unavailable (we did not). Either
            // way, mark it current at the revision we asked about so the store
            // stops asking until the project actually moves again.
            switch cache[clipID] {
            case .notes(var held):
                held.revision = max(held.revision, projectRevision)
                cache[clipID] = .notes(held)
            default:
                cache[clipID] = .unavailable(revision: projectRevision)
            }
            touch(clipID)
            epoch &+= 1
            return
        }
        cache[clipID] = .notes(StudioClipNotes(
            notes: session.clip.notes,
            // The seam's revision is the journal seq, the same clock
            // `projectRevision` is on. Take the later of the two: the session
            // read may have raced ahead of the snapshot the canvas is drawing.
            revision: max(session.revision, projectRevision)))
        touch(clipID)
        evictIfNeeded()
        epoch &+= 1
    }

    // MARK: Bookkeeping

    private func touch(_ clipID: UUID) {
        nextAccessStamp &+= 1
        accessStamp[clipID] = nextAccessStamp
    }

    private func evictIfNeeded() {
        while cache.count > capacity {
            guard let victim = accessStamp.min(by: { $0.value < $1.value })?.key else { break }
            cache.removeValue(forKey: victim)
            accessStamp.removeValue(forKey: victim)
            lastRequestedAt.removeValue(forKey: victim)
        }
    }

    // MARK: Test / evidence hooks

    /// Whether a read for this clip is outstanding. Lets a test await the fetch
    /// path instead of sleeping a fixed amount and hoping.
    var hasPendingReads: Bool { !inFlight.isEmpty }

    /// Number of clips held. Evidence for the cache actually caching.
    var cachedClipCount: Int { cache.count }
}
