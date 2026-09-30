import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// An import inserts each row, then applies what was staged for it (tags,
/// fields, favourite) in writes of its own. A staged tag deleted while the
/// import waited made that apply throw: the job failed with the row
/// already in, every later file was left out, and a re-run skipped the
/// half-done row as already imported, so its staging never landed and
/// nothing said so. A staged value that no longer exists is now skipped
/// with a note, and the import carries on.
@Suite struct ImportStagingFailureTests {
    @Test func aStagedTagDeletedMeanwhileDoesNotStopTheImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-import-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.mp4", "b.mp4", "c.mp4"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Staging")
        let source = Source(name: "Here", rootPath: root.path)
        let band = TagCategory(name: "Band")
        try await library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
        }
        let kept = try library.ensureTag(named: "Kept", inCategory: band.id)
        let gone = try library.ensureTag(named: "Gone", inCategory: band.id)
        let runner = JobRunner(library: library, jobTypes: [ImportJob.self])
        let queued = try await ImportJob.enqueue(
            on: runner, sourceID: source.id,
            staging: ImportStaging(tagIDs: [gone.id, kept.id], marksFavorite: true))
        try await library.writer.write { db in _ = try SightsAndSoundsKit.Tag.deleteOne(db, key: gone.id) }

        try await runner.runPending()

        let record = try await library.writer.read { try JobRecord.fetchOne($0, key: queued.id)! }
        #expect(record.state == .succeeded, "\(record.error ?? "")")
        let items = try await library.writer.read { try MediaItem.fetchAll($0) }
        #expect(items.count == 3)
        // What still exists was applied to both.
        let favourites = items.filter { $0.isFavorite }.count
        #expect(favourites == 3)
        for item in items {
            #expect(try library.tags(of: item.id).flatMap(\.tags).map(\.id) == [kept.id])
        }
        // One deleted tag is one missing value, however many files it
        // was staged onto (it read "3" here, and "500" on a big import).
        #expect(record.summary?.contains("1 staged tag or field no longer exists") == true, "\(record.summary ?? "")")
    }

    /// On a case-sensitive volume `a.mp4` and `A.mp4` are two files, but
    /// the library's paths are unique ignoring case. The second insert
    /// hit the index and failed the whole run partway.
    @Test func twoPathsDifferingOnlyInCaseImportOnceAndCarryOn() async throws {
        let root = URL(fileURLWithPath: "/Volumes/SAS-Test-CaseSensitive-\(UUID().uuidString)", isDirectory: true)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Case")
        let source = Source(name: "Case", rootPath: root.path)
        try await library.writer.write { try source.insert($0) }
        let files = CaseSensitiveVolume(files: ["A.mp4", "a.mp4", "b.mp4"].map { root.appendingPathComponent($0) })
        let job = ImportJob(payload: .init(sourceID: source.id), fileAccess: files)
        let summary = Summary()
        let context = JobContext(
            library: library, jobID: UUID(), progressHandler: { _, _ in },
            cancellationCheck: { false }, summaryHandler: { await summary.set($0) })

        try await job.run(context)

        let paths = try await library.writer.read { try MediaItem.fetchAll($0).map(\.relativePath) }.sorted()
        #expect(paths == ["A.mp4", "b.mp4"])
        // The twin is not "already imported" — it is in no library — and
        // the summary says which file was left out and why.
        let text = await summary.text ?? ""
        #expect(text.hasPrefix("2 new, 0 already imported"), "\(text)")
        #expect(text.contains("a.mp4"), "\(text)")
    }

    private actor Summary {
        var text: String?
        func set(_ value: String) { text = value }
    }

    private struct CaseSensitiveVolume: FileAccess {
        let files: [URL]
        func isReachable(_ url: URL) -> Bool { true }
        func contentsOfDirectory(at url: URL) throws -> [URL] { files }
        func allFiles(under url: URL) throws -> [URL] { files }
        func fileSize(at url: URL) throws -> Int64 { 1 }
        func readFile(at url: URL, chunk: (Data) throws -> Void) throws {}
        func moveFile(at url: URL, to destination: URL) throws {}
        func removeFile(at url: URL) throws {}
    }

    /// A staged tag deleted while the import RUNS — not before — is also
    /// skipped and said. The staging is resolved once per run, so for the
    /// length of the run the assign itself met the deleted tag and threw.
    @Test func aStagedTagDeletedMidRunIsSkippedToo() async throws {
        let root = URL(fileURLWithPath: "/Volumes/SAS-Test-MidRun-\(UUID().uuidString)", isDirectory: true)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "MidRun")
        let source = Source(name: "S", rootPath: root.path)
        let band = TagCategory(name: "Band")
        try await library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
        }
        let doomed = try library.ensureTag(named: "Doomed", inCategory: band.id)
        let files = DeletingVolume(
            files: ["a.mp4", "b.mp4", "c.mp4"].map { root.appendingPathComponent($0) },
            onSecondSize: { try? library.deleteTag(doomed.id) })
        let job = ImportJob(
            payload: .init(sourceID: source.id, staging: ImportStaging(tagIDs: [doomed.id])), fileAccess: files)
        let summary = Summary()
        let context = JobContext(
            library: library, jobID: UUID(), progressHandler: { _, _ in },
            cancellationCheck: { false }, summaryHandler: { await summary.set($0) })

        try await job.run(context)

        let count = try await library.writer.read { try MediaItem.fetchCount($0) }
        #expect(count == 3)
        #expect(await summary.text?.contains("1 staged tag or field no longer exists") == true)
    }

    /// Rescanning the same case-sensitive folder: the twin that was left
    /// out the first time is still a twin, not "already imported".
    @Test func aCaseTwinIsStillNamedOnALaterScan() async throws {
        let root = URL(fileURLWithPath: "/Volumes/SAS-Test-CaseAgain-\(UUID().uuidString)", isDirectory: true)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "CaseAgain")
        let source = Source(name: "Case", rootPath: root.path)
        try await library.writer.write { try source.insert($0) }
        let files = CaseSensitiveVolume(files: ["A.mp4", "a.mp4"].map { root.appendingPathComponent($0) })
        for _ in 0..<2 {
            let summary = Summary()
            let context = JobContext(
                library: library, jobID: UUID(), progressHandler: { _, _ in },
                cancellationCheck: { false }, summaryHandler: { await summary.set($0) })
            try await ImportJob(payload: .init(sourceID: source.id), fileAccess: files).run(context)
            let text = await summary.text ?? ""
            #expect(text.contains("a.mp4"), "\(text)")
        }
    }

    /// A staged tag deleted meanwhile, on a run that imports nothing new:
    /// there was nothing to apply it to, so nothing was left unapplied and
    /// the summary must not say so.
    @Test func aMissingStagedTagIsNotReportedWhenNothingWasImported() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-import-nothing-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("a.mp4"))
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "NothingNew")
        let source = Source(name: "Here", rootPath: root.path)
        let band = TagCategory(name: "Band")
        try await library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
        }
        let runner = JobRunner(library: library, jobTypes: [ImportJob.self])
        _ = try await ImportJob.enqueue(on: runner, sourceID: source.id)
        try await runner.runPending()

        let gone = try library.ensureTag(named: "Gone", inCategory: band.id)
        let queued = try await ImportJob.enqueue(
            on: runner, sourceID: source.id, staging: ImportStaging(tagIDs: [gone.id]))
        try await library.writer.write { db in _ = try SightsAndSoundsKit.Tag.deleteOne(db, key: gone.id) }
        try await runner.runPending()

        let summary = try await library.writer.read { try JobRecord.fetchOne($0, key: queued.id)?.summary } ?? ""
        #expect(summary.hasPrefix("0 new, 1 already imported"), "\(summary)")
        #expect(!summary.contains("no longer exist"), "\(summary)")
    }

    private final class DeletingVolume: FileAccess, @unchecked Sendable {
        let files: [URL]
        let onSecondSize: () -> Void
        private let lock = NSLock()
        private var sizes = 0
        init(files: [URL], onSecondSize: @escaping () -> Void) {
            self.files = files
            self.onSecondSize = onSecondSize
        }
        func isReachable(_ url: URL) -> Bool { true }
        func contentsOfDirectory(at url: URL) throws -> [URL] { files }
        func allFiles(under url: URL) throws -> [URL] { files }
        func fileSize(at url: URL) throws -> Int64 {
            let count = lock.withLock { sizes += 1; return sizes }
            if count == 2 { onSecondSize() }
            return 1
        }
        func readFile(at url: URL, chunk: (Data) throws -> Void) throws {}
        func moveFile(at url: URL, to destination: URL) throws {}
        func removeFile(at url: URL) throws {}
    }
}

