import Foundation
import Testing

@testable import SightsAndSoundsKit

/// Where an item's file is, worked out from rows a window already holds:
/// the source's folder and the item's path. It has to agree with what the
/// library resolves by asking the database, for a video, for a segment of
/// it, and after the file has been moved.
@Suite struct SourceFileURLTests {
    @Test func aSourceSaysWhereItsItemsAreAsTheLibraryDoes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-source-file-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("set"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("v".utf8).write(to: root.appendingPathComponent("set/show.mp4"))
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "FileURL")
        let source = Source(name: "Here", rootPath: root.path)
        let video = MediaItem(sourceID: source.id, kind: .video, relativePath: "set/show.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try video.insert(db)
        }
        let segment = try library.createEmbeddedClip(
            parentID: video.id, name: "Song", startSeconds: 1, endSeconds: 2)

        #expect(source.fileURL(for: video) == root.appendingPathComponent("set/show.mp4"))
        #expect(source.fileURL(for: video) == (try library.resolvedFileURL(for: video)))
        // A segment's row carries its video's path: the same file.
        #expect(source.fileURL(for: segment) == (try library.resolvedFileURL(for: segment)))

        // Staged: the file moves, and the segment's row moves with it.
        try library.stage(.toDelete, itemID: video.id)
        let moved = try #require(try await library.writer.read { try MediaItem.fetchOne($0, key: video.id) })
        let movedSegment = try #require(
            try await library.writer.read { try MediaItem.fetchOne($0, key: segment.id) })
        #expect(moved.relativePath == "_ToDelete/set/show.mp4")
        #expect(source.fileURL(for: moved) == (try library.resolvedFileURL(for: moved)))
        #expect(source.fileURL(for: movedSegment) == (try library.resolvedFileURL(for: movedSegment)))
    }
}
