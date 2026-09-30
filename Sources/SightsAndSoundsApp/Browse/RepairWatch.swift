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

    func queued(_ item: UUID) { awaiting.insert(item) }

    /// The repair was never queued (the enqueue failed).
    func release(_ item: UUID) { awaiting.remove(item) }

    /// Run fix waits for this item's repair.
    func isRepairing(_ item: UUID) -> Bool { awaiting.contains(item) }

    /// The number of queued or running repairs changed. True when none are
    /// left for items still awaited: time to reload and `settle`.
    func pendingChanged(to count: Int) -> Bool {
        repairsPending = count > 0
        return !repairsPending && !awaiting.isEmpty
    }

    /// After a reload: the awaited items that are no longer flagged were
    /// resolved; every awaited item is let go (one still flagged can try
    /// another recipe). Nothing is settled while repairs are still queued.
    func settle(stillFlagged: Set<UUID>) -> Int {
        guard !repairsPending else { return 0 }
        let resolved = awaiting.subtracting(stillFlagged).count
        awaiting.removeAll()
        return resolved
    }
}
