import SwiftUI

struct FirstRunSetupView: View {
    @EnvironmentObject var llmSettings: LLMProviderSettings
    @Environment(\.dismiss) var dismiss

    @State private var setupComplete = false
    @State private var aceStepDetected = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    // Fallback if icon not found
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundColor(.blue)
                }

                Text("Welcome to Majik's Music Studio")
                    .font(.title)
                    .bold()

                Text("Let's get you set up in 30 seconds")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                SetupStepRow(
                    icon: aceStepDetected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    title: "ACE-Step Detection",
                    status: aceStepDetected
                        ? "Found at \(llmSettings.aceStepPath)"
                        : "Not found - needs manual setup",
                    color: aceStepDetected ? .green : .orange
                )

                SetupStepRow(
                    icon: llmSettings.primaryProvider == .mlxLocal ? "checkmark.circle.fill" : "circle",
                    title: "LLM Provider",
                    status: llmSettings.primaryProvider == .mlxLocal ? "Local MLX (free)" : "Needs configuration",
                    color: llmSettings.primaryProvider == .mlxLocal ? .green : .gray
                )

                SetupStepRow(
                    icon: setupComplete ? "checkmark.circle.fill" : "circle",
                    title: "Ready to Generate",
                    status: setupComplete ? "All set!" : "Complete setup above",
                    color: setupComplete ? .green : .gray
                )
            }
            .padding()
            .background(Color(.windowBackgroundColor))
            .cornerRadius(12)

            // Helpful note
            if !aceStepDetected {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("Next Steps:")
                            .font(.headline)
                    }

                    Text("1. Install ACE-Step 1.5 from GitHub\n2. Configure your LLM provider in Settings\n3. Start creating music!")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }

            Spacer()

            HStack(spacing: 12) {
                if !aceStepDetected {
                    Button("Manual Setup") {
                        NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }

                Button(setupComplete ? "Start Creating Music" : "Skip for Now") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!setupComplete && aceStepDetected)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(32)
        .frame(width: 500, height: 450)
        .onAppear {
            // Attempt auto-detection on first run.
            aceStepDetected = llmSettings.autoDetectACEStep()
            setupComplete = aceStepDetected && llmSettings.primaryProvider == .mlxLocal
        }
    }
}

struct SetupStepRow: View {
    let icon: String
    let title: String
    let status: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}
