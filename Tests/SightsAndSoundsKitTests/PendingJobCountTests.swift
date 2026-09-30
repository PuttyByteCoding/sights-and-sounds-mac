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

    /// Which items have a repair queued or running, from the queue itself:
    /// a window that keeps its own note of what it queued forgets it when
    /// it is rebuilt (Review swaps to the player and back), and then offered
    /// Run fix again for a repair still waiting.
    @Test(.timeLimit(.minutes(1)))
    func theItemsWithARepairWaitingFollowTheQueue() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library, paused: true)
        var items = library.pendingRepairItems().makeAsyncIterator()
        #expect(try await items.next() == [])

        let item = UUID()
        let recipe = RepairRecipe(
            name: "remux", matchPattern: nil, tool: "ffmpeg",
            argumentTemplate: ["{input}", "{output}"], estimate: "seconds")
        let job = try await RepairJob.enqueue(on: runner, itemID: item, recipe: recipe)
        #expect(try await items.next() == [item])

        try await library.writer.write { db in
            try db.execute(sql: "UPDATE job SET state = ? WHERE id = ?",
                           arguments: [JobState.succeeded.rawValue, job.id])
        }
        #expect(try await items.next() == [])
    }
}
