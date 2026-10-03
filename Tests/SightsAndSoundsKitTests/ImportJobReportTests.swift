import Foundation
import Testing

@testable import SightsAndSoundsKit

/// What the import job says about itself. The Import window reads the
/// summary's leading "N new, M already imported" for its tally, and showed
/// "Import finished · 0 inserted" for a run cancelled after thirty files,
/// because a cancelled job wrote no summary at all. Files named in the
/// list but gone from disk by the time the job ran were dropped without a
/// word, and progress was reported from fire-and-forget tasks that could
/// land out of order, or after the job was already done.
@Suite struct ImportJobReportTests {
    /// Three real files under a source, and a job context whose handlers
    /// are the test's own, so the job runs without a runner.
    struct Fixture {
        let library: LibraryDatabase
        let source: Source
        let root: URL

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-import-report-\(UUID().uuidString)", isDirectory: true)
            for name in ["a", "b", "c"] {
                try DemoMediaFactory.writeAudio(
                    to: root.appendingPathComponent("set/\(name).m4a"), seconds: 1, variant: 1)
            }
            library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Report")
            source = Source(name: "Root", rootPath: root.path)
            try await library.writer.write { [source] in try source.insert($0) }
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    /// Everything a run reports, in the order it reported it.
    final class Report: @unchecked Sendable {
        enum Event: Equatable { case progress(Int, Int?), summary(String) }
        private let lock = NSLock()
        private var events: [Event] = []
        var cancelAfterChecks = Int.max
        private var checks = 0

        func progress(_ current: Int, _ total: Int?) { lock.withLock { events.append(.progress(current, total)) } }
        func summary(_ text: String) { lock.withLock { events.append(.summary(text)) } }
        func isCancelled() -> Bool {
            lock.withLock {
                checks += 1
                return checks > cancelAfterChecks
            }
        }
        var all: [Event] { lock.withLock { events } }
        var summaryText: String? {
            all.compactMap { if case .summary(let text) = $0 { text } else { nil } }.last
        }
        var progressValues: [Int] {
            all.compactMap { if case .progress(let current, _) = $0 { current } else { nil } }
        }

        func context(_ library: LibraryDatabase) -> JobContext {
            JobContext(
                library: library, jobID: UUID(),
                progressHandler: { [self] current, total in progress(current, total) },
                cancellationCheck: { [self] in isCancelled() },
                summaryHandler: { [self] text in summary(text) })
        }
    }

    private func run(_ f: Fixture, paths: [String]? = nil, report: Report) async throws {
        let job = ImportJob(
            payload: .init(sourceID: f.source.id, relativePaths: paths), fileAccess: LiveFileAccess())
        try await job.run(report.context(f.library))
    }

    @Test func aCancelledImportReportsWhatItInserted() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let report = Report()
        // The job checks once per file, before it: the first file goes in,
        // the check before the second says stop.
        report.cancelAfterChecks = 1
        await #expect(throws: CancellationError.self) { try await run(f, report: report) }

        let inserted = try await f.library.writer.read { try MediaItem.fetchCount($0) }
        #expect(inserted == 1)
        let summary = try #require(report.summaryText, "a cancelled import wrote no summary")
        #expect(summary.hasPrefix("1 new, 0 already imported"), Comment(rawValue: summary))
        #expect(summary.contains("cancelled"), Comment(rawValue: summary))
        #expect(summary.contains("2 not reached"), Comment(rawValue: summary))
    }

    @Test func filesNamedButGoneFromDiskAreCounted() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let report = Report()
        try await run(f, paths: ["set/a.m4a", "set/ghost.m4a", "set/phantom.m4a"], report: report)
        let summary = try #require(report.summaryText)
        #expect(summary.hasPrefix("1 new, 0 already imported"), Comment(rawValue: summary))
        #expect(summary.contains("2 no longer on disk"), Comment(rawValue: summary))
    }

    /// A guard, not a proof: the old fire-and-forget reports could land in
    /// order by luck. With them awaited in place, this can never fail.
    @Test func progressNeverGoesBackwardsAndLandsBeforeTheSummary() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let report = Report()
        try await run(f, report: report)
        let values = report.progressValues
        #expect(values == values.sorted(), "\(values)")
        #expect(values.last == 3, "\(values)")
        let events = report.all
        let lastProgress = events.lastIndex { if case .progress = $0 { true } else { false } }
        let summary = events.lastIndex { if case .summary = $0 { true } else { false } }
        #expect(lastProgress != nil && summary != nil && lastProgress! < summary!,
                "progress landed after the summary: \(events)")
    }
    /// Counts the walks a job makes over the source.
    final class CountingAccess: FileAccess, @unchecked Sendable {
        private let live = LiveFileAccess()
        private let lock = NSLock()
        private var walks = 0
        var walkCount: Int { lock.withLock { walks } }
        func isReachable(_ url: URL) -> Bool { live.isReachable(url) }
        func contentsOfDirectory(at url: URL) throws -> [URL] { try live.contentsOfDirectory(at: url) }
        func allFiles(under url: URL) throws -> [URL] {
            lock.withLock { walks += 1 }
            return try live.allFiles(under: url)
        }
        func fileSize(at url: URL) throws -> Int64 { try live.fileSize(at: url) }
        func readFile(at url: URL, chunk: (Data) throws -> Void) throws { try live.readFile(at: url, chunk: chunk) }
        func moveFile(at url: URL, to destination: URL) throws { try live.moveFile(at: url, to: destination) }
        func removeFile(at url: URL) throws { try live.removeFile(at: url) }
    }

    /// A named import is one folder of a drive that may hold forty
    /// thousand files, and a per-folder import is one job per folder: each
    /// walked the whole source again. A named list is checked file by
    /// file instead, with the same rules as the walk.
    @Test func aNamedImportDoesNotWalkTheSource() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        // Named: one real file, one gone, one under the archive, one whose
        // extension no list claims.
        try Data("x".utf8).write(to: f.root.appendingPathComponent("set/notes.txt"))
        try FileManager.default.createDirectory(
            at: f.root.appendingPathComponent("_Replaced/set"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: f.root.appendingPathComponent("_Replaced/set/old.m4a"))
        let access = CountingAccess()
        let report = Report()
        let job = ImportJob(
            payload: .init(sourceID: f.source.id, relativePaths: [
                "set/a.m4a", "set/ghost.m4a", "_Replaced/set/old.m4a", "set/notes.txt",
            ]),
            fileAccess: access)
        try await job.run(report.context(f.library))

        #expect(access.walkCount == 0, "a named import walked the source \(access.walkCount) times")
        let paths = try await f.library.writer.read { try MediaItem.fetchAll($0).map(\.relativePath) }
        #expect(paths == ["set/a.m4a"], "\(paths)")
        let summary = try #require(report.summaryText)
        #expect(summary.hasPrefix("1 new, 0 already imported"), Comment(rawValue: summary))
        #expect(summary.contains("1 no longer on disk"), Comment(rawValue: summary))
    }

    @Test func anUnnamedImportStillWalksOnce() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let access = CountingAccess()
        let job = ImportJob(payload: .init(sourceID: f.source.id), fileAccess: access)
        try await job.run(Report().context(f.library))
        #expect(access.walkCount == 1)
        #expect(try await f.library.writer.read { try MediaItem.fetchCount($0) } == 3)
    }
}
