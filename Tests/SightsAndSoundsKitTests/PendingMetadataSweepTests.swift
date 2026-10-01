import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// Tag Analysis remembered the sweep it queued only while its window was
/// open: closed and reopened while the sweep still waited, it queued
/// another (and another per reopen). A sweep of an item waiting is read
/// from the queue instead. Only a scoped sweep naming the item counts: a
/// library-wide sweep can take days, and the scoped one runs ahead of it.
@Suite struct PendingMetadataSweepTests {
    @Test func aScopedSweepOfTheItemIsFoundUntilItSettles() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library, paused: true)
        let item = UUID(), other = UUID()
        _ = try await runner.enqueueUnlessPending(MetadataSweepJob.self)
        #expect(try library.pendingMetadataSweep(of: item) == nil, "the library-wide sweep was taken for a scoped one")

        let job = try await MetadataSweepJob.enqueue(on: runner, itemIDs: [other, item])
        #expect(try library.pendingMetadataSweep(of: item) == job.id)
        #expect(try library.pendingMetadataSweep(of: UUID()) == nil)

        try await library.writer.write { db in
            try db.execute(sql: "UPDATE job SET state = ? WHERE id = ?",
                           arguments: [JobState.running.rawValue, job.id])
        }
        #expect(try library.pendingMetadataSweep(of: item) == job.id, "a running sweep is still waiting")
        try await library.writer.write { db in
            try db.execute(sql: "UPDATE job SET state = ? WHERE id = ?",
                           arguments: [JobState.succeeded.rawValue, job.id])
        }
        #expect(try library.pendingMetadataSweep(of: item) == nil)
    }
}
