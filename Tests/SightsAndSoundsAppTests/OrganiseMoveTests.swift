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
        private(set) var started = false

        func reset() { lock.withLock { isOpen = false; started = false } }

        func open() {
            let held = lock.withLock {
                isOpen = true
                defer { waiting = [] }
                return waiting
            }
            for job in held { job.resume() }
        }

        func hold() async {
            lock.withLock { started = true }
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
        for _ in 0..<200 where !queued { try await Task.sleep(for: .milliseconds(10)) }
        #expect(queued, "queueing the moves waited for the sweep ahead of them")

        let jobs = try await library.writer.read { try JobRecord.fetchAll($0) }
        #expect(jobs.first { $0.id == sweep.id }?.state == .running, "the sweep ahead is still running")
        #expect(jobs.contains { $0.kind == ReorganizeJob.kind && $0.state == .queued })

        Gate.shared.open()
        _ = try await moving.value
    }
}
