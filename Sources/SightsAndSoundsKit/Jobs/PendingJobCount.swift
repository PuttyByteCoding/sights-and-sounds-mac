import Foundation
import GRDB

extension LibraryDatabase {
    /// How many jobs of `kind` are queued or running: now, and again each
    /// time that number changes. For a window whose work can wait behind
    /// a long queue — days, behind a sweep — and must say so until it ends,
    /// whether or not it changed anything. Observed, not polled: nothing
    /// runs between changes to the queue.
    public func pendingJobCounts(of kind: String) -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { try Self.pendingCount(of: kind, in: $0) }
            .removeDuplicates()
            .values(in: writer)
    }

    private static func pendingCount(of kind: String, in db: Database) throws -> Int {
        let pending = [JobState.queued.rawValue, JobState.running.rawValue]
        return try JobRecord
            .filter(Column("kind") == kind && pending.contains(Column("state")))
            .fetchCount(db)
    }
}
