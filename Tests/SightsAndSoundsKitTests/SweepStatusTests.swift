import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The numbers beside the sweep buttons must agree with what the sweeps
/// themselves would do.
@Suite struct SweepStatusTests {

    @Test func thumbnailStatusCountsVideoItemsWithoutACacheFile() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Thumbs")
        let source = Source(name: "S", rootPath: "/tmp/thumbs")
        try await library.writer.write { db in
            try source.insert(db)
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false).insert(db)
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", needsReview: false).insert(db)
            try MediaItem(sourceID: source.id, kind: .audio, relativePath: "c.mp3", needsReview: false).insert(db)
        }

        // A library ID nothing has ever written a thumbnail for.
        let status = try library.thumbnailStatus(libraryID: UUID())
        #expect(status.missing == 2)  // the two videos; audio has no frames
        #expect(status.failed == 0)
    }
}
