import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// "3 failed" with no way to learn why is a dead end: the summary names
/// the first failures and their reasons.
@Suite struct ReorganizeFailureReasonTests {
    @Test func aFailedMoveIsNamedWithItsReason() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-reorg-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        // The row says the file is there; the disk does not have it.
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "R")
        let source = Source(name: "S", rootPath: root.path)
        let band = TagCategory(name: "Band")
        let larks = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Larks")
        let missing = MediaItem(sourceID: source.id, kind: .video, relativePath: "inbox/missing.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
            try larks.insert(db)
            try missing.insert(db)
            try MediaItemTag(mediaItemID: missing.id, tagID: larks.id).insert(db)
        }

        let runner = JobRunner(library: library)
        await runner.register(ReorganizeJob.self)
        let record = try await ReorganizeJob.enqueue(on: runner, template: "%Band", itemIDs: [missing.id])
        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: record.id)! }

        let summary = try #require(row.summary)
        #expect(summary.hasPrefix("0 moved, 0 skipped, 1 failed"))
        #expect(summary.contains("missing.mp4"))
    }
}
