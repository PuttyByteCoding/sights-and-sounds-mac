import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The generic job abstraction, end to end: state machine, progress
/// persistence, failure capture, unknown kinds, cancellation.
@Suite struct JobRunnerTests {

    /// Counts to a payload-specified total, reporting progress and honoring
    /// cancellation between steps.
    private struct CountingJob: Job {
        static let kind = "test.counting"
        let total: Int

        init(payload: Data?) throws {
            total = payload.flatMap { try? JSONDecoder().decode(Int.self, from: $0) } ?? 3
        }

        func run(_ context: JobContext) async throws {
            for step in 1...total {
                try await context.checkCancellation()
                await context.reportProgress(current: step, total: total)
            }
        }
    }

    private struct ExplodingJob: Job {
        static let kind = "test.exploding"
        init(payload: Data?) throws {}
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        func run(_ context: JobContext) async throws { throw Boom() }
    }

    private func makeRunner() throws -> (LibraryDatabase, JobRunner) {
        let library = try LibraryDatabase.openInMemory()
        return (library, JobRunner(library: library))
    }

    private func record(_ library: LibraryDatabase, _ id: UUID) throws -> JobRecord {
        try library.writer.read { try JobRecord.fetchOne($0, key: id)! }
    }

    @Test func successPathTransitionsAndTimestamps() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(CountingJob.self)
        let queued = try await runner.enqueue(CountingJob.self, payload: try JSONEncoder().encode(5))
        #expect(queued.state == .queued)

        try await runner.runPending()

        let done = try record(library, queued.id)
        #expect(done.state == .succeeded)
        #expect(done.startedAt != nil)
        #expect(done.finishedAt != nil)
        #expect(done.progressCurrent == 5)
        #expect(done.progressTotal == 5)
        #expect(done.error == nil)
    }

    @Test func failureIsCapturedNotThrown() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(ExplodingJob.self)
        let queued = try await runner.enqueue(ExplodingJob.self)

        try await runner.runPending()

        let failed = try record(library, queued.id)
        #expect(failed.state == .failed)
        #expect(failed.error?.contains("boom") == true)
        #expect(failed.finishedAt != nil)
    }

    @Test func unknownKindFailsCleanly() async throws {
        let (library, runner) = try makeRunner()
        // Enqueue a kind, then "forget" to register it.
        let queued = try await runner.enqueue(CountingJob.self)

        try await runner.runPending()

        let failed = try record(library, queued.id)
        #expect(failed.state == .failed)
        #expect(failed.error?.contains("test.counting") == true)
    }

    @Test func cancelBeforeStartSkipsExecution() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(CountingJob.self)
        let queued = try await runner.enqueue(CountingJob.self)
        await runner.requestCancel(queued.id)

        try await runner.runPending()

        let cancelled = try record(library, queued.id)
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.startedAt == nil)
    }

    @Test func jobsRunOldestFirstAndDrainCompletely() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(CountingJob.self)
        var ids: [UUID] = []
        for _ in 0..<3 {
            ids.append(try await runner.enqueue(CountingJob.self).id)
        }

        let settled = try await runner.runPending()
        #expect(settled == ids)
        for id in ids {
            #expect(try record(library, id).state == .succeeded)
        }
    }

    @Test func failedJobRowSurvivesForInspection() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(ExplodingJob.self)
        _ = try await runner.enqueue(ExplodingJob.self)
        try await runner.runPending()

        let failures = try await library.writer.read { db in
            try JobRecord.filter(sql: "state = ?", arguments: [JobState.failed.rawValue]).fetchAll(db)
        }
        #expect(failures.count == 1)
    }
}
