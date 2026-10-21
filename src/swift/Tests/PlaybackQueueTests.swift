import Testing
import Foundation
@testable import MajiksMusicStudio

// MARK: - PlaybackQueue Tests

@Suite("PlaybackQueue")
struct PlaybackQueueTests {

    private static func makeTracks(_ count: Int) -> [Track] {
        (0..<count).map { i in
            Track(
                id: UUID(),
                title: "Track \(i + 1)",
                caption: "",
                audioFileName: "track\(i).wav",
                createdAt: Date(),
                duration: Double(60 + i * 30)
            )
        }
    }

    // MARK: - Initial State

    @Test("initial state has empty queue")
    @MainActor
    func initialState() {
        let queue = PlaybackQueue()
        #expect(queue.queue.isEmpty)
        #expect(queue.currentIndex == -1)
        #expect(!queue.shuffleEnabled)
        #expect(queue.repeatMode == .off)
        #expect(queue.currentTrack == nil)
        #expect(queue.upNext.isEmpty)
    }

    // MARK: - playAll

    @Test("playAll sets queue and current index")
    @MainActor
    func playAllSetsQueue() {
        let queue = PlaybackQueue()
        let tracks = Self.makeTracks(5)

        queue.playAll(tracks, startingAt: 2)

        #expect(queue.queue.count == 5)
        #expect(queue.currentIndex == 2)
        #expect(queue.currentTrack?.id == tracks[2].id)
    }

    @Test("playAll with empty tracks does nothing")
    @MainActor
    func playAllEmpty() {
        let queue = PlaybackQueue()
        queue.playAll([])
        #expect(queue.queue.isEmpty)
        #expect(queue.currentIndex == -1)
    }

    @Test("playAll clamps startingAt to bounds")
    @MainActor
    func playAllClamps() {
        let queue = PlaybackQueue()
        let tracks = Self.makeTracks(3)

        queue.playAll(tracks, startingAt: 100)

        #expect(queue.currentIndex == 2)
    }

    // MARK: - playTrack

    @Test("playTrack sets queue from context and finds track")
    @MainActor
    func playTrackSetsContext() {
        let queue = PlaybackQueue()
        let tracks = Self.makeTracks(4)

        queue.playTrack(tracks[2], from: tracks)

        #expect(queue.queue.count == 4)
        #expect(queue.currentIndex == 2)
        #expect(queue.currentTrack?.id == tracks[2].id)
    }

    @Test("playTrack defaults to index 0 if track not in context")
    @MainActor
    func playTrackNotInContext() {
        let queue = PlaybackQueue()
        let tracks = Self.makeTracks(3)
        let outsideTrack = Track(
            id: UUID(),
            title: "Outside",
            caption: "",
            audioFileName: "outside.wav",
            createdAt: Date(),
            duration: 60
        )

        queue.playTrack(outsideTrack, from: tracks)

        #expect(queue.currentIndex == 0)
    }

    // MARK: - upNext

    @Test("upNext returns remaining tracks")
    @MainActor
    func upNextNormal() {
        let queue = PlaybackQueue()
        let tracks = Self.makeTracks(5)

        queue.playAll(tracks, startingAt: 1)

        let upcoming = queue.upNext
        #expect(upcoming.count == 3)
        #expect(upcoming[0].id == tracks[2].id)
        #expect(upcoming[1].id == tracks[3].id)
        #expect(upcoming[2].id == tracks[4].id)
    }

    @Test("upNext is empty at end of queue")
    @MainActor
    func upNextAtEnd() {
        let queue = PlaybackQueue()
        let tracks = Self.makeTracks(3)

        queue.playAll(tracks, startingAt: 2)

        #expect(queue.upNext.isEmpty)
    }

    // MARK: - hasNext / hasPrevious

    @Test("hasNext is true when not at end")
    @MainActor
    func hasNextMiddle() {
        let queue = PlaybackQueue()
        queue.playAll(Self.makeTracks(5), startingAt: 2)
        #expect(queue.hasNext)
    }

    @Test("hasNext is false at end with repeat off")
    @MainActor
    func hasNextAtEndRepeatOff() {
        let queue = PlaybackQueue()
        queue.playAll(Self.makeTracks(3), startingAt: 2)
        #expect(!queue.hasNext)
    }

