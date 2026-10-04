import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The Browse grid's listing, asked of the service: the items, and with
/// them everything that describes the same moment — the faceted counts,
/// what the tiles' menus need, and (only when the tiles show them) each
/// item's tag pills and whether it is in a pending duplicate pair.
@Suite struct LocalLibraryServiceListingTests {
    struct Fixture {
        let library: LibraryDatabase
        let service: LocalLibraryService
        let a: MediaItem
        let b: MediaItem
        let c: MediaItem

        init() async throws {
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Listing")
            let source = Source(name: "Here", rootPath: "/tmp/sas-service-listing-\(UUID().uuidString)")
            // Venue is created first and sorts second: the pills follow
            // the categories' sort order, not their age.
            let venue = TagCategory(name: "Venue", sortOrder: 1)
            let band = TagCategory(name: "Band", sortOrder: 0)
            let hall = SightsAndSoundsKit.Tag(tagCategoryID: venue.id, name: "Hall")
            let zed = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Zed")
            let alpha = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Alpha")
            let a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
            let b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", needsReview: false)
            let c = MediaItem(sourceID: source.id, kind: .video, relativePath: "c.mp4", needsReview: false)
            try await library.writer.write { db in
                try source.insert(db)
                for category in [venue, band] { try category.insert(db) }
                for tag in [hall, zed, alpha] { try tag.insert(db) }
                for item in [a, b, c] { try item.insert(db) }
                try DuplicateCandidate(itemA: a.id, itemB: b.id, source: .contentHash).insert(db)
            }
            try library.assignTag(hall.id, to: [a.id])
            try library.assignTag(zed.id, to: [a.id])
            try library.assignTag(alpha.id, to: [a.id, b.id])
            self.library = library
            self.a = a
            self.b = b
            self.c = c
            service = LocalLibraryService(library: library, runner: JobRunner(library: library))
        }

        func request(tags: Bool = false, duplicates: Bool = false) -> ListingRequest {
            ListingRequest(
                filter: MediaFilter(), kinds: .video, ordering: .relativePath,
                includesTagData: tags, includesDuplicateData: duplicates, snapshotsPerItem: 10)
        }
    }

    @Test func theListingIsTheItemsTheDatabaseListsInTheOrderAsked() async throws {
        let f = try await Fixture()
        let answer = try await f.service.listing(f.request())
        #expect(answer.items.map(\.relativePath) == ["a.mp4", "b.mp4", "c.mp4"])
        #expect(answer.items == (try f.library.mediaItems(
            matching: MediaFilter(), kinds: .video, orderedBy: .relativePath)))
        #expect(answer.filteredTagCounts == (try f.library.filteredTagCounts(kinds: .video, filter: MediaFilter())))
        #expect(answer.filteredMissingCounts == (try f.library.filteredMissingCategoryCounts(
            kinds: .video, filter: MediaFilter())))
        #expect(answer.menuFacts == (try await f.service.tileMenuFacts(snapshotsPerItem: 10)))
    }

    @Test func theFilterAndTheKindsNarrowIt() async throws {
        let f = try await Fixture()
        var request = f.request()
        request.filter.searchText = "b.mp4"
        #expect(try await f.service.listing(request).items.map(\.relativePath) == ["b.mp4"])
        request = f.request()
        request.kinds = .audio
        #expect(try await f.service.listing(request).items.isEmpty)
    }

    @Test func pillsAreInCategoryOrderThenByName() async throws {
        let f = try await Fixture()
        let answer = try await f.service.listing(f.request(tags: true))
        #expect(answer.tags[f.a.id]?.map(\.name) == ["Alpha", "Zed", "Hall"])
        #expect(answer.tags[f.a.id]?.map(\.categoryName) == ["Band", "Band", "Venue"])
        #expect(answer.tags[f.c.id] == [])
        #expect(answer.missingCategories[f.a.id] == [])
        #expect(answer.missingCategories[f.b.id] == ["Venue"])
        #expect(answer.missingCategories[f.c.id] == ["Band", "Venue"])
    }

    @Test func tagAndDuplicateDataAreLeftOutUnlessAskedFor() async throws {
        let f = try await Fixture()
        let bare = try await f.service.listing(f.request())
        #expect(bare.tags.isEmpty && bare.missingCategories.isEmpty && bare.duplicateIDs.isEmpty)
        let full = try await f.service.listing(f.request(tags: true, duplicates: true))
        #expect(full.duplicateIDs == [f.a.id, f.b.id])
    }

    @Test func theAnswerSurvivesEncodingAndDecoding() async throws {
        let f = try await Fixture()
        let answer = try await f.service.listing(f.request(tags: true, duplicates: true))
        let decoded = try JSONDecoder().decode(
            BrowseListingAnswer.self, from: JSONEncoder().encode(answer))
        #expect(decoded == answer)

        let request = f.request(tags: true)
        #expect(try JSONDecoder().decode(ListingRequest.self, from: JSONEncoder().encode(request)) == request)
        let orderings: [MediaOrdering] = [
            .relativePath, .fileName, .fieldValue(UUID(), ascending: false), .fileSize(ascending: true),
            .duration(ascending: false), .fullPath, .random(seed: 7),
        ]
        for ordering in orderings {
            #expect(try JSONDecoder().decode(MediaOrdering.self, from: JSONEncoder().encode(ordering)) == ordering)
        }
    }
}
