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
}
