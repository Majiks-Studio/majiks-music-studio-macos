import SwiftUI

// MARK: - Lyrics Editor View

struct LyricsEditorView: View {
    @Binding var lyrics: String
    @Binding var sections: [Section]
    @EnvironmentObject var backend: BackendViewModel

    @State private var selectedLine: Int?
    @State private var editingLine: String = ""

    var lyricsLines: [String] {
        lyrics.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .foregroundColor(.purple)
                    Text("Lyrics Editor")
                        .font(.headline)
                }

                Spacer()
            }
            .padding()
            .background(Color.gray.opacity(0.05))

            Divider()

            // Structure Tags Toolbar
            //
            // A WRAPPING grid, not a horizontal ScrollView. On macOS a
            // horizontal ScrollView claims the mouse-DOWN as a possible pan and
            // cancels the Button press inside it — the failure that has now
            // killed the mixer's Mute and Solo twice and the Settings tabs once.
            //
            // This row was allowlisted with the reason "each button's effect is
            // also reachable by typing the tag", and that reason was only true
            // of six of the eight buttons. "Full Template" writes a whole song
            // skeleton and "Clear Tags" strips every tag out of the lyric — a
            // person cannot type either of those, so two genuinely dead controls
            // were being filed as low-stakes.
            //
            // The chevron treatment the mixer and the Settings strip got is not
            // needed here: these are eight short chips, so an adaptive grid
            // wraps onto a second line rather than running off the edge, and
            // every chip stays on screen AND clickable at any pane width.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                Text("Tags:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    // In a tight cell an unconstrained Text wraps to one
                    // character per line; this is the toolbar-row lesson from
                    // the Studio applied to the one label in here.
                    .lineLimit(1)
                    .fixedSize()

                ForEach(["[Intro]", "[Verse]", "[Pre-Chorus]", "[Chorus]", "[Bridge]", "[Outro]"], id: \.self) { tag in
                    Button(action: { insertTag(tag) }) {
                        Text(tag)
                            .font(.caption)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                }

                Button(action: insertFullTemplate) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        Text("Full Template").lineLimit(1).fixedSize()
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                Button(action: clearAllTags) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                        Text("Clear Tags").lineLimit(1).fixedSize()
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(lyrics.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Lyrics content
            ScrollView {
                if lyrics.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(lyricsLines.enumerated()), id: \.offset) { index, line in
                            LyricsLineRow(
                                line: line,
                                lineNumber: index + 1,
                                isSelected: selectedLine == index,
                                onSelect: {
                                    selectedLine = index
                                    editingLine = line
                                },
                                onEdit: { newLine in
                                    updateLine(at: index, with: newLine)
                                }
                            )
                        }
                    }
                }
            }

            // Bottom toolbar
            if selectedLine != nil {
                Divider()
                lyricsToolbar
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(12)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.quote")
                .font(.system(size: 48))
                .foregroundColor(.gray.opacity(0.3))

            Text("No Lyrics Yet")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            Text("Generate music first, then add lyrics here")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: {
                lyrics = "Enter your lyrics here...\nLine by line\nVerse after verse"
            }) {
                Label("Start Writing", systemImage: "pencil")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var lyricsToolbar: some View {
        HStack(spacing: 12) {
            Text("Line \(selectedLine! + 1)")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()
                .frame(height: 20)

            Button(action: {
                if let index = selectedLine {
                    insertLineAfter(index: index)
                }
            }) {
                Label("Insert Line", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)

            Button(action: {
                if let index = selectedLine {
                    deleteLine(at: index)
                }
            }) {
                Label("Delete Line", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Spacer()
        }
        .padding()
        .background(Color.gray.opacity(0.05))
    }

    private func updateLine(at index: Int, with newLine: String) {
        var lines = lyricsLines
        lines[index] = newLine
        lyrics = lines.joined(separator: "\n")
    }

    private func insertLineAfter(index: Int) {
        var lines = lyricsLines
        lines.insert("New line", at: index + 1)
        lyrics = lines.joined(separator: "\n")
        selectedLine = index + 1
    }

    private func deleteLine(at index: Int) {
        var lines = lyricsLines
        lines.remove(at: index)
        lyrics = lines.joined(separator: "\n")
        selectedLine = nil
    }

    private func insertTag(_ tag: String) {
        if lyrics.isEmpty {
            lyrics = "\(tag)\n"
        } else if lyrics.hasSuffix("\n") {
            lyrics += "\(tag)\n"
        } else {
            lyrics += "\n\(tag)\n"
        }
    }

    private func insertFullTemplate() {
        let template = """
[Intro]


[Verse 1]


[Pre-Chorus]


[Chorus]


[Verse 2]


[Pre-Chorus]


[Chorus]


[Bridge]


[Chorus]


[Outro]

"""
        lyrics = template
    }

    private func clearAllTags() {
        let tags = ["[Intro]", "[Verse]", "[Verse 1]", "[Verse 2]", "[Verse 3]",
                    "[Pre-Chorus]", "[Chorus]", "[Bridge]", "[Outro]", "[Interlude]", "[Post-Chorus]"]
        var cleaned = lyrics
        for tag in tags {
            cleaned = cleaned.replacingOccurrences(of: tag, with: "")
        }
        lyrics = cleaned
    }
}

// MARK: - Lyrics Line Row

struct LyricsLineRow: View {
    let line: String
    let lineNumber: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: (String) -> Void

    @State private var isEditing = false
    @State private var editText: String = ""

    var body: some View {
        HStack(spacing: 12) {
            // Line number
            Text("\(lineNumber)")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)

            // Line content
            if isEditing {
                TextField("", text: $editText, onCommit: {
                    onEdit(editText)
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.body)
            } else {
                Text(line)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture {
                        onSelect()
                    }
                    .onTapGesture(count: 2) {
                        editText = line
                        isEditing = true
                    }
            }

            // Actions
            if isSelected && !isEditing {
                Button(action: {
                    editText = line
                    isEditing = true
                }) {
                    Image(systemName: "pencil.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .onAppear {
            editText = line
        }
    }
}

