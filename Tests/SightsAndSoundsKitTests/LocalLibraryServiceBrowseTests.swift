import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// What the Browse window's sidebar asks of a library, through the
/// service a window is given rather than the database itself. The local
/// service answers from the library on this machine; the same questions
/// are what a library on another Mac will be asked over the wire, so each
/// answer is a plain value that survives being encoded and decoded.
@Suite struct LocalLibraryServiceBrowseTests {
    /// A library with one of everything the sidebar draws.
    struct Fixture {
        let library: LibraryDatabase
        let service: LocalLibraryService
        let root: URL
        let online: Source
        let offline: Source
        let disabled: Source
        let band: TagCategory
        let hidden: TagCategory
        let alpha: SightsAndSoundsKit.Tag
        let items: [MediaItem]

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-service-browse-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Service")
            online = Source(name: "Here", rootPath: root.path)
            offline = Source(name: "Away", rootPath: root.path + "-not-mounted")
            var off = Source(name: "Off", rootPath: root.path)
            off.enabled = false
            disabled = off
            band = TagCategory(name: "Band", sortOrder: 0)
            hidden = TagCategory(name: "Internal", sortOrder: 1, hiddenFromBrowse: true)
            alpha = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Alpha")
            let secret = SightsAndSoundsKit.Tag(tagCategoryID: hidden.id, name: "Secret")
            items = [
                MediaItem(sourceID: online.id, kind: .video, relativePath: "shows/1995/a.mp4", needsReview: false),
                MediaItem(sourceID: online.id, kind: .video, relativePath: "shows/b.mp4", needsReview: false),
                MediaItem(sourceID: offline.id, kind: .video, relativePath: "c.mp4", needsReview: false),
            ]
            try await library.writer.write { [online, offline, disabled, band, hidden, alpha, items] db in
                try online.insert(db)
                try offline.insert(db)
                try disabled.insert(db)
                try band.insert(db)
                try hidden.insert(db)
                try alpha.insert(db)
                try secret.insert(db)
                try TagAlias(tagID: alpha.id, alias: "A").insert(db)
                for item in items { try item.insert(db) }
            }
            self.library = library
            service = LocalLibraryService(library: library, runner: JobRunner(library: library))
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func sourcesComeWithWhetherTheirFilesAreReachableHere() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let states = try await f.service.sourceStates()
        #expect(states.map(\.source.name) == ["Away", "Here", "Off"], "sidebar order is by name")
        let online = Dictionary(uniqueKeysWithValues: states.map { ($0.source.name, $0.isOnline) })
        #expect(online == ["Here": true, "Away": false, "Off": false],
                "a disabled source is not online, whatever its folder")
    }

    @Test func theBrowseVocabularyLeavesOutCategoriesHiddenFromBrowse() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let vocabulary = try await f.service.browseVocabulary()
        #expect(vocabulary.categories.map(\.category.name) == ["Band"])
        #expect(vocabulary.categories.first?.tags.map(\.name) == ["Alpha"])
        #expect(vocabulary.aliases == [f.alpha.id: ["A"]])
    }

    @Test func sidebarCountsCarryATreePerEnabledSourceAndTheLibraryCounts() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let sidebar = try await f.service.sidebarCounts(kinds: .video)
        #expect(Set(sidebar.trees.keys) == [f.online.id, f.offline.id], "no tree for a disabled source")
        let shows = try #require(sidebar.trees[f.online.id]?.first)
        #expect(shows.path == "shows" && shows.subtreeCount == 2)
        #expect(shows.children.map(\.path) == ["shows/1995"])
        #expect(sidebar.counts == (try f.library.browseCounts(kinds: .video)))
        #expect(sidebar.counts.total == 3)
    }

    @Test func savedFiltersAreCountedUnderTheKindsShown() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        var filter = MediaFilter()
        filter.selectSubtree("shows", sourceID: f.online.id)
        let saved = try f.library.saveFilter(named: "Shows", filter)
        #expect(try await f.service.savedFilters().map(\.name) == ["Shows"])
        #expect(try await f.service.savedFilterCounts(kinds: .video) == [saved.id: 2])
        #expect(try await f.service.savedFilterCounts(kinds: .audio) == [saved.id: 0])
    }

    @Test func pendingDuplicatesAreCounted() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.pendingDuplicateCount() == 0)
        #expect(try await f.service.pendingDuplicateCount() == (try f.library.pendingCandidates().count))
    }

    @Test func tileMenuFactsAreTheHideBlocksAndTheRecentSnapshots() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let facts = try await f.service.tileMenuFacts(snapshotsPerItem: 10)
        #expect(facts.hideBlockItemIDs == (try f.library.itemIDsWithHideBlocks()))
        #expect(facts.snapshotRefs == (try f.library.recentSnapshotRefs(perItem: 10)))
    }

    @Test func theThumbnailQueueIsReportedOnlyWhileASweepIsPending() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.thumbnailQueueStatus() == nil)

        var job = JobRecord(kind: ThumbnailBatchJob.kind)
        job.progressCurrent = 4
        job.progressTotal = 9
        try await f.library.writer.write { [job] in try job.insert($0) }
        #expect(try await f.service.thumbnailQueueStatus() == ThumbnailQueueStatus(current: 4, total: 9, failed: 0))

        try await f.library.writer.write { db in
            try db.execute(sql: "UPDATE job SET state = ?", arguments: [JobState.succeeded.rawValue])
        }
        #expect(try await f.service.thumbnailQueueStatus() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aWriteAnywhereReachesTheChangeStream() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let stream = f.service.changes()
        let waiting = Task { () -> Set<LibraryChangeDomain> in
            for await change in stream where change.domains.contains(.items) { return change.domains }
            return []
        }
        // The subscription is made when the stream is, not when it is
        // first read, so a write straight after cannot be missed.
        let added = MediaItem(sourceID: f.online.id, kind: .video, relativePath: "new.mp4", needsReview: false)
        try await f.library.writer.write { try added.insert($0) }
        #expect(await waiting.value.contains(.items))
    }

    /// Every answer has to cross a wire one day.
    @Test func everyAnswerSurvivesEncodingAndDecoding() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        func roundTrip<T: Codable & Equatable>(_ value: T) throws {
            let decoded = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
            #expect(decoded == value, "\(T.self) changed in transit")
        }
        try roundTrip(try await f.service.sourceStates())
        try roundTrip(try await f.service.browseVocabulary())
        try roundTrip(try await f.service.sidebarCounts(kinds: .video))
        try roundTrip(try await f.service.tileMenuFacts(snapshotsPerItem: 10))
        try roundTrip(ThumbnailQueueStatus(current: 1, total: nil, failed: 2))
        try roundTrip(MediaKinds.all)
        try roundTrip(SnapshotRef(id: UUID(), capturedAt: Date(timeIntervalSince1970: 1_000), source: SnapshotSource.allCases[0]))
    }

    /// A kinds value decoded from a peer keeps the type's own rule.
    @Test func decodedKindsAreNeverEmpty() throws {
        let decoded = try JSONDecoder().decode(MediaKinds.self, from: Data("[]".utf8))
        #expect(decoded == .video)
    }
}
