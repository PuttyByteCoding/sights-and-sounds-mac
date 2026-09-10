import AVFoundation
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Every load plays from the top. The stored resume position never
/// drives playback, and neither does whatever the LAST item was doing:
/// its playhead, its seek in flight, its position in the player.
@Suite @MainActor struct PlayerStartPositionTests {
    private func makeLibrary() async throws -> (LibraryDatabase, Source, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-start-\(UUID().uuidString)", isDirectory: true)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "PlayerStart")
        let source = Source(name: "S", rootPath: root.path)
        try await library.writer.write { try source.insert($0) }
        return (library, source, root)
    }

    private func insert(
        _ library: LibraryDatabase, _ source: Source, _ root: URL, _ path: String, variant: Int
    ) async throws -> MediaItem {
        try await DemoMediaFactory.writeVideo(
            to: root.appendingPathComponent(path), seconds: 4, variant: variant)
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: path,
            durationSeconds: 4, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return item
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    /// Polls without sleeping, so the check lands in the gap between the
    /// load settling and the player's first time tick — the gap a slow
    /// file on a network volume holds open for seconds.
    private func spinUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200_000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    /// The gap after a switch and before the first tick is where a
    /// relative seek lands on a big file: "skip the intro" pressed as
    /// the next video comes up must skip from ITS start, not from
    /// wherever the last one was.
    @Test func aRelativeSeekRightAfterTheSwitchCountsFromZero() async throws {
        let (library, source, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await insert(library, source, root, "a.mp4", variant: 0)
        let b = try await insert(library, source, root, "b.mp4", variant: 1)
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: a.id, playlist: [a.id, b.id], name: "Two"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == a.id && model.fileURL != nil }
        model.seek(to: 3)
        try await waitUntil { model.player.currentTime().seconds >= 2.5 }

        model.goNext()
        await spinUntil { model.item?.id == b.id }
        #expect(model.currentSeconds == 0)
        model.seek(by: 0.5)
        #expect(model.currentSeconds == 0.5)
    }

    /// A seek still in flight on the last item is not the next item's.
    @Test func aSeekInFlightOnTheLastItemDoesNotLandOnTheNext() async throws {
        let (library, source, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await insert(library, source, root, "a.mp4", variant: 0)
        let b = try await insert(library, source, root, "b.mp4", variant: 1)
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: a.id, playlist: [a.id, b.id], name: "Two"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == a.id && model.fileURL != nil }
        try await waitUntil { model.player.currentTime().seconds >= 0.3 }
        model.seek(to: 3)
        model.goNext()
        try await waitUntil { model.item?.id == b.id && model.fileURL != nil }
        try await Task.sleep(for: .milliseconds(800))
        #expect(model.player.currentTime().seconds < 1.5)
        #expect(model.currentSeconds < 1.5)
    }

    @Test func theNextItemStartsAtZeroWhateverTheLastOneWasDoing() async throws {
        let (library, source, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await insert(library, source, root, "a.mp4", variant: 0)
        let b = try await insert(library, source, root, "b.mp4", variant: 1)
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: a.id, playlist: [a.id, b.id], name: "Two"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == a.id && model.fileURL != nil }
        // Deep into A, with the position written where Recently Watched
        // reads it — the stored resume that must never drive a load.
        model.seek(to: 3)
        try await waitUntil { model.player.currentTime().seconds >= 2.5 }
        model.pause()

        model.goNext()
        try await waitUntil { model.item?.id == b.id && model.fileURL != nil }
        // The playhead answers for B the moment B is the item: A's
        // three seconds must not linger on the display, nor feed the
        // next relative seek or progress write.
        #expect(model.currentSeconds < 0.5)
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.player.currentTime().seconds < 1.5)
        #expect(model.currentSeconds < 1.5)
    }
}
