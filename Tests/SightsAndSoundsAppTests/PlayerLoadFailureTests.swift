import AVFoundation
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A load that cannot play anything must leave nothing playing: not the
/// last item's picture under the new item's title, and not a file URL
/// that still answers for the last item.
@Suite @MainActor struct PlayerLoadFailureTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    /// One source with a real file, and a second whose drive is not there.
    private func makeLibrary() async throws -> (LibraryDatabase, playable: MediaItem, offline: MediaItem, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-load-failure-\(UUID().uuidString)", isDirectory: true)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "LoadFailure")
        let online = Source(name: "Here", rootPath: root.path)
        let unplugged = Source(name: "Unplugged", rootPath: root.appendingPathComponent("not-mounted").path)
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 4, variant: 0)
        let playable = MediaItem(
            sourceID: online.id, kind: .video, relativePath: "a.mp4", durationSeconds: 4, needsReview: false)
        let offline = MediaItem(
            sourceID: unplugged.id, kind: .video, relativePath: "b.mp4", durationSeconds: 4, needsReview: false)
        try await library.writer.write { db in
            try online.insert(db)
            try unplugged.insert(db)
            try playable.insert(db)
            try offline.insert(db)
        }
        return (library, playable, offline, root)
    }

    @Test func steppingOntoAnOfflineItemStopsTheLastOne() async throws {
        let (library, playable, offline, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: playable.id, playlist: [playable.id, offline.id], name: "Two"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == playable.id && model.isPlaying }

        model.goNext()
        try await waitUntil { model.item?.id == offline.id }

        #expect(model.loadError != nil)
        #expect(!model.isPlaying)
        #expect(model.fileURL == nil)  // never the last item's file under this title
        #expect(model.player.currentItem == nil)
        #expect(model.currentSeconds == 0)
    }

    @Test func anItemThatNoLongerExistsStopsTheLastOneToo() async throws {
        let (library, playable, offline, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: playable.id, playlist: [playable.id, offline.id], name: "Two"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == playable.id && model.isPlaying }
        try await library.writer.write { _ = try MediaItem.deleteOne($0, key: offline.id) }

        model.goNext()
        try await waitUntil { model.loadError != nil }

        #expect(!model.isPlaying)
        #expect(model.fileURL == nil)
        #expect(model.player.currentItem == nil)
    }

    @Test func aFileThePlayerCannotOpenSaysSoInsteadOfClaimingToPlay() async throws {
        let (library, playable, _, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a movie".utf8).write(to: root.appendingPathComponent("broken.mp4"))
        let broken = MediaItem(
            sourceID: playable.sourceID, kind: .video, relativePath: "broken.mp4", needsReview: false)
        try await library.writer.write { try broken.insert($0) }
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: broken.id, playlist: [broken.id], name: "One"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }

        try await waitUntil { model.loadError != nil }

        #expect(model.loadError?.contains("could not be played") == true)
        #expect(!model.isPlaying)
        #expect(model.player.currentItem == nil)
    }
}
