import SwiftUI

// MARK: - Persistent Player Bar (app-wide, below TabView)

struct PersistentPlayerBar: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var playbackQueue: PlaybackQueue
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0
    @State private var showUpNext = false

    private var repeatIcon: String {
        switch playbackQueue.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Waveform progress bar at top
            if player.duration > 0 {
                GeometryReader { geo in
                    ZStack {
                        if let audioURL = player.currentURL {
                            CompactWaveformView(
                                url: audioURL,
                                playbackProgress: isSeeking
                                    ? seekPosition / player.duration
                                    : player.currentTime / player.duration,
                                accentColor: .accentColor
                            )
                        } else {
                            // Fallback thin progress line when no URL available
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.15))
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * (isSeeking ? seekPosition / player.duration : player.currentTime / player.duration))
                            }
                        }
                    }
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isSeeking = true
                            let fraction = max(0, min(1, value.location.x / (NSScreen.main?.frame.width ?? 1200)))
                            seekPosition = fraction * player.duration
                        }
                        .onEnded { _ in
                            player.seek(to: seekPosition)
                            isSeeking = false
                        }
                )
            }

            HStack(spacing: 16) {
                // Track artwork + info
                HStack(spacing: 12) {
                    if let info = player.nowPlaying, let artURL = info.artworkURL,
                       FileExistenceProbe.exists(atPath: artURL.path) {
                        AsyncImage(url: artURL) { image in
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            playerArtworkPlaceholder
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        playerArtworkPlaceholder
                    }

                    if let info = player.nowPlaying {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                if !info.artist.isEmpty {
                                    Text(info.artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                if !info.album.isEmpty {
                                    Text("—")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(info.album)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(minWidth: 120, maxWidth: 200, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Playing")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .frame(minWidth: 120, alignment: .leading)
                    }
                }

                // Time display
                Text(formatDuration(player.currentTime) + " / " + formatDuration(player.duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(width: 80)

                // Waveform seek bar (replaces plain slider)
                if player.duration > 0, let audioURL = player.currentURL {
                    AudioWaveformView(
                        url: audioURL,
                        barColor: .accentColor,
                        playbackProgress: isSeeking
                            ? seekPosition / player.duration
                            : player.currentTime / player.duration
                    )
                    .frame(maxWidth: 300, maxHeight: 28)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isSeeking = true
                                seekPosition = max(0, min(player.duration, Double(value.location.x / 300) * player.duration))
                            }
                            .onEnded { _ in
                                player.seek(to: seekPosition)
                                isSeeking = false
                            }
                    )
                    .help("Seek — click or drag to jump to a position")
                } else if player.duration > 0 {
                    // Fallback slider when no audio URL available
                    Slider(
                        value: Binding(
                            get: { isSeeking ? seekPosition : player.currentTime },
                            set: { newValue in
                                seekPosition = newValue
                                isSeeking = true
                            }
                        ),
                        in: 0...player.duration,
                        onEditingChanged: { editing in
                            if !editing {
                                player.seek(to: seekPosition)
                                isSeeking = false
                            }
                        }
                    )
                    .frame(maxWidth: 300)
                }

                Spacer()

                // Playback controls
                HStack(spacing: 8) {
                    // Shuffle toggle
                    Button(action: { playbackQueue.toggleShuffle() }) {
                        Image(systemName: "shuffle")
                            .font(.caption)
                            .foregroundColor(playbackQueue.shuffleEnabled ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Shuffle \(playbackQueue.shuffleEnabled ? "On" : "Off")")

                    // Previous
                    Button(action: { playbackQueue.skipToPrevious() }) {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!playbackQueue.hasPrevious && playbackQueue.queue.isEmpty)
                    .help("Previous Track (⌘←)")

                    if player.isPlaying {
                        Button(action: { player.pause() }) {
                            Image(systemName: "pause.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.bordered)
                        .help("Pause")
                    } else {
                        Button(action: { player.play() }) {
                            Image(systemName: "play.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Play")
                    }

                    // Next
                    Button(action: { playbackQueue.skipToNext() }) {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!playbackQueue.hasNext && playbackQueue.queue.isEmpty)
                    .help("Next Track (⌘→)")

                    // Repeat toggle
                    Button(action: { playbackQueue.cycleRepeatMode() }) {
                        Image(systemName: repeatIcon)
                            .font(.caption)
                            .foregroundColor(playbackQueue.repeatMode != .off ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Repeat: \(playbackQueue.repeatMode.rawValue.capitalized)")

                    Button(action: { player.stop() }) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .help("Stop playback")
                }

                Spacer()

                // Up Next popover
                if !playbackQueue.upNext.isEmpty {
                    Button(action: { showUpNext.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet")
                                .font(.caption)
                            Text("\(playbackQueue.upNext.count)")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Up Next")
                    .popover(isPresented: $showUpNext) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Up Next")
                                .font(.headline)
                                .padding()

                            Divider()

                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(playbackQueue.upNext.prefix(20).enumerated()), id: \.element.id) { index, track in
                                        HStack(spacing: 8) {
                                            Text("\(index + 1)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .frame(width: 20)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(track.title)
                                                    .font(.subheadline)
                                                    .lineLimit(1)
                                                if let artist = track.artist {
                                                    Text(artist)
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Spacer()
                                            Text(formatDuration(track.duration))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 6)
                                    }
                                }
                            }
                            .frame(maxHeight: 300)
                        }
                        .frame(width: 280)
                    }
                }

                // Volume control
                HStack(spacing: 8) {
                    Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Slider(value: $player.volume, in: 0...1)
                        .frame(width: 80)
                    Text("\(Int(player.volume * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 35)
                }
                .help("Volume")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.05))
        }
        .frame(height: 90)
    }

    private var playerArtworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(
                colors: [.blue.opacity(0.6), .purple.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: 48, height: 48)
            .overlay(
                Image(systemName: "music.note")
                    .foregroundColor(.white)
            )
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
