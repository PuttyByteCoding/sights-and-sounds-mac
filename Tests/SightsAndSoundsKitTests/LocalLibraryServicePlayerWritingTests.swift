import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// What the player records as it plays, and the flags it sets on the
/// item it shows.
@Suite struct LocalLibraryServicePlayerWritingTests {
    struct Fixture {
        let library: LibraryDatabase
        let service: LocalLibraryService
        let root: URL
        let a: MediaItem
        let b: MediaItem
        let band: TagCategory
        let year: TagCategory
        let alpha: SightsAndSoundsKit.Tag
        let beta: SightsAndSoundsKit.Tag
        let y1995: SightsAndSoundsKit.Tag
        let y1996: SightsAndSoundsKit.Tag

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-service-player-writing-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("a".utf8).write(to: root.appendingPathComponent("a.mp4"))
            try Data("b".utf8).write(to: root.appendingPathComponent("b.mp4"))
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "PlayerWriting")
            let source = Source(name: "Here", rootPath: root.path)
            let a = MediaItem(
                sourceID: source.id, kind: .video, relativePath: "a.mp4", durationSeconds: 600, needsReview: true)
            let b = MediaItem(
                sourceID: source.id, kind: .video, relativePath: "b.mp4", durationSeconds: 600, needsReview: true)
            let band = TagCategory(name: "Band", sortOrder: 0)
            let year = TagCategory(name: "Year", allowMultiple: false, sortOrder: 1)
            let alpha = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Alpha")
            let beta = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Beta")
            let y1995 = SightsAndSoundsKit.Tag(tagCategoryID: year.id, name: "1995")
            let y1996 = SightsAndSoundsKit.Tag(tagCategoryID: year.id, name: "1996")
            try await library.writer.write { db in
                try source.insert(db)
                try a.insert(db)
                try b.insert(db)
                for category in [band, year] { try category.insert(db) }
                for tag in [alpha, beta, y1995, y1996] { try tag.insert(db) }
            }
            self.band = band
            self.year = year
            self.alpha = alpha
            self.beta = beta
            self.y1995 = y1995
            self.y1996 = y1996
            self.library = library
            self.a = a
            self.b = b
            service = LocalLibraryService(library: library)
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        func tagIDs(of item: MediaItem) throws -> Set<UUID> {
            Set(try library.writer.read { db in
                try UUID.fetchAll(
                    db, sql: "SELECT tagID FROM mediaItemTag WHERE mediaItemID = ?", arguments: [item.id])
            })
        }

        func row(_ item: MediaItem) throws -> MediaItem {
            try #require(try library.writer.read { try MediaItem.fetchOne($0, key: item.id) })
        }

