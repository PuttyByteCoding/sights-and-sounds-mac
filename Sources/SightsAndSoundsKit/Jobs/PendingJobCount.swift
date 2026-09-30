import Foundation
import GRDB

extension LibraryDatabase {
    /// How many jobs of `kind` are queued or running: now, and again each
    /// time that number changes. For a window whose work can wait behind
    /// a long queue — days, behind a sweep — and must say so until it ends,
    /// whether or not it changed anything. Observed, not polled: nothing
    /// runs between changes to the queue.
    public func pendingJobCounts(of kind: String) -> AsyncValueObservation<Int> {
        let pending = [JobState.queued.rawValue, JobState.running.rawValue]
        return ValueObservation
            .tracking { db in
                try JobRecord
                    .filter(Column("kind") == kind && pending.contains(Column("state")))
                    .fetchCount(db)
            }
            .removeDuplicates()
            .values(in: writer)
    }
}
