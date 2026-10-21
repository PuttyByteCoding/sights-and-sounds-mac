import Foundation
import GRDB
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The bulk bar's one Mark… menu: six items, each a mark or its undo, and
/// each doing to the whole selection what its title says.
@Suite @MainActor struct GridBulkMarkMenuTests {
    private func makeModel() async throws -> (BrowseModel, LibraryDatabase, [MediaItem]) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Mark")
        // Files do not exist: staging then flags without moving, which is
        // the part under test here.
        let source = Source(name: "S", rootPath: "/tmp/sas-mark-\(UUID().uuidString)")
        let items = ["a.mp4", "b.mp4", "c.mp4"].map {
            MediaItem(sourceID: source.id, kind: .video, relativePath: $0, needsReview: false)
        }
        try await library.writer.write { db in
            try source.insert(db)
            for item in items { try item.insert(db) }
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 3 }
        return (model, library, items)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func stored(_ library: LibraryDatabase, _ id: UUID) throws -> MediaItem? {
        try library.writer.read { try MediaItem.fetchOne($0, key: id) }
    }

    /// The menu lists every mark once, a mark beside its undo, and no two
    /// items share a title.
    @Test func theMenuListsEachMarkOnceWithItsUndo() {
        let listed = BulkMark.menuSections.flatMap { $0 }
        #expect(Set(listed) == Set(BulkMark.allCases))
        #expect(listed.count == BulkMark.allCases.count)
        #expect(BulkMark.menuSections.allSatisfy { $0.count == 2 })
        #expect(Set(listed.map(\.title)).count == listed.count)
    }

    @Test func needsReviewGoesOnAndOffForTheSelection() async throws {
        let (model, library, items) = try await makeModel()
        model.click(items[0].id, extend: false, range: false)
        model.click(items[1].id, extend: false, range: false)
        await BulkMark.needsReview.perform(on: model)
        #expect(try stored(library, items[0].id)?.needsReview == true)
        #expect(try stored(library, items[1].id)?.needsReview == true)
        #expect(try stored(library, items[2].id)?.needsReview == false)
        // The selection is cleared once the write has landed.
        #expect(model.selection.isEmpty)

        model.click(items[0].id, extend: false, range: false)
        await BulkMark.reviewed.perform(on: model)
        #expect(try stored(library, items[0].id)?.needsReview == false)
        #expect(try stored(library, items[1].id)?.needsReview == true)
    }

    @Test func theDeletionMarkGoesOnAndOff() async throws {
        let (model, library, items) = try await makeModel()
        model.click(items[2].id, extend: false, range: false)
        await BulkMark.forDeletion.perform(on: model)
        try await waitUntil { (try? self.stored(library, items[2].id)?.markedForDeletion) == true }
        try await waitUntil { model.items.first { $0.id == items[2].id }?.markedForDeletion == true }

        model.click(items[2].id, extend: false, range: false)
        await BulkMark.restoreFromDeletion.perform(on: model)
        try await waitUntil { (try? self.stored(library, items[2].id)?.markedForDeletion) == false }
    }

    @Test func theWontPlayMarkGoesOnAndOff() async throws {
        let (model, library, items) = try await makeModel()
        model.click(items[1].id, extend: false, range: false)
        await BulkMark.wontPlay.perform(on: model)
        try await waitUntil { (try? self.stored(library, items[1].id)?.playbackIssue) == true }
        try await waitUntil { model.items.first { $0.id == items[1].id }?.playbackIssue == true }

        model.click(items[1].id, extend: false, range: false)
        await BulkMark.clearWontPlay.perform(on: model)
        try await waitUntil { (try? self.stored(library, items[1].id)?.playbackIssue) == false }
    }
}
