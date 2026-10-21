import Testing
import Foundation
@testable import MajiksMusicStudio

// MARK: - GenerationJob Tests

@Suite("GenerationJob")
struct GenerationJobTests {

    // MARK: - Status computed properties

    @Test("isActive returns true only when generating")
    func isActive() {
        var job = Self.makeJob(status: .generating(progress: 0.5))
        #expect(job.isActive)

        job.status = .queued
        #expect(!job.isActive)

        job.status = .completed
        #expect(!job.isActive)

        job.status = .failed(message: "err")
        #expect(!job.isActive)

        job.status = .cancelled
        #expect(!job.isActive)
    }

    @Test("isPending returns true only when queued")
    func isPending() {
        var job = Self.makeJob(status: .queued)
        #expect(job.isPending)

        job.status = .generating(progress: 0.0)
        #expect(!job.isPending)

        job.status = .completed
        #expect(!job.isPending)
    }

    @Test("isFinished returns true for terminal states")
    func isFinished() {
        var job = Self.makeJob(status: .completed)
        #expect(job.isFinished)

        job.status = .failed(message: "err")
        #expect(job.isFinished)

        job.status = .cancelled
        #expect(job.isFinished)

        job.status = .queued
        #expect(!job.isFinished)

        job.status = .generating(progress: 0.3)
        #expect(!job.isFinished)
    }

    // MARK: - Helpers

    private static func makeJob(status: GenerationJobStatus = .queued) -> GenerationJob {
        GenerationJob(
            id: UUID(),
            variantId: "abcd1234",
            displayLabel: "A",
            parameters: MusicParameters(),
            sessionId: UUID(),
            status: status,
            createdAt: Date()
        )
    }
}

// MARK: - GenerationQueue Tests

@Suite("GenerationQueue")
struct GenerationQueueTests {

    // MARK: - Enqueue

    @Test("enqueue adds jobs with correct labels")
    @MainActor func enqueueAddsJobs() {
        let queue = GenerationQueue()
        let sessionId = UUID()
        let params = MusicParameters()

        let jobs = queue.enqueue(count: 3, parameters: params, sessionId: sessionId, existingVariantCount: 0)

        #expect(jobs.count == 3)
        #expect(queue.jobs.count == 3)
        #expect(jobs[0].displayLabel == "A")
        #expect(jobs[1].displayLabel == "B")
        #expect(jobs[2].displayLabel == "C")
    }

    @Test("enqueue respects existingVariantCount offset")
    @MainActor func enqueueWithOffset() {
        let queue = GenerationQueue()
        let sessionId = UUID()
        let params = MusicParameters()

        let jobs = queue.enqueue(count: 2, parameters: params, sessionId: sessionId, existingVariantCount: 3)

        #expect(jobs[0].displayLabel == "D")
        #expect(jobs[1].displayLabel == "E")
    }

    @Test("enqueue falls back to numeric label beyond Z")
    @MainActor func enqueueNumericFallback() {
        let queue = GenerationQueue()
        let params = MusicParameters()

        let jobs = queue.enqueue(count: 1, parameters: params, sessionId: UUID(), existingVariantCount: 26)

        #expect(jobs[0].displayLabel == "27")
    }

    @Test("enqueue snapshots parameters at enqueue time")
    @MainActor func enqueueSnapshotsParams() {
        let queue = GenerationQueue()
        var params = MusicParameters(bpm: 120, key: "C major", duration: 30)

        let jobs = queue.enqueue(count: 1, parameters: params, sessionId: UUID(), existingVariantCount: 0)

        // Mutating params after enqueue should not affect the job
        params.bpm = 140
        #expect(jobs[0].parameters.bpm == 120)
        #expect(queue.jobs[0].parameters.bpm == 120)
    }

    @Test("all enqueued jobs start with queued status")
    @MainActor func enqueueInitialStatus() {
        let queue = GenerationQueue()
        let jobs = queue.enqueue(count: 3, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        for job in jobs {
            #expect(job.status == .queued)
            #expect(job.isPending)
            #expect(!job.isActive)
            #expect(!job.isFinished)
        }
    }

    // MARK: - Remove

    @Test("removeJob removes a queued job")
    @MainActor func removeQueuedJob() {
        let queue = GenerationQueue()
        let jobs = queue.enqueue(count: 3, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.removeJob(jobs[1].id)

        #expect(queue.jobs.count == 2)
        #expect(queue.jobs[0].id == jobs[0].id)
        #expect(queue.jobs[1].id == jobs[2].id)
    }

    @Test("removeJob does not remove a non-queued job")
    @MainActor func removeNonQueuedJob() {
        let queue = GenerationQueue()
        let jobs = queue.enqueue(count: 2, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        // Simulate job becoming active
        queue.jobs[0].status = .generating(progress: 0.5)
        queue.removeJob(jobs[0].id)

        #expect(queue.jobs.count == 2, "Active job should not be removable")
    }

    @Test("removeJob with unknown id is a no-op")
    @MainActor func removeUnknownJob() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 1, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.removeJob(UUID())

        #expect(queue.jobs.count == 1)
    }

    // MARK: - Cancel

    @Test("cancelActiveJobs cancels the generating job")
    @MainActor func cancelActiveJobs() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 2, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        // Simulate first job becoming active
        queue.jobs[0].status = .generating(progress: 0.3)

        queue.cancelActiveJobs()

        #expect(queue.jobs[0].status == .cancelled)
        #expect(queue.jobs[0].progressMessage == "Cancelled")
        #expect(queue.jobs[1].status == .queued, "Other jobs should be unaffected")
    }

    @Test("cancelActiveJobs is a no-op when no job is active")
    @MainActor func cancelWithNoActiveJob() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 2, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.cancelActiveJobs()

        #expect(queue.jobs[0].status == .queued)
        #expect(queue.jobs[1].status == .queued)
    }

