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

/// The thumbnail sweep needs to know which library's cache folder it is
/// filling. A row enqueued without that payload fails on construction
/// with a message about a missing payload — which is what the sweeps
/// panel's Verify button produced. Every enqueue goes through one
/// helper that cannot forget it.
@Suite struct ThumbnailSweepEnqueueTests {

    @Test func enqueueUnlessPendingCarriesTheLibraryID() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Thumbs")
        let runner = JobRunner(library: library)
        await runner.register(ThumbnailBatchJob.self)
        let libraryID = UUID()

        let first = try await ThumbnailBatchJob.enqueueUnlessPending(on: runner, libraryID: libraryID)
        let second = try await ThumbnailBatchJob.enqueueUnlessPending(on: runner, libraryID: libraryID)
        #expect(first != nil)
        #expect(second == nil)  // already pending: signals collapse

        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: first!.id)! }
        #expect(row.state == .succeeded)
        #expect(row.error == nil)
        #expect(row.summary == "0 generated")
    }
}
