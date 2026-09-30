import Foundation
import Testing

@testable import SightsAndSoundsApp

/// Review's Run fix used to wait for `runPending`, which returns only when
/// the whole queue is empty — or at once when the queue is paused — and
/// then kept its own record of what it queued, which had races and was
/// forgotten when the window was rebuilt. The queue is the truth now.
@Suite @MainActor struct RepairWatchTests {
    @Test func anItemIsHeldFromTheClickUntilTheQueueHasNoRepairForIt() {
        let watch = RepairWatch()
        let item = UUID()
        watch.queued(item)
        #expect(watch.isRepairing(item), "free between the click and the queue")
        watch.enqueueFinished(item, pendingNow: [item])
        #expect(watch.isRepairing(item))
        // Paused, or behind a sweep: still in the queue, still held.
        #expect(!watch.pendingChanged(to: [item]))
        #expect(watch.isRepairing(item))
        // Done: reload to see what it did.
        #expect(watch.pendingChanged(to: []))
        #expect(!watch.isRepairing(item))
    }

    /// Rebuilt while a repair waits: the queue still says so.
    @Test func aFreshWatchKnowsWhatTheQueueHolds() {
        let watch = RepairWatch()
        let item = UUID()
        watch.pendingChanged(to: [item])
        #expect(watch.isRepairing(item), "a rebuilt window offered Run fix for a repair still queued")
    }

    @Test func onlyARepairThatClearedItsFlagCountsAsResolved() {
        let watch = RepairWatch()
        let fixed = UUID(), stubborn = UUID()
        for item in [fixed, stubborn] {
            watch.queued(item)
            watch.enqueueFinished(item, pendingNow: [fixed, stubborn])
        }
        watch.pendingChanged(to: [])
        #expect(watch.settle(stillFlagged: [stubborn]) == 1)
        #expect(watch.settle(stillFlagged: []) == 0, "counted twice")
    }

    /// Nothing done yet settles nothing — whatever reloads meanwhile.
    @Test func aReloadWhileRepairsWaitSettlesNothing() {
        let watch = RepairWatch()
        let a = UUID(), b = UUID()
        watch.queued(a)
        #expect(watch.settle(stillFlagged: [a]) == 0, "settled while still being queued")
        watch.enqueueFinished(a, pendingNow: [a])
        watch.queued(b)
        #expect(watch.settle(stillFlagged: []) == 0)
        #expect(watch.isRepairing(a) && watch.isRepairing(b))
    }

    /// A repair queued and already done by the time the enqueue returns:
    /// not held on a guess, and counted.
    @Test func aRepairDoneBeforeItsEnqueueReturnedIsNotHeld() {
        let watch = RepairWatch()
        let item = UUID()
        watch.queued(item)
        watch.enqueueFinished(item, pendingNow: [])
        #expect(!watch.isRepairing(item))
        #expect(watch.settle(stillFlagged: []) == 1)
    }

    /// A failed enqueue lets its item go, and nothing else.
    @Test func aFailedEnqueueLetsOnlyItsItemGo() {
        let watch = RepairWatch()
        let a = UUID(), b = UUID()
        watch.queued(a)
        watch.enqueueFinished(a, pendingNow: [a])
        watch.queued(b)
        watch.enqueueFinished(b, pendingNow: nil)
        #expect(!watch.isRepairing(b))
        #expect(watch.isRepairing(a))
        #expect(watch.settle(stillFlagged: []) == 0, "the failed one counted as resolved")
    }
}
