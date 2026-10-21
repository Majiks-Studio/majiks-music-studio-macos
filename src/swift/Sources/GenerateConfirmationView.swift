import SwiftUI

struct GenerateConfirmationView: View {
    @State var parameters: BackendViewModel.MusicParameters
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onEdit: (BackendViewModel.MusicParameters) -> Void

    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        return formatter
    }()

    var body: some View {
        VStack(spacing: 20) {
            Text("Generate Music")
                .font(.title2)
                .fontWeight(.bold)

            Text("The Engineer extracted these parameters from your conversation:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                // Description Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description")
                        .font(.headline)
                    TextEditor(text: $parameters.caption)
                        .frame(minHeight: 80)
                        .font(.body)
                        .border(Color.gray.opacity(0.3))
                }

                // Lyrics Section (if present)
                if parameters.lyrics != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Lyrics")
                            .font(.headline)
                        TextEditor(text: Binding(
                            get: { parameters.lyrics ?? "" },
                            set: { parameters.lyrics = $0.isEmpty ? nil : $0 }
                        ))
                        .frame(minHeight: 100)
                        .font(.body)
                        .border(Color.gray.opacity(0.3))
                    }
                }

                // Settings Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Settings")
                        .font(.headline)
                    HStack {
                        Text("Duration:")
                        Spacer()
                        TextField("Seconds", value: $parameters.duration, formatter: numberFormatter)
                            .frame(width: 80)
                        Text("seconds")
                    }

                    HStack {
                        Text("Variants:")
                        Spacer()
                        Stepper(value: $parameters.variantCount, in: 1...5) {
                            Text("\(parameters.variantCount)")
                        }
                    }

                    HStack {
                        Text("BPM:")
                        Spacer()
                        if let bpm = parameters.bpm {
                            TextField(
                                "BPM",
                                value: Binding(
                                    get: { bpm },
                                    set: { parameters.bpm = $0 }
                                ),
                                formatter: numberFormatter
                            )
                            .frame(width: 80)
                        } else {
                            Text("Auto")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Key:")
                        Spacer()
                        if let key = parameters.key {
                            TextField(
                                "Key",
                                text: Binding(
                                    get: { key },
                                    set: { parameters.key = $0 }
                                )
                            )
                            .frame(width: 120)
                        } else {
                            Text("Auto")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button("Generate") {
                    onEdit(parameters)
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 500, height: 500)
    }
}
