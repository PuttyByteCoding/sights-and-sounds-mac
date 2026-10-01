import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// A panel that queued one scan waited for `runPending`, which returns only
/// when the whole queue is empty: behind a library-wide sweep, Tag Analysis
/// stayed loading, its buttons disabled, for as long as the sweep ran. A
/// caller waits for its own jobs now, and the queue is started for it.
@Suite struct JobWaitTests {
    /// Holds a job until its gate opens; suspended, not blocking a thread.
    final class Gate: @unchecked Sendable {
        static let shared = Gate()
        private let lock = NSLock()
        private var isOpen = false
        private var hasStarted = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

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

    /// Runs until the shared gate opens.
    struct LongSweep: Job {
        static let kind = "test.job-wait.long-sweep"
        init(payload: Data?) throws {}
        func run(_ context: JobContext) async throws { await Gate.shared.hold() }
    }

    struct Quick: Job {
        static let kind = "test.job-wait.quick"
        init(payload: Data?) throws {}
        func run(_ context: JobContext) async throws {}
    }

    /// Only one test uses `Gate.shared`, so parallel tests never share it.
    @Test(.timeLimit(.minutes(1))) @MainActor
    func waitingForOwnJobsDoesNotWaitForTheRestOfTheQueue() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library, jobTypes: [LongSweep.self, Quick.self])
        Gate.shared.reset()
        defer { Gate.shared.open() }

        // Mine first, then a sweep that holds the queue behind it.
        let mine = try await runner.enqueue(Quick.self)
        _ = try await runner.enqueue(LongSweep.self)

        var done = false
        // Not awaited: on failure it would wait for the sweep, and the
        // gate opens only when the test ends.
        Task { @MainActor in
            do {
                try await runner.waitUntilSettled([mine.id])
                done = true
            } catch {}
        }
        for _ in 0..<400 where !done { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done, "waited for the sweep queued after its own job")
        #expect(Gate.shared.started, "the queue was not started")
    }

    /// A deduplicated request (`enqueueUnlessPending` returning nil) has no
    /// id of its own: it waits for the pending job of its kind instead.
    @Test(.timeLimit(.minutes(1)))
    func waitingForAKindEndsWhenNoneOfItIsPending() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library, jobTypes: [Quick.self])
        _ = try await runner.enqueue(Quick.self)
        try await runner.waitUntilNonePending(of: Quick.kind)
        let states = try await library.writer.read { try JobRecord.fetchAll($0).map(\.state) }
        #expect(states == [.succeeded])
    }

    @Test(.timeLimit(.minutes(1)))
    func waitingForNothingReturnsAtOnce() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library, jobTypes: [Quick.self], paused: true)
        try await runner.waitUntilSettled([])
        try await runner.waitUntilNonePending(of: Quick.kind)
    }
}