    @Test("hasNext is true at end with repeat all")
    @MainActor
    func hasNextAtEndRepeatAll() {
        let queue = PlaybackQueue()
        queue.playAll(Self.makeTracks(3), startingAt: 2)
        queue.repeatMode = .all
        #expect(queue.hasNext)
    }

    @Test("hasPrevious is false at start with repeat off")
    @MainActor
    func hasPreviousAtStart() {
        let queue = PlaybackQueue()
        queue.playAll(Self.makeTracks(3), startingAt: 0)
        #expect(!queue.hasPrevious)
    }

    @Test("hasPrevious is true in middle")
    @MainActor
    func hasPreviousMiddle() {
        let queue = PlaybackQueue()
        queue.playAll(Self.makeTracks(3), startingAt: 1)
        #expect(queue.hasPrevious)
    }

    // MARK: - addToQueue / addNext

    @Test("addToQueue appends track to end")
    @MainActor
    func addToQueue() {
        let queue = PlaybackQueue()
        let tracks = Self.makeTracks(3)
        queue.playAll(tracks, startingAt: 0)

        let extra = Track(
            id: UUID(), title: "Extra", caption: "",
            audioFileName: "extra.wav", createdAt: Date(), duration: 60
        )
        queue.addToQueue(extra)

        #expect(queue.queue.count == 4)
        #expect(queue.queue.last?.id == extra.id)
    }

    @Test("addNext inserts track after current")
    @MainActor
    func addNext() {
        let queue = PlaybackQueue()
        let tracks = Self.makeTracks(3)
        queue.playAll(tracks, startingAt: 0)

        let inserted = Track(
            id: UUID(), title: "Inserted", caption: "",
            audioFileName: "ins.wav", createdAt: Date(), duration: 60
        )
        queue.addNext(inserted)

        #expect(queue.queue.count == 4)
        #expect(queue.queue[1].id == inserted.id)
    }

    // MARK: - removeFromQueue

    @Test("removeFromQueue removes track and adjusts index")
    @MainActor
    func removeFromQueue() {
        let queue = PlaybackQueue()
        let tracks = Self.makeTracks(5)
        queue.playAll(tracks, startingAt: 3)

        // Remove a track before current — currentIndex should decrement
        queue.removeFromQueue(at: 1)
        #expect(queue.queue.count == 4)
        #expect(queue.currentIndex == 2) // Was 3, removed before it
    }

    @Test("removeFromQueue at current track adjusts properly")
    @MainActor
    func removeCurrentTrack() {
        let queue = PlaybackQueue()
        let tracks = Self.makeTracks(3)
        queue.playAll(tracks, startingAt: 1)

        queue.removeFromQueue(at: 1) // Remove current
        #expect(queue.queue.count == 2)
        #expect(queue.currentIndex >= 0)
        #expect(queue.currentIndex < queue.queue.count)
    }

    // MARK: - Shuffle

    @Test("toggleShuffle enables and disables")
    @MainActor
    func toggleShuffle() {
        let queue = PlaybackQueue()
        #expect(!queue.shuffleEnabled)

        queue.toggleShuffle()
        #expect(queue.shuffleEnabled)

        queue.toggleShuffle()
        #expect(!queue.shuffleEnabled)
    }

    @Test("shuffleAll sets shuffle mode and starts playing")
    @MainActor
    func shuffleAll() {
        let queue = PlaybackQueue()
        let tracks = Self.makeTracks(10)

        queue.shuffleAll(tracks)

        #expect(queue.shuffleEnabled)
        #expect(queue.queue.count == 10)
        #expect(queue.currentIndex >= 0)
        #expect(queue.currentTrack != nil)
    }

    // MARK: - Repeat Mode

    @Test("cycleRepeatMode cycles through all modes")
    @MainActor
    func cycleRepeatMode() {
        let queue = PlaybackQueue()

        #expect(queue.repeatMode == .off)

        queue.cycleRepeatMode()
        #expect(queue.repeatMode == .all)

        queue.cycleRepeatMode()
        #expect(queue.repeatMode == .one)

        queue.cycleRepeatMode()
        #expect(queue.repeatMode == .off)
    }

    // MARK: - RepeatMode cases

    @Test("RepeatMode has three cases")
    func repeatModeCases() {
        let cases = PlaybackQueue.RepeatMode.allCases
        #expect(cases.count == 3)
        #expect(cases.contains(.off))
        #expect(cases.contains(.all))
        #expect(cases.contains(.one))
    }
}
