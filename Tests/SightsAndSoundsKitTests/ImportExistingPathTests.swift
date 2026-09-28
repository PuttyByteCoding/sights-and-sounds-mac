import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// A file already in the library is skipped whatever the case of its
/// path — the schema's path index is NOCASE — and a rescan of a large
/// source answers that from one lookup per file, not a scan of every
/// known path per file.
@Suite struct ImportExistingPathTests {
    @Test func aPathKnownInAnotherCaseIsSkipped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-import-case-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("shows/a.mp4"), seconds: 1)
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("shows/b.mp4"), seconds: 1)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Case")
        let source = Source(name: "S", rootPath: root.path)
        try await library.writer.write { db in
            try source.insert(db)
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "Shows/A.mp4", needsReview: false).insert(db)
        }
        let runner = JobRunner(library: library)
        await runner.register(ImportJob.self)

        let record = try await ImportJob.enqueue(on: runner, sourceID: source.id)
        try await runner.runPending()

        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: record.id)! }
        #expect(row.state == .succeeded)
        #expect(row.summary == "1 new, 1 already imported")
        let count = try await library.writer.read { try MediaItem.fetchCount($0) }
        #expect(count == 2)
    }
}
