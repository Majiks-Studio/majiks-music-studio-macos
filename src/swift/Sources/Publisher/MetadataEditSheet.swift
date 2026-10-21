import SwiftUI

// MARK: - Shared Track Metadata Form Sections

/// Reusable form sections shared between MetadataEditSheet (publish candidates)
/// and CatalogueEditSheet (published tracks). Takes bindings for all common fields.
struct TrackMetadataFormSections: View {
    @Binding var title: String
    @Binding var artist: String
    @Binding var album: String
    @Binding var genre: String
    @Binding var subgenre: String
    @Binding var description: String
    @Binding var backstory: String
    @Binding var backstoryVisibility: String
    @Binding var mood: String
    @Binding var energy: Double
    @Binding var tags: String
    @Binding var language: String
    @Binding var isExplicit: Bool
    @Binding var credits: [Credit]
    @Binding var bpmString: String
    @Binding var musicalKey: String
    @Binding var lyrics: String
    var duration: Double = 0

    var body: some View {
        // Track Information
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Track Information")

            VStack(alignment: .leading, spacing: 12) {
                LabeledField(label: "Title") {
                    HStack(spacing: 4) {
                        TextField("Track title", text: $title)
                            .textFieldStyle(.roundedBorder)
                        validationDot(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .error : .ok)
                    }
                }

                LabeledField(label: "Artist") {
                    HStack(spacing: 4) {
                        TextField("Artist name", text: $artist)
                            .textFieldStyle(.roundedBorder)
                        validationDot(artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .error : .ok)
                    }
                }

                LabeledField(label: "Album") {
                    TextField("Album name", text: $album)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledField(label: "Genre") {
                    HStack(spacing: 4) {
                        TextField("Genre", text: $genre)
                            .textFieldStyle(.roundedBorder)
                        validationDot(genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .warning : .ok)
                    }
                }
            }
        }

        Divider()

        // Additional Details
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Additional Details")

            VStack(alignment: .leading, spacing: 12) {
                LabeledField(label: "Subgenre") {
                    TextField("e.g. synthwave, acid house", text: $subgenre)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledField(label: "Description") {
                    TextEditor(text: $description)
                        .frame(minHeight: 60)
                        .font(.body)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                }

                LabeledField(label: "Backstory") {
                    TextEditor(text: $backstory)
                        .frame(minHeight: 60)
                        .font(.body)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                }

                LabeledField(label: "Mood") {
                    TextField("e.g. energetic, melancholy", text: $mood)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledField(label: "Energy") {
                    HStack {
                        Slider(value: $energy, in: 0...1)
                            .help("Set the energy level of this track (0% calm --- 100% intense)")
                        Text(String(format: "%.0f%%", energy * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 40)
                    }
                }

                LabeledField(label: "Tags") {
                    HStack(spacing: 4) {
                        TextField("comma-separated, e.g. synthwave,retro", text: $tags)
                            .textFieldStyle(.roundedBorder)
                        let tagCount = tags.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                        if tagCount > 0 {
                            Text("\(tagCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 20) {
                    LabeledField(label: "Language") {
                        TextField("en", text: $language)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }

                    Toggle("Explicit", isOn: $isExplicit)
                        .help("Mark this track as containing explicit content")

                    Picker("Backstory Visibility", selection: $backstoryVisibility) {
                        Text("Public").tag("public")
                        Text("Private").tag("private")
                        Text("Paid").tag("paid")
                    }
                    .frame(width: 200)
                    .help("Control who can see the backstory: everyone, only you, or paid listeners")

                    Spacer()
                }
            }
        }

        Divider()

        // Credits
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Credits")

            ForEach($credits) { $credit in
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
                        credits.removeAll { $0.id == credit.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                credits.append(Credit(name: "", role: "producer"))
            } label: {
                Label("Add Collaborator", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }

        Divider()

        // Music Details
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Music Details")

            HStack(spacing: 20) {
                LabeledField(label: "BPM") {
                    HStack(spacing: 4) {
                        TextField("BPM", text: $bpmString)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        if let bpm = Double(bpmString), (bpm < 20 || bpm > 300) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("BPM outside typical range (20-300)")
                        }
                    }
                }

                LabeledField(label: "Key") {
                    TextField("Key", text: $musicalKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                if duration > 0 {
                    LabeledField(label: "Duration") {
                        let mins = Int(duration) / 60
                        let secs = Int(duration) % 60
                        Text(String(format: "%d:%02d", mins, secs))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(height: 22)
                    }
                }

                Spacer()
            }
        }

        Divider()

        // Lyrics
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Lyrics")

            TextEditor(text: $lyrics)
                .frame(minHeight: 200)
                .font(.body)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
    }

    // MARK: - Validation Indicators

    private enum ValidationState {
        case ok, warning, error
    }

    @ViewBuilder
    private func validationDot(_ state: ValidationState) -> some View {
        switch state {
        case .ok:
            EmptyView()
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help("Recommended")
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .help("Required")
        }
    }
}

// MARK: - Metadata Edit Sheet (Publish Candidates)

struct MetadataEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var candidate: PublishCandidate
    let catalogueTracks: [CatalogueTrack]
    let onSave: (PublishCandidate) -> Void

    private var bpmBinding: Binding<String> {
        Binding(
            get: { candidate.bpm.map { String(Int($0)) } ?? "" },
            set: { candidate.bpm = Double($0) }
        )
    }

    private var musicalKeyBinding: Binding<String> {
        Binding(
            get: { candidate.musicalKey ?? "" },
            set: { candidate.musicalKey = $0.isEmpty ? nil : $0 }
        )
    }

    private var energyBinding: Binding<Double> {
        Binding(
            get: { candidate.energy ?? 0.5 },
            set: { candidate.energy = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Artwork preview
                    VStack(spacing: 8) {
                        if let customURL = candidate.sourceTrack.customArtworkURL,
                           let nsImage = ArtworkDecodeCache.image(at: customURL) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 160, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                        } else {
                            AlbumArtGenerator.generate(for: candidate.id.uuidString, size: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                        }
                        Text("Artwork published from Library")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Divider()

                    TrackMetadataFormSections(
                        title: $candidate.title,
                        artist: $candidate.artist,
                        album: $candidate.album,
                        genre: $candidate.genre,
                        subgenre: $candidate.subgenre,
                        description: $candidate.description,
                        backstory: $candidate.backstory,
                        backstoryVisibility: $candidate.backstoryVisibility,
                        mood: $candidate.mood,
                        energy: energyBinding,
                        tags: $candidate.tags,
                        language: $candidate.language,
                        isExplicit: $candidate.isExplicit,
                        credits: $candidate.credits,
                        bpmString: bpmBinding,
                        musicalKey: musicalKeyBinding,
                        lyrics: $candidate.lyrics,
                        duration: candidate.duration
                    )

                    if !catalogueTracks.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Variant / Remix Of")

                            Picker("Parent Track", selection: $candidate.parentTrackId) {
                                Text("None (standalone)").tag(String?.none)
                                ForEach(catalogueTracks) { track in
                                    Text("\(track.title) --- \(track.artist)")
                                        .tag(Optional(track.trackId))
                                }
                            }
                            .labelsHidden()

                            Text("If this is a remix, cover, or variant, select the original track above")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Release Scheduling")

                        Toggle("Schedule for later", isOn: Binding(
                            get: { candidate.scheduledAt != nil },
                            set: { candidate.scheduledAt = $0 ? Date().addingTimeInterval(86400) : nil }
                        ))

                        if let scheduledAt = candidate.scheduledAt {
                            DatePicker("Publish at", selection: Binding(
                                get: { scheduledAt },
                                set: { candidate.scheduledAt = $0 }
                            ), in: Date()..., displayedComponents: [.date, .hourAndMinute])

                            Text("Track will be created with scheduled visibility and auto-publish at this time")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("Track will be published immediately")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Edit Metadata")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(candidate)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(width: 600, height: 850)
    }
}
