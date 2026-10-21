import SwiftUI

struct LicenseEntryView: View {
    @EnvironmentObject var licenseManager: LicenseManager
    @Environment(\.dismiss) private var dismiss

    @State private var licenseInput: String = ""
    @State private var statusMessage: String?
    @State private var licenseActivated: Bool = false

    let isBlocking: Bool

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Legacy license key")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Optional. Apps are free — publishing uses your Unicorn Commander account. A leftover Pro Suite key still works here if you have one.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextField("MS1-aBcD12-xYz789...", text: $licenseInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()

            if let statusMessage {
                VStack(spacing: 8) {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(statusMessage.contains("✓") ? .green : .red)

                    if licenseActivated {
                        Text("Please close and restart the app for changes to take effect.")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            HStack(spacing: 12) {
                if licenseActivated {
                    // After activation, show Close button
                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    // Before activation, show Cancel/Quit and Activate
                    if isBlocking {
                        Button("Quit") {
                            NSApp.terminate(nil)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Cancel") {
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Activate") {
                        validateLicense()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(licenseInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(28)
        .frame(width: 420, height: 300)
    }

    private func validateLicense() {
        // Trim whitespace and newlines
        let trimmedKey = licenseInput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Basic format validation
        if !trimmedKey.hasPrefix("MS1-") {
            statusMessage = "✗ Invalid format. License keys start with MS1-"
            return
        }

        if trimmedKey.count < 20 {
            statusMessage = "✗ License key is too short. Check your license email."
            return
        }

        // Validate with license manager
        let ok = licenseManager.validateAndStore(key: trimmedKey)
        statusMessage = ok ? "✓ License activated successfully!" : "✗ License key not recognized. Check your email."

        if ok {
            licenseActivated = true
        }
    }
}
