import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export Format

enum ExportFormat: String, CaseIterable, Identifiable {
    case wav = "WAV"
    case flac = "FLAC"
    case m4a = "M4A"

    var id: String { rawValue }

    var fileExtension: String {
        rawValue.lowercased()
    }

    var utType: UTType {
        switch self {
        case .wav: return .wav
        case .flac: return .audio
        case .m4a: return .mpeg4Audio
        }
    }
}

// MARK: - Audio File Document for Export

struct AudioFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.audio]

    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tempURL)
        self.url = tempURL
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try Data(contentsOf: url)
        return FileWrapper(regularFileWithContents: data)
    }
}

struct ExportRequest {
    let tracks: [Track]
    let format: ExportFormat
    let bitrateKbps: Int?
    let destination: URL?
}

struct ExportView: View {
    let tracks: [Track]
    let onExport: (ExportRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .wav
    @State private var bitrateKbps: Int = 256
    @State private var destinationURL: URL? = FileManager.default.homeDirectoryForCurrentUser
    @State private var showingFolderPicker = false
    @State private var isExporting = false

    private var totalDuration: Double {
        tracks.reduce(0) { $0 + $1.duration }
    }

    private var shouldShowQuality: Bool {
        format == .m4a
    }

    private var bitrateRange: ClosedRange<Double> {
        switch format {
        case .m4a:
            return 128...256
        default:
            return 256...256
        }
    }

    private var estimatedFileSizeMB: Double {
        let kbps: Double
        switch format {
        case .wav:
            kbps = 1411
        case .flac:
            kbps = 900
        case .m4a:
            kbps = Double(bitrateKbps)
        }
        let totalSeconds = max(totalDuration, 1)
        let totalKilobits = kbps * totalSeconds
        return totalKilobits / 8.0 / 1024.0
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Export Audio")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("\(tracks.count) track(s) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Format")
                        .font(.headline)

                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Export format")
                }

                if shouldShowQuality {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quality")
                            .font(.headline)

                        Slider(
                            value: Binding(
                                get: { Double(bitrateKbps) },
                                set: { bitrateKbps = Int($0) }
                            ),
                            in: bitrateRange,
                            step: 1
                        )
                        .accessibilityLabel("Audio quality")
                        .accessibilityValue("\(bitrateKbps) kilobits per second")
                        Text("\(bitrateKbps) kbps")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Destination")
                        .font(.headline)

                    HStack {
                        Text(destinationURL?.path ?? "Choose a destination folder")
                            .font(.caption)
                            .foregroundColor(destinationURL == nil ? .secondary : .primary)
                            .lineLimit(1)

                        Spacer()

                        Button("Choose...") {
                            showingFolderPicker = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(isExporting)
                        .accessibilityLabel("Choose export destination folder")
                    }
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Format: \(format.rawValue)")
                        if shouldShowQuality {
                            Text("Quality: \(bitrateKbps) kbps")
                        }
                        Text("Estimated Size: \(String(format: "%.1f", estimatedFileSizeMB)) MB")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Color.gray.opacity(0.08))
                    .cornerRadius(8)
                }
            }

            if isExporting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing export...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isExporting)

                Button("Export") {
                    isExporting = true
                    let request = ExportRequest(
                        tracks: tracks,
                        format: format,
                        bitrateKbps: shouldShowQuality ? bitrateKbps : nil,
                        destination: destinationURL
                    )
                    onExport(request)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty || isExporting)
            }
        }
        .padding(28)
        .frame(width: 520, height: 520)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                destinationURL = urls.first
            case .failure:
                break
            }
        }
        .onChange(of: format) { _, newValue in
            if newValue == .m4a && bitrateKbps < 128 {
                bitrateKbps = 128
            }
        }
    }
}
