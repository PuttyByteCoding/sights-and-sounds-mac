import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// An import waits for nobody. The library's lane runs one job at a time,
/// oldest first, and an import finishing wakes the workers: a content
/// hash sweep over every unhashed file, thumbnails, fingerprints. The
/// next import, pressed from the same window, queued behind all of it,
/// and the window said "Importing…" until the sweeps were done.
///
/// Now an import goes to the front of the lane, the sweeps step aside
/// between files when one is waiting and carry on after it, and each
/// import queues a hash job of its own for the files it brought in.
@Suite struct ImportJumpsQueueTests {
    /// Remembers what ran, in order, across the jobs of one test.
    actor Log {
        private(set) var events: [String] = []
        private(set) var done: Set<Int> = []
        func add(_ event: String) { events.append(event) }
        func finish(_ step: Int) { done.insert(step) }
    }

    /// One log per test: a payload names it, since a Job is built from
    /// its payload alone.
    nonisolated(unsafe) static var logs: [String: Log] = [:]
    static let logsLock = NSLock()
    static func log(_ name: String) -> Log {
        logsLock.withLock {
            if let log = logs[name] { return log }
            let log = Log()
            logs[name] = log
            return log
        }
    }

    struct Named: Codable { var log: String; var label: String }

    /// Background work in steps, picking up where it left off: it
    /// decides its work per run, as the sweeps do. Before each step it
    /// steps aside if an import is waiting. When asked, it queues the
    /// import itself after its first step, so the import arrives while
    /// it is running.
    struct SweepLikeJob: Job {
        static let kind = "test.sweepLike"
        let named: Named
        init(payload: Data?) throws { named = try JSONDecoder().decode(Named.self, from: payload!) }

        func run(_ context: JobContext) async throws {
            let log = ImportJumpsQueueTests.log(named.log)
            for step in 1...3 where await !log.done.contains(step) {
                try await context.stepAsideIfAnImportIsWaiting()
                await log.add("\(named.label) \(step)")
                await log.finish(step)
                if step == 1, named.label == "sweep+import" {
                    try await context.enqueue(
                        ImportLikeJob.self,
                        payload: JSONEncoder().encode(Named(log: named.log, label: "import")))
                }
            }
        }
    }

    struct ImportLikeJob: Job {
        static let kind = "test.importLike"
        static let jumpsQueue = true
        let named: Named
        init(payload: Data?) throws { named = try JSONDecoder().decode(Named.self, from: payload!) }
        func run(_ context: JobContext) async throws {
            await ImportJumpsQueueTests.log(named.log).add(named.label)
        }
    }

    private func runner(_ library: LibraryDatabase) -> JobRunner {
        JobRunner(library: library, jobTypes: [SweepLikeJob.self, ImportLikeJob.self], paused: true)
    }

    private func payload(_ log: String, _ label: String) throws -> Data {
        try JSONEncoder().encode(Named(log: log, label: label))
    }

