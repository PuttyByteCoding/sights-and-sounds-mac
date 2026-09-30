import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The generic job abstraction, end to end: state machine, progress
/// persistence, failure capture, unknown kinds, cancellation.
@Suite struct JobRunnerTests {

    /// Counts to a payload-specified total, reporting progress and honoring
    /// cancellation between steps.
    private struct CountingJob: Job {
        static let kind = "test.counting"
        let total: Int

        init(payload: Data?) throws {
            total = payload.flatMap { try? JSONDecoder().decode(Int.self, from: $0) } ?? 3
        }

        func run(_ context: JobContext) async throws {
            for step in 1...total {
                try await context.checkCancellation()
                await context.reportProgress(current: step, total: total)
            }
        }
    }

    private struct ExplodingJob: Job {
        static let kind = "test.exploding"
        init(payload: Data?) throws {}
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        func run(_ context: JobContext) async throws { throw Boom() }
    }

    /// How many OverlapJobs are inside `run` at once, and the most there
    /// ever were.
    private actor Gauge {
        static let shared = Gauge()
        private var inside = 0
        private(set) var peak = 0
        func enter() { inside += 1; peak = max(peak, inside) }
        func leave() { inside -= 1 }
        func reset() { inside = 0; peak = 0 }
    }

    /// Suspends mid-run and touches no shared state, so it can run in a
    /// test that executes beside the gauge's.
    private struct PausingJob: Job {
        static let kind = "test.pausing"
        init(payload: Data?) throws {}
        func run(_ context: JobContext) async throws {
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Suspends mid-run, which is where a second drain used to slip in.
    /// Only `concurrentDrainsStillRunOneJobAtATime` may run it: the gauge
    /// is shared, and tests run in parallel.
    private struct OverlapJob: Job {
        static let kind = "test.overlap"
        init(payload: Data?) throws {}
        func run(_ context: JobContext) async throws {
            await Gauge.shared.enter()
            try await Task.sleep(for: .milliseconds(30))
            await Gauge.shared.leave()
        }
    }

    /// Runs until its gate opens, counting the jobs that got past start.
    /// Shared by the process, so a test resets both before it uses it.
    private actor Gate {
        static let shared = Gate()
        private(set) var open = false
        private(set) var started = 0
        func set(_ value: Bool) { open = value }
        func reset() {
            open = false
            started = 0
        }
        func start() { started += 1 }
    }

    private struct GatedJob: Job {
        static let kind = "test.gated"
        init(payload: Data?) throws {}
        func run(_ context: JobContext) async throws {
            await Gate.shared.start()
            while await !Gate.shared.open { try await Task.sleep(for: .milliseconds(10)) }
        }
    }

    /// A window that only queued work must be able to say "queued" at
    /// once. `runPending` returns when the whole queue has drained, so
    /// Operations, Organise and Review reported "Queued…" only after every
    /// job ahead had finished, and kept Run enabled all that time.
    ///
    /// Time-limited: if `startDraining` ever awaited the drain again, the
    /// gate below would never open and the test would hang, not fail.
    @Test(.timeLimit(.minutes(1)))
    func startDrainingReturnsWhileTheJobRuns() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(GatedJob.self)
        await Gate.shared.reset()
        // However the test ends, its jobs stop polling: a gate left shut
        // kept them looping for the rest of the process.
        defer { Task { await Gate.shared.set(true) } }
        let queued = try await runner.enqueue(GatedJob.self)
        let behind = try await runner.enqueue(GatedJob.self)

        await runner.startDraining()
        await runner.startDraining()  // a second call joins, never doubles

        for _ in 0..<200 where try record(library, queued.id).state != .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try record(library, queued.id).state == .running)
        // A second drain would have started the job behind it by now.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await Gate.shared.started == 1, "a second drain ran beside the first")
        #expect(try record(library, behind.id).state == .queued)

        await Gate.shared.set(true)
        for _ in 0..<400 where try record(library, behind.id).state != .succeeded {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try record(library, queued.id).state == .succeeded)
        #expect(try record(library, behind.id).state == .succeeded)
    }

    /// Nobody awaits the drain `startDraining` starts, so a queue it
    /// could not read vanished while the window still said "Queued…". It
    /// goes to the log now.
    @Test(.timeLimit(.minutes(1)))
    func aDrainThatCannotReadTheQueueIsLogged() async throws {
        let (library, runner) = try makeRunner()
        try await library.writer.write { try $0.execute(sql: "DROP TABLE job") }

        await runner.startDraining()

        func logged() -> Bool {
            AppLog.shared.snapshot().contains {
                $0.level == .error && $0.category == "jobs" && $0.message.contains("no such table: job")
            }
        }
        for _ in 0..<200 where !logged() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(logged(), "the failed drain left nothing in the log")
    }

    private func makeRunner() throws -> (LibraryDatabase, JobRunner) {
        let library = try LibraryDatabase.openInMemory()
        return (library, JobRunner(library: library))
    }

