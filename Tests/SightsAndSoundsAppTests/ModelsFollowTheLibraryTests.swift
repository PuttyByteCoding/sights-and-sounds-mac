import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Nobody calls `refreshAll()` in these tests. A window used to hear
/// about a change only if it made it, or if another browse window
/// happened to refresh; the player's edits, a view's direct writes and a
/// background import were invisible to everyone else.
@Suite @MainActor struct ModelsFollowTheLibraryTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func makeLibrary() async throws -> (LibraryDatabase, Source, MediaItem, SightsAndSoundsKit.Tag) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Follow")
        let source = Source(name: "S", rootPath: "/tmp/sas-follow-\(UUID().uuidString)")
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        let band = TagCategory(name: "Band")
        let tag = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Band A")
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
            try band.insert(db)
            try tag.insert(db)
        }
        return (library, source, item, tag)
    }

    @Test func theGridSeesAnItemThatArrivedBehindItsBack() async throws {
        let (library, source, _, _) = try await makeLibrary()
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 1 }

        // What an import job does, from its own task.
        try await library.writer.write { db in
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", needsReview: false).insert(db)
        }

        try await waitUntil { model.items.count == 2 }
    }

    @Test func theSidebarCountsFollowATagAssignedSomewhereElse() async throws {
        let (library, _, item, tag) = try await makeLibrary()
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 1 }
        #expect((model.counts.byTag[tag.id] ?? 0) == 0)

        // What the player does when a tag key is pressed.
        try library.assignTag(tag.id, to: item.id)

        try await waitUntil { (model.counts.byTag[tag.id] ?? 0) == 1 }
    }

    /// The model's own writes need no refresh call after them either:
    /// there is none in `applyTagToSelection` any more.
    @Test func theModelsOwnBulkTagShowsWithoutARefreshCall() async throws {
        let (library, _, item, tag) = try await makeLibrary()
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 1 }
        model.click(item.id, extend: true, range: false)

        model.applyTagToSelection(tag.id)

        try await waitUntil { (model.counts.byTag[tag.id] ?? 0) == 1 }
        try await waitUntil { model.itemTags[item.id]?.map(\.name) == ["Band A"] || !GridDisplaySettings.shared.grid.needsTagData }
    }

    @Test func anOpenPlayerSeesATagRenamedInAnotherWindow() async throws {
        let (library, source, item, tag) = try await makeLibrary()
        // The tag panel only loads for an item that can play.
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 2, variant: 0)
        try library.assignTag(tag.id, to: item.id)
        let player = PlayerModel(
            request: PlayerRequest(libraryID: UUID(), itemID: item.id, playlist: [item.id], name: "One"),
            library: library, appDatabase: nil)
        defer { player.shutdown() }
        try await waitUntil { player.item?.id == item.id }
        try await waitUntil { player.itemTags.flatMap(\.tags).map(\.name) == ["Band A"] }

        // What the Tag Manager does.
        try library.renameTag(tag.id, to: "Band Alpha")

        try await waitUntil { player.itemTags.flatMap(\.tags).map(\.name) == ["Band Alpha"] }
    }
}
