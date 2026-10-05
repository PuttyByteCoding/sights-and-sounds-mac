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
/// only looked at the pending set, so the issue said "Repair queued" with
/// Run fix disabled until something unrelated started the queue. Asking
/// how the queue stands starts it — unless tasks are paused.
@Suite @MainActor struct RepairWatchQueueTests {
    private func recipe() -> RepairRecipe {
        RepairRecipe(name: "remux", matchPattern: nil, tool: "ffmpeg",
                     argumentTemplate: ["{input}", "{output}"], estimate: "seconds")
    }

    @Test(.timeLimit(.minutes(1)))
    func askingAboutPendingRepairsStartsAQueueNobodyStarted() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "RepairLeftQueued")
        let runner = JobRunner(library: library)
        let service = LocalLibraryService(library: library, runner: runner)
        // Queued, and nothing drains it. Its item does not exist, so the
        // repair settles (as failed) as soon as it runs.
        let item = UUID()
        _ = try await RepairJob.enqueue(on: runner, itemID: item, recipe: recipe())

        // Only looking does not start it.
        #expect(try await service.repairQueue(startingQueue: false) == RepairQueue(pending: [item], isPaused: false))
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await service.repairQueue(startingQueue: false).pending == [item])

        // Asking as the Review window does, does.
        #expect(try await service.repairQueue(startingQueue: true).pending == [item])
        var pending: Set<UUID> = [item]
        for _ in 0..<400 where !pending.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
            pending = try await service.repairQueue(startingQueue: true).pending
        }
        #expect(pending.isEmpty, "the queued repair never ran")
    }

    @Test(.timeLimit(.minutes(1)))
    func askingNeverRunsAPausedQueue() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "RepairPaused")
        let runner = JobRunner(library: library, paused: true)
        let service = LocalLibraryService(library: library, runner: runner)
        let item = UUID()
        let job = try await RepairJob.enqueue(on: runner, itemID: item, recipe: recipe())

        #expect(try await service.repairQueue(startingQueue: true) == RepairQueue(pending: [item], isPaused: true))
        try await Task.sleep(for: .milliseconds(300))
        let state = try await library.writer.read { try JobRecord.fetchOne($0, key: job.id)?.state }
        #expect(state == .queued, "a paused queue was started")
        #expect(try await service.repairQueue(startingQueue: true).pending == [item])
    }

    /// Run fix, as the window does it: queued through the service, which
    /// starts the queue itself.
    @Test(.timeLimit(.minutes(1)))
    func aRepairQueuedThroughTheServiceRuns() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "RepairQueued")
        let runner = JobRunner(library: library)
        let service = LocalLibraryService(library: library, runner: runner)
        let job = try await service.queueRepair(itemID: UUID(), recipe: recipe())
        #expect(job.kind == RepairJob.kind)
        var state = JobState.queued
        for _ in 0..<400 where state == .queued || state == .running {
            try await Task.sleep(for: .milliseconds(25))
            state = try await library.writer.read { try JobRecord.fetchOne($0, key: job.id)?.state } ?? .queued
        }
        #expect(state == .failed, "its item does not exist: it runs, and fails")

        // A service made without the library's runner cannot queue one.
        let bare = LocalLibraryService(library: library)
        await #expect(throws: ServiceError.noJobRunner) {
            _ = try await bare.queueRepair(itemID: UUID(), recipe: recipe())
        }
    }
}
