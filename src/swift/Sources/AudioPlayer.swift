import AVFoundation
import Foundation
import Combine

struct NowPlayingInfo: Equatable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let artworkURL: URL?
}

@MainActor
final class AudioPlayer: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentURL: URL?
    @Published var currentTime: Double = 0.0
    @Published var nowPlaying: NowPlayingInfo?
    @Published var volume: Double = 0.7 {
        didSet {
            player?.volume = Float(volume)
        }
    }

    var duration: Double {
        player?.duration ?? nowPlaying?.duration ?? 0
    }

    /// Called when a track finishes playing naturally (not stopped manually)
    var onPlaybackFinished: (() -> Void)?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Whether the last load() call succeeded. Used by PlaybackQueue to detect failures.
    private(set) var loadFailed: Bool = false

    func load(url: URL) {
        stop()
        loadFailed = false
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.volume = Float(volume)
            currentURL = url
            currentTime = 0.0
        } catch {
            player = nil
            loadFailed = true
            let filename = url.lastPathComponent
            ToastManager.shared.show("Could not play: \(filename)", style: .error)
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0.0
        nowPlaying = nil
        currentURL = nil
        stopTimer()
    }

    func seek(to time: Double) {
        guard let player = player else { return }
        player.currentTime = time
        currentTime = time
    }

    /// Adopt the player's clock. Assigns ONLY when the value actually moved.
    ///
    /// `@Published` fires `objectWillChange` on every write, equal or not, so
    /// the 10 Hz tick below used to invalidate every view observing this object
    /// ten times a second whether or not the clock had moved — and one of those
    /// observers was `ContentView`, i.e. the entire TabView. That was the engine
    /// behind the P0 in `StudioKeychainItem`: a free-looking body pass that was
    /// not free. Publishing on change is the rule; this is where it was missing.
    func adoptClock(_ time: Double) {
        guard currentTime != time else { return }
        currentTime = time
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if let player = self.player {
                    self.adoptClock(player.currentTime)

                    // Auto-advance when finished
                    if !player.isPlaying && self.isPlaying {
                        if let callback = self.onPlaybackFinished {
                            self.isPlaying = false
                            self.stopTimer()
                            callback()
                        } else {
                            self.stop()
                        }
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
