import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Move used to wait for `runPending`, which returns only when the whole
/// queue is empty. With a sweep that takes days ahead of it, the button
/// stayed disabled, with no reason given, long after the moves were done.
/// Queueing the moves returns once they are queued.
@Suite @MainActor struct OrganiseMoveTests {
    /// Holds the queue until its gate opens. A held job is suspended, not
    /// blocking a thread.
    final class Gate: @unchecked Sendable {
        static let shared = Gate()
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var hasStarted = false

        var started: Bool { lock.withLock { hasStarted } }

        func reset() { lock.withLock { isOpen = false; hasStarted = false } }

        func open() {
            let held = lock.withLock {
                isOpen = true
                defer { waiting = [] }
                return waiting
            }
            for job in held { job.resume() }
        }

        func hold() async {
            lock.withLock { hasStarted = true }
            await withCheckedContinuation { (job: CheckedContinuation<Void, Never>) in
                let goNow = lock.withLock {
                    if isOpen { return true }
                    waiting.append(job)
                    return false
                }
                if goNow { job.resume() }
            }
        }
    }

    struct LongSweep: Job {
        static let kind = "test.organise.long-sweep"
        init(payload: Data?) throws {}
        func run(_ context: JobContext) async throws { await Gate.shared.hold() }
    }

    @Test(.timeLimit(.minutes(1)))
    func movesAreQueuedWithoutWaitingForTheQueueToEmpty() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "OrganiseMove")
        let runner = JobRunner(library: library, jobTypes: JobCatalog.all + [LongSweep.self])
        let service = LocalLibraryService(library: library, runner: runner)
        Gate.shared.reset()
        defer { Gate.shared.open() }

        let sweep = try await runner.enqueue(LongSweep.self)
        await runner.startDraining()
        for _ in 0..<400 where !Gate.shared.started { try await Task.sleep(for: .milliseconds(10)) }
        try #require(Gate.shared.started)

        var queued = false
        let moving = Task { @MainActor in
            try await service.run(.reorganize(template: "%Band", itemIDs: [UUID()]), wait: .none)
            queued = true
        }
        // Correct code needs one write and a hop; the old code never
        // returned. A wide bound costs nothing on correct code.
        for _ in 0..<400 where !queued { try await Task.sleep(for: .milliseconds(25)) }
        #expect(queued, "queueing the moves waited for the sweep ahead of them")

        let jobs = try await library.writer.read { try JobRecord.fetchAll($0) }
        #expect(jobs.first { $0.id == sweep.id }?.state == .running, "the sweep ahead is still running")
        #expect(jobs.contains { $0.kind == ReorganizeJob.kind && $0.state == .queued })
        // And the window, asking, is told one is waiting.
        #expect(try await service.jobQueue(kind: ReorganizeJob.kind, startingQueue: false)
            == JobQueueState(pendingCount: 1, isPaused: false))

        Gate.shared.open()
        try await moving.value
    }

    /// A reorganize left queued by an earlier session (quit behind a long
    /// sweep) has nothing draining it after relaunch. Asking how the
    /// queue of moves stands starts it, so the window is never stuck on
    /// "Moves queued…" — unless tasks are paused, which the window says
    /// instead.
    @Test(.timeLimit(.minutes(1)))
    func askingAboutPendingMovesStartsAQueueNobodyStarted() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "OrganiseLeftQueued")
        let runner = JobRunner(library: library)
        let service = LocalLibraryService(library: library, runner: runner)
        // Queued, and nothing drains it.
        _ = try await ReorganizeJob.enqueue(on: runner, template: "%Band", itemIDs: [])

        // Only looking does not start it.
        #expect(try await service.jobQueue(kind: ReorganizeJob.kind, startingQueue: false).pendingCount == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await service.jobQueue(kind: ReorganizeJob.kind, startingQueue: false).pendingCount == 1)

        // Asking as the Organise window does, does.
        var pending = try await service.jobQueue(kind: ReorganizeJob.kind, startingQueue: true).pendingCount
        #expect(pending == 1)
        for _ in 0..<400 where pending > 0 {
            try await Task.sleep(for: .milliseconds(25))
            pending = try await service.jobQueue(kind: ReorganizeJob.kind, startingQueue: true).pendingCount
        }
        #expect(pending == 0, "the queued move never ran")
        // Another kind's queue is another count.
        #expect(try await service.jobQueue(kind: "no.such.kind", startingQueue: true).pendingCount == 0)
    }

    /// Asking starts the queue, but a paused runner stays paused: the
    /// moves wait, whatever asks after them. (The runner's drain is what
    /// holds them; this pins that asking goes through it rather than
    /// around it.)
    @Test(.timeLimit(.minutes(1)))
    func askingNeverRunsAPausedQueue() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "OrganisePaused")
        let runner = JobRunner(library: library, paused: true)
        let service = LocalLibraryService(library: library, runner: runner)
        let job = try await ReorganizeJob.enqueue(on: runner, template: "%Band", itemIDs: [])

        #expect(try await service.jobQueue(kind: ReorganizeJob.kind, startingQueue: true)
            == JobQueueState(pendingCount: 1, isPaused: true))
        try await Task.sleep(for: .milliseconds(300))
        let state = try await library.writer.read { try JobRecord.fetchOne($0, key: job.id)?.state }
        #expect(state == .queued, "a paused queue was started")
    }
}
