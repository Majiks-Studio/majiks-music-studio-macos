import SwiftUI

// MARK: - Sidebar Section

private enum PublisherSection: String, CaseIterable, Identifiable {
    case publish = "Publish"
    case catalogue = "Catalogue"
    case earnings = "Earnings"
    case profiles = "Artist Profiles"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .publish: return "arrow.up.doc"
        case .catalogue: return "music.note.list"
        case .earnings: return "chart.bar"
        case .profiles: return "person.2"
        }
    }

    var tooltip: String {
        switch self {
        case .publish: return "Publish a new track"
        case .catalogue: return "Browse your published catalogue"
        case .earnings: return "View sales, earnings, and payouts"
        case .profiles: return "Manage artist profiles"
        }
    }
}

// MARK: - Publisher View

struct PublisherView: View {
    @EnvironmentObject var publisherStore: PublisherStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var backend: BackendViewModel

    @State private var selectedSection: PublisherSection? = .publish
    @State private var showTrackPicker = false
    @State private var editingCandidate: PublishCandidate?

    var body: some View {
        Group {
            if publisherStore.authState.isAuthenticated {
                authenticatedContent
            } else {
                signedOutView
            }
        }
        .onAppear {
            guard publisherStore.authState.isAuthenticated else { return }
            publisherStore.startHealthCheckTimer()
            if publisherStore.catalogueState == .idle {
                Task {
                    await publisherStore.fetchCatalogue(backend: backend, library: library)
                    if !publisherStore.profilesLoaded {
                        await publisherStore.fetchArtistProfiles(backend: backend)
                    }
                }
            }
        }
        .onDisappear {
            publisherStore.stopHealthCheckTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RefreshPublisherSection"))) { _ in
            guard publisherStore.authState.isAuthenticated else { return }
            Task {
                switch selectedSection {
                case .publish:
                    await publisherStore.fetchCatalogue(backend: backend, library: library)
                case .catalogue:
                    await publisherStore.fetchCatalogue(backend: backend, library: library)
                case .earnings:
                    await publisherStore.fetchDashboardData(backend: backend)
                case .profiles:
                    await publisherStore.fetchArtistProfiles(backend: backend)
                case .none:
                    break
                }
            }
        }
    }

    // MARK: - Authenticated Layout

    private var authenticatedContent: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailContent
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Server status banner
            if !publisherStore.serverReachable {
                serverWarningBanner
            }

            List(selection: $selectedSection) {
                SwiftUI.Section {
                    ForEach(PublisherSection.allCases) { section in
                        sidebarRow(section)
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Account status at bottom
            accountStatusView
                .padding(12)
        }
    }

    private func sidebarRow(_ section: PublisherSection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.icon)
                .frame(width: 18)
            Text(section.rawValue)
            Spacer()
            if let count = badgeCount(for: section) {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.18))
                    )
            }
        }
        .help(section.tooltip)
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .publish:
            PublishQueueView(showTrackPicker: $showTrackPicker, editingCandidate: $editingCandidate)
        case .catalogue:
            CatalogueView()
        case .earnings:
            DashboardView()
        case .profiles:
            ArtistProfilesView()
        case .none:
            PublishQueueView(showTrackPicker: $showTrackPicker, editingCandidate: $editingCandidate)
        }
    }

    // MARK: - Signed Out View

    private var signedOutView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color(red: 0.545, green: 0.361, blue: 0.965))  // #8b5cf6
            Text("Publish Your Music")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Sign in to publish, sell, and manage your tracks on majiks.online")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            UnicornSignInButton {
                publisherStore.startLogin()
            }

            // Auth error display
            if case .failed(let message) = publisherStore.authState {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        publisherStore.authState = .notAuthenticated
                    }
                    .controlSize(.small)
                }
                .padding(.top, 8)
            }

            Spacer()
        }
    }

    // MARK: - Account Status

    /// Bottom-of-sidebar account footer. This reflects the actual Keycloak
    /// session (authState is only .authenticated when a usable token
    /// exists) — server reachability is a separate concern shown by the
    /// warning banner at the top of the sidebar.
    private var accountStatusView: some View {
        HStack(spacing: 10) {
            switch publisherStore.authState {
            case .authenticated:
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signed in")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text(publisherStore.accountName ?? publisherStore.accountEmail ?? "majiks.online")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Sign Out") {
                    publisherStore.clearAuth()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Sign out of majiks.online")

            case .notAuthenticated:
                Circle()
                    .fill(.secondary)
                    .frame(width: 8, height: 8)
                Text("Not signed in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign In") {
                    publisherStore.startLogin()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .help("Sign in to your majiks.online account")

            case .failed(let message):
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer()
                Button("Retry") {
                    publisherStore.authState = .notAuthenticated
                }
                .controlSize(.mini)
            }
        }
    }

    // MARK: - Server Warning

    private var serverWarningBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("Server unreachable")
                .font(.caption2)
                .foregroundStyle(.orange)
            Spacer()
            Button("Retry") {
                Task { publisherStore.startHealthCheckTimer() }
            }
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Badge Counts

    private func badgeCount(for section: PublisherSection) -> Int? {
        switch section {
        case .publish:
            return nil
        case .catalogue:
            let count = publisherStore.catalogueTracks.count
            return count > 0 ? count : nil
        case .earnings:
            return nil
        case .profiles:
            let count = publisherStore.artistProfiles.count
            return count > 0 ? count : nil
        }
    }
}

// MARK: - Unicorn Commander Sign-In Button

/// The one big obvious sign-in button, shared by the Publisher tab's
/// signed-out state and the Settings Account section. Triggers the
/// PublisherStore Keycloak OAuth flow via the provided action.
struct UnicornSignInButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                Text("Sign in with Unicorn Commander")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(red: 0.545, green: 0.361, blue: 0.965))  // #8b5cf6
        .controlSize(.large)
        .help("Sign in to your majiks.online account with Unicorn Commander")
    }
}
