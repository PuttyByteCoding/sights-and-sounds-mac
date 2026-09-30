import Foundation
import Testing

@testable import SightsAndSoundsApp

/// Review's Run fix used to wait for `runPending`, which returns only when
/// the whole queue is empty — or at once when the queue is paused. Paused,
/// it counted a repair that had not run as resolved and re-enabled Run fix
/// for a second, duplicate repair; behind a long sweep it stayed disabled
/// until the sweep ended. The window now follows the queue itself.
@Suite @MainActor struct RepairWatchTests {
    @Test func aQueuedRepairHoldsItsItemUntilTheQueueHasNoRepairs() {
        let watch = RepairWatch()
        let item = UUID()
        watch.queued(item)
        #expect(watch.isRepairing(item))
        // Paused, or behind a sweep: still queued, so still held.
        #expect(!watch.pendingChanged(to: 1))
        #expect(watch.isRepairing(item), "a queued repair was let go while it waited")
        // The queue has no repairs left: reload to see what they did.
        #expect(watch.pendingChanged(to: 0))
        #expect(watch.isRepairing(item), "let go before the issues were reloaded")
    }

    @Test func onlyARepairThatClearedItsFlagCountsAsResolved() {
        let watch = RepairWatch()
        let fixed = UUID(), stubborn = UUID()
        watch.queued(fixed)
        watch.queued(stubborn)
        _ = watch.pendingChanged(to: 0)
        // The reload finds `stubborn` still flagged.
        #expect(watch.settle(stillFlagged: [stubborn]) == 1)
        #expect(!watch.isRepairing(fixed))
        #expect(!watch.isRepairing(stubborn), "another recipe must be possible for an item still flagged")
    }

    @Test func aReloadWhileRepairsAreStillQueuedSettlesNothing() {
        let watch = RepairWatch()
        let item = UUID()
        watch.queued(item)
        _ = watch.pendingChanged(to: 1)
        #expect(watch.settle(stillFlagged: []) == 0)
        #expect(watch.isRepairing(item))
    }

    @Test func aRepairThatWasNeverQueuedIsLetGo() {
        let watch = RepairWatch()
        let item = UUID(), other = UUID()
        watch.queued(item)
        watch.queued(other)
        _ = watch.pendingChanged(to: 1)
        watch.release(item)
        #expect(!watch.isRepairing(item))
        #expect(watch.isRepairing(other), "releasing one let go of another still queued")
    }

    /// Queueing and the queue's first report of it are apart in time: a
    /// reload in between (an import delivers several a second) settled the
    /// item before its repair was even counted, and Run fix came back on.
    @Test func aReloadBeforeTheQueueReportsTheRepairDoesNotSettleIt() {
        let watch = RepairWatch()
        let item = UUID()
        watch.queued(item)
        #expect(watch.settle(stillFlagged: [item]) == 0)
        #expect(watch.isRepairing(item), "settled before the queue had reported the repair")
    }
}
