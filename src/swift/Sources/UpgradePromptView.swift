import SwiftUI

/// Optional publishing/account sheet. Apps are free; no license wall, no cart.
struct UpgradePromptView: View {
    @EnvironmentObject var licenseManager: LicenseManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showLicenseEntry = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.purple)

                Text("Publishing is free")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Majiks desktop apps are free. Sign in with Unicorn Commander to publish to majiks.online — no Pro Suite key, no $29.99 cart.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                FeatureBullet(
                    icon: "arrow.up.circle.fill",
                    text: "Publish to majiks.online",
                    detail: "Included with your Unicorn Commander account"
                )

                FeatureBullet(
                    icon: "person.crop.circle.badge.checkmark",
                    text: "Artist profiles",
                    detail: "Create and manage artist identities"
                )

                FeatureBullet(
                    icon: "shield.checkered",
                    text: "Provenance certificates",
                    detail: "Cryptographic proof of first publication"
                )
            }
            .padding(.vertical, 8)

            Divider()

            VStack(spacing: 12) {
                Button {
                    showLicenseEntry = true
                } label: {
                    Text("Have a legacy license key?")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    if let url = URL(string: "https://majiks.studio/pricing") {
                        openURL(url)
                    }
                } label: {
                    Text("Pricing")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
        }
        .padding(32)
        .frame(width: 500)
        .sheet(isPresented: $showLicenseEntry) {
            LicenseEntryView(isBlocking: false)
                .environmentObject(licenseManager)
        }
    }
}

struct FeatureBullet: View {
    let icon: String
    let text: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.body)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Publisher tab empty state — sign in, do not buy a key.
struct PublisherUpgradeView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 64))
                .foregroundColor(.purple)

            Text("Sign in to publish")
                .font(.title)
                .fontWeight(.bold)

            Text("Publishing to majiks.online is free. Use your Unicorn Commander account from Settings or the Publisher tab. Desktop apps do not require a license key.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                if let url = URL(string: "https://majiks.studio/pricing") {
                    openURL(url)
                }
            } label: {
                Text("Pricing")
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    UpgradePromptView()
        .environmentObject(LicenseManager())
}
