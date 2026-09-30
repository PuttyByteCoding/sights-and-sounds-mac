import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// A window that queued work behind a long queue must be able to say so
/// for as long as the work waits — days, behind a sweep — and to stop
/// saying so when it ends, whether or not it changed anything.
@Suite struct PendingJobCountTests {
    @Test(.timeLimit(.minutes(1)))
    func theCountFollowsTheQueueForOneKind() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library, paused: true)
        var counts = library.pendingJobCounts(of: ReorganizeJob.kind).makeAsyncIterator()
        #expect(try await counts.next() == 0)

        let job = try await ReorganizeJob.enqueue(on: runner, template: "%Band", itemIDs: [])
        #expect(try await counts.next() == 1)

        // Another kind does not count.
        _ = try await runner.enqueue(ThumbnailBatchJob.self)
        try await library.writer.write { db in
            try db.execute(sql: "UPDATE job SET state = ? WHERE id = ?",
                           arguments: [JobState.running.rawValue, job.id])
        }
        try await library.writer.write { db in
            try db.execute(sql: "UPDATE job SET state = ? WHERE id = ?",
                           arguments: [JobState.succeeded.rawValue, job.id])
        }
        #expect(try await counts.next() == 0, "a finished run still counted, or another kind did")
    }

    /// The count once, for a caller that must not wait for a change the
    /// observation may never deliver (a run that is queued and done inside
    /// one delivery reads as no change).
    @Test func theCountCanBeReadOnce() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library, paused: true)
        #expect(try library.pendingJobCount(of: ReorganizeJob.kind) == 0)
        _ = try await ReorganizeJob.enqueue(on: runner, template: "%Band", itemIDs: [])
        #expect(try library.pendingJobCount(of: ReorganizeJob.kind) == 1)
    }
}
