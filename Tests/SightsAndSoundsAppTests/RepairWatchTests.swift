import Foundation
import SightsAndSoundsKit
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

    /// The read after queueing can fail. It used to stand in as "only this
    /// item is pending", so another item's queued repair looked done: Run
    /// fix came back for it, and it was dropped uncounted.
    @Test func aFailedReadAfterQueueingForgetsNothingElse() {
        let watch = RepairWatch()
        let a = UUID(), b = UUID()
        watch.queued(a)
        watch.enqueueFinished(a, pendingNow: [a])
        watch.queued(b)
        watch.enqueueFinishedUnread(b)
        #expect(watch.isRepairing(a), "another item's queued repair looked done")
        #expect(watch.isRepairing(b))
        #expect(watch.settle(stillFlagged: [a, b]) == 0)
    }
}

/// A repair queued before a quit has nothing draining it after relaunch:
/// a runner does not start its queue when the library opens, and Review
/// only watched the pending set, so the issue said "Repair queued" with
/// Run fix disabled until something unrelated started the queue. Watching
/// starts it, as Organise's watch does — unless tasks are paused.
@Suite @MainActor struct RepairWatchQueueTests {
    private func recipe() -> RepairRecipe {
        RepairRecipe(name: "remux", matchPattern: nil, tool: "ffmpeg",
                     argumentTemplate: ["{input}", "{output}"], estimate: "seconds")
    }

    @Test(.timeLimit(.minutes(1)))
    func watchingPendingRepairsStartsAQueueNobodyStarted() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "RepairLeftQueued")
        let runner = JobRunner(library: library)
        // Queued, and nothing drains it. Its item does not exist, so the
        // repair settles (as failed) as soon as it runs.
        let item = UUID()
        _ = try await RepairJob.enqueue(on: runner, itemID: item, recipe: recipe())

        var seen: [Set<UUID>] = []
        let watching = Task { @MainActor in
            for try await items in RepairWatch.pending(in: library, runner: runner) {
                seen.append(items)
                if items.isEmpty, seen.contains(where: { !$0.isEmpty }) { return }
            }
        }
        defer { watching.cancel() }
        for _ in 0..<400 where !(seen.last == [] && seen.contains { !$0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(seen.first == [item])
        #expect(seen.last == [], "the queued repair never ran: \(seen)")
    }

    @Test(.timeLimit(.minutes(1)))
    func watchingNeverRunsAPausedQueue() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "RepairPaused")
        let runner = JobRunner(library: library, paused: true)
        let item = UUID()
        let job = try await RepairJob.enqueue(on: runner, itemID: item, recipe: recipe())

        var seen: [Set<UUID>] = []
        let watching = Task { @MainActor in
            for try await items in RepairWatch.pending(in: library, runner: runner) { seen.append(items) }
        }
        defer { watching.cancel() }
        for _ in 0..<400 where seen.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(seen == [[item]])
        try await Task.sleep(for: .milliseconds(300))
        let state = try await library.writer.read { try JobRecord.fetchOne($0, key: job.id)?.state }
        #expect(state == .queued, "a paused queue was started")
    }
}
