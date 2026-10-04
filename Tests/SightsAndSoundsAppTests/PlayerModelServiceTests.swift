import AVFoundation
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A player over a service that behaves the way a library on another
/// Mac can: an answer fails, an older answer arrives after a newer one,
/// and the window closes while the library goes on changing.
@Suite @MainActor struct PlayerModelServiceTests {
    struct Fixture {
        let library: LibraryDatabase
        let stub: StubLibraryService
        let root: URL
        let a: MediaItem
        let b: MediaItem
        let unmounted: MediaItem
        let tag: SightsAndSoundsKit.Tag

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("player-service-\(UUID().uuidString)", isDirectory: true)
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "PlayerService")
            let online = Source(name: "Here", rootPath: root.path)
            let away = Source(name: "Away", rootPath: root.appendingPathComponent("not-mounted").path)
            try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 4, variant: 0)
            try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("b.mp4"), seconds: 4, variant: 1)
            let band = TagCategory(name: "Band")
            let tag = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Alpha")
            let a = MediaItem(
                sourceID: online.id, kind: .video, relativePath: "a.mp4", durationSeconds: 4, needsReview: false)
            let b = MediaItem(
                sourceID: online.id, kind: .video, relativePath: "b.mp4", durationSeconds: 4, needsReview: false)
            let unmounted = MediaItem(
                sourceID: away.id, kind: .video, relativePath: "c.mp4", durationSeconds: 4, needsReview: false)
            try await library.writer.write { db in
                try online.insert(db)
                try away.insert(db)
                try band.insert(db)
                try tag.insert(db)
                for item in [a, b, unmounted] { try item.insert(db) }
            }
            self.library = library
            self.a = a
            self.b = b
            self.unmounted = unmounted
            self.tag = tag
            stub = StubLibraryService(LocalLibraryService(library: library))
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        @MainActor func player(_ playlist: [MediaItem]) -> PlayerModel {
            PlayerModel(
                request: PlayerRequest(
                    libraryID: UUID(), itemID: playlist[0].id, playlist: playlist.map(\.id), name: "Test"),
                library: library, appDatabase: nil, service: stub)
        }
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition(), "\(what): never happened")
    }

    @Test func aFailedLoadLetsGoOfTheItemAndSaysWhy() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("the first item") { model.fileURL != nil }

        f.stub.fail("playable(itemID:)")
        model.load(itemID: f.b.id)

        try await waitUntil("the error") { model.loadError != nil }
        #expect(model.item == nil, "the last item is still the one keys act on")
        #expect(model.fileURL == nil)
        #expect(model.loadError?.contains("playable") == true)
    }

    @Test func anItemWithNoPlaybackURLShowsWhyAndStopsTheLast() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a, f.unmounted])
        defer { model.shutdown() }
        try await waitUntil("the first item") { model.fileURL != nil }

        model.load(itemID: f.unmounted.id)

        try await waitUntil("the error") { model.loadError != nil }
        #expect(model.item?.id == f.unmounted.id)
        #expect(model.fileURL == nil)
    }

    /// Stepped to b and straight back to a, with b's answer held up:
    /// the answer to the step no longer wanted must not land on top.
    @Test func aSlowOlderLoadDoesNotReplaceANewerOne() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("the first item") { model.item?.id == f.a.id }
        let before = f.stub.answered("playable(itemID:)")

        f.stub.delay("playable(itemID:)", by: .milliseconds(400))
        model.load(itemID: f.b.id)
        try await waitUntil("b was asked for") { f.stub.calls("playable(itemID:)") == before + 1 }
        model.load(itemID: f.a.id)
        try await waitUntil("both answered") { f.stub.answered("playable(itemID:)") == before + 2 }
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.item?.id == f.a.id)
    }

    @Test func theOpeningQueueIsTheItemsNamedInTheirOrder() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.b, f.a])
        defer { model.shutdown() }
        try await waitUntil("the queue") { model.queue.items.count == 2 }
        #expect(model.queue.items.map(\.id) == [f.b.id, f.a.id])
    }

    @Test func aRefreshThatFailsSaysSoAndKeepsTheQueue() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("the queue") { model.queue.items.count == 2 }

        f.stub.fail("queueItems(_:)")
        model.refreshQueue()

        try await waitUntil("the error") { model.loadError?.hasPrefix("Refresh failed") == true }
        #expect(model.queue.items.count == 2)
    }

    @Test func aTagAppliedElsewhereReachesThePlayer() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("the first item") { model.item?.id == f.a.id }
        #expect(!model.hasTag(f.tag.id))

        try f.library.assignTag(f.tag.id, to: [f.a.id])

        try await waitUntil("the tag") { model.hasTag(f.tag.id) }
    }

    @Test func closingThePlayerEndsItsSubscription() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        try await waitUntil("the first item") { model.item?.id == f.a.id }
        #expect(f.stub.openChangeStreams == 1)

        model.shutdown()

        try await waitUntil("the stream was let go of") { f.stub.openChangeStreams == 0 }
    }
}
