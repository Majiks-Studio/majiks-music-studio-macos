import SwiftUI

// MARK: - Track Picker Sheet

struct TrackPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let library: LibraryStore
    let onSelect: ([Track]) -> Void

    @State private var selectedIds: Set<UUID> = []
    @State private var searchText: String = ""

    private var filteredTracks: [Track] {
        if searchText.isEmpty {
            return library.tracks
        }
        let query = searchText.lowercased()
        return library.tracks.filter {
            $0.title.lowercased().contains(query) ||
            ($0.artist?.lowercased().contains(query) ?? false) ||
            ($0.genre?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Tracks to Publish")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(selectedIds.count) selected")
                    .foregroundStyle(.secondary)
            }
            .padding()

            TextField("Search tracks...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            List(filteredTracks, selection: $selectedIds) { track in
                HStack {
                    VStack(alignment: .leading) {
                        Text(track.title)
                            .font(.headline)
                        HStack(spacing: 8) {
                            if let artist = track.artist, !artist.isEmpty {
                                Text(artist).font(.caption).foregroundStyle(.secondary)
                            }
                            if let genre = track.genre, !genre.isEmpty {
                                Text(genre).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer()
                    if track.rating > 0 {
                        HStack(spacing: 1) {
                            ForEach(0..<track.rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                }
                .tag(track.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add \(selectedIds.count) Track\(selectedIds.count == 1 ? "" : "s")") {
                    let selected = library.tracks.filter { selectedIds.contains($0.id) }
                    onSelect(selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedIds.isEmpty)
            }
            .padding()
        }
        .frame(width: 600, height: 500)
    }
}
