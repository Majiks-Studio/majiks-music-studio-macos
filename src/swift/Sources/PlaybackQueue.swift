import Foundation
import Combine

@MainActor
final class PlaybackQueue: ObservableObject {
    enum RepeatMode: String, CaseIterable {
        case off
        case all
        case one
    }

    @Published var queue: [Track] = []
    @Published var currentIndex: Int = -1
    @Published var shuffleEnabled: Bool = false
    @Published var repeatMode: RepeatMode = .off

    /// Underlying audio player — set via configure(player:)
    private(set) var player: AudioPlayer?

    /// Shuffle order indices (into `queue`)
    private var shuffleOrder: [Int] = []

    var currentTrack: Track? {
        guard currentIndex >= 0 && currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    /// Tracks coming up after current (respects shuffle order)
    var upNext: [Track] {
        guard currentIndex >= 0 && currentIndex < queue.count else { return [] }
        if shuffleEnabled && !shuffleOrder.isEmpty {
            guard let shufflePos = shuffleOrder.firstIndex(of: currentIndex) else { return [] }
            let remaining = shuffleOrder.dropFirst(shufflePos + 1)
            return remaining.compactMap { idx in
                idx < queue.count ? queue[idx] : nil
            }
        } else {
            let remaining = queue.dropFirst(currentIndex + 1)
            return Array(remaining)
        }
    }

    var hasNext: Bool {
        if repeatMode == .all || repeatMode == .one { return !queue.isEmpty }
        if shuffleEnabled && !shuffleOrder.isEmpty {
            guard let shufflePos = shuffleOrder.firstIndex(of: currentIndex) else { return false }
            return shufflePos + 1 < shuffleOrder.count
        }
        return currentIndex + 1 < queue.count
    }

    var hasPrevious: Bool {
        if repeatMode == .all { return !queue.isEmpty }
        if shuffleEnabled && !shuffleOrder.isEmpty {
            guard let shufflePos = shuffleOrder.firstIndex(of: currentIndex) else { return false }
            return shufflePos > 0
        }
        return currentIndex > 0
    }

    /// Connect to the audio player. Call once from onAppear.
    func configure(player: AudioPlayer) {
        self.player = player
        player.onPlaybackFinished = { [weak self] in
            Task { @MainActor in
                self?.handlePlaybackFinished()
            }
        }
    }

    // MARK: - Public API

    /// Play a specific track, setting the queue to the given context
    func playTrack(_ track: Track, from context: [Track]) {
        queue = context
        if let idx = context.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }
        if shuffleEnabled {
            regenerateShuffleOrder()
        }
        loadAndPlay(track)
    }

    /// Play all tracks starting at the given index
    func playAll(_ tracks: [Track], startingAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        currentIndex = min(index, tracks.count - 1)
        if shuffleEnabled {
            regenerateShuffleOrder()
        }
        loadAndPlay(tracks[currentIndex])
    }

    /// Shuffle all tracks and start playing
    func shuffleAll(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffleEnabled = true
        queue = tracks
        regenerateShuffleOrder()
        currentIndex = shuffleOrder.first ?? 0
        loadAndPlay(queue[currentIndex])
    }

    /// Add a track to the end of the queue
    func addToQueue(_ track: Track) {
        queue.append(track)
        if shuffleEnabled {
            shuffleOrder.append(queue.count - 1)
        }
    }

    /// Insert a track right after the current one
    func addNext(_ track: Track) {
        let insertAt = currentIndex + 1
        if insertAt >= queue.count {
            queue.append(track)
        } else {
            queue.insert(track, at: insertAt)
        }
        if shuffleEnabled {
            regenerateShuffleOrder()
        }
    }

    func skipToNext() {
        guard !queue.isEmpty else { return }

        if repeatMode == .one {
            if let track = currentTrack {
                loadAndPlay(track)
            }
            return
        }

        let nextIndex = resolveNextIndex()
        if let nextIndex = nextIndex {
            currentIndex = nextIndex
            loadAndPlay(queue[currentIndex])
        } else {
            player?.stop()
        }
    }

