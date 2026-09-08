import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The player's queue is its own: nothing outside replaces it, Refresh
/// re-runs its definition, and a refresh never stops playback.
@Suite @MainActor struct PlayerQueueTests {
    private func makeLibrary() async throws -> (LibraryDatabase, Source) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "PlayerQueue")
        let source = Source(name: "S", rootPath: "/tmp/pq-\(UUID().uuidString)")
        try await library.writer.write { try source.insert($0) }
        return (library, source)
    }

    private func insert(_ library: LibraryDatabase, _ source: Source, _ path: String) async throws -> MediaItem {
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: path, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return item
    }

    private func settle(_ model: PlayerModel) async throws {
        for _ in 0..<200 where model.item == nil { try await Task.sleep(for: .milliseconds(25)) }
        for _ in 0..<200 where model.isRefreshingQueue { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func refreshRerunsTheDefinitionAndKeepsTheShownItem() async throws {
        let (library, source) = try await makeLibrary()
        let a = try await insert(library, source, "a.mp4")
        let b = try await insert(library, source, "b.mp4")
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: a.id,
                definition: .listing(filter: MediaFilter(), kinds: .video, ordering: .relativePath),
                playlist: [a.id, b.id]),
            library: library, appDatabase: nil)
        try await settle(model)
        #expect(model.playlist == [a.id, b.id])

        _ = try await insert(library, source, "c.mp4")
        #expect(model.playlist == [a.id, b.id])  // nothing outside touches it

        model.refreshQueue()
        try await settle(model)
        #expect(model.playlist.count == 3)
        #expect(model.item?.id == a.id)
    }

    @Test func aRefreshThatDropsTheShownItemLeavesItPlayingAndWalksFromTheEnds() async throws {
        let (library, source) = try await makeLibrary()
        let a = try await insert(library, source, "a.mp4")
        let b = try await insert(library, source, "b.mp4")
        let model = PlayerModel(
            request: PlayerRequest(libraryID: UUID(), itemID: a.id, playlist: [a.id, b.id], name: "Pair"),
            library: library, appDatabase: nil)
        try await settle(model)

        try await library.writer.write { db in _ = try MediaItem.deleteOne(db, key: a.id) }
        model.refreshQueue()
        try await settle(model)
        #expect(model.playlist == [b.id])
        #expect(model.item?.id == a.id)  // still the shown item

        model.goNext()
        try await settle(model)
        #expect(model.item?.id == b.id)  // from the top of what is left
    }
}
