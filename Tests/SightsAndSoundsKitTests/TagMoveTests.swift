import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Moving a tag between categories: the taggings, aliases and flags
/// travel; the name takes the target's format; the two silent-loss
/// cases refuse rather than guess.
@Suite struct TagMoveTests {

    private struct Fixture {
        let library: LibraryDatabase
        let source: Source
        let band: TagCategory
        let venue: TagCategory
        let items: [MediaItem]
    }

    private func makeFixture(venueSingle: Bool = false, venueFormat: TextFormat = .noFormatting) async throws -> Fixture {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Move")
        let source = Source(name: "S", rootPath: "/tmp/move-\(UUID().uuidString)")
        let band = TagCategory(name: "Band")
        let venue = TagCategory(name: "Venue", allowMultiple: !venueSingle, textFormat: venueFormat)
        let items = ["a.mp4", "b.mp4"].map {
            MediaItem(sourceID: source.id, kind: .video, relativePath: $0, needsReview: false)
        }
        try await library.writer.write { db in
            try source.insert(db); try band.insert(db); try venue.insert(db)
            for item in items { try item.insert(db) }
        }
        return Fixture(library: library, source: source, band: band, venue: venue, items: items)
    }

    @Test func aMoveKeepsTaggingsAliasesAndFlagsAndLandsLast() async throws {
        let f = try await makeFixture()
        let existing = SightsAndSoundsKit.Tag(tagCategoryID: f.venue.id, name: "Red Rocks", sortOrder: 10)
        let moving = SightsAndSoundsKit.Tag(tagCategoryID: f.band.id, name: "Phish", isFavorite: true)
        try await f.library.writer.write { db in try existing.insert(db); try moving.insert(db) }
        try f.library.assignTag(moving.id, to: f.items[0].id)
        try f.library.addAlias("PH", toTag: moving.id)

        let moved = try f.library.moveTag(moving.id, toCategory: f.venue.id)

        #expect(moved.tagCategoryID == f.venue.id)
        #expect(moved.isFavorite)
        #expect(moved.sortOrder > existing.sortOrder)
        #expect(try f.library.tags(of: f.items[0].id).flatMap(\.tags).map(\.id) == [moving.id])
        let aliases = try await f.library.writer.read { db in
            try TagAlias.filter(sql: "tagID = ?", arguments: [moving.id]).fetchAll(db)
        }
        #expect(aliases.map(\.alias) == ["PH"])
    }

    @Test func theNameTakesTheTargetCategorysFormat() async throws {
        let f = try await makeFixture(venueFormat: .allUppercase)
        let moving = SightsAndSoundsKit.Tag(tagCategoryID: f.band.id, name: "phish")
        try await f.library.writer.write { db in try moving.insert(db) }
        let moved = try f.library.moveTag(moving.id, toCategory: f.venue.id)
        #expect(moved.name == "PHISH")
    }

    @Test func aDuplicateNameInTheTargetIsRefused() async throws {
        let f = try await makeFixture()
        let there = SightsAndSoundsKit.Tag(tagCategoryID: f.venue.id, name: "Phish")
        let moving = SightsAndSoundsKit.Tag(tagCategoryID: f.band.id, name: "phish")
        try await f.library.writer.write { db in try there.insert(db); try moving.insert(db) }
        #expect(throws: (any Error).self) {
            try f.library.moveTag(moving.id, toCategory: f.venue.id)
        }
        let still = try await f.library.writer.read { try SightsAndSoundsKit.Tag.fetchOne($0, key: moving.id) }
        #expect(still?.tagCategoryID == f.band.id)
    }

    @Test func aSingleSelectConflictIsRefusedWithACount() async throws {
        let f = try await makeFixture(venueSingle: true)
        let there = SightsAndSoundsKit.Tag(tagCategoryID: f.venue.id, name: "Red Rocks")
        let moving = SightsAndSoundsKit.Tag(tagCategoryID: f.band.id, name: "Phish")
        try await f.library.writer.write { db in try there.insert(db); try moving.insert(db) }
        try f.library.assignTag(there.id, to: f.items[0].id)
        try f.library.assignTag(moving.id, to: f.items[0].id)
        try f.library.assignTag(moving.id, to: f.items[1].id)

        #expect(throws: (any Error).self) {
            try f.library.moveTag(moving.id, toCategory: f.venue.id)
        }
        do {
            try f.library.moveTag(moving.id, toCategory: f.venue.id)
        } catch {
            #expect("\(error)".contains("1 item"))
        }
    }

    @Test func fieldValuesOfTheOldCategoryAreDropped() async throws {
        let f = try await makeFixture()
        let moving = SightsAndSoundsKit.Tag(tagCategoryID: f.band.id, name: "Phish")
        try await f.library.writer.write { db in try moving.insert(db) }
        let field = try f.library.createField(
            FieldDefinition(name: "Hometown", scope: .tag, tagCategoryID: f.band.id))
        try f.library.setFieldValue("Vermont", ofTag: moving.id, field: field)
        #expect(try f.library.fieldValues(ofTag: moving.id).isEmpty == false)

        _ = try f.library.moveTag(moving.id, toCategory: f.venue.id)
        #expect(try f.library.fieldValues(ofTag: moving.id).isEmpty)
    }
}