    func skipToPrevious() {
        guard !queue.isEmpty, let player = player else { return }

        // If more than 3 seconds in, restart current track
        if player.currentTime > 3.0 {
            player.seek(to: 0)
            if !player.isPlaying {
                player.play()
            }
            return
        }

        let prevIndex = resolvePreviousIndex()
        if let prevIndex = prevIndex {
            currentIndex = prevIndex
            loadAndPlay(queue[currentIndex])
        } else {
            player.seek(to: 0)
            if !player.isPlaying {
                player.play()
            }
        }
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        if shuffleEnabled {
            regenerateShuffleOrder()
        } else {
            shuffleOrder = []
        }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// Remove a track from the queue by index
    func removeFromQueue(at index: Int) {
        guard index >= 0 && index < queue.count else { return }
        queue.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            if currentIndex >= queue.count {
                currentIndex = max(0, queue.count - 1)
            }
        }
        if shuffleEnabled {
            regenerateShuffleOrder()
        }
    }

    // MARK: - Private

    /// Tracks that failed to load in the current skip chain, to prevent infinite loops.
    private var failedIndices: Set<Int> = []

    private func loadAndPlay(_ track: Track) {
        guard let player = player else { return }
        player.load(url: track.audioURL)

        // If load failed, skip to the next playable track
        if player.loadFailed {
            failedIndices.insert(currentIndex)

            // If all tracks in the queue have failed, stop trying
            if failedIndices.count >= queue.count {
                failedIndices.removeAll()
                player.stop()
                return
            }

            // Try the next track
            if let nextIndex = resolveNextIndex(), !failedIndices.contains(nextIndex) {
                currentIndex = nextIndex
                loadAndPlay(queue[currentIndex])
            } else {
                failedIndices.removeAll()
                player.stop()
            }
            return
        }

        // Load succeeded — clear failure tracking
        failedIndices.removeAll()

        player.nowPlaying = NowPlayingInfo(
            title: track.title,
            artist: track.artist ?? "",
            album: track.album ?? "",
            duration: track.duration,
            artworkURL: track.customArtworkURL
        )
        player.play()
    }

    private func handlePlaybackFinished() {
        if repeatMode == .one {
            if let track = currentTrack {
                loadAndPlay(track)
            }
            return
        }

        if let nextIndex = resolveNextIndex() {
            currentIndex = nextIndex
            loadAndPlay(queue[currentIndex])
        }
    }

    private func resolveNextIndex() -> Int? {
        if shuffleEnabled && !shuffleOrder.isEmpty {
            guard let shufflePos = shuffleOrder.firstIndex(of: currentIndex) else { return nil }
            let nextShufflePos = shufflePos + 1
            if nextShufflePos < shuffleOrder.count {
                return shuffleOrder[nextShufflePos]
            } else if repeatMode == .all {
                regenerateShuffleOrder()
                return shuffleOrder.first
            }
            return nil
        } else {
            let next = currentIndex + 1
            if next < queue.count {
                return next
            } else if repeatMode == .all {
                return 0
            }
            return nil
        }
    }

    private func resolvePreviousIndex() -> Int? {
        if shuffleEnabled && !shuffleOrder.isEmpty {
            guard let shufflePos = shuffleOrder.firstIndex(of: currentIndex) else { return nil }
            if shufflePos > 0 {
                return shuffleOrder[shufflePos - 1]
            } else if repeatMode == .all {
                return shuffleOrder.last
            }
            return nil
        } else {
            if currentIndex > 0 {
                return currentIndex - 1
            } else if repeatMode == .all {
                return queue.count - 1
            }
            return nil
        }
    }

    private func regenerateShuffleOrder() {
        var indices = Array(0..<queue.count)
        if currentIndex >= 0 && currentIndex < queue.count {
            indices.removeAll { $0 == currentIndex }
            indices.shuffle()
            indices.insert(currentIndex, at: 0)
        } else {
            indices.shuffle()
        }
        shuffleOrder = indices
    }
}
