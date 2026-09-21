import Foundation
import Testing
@testable import SightsAndSoundsKit

/// What a tile's context menu needs to know about every listed item, in
/// two queries for the whole grid — the menu used to ask per tile, per
/// render, on the main thread.
@Suite struct TileMenuFactsTests {

    private func makeLibrary() throws -> (LibraryDatabase, [MediaItem]) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Menu")
        let source = Source(name: "S", rootPath: "/tmp/sas-menu-facts")
        let items = (0..<3).map {
            MediaItem(sourceID: source.id, kind: .video, relativePath: "v\($0).mp4")
        }
        try library.writer.write { db in
            try source.insert(db)
            for item in items { try item.insert(db) }
        }
        return (library, items)
    }

    @Test func onlyItemsWithAHideBlockAreListed() throws {
        let (library, items) = try makeLibrary()
        try library.writer.write { db in
            try VideoBlock(mediaItemID: items[0].id, startSeconds: 1, endSeconds: 2, kind: .hide).insert(db)
            try VideoBlock(mediaItemID: items[0].id, startSeconds: 5, endSeconds: 6, kind: .hide).insert(db)
            try VideoBlock(mediaItemID: items[1].id, startSeconds: 1, endSeconds: 2, kind: .clip).insert(db)
        }
        #expect(try library.itemIDsWithHideBlocks() == [items[0].id])
    }

    @Test func snapshotsComeNewestFirstCappedPerItemAndWithoutTheirPayload() throws {
        let (library, items) = try makeLibrary()
        let start = Date(timeIntervalSince1970: 1_000_000)
        try library.writer.write { db in
            for n in 0..<12 {
                try EmbeddedTagSnapshot(
                    mediaItemID: items[0].id, capturedAt: start.addingTimeInterval(Double(n)),
                    source: .preWrite, tagsJSON: "{}").insert(db)
            }
            try EmbeddedTagSnapshot(
                mediaItemID: items[1].id, capturedAt: start, source: .preWrite, tagsJSON: "{}").insert(db)
        }

        let refs = try library.recentSnapshotRefs(perItem: 10)

        #expect(refs[items[0].id]?.count == 10)
        #expect(refs[items[0].id]?.first?.capturedAt == start.addingTimeInterval(11))
        #expect(refs[items[1].id]?.count == 1)
        #expect(refs[items[2].id] == nil)
    }
}
