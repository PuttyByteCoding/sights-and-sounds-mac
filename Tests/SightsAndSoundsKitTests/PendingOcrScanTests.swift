import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The player's text panel kept its own note of the scans it queued, and
/// lost it whenever the drawer closed: reopened, it offered Scan again for
/// a scan still waiting, and a second click queued a second full pass.
/// Whether a scan of an item waits is read from the queue instead.
@Suite struct PendingOcrScanTests {
    @Test func aScanWaitingForTheItemIsFoundUntilItSettles() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library, paused: true)
        let item = UUID(), other = UUID()
        #expect(try library.pendingOcrScan(of: item) == nil)

        let job = try await OcrJob.enqueue(on: runner, itemID: item)
        #expect(try library.pendingOcrScan(of: item) == job.id)
        #expect(try library.pendingOcrScan(of: other) == nil, "another item's scan was taken for this one")

        try await library.writer.write { db in
            try db.execute(sql: "UPDATE job SET state = ? WHERE id = ?",
                           arguments: [JobState.running.rawValue, job.id])
        }
        #expect(try library.pendingOcrScan(of: item) == job.id, "a running scan is still waiting")

        try await library.writer.write { db in
            try db.execute(sql: "UPDATE job SET state = ? WHERE id = ?",
                           arguments: [JobState.succeeded.rawValue, job.id])
        }
        #expect(try library.pendingOcrScan(of: item) == nil)
    }
}
