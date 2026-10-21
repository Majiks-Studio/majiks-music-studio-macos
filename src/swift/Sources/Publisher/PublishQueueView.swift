import SwiftUI

// MARK: - Publish Queue View

struct PublishQueueView: View {
    @EnvironmentObject var publisherStore: PublisherStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var backend: BackendViewModel
    @Binding var showTrackPicker: Bool
    @Binding var editingCandidate: PublishCandidate?

    @State private var showPreflightSheet = false
    @State private var preflightResults: [PreflightResult] = []
    @State private var showLibraryImport = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                trackToolbar
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                Divider()

                if publisherStore.isPublishing {
                    batchProgressBar
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    Divider()
                }

                if showLibraryImport && !publisherStore.candidates.isEmpty {
                    libraryImportBrowser
                        .frame(maxHeight: 200)
                        .padding(.horizontal)
                    Divider()
                }

                if publisherStore.candidates.isEmpty {
                    emptyState
                } else {
                    candidateList
                }
            }
            .frame(minHeight: 150)

            queueInfoPanel
                .frame(minHeight: 80)
        }
        .sheet(isPresented: $showPreflightSheet) {
            PreflightSheet(results: preflightResults) {
                showPreflightSheet = false
                Task { await publisherStore.publishAll(backend: backend, library: library) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PublishSelected"))) { _ in
            let candidates = publisherStore.candidates.filter {
                !$0.status.isPublished && !$0.status.isInProgress && !$0.status.isDuplicateWarning
            }
            guard !candidates.isEmpty && !publisherStore.isPublishing else { return }
            preflightResults = candidates.map { $0.preflightCheck() }
            if preflightResults.contains(where: { $0.hasErrors || $0.hasWarnings }) {
                showPreflightSheet = true
            } else {
                Task { await publisherStore.publishAll(backend: backend, library: library) }
            }
        }
    }

    // MARK: - Batch Progress Bar

    private var batchProgressBar: some View {
        let total = publisherStore.candidates.count
        let completed = publisherStore.candidates.filter { $0.status.isPublished }.count
        let failed = publisherStore.candidates.filter { $0.status.isFailed }.count
        let progress = total > 0 ? Double(completed) / Double(total) : 0

        return VStack(spacing: 4) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Publishing progress")
                .accessibilityValue("\(completed) of \(total) published")

            HStack(spacing: 12) {
                if let trackName = publisherStore.currentPublishingTrackName {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(trackName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                }

                if let step = publisherStore.currentPublishingStep {
                    Text(step)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .fixedSize()
                }

                Spacer()

                Text("\(completed)/\(total) published")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()

                if failed > 0 {
                    Text("\(failed) failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize()
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Track Toolbar

    private var trackToolbar: some View {
        HStack(spacing: 12) {
            Button {
                let starred = library.tracks.filter { $0.rating > 0 }
                publisherStore.addCandidates(from: starred)
            } label: {
                Label("Add Starred Tracks", systemImage: "star.fill")
            }
            .help("Add all rated tracks from your library to the publish queue")

            Button {
                showTrackPicker = true
            } label: {
                Label("Pick Tracks...", systemImage: "plus.circle")
            }
            .help("Choose specific tracks from your library to publish")

            Button {
                showLibraryImport.toggle()
            } label: {
                Label("Import from Library", systemImage: "square.and.arrow.down")
            }
            .help("Browse and import tracks from your library with all metadata")

            if !publisherStore.artistProfiles.isEmpty {
                Picker("Profile", selection: $publisherStore.selectedProfileId) {
                    Text("No Profile").tag(String?.none)
                    ForEach(publisherStore.artistProfiles) { profile in
                        Text(profile.artistName).tag(Optional(profile.id))
                    }
                }
                .frame(maxWidth: 180)
                .help("Select which artist profile to publish under")
            }

            // ACE Music sharing
            Button {
                // Coming soon — waiting on API auth confirmation
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "music.note.house")
                    Text("Share to ACE Music")
                    Text("Coming Soon")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .help("Share your music on acemusic.ai — coming soon!")

            Spacer()

            // Retry Failed button
            if publisherStore.candidates.contains(where: { $0.status.isFailed }) {
                Button {
                    publisherStore.retryFailed()
                } label: {
                    Label("Retry Failed", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .help("Reset failed tracks to try again")
            }

            if publisherStore.candidates.contains(where: { $0.status.isPublished }) {
                Button("Clear Published") {
                    publisherStore.clearCompleted()
                }
                .controlSize(.small)
                .help("Remove successfully published tracks from the queue")
            }

            let unpublishedCount = publisherStore.candidates.filter {
                !$0.status.isPublished && !$0.status.isInProgress && !$0.status.isDuplicateWarning
            }.count

            Button {
                // Run pre-flight check before publishing
                let candidates = publisherStore.candidates.filter {
                    !$0.status.isPublished && !$0.status.isInProgress && !$0.status.isDuplicateWarning
                }
                preflightResults = candidates.map { $0.preflightCheck() }

                if preflightResults.contains(where: { $0.hasErrors || $0.hasWarnings }) {
                    showPreflightSheet = true
                } else {
                    // All clean — publish immediately
                    Task { await publisherStore.publishAll(backend: backend, library: library) }
                }
            } label: {
                Label("Publish All (\(unpublishedCount))", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(unpublishedCount == 0 || publisherStore.isPublishing)
            .help("Run pre-flight checks and publish all queued tracks")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Publish Your Music")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Add tracks from your library using the buttons above or the Library context menu")
                } icon: {
                    Text("1").font(.caption.bold()).frame(width: 22, height: 22)
                        .background(Color.blue).foregroundStyle(.white).clipShape(Circle())
                }
                Label {
                    Text("Review and edit metadata, set artist profile, and choose a parent track")
                } icon: {
                    Text("2").font(.caption.bold()).frame(width: 22, height: 22)
                        .background(Color.blue).foregroundStyle(.white).clipShape(Circle())
                }
                Label {
                    Text("Publish to majiks.online where fans can discover and buy your music")
                } icon: {
                    Text("3").font(.caption.bold()).frame(width: 22, height: 22)
                        .background(Color.blue).foregroundStyle(.white).clipShape(Circle())
                }
            }
            .font(.body)
            .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button {
                    let starred = library.tracks.filter { $0.rating > 0 }
                    publisherStore.addCandidates(from: starred)
                } label: {
                    Label("Add Starred Tracks", systemImage: "star.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showTrackPicker = true
                } label: {
                    Label("Pick Tracks...", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)

                Button {
                    showLibraryImport.toggle()
                } label: {
                    Label("Import from Library", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .help("Browse your library and import tracks with all metadata pre-filled")
            }

            // Inline library browser for quick import
            if showLibraryImport {
                libraryImportBrowser
                    .frame(maxHeight: 250)
                    .padding(.horizontal)
            }

            Spacer()
        }
    }

    // MARK: - Library Import Browser

    private var libraryImportBrowser: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Library Tracks")
                    .font(.headline)
                Spacer()
                Text("\(library.tracks.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if library.tracks.isEmpty {
                Text("No tracks in library yet. Generate some music first!")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                List {
                    ForEach(library.tracks) { track in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.body)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    if let artist = track.artist, !artist.isEmpty {
                                        Text(artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let genre = track.genre, !genre.isEmpty {
                                        Text(genre)
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(.secondary.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                    if let bpm = track.bpm {
                                        Text("\(Int(bpm)) BPM")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
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
                            Button("Add") {
                                publisherStore.addCandidates(from: [track])
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .disabled(publisherStore.candidates.contains { $0.id == track.id })
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.controlBackgroundColor)))
    }

    // MARK: - Candidate List

    private var candidateList: some View {
        List {
            ForEach(publisherStore.candidates) { candidate in
                CandidateRow(candidate: candidate) {
                    editingCandidate = candidate
                } onPublish: {
                    Task { await publisherStore.publishSingle(candidate, backend: backend, library: library) }
                } onPublishAnyway: {
                    Task { await publisherStore.publishAnywaySkippingDuplicateCheck(candidate, backend: backend, library: library) }
                } onRemove: {
                    publisherStore.removeCandidate(candidate)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Queue Info Panel

    private var queueInfoPanel: some View {
        let total = publisherStore.candidates.count
        let published = publisherStore.candidates.filter { $0.status.isPublished }.count
        let failed = publisherStore.candidates.filter { $0.status.isFailed }.count
        let pending = total - published - failed

        return VStack(alignment: .leading, spacing: 12) {
            Text("Queue Summary")
                .font(.headline)

            if total > 0 {
                HStack(spacing: 20) {
                    statLabel("\(total)", subtitle: "Total")
                    statLabel("\(pending)", subtitle: "Pending", color: .blue)
                    statLabel("\(published)", subtitle: "Published", color: .green)
                    if failed > 0 {
                        statLabel("\(failed)", subtitle: "Failed", color: .red)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                tipRow(icon: "star.fill", text: "Rate tracks in your Library to quickly add them with 'Add Starred Tracks'")
                tipRow(icon: "pencil", text: "Click the pencil icon to edit metadata before publishing")
                tipRow(icon: "arrow.up.circle.fill", text: "Pre-flight checks run automatically before batch publishing")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding()
        .background(Color(.windowBackgroundColor))
    }

    @ViewBuilder
    private func statLabel(_ value: String, subtitle: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .frame(width: 14)
            Text(text)
        }
    }
}

// MARK: - Pre-flight Sheet

struct PreflightSheet: View {
    let results: [PreflightResult]
    let onProceed: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var hasErrors: Bool { results.contains { $0.hasErrors } }
    private var errorCount: Int { results.filter { $0.hasErrors }.count }
    private var warningCount: Int { results.filter { !$0.hasErrors && $0.hasWarnings }.count }
    private var cleanCount: Int { results.filter { $0.isClean }.count }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: hasErrors ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(hasErrors ? .red : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Pre-publish Check")
                        .font(.headline)
                    Text(hasErrors
                         ? "\(errorCount) track\(errorCount == 1 ? "" : "s") with errors must be fixed before publishing"
                         : "\(warningCount) track\(warningCount == 1 ? " has" : "s have") warnings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 16) {
                    if cleanCount > 0 {
                        Label("\(cleanCount) ready", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if warningCount > 0 {
                        Label("\(warningCount) warning\(warningCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if errorCount > 0 {
                        Label("\(errorCount) error\(errorCount == 1 ? "" : "s")", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding()

            Divider()

            // Results list
            List {
                ForEach(results.filter { !$0.isClean }) { result in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: result.hasErrors ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.hasErrors ? .red : .orange)
                            Text(result.title)
                                .font(.headline)
                                .lineLimit(1)
                        }

                        ForEach(result.issues) { issue in
                            HStack(spacing: 6) {
                                issueIcon(issue.severity)
                                Text(issue.field)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text(issue.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(.leading, 22)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if !hasErrors {
                    Button("Publish Anyway") {
                        dismiss()
                        onProceed()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Text("Fix errors before publishing")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 400)
    }

    @ViewBuilder
    private func issueIcon(_ severity: PreflightSeverity) -> some View {
        switch severity {
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .info:
            Image(systemName: "info.circle.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
        }
    }
}

// MARK: - Candidate Row

struct CandidateRow: View {
    let candidate: PublishCandidate
    let onEdit: () -> Void
    let onPublish: () -> Void
    let onPublishAnyway: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Status indicator
                statusIcon
                    .frame(width: 24)

                // Artwork thumbnail
                Group {
                    if let customURL = candidate.sourceTrack.customArtworkURL,
                       let nsImage = ArtworkDecodeCache.image(at: customURL) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        AlbumArtGenerator.generate(for: candidate.id.uuidString, size: 44)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Track info
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if !candidate.artist.isEmpty {
                            Text(candidate.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !candidate.genre.isEmpty {
                            Text(candidate.genre)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        if let bpm = candidate.bpm {
                            Text("\(Int(bpm)) BPM")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let key = candidate.musicalKey, !key.isEmpty {
                            Text(key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Inline validation indicators
                    preflightIndicators
                }

                Spacer()

                // Status badge
                statusBadge

                // Actions
                if !candidate.status.isInProgress {
                    if candidate.status.isDuplicateWarning {
                        Button { onPublishAnyway() } label: {
                            Label("Publish Anyway", systemImage: "arrow.up.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Skip duplicate check and publish")
                    } else if !candidate.status.isPublished {
                        Button { onEdit() } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit \(candidate.title) metadata")
                        .help("Edit metadata")

                        Button { onPublish() } label: {
                            Image(systemName: "arrow.up.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Publish \(candidate.title)")
                        .help("Publish this track")
                    }

                    // Only offered when the track is actually LIVE. It used to
                    // be offered for any accepted track, so a scheduled one got
                    // a "view on the site" button pointing at a page that does
                    // not exist yet. `trackURL` is the single place that rule
                    // lives now, so the button and the status cannot disagree.
                    if let link = candidate.status.trackURL {
                        Button {
                            if let url = URL(string: link) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "safari")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Open \(candidate.title) on majiks.online")
                        .help("Open on majiks.online")
                    }

                    Button { onRemove() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(candidate.title) from queue")
                    .help("Remove from queue")
                }
            }
            .padding(.vertical, 6)

            // Expanded duplicate warning details
            if case .duplicateWarning(let matches) = candidate.status {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio fingerprint matches found:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)

                    ForEach(matches) { match in
                        HStack(spacing: 6) {
                            Image(systemName: "waveform.badge.exclamationmark")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("\"\(match.title)\"")
                                .font(.caption)
                                .fontWeight(.medium)
                            if !match.artist.isEmpty {
                                Text("by \(match.artist)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(Int(match.similarity * 100))% similar")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.orange.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    Text("If this is a remix or new version, you can safely publish anyway.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 36)
                .padding(.top, 4)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Inline Preflight Indicators

    @ViewBuilder
    private var preflightIndicators: some View {
        let result = candidate.preflightCheck()
        if !result.isClean && !candidate.status.isPublished && !candidate.status.isInProgress {
            HStack(spacing: 6) {
                ForEach(result.issues) { issue in
                    HStack(spacing: 2) {
                        switch issue.severity {
                        case .error:
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        case .warning:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        case .info:
                            Image(systemName: "info.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        Text(issue.field)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch candidate.status {
        case .unpublished:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Unpublished")
        case .converting, .fingerprinting, .checkingDuplicates:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Processing")
        case .duplicateWarning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Duplicate warning")
        case .readyToPublish:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.blue)
                .accessibilityLabel("Ready to publish")
        case .uploading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Uploading")
        case .published(_, _, let scheduledAt):
            // A scheduled track gets a CLOCK, not the live track's green tick.
            // From a sofa the icon is read before the text, so two different
            // outcomes must not share one glyph.
            if scheduledAt == nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Published")
            } else {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Scheduled, not yet on the site")
            }
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Failed")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(candidate.status.statusText)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
            .help(statusHelpText)
    }

    /// The badge is a small capsule, so a long failure — the raw body of a
    /// server refusal, say — has nowhere to go. The tooltip used to be empty for
    /// everything except a duplicate warning, which meant the one status a
    /// person most needs to read in full was the one they could not hover.
    private var statusHelpText: String {
        if case .failed(let message) = candidate.status { return message }
        return duplicateHelpText
    }

    private var duplicateHelpText: String {
        guard case .duplicateWarning(let matches) = candidate.status else { return "" }
        return matches.map { match in
            let pct = Int(match.similarity * 100)
            let artist = match.artist.isEmpty ? "" : " by \(match.artist)"
            return "\(pct)% similar to \"\(match.title)\"\(artist)"
        }.joined(separator: "\n")
    }

    private var statusColor: Color {
        switch candidate.status {
        case .unpublished: return .secondary
        case .converting, .fingerprinting, .checkingDuplicates, .uploading: return .blue
        case .duplicateWarning: return .orange
        case .readyToPublish: return .blue
        // Green means "it is on the site". A scheduled track is not, so it
        // takes the same amber the other not-done-yet states use.
        case .published(_, _, let scheduledAt): return scheduledAt == nil ? .green : .orange
        case .failed: return .red
        }
    }
}
