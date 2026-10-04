import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// What the player reads to play something: an item with where its file
/// can be played from, the items of a queue, and which tags they wear.
@Suite struct LocalLibraryServicePlayerReadingTests {
    struct Fixture {
        let library: LibraryDatabase
        let service: LocalLibraryService
        let root: URL
        let source: Source
        let a: MediaItem
        let b: MediaItem
        let segment: MediaItem
        let unmounted: MediaItem
        let alpha: SightsAndSoundsKit.Tag

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-service-player-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("set"), withIntermediateDirectories: true)
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Player")
            let source = Source(name: "Here", rootPath: root.path)
            let away = Source(name: "Away", rootPath: root.path + "-not-mounted")
            let band = TagCategory(name: "Band")
            let alpha = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Alpha")
            let a = MediaItem(
                sourceID: source.id, kind: .video, relativePath: "set/a.mp4", durationSeconds: 60, needsReview: false)
            let b = MediaItem(
                sourceID: source.id, kind: .video, relativePath: "set/b.mp4", durationSeconds: 60, needsReview: false)
            let unmounted = MediaItem(
                sourceID: away.id, kind: .video, relativePath: "c.mp4", needsReview: false)
            try await library.writer.write { db in
                try source.insert(db)
                try away.insert(db)
                try band.insert(db)
                try alpha.insert(db)
                for item in [a, b, unmounted] { try item.insert(db) }
            }
            try library.assignTag(alpha.id, to: [a.id])
            segment = try library.createEmbeddedClip(
                parentID: a.id, name: "Song", startSeconds: 10, endSeconds: 20, role: .song)
            self.library = library
            self.source = source
            self.a = a
            self.b = b
            self.unmounted = unmounted
            self.alpha = alpha
            service = LocalLibraryService(library: library)
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func aPlayableItemComesWithItsFileURL() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let playable = try await f.service.playable(itemID: f.a.id)
        #expect(playable.item?.id == f.a.id)
        #expect(playable.url == f.root.appendingPathComponent("set/a.mp4"))
        #expect(playable.url == (try f.library.resolvedFileURL(for: f.a)))
    }

    @Test func aSegmentPlaysFromItsParentsFile() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let playable = try await f.service.playable(itemID: f.segment.id)
        #expect(playable.item?.id == f.segment.id)
        #expect(playable.item?.clipStartSeconds == 10)
        #expect(playable.url == f.root.appendingPathComponent("set/a.mp4"))
    }

    @Test func anItemOnAnUnmountedSourceHasNoURL() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let playable = try await f.service.playable(itemID: f.unmounted.id)
        #expect(playable.item?.id == f.unmounted.id)
        #expect(playable.url == nil)
    }

    @Test func anItemThatIsGoneIsNil() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.playable(itemID: UUID()) == Playable(item: nil, url: nil))
    }

    @Test func itemsComeBackInTheOrderAskedMinusTheMissing() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let rows = try await f.service.items(ids: [f.b.id, UUID(), f.a.id])
        #expect(rows.map(\.id) == [f.b.id, f.a.id])
        #expect(try await f.service.items(ids: []).isEmpty)
    }

    @Test func eachQueueDefinitionListsWhatItNames() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        // A listing: the grid's own query, in its order.
        let listing = try await f.service.queueItems(
            .listing(filter: MediaFilter(), kinds: .video, ordering: .relativePath))
        #expect(listing == (try f.library.mediaItems(
            matching: MediaFilter(), kinds: .video, orderedBy: .relativePath)))
        #expect(listing.map(\.relativePath).contains("set/a.mp4"))
        // A tag: every item wearing it.
        let tagged = try await f.service.queueItems(.tag(id: f.alpha.id, name: "Alpha"))
        #expect(tagged.map(\.id) == [f.a.id])
        // History: most recently watched first.
        try f.library.recordPlaybackStart(itemID: f.a.id, at: Date(timeIntervalSince1970: 100))
        try f.library.recordPlaybackStart(itemID: f.b.id, at: Date(timeIntervalSince1970: 200))
        let history = try await f.service.queueItems(.history)
        #expect(history.map(\.id) == [f.b.id, f.a.id])
        #expect(history == (try f.library.recentlyWatched()))
        // A fixed set: the given order, minus anything gone.
        let fixed = try await f.service.queueItems(.explicit(ids: [f.b.id, UUID(), f.a.id], name: "Two"))
        #expect(fixed.map(\.id) == [f.b.id, f.a.id])
    }

    @Test func tagMembershipIsByItem() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let membership = try await f.service.tagMembership(itemIDs: [f.a.id, f.b.id])
        #expect(membership == (try f.library.tagIDsByItem(forItems: [f.a.id, f.b.id])))
        #expect(membership[f.a.id] == [f.alpha.id])
        #expect(membership[f.b.id, default: []].isEmpty)
    }

    @Test func textLinesAreInTimeOrderAndNoScanIsPending() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try await f.library.writer.write { db in
            for (time, text) in [(9.0, "later"), (2.0, "sooner")] {
                try db.execute(
                    sql: """
                    INSERT INTO ocrTextLine (id, mediaItemID, timeSeconds, text) VALUES (?, ?, ?, ?)
                    """,
                    arguments: [UUID(), f.a.id, time, text])
            }
        }
        #expect(try await f.service.textLines(itemID: f.a.id).map(\.text) == ["sooner", "later"])
        #expect(try await f.service.textLines(itemID: f.b.id).isEmpty)
        #expect(try await f.service.pendingTextScan(itemID: f.a.id) == (try f.library.pendingOcrScan(of: f.a.id)))
    }

    @Test func everyAnswerSurvivesEncodingAndDecoding() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        func roundTrip<T: Codable & Equatable>(_ value: T) throws {
            let decoded = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
            #expect(decoded == value, "\(T.self) changed in transit")
        }
        try roundTrip(try await f.service.playable(itemID: f.a.id))
        try roundTrip(try await f.service.playable(itemID: f.unmounted.id))
        let definitions: [QueueDefinition] = [
            .listing(filter: MediaFilter(), kinds: .all, ordering: .random(seed: 3)),
            .tag(id: UUID(), name: "Alpha"), .history, .explicit(ids: [UUID(), UUID()], name: "Two"),
        ]
        for definition in definitions { try roundTrip(definition) }
    }

    /// A service made without a runner reads and writes; asked for a
    /// job it says why not, rather than making a second runner for a
    /// library that already has one.
    @Test func aServiceWithNoRunnerRefusesJobs() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        await #expect(throws: ServiceError.noJobRunner) {
            try await f.service.run(.validation, wait: .none)
        }
    }
}
