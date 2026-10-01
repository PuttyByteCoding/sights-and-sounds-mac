import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A scan of the item on screen waited behind every sweep already queued:
/// the runner takes one job at a time, oldest first, so after an import
/// queued its hash, thumbnail and fingerprint sweeps, Tag Analysis and the
/// OCR panel waited for all of them. A scan somebody is waiting on goes to
/// the front now — next after the job running, which it never interrupts.
@Suite @MainActor struct ScanGoesNextTests {
    /// Two gates: the running job's, which the test opens, and the queued
    /// sweep's, which stays shut until the test ends.
    final class Gates: @unchecked Sendable {
        static let shared = Gates()
        private let lock = NSLock()
        private var open: Set<String> = []
        private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
        private var arrived: Set<String> = []

        func reset() { lock.withLock { open = []; waiting = [:]; arrived = [] } }
        func hasArrived(_ gate: String) -> Bool { lock.withLock { arrived.contains(gate) } }
        func open(_ gate: String) {
            let held = lock.withLock {
                open.insert(gate)
                defer { waiting[gate] = [] }
                return waiting[gate] ?? []
            }
            for job in held { job.resume() }
        }
        func hold(_ gate: String) async {
            lock.withLock { _ = arrived.insert(gate) }
            await withCheckedContinuation { (job: CheckedContinuation<Void, Never>) in
                let goNow = lock.withLock {
                    if open.contains(gate) { return true }
                    waiting[gate, default: []].append(job)
                    return false
                }
                if goNow { job.resume() }
            }
        }
    }

    struct Running: Job {
        static let kind = "test.scan-next.running"
        init(payload: Data?) throws {}
        func run(_ context: JobContext) async throws { await Gates.shared.hold("running") }
    }

    struct QueuedSweep: Job {
        static let kind = "test.scan-next.queued-sweep"
        init(payload: Data?) throws {}
        func run(_ context: JobContext) async throws { await Gates.shared.hold("sweep") }
    }

    @Test(.timeLimit(.minutes(1)))
    func aScanOfTheItemOnScreenRunsBeforeQueuedSweeps() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ScanGoesNext")
        let runner = JobRunner(library: library, jobTypes: JobCatalog.all + [Running.self, QueuedSweep.self])
        let model = BrowseModel(libraryID: UUID(), library: library, runner: runner)
        Gates.shared.reset()
        defer { Gates.shared.open("running"); Gates.shared.open("sweep") }

        _ = try await runner.enqueue(Running.self)
        await runner.startDraining()
        for _ in 0..<400 where !Gates.shared.hasArrived("running") { try await Task.sleep(for: .milliseconds(5)) }
        try #require(Gates.shared.hasArrived("running"))
        _ = try await runner.enqueue(QueuedSweep.self)

        var finished = false
        model.scanText(itemID: UUID()) { finished = true }
        // The scan has been queued and moved forward before the running job
        // is let go: let go earlier, the drain could pick the older sweep
        // first on a slow machine, with correct code. Without the move this
        // waits out its budget, and the sweep then holds the scan back.
        for _ in 0..<400 {
            let moved = try await library.writer.read {
                try JobRecord.filter(sql: "kind = ? AND priority > 0", arguments: [OcrJob.kind]).fetchCount($0)
            }
            if moved > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        Gates.shared.open("running")

        for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished, "the scan waited for the sweep queued before it")
    }
}
