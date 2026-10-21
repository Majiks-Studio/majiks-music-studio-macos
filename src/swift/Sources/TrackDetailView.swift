import SwiftUI
import UniformTypeIdentifiers

// MARK: - Comprehensive Track Detail/Edit View

struct TrackDetailView: View {
    @State private var editedTrack: Track
    let onSave: (Track) -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    let onSendToStudio: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var backend: BackendViewModel
    @EnvironmentObject private var publisherStore: PublisherStore

    @State private var showDeleteConfirmation = false
    @State private var artStudioAvailable = false
    @State private var isGeneratingArtwork = false
    @State private var albumArtSeed: String
    @State private var exportError: String?
    @State private var showExportError = false
    @State private var showSyncPrompt = false

    init(track: Track, onSave: @escaping (Track) -> Void, onExport: @escaping () -> Void, onDelete: @escaping () -> Void, onSendToStudio: @escaping () -> Void) {
        _editedTrack = State(initialValue: track)
        _albumArtSeed = State(initialValue: track.id.uuidString)
        self.onSave = onSave
        self.onExport = onExport
        self.onDelete = onDelete
        self.onSendToStudio = onSendToStudio
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Album Art Section
                    VStack(spacing: 12) {
                        if let customURL = editedTrack.customArtworkURL,
                           let nsImage = ArtworkDecodeCache.image(at: customURL) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 240, height: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                                .accessibilityLabel("Custom artwork for \(editedTrack.title)")
                        } else {
                            AlbumArtGenerator.generate(for: albumArtSeed, size: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                                .accessibilityLabel("Generated artwork for \(editedTrack.title)")
                        }

                        HStack(spacing: 8) {
                            Button(action: chooseArtwork) {
                                Label("Choose Artwork...", systemImage: "photo")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)

                            if editedTrack.customArtworkFileName != nil {
                                Button(action: removeArtwork) {
                                    Label("Remove", systemImage: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .accessibilityLabel("Remove custom artwork")
                            } else {
                                Button(action: regenerateAlbumArt) {
                                    Label("Regenerate", systemImage: "arrow.clockwise")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Regenerate album art")
                            }

                            Button {
                                isGeneratingArtwork = true
                                Task {
                                    do {
                                        let (imagePath, _) = try await backend.generateTrackArtwork(
                                            trackId: editedTrack.id.uuidString,
                                            title: editedTrack.title,
                                            artist: editedTrack.artist ?? "",
                                            album: editedTrack.album,
                                            genre: editedTrack.genre
                                        )
                                        if !imagePath.isEmpty {
                                            let url = URL(fileURLWithPath: imagePath)
                                            let artworkDir = FileStore.shared.artworkDirectory
                                            let dest = artworkDir.appendingPathComponent("track-\(editedTrack.id.uuidString)\(url.pathExtension.isEmpty ? ".png" : ".\(url.pathExtension)")")
                                            try? FileManager.default.copyItem(at: url, to: dest)
                                            editedTrack.customArtworkFileName = dest.lastPathComponent
                                        }
                                    } catch {
                                        AppLog.error("Art Studio generation failed: \(error)")
                                    }
                                    isGeneratingArtwork = false
                                }
                            } label: {
                                if isGeneratingArtwork {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Generate with Art Studio", systemImage: "paintbrush")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.purple)
                            .disabled(!artStudioAvailable || isGeneratingArtwork)
                            .help(artStudioAvailable ? "Generate artwork using Majik's Art Studio" : "Art Studio not running")
                        }
                    }

                    Divider()

                    // Track Information
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Track Information")

                        VStack(alignment: .leading, spacing: 12) {
                            LabeledField(label: "Title") {
                                TextField("Track title", text: $editedTrack.title)
                                    .textFieldStyle(.roundedBorder)
                            }

                            LabeledField(label: "Artist") {
                                AutocompleteTextField(
                                    placeholder: "Artist name",
                                    text: Binding(
                                        get: { editedTrack.artist ?? "" },
                                        set: { editedTrack.artist = $0.isEmpty ? nil : $0 }
                                    ),
                                    suggestions: library.getAllArtists().filter {
                                        $0 != "Working Files"
                                    }
                                )
                            }
                            .zIndex(2)

                            LabeledField(label: "Album") {
                                AutocompleteTextField(
                                    placeholder: "Album name",
                                    text: Binding(
                                        get: { editedTrack.album ?? "" },
                                        set: { editedTrack.album = $0.isEmpty ? nil : $0 }
                                    ),
                                    suggestions: library.getAllAlbums(for: editedTrack.artist).filter {
                                        $0 != "Unsorted"
                                    }
                                )
                            }
                            .zIndex(1)

                            LabeledField(label: "Genre") {
                                TextField("Genre", text: Binding(
                                    get: { editedTrack.genre ?? "" },
                                    set: { editedTrack.genre = $0.isEmpty ? nil : $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                            }

                            LabeledField(label: "Rating") {
                                StarRatingView(rating: editedTrack.rating, isInteractive: true) { newRating in
                                    editedTrack.rating = newRating
                                }
                                .accessibilityLabel("Rating")
                                .accessibilityValue("\(editedTrack.rating) out of 5 stars")
                                .accessibilityHint("Tap to change rating")
                            }
                        }
                    }

                    Divider()

                    // Music Details
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Music Details")

                        HStack(spacing: 20) {
                            LabeledField(label: "BPM") {
                                TextField("BPM", value: Binding(
                                    get: { editedTrack.bpm ?? 0 },
                                    set: { editedTrack.bpm = $0 == 0 ? nil : $0 }
                                ), format: .number)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            }

                            LabeledField(label: "Key") {
                                TextField("Key", text: Binding(
                                    get: { editedTrack.key ?? "" },
                                    set: { editedTrack.key = $0.isEmpty ? nil : $0 }
                                ))
                                .frame(width: 120)
                                .textFieldStyle(.roundedBorder)
                            }

                            Spacer()
                        }
                    }

                    Divider()

                    // Credits
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Binding(
                                get: { editedTrack.credits ?? [] },
                                set: { editedTrack.credits = $0.isEmpty ? nil : $0 }
                            )) { $credit in
                                HStack(spacing: 8) {
                                    TextField("Name", text: $credit.name)
                                        .textFieldStyle(.roundedBorder)

                                    TextField("Display Name", text: $credit.displayName)
                                        .textFieldStyle(.roundedBorder)
                                        .help("Public display name (optional)")

                                    Picker("Role", selection: $credit.role) {
                                        ForEach(Credit.standardRoles, id: \.self) { role in
                                            Text(role.capitalized).tag(role)
                                        }
                                    }
                                    .frame(width: 150)

                                    Button {
                                        var current = editedTrack.credits ?? []
                                        current.removeAll { $0.id == credit.id }
                                        editedTrack.credits = current.isEmpty ? nil : current
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Button {
                                var current = editedTrack.credits ?? []
                                current.append(Credit(name: "", role: "producer"))
                                editedTrack.credits = current
                            } label: {
                                Label("Add Collaborator", systemImage: "plus.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                    } label: {
                        SectionHeader(title: "Credits")
                    }

                    Divider()

                    // Description/Caption
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Description")

                        TextEditor(text: $editedTrack.caption)
                            .frame(minHeight: 100)
                            .font(.body)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .accessibilityLabel("Track description")
                    }

                    Divider()

                    // Lyrics
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Lyrics")

                        TextEditor(text: Binding(
                            get: { editedTrack.lyrics ?? "" },
                            set: { editedTrack.lyrics = $0.isEmpty ? nil : $0 }
                        ))
                        .frame(minHeight: 200)
                        .font(.body)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .accessibilityLabel("Lyrics")
                    }

                    Divider()

                    // Generation Settings (Read-only)
                    if let params = editedTrack.generationParams {
                        VStack(alignment: .leading, spacing: 16) {
                            SectionHeader(title: "Generation Settings")

                            VStack(alignment: .leading, spacing: 8) {
                                InfoRow(label: "Model", value: params.model ?? "Unknown")
                                InfoRow(label: "LM Model", value: params.lmModel ?? "Unknown")
                                InfoRow(label: "Guidance Scale", value: params.guidanceScale.map { String(format: "%.1f", $0) } ?? "—")
                                InfoRow(label: "Variants", value: params.variantCount.map { "\($0)" } ?? "—")
                                if let style = editedTrack.originalPrompt, !style.isEmpty {
                                    InfoRow(label: "Original Prompt", value: style)
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }

                        Divider()
                    }

                    // File Information (Read-only)
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "File Information")

                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Duration", value: formatDuration(editedTrack.duration))
                            InfoRow(label: "Created", value: formatDate(editedTrack.createdAt))
                            InfoRow(label: "File", value: editedTrack.audioFileName)
                            InfoRow(label: "Path", value: editedTrack.audioURL.path)
                            if let isrc = editedTrack.isrc, !isrc.isEmpty {
                                HStack {
                                    Text("ISRC:")
                                        .fontWeight(.medium)
                                    Text(ISRCHelper.formatISRC(isrc))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(isrc, forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy ISRC to clipboard")
                                    Spacer()
                                }
                                .padding(.vertical, 2)
                            } else {
                                InfoRow(label: "ISRC", value: "(assigned on publish)")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    // Actions
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Button(action: {
                                onSendToStudio()
                                dismiss()
                            }) {
                                Label("Send to Studio", systemImage: "waveform")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button(action: {
                                onExport()
                                dismiss()
                            }) {
                                Label("Export", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                NSWorkspace.shared.selectFile(
                                    editedTrack.audioURL.path,
                                    inFileViewerRootedAtPath: ""
                                )
                            } label: {
                                Label("Show in Finder", systemImage: "folder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        Button(action: exportMetadata) {
                            Label("Export Metadata as JSON", systemImage: "doc.text")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive, action: {
                            showDeleteConfirmation = true
                        }) {
                            Label("Delete Track", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                .padding(24)
            }
            .navigationTitle("Track Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(editedTrack)
                        // Check if this track is published and prompt for sync
                        if publisherStore.isTrackPublished(editedTrack.id) {
                            showSyncPrompt = true
                        } else {
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .alert("Update on majiks.online?", isPresented: $showSyncPrompt) {
                Button("Not Now") { dismiss() }
                Button("Update Server") {
                    if let catalogueTrack = publisherStore.catalogueTrackForLibraryTrack(editedTrack.id) {
                        Task {
                            await publisherStore.pushLocalMetadataToServer(
                                editedTrack,
                                catalogueTrack: catalogueTrack,
                                backend: backend
                            )
                        }
                    }
                    dismiss()
                }
            } message: {
                Text("This track is published. Would you like to push your changes to majiks.online?")
            }
            .alert("Delete Track?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            } message: {
                Text("This action cannot be undone. The audio file will be moved to the trash.")
            }
            .alert("Export Failed", isPresented: $showExportError) {
                Button("OK", role: .cancel) { }
            } message: {
                if let error = exportError {
                    Text(error)
                }
            }
        }
        .frame(width: 600, height: 800)
        .onAppear {
            Task {
                do {
                    let (available, _) = try await backend.checkArtStudioHealth()
                    artStudioAvailable = available
                } catch {
                    artStudioAvailable = false
                }
            }
        }
    }

    private func regenerateAlbumArt() {
        // Generate a new random seed based on current time
        albumArtSeed = UUID().uuidString
    }

    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        panel.message = "Choose custom artwork for this track"

        if panel.runModal() == .OK, let url = panel.url {
            library.setTrackArtwork(editedTrack.id, imageURL: url)
            // Refresh the track to pick up the new artwork filename
            if let updated = library.tracks.first(where: { $0.id == editedTrack.id }) {
                editedTrack.customArtworkFileName = updated.customArtworkFileName
            }
        }
    }

    private func removeArtwork() {
        library.setTrackArtwork(editedTrack.id, imageURL: nil)
        editedTrack.customArtworkFileName = nil
    }

    private func exportMetadata() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(editedTrack.title)_metadata.json"
        panel.message = "Export track metadata to JSON file"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try library.exportTrackMetadata(track: editedTrack, to: url)
            } catch {
                exportError = "Failed to export metadata: \(error.localizedDescription)"
                showExportError = true
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Helper Views

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.secondary)
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            content()
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label + ":")
                .fontWeight(.medium)
            Text(value)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
