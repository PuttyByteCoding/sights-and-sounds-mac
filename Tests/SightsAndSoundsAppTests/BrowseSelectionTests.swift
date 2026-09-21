import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// "N selected" and every bulk action must mean the same N: the tiles
/// that are on screen and ticked. The selection used to outlive the
/// listing it was made in, so narrowing a search left the bar saying 10,
/// Delete staging 3, and Add Tag tagging 10.
@Suite @MainActor struct BrowseSelectionTests {
    private func makeModel() async throws -> (BrowseModel, [MediaItem]) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Selection")
        let source = Source(name: "S", rootPath: "/tmp/sas-selection-\(UUID().uuidString)")
        let items = ["alpha.mp4", "beta.mp4", "gamma.mp4"].map {
            MediaItem(sourceID: source.id, kind: .video, relativePath: $0, needsReview: false)
        }
        try await library.writer.write { db in
            try source.insert(db)
            for item in items { try item.insert(db) }
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 3 }
        return (model, items)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func narrowingTheListingNarrowsTheSelection() async throws {
        let (model, items) = try await makeModel()
        model.click(items[0].id, extend: true, range: false)
        model.click(items[1].id, extend: false, range: false)
        #expect(model.selection.count == 2)

        model.filter.searchText = "alpha"
        try await waitUntil { model.items.count == 1 }

        #expect(model.selection == [items[0].id])
        #expect(model.selectedItems.map(\.id) == [items[0].id])
    }

    @Test func aSelectionThatLeavesTheListingEntirelyIsGone() async throws {
        let (model, items) = try await makeModel()
        model.click(items[2].id, extend: true, range: false)

        model.filter.searchText = "alpha"
        try await waitUntil { model.items.count == 1 }

        #expect(model.selection.isEmpty)
    }
}
