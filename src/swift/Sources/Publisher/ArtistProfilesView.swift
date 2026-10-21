import SwiftUI

// MARK: - Artist Profiles View

struct ArtistProfilesView: View {
    @EnvironmentObject var publisherStore: PublisherStore
    @EnvironmentObject var backend: BackendViewModel
    @State private var editingProfile: ArtistProfile?
    @State private var showNewProfileSheet = false
    @State private var profileToDelete: ArtistProfile?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Text("Artist Profiles")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Text("\(publisherStore.artistProfiles.count)/\(publisherStore.maxArtists) profiles")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await publisherStore.fetchArtistProfiles(backend: backend) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh artist profiles")

                Button {
                    showNewProfileSheet = true
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.545, green: 0.361, blue: 0.965))
                .disabled(publisherStore.artistProfiles.count >= publisherStore.maxArtists)
                .help("Create a new artist profile")
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            Divider()

            if publisherStore.artistProfiles.isEmpty {
                emptyState
            } else {
                profileList
            }
        }
        .onAppear {
            if !publisherStore.profilesLoaded {
                Task { await publisherStore.fetchArtistProfiles(backend: backend) }
            }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditSheet(profile: profile) { updated in
                Task { await publisherStore.updateArtistProfile(updated, backend: backend) }
            }
        }
        .sheet(isPresented: $showNewProfileSheet) {
            NewProfileSheet { name in
                Task { await publisherStore.createArtistProfile(name: name, backend: backend) }
            }
        }
        .alert("Delete Profile", isPresented: Binding(
            get: { profileToDelete != nil },
            set: { if !$0 { profileToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { profileToDelete = nil }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    Task { await publisherStore.deleteArtistProfile(profile, backend: backend) }
                }
                profileToDelete = nil
            }
        } message: {
            if let profile = profileToDelete {
                Text("Are you sure you want to delete the profile \"\(profile.artistName)\"? Tracks using this profile must be reassigned first.")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            if publisherStore.profilesLoaded {
                Text("No artist profiles")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Create a profile to publish tracks under a specific artist name")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Button("Create Profile") {
                    showNewProfileSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.545, green: 0.361, blue: 0.965))
                .help("Create your first artist profile")
            } else {
                Text("Loading profiles...")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Profile List

    private var profileList: some View {
        List {
            ForEach(publisherStore.artistProfiles) { profile in
                profileRow(profile)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func profileRow(_ profile: ArtistProfile) -> some View {
        HStack(spacing: 16) {
            // Artist avatar
            ZStack {
                Circle()
                    .fill(Color(red: 0.545, green: 0.361, blue: 0.965).opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(String(profile.artistName.prefix(1)).uppercased())
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(red: 0.545, green: 0.361, blue: 0.965))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.artistName)
                        .font(.headline)
                    if publisherStore.selectedProfileId == profile.id {
                        Text("Active")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color(red: 0.545, green: 0.361, blue: 0.965).opacity(0.15))
                            .foregroundStyle(Color(red: 0.545, green: 0.361, blue: 0.965))
                            .clipShape(Capsule())
                    }
                }
                if !profile.website.isEmpty {
                    Text(profile.website)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !profile.socialLinks.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(profile.socialLinks.keys.sorted().prefix(3)), id: \.self) { platform in
                            Text(platform.capitalized)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Spacer()

            if publisherStore.selectedProfileId != profile.id {
                Button("Select") {
                    publisherStore.selectedProfileId = profile.id
                }
                .controlSize(.small)
                .help("Set as active artist profile")
            }

            Button { editingProfile = profile } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit profile")

            Button { profileToDelete = profile } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete profile")
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Profile Edit Sheet

struct ProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: ArtistProfile
    let onSave: (ArtistProfile) -> Void

    @State private var newLinkKey: String = ""
    @State private var newLinkValue: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Artist Identity
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Artist Identity")

                        LabeledField(label: "Artist Name") {
                            TextField("Artist name", text: $profile.artistName)
                                .textFieldStyle(.roundedBorder)
                        }

                        LabeledField(label: "Website") {
                            TextField("https://yoursite.com", text: $profile.website)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    Divider()

                    // Social Links
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Social Links")

                        if profile.socialLinks.isEmpty && newLinkKey.isEmpty {
                            Text("No social links added yet")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        ForEach(Array(profile.socialLinks.keys.sorted()), id: \.self) { key in
                            HStack(spacing: 8) {
                                Text(key.capitalized)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .frame(width: 80, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                                TextField("URL", text: Binding(
                                    get: { profile.socialLinks[key] ?? "" },
                                    set: { profile.socialLinks[key] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                Button {
                                    profile.socialLinks.removeValue(forKey: key)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this social link")
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("Platform", text: $newLinkKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .font(.caption)
                            TextField("URL", text: $newLinkValue)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                            Button {
                                let key = newLinkKey.trimmingCharacters(in: .whitespaces).lowercased()
                                let value = newLinkValue.trimmingCharacters(in: .whitespaces)
                                guard !key.isEmpty, !value.isEmpty else { return }
                                profile.socialLinks[key] = value
                                newLinkKey = ""
                                newLinkValue = ""
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.borderless)
                            .disabled(newLinkKey.trimmingCharacters(in: .whitespaces).isEmpty)
                            .help("Add social link")
                        }
                    }

                    Divider()

                    // Profile Info
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Profile Info")
                        InfoRow(label: "Profile ID", value: profile.id)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(24)
            }
            .navigationTitle("Edit Artist Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .help("Discard changes and close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(profile)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(profile.artistName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Save profile changes")
                }
            }
        }
        .frame(width: 550, height: 500)
    }
}

// MARK: - New Profile Sheet

struct NewProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var artistName: String = ""
    let onCreate: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Artist Profile")
                .font(.title2)
                .fontWeight(.semibold)

            LabeledContent("Artist Name") {
                TextField("Enter artist name", text: $artistName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            Text("You can add website and social links after creating the profile.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel profile creation")
                Spacer()
                Button("Create") {
                    onCreate(artistName.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(artistName.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Create the artist profile")
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 400, height: 200)
    }
}
