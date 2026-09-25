import Foundation
import GRDB
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The grid selects with a plain click, and the bulk bar does the same
/// thing to everything selected: the two marks on and off, a tag on and
/// off, and the player opened with the selection as its queue.
@Suite @MainActor struct BulkSelectionActionsTests {
    private func makeModel() async throws -> (BrowseModel, LibraryDatabase, [MediaItem], SightsAndSoundsKit.Tag) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Bulk")
        // Files do not exist: staging then flags without moving, which is
        // the part under test here.
        let source = Source(name: "S", rootPath: "/tmp/sas-bulk-\(UUID().uuidString)")
        let items = ["a.mp4", "b.mp4", "c.mp4"].map {
            MediaItem(sourceID: source.id, kind: .video, relativePath: $0, needsReview: false)
        }
        let category = TagCategory(name: "Band")
        let tag = SightsAndSoundsKit.Tag(tagCategoryID: category.id, name: "Blue Orchestra")
        try await library.writer.write { db in
            try source.insert(db)
            for item in items { try item.insert(db) }
            try category.insert(db)
            try tag.insert(db)
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 3 }
        return (model, library, items, tag)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func stored(_ library: LibraryDatabase, _ id: UUID) throws -> MediaItem? {
        try library.writer.read { try MediaItem.fetchOne($0, key: id) }
    }

    @Test func aPlainClickTicksAndASecondUnticks() async throws {
        let (model, _, items, _) = try await makeModel()
        model.click(items[0].id, extend: false, range: false)
        model.click(items[2].id, extend: false, range: false)
        #expect(model.selection == [items[0].id, items[2].id])
        model.click(items[0].id, extend: false, range: false)
        #expect(model.selection == [items[2].id])
        // ⇧-click ticks the run from the last tick.
        model.click(items[0].id, extend: false, range: true)
        #expect(model.selection == Set(items.map(\.id)))
    }

    @Test func theDeletionMarkGoesOnAndOffForTheWholeSelection() async throws {
        let (model, library, items, _) = try await makeModel()
        model.click(items[0].id, extend: false, range: false)
        model.click(items[1].id, extend: false, range: false)
        model.markSelectionForDeletion()
        try await waitUntil {
            (try? self.stored(library, items[0].id)?.markedForDeletion) == true
                && (try? self.stored(library, items[1].id)?.markedForDeletion) == true
        }
        #expect(try stored(library, items[2].id)?.markedForDeletion == false)
        #expect(model.selection.isEmpty)

        try await waitUntil { model.items.filter(\.markedForDeletion).count == 2 }
        model.click(items[0].id, extend: false, range: false)
        model.click(items[1].id, extend: false, range: false)
        model.click(items[2].id, extend: false, range: false)  // never marked: left alone
        model.unmarkSelectionForDeletion()
        try await waitUntil {
            (try? self.stored(library, items[0].id)?.markedForDeletion) == false
                && (try? self.stored(library, items[1].id)?.markedForDeletion) == false
        }
    }

    @Test func theWontPlayMarkGoesOnAndOff() async throws {
        let (model, library, items, _) = try await makeModel()
        model.click(items[1].id, extend: false, range: false)
        model.markSelectionWontPlay()
        try await waitUntil { (try? self.stored(library, items[1].id)?.playbackIssue) == true }
        try await waitUntil { model.items.first { $0.id == items[1].id }?.playbackIssue == true }
        model.click(items[1].id, extend: false, range: false)
        model.unmarkSelectionWontPlay()
        try await waitUntil { (try? self.stored(library, items[1].id)?.playbackIssue) == false }
    }

    @Test func aTagIsAppliedToAndRemovedFromTheSelection() async throws {
        let (model, library, items, tag) = try await makeModel()
        model.click(items[0].id, extend: false, range: false)
        model.click(items[2].id, extend: false, range: false)
        model.applyTagToSelection(tag.id)
        func tagged(_ id: UUID) throws -> Bool {
            try library.writer.read {
                try MediaItemTag.filter(sql: "mediaItemID = ? AND tagID = ?", arguments: [id, tag.id]).fetchCount($0) > 0
            }
        }
        #expect(try tagged(items[0].id) && tagged(items[2].id))
        #expect(try !tagged(items[1].id))

        // The one in the middle has no such tag; removing from all three
        // is fine.
        model.click(items[1].id, extend: false, range: false)
        model.removeTagFromSelection(tag.id)
        #expect(try !tagged(items[0].id) && !tagged(items[1].id) && !tagged(items[2].id))
    }

    @Test func playTheseOpensThePlayerWithTheSelectionInListingOrder() async throws {
        let (model, _, items, _) = try await makeModel()
        // The player refuses an offline source, so the root has to exist.
        let root = URL(fileURLWithPath: model.sources[0].rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        model.refreshAll()
        try await waitUntil { model.isOnline(items[0]) }
        // Ticked out of order; the queue is the listing's order.
        model.click(items[2].id, extend: false, range: false)
        model.click(items[0].id, extend: false, range: false)
        model.queueSelection()
        let request = try #require(model.playerRequest)
        #expect(request.itemID == items[0].id)
        #expect(request.playlist == [items[0].id, items[2].id])
        #expect(model.selection.isEmpty)
    }
}
