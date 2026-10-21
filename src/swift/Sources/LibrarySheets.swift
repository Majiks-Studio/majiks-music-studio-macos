import SwiftUI

struct NewArtistSheet: View {
    @Binding var artistName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Artist")
                .font(.title2)
                .fontWeight(.bold)

            TextField("Artist Name", text: $artistName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(artistName.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(width: 400, height: 200)
    }
}

// MARK: - New Album Sheet

struct NewAlbumSheet: View {
    @Binding var albumName: String
    let artistName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Album")
                .font(.title2)
                .fontWeight(.bold)

            Text("Artist: \(artistName)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextField("Album Name", text: $albumName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(albumName.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(width: 400, height: 250)
    }
}

// MARK: - Move Track Sheet

struct MoveTrackSheet: View {
    let track: Track
    let library: LibraryStore
    @Binding var selectedArtist: String
    @Binding var selectedAlbum: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @State private var showNewArtistField = false
    @State private var showNewAlbumField = false
    @State private var newArtistName = ""
    @State private var newAlbumName = ""

    var availableArtists: [String] {
        var artists = library.getAllArtists()
        if !artists.contains("Unknown Artist") {
            artists.insert("Unknown Artist", at: 0)
        }
        return artists
    }

    var availableAlbumsForSelectedArtist: [String] {
        var albums = library.getAllAlbums(for: selectedArtist.isEmpty ? nil : selectedArtist)
        if !albums.contains("Singles") {
            albums.insert("Singles", at: 0)
        }
        return albums
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Move Track")
                .font(.title2)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 8) {
                Text("Track: \(track.title)")
                    .font(.headline)
                if let artist = track.artist, let album = track.album {
                    Text("Current Location: \(artist) / \(album)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else if let artist = track.artist {
                    Text("Current Location: \(artist) / Singles")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("Current Location: Unknown Artist / Singles")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                // Artist Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Artist")
                        .font(.headline)

                    if showNewArtistField {
                        HStack {
                            TextField("New Artist Name", text: $newArtistName)
                                .textFieldStyle(.roundedBorder)
                            Button("Cancel") {
                                showNewArtistField = false
                                newArtistName = ""
                            }
                            .buttonStyle(.bordered)
                            Button("Create") {
                                if !newArtistName.isEmpty {
                                    selectedArtist = newArtistName
                                    showNewArtistField = false
                                    newArtistName = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newArtistName.isEmpty)
                        }
                    } else {
                        HStack {
                            Picker("", selection: $selectedArtist) {
                                ForEach(availableArtists, id: \.self) { artist in
                                    Text(artist).tag(artist)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                            Button(action: {
                                showNewArtistField = true
                            }) {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Create New Artist")
                        }
                    }
                }

                // Album Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Album")
                        .font(.headline)

                    if showNewAlbumField {
                        HStack {
                            TextField("New Album Name", text: $newAlbumName)
                                .textFieldStyle(.roundedBorder)
                            Button("Cancel") {
                                showNewAlbumField = false
                                newAlbumName = ""
                            }
                            .buttonStyle(.bordered)
                            Button("Create") {
                                if !newAlbumName.isEmpty {
                                    selectedAlbum = newAlbumName
                                    showNewAlbumField = false
                                    newAlbumName = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newAlbumName.isEmpty)
                        }
                    } else {
                        HStack {
                            Picker("", selection: $selectedAlbum) {
                                ForEach(availableAlbumsForSelectedArtist, id: \.self) { album in
                                    Text(album).tag(album)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                            .disabled(selectedArtist.isEmpty)
                            Button(action: {
                                showNewAlbumField = true
                            }) {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Create New Album")
                            .disabled(selectedArtist.isEmpty)
                        }
                    }
                }
            }

            Divider()

            // Preview of new location
            VStack(spacing: 4) {
                Text("New Location:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(selectedArtist.isEmpty ? "Unknown Artist" : selectedArtist) / \(selectedAlbum.isEmpty ? "Singles" : selectedAlbum)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Move Track") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(width: 500, height: 500)
    }
}

// MARK: - Batch Operations Toolbar

struct BatchOperationsToolbar: View {
    let selectedCount: Int
    let onMoveAll: () -> Void
    let onDeleteAll: () -> Void
    let onAutoNameAll: () -> Void
    let onExportAll: () -> Void
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 16) {
                Text("\(selectedCount) track(s) selected")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                Button(action: onSelectAll) {
                    Label("Select All", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .help("Select all tracks")

                Button(action: onDeselectAll) {
                    Label("Deselect All", systemImage: "circle")
                }
                .buttonStyle(.bordered)
                .help("Deselect all tracks")

                Divider()
                    .frame(height: 20)

                Button(action: onMoveAll) {
                    Label("Move All", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .help("Move selected tracks to a different artist/album")

                Button(action: onAutoNameAll) {
                    Label("Auto-name All", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .help("Generate AI titles for selected tracks")

                Button(action: onExportAll) {
                    Label("Export Selected", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .help("Export selected tracks to a folder")

                Button(action: {
                    showDeleteConfirmation = true
                }) {
                    Label("Delete All", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Delete selected tracks from the library")
                .confirmationDialog(
                    "Delete \(selectedCount) track(s)?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        onDeleteAll()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete \(selectedCount) track(s) from your library. This action cannot be undone.")
                }
            }
            .padding()
            .background(Color.accentColor.opacity(0.1))
        }
    }
}

// MARK: - Batch Move Tracks Sheet

struct BatchMoveTracksSheet: View {
    let trackCount: Int
    let library: LibraryStore
    @Binding var selectedArtist: String
    @Binding var selectedAlbum: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @State private var showNewArtistField = false
    @State private var showNewAlbumField = false
    @State private var newArtistName = ""
    @State private var newAlbumName = ""

    var availableArtists: [String] {
        var artists = library.getAllArtists()
        if !artists.contains("Unknown Artist") {
            artists.insert("Unknown Artist", at: 0)
        }
        return artists
    }

    var availableAlbumsForSelectedArtist: [String] {
        var albums = library.getAllAlbums(for: selectedArtist.isEmpty ? nil : selectedArtist)
        if !albums.contains("Singles") {
            albums.insert("Singles", at: 0)
        }
        return albums
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Move \(trackCount) Track(s)")
                .font(.title2)
                .fontWeight(.bold)

            Text("All selected tracks will be moved to the same artist and album.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                // Artist Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Artist")
                        .font(.headline)

                    if showNewArtistField {
                        HStack {
                            TextField("New Artist Name", text: $newArtistName)
                                .textFieldStyle(.roundedBorder)
                            Button("Cancel") {
                                showNewArtistField = false
                                newArtistName = ""
                            }
                            .buttonStyle(.bordered)
                            Button("Create") {
                                if !newArtistName.isEmpty {
                                    selectedArtist = newArtistName
                                    showNewArtistField = false
                                    newArtistName = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newArtistName.isEmpty)
                        }
                    } else {
                        HStack {
                            Picker("", selection: $selectedArtist) {
                                ForEach(availableArtists, id: \.self) { artist in
                                    Text(artist).tag(artist)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                            Button(action: {
                                showNewArtistField = true
                            }) {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Create New Artist")
                        }
                    }
                }

                // Album Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Album")
                        .font(.headline)

                    if showNewAlbumField {
                        HStack {
                            TextField("New Album Name", text: $newAlbumName)
                                .textFieldStyle(.roundedBorder)
                            Button("Cancel") {
                                showNewAlbumField = false
                                newAlbumName = ""
                            }
                            .buttonStyle(.bordered)
                            Button("Create") {
                                if !newAlbumName.isEmpty {
                                    selectedAlbum = newAlbumName
                                    showNewAlbumField = false
                                    newAlbumName = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newAlbumName.isEmpty)
                        }
                    } else {
                        HStack {
                            Picker("", selection: $selectedAlbum) {
                                ForEach(availableAlbumsForSelectedArtist, id: \.self) { album in
                                    Text(album).tag(album)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                            .disabled(selectedArtist.isEmpty)
                            Button(action: {
                                showNewAlbumField = true
                            }) {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Create New Album")
                            .disabled(selectedArtist.isEmpty)
                        }
                    }
                }
            }

            Divider()

            // Preview of new location
            VStack(spacing: 4) {
                Text("New Location:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(selectedArtist.isEmpty ? "Unknown Artist" : selectedArtist) / \(selectedAlbum.isEmpty ? "Singles" : selectedAlbum)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Move \(trackCount) Track(s)") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(width: 500, height: 450)
    }
}


// MARK: - Edit Artist Sheet

struct EditArtistSheet: View {
    let originalName: String
    @Binding var editedName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Rename Artist")
                .font(.title2)
                .fontWeight(.bold)

            Text("Current name: \(originalName)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextField("New Artist Name", text: $editedName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            Text("All tracks by this artist will be updated and files will be moved.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editedName.isEmpty || editedName == originalName)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(width: 400, height: 250)
    }
}

// MARK: - Edit Album Sheet

struct EditAlbumSheet: View {
    let artistName: String
    let originalAlbumName: String
    @Binding var editedName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Rename Album")
                .font(.title2)
                .fontWeight(.bold)

            VStack(spacing: 4) {
                Text("Artist: \(artistName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Current album: \(originalAlbumName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            TextField("New Album Name", text: $editedName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            Text("All tracks in this album will be updated and files will be moved.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editedName.isEmpty || editedName == originalAlbumName)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(width: 400, height: 280)
    }
}

// MARK: - 3-Column Browser Library View
