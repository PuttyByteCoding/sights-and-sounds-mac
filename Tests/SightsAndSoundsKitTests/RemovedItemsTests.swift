import Foundation
import Testing

@testable import SightsAndSoundsKit

/// A file removed from the library is still under its source, so the next
/// scan would list it as new and the next Update would offer to import it
/// back. The removal is remembered: the scan shows it as removed, not new,
/// and importing it again — a choice made per file — forgets the removal.
@Suite struct RemovedItemsTests {
    private func makeSource(files: [String], in library: LibraryDatabase) throws -> (Source, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-removed-\(UUID().uuidString)", isDirectory: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let source = try library.addSource(named: "Scan", rootPath: root.path)
        return (source, root)
    }

    @Test func aRemovedFileScansAsRemovedNotNew() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Removed")
        let (source, root) = try makeSource(files: ["shows/a.mp4", "shows/b.mp4"], in: library)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/a.mp4", needsReview: false)
        try await library.writer.write { try a.insert($0) }

        try library.removeFromLibrary(itemIDs: [a.id])
        #expect(try library.removedItems().map(\.relativePath) == ["shows/a.mp4"])

        let outcome = try await MediaScanner.scan(source: source, library: library)
        let scannedA = try #require(outcome.candidates.first { $0.relativePath == "shows/a.mp4" })
        #expect(scannedA.isRemoved && !scannedA.isKnown && !scannedA.isNew)
        #expect(outcome.newCount == 1, "the removed file counted as new")
        #expect(outcome.removedCount == 1)
        #expect(outcome.folders().first?.new == 1)
    }

    @Test func importingARemovedFileAgainForgetsTheRemoval() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Removed")
        let (source, root) = try makeSource(files: ["shows/a.mp4"], in: library)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/a.mp4", needsReview: false)
        try await library.writer.write { try a.insert($0) }
        try library.removeFromLibrary(itemIDs: [a.id])

        // Named, as the window names a ticked row — spelled differently,
        // as the library's NOCASE paths allow.
        let runner = JobRunner(library: library)
        _ = try await ImportJob.enqueue(on: runner, sourceID: source.id, relativePaths: ["Shows/A.MP4"])
        try await runner.runPending()
        #expect(try library.removedItems().isEmpty, "the removal was not forgotten on re-import")
        let rescanned = try await MediaScanner.scan(source: source, library: library)
        #expect(rescanned.candidates.first?.isKnown == true)
        #expect(rescanned.removedCount == 0)
    }

    @Test func removingASegmentRemembersNothing() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Removed")
        let (source, root) = try makeSource(files: ["show.mp4"], in: library)
        defer { try? FileManager.default.removeItem(at: root) }
        let show = MediaItem(sourceID: source.id, kind: .video, relativePath: "show.mp4", needsReview: false)
        let part = MediaItem(sourceID: source.id, kind: .video, relativePath: "show.mp4#1",
                             needsReview: false, parentMediaItemID: show.id)
        try await library.writer.write { db in
            try show.insert(db)
            try part.insert(db)
        }
        try library.removeFromLibrary(itemIDs: [part.id])
        #expect(try library.removedItems().isEmpty, "a segment is part of its show's file, not a file of its own")
    }
}
