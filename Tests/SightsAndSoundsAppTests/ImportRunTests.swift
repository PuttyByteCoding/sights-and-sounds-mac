import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Cancel stops the whole import. A per-folder import is one job per
/// folder; Cancel used to stop only the job in flight, and every later
/// folder was enqueued and imported anyway.
@Suite @MainActor struct ImportRunTests {
    @Test func cancelDuringTheFirstFolderImportsNoLaterFolder() async throws {
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

        var finished = false
        run.start(
            sourceID: source.id,
            groups: [.init(paths: ["one/a.mp4"]), .init(paths: ["two/b.mp4"]), .init(paths: ["three/c.mp4"])]
        ) { _ in finished = true }
        for _ in 0..<400 where run.running == nil { try await Task.sleep(for: .milliseconds(5)) }
        run.cancel()
        for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(25)) }

        #expect(finished)
        let imported = try await library.writer.read { try MediaItem.fetchAll($0).map(\.relativePath) }
        #expect(!imported.contains("two/b.mp4"))
        #expect(!imported.contains("three/c.mp4"))
        // The first folder's import really ran: a job that failed to start
        // imports nothing, and the checks above would pass with Cancel broken.
        let jobs = try await library.writer.read { try JobRecord.fetchAll($0) }
        #expect(!jobs.isEmpty)
        #expect(jobs.allSatisfy { $0.state != .failed }, "\(jobs.compactMap(\.error))")
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
    @Test func aRunSaysItIsRunningUntilItFinishes() async throws {
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
        func reset() { lock.withLock { isOpen = false } }
        func open() {
            let held = lock.withLock {
                isOpen = true
                defer { waiting = [] }
                return waiting
            }
            for job in held { job.resume() }
        }
        func hold() async {
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
        try await Task.sleep(for: .milliseconds(50))
        run.cancel()
        gate.open()
        for _ in 0..<300 where !finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished, "the folder queued during Cancel was not cancelled")
        let states = try await library.writer.read { try JobRecord.fetchAll($0).map(\.state) }
        #expect(states == [.cancelled])
    }
}
