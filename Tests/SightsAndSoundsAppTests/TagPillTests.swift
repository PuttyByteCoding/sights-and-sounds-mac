import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A tag pill is a tag wherever it is drawn: clicking one under the
/// video filters the browse window by it, the way clicking the sidebar
/// row does, and every pill says how many items wear the tag.
@Suite @MainActor struct TagPillTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func makeLibrary() async throws -> (LibraryDatabase, MediaItem, SightsAndSoundsKit.Tag) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Pills")
        let source = Source(name: "S", rootPath: "/tmp/sas-pills-\(UUID().uuidString)")
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        let band = TagCategory(name: "Band")
        let tag = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Band A")
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
            try band.insert(db)
            try tag.insert(db)
        }
        return (library, item, tag)
    }

    /// The pill used to take the tag OFF the item. The click now walks
    /// the sidebar's cycle — optional first — and the tag stays on.
    @Test func clickingAPillFiltersByTheTagAndLeavesItOnTheItem() async throws {
        let (library, item, tag) = try await makeLibrary()
        try library.assignTag(tag.id, to: item.id)
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 1 }
        #expect(model.filter.slot(of: tag.id) == nil)

        AppliedTagsStrip.filter(by: tag.id, in: model)
        #expect(model.filter.slot(of: tag.id) == .optional)

        AppliedTagsStrip.filter(by: tag.id, in: model)
        #expect(model.filter.slot(of: tag.id) == .required)

        let stillOn = try library.tags(of: item.id).flatMap(\.tags).map(\.id)
        #expect(stillOn == [tag.id])
    }

    /// The number on a pill is the sidebar's: the library-wide count,
    /// narrowed by the filter when one is on.
    @Test func thePillCountIsTheSidebarsCount() async throws {
        let (library, item, tag) = try await makeLibrary()
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 1 }
        #expect(model.tagCount(tag.id) == 0)

        try library.assignTag(tag.id, to: item.id)
        try await waitUntil { model.tagCount(tag.id) == 1 }
    }

    /// A tile's tag pills carry their counts; a tag the context has no
    /// count for draws without one rather than as zero.
    @Test func tileTagPillsCarryTheirCounts() {
        let item = MediaItem(sourceID: UUID(), kind: .video, relativePath: "a.mp4", needsReview: false)
        let counted = TagPill(id: UUID(), name: "Counted", categoryID: UUID(), categoryName: "Band", colorIndex: 0)
        let uncounted = TagPill(id: UUID(), name: "Uncounted", categoryID: UUID(), categoryName: "Band", colorIndex: 1)
        let context = TileContext(tags: [counted, uncounted], tagCounts: [counted.id: 12])

        let badges = TileCard.badges(for: .tags, item: item, context: context)

        #expect(badges.map(\.text) == ["Counted", "Uncounted"])
        #expect(badges.map(\.count) == [12, nil])
        let allPills = badges.allSatisfy(\.isPill)
        #expect(allPills)
    }
}