    @Test func anImportIsQueuedAheadOfBackgroundWorkAndImportsKeepTheirOrder() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = runner(library)
        let name = UUID().uuidString
        _ = try await runner.enqueue(SweepLikeJob.self, payload: payload(name, "sweep"))
        _ = try await runner.enqueue(ImportLikeJob.self, payload: payload(name, "first import"))
        _ = try await runner.enqueue(ImportLikeJob.self, payload: payload(name, "second import"))
        await runner.setPaused(false)
        try await runner.runPending()
        #expect(await Self.log(name).events == [
            "first import", "second import", "sweep 1", "sweep 2", "sweep 3",
        ])
    }

    @Test func backgroundWorkStepsAsideForAnImportAndCarriesOnAfterIt() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = runner(library)
        let name = UUID().uuidString
        let sweep = try await runner.enqueue(SweepLikeJob.self, payload: payload(name, "sweep+import"))
        await runner.setPaused(false)
        let settled = try await runner.runPending()
        #expect(await Self.log(name).events == [
            "sweep+import 1", "import", "sweep+import 2", "sweep+import 3",
        ])
        // The same row, carried on: not a second one, and not "failed".
        let rows = try await library.read { try JobRecord.fetchAll($0) }
        #expect(rows.filter { $0.kind == SweepLikeJob.kind }.map(\.id) == [sweep.id])
        #expect(rows.allSatisfy { $0.state == .succeeded })
        // Settled once, after it finished — not when it stepped aside.
        #expect(settled.filter { $0 == sweep.id }.count == 1)
        #expect(settled.last == sweep.id)
    }

    @Test func importsAndTheSweepsThatStepAsideForThem() {
        #expect(ImportJob.jumpsQueue)
        #expect(!ContentHashJob.jumpsQueue)
        #expect(!ThumbnailBatchJob.jumpsQueue)
        #expect(!FingerprintCaptureJob.jumpsQueue)
    }

    /// Each import hashes what it brought in, as a job of its own, and
    /// that job hashes only those files.
    @Test func eachImportQueuesAHashJobForItsOwnFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-import-hash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            try DemoMediaFactory.writeAudio(
                to: root.appendingPathComponent("set/\(name).m4a"), seconds: 1, variant: 1)
        }
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Hash per import")
        try library.setHashesFiles(true)
        let source = Source(name: "Root", rootPath: root.path)
        try await library.writer.write { [source] in try source.insert($0) }
        let runner = JobRunner(library: library, paused: true)

        try await ImportJob.enqueue(on: runner, sourceID: source.id, relativePaths: ["set/a.m4a"])
        try await ImportJob.enqueue(on: runner, sourceID: source.id, relativePaths: ["set/b.m4a"])
        await runner.setPaused(false)
        try await runner.runPending()

        let jobs = try await library.read { try JobRecord.order(sql: "rowid").fetchAll($0) }
        let hashJobs = jobs.filter { $0.kind == ContentHashJob.kind }
        #expect(hashJobs.count == 2, "one hash job per import")
        #expect(hashJobs.allSatisfy { $0.state == .succeeded && $0.summary == "1 hashed" })
        let hashed = try await library.read {
            try String.fetchAll($0, sql: "SELECT relativePath FROM mediaItem WHERE contentHash IS NOT NULL ORDER BY relativePath")
        }
        #expect(hashed == ["set/a.m4a", "set/b.m4a"])
    }

    /// A library that does not hash — the default — queues no hashing
    /// for what an import brings in.
    @Test func anImportIntoALibraryThatDoesNotHashQueuesNoHashJob() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-import-nohash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try DemoMediaFactory.writeAudio(to: root.appendingPathComponent("set/a.m4a"), seconds: 1, variant: 1)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "No hashing")
        #expect(try !library.hashesFiles())
        let source = Source(name: "Root", rootPath: root.path)
        try await library.writer.write { [source] in try source.insert($0) }
        let runner = JobRunner(library: library)
        try await ImportJob.enqueue(on: runner, sourceID: source.id, relativePaths: ["set/a.m4a"])
        try await runner.runPending()
        let kinds = try await library.read { try JobRecord.fetchAll($0) }.map(\.kind)
        #expect(kinds == [ImportJob.kind])
        let hashed = try await library.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM mediaItem WHERE contentHash IS NOT NULL") ?? 0
        }
        #expect(hashed == 0)
    }

    /// An import that brought nothing in queues nothing.
    @Test func anImportOfNothingNewQueuesNoHashJob() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Nothing new")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-import-none-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(name: "Root", rootPath: root.path)
        try await library.writer.write { [source] in try source.insert($0) }
        let runner = JobRunner(library: library)
        try await ImportJob.enqueue(on: runner, sourceID: source.id, relativePaths: [])
        try await runner.runPending()
        let kinds = try await library.read { try JobRecord.fetchAll($0) }.map(\.kind)
        #expect(kinds == [ImportJob.kind])
    }
}
