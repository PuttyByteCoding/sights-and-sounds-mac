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
        Gate.shared.reset()
        defer { Gate.shared.open() }

        let sweep = try await runner.enqueue(LongSweep.self)
        await runner.startDraining()
        for _ in 0..<400 where !Gate.shared.started { try await Task.sleep(for: .milliseconds(10)) }
        try #require(Gate.shared.started)

        var queued = false
        let moving = Task { @MainActor in
            try await OrganiseMove.queue(on: runner, template: "%Band", ids: [UUID()])
            queued = true
        }
        // Correct code needs one write and a hop; the old code never
        // returned. A wide bound costs nothing on correct code.
        for _ in 0..<400 where !queued { try await Task.sleep(for: .milliseconds(25)) }
        #expect(queued, "queueing the moves waited for the sweep ahead of them")

        let jobs = try await library.writer.read { try JobRecord.fetchAll($0) }
        #expect(jobs.first { $0.id == sweep.id }?.state == .running, "the sweep ahead is still running")
        #expect(jobs.contains { $0.kind == ReorganizeJob.kind && $0.state == .queued })

        Gate.shared.open()
        _ = try await moving.value
    }

    /// A reorganize left queued by an earlier session (quit behind a long
    /// sweep) has nothing draining it after relaunch. Watching the pending
    /// moves starts the queue, so the window is never stuck on "Moves
    /// queued…" — unless tasks are paused, which the window says instead.
    @Test(.timeLimit(.minutes(1)))
    func watchingPendingMovesStartsAQueueNobodyStarted() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "OrganiseLeftQueued")
        let runner = JobRunner(library: library)
        // Queued, and nothing drains it.
        _ = try await ReorganizeJob.enqueue(on: runner, template: "%Band", itemIDs: [])

        var seen: [Int] = []
        let watching = Task { @MainActor in
            for try await count in OrganiseMove.pending(in: library, runner: runner) {
                seen.append(count)
                if count == 0, seen.contains(where: { $0 > 0 }) { return }
            }
        }
        defer { watching.cancel() }
        for _ in 0..<400 where !(seen.last == 0 && seen.contains { $0 > 0 }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(seen.first == 1)
        #expect(seen.last == 0, "the queued move never ran: \(seen)")
    }

    /// Watching starts the queue, but a paused runner stays paused: the
    /// moves wait, whatever watches them. (The runner's drain is what
    /// holds them; this pins that watching goes through it rather than
    /// around it.)
    @Test(.timeLimit(.minutes(1)))
    func watchingNeverRunsAPausedQueue() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "OrganisePaused")
        let runner = JobRunner(library: library, paused: true)
        let job = try await ReorganizeJob.enqueue(on: runner, template: "%Band", itemIDs: [])

        var seen: [Int] = []
        let watching = Task { @MainActor in
            for try await count in OrganiseMove.pending(in: library, runner: runner) { seen.append(count) }
        }
        defer { watching.cancel() }
        for _ in 0..<400 where seen.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(seen == [1])
        try await Task.sleep(for: .milliseconds(300))
        let state = try await library.writer.read { try JobRecord.fetchOne($0, key: job.id)?.state }
        #expect(state == .queued, "a paused queue was started")
    }
}
