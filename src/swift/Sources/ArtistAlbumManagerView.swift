import SwiftUI

// MARK: - Artist/Album Manager

struct ArtistAlbumManagerView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedArtist: String?
    @State private var showNewArtistSheet = false
    @State private var showNewAlbumSheet = false
    @State private var newArtistName = ""
    @State private var newAlbumName = ""

    var body: some View {
        NavigationStack {
            HSplitView {
                // Artists list
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Artists")
                            .font(.headline)
                        Spacer()
                        Button(action: { showNewArtistSheet = true }) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Create New Artist")
                    }
                    .padding()

                    List(library.getAllArtists(), id: \.self, selection: $selectedArtist) { artist in
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text(artist)
                                    .font(.body)
                                Text("\(library.getTracksCount(for: artist)) track(s)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tag(artist)
                    }
                }
                .frame(minWidth: 200)

                // Albums for selected artist
                if let artist = selectedArtist {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Albums by \(artist)")
                                .font(.headline)
                            Spacer()
                            Button(action: { showNewAlbumSheet = true }) {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Create New Album")
                        }
                        .padding()

                        List(library.getAllAlbums(for: artist), id: \.self) { album in
                            HStack {
                                Image(systemName: "square.stack.fill")
                                    .foregroundColor(.purple)
                                VStack(alignment: .leading) {
                                    Text(album)
                                        .font(.body)
                                    Text("\(library.getTracksCount(for: artist, album: album)) track(s)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 250)
                } else {
                    VStack {
                        Spacer()
                        Text("Select an artist to see albums")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(minWidth: 250)
                }

                // File browser
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Folder Structure")
                            .font(.headline)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(
                                nil,
                                inFileViewerRootedAtPath: FileStore.shared.audioDirectory.path
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("📁 Audio/")
                                .font(.caption.monospaced())
                            ForEach(library.getAllArtists(), id: \.self) { artist in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("  📁 \(artist)/")
                                        .font(.caption.monospaced())
                                    ForEach(library.getAllAlbums(for: artist), id: \.self) { album in
                                        Text("    📁 \(album)/")
                                            .font(.caption.monospaced())
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
                .frame(minWidth: 300)
            }
            .navigationTitle("Library Organization")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Organize All Files") {
                        library.organizeAllTracks()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(width: 800, height: 500)
        .sheet(isPresented: $showNewArtistSheet) {
            NewArtistSheet(
                artistName: $newArtistName,
                onSave: {
                    createNewArtist()
                    showNewArtistSheet = false
                },
                onCancel: {
                    newArtistName = ""
                    showNewArtistSheet = false
                }
            )
        }
        .sheet(isPresented: $showNewAlbumSheet) {
            if let artist = selectedArtist {
                NewAlbumSheet(
                    albumName: $newAlbumName,
                    artistName: artist,
                    onSave: {
                        createNewAlbum(for: artist)
                        showNewAlbumSheet = false
                    },
                    onCancel: {
                        newAlbumName = ""
                        showNewAlbumSheet = false
                    }
                )
            }
        }
    }

    func createNewArtist() {
        guard !newArtistName.isEmpty else { return }

        // Create artist folder
        let artistFolder = library.getArtistFolder(for: newArtistName)
        let singlesFolder = artistFolder.appendingPathComponent("Singles", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: singlesFolder,
            withIntermediateDirectories: true
        )

        print("[LibraryManager] Created artist: \(newArtistName)")
        newArtistName = ""
    }

    func createNewAlbum(for artist: String) {
        guard !newAlbumName.isEmpty else { return }

        // Create album folder
        let albumFolder = library.getAlbumFolder(for: artist, album: newAlbumName)

        try? FileManager.default.createDirectory(
            at: albumFolder,
            withIntermediateDirectories: true
        )

        print("[LibraryManager] Created album: \(newAlbumName) for \(artist)")
        newAlbumName = ""
    }
}

// MARK: - New Artist Sheet
