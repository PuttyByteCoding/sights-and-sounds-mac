import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The Background Tasks sweeps panel shows "missing" and "failed" beside
/// each sweep. For thumbnails, failures were said to self-heal and the
/// failed count was always zero — but the sweep records them and skips
/// them, so one corrupt video read "1 missing, 0 failed" forever with no
/// retry short of deleting every thumbnail. For hashes, an item that
/// failed counted as missing as well, so "missing" never reached zero.
@Suite struct SweepStatusFailureTests {
    private func library() async throws -> (LibraryDatabase, MediaItem) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Status")
        let source = Source(name: "S", rootPath: TestRoots.unreachable("status"))
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "broken.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }
        return (library, item)
    }

    @Test func aThumbnailFailureIsCountedAsFailedAndCanBeRetried() async throws {
        let (library, item) = try await library()
        let libraryID = UUID()
        try await library.writer.write { db in
            try ThumbnailState(mediaItemID: item.id, generated: false, failureMessage: "no frame").upsert(db)
        }

        #expect(try library.thumbnailStatus(libraryID: libraryID) == SweepStatus(missing: 0, failed: 1))

        try library.retryThumbnailFailures()
        #expect(try library.thumbnailStatus(libraryID: libraryID) == SweepStatus(missing: 1, failed: 0))
    }

    @Test func aHashFailureIsFailedNotAlsoMissing() async throws {
        let (library, item) = try await library()
        try await library.writer.write { db in
            try ContentHashFailure(mediaItemID: item.id, message: "timed out").insert(db)
        }
        #expect(try library.contentHashStatus() == SweepStatus(missing: 0, failed: 1))
    }
}
