import Foundation
import Observation

/// Which of Review's issues have a repair waiting, and what came of them.
///
/// Run fix used to wait for `runPending`, which returns only when the
/// whole queue is empty — or at once when the queue is paused. Paused, it
/// counted a repair that had not run as resolved and let Run fix queue the
/// same repair again; behind a long sweep it stayed disabled until the
/// sweep ended. This follows the queue instead: an item is held while any
/// repair is queued or running, and only a repair whose item is no longer
/// flagged afterwards counts as resolved.
@Observable
@MainActor
final class RepairWatch {
    private var awaiting: Set<UUID> = []
    private var repairsPending = false
    /// Repairs clicked but not yet in the queue. The queue's "none
    /// pending" says nothing about them, so nothing settles meanwhile.
    private var enqueuing = 0

    /// Also counts as a repair pending: the queue's own report of it
    /// comes later, and a reload in between must not settle the item.
    func queued(_ item: UUID) {
        awaiting.insert(item)
        repairsPending = true
        enqueuing += 1
    }

    /// The repair is in the queue: pending until the queue reports none.
    func enqueued(_ item: UUID) {
        enqueuing = max(0, enqueuing - 1)
        repairsPending = true
    }

    /// The repair was never queued (the enqueue failed). True when that
    /// was the last thing holding other items whose repairs are done:
    /// nothing else will ask again, so a reload is due now.
    @discardableResult
    func release(_ item: UUID) -> Bool {
        enqueuing = max(0, enqueuing - 1)
        awaiting.remove(item)
        return !repairsPending && enqueuing == 0 && !awaiting.isEmpty
    }

    /// Run fix waits for this item's repair.
    func isRepairing(_ item: UUID) -> Bool { awaiting.contains(item) }

    /// The number of queued or running repairs changed. True when none are
    /// left for items still awaited: time to reload and `settle`.
    func pendingChanged(to count: Int) -> Bool {
        repairsPending = count > 0
        return !repairsPending && enqueuing == 0 && !awaiting.isEmpty
    }

    /// After a reload: the awaited items that are no longer flagged were
    /// resolved; every awaited item is let go (one still flagged can try
    /// another recipe). Nothing is settled while repairs are still queued.
    func settle(stillFlagged: Set<UUID>) -> Int {
        guard !repairsPending, enqueuing == 0 else { return 0 }
        let resolved = awaiting.subtracting(stillFlagged).count
        awaiting.removeAll()
        return resolved
    }
}
