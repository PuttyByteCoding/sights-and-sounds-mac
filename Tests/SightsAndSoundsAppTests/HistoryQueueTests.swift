import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// History is the one live queue: another player's load re-runs it;
/// its own plays never reorder it.
@Suite @MainActor struct HistoryQueueTests {
    private func makeLibrary() async throws -> (LibraryDatabase, [MediaItem]) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "HistoryQueue")
        // A real folder with real (empty) files: an offline source never
        // reaches the load, and the load is what is under test.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = Source(name: "S", rootPath: root.path)
        let items = ["a.mp4", "b.mp4", "c.mp4"].map { name in
            FileManager.default.createFile(
                atPath: root.appendingPathComponent(name).path, contents: Data())
            return MediaItem(sourceID: source.id, kind: .video, relativePath: name, needsReview: false)
        }
        try await library.writer.write { db in
            try source.insert(db)
            for item in items { try item.insert(db) }
        }
        return (library, items)
    }

    private func settle(_ model: PlayerModel) async throws {
        for _ in 0..<200 where model.item == nil { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<200 where model.isRefreshingQueue { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func anotherPlayersLoadRerunsTheHistoryQueue() async throws {
        let (library, items) = try await makeLibrary()
        let libraryID = UUID()
        let history = PlayerModel(
            request: PlayerRequest(
                libraryID: libraryID, itemID: items[0].id, definition: .history, playlist: [items[0].id]),
            library: library, appDatabase: nil)
        try await settle(history)
        #expect(history.playlist == [items[0].id])

        let other = PlayerModel(
            request: PlayerRequest(
                libraryID: libraryID, itemID: items[1].id, playlist: [items[1].id], name: "Other"),
            library: library, appDatabase: nil)
        try await settle(other)
        try await settle(history)

        #expect(history.playlist.first == items[1].id)  // b, just loaded elsewhere, leads
        #expect(history.playlist.contains(items[0].id))
        other.shutdown()
        history.shutdown()
    }

    @Test func theHistoryPlayersOwnPlaysDoNotReorderIt() async throws {
        let (library, items) = try await makeLibrary()
        let libraryID = UUID()
        try library.recordPlaybackStart(itemID: items[2].id, at: Date(timeIntervalSince1970: 1_000))
        try library.recordPlaybackStart(itemID: items[0].id, at: Date(timeIntervalSince1970: 2_000))
        let history = PlayerModel(
            request: PlayerRequest(
                libraryID: libraryID, itemID: items[0].id, definition: .history,
                playlist: [items[0].id, items[2].id]),
            library: library, appDatabase: nil)
        try await settle(history)

        history.goNext()  // plays c inside the History player
        try await settle(history)

        #expect(history.item?.id == items[2].id)
        #expect(history.playlist == [items[0].id, items[2].id])  // order untouched
        history.shutdown()
    }
}
