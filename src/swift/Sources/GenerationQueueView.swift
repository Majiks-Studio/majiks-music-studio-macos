import SwiftUI

struct GenerationQueueView: View {
    let availableWidth: CGFloat
    @EnvironmentObject var generationQueue: GenerationQueue

    private var sectionColumns: [GridItem] {
        if availableWidth < 980 {
            return [GridItem(.flexible(), spacing: 12, alignment: .top)]
        }

        return [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 12, alignment: .top)]
    }

    var body: some View {
        let pending = generationQueue.pendingJobs
        let finished = generationQueue.completedJobs

        VStack(alignment: .leading, spacing: 16) {
            if availableWidth < 900 {
                compactHeader
            } else {
                regularHeader
            }

            LazyVGrid(columns: sectionColumns, alignment: .leading, spacing: 12) {
                if let activeJob = generationQueue.activeJob {
                    QueueSectionCard(
                        title: "Active",
                        systemImage: "bolt.horizontal.circle",
                        caption: "Now generating"
                    ) {
                        ActiveJobCard(job: activeJob, onCancel: {
                            generationQueue.stopProcessing()
                        })
                    }
                }

                if !pending.isEmpty {
                    QueueSectionCard(
                        title: "Pending",
                        systemImage: "clock",
                        caption: "\(pending.count) queued"
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(pending) { job in
                                PendingJobRow(job: job, onRemove: {
                                    generationQueue.removeJob(job.id)
                                })
                            }
                        }
                    }
                }

                if !finished.isEmpty {
                    QueueSectionCard(
                        title: "Finished",
                        systemImage: "checkmark.circle",
                        caption: "\(finished.count) processed"
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(finished) { job in
                                FinishedJobRow(job: job)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.08))
        )
    }

    private var regularHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .foregroundColor(.blue)
                    .font(.title3)
                Text("Generation Queue")
                    .font(.headline)
            }

            Spacer()

            if !generationQueue.summaryText.isEmpty {
                Text(generationQueue.summaryText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            headerActions
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .foregroundColor(.blue)
                    .font(.title3)
                Text("Generation Queue")
                    .font(.headline)
            }

            if !generationQueue.summaryText.isEmpty {
                Text(generationQueue.summaryText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            headerActions
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if generationQueue.isProcessing {
                Button("Cancel All") {
                    generationQueue.stopProcessing()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }

            if generationQueue.completedJobs.count > 0 {
                Button("Clear Finished") {
                    generationQueue.clearCompleted()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

private struct QueueSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let caption: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.04))
        )
    }
}

// MARK: - Active Job Card

private struct ActiveJobCard: View {
    let job: GenerationJob
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                // Variant badge
                VariantBadge(letter: job.displayLabel, color: .blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Generating Version \(job.displayLabel)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    if !job.progressMessage.isEmpty {
                        Text(job.progressMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if case .generating(let progress) = job.status {
                    Text("\(Int(progress * 100))%")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Cancel generation")
            }

            if case .generating(let progress) = job.status {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.blue.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Pending Job Row

private struct PendingJobRow: View {
    let job: GenerationJob
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundColor(.secondary)

            VariantBadge(letter: job.displayLabel, color: .gray)

            Text("Version \(job.displayLabel)")
                .font(.caption)

            Text("\(Int(job.parameters.duration))s, \(Int(job.parameters.bpm)) BPM")
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isHovered ? Color.gray.opacity(0.08) : Color.clear)
        .cornerRadius(6)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Finished Job Row

private struct FinishedJobRow: View {
    let job: GenerationJob
    @State private var showErrorDetail = false

    var body: some View {
        HStack(spacing: 8) {
            switch job.status {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            case .cancelled:
                Image(systemName: "slash.circle")
                    .font(.caption)
                    .foregroundColor(.orange)
            default:
                EmptyView()
            }

            VariantBadge(letter: job.displayLabel, color: job.status == .completed ? .green : .red)

            Text("Version \(job.displayLabel)")
                .font(.caption)

            if case .failed(let message) = job.status {
                Button {
                    showErrorDetail = true
                } label: {
                    HStack(spacing: 4) {
                        Text(message)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(1)
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundColor(.red.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
                .help("Click to view full error and copy")
                .popover(isPresented: $showErrorDetail) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Generation Error")
                            .font(.headline)
                        Text(message)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: 400)
                        HStack {
                            Button("Copy Error") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message, forType: .string)
                            }
                            .buttonStyle(.borderedProminent)
                            Spacer()
                            Button("Dismiss") { showErrorDetail = false }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .frame(minWidth: 300)
                }
            } else if job.status == .cancelled {
                Text("Cancelled")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
    }
}

// MARK: - Variant Badge

private struct VariantBadge: View {
    let letter: String
    let color: Color

    var body: some View {
        Text(letter)
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(color)
            )
    }
}
