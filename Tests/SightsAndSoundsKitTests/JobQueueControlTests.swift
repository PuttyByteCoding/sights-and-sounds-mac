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