    private func record(_ library: LibraryDatabase, _ id: UUID) throws -> JobRecord {
        try library.writer.read { try JobRecord.fetchOne($0, key: id)! }
    }

    @Test func successPathTransitionsAndTimestamps() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(CountingJob.self)
        let queued = try await runner.enqueue(CountingJob.self, payload: try JSONEncoder().encode(5))
        #expect(queued.state == .queued)

        try await runner.runPending()

        let done = try record(library, queued.id)
        #expect(done.state == .succeeded)
        #expect(done.startedAt != nil)
        #expect(done.finishedAt != nil)
        #expect(done.progressCurrent == 5)
        #expect(done.progressTotal == 5)
        #expect(done.error == nil)
    }

    @Test func failureIsCapturedNotThrown() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(ExplodingJob.self)
        let queued = try await runner.enqueue(ExplodingJob.self)

        try await runner.runPending()

        let failed = try record(library, queued.id)
        #expect(failed.state == .failed)
        #expect(failed.error?.contains("boom") == true)
        #expect(failed.finishedAt != nil)
    }

    @Test func concurrentDrainsStillRunOneJobAtATime() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(OverlapJob.self)
        await Gauge.shared.reset()
        var ids: [UUID] = []
        for _ in 0..<4 { ids.append(try await runner.enqueue(OverlapJob.self).id) }

        // Every window and panel calls runPending; they arrive together.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { try await runner.runPending() } }
            try await group.waitForAll()
        }

        #expect(await Gauge.shared.peak == 1)
        for id in ids { #expect(try record(library, id).state == .succeeded) }
    }

    @Test func aCallerThatJoinsADrainReturnsAfterItsOwnJobRan() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(PausingJob.self)
        await runner.register(CountingJob.self)
        _ = try await runner.enqueue(PausingJob.self)
        let first = Task { try await runner.runPending() }
        // Let the first drain get inside its job.
        try await Task.sleep(for: .milliseconds(10))

        let mine = try await runner.enqueue(CountingJob.self)
        try await runner.runPending()

        #expect(try record(library, mine.id).state == .succeeded)
        _ = try await first.value
    }

    @Test func aRunnerBornWithItsJobTypesRunsThemAtOnce() async throws {
        // The app used to register kinds in a task it did not wait for,
        // so the first drain could meet a job before its kind existed.
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library, jobTypes: [CountingJob.self])
        let queued = try await runner.enqueue(CountingJob.self)

        try await runner.runPending()

        #expect(try record(library, queued.id).state == .succeeded)
    }

    @Test func aRunnerBornPausedHoldsItsQueue() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library, jobTypes: [CountingJob.self], paused: true)
        let queued = try await runner.enqueue(CountingJob.self)

        let settled = try await runner.runPending()

        #expect(settled.isEmpty)
        #expect(try record(library, queued.id).state == .queued)
    }

    @Test func unknownKindFailsCleanly() async throws {
        let (library, runner) = try makeRunner()
        // Enqueue a kind, then "forget" to register it.
        let queued = try await runner.enqueue(CountingJob.self)

        try await runner.runPending()

        let failed = try record(library, queued.id)
        #expect(failed.state == .failed)
        #expect(failed.error?.contains("test.counting") == true)
    }

    /// Cancelling a job that has not started settles it at once. It used
    /// to be only marked, and stayed "queued" until a drain reached it —
    /// behind a sweep that could be days — so the dashboard said "Removed
    /// from the queue" while the queue, and anything watching it, still
    /// counted it.
    @Test func cancellingAQueuedJobSettlesItWithoutADrain() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(CountingJob.self)
        let queued = try await runner.enqueue(CountingJob.self)

        await runner.requestCancel(queued.id)

        let cancelled = try record(library, queued.id)
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.finishedAt != nil)
        #expect(cancelled.startedAt == nil)
        // And a drain afterwards does not run it. (This replaces the old
        // cancel-before-start test, which now takes this same path.)
        try await runner.runPending()
        let after = try record(library, queued.id)
        #expect(after.state == .cancelled)
        #expect(after.startedAt == nil)
    }

    @Test func jobsRunOldestFirstAndDrainCompletely() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(CountingJob.self)
        var ids: [UUID] = []
        for _ in 0..<3 {
            ids.append(try await runner.enqueue(CountingJob.self).id)
        }

        let settled = try await runner.runPending()
        #expect(settled == ids)
        for id in ids {
            #expect(try record(library, id).state == .succeeded)
        }
    }

    @Test func failedJobRowSurvivesForInspection() async throws {
        let (library, runner) = try makeRunner()
        await runner.register(ExplodingJob.self)
        _ = try await runner.enqueue(ExplodingJob.self)
        try await runner.runPending()

        let failures = try await library.writer.read { db in
            try JobRecord.filter(sql: "state = ?", arguments: [JobState.failed.rawValue]).fetchAll(db)
        }
        #expect(failures.count == 1)
    }
}
