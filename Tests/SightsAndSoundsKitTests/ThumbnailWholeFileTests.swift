import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// A thumbnail on disk counts as done only when it is a whole JPEG. The
/// cache file used to be written in place, so a crash mid-write left a
/// truncated file — and the sweep, checking only that a file existed,
/// never made it again.
@Suite(.writesVideo) struct ThumbnailWholeFileTests {
    @Test func aTruncatedThumbnailIsMadeAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-thumb-whole-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 2, variant: 1)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Thumbs")
        let source = Source(name: "S", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", durationSeconds: 2, needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }
        let libraryID = UUID()
        let thumb = ThumbnailStore.url(libraryID: libraryID, itemID: item.id)
        defer { try? FileManager.default.removeItem(at: thumb.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A JPEG cut off after its first bytes: no end-of-image marker.
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).write(to: thumb)

        let job = try ThumbnailBatchJob(payload: JSONEncoder().encode(ThumbnailBatchJob.Payload(libraryID: libraryID)))
        try await job.run(JobContext(
            library: library, jobID: UUID(), progressHandler: { _, _ in },
            cancellationCheck: { false }, summaryHandler: { _ in }))

        let data = try Data(contentsOf: thumb)
        #expect(data.count > 6)
        #expect(data.suffix(2) == Data([0xFF, 0xD9]))
    }
}
