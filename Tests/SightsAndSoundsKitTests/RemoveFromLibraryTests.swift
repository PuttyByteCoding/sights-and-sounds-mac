import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// Taking items out of the library without touching their files. There is
/// no un-import; this is the way out.
@Suite struct RemoveFromLibraryTests {
    struct Fixture {
        let library: LibraryDatabase
        let source: Source
        let root: URL

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-remove-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Remove")
            source = Source(name: "Root", rootPath: root.path)
            try await library.writer.write { [source] in try source.insert($0) }
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func addItem(_ path: String, parent: UUID? = nil, exported: Bool = false) async throws -> MediaItem {
            if parent == nil { try Data("media".utf8).write(to: root.appendingPathComponent(path)) }
            var item = MediaItem(sourceID: source.id, kind: .video, relativePath: path,
                                 needsReview: false, parentMediaItemID: parent)
            item.clipExported = exported
            try await library.writer.write { [item] in try item.insert($0) }
            return item
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }

        func paths() async throws -> [String] {
            try await library.writer.read { try MediaItem.order(sql: "relativePath").fetchAll($0).map(\.relativePath) }
        }
    }

    @Test func aShowLeavesWithItsSegmentsAndTagsAndItsFileStays() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let show = try await f.addItem("show.mp4")
        let other = try await f.addItem("other.mp4")
        let segment = try await f.addItem("show.mp4#1", parent: show.id)
        let band = TagCategory(name: "Band")
        let tag = Tag(tagCategoryID: band.id, name: "Larks")
        try await f.library.writer.write { db in
            try band.insert(db)
            try tag.insert(db)
            try MediaItemTag(mediaItemID: show.id, tagID: tag.id).insert(db)
            try MediaItemTag(mediaItemID: other.id, tagID: tag.id).insert(db)
        }

        let outcome = try f.library.removeFromLibrary(itemIDs: [show.id])
        #expect(outcome == {
            var o = RemovalOutcome(); o.itemsRemoved = 1; o.segmentsRemoved = 1; return o
        }())
        #expect(try await f.paths() == ["other.mp4"])
        #expect(f.exists("show.mp4"), "the file was touched")
        let taggings = try await f.library.writer.read { try MediaItemTag.fetchCount($0) }
        #expect(taggings == 1, "the other item's tag went too, or the show's stayed")
        _ = segment
    }

    @Test func aSegmentOnItsOwnLeavesAlone() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let show = try await f.addItem("show.mp4")
        let segment = try await f.addItem("show.mp4#1", parent: show.id)
        let outcome = try f.library.removeFromLibrary(itemIDs: [segment.id])
        #expect(outcome.itemsRemoved == 1 && outcome.segmentsRemoved == 0)
        #expect(try await f.paths() == ["show.mp4"])
    }

    @Test func unsavedSegmentsAreNamedWhetherOrNotTheShowIsFlagged() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let show = try await f.addItem("show.mp4")
        let kept = try await f.addItem("show.mp4#1", parent: show.id)
        try await f.addItem("show.mp4#2", parent: show.id, exported: true)
        let unsaved = try f.library.unsavedSegments(of: [show.id])
        #expect(unsaved.map(\.parentID) == [show.id])
        #expect(unsaved.first?.segmentIDs == [kept.id], "an exported segment is saved; it does not count")
        #expect(try f.library.unsavedSegments(ofFlagged: [show.id]).isEmpty, "the delete list's question needs the flag")
    }

    /// Asked to write the tags first, the job keeps an item whose tags it
    /// could not write: removing it would lose them for good.
    @Test func anItemWhoseTagsCannotBeWrittenIsKept() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let here = try await f.addItem("here.mp4")
        // A file that is gone cannot take its tags.
        let gone = try await f.addItem("gone.mp4")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("gone.mp4"))
        // Nothing to write for this one: no write-back-enabled category.
        let band = TagCategory(name: "Band", writebackEnabled: false)
        let tag = Tag(tagCategoryID: band.id, name: "Larks")
        try await f.library.writer.write { db in
            try band.insert(db)
            try tag.insert(db)
            try MediaItemTag(mediaItemID: here.id, tagID: tag.id).insert(db)
            try MediaItemTag(mediaItemID: gone.id, tagID: tag.id).insert(db)
        }

        let job = RemoveFromLibraryJob(
            payload: .init(itemIDs: [here.id, gone.id], writeTagsFirst: true), fileAccess: LiveFileAccess())
        final class Summary: @unchecked Sendable { var text: String? }
        let summary = Summary()
        try await job.run(JobContext(
            library: f.library, jobID: UUID(),
            progressHandler: { _, _ in }, cancellationCheck: { false },
            summaryHandler: { summary.text = $0 }))

        #expect(try await f.paths() == ["gone.mp4"], "the item whose file is gone was removed with its tags unwritten")
        let text = try #require(summary.text)
        #expect(text.hasPrefix("1 removed from the library, files kept"), Comment(rawValue: text))
        #expect(text.contains("1 kept in the library: gone.mp4"), Comment(rawValue: text))
    }
}
