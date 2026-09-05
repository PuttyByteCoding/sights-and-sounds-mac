import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Run next, Retry and Clear finished — the three actions the dashboard
/// had nothing to call.
@Suite struct JobQueueControlTests {

    /// Priority decides what starts NEXT and never what stops: the
    /// runner is serialized on purpose.
    @Test func runNextReordersTheQueue() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library)
        await runner.register(ValidationJob.self)

        let first = try await runner.enqueue(ValidationJob.self)
        let second = try await runner.enqueue(ValidationJob.self)
        let third = try await runner.enqueue(ValidationJob.self)

        #expect(try await runner.runNext(third.id))
        // Two Run nexts in a row keep their relative order: the second
        // one goes in front of the first.
        #expect(try await runner.runNext(second.id))

        let order = try await library.writer.read { db in
            try JobRecord
                .filter(sql: "state = ?", arguments: [JobState.queued.rawValue])
                .order(sql: "priority DESC, createdAt, rowid")
                .fetchAll(db)
        }.map(\.id)
        #expect(order == [second.id, third.id, first.id])
    }

    @Test func runNextOnlyMovesQueuedJobs() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library)
        await runner.register(ValidationJob.self)
        let job = try await runner.enqueue(ValidationJob.self)
        try await runner.runPending()
        // Finished: there is no queue position to take.
        #expect(!(try await runner.runNext(job.id)))
    }

    /// Retrying must not rewrite history: the failure stays in the list
    /// with its error, and the retry is its own row.
    @Test func retryLeavesTheFailureInPlace() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library)
        // No registered type — the run fails and records why.
        let failed = try await runner.enqueue(FailingJob.self)
        try await runner.runPending()

        let retried = try await runner.retry(failed.id)
        #expect(retried != nil)
        #expect(retried?.id != failed.id)
        #expect(retried?.state == .queued)

        let original = try await library.writer.read { try JobRecord.fetchOne($0, key: failed.id) }
        #expect(original?.state == .failed)
        #expect(original?.error != nil)
    }

    /// Failed rows survive Clear finished — their evidence is the point.
    @Test func clearFinishedKeepsFailures() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library)
        await runner.register(ValidationJob.self)
        _ = try await runner.enqueue(ValidationJob.self)
        _ = try await runner.enqueue(FailingJob.self)
        try await runner.runPending()

        let removed = try await runner.deleteFinished()
        #expect(removed == 1)
        let left = try await library.writer.read { try JobRecord.fetchAll($0) }
        #expect(left.count == 1)
        #expect(left[0].state == .failed)
    }

    /// Pause is per runner, and it is not cancel: the running job
    /// finishes, queued work waits, enqueues still land.
    @Test func pauseHoldsTheQueueWithoutLosingIt() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library)
        await runner.register(ValidationJob.self)
        await runner.setPaused(true)
        _ = try await runner.enqueue(ValidationJob.self)

        #expect(await runner.isPaused)
        let settled = try await runner.runPending()
        #expect(settled.isEmpty)

        await runner.setPaused(false)
        #expect(try await runner.runPending().count == 1)
    }
}

/// A job kind nothing registers — the runner records the failure with a
/// reason, which is exactly the row Retry exists for.
private struct FailingJob: Job {
    static let kind = "test.failing"
    init(payload: Data?) throws {}
    func run(_ context: JobContext) async throws {}
}

/// The sweep maintenance surface: status counts and the three moves.
@Suite struct SweepMaintenanceTests {
    @Test func statusRetryAndResetBehaveForContentHashes() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Sweeps")
        let source = Source(name: "S", rootPath: "/tmp/sweeps")
        try await library.writer.write { try source.insert($0) }

        let hashed = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "a.mp4",
            contentHash: "abc", needsReview: false)
        let unhashed = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "b.mp4", needsReview: false)
        try await library.writer.write { db in
            try hashed.insert(db)
            try unhashed.insert(db)
            try ContentHashFailure(mediaItemID: unhashed.id, message: "io").insert(db)
        }

        var status = try library.contentHashStatus()
        #expect(status.missing == 1)
        #expect(status.failed == 1)

        // Retry: the failure row goes; the data stays.
        try library.retryContentHashFailures()
        status = try library.contentHashStatus()
        #expect(status.failed == 0)
        #expect(status.missing == 1)

        // Recalculate: everything is missing again, failures gone too.
        try library.resetContentHashes()
        status = try library.contentHashStatus()
        #expect(status.missing == 2)
        #expect(status.failed == 0)
    }

    @Test func metadataRetryClearsOnlyFailedMarkers() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Sweeps")
        let source = Source(name: "S", rootPath: "/tmp/sweeps")
        try await library.writer.write { try source.insert($0) }
        let good = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        let bad = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", needsReview: false)
        try await library.writer.write { db in
            try good.insert(db)
            try bad.insert(db)
        }
        try library.recordMetadataPairs(itemID: good.id, pairs: [("k", "v")])
        try library.recordMetadataPairs(itemID: bad.id, pairs: [], failure: "ffprobe failed")

        try library.retryMetadataSweepFailures()
        let status = try library.metadataSweepStatus()
        // The failed one is eligible again; the good one's marker stays.
        #expect(status.missing == 1)
        #expect(status.failed == 0)
    }
}

/// A row left in `running` when the process died is a zombie: the
/// footer shows its progress forever and enqueueUnlessPending treats
/// it as pending, so the sweep never runs again. A new runner is the
/// proof the old lane is dead, and settles such rows as failed.
@Suite struct InterruptedJobTests {

    @Test func newRunnerFailsRowsLeftRunning() async throws {
        let library = try LibraryDatabase.openInMemory()
        let zombie: JobRecord = {
            var row = JobRecord(kind: ValidationJob.kind, payload: nil)
            row.state = .running
            row.startedAt = Date()
            row.progressCurrent = 5104
            row.progressTotal = 31090
            return row
        }()
        let queued = JobRecord(kind: ValidationJob.kind, payload: nil)
        try await library.writer.write { db in
            try zombie.insert(db)
            try queued.insert(db)
        }

        let runner = JobRunner(library: library)

        let settled = try await library.writer.read { try JobRecord.fetchOne($0, key: zombie.id)! }
        #expect(settled.state == .failed)
        #expect(settled.error?.contains("interrupted") == true)
        #expect(settled.finishedAt != nil)
        #expect(settled.progressCurrent == 5104)  // evidence of how far it got survives

        let untouched = try await library.writer.read { try JobRecord.fetchOne($0, key: queued.id)! }
        #expect(untouched.state == .queued)

        // The lane is free again: the kind is no longer "pending".
        await runner.register(ValidationJob.self)
        _ = try await runner.retry(zombie.id)  // dashboard Retry still works on it
        let pending = try await library.writer.read { db in
            try JobRecord.filter(sql: "kind = ? AND state = 'queued'", arguments: [ValidationJob.kind])
                .fetchCount(db)
        }
        #expect(pending == 2)
    }
}
