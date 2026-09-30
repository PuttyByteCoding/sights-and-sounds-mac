import Foundation
import Observation

/// Which of Review's issues have a repair waiting, and what came of them.
///
/// Run fix used to wait for `runPending`, which returns only when the
/// whole queue is empty — or at once when the queue is paused — and a
/// window-local record of what it queued then had races of its own, and
/// was forgotten when the window was rebuilt (Review swaps to the player
/// and back). The queue is the truth now: an item is repairing while it
/// has a repair queued or running (`pending`, observed), or while its
/// Run fix click is still being queued (`enqueuing`). Only a repair queued
/// from here whose item is no longer flagged afterwards counts as
/// resolved.
@Observable
@MainActor
final class RepairWatch {
    /// From the queue.
    private var pending: Set<UUID> = []
    /// Clicked, not yet in the queue.
    private var enqueuing: Set<UUID> = []
    /// Queued from this window: counted once their repairs are done.
    private var watched: Set<UUID> = []

    func isRepairing(_ item: UUID) -> Bool {
        pending.contains(item) || enqueuing.contains(item)
    }

    func queued(_ item: UUID) {
        enqueuing.insert(item)
        watched.insert(item)
    }

    /// The enqueue returned. On success `pendingNow` is the queue read
    /// after it committed, applied in the same step that ends the click's
    /// own hold, so the item is never shown free while its repair waits —
    /// and a repair queued and already done is not held on a guess.
    func enqueueFinished(_ item: UUID, pendingNow: Set<UUID>?) {
        if let pendingNow { pending = pendingNow } else { watched.remove(item) }
        enqueuing.remove(item)
    }

    /// The enqueue committed but the queue could not be read afterwards:
    /// the item joins what is already known to be pending — standing in
    /// for the whole set, it made other items' queued repairs look done.
    /// The observation corrects it on its next delivery.
    func enqueueFinishedUnread(_ item: UUID) {
        pending.insert(item)
        enqueuing.remove(item)
    }

    /// The queue's set changed. True when a repair queued from here has
    /// finished: time to reload and `settle`.
    @discardableResult
    func pendingChanged(to items: Set<UUID>) -> Bool {
        pending = items
        return !finished.isEmpty
    }

    /// After a reload: repairs queued from here that are done count as
    /// resolved if their item is no longer flagged, and are let go.
    func settle(stillFlagged: Set<UUID>) -> Int {
        let done = finished
        watched.subtract(done)
        return done.subtracting(stillFlagged).count
    }

    private var finished: Set<UUID> {
        watched.filter { !pending.contains($0) && !enqueuing.contains($0) }
    }
}
