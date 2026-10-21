import SwiftUI

// MARK: - Library Track Row

struct LibraryTrackRow: View {
    let track: Track
    let isSelected: Bool
    let isPlaying: Bool
    let selectionMode: Bool
    let isChecked: Bool
    var isPublished: Bool = false
    var publishedTrack: CatalogueTrack? = nil
    let onToggleSelection: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onRatingChange: (Int) -> Void
    let onAutoName: () -> Void
    let onSendToStudio: () -> Void
    let onMoveTrack: () -> Void
    /// L8: open this finished song in the Studio (DAW) as a bar-aligned stem
    /// session. Defaulted so existing call sites keep compiling.
    var onOpenInStudio: () -> Void = {}
    /// Split this song into vocals / drums / bass / other and land them in the
    /// Stems tab. Sits next to "Open in Studio" because this is where a
    /// person's finished songs are, and "break this one apart" is a thing you
    /// want about a song you are looking at — not about a song you have just
    /// generated, which was the only place it used to be offered.
    var onSeparateIntoStems: () -> Void = {}
    var isAnalyzing: Bool = false

    @State private var showPublishPopover = false

    private static let publishDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        HStack(spacing: 16) {
            // Selection checkbox (when in selection mode)
            if selectionMode {
                Button(action: onToggleSelection) {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isChecked ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }

            // Album art — routed through ArtworkDecodeCache so a body pass
            // reuses a decoded image instead of re-opening the file (577 µs
            // each, uncached). File existence is still probed first so a
            // missing file never pays a decode attempt.
            Group {
                if let customURL = track.customArtworkURL,
                   FileExistenceProbe.exists(atPath: customURL.path),
                   let nsImage = ArtworkDecodeCache.image(at: customURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    AlbumArtGenerator.generate(for: track.id.uuidString, size: 56)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
            .overlay(alignment: .bottomTrailing) {
                if isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Color.green)
                        .clipShape(Circle())
                        .offset(x: 4, y: 4)
                }
            }
            .overlay {
                if isAnalyzing {
                    ZStack {
                        Color.black.opacity(0.4)
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // Track info
            VStack(alignment: .leading, spacing: 8) {
                Text(track.title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(isSelected ? .accentColor : .primary)
                    .lineLimit(2)

                if track.artist != nil || track.album != nil {
                    HStack(spacing: 4) {
                        if let artist = track.artist, !artist.isEmpty {
                            Text(artist)
                        }
                        if let artist = track.artist, !artist.isEmpty, let album = track.album, !album.isEmpty {
                            Text("—")
                        }
                        if let album = track.album, !album.isEmpty {
                            Text(album)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }

                HStack(spacing: 10) {
                    if let bpm = track.bpm {
                        HStack(spacing: 4) {
                            Image(systemName: "metronome")
                            Text("\(Int(bpm)) BPM")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(6)
                    }
                    if let key = track.key {
                        HStack(spacing: 4) {
                            Image(systemName: "music.note.list")
                            Text(key)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.15))
                        .cornerRadius(6)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text(formatDuration(track.duration))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text(track.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                    if isPublished {
                        Button {
                            showPublishPopover = true
                        } label: {
                            Text("Published")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showPublishPopover) {
                            publishedPopoverContent
                        }
                    }
                }

                StarRatingView(rating: track.rating, isInteractive: true) { newRating in
                    onRatingChange(newRating)
                }
            }

            Spacer()

            // Control buttons
            HStack(spacing: 8) {
                if isPlaying {
                    Button(action: onPause) {
                        Image(systemName: "pause.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Menu {
                    Button(action: onEdit) {
                        Label("Edit Track Info", systemImage: "pencil")
                    }

                    Button(action: onOpenInStudio) {
                        Label("Open in Studio", systemImage: "slider.horizontal.below.rectangle")
                    }

                    Button(action: onSeparateIntoStems) {
                        Label("Split into Stems", systemImage: "wand.and.rays")
                    }

                    Button(action: onSendToStudio) {
                        Label("Send to Studio", systemImage: "waveform.badge.plus")
                    }

                    Button(action: onMoveTrack) {
                        Label("Move to Artist/Album", systemImage: "folder")
                    }

                    Button(action: onAutoName) {
                        Label("Auto-name Track", systemImage: "sparkles")
                    }

                    Button {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("AnalyzeWithEngineer"),
                            object: nil,
                            userInfo: ["trackId": track.id]
                        )
                    } label: {
                        Label("Analyze with Engineer", systemImage: "tuningfork")
                    }

                    Button(action: onCopy) {
                        Label("Duplicate Track", systemImage: "doc.on.doc")
                    }

                    Divider()

                    Button(action: onExport) {
                        Label("Export Audio File", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        NSWorkspace.shared.selectFile(
                            track.audioURL.path,
                            inFileViewerRootedAtPath: ""
                        )
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }

                    Divider()

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete Track", systemImage: "trash")
                    }

                    // Publishing actions
                    if isPublished {
                        Divider()
                        Button {
                            NotificationCenter.default.post(
                                name: NSNotification.Name("UpdatePublishedTrack"),
                                object: nil,
                                userInfo: ["trackId": track.id]
                            )
                        } label: {
                            Label("Update on majiks.online", systemImage: "arrow.triangle.2.circlepath")
                        }

                        Button(role: .destructive) {
                            NotificationCenter.default.post(
                                name: NSNotification.Name("UnpublishTrack"),
                                object: nil,
                                userInfo: ["trackId": track.id]
                            )
                        } label: {
                            Label("Unpublish", systemImage: "icloud.slash")
                        }
                    } else {
                        Divider()
                        Button {
                            NotificationCenter.default.post(
                                name: NSNotification.Name("PublishTrack"),
                                object: nil,
                                userInfo: ["trackId": track.id]
                            )
                        } label: {
                            Label("Publish to majiks.online", systemImage: "icloud.and.arrow.up")
                        }
                        Button {
                            NotificationCenter.default.post(
                                name: NSNotification.Name("StageForPublish"),
                                object: nil,
                                userInfo: ["trackId": track.id]
                            )
                        } label: {
                            Label("Add to Publish Queue", systemImage: "text.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .frame(width: 36, height: 36)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onDrag {
            let provider = NSItemProvider(object: track.id.uuidString as NSString)
            provider.suggestedName = track.title
            if let nsURL = track.audioURL as NSURL? {
                provider.registerObject(nsURL, visibility: .all)
            }
            return provider
        }
        .onTapGesture(count: 2) {
            // Double-click to edit
            onEdit()
        }
    }

    @ViewBuilder
    private var publishedPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Published on majiks.online")
                    .font(.headline)
            }

            if let ct = publishedTrack {
                if let date = ct.publishedAt {
                    LabeledContent("Published") {
                        Text(Self.publishDateFormatter.string(from: date))
                    }
                    .font(.caption)
                }
                LabeledContent("Plays") {
                    Text("\(ct.playCount)")
                }
                .font(.caption)

                Divider()

                Button {
                    let urlStr = ct.pageUrl.isEmpty
                        ? "https://majiks.online/track/\(ct.trackSlug)"
                        : ct.pageUrl
                    if let url = URL(string: urlStr) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open on majiks.online", systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Global Playback Controls
