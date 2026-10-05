import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Cancel stops the whole import. A per-folder import is one job per
/// folder; Cancel used to stop only the job in flight, and every later
/// folder was enqueued and imported anyway.
@Suite @MainActor struct ImportRunTests {
    /// Cancel reaches the whole run: a per-folder import is one job per
    /// folder, and every later folder used to go ahead after Cancel. The
    /// second folder's queueing is held at a gate until Cancel has been
    /// pressed — cancelling on a timer caught the first job still queued
    /// (cancelled before it ran: the first folder imported nothing) or
    /// already finished (the second had begun: it imported too).
    @Test(.timeLimit(.minutes(1)), .writesVideo)
    func cancelAfterTheFirstFolderImportsNoLaterFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["one/a.mp4", "two/b.mp4", "three/c.mp4"] {
            try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent(path), seconds: 1, variant: 0)
        }
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportRun")
        let source = Source(name: "Here", rootPath: root.path)
        try await library.writer.write { try source.insert($0) }
        let run = ImportRun(runner: JobRunner(library: library), library: library)
        let gate = Gate()
        defer { gate.open() }
        let enqueue = run.enqueue
        let counter = Counter()
        run.enqueue = { runner, sourceID, paths, staging in
            // The first folder queues at once; the second waits for the gate.
            if counter.next() > 1 { await gate.hold() }
            return try await enqueue(runner, sourceID, paths, staging)
        }

        var finished = false
        run.start(
            sourceID: source.id,
            groups: [.init(paths: ["one/a.mp4"]), .init(paths: ["two/b.mp4"]), .init(paths: ["three/c.mp4"])]
        ) { _ in finished = true }
        for _ in 0..<800 where !gate.arrived { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.arrived, "the second folder never came to be queued")
        run.cancel()
        gate.open()
        for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(25)) }

        #expect(finished)
        let imported = try await library.writer.read { try MediaItem.fetchAll($0).map(\.relativePath) }
        #expect(imported == ["one/a.mp4"], "\(imported)")
        let jobs = try await library.writer.read { try JobRecord.order(sql: "createdAt").fetchAll($0) }
        #expect(jobs.first?.state == .succeeded, "\(jobs.map { ($0.state, $0.error ?? "") })")
        #expect(!jobs.contains { $0.state == .failed })
    }

    /// Counts calls from any task.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    /// Cancel pressed before the first job exists still stops the run —
    /// it used to do nothing until a job had been enqueued.
    @Test func cancelBeforeTheFirstJobStopsEverything() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportRunEarly")
        let source = Source(name: "Here", rootPath: "/tmp/sas-import-run-\(UUID().uuidString)")
        try await library.writer.write { try source.insert($0) }
        let run = ImportRun(runner: JobRunner(library: library), library: library)

        var finished = false
        run.start(sourceID: source.id, groups: [.init(paths: ["a.mp4"])]) { _ in finished = true }
        run.cancel()
        for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(25)) }

        let jobs = try await library.writer.read { try JobRecord.fetchCount($0) }
        #expect(jobs == 0)
    }

    /// "Run in background" leaves the Import window usable while the run
    /// goes on. Import stayed armed there — it only looked at the window's
    /// step — and a second click started a second run over the same files
    /// and orphaned the first one's Cancel. The run says whether it is
    /// still going.
    @Test(.writesVideo) func aRunSaysItIsRunningUntilItFinishes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-run-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 1, variant: 0)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportRunLive")
        let source = Source(name: "Here", rootPath: root.path)
        try await library.writer.write { try source.insert($0) }
        let run = ImportRun(runner: JobRunner(library: library), library: library)
        #expect(!run.isRunning)

        var finished = false
        run.start(sourceID: source.id, groups: [.init(paths: ["a.mp4"])]) { _ in finished = true }
        #expect(run.isRunning)
        for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(25)) }

        #expect(finished)
        #expect(!run.isRunning)
        // A real run, not one whose job failed at once.
        let imported = try await library.writer.read { try MediaItem.fetchAll($0).map(\.relativePath) }
        #expect(imported == ["a.mp4"])
    }

    /// Holds the queue until its gate opens; suspended, not blocking.
    final class Gate: @unchecked Sendable {
        static let shared = Gate()
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var hasArrived = false
        /// Something has reached the gate, so a test can wait for that
        /// rather than guess how long it takes.
        var arrived: Bool { lock.withLock { hasArrived } }
        func reset() { lock.withLock { isOpen = false; hasArrived = false } }
        func open() {
            let held = lock.withLock {
                isOpen = true
                defer { waiting = [] }
                return waiting
            }
            for job in held { job.resume() }
        }
        func hold() async {
            lock.withLock { hasArrived = true }
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
        static let kind = "test.import-run.long-sweep"
        init(payload: Data?) throws {}
        func run(_ context: JobContext) async throws { await Gate.shared.hold() }
    }

    /// The run waited for the whole queue to drain after each folder. A
    /// Cancel settles a queued import at once now, but the window still
    /// said it was running — Import disabled — until every job ahead of
    /// it, a sweep of hours, had finished.
    @Test(.timeLimit(.minutes(1)))
    func cancellingAnImportBehindALongJobFinishesTheRunAtOnce() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportRunBehind")
        let source = Source(name: "Here", rootPath: "/tmp/sas-import-behind-\(UUID().uuidString)")
        try await library.writer.write { try source.insert($0) }
        let runner = JobRunner(library: library, jobTypes: JobCatalog.all + [LongSweep.self])
        Gate.shared.reset()
        defer { Gate.shared.open() }
        _ = try await runner.enqueue(LongSweep.self)
        await runner.startDraining()

        let run = ImportRun(runner: runner, library: library)
        var finished = false
        run.start(sourceID: source.id, groups: [.init(paths: ["a.mp4"])]) { _ in finished = true }
        for _ in 0..<400 where run.running == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(run.running != nil)
        run.cancel()
        for _ in 0..<300 where !finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished, "the run waited for the job ahead of it")
        #expect(!run.isRunning)
    }

    /// Cancel pressed while a folder was still being queued cancelled
    /// nothing: the job did not exist yet, and once it did the run polled
    /// it to the end, importing that folder after Cancel. On a paused
    /// queue it never ended at all.
    @Test(.timeLimit(.minutes(1)))
    func cancelWhileAFolderIsBeingQueuedCancelsThatFolder() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportRunQueueing")
        let source = Source(name: "Here", rootPath: "/tmp/sas-import-queueing-\(UUID().uuidString)")
        try await library.writer.write { try source.insert($0) }
        let runner = JobRunner(library: library, paused: true)
        let gate = Gate()
        defer { gate.open() }
        let run = ImportRun(runner: runner, library: library)
        let enqueue = run.enqueue
        run.enqueue = { runner, sourceID, paths, staging in
            await gate.hold()
            return try await enqueue(runner, sourceID, paths, staging)
        }

        var finished = false
        run.start(sourceID: source.id, groups: [.init(paths: ["a.mp4"])]) { _ in finished = true }
        // Cancel must land while the folder is being queued, not before
        // the run reaches it (that is cancelBeforeTheFirstJobStopsEverything).
        for _ in 0..<400 where !gate.arrived { try await Task.sleep(for: .milliseconds(5)) }
        try #require(gate.arrived)
        run.cancel()
        gate.open()
        for _ in 0..<300 where !finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished, "the folder queued during Cancel was not cancelled")
        let states = try await library.writer.read { try JobRecord.fetchAll($0).map(\.state) }
        #expect(states == [.cancelled])
    }
    /// The window said "Import finished · 0 inserted" for a run whose job
    /// failed (the drive unplugged between Scan and Import) or that was
    /// cancelled: a settled row's error was never read, and a cancel was
    /// not told apart from a finish.
    @Test(.timeLimit(.minutes(1)))
    func aFailedJobIsReportedAsAFailure() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportRunFailed")
        // A root that does not exist: the job refuses it as offline.
        let source = Source(name: "Gone", rootPath: "/tmp/sas-import-gone-\(UUID().uuidString)")
        try await library.writer.write { try source.insert($0) }
        let run = ImportRun(runner: JobRunner(library: library), library: library)
        var outcome: ImportRun.Outcome?
        run.start(sourceID: source.id, groups: [.init(paths: ["a.mp4"])]) { outcome = $0 }
        for _ in 0..<400 where outcome == nil { try await Task.sleep(for: .milliseconds(25)) }
        let got = try #require(outcome)
        #expect(!got.cancelled)
        #expect(got.failures.count == 1, "\(got.failures)")
        #expect(got.failures.first?.contains("offline") == true, "\(got.failures)")
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledRunIsReportedAsCancelled() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportRunCancelled")
        let source = Source(name: "Here", rootPath: "/tmp/sas-import-cancel-\(UUID().uuidString)")
        try await library.writer.write { try source.insert($0) }
        let run = ImportRun(runner: JobRunner(library: library), library: library)
        var outcome: ImportRun.Outcome?
        run.start(sourceID: source.id, groups: [.init(paths: ["a.mp4"])]) { outcome = $0 }
        run.cancel()
        for _ in 0..<400 where outcome == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(try #require(outcome).cancelled)
    }

    /// Per-folder imports are one job each, and the overlay restarted at
    /// "0 of 12" for every folder with no sense of the whole.
    @Test(.timeLimit(.minutes(1)))
    func progressCountsAcrossFolders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-run-folders-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try DemoMediaFactory.writeAudio(to: root.appendingPathComponent("one/a.m4a"), seconds: 1)
        try DemoMediaFactory.writeAudio(to: root.appendingPathComponent("two/b.m4a"), seconds: 1)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportRunFolders")
        let source = Source(name: "Here", rootPath: root.path)
        try await library.writer.write { try source.insert($0) }
        let run = ImportRun(runner: JobRunner(library: library), library: library)
        var outcome: ImportRun.Outcome?
        run.start(sourceID: source.id, groups: [.init(paths: ["one/a.m4a"]), .init(paths: ["two/b.m4a"])]) {
            outcome = $0
        }
        for _ in 0..<400 where outcome == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(try #require(outcome).tally.inserted == 2)
        #expect(run.progress?.total == 2, "the total is the run's, not the folder's: \(String(describing: run.progress))")
        #expect(run.progress?.current == 2)
    }
}