    // MARK: - Clear Completed

    @Test("clearCompleted removes finished jobs")
    @MainActor func clearCompleted() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 4, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.jobs[0].status = .completed
        queue.jobs[1].status = .failed(message: "err")
        queue.jobs[2].status = .cancelled
        // jobs[3] remains .queued

        queue.clearCompleted()

        #expect(queue.jobs.count == 1)
        #expect(queue.jobs[0].status == .queued)
    }

    @Test("clearCompleted is a no-op when no jobs are finished")
    @MainActor func clearCompletedNoOp() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 2, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.clearCompleted()

        #expect(queue.jobs.count == 2)
    }

    // MARK: - Move

    @Test("moveJob reorders jobs")
    @MainActor func moveJob() {
        let queue = GenerationQueue()
        let jobs = queue.enqueue(count: 3, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        // Move first job to position 2 (after second job)
        queue.moveJob(from: IndexSet(integer: 0), to: 2)

        #expect(queue.jobs[0].id == jobs[1].id)
        #expect(queue.jobs[1].id == jobs[0].id)
        #expect(queue.jobs[2].id == jobs[2].id)
    }

    // MARK: - Progress Updates

    @Test("updateActiveJobProgress updates the active job")
    @MainActor func updateProgress() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 2, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.jobs[0].status = .generating(progress: 0.0)

        queue.updateActiveJobProgress(progress: 0.5, stage: "Generating", message: "Step 50/100")

        #expect(queue.jobs[0].status == .generating(progress: 0.5))
        #expect(queue.jobs[0].progressMessage == "Generating: Step 50/100")
    }

    @Test("updateActiveJobProgress normalizes values over 1.0")
    @MainActor func updateProgressNormalization() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 1, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.jobs[0].status = .generating(progress: 0.0)

        // Progress of 75.0 should be normalized to 0.75
        queue.updateActiveJobProgress(progress: 75.0, stage: "", message: "75%")

        #expect(queue.jobs[0].status == .generating(progress: 0.75))
    }

    @Test("updateActiveJobProgress with only stage")
    @MainActor func updateProgressStageOnly() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 1, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.jobs[0].status = .generating(progress: 0.0)

        queue.updateActiveJobProgress(progress: 0.1, stage: "Loading", message: "")

        #expect(queue.jobs[0].progressMessage == "Loading")
    }

    @Test("updateActiveJobProgress with only message")
    @MainActor func updateProgressMessageOnly() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 1, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.jobs[0].status = .generating(progress: 0.0)

        queue.updateActiveJobProgress(progress: 0.1, stage: "", message: "Working...")

        #expect(queue.jobs[0].progressMessage == "Working...")
    }

    // MARK: - Computed Properties

    @Test("activeJob returns the generating job")
    @MainActor func activeJob() {
        let queue = GenerationQueue()
        let jobs = queue.enqueue(count: 3, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        #expect(queue.activeJob == nil)

        queue.jobs[1].status = .generating(progress: 0.0)
        #expect(queue.activeJob?.id == jobs[1].id)
    }

    @Test("pendingJobs returns only queued jobs")
    @MainActor func pendingJobs() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 3, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.jobs[0].status = .generating(progress: 0.0)
        queue.jobs[1].status = .completed

        #expect(queue.pendingJobs.count == 1)
        #expect(queue.pendingCount == 1)
    }

    @Test("completedJobs returns all finished jobs")
    @MainActor func completedJobs() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 4, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.jobs[0].status = .completed
        queue.jobs[1].status = .failed(message: "err")
        queue.jobs[2].status = .cancelled

        #expect(queue.completedJobs.count == 3)
        #expect(queue.completedCount == 1)  // Only .completed, not failed/cancelled
    }

    @Test("totalCount returns all jobs")
    @MainActor func totalCount() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 5, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        #expect(queue.totalCount == 5)
    }

    @Test("summaryText when processing")
    @MainActor func summaryTextProcessing() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 3, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.isProcessing = true
        queue.jobs[0].status = .generating(progress: 0.5)

        #expect(queue.summaryText == "1 generating, 2 queued")
    }

    @Test("summaryText when idle with results")
    @MainActor func summaryTextIdle() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 3, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.jobs[0].status = .completed
        queue.jobs[1].status = .completed
        queue.jobs[2].status = .failed(message: "err")

        #expect(queue.summaryText == "2 completed, 1 failed")
    }

    @Test("summaryText when empty")
    @MainActor func summaryTextEmpty() {
        let queue = GenerationQueue()
        #expect(queue.summaryText == "")
    }

    // MARK: - Stop Processing

    @Test("stopProcessing resets state")
    @MainActor func stopProcessing() {
        let queue = GenerationQueue()
        _ = queue.enqueue(count: 2, parameters: MusicParameters(), sessionId: UUID(), existingVariantCount: 0)

        queue.isProcessing = true
        queue.jobs[0].status = .generating(progress: 0.5)

        queue.stopProcessing()

        #expect(!queue.isProcessing)
        #expect(queue.jobs[0].status == .cancelled)
    }
}
