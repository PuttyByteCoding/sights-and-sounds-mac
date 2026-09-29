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
        for name in ["a.mp4", "b.mp4"] {
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
        #expect(items.count == 2)
        // What still exists was applied to both.
        let favourites = items.filter { $0.isFavorite }.count
        #expect(favourites == 2)
        for item in items {
            #expect(try library.tags(of: item.id).flatMap(\.tags).map(\.id) == [kept.id])
        }
        #expect(record.summary?.contains("no longer exist") == true, "\(record.summary ?? "")")
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
        let context = JobContext(
            library: library, jobID: UUID(), progressHandler: { _, _ in },
            cancellationCheck: { false }, summaryHandler: { _ in })

        try await job.run(context)

        let paths = try await library.writer.read { try MediaItem.fetchAll($0).map(\.relativePath) }.sorted()
        #expect(paths == ["A.mp4", "b.mp4"])
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
}