        /// What playback history writes, as one comparable value.
        func history(_ item: MediaItem) throws -> [String] {
            let row = try row(item)
            return [
                "\(row.resumePositionSeconds ?? -1)", "\(row.lastWatchedAt?.timeIntervalSince1970 ?? -1)",
                "\(row.watchCount)", "\(row.completed)",
            ]
        }
    }

    /// Each event through the service on one item, and the library's own
    /// call on another: the rows end the same.
    @Test func eachPlaybackEventWritesWhatItsOwnCallWrites() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let started = Date(timeIntervalSince1970: 1_000)
        try await f.service.recordPlayback(.started(itemID: f.a.id, at: started))
        try f.library.recordPlaybackStart(itemID: f.b.id, at: started)
        #expect(try f.history(f.a) == f.history(f.b))

        let stopped = Date(timeIntervalSince1970: 2_000)
        try await f.service.recordPlayback(
            .stopped(itemID: f.a.id, positionSeconds: 120, durationSeconds: 600, at: stopped))
        try f.library.recordPlaybackStop(itemID: f.b.id, positionSeconds: 120, durationSeconds: 600, at: stopped)
        #expect(try f.history(f.a) == f.history(f.b))
        #expect(try f.row(f.a).resumePositionSeconds == 120)

        let completed = Date(timeIntervalSince1970: 3_000)
        try await f.service.recordPlayback(.completed(itemID: f.a.id, at: completed))
        try f.library.recordPlaybackCompletion(itemID: f.b.id, at: completed)
        #expect(try f.history(f.a) == f.history(f.b))
        #expect(try f.row(f.a).watchCount == 1)
    }

    /// The time is the player's, taken when it happened: a request that
    /// arrives late must not say the video was watched late.
    @Test func anEventKeepsTheTimeItWasStampedWith() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let then = Date(timeIntervalSince1970: 86_400)
        try await f.service.recordPlayback(.started(itemID: f.a.id, at: then))
        #expect(try f.row(f.a).lastWatchedAt == then)
    }

    @Test func aPlainFlagChangesOnlyItsColumnAndReturnsTheRow() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let favourite = try await f.service.setFlag(.favorite, true, itemID: f.a.id)
        #expect(favourite.item?.isFavorite == true)
        #expect(favourite.item?.needsReview == true, "the other flag moved")
        #expect(favourite.url == f.root.appendingPathComponent("a.mp4"))

        let reviewed = try await f.service.setFlag(.needsReview, false, itemID: f.a.id)
        #expect(reviewed.item?.needsReview == false && reviewed.item?.isFavorite == true)
        #expect(reviewed.item == (try f.row(f.a)))

        // Set to what it already is: nothing changes.
        #expect(try await f.service.setFlag(.favorite, true, itemID: f.a.id).item == reviewed.item)
        #expect(try !f.row(f.b).isFavorite)
    }

    @Test func markingForDeletionStagesTheFileAndReturnsItsNewURL() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let marked = try await f.service.setFlag(.markedForDeletion, true, itemID: f.a.id)
        #expect(marked.item?.markedForDeletion == true)
        #expect(marked.item?.relativePath == "_ToDelete/a.mp4")
        #expect(marked.url == f.root.appendingPathComponent("_ToDelete/a.mp4"))
        #expect(FileManager.default.fileExists(atPath: try #require(marked.url).path))

        let restored = try await f.service.setFlag(.markedForDeletion, false, itemID: f.a.id)
        #expect(restored.item?.markedForDeletion == false)
        #expect(restored.url == f.root.appendingPathComponent("a.mp4"))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("a.mp4").path))
    }

    @Test func aPlaybackIssueIsStagedInItsOwnFolder() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let marked = try await f.service.setFlag(.playbackIssue, true, itemID: f.b.id)
        #expect(marked.item?.playbackIssue == true)
        #expect(marked.item?.relativePath == "_PlaybackIssue/b.mp4")
    }

    @Test func aFlagOnAnItemThatIsGone() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        // A plain flag has nothing to change and nothing to return.
        #expect(try await f.service.setFlag(.favorite, true, itemID: UUID()) == Playable(item: nil, url: nil))
        // A staging flag has a file to move, and says the item is gone.
        await #expect(throws: MoveError.self) {
            _ = try await f.service.setFlag(.markedForDeletion, true, itemID: UUID())
        }
    }

    @Test func eventsAndFlagsSurviveEncodingAndDecoding() throws {
        let events: [PlaybackEvent] = [
            .started(itemID: UUID(), at: Date(timeIntervalSince1970: 10)),
            .stopped(itemID: UUID(), positionSeconds: 12.5, durationSeconds: nil, at: Date(timeIntervalSince1970: 20)),
            .stopped(itemID: UUID(), positionSeconds: 12.5, durationSeconds: 600, at: Date(timeIntervalSince1970: 20)),
            .completed(itemID: UUID(), at: Date(timeIntervalSince1970: 30)),
        ]
        for event in events {
            #expect(try JSONDecoder().decode(PlaybackEvent.self, from: JSONEncoder().encode(event)) == event)
        }
        for flag in PlayerToggleFlag.allCases {
            #expect(try JSONDecoder().decode(PlayerToggleFlag.self, from: JSONEncoder().encode(flag)) == flag)
        }
        #expect(PlayerToggleFlag.allCases.count == 4)
    }

    // MARK: - The tag panel

    @Test func togglingReturnsWhetherTheTagIsNowOn() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.toggleTag(f.alpha.id, on: f.a.id) == true)
        #expect(try f.tagIDs(of: f.a) == [f.alpha.id])
        #expect(try await f.service.toggleTag(f.alpha.id, on: f.a.id) == false)
        #expect(try f.tagIDs(of: f.a).isEmpty)
        #expect(try f.tagIDs(of: f.b).isEmpty)
    }

    @Test func aSingleSelectCategoryReplacesOnToggle() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        _ = try await f.service.toggleTag(f.y1995.id, on: f.a.id)
        _ = try await f.service.toggleTag(f.alpha.id, on: f.a.id)
        #expect(try await f.service.toggleTag(f.y1996.id, on: f.a.id) == true)
        #expect(try f.tagIDs(of: f.a) == [f.y1996.id, f.alpha.id])
    }

    @Test func renamingToANameInUseIsRefused() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        await #expect(throws: (any Error).self) {
            try await f.service.renameTag(f.beta.id, to: "alpha")
        }
        try await f.service.renameTag(f.beta.id, to: "  Beta Prime  ")
        let names = try f.library.vocabulary().first { $0.category.id == f.band.id }?.tags.map(\.name)
        #expect(names == ["Alpha", "Beta Prime"])
    }

    @Test func ensureTagReturnsTheExistingOneWhateverItsCase() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.ensureTag(named: "ALPHA", inCategory: f.band.id).id == f.alpha.id)
        let made = try await f.service.ensureTag(named: "Gamma", inCategory: f.band.id)
        #expect(made.name == "Gamma" && made.tagCategoryID == f.band.id)
        #expect(try await f.service.ensureTag(named: "gamma", inCategory: f.band.id).id == made.id)
    }

    @Test func anAliasIsAddedAndAnEmptyOneIsNot() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try await f.service.addAlias("A", toTag: f.alpha.id)
        try await f.service.addAlias("   ", toTag: f.alpha.id)
        let aliases = try await f.library.writer.read { try TagAlias.fetchAll($0) }
        #expect(aliases.map(\.alias) == ["A"])
    }

    @Test func categoryOrderIsStored() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try await f.service.setCategoryOrder([f.year.id, f.band.id])
        #expect(try f.library.vocabulary().map(\.category.name) == ["Year", "Band"])
    }

    @Test func aKeyIsBoundReboundAndUnbound() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try await f.service.setKeyBinding("1", tagID: f.alpha.id, advance: false)
        try await f.service.setKeyBinding("1", tagID: f.beta.id, advance: true)
        let bound = try f.library.keyBindings()
        #expect(bound.map(\.key) == ["1"])
        #expect(bound.first?.tagID == f.beta.id && bound.first?.advance == true)
        try await f.service.removeKeyBinding("1")
        #expect(try f.library.keyBindings().isEmpty)
    }
}
