import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A queue is a snapshot with a definition: it changes only when the
/// definition is re-run, whatever the library does in between.
@Suite @MainActor struct PlayQueueTests {

    private func makeLibrary() async throws -> (LibraryDatabase, Source, TagCategory) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Queues")
        let source = Source(name: "S", rootPath: "/tmp/queues-\(UUID().uuidString)")
        let band = TagCategory(name: "Band")
        try await library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
        }
        return (library, source, band)
    }

    @discardableResult
    private func insert(_ library: LibraryDatabase, _ source: Source, _ path: String) async throws -> MediaItem {
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: path, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return item
    }

    @Test func aListingQueueIsASnapshotUntilRefreshed() async throws {
        let (library, source, _) = try await makeLibrary()
        try await insert(library, source, "a.mp4")
        let queue = try PlayQueue.make(
            .listing(filter: MediaFilter(), kinds: .video, ordering: .relativePath),
            library: library)
        #expect(queue.items.map(\.relativePath) == ["a.mp4"])

        try await insert(library, source, "b.mp4")
        #expect(queue.items.map(\.relativePath) == ["a.mp4"])  // untouched

        queue.apply(try PlayQueue.run(queue.definition, library: library))
        #expect(queue.items.map(\.relativePath) == ["a.mp4", "b.mp4"])
    }

    @Test func aTagQueueHoldsOnlyThatTagsItemsAndKeepsItsTitle() async throws {
        let (library, source, band) = try await makeLibrary()
        let phish = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Phish")
        try await library.writer.write { try phish.insert($0) }
        let tagged = try await insert(library, source, "phish.mp4")
        try await insert(library, source, "other.mp4")
        try library.assignTag(phish.id, to: tagged.id)

        let queue = try PlayQueue.make(.tag(id: phish.id, name: "Phish"), library: library)
        #expect(queue.items.map(\.relativePath) == ["phish.mp4"])
        #expect(queue.title == "Tag: Phish")
    }

    @Test func anExplicitQueueDropsItemsThatNoLongerExistOnRefresh() async throws {
        let (library, source, _) = try await makeLibrary()
        let a = try await insert(library, source, "a.mp4")
        let b = try await insert(library, source, "b.mp4")
        let queue = try PlayQueue.make(.explicit(ids: [b.id, a.id], name: "Selection"), library: library)
        #expect(queue.ids == [b.id, a.id])  // the given order, not the table's

        try await library.writer.write { db in _ = try MediaItem.deleteOne(db, key: a.id) }
        queue.apply(try PlayQueue.run(queue.definition, library: library))
        #expect(queue.ids == [b.id])
    }

    @Test func aHistoryQueueIsWhatWasWatchedMostRecentFirst() async throws {
        let (library, source, _) = try await makeLibrary()
        let old = try await insert(library, source, "old.mp4")
        let new = try await insert(library, source, "new.mp4")
        try await insert(library, source, "never.mp4")
        try library.recordPlaybackStop(
            itemID: old.id, positionSeconds: 10, durationSeconds: 100, at: Date(timeIntervalSince1970: 1_000))
        try library.recordPlaybackStop(
            itemID: new.id, positionSeconds: 10, durationSeconds: 100, at: Date(timeIntervalSince1970: 2_000))

        let queue = try PlayQueue.make(.history, library: library)
        #expect(queue.items.map(\.relativePath) == ["new.mp4", "old.mp4"])
    }

    @Test func replacingTheDefinitionChangesWhatRefreshRuns() async throws {
        let (library, source, _) = try await makeLibrary()
        try await insert(library, source, "b.mp4")
        try await insert(library, source, "a.mp4")
        let queue = try PlayQueue.make(
            .listing(filter: MediaFilter(), kinds: .video, ordering: .relativePath),
            library: library)
        #expect(queue.items.map(\.relativePath) == ["a.mp4", "b.mp4"])
        queue.replaceDefinition(
            .listing(filter: MediaFilter(), kinds: .video, ordering: .fileSize(ascending: false)))
        #expect(queue.items.map(\.relativePath) == ["a.mp4", "b.mp4"])  // not until refresh
        queue.apply(try PlayQueue.run(queue.definition, library: library))
        #expect(queue.items.count == 2)
    }
}
