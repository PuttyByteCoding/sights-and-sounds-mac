import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The Tag Manager's reads and writes, as asked of the library's
/// service.
@Suite struct VocabularyManagingTests {
    typealias Tag = SightsAndSoundsKit.Tag

    struct Fixture {
        let library: LibraryDatabase
        let service: LocalLibraryService
        let band: TagCategory
        let venue: TagCategory
        let alpha: Tag
        let beta: Tag
        let gamma: Tag
        let hall: Tag
        let a: MediaItem
        let b: MediaItem

        init() throws {
            library = try LibraryDatabase.openInMemory()
            service = LocalLibraryService(library: library)
            let source = Source(name: "Here", rootPath: "/tmp/sas-vocabulary-managing")
            // Out of name order on purpose: the order shown is sortOrder's.
            venue = TagCategory(name: "Venue", sortOrder: 0)
            band = TagCategory(name: "Band", sortOrder: 10)
            alpha = Tag(tagCategoryID: band.id, name: "Alpha")
            beta = Tag(tagCategoryID: band.id, name: "Beta")
            gamma = Tag(tagCategoryID: band.id, name: "Gamma")
            hall = Tag(tagCategoryID: venue.id, name: "The Hall")
            a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4")
            b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4")
            try library.writer.write { [band, venue, alpha, beta, gamma, hall, a, b] db in
                try source.insert(db)
                for row in [venue, band] { try row.insert(db) }
                for row in [alpha, beta, gamma, hall] { try row.insert(db) }
                for row in [a, b] { try row.insert(db) }
            }
            try library.assignTag(alpha.id, to: [a.id, b.id])
            try library.assignTag(beta.id, to: [a.id])
            try library.addAlias("Al", toTag: alpha.id)
            try library.addAlias("A", toTag: alpha.id)
            try library.addAlias("Hall", toTag: hall.id)
        }

        func tagIDs(on item: MediaItem) throws -> Set<UUID> {
            Set(try library.writer.read { db in
                try UUID.fetchAll(db, sql: "SELECT tagID FROM mediaItemTag WHERE mediaItemID = ?", arguments: [item.id])
            })
        }
    }

    // MARK: - Reading

    @Test func categoriesComeInTheOrderTheyAreShown() async throws {
        let f = try Fixture()
        #expect(try await f.service.categories().map(\.name) == ["Venue", "Band"])
    }

    @Test func aCategorysTableIsItsTagsAliasesAndCounts() async throws {
        let f = try Fixture()
        let table = try await f.service.categoryTable(categoryID: f.band.id)
        #expect(table.tags.map(\.name) == ["Alpha", "Beta", "Gamma"])
        #expect(table.aliases == [f.alpha.id: ["A", "Al"]], "another category's aliases, or unsorted")
        #expect(table.usage == [f.alpha.id: 2, f.beta.id: 1, f.gamma.id: 0])
        let none = try await f.service.categoryTable(categoryID: UUID())
        #expect(none == CategoryTable(tags: [], aliases: [:], usage: [:]))
    }

    @Test func theIndexIsTheWholeVocabulary() async throws {
        let f = try Fixture()
        let index = try await f.service.vocabularyIndex()
        #expect(index.vocabulary.map(\.category.name) == ["Venue", "Band"])
        #expect(index.vocabulary.flatMap(\.tags).count == 4)
        #expect(Set(index.aliases[f.alpha.id] ?? []) == ["A", "Al"])
        #expect(index.aliases[f.hall.id] == ["Hall"])
        #expect(index.usage == [f.alpha.id: 2, f.beta.id: 1, f.gamma.id: 0, f.hall.id: 0])
    }

    @Test func theNamesACategoryHasIncludeItsAliases() async throws {
        let f = try Fixture()
        #expect(try await f.service.takenNames(categoryID: f.band.id) == ["alpha", "beta", "gamma", "a", "al"])
        #expect(try await f.service.takenNames(categoryID: f.venue.id) == ["the hall", "hall"])
    }

    // MARK: - Categories

    @Test func aCategoryIsMadeChangedAndDeleted() async throws {
        let f = try Fixture()
        var year = TagCategory(name: "Year", allowMultiple: false, sortOrder: 20)
        try await f.service.createCategory(year)
        #expect(try await f.service.categories().map(\.name) == ["Venue", "Band", "Year"])

        year.name = "Decade"
        year.hiddenFromBrowse = true
        try await f.service.updateCategory(year)
        let read = try #require(try await f.service.categories().last)
        #expect(read.name == "Decade" && read.hiddenFromBrowse && !read.allowMultiple)

        // With its tags, and off the items that wore them.
        try await f.service.deleteCategory(f.band.id)
        #expect(try await f.service.categories().map(\.name) == ["Venue", "Decade"])
        #expect(try f.tagIDs(on: f.a).isEmpty)
        let tags = try await f.library.writer.read { try Tag.fetchCount($0) }
        #expect(tags == 1)
    }

    // MARK: - Merging

    @Test func tagsMergedIntoOneOfThemKeepTheirNamesAsAliases() async throws {
        let f = try Fixture()
        let into = try await f.service.mergeTags([f.alpha.id, f.beta.id], into: .existing(f.beta.id))
        #expect(into.id == f.beta.id)
        #expect(try f.tagIDs(on: f.a) == [f.beta.id])
        #expect(try f.tagIDs(on: f.b) == [f.beta.id])
        let table = try await f.service.categoryTable(categoryID: f.band.id)
        #expect(table.tags.map(\.name) == ["Beta", "Gamma"])
        #expect(Set(table.aliases[f.beta.id] ?? []) == ["A", "Al", "Alpha"])
        #expect(table.usage[f.beta.id] == 2)
    }

    @Test func tagsMergedIntoANewOne() async throws {
        let f = try Fixture()
        let made = try await f.service.mergeTags([f.alpha.id, f.beta.id], into: .newTag(named: "Alphabet"))
        #expect(made.name == "Alphabet" && made.tagCategoryID == f.band.id)
        #expect(try f.tagIDs(on: f.b) == [made.id])
        let table = try await f.service.categoryTable(categoryID: f.band.id)
        #expect(table.tags.map(\.name) == ["Alphabet", "Gamma"])
        #expect(Set(table.aliases[made.id] ?? []).isSuperset(of: ["Alpha", "Beta"]))
    }

    // MARK: - One tag

    @Test func aTagIsHiddenAndGivenNotes() async throws {
        let f = try Fixture()
        try await f.service.setTagHidden(f.gamma.id, true)
        try await f.service.setTagNotes(f.gamma.id, "Seen twice.")
        let read = try #require(try await f.library.writer.read { try Tag.fetchOne($0, key: f.gamma.id) })
        #expect(read.hiddenByDefault && read.notes == "Seen twice.")
        try await f.service.setTagHidden(f.gamma.id, false)
        let shown = try await f.library.writer.read { try Tag.fetchOne($0, key: f.gamma.id) }
        #expect(shown?.hiddenByDefault == false)
    }

    // MARK: - Fields

    @Test func fieldsAreMadeFilledInAndDeleted() async throws {
        let f = try Fixture()
        #expect(try await f.service.fields(scope: .tag, categoryID: f.band.id).isEmpty)
        let formed = try await f.service.createField(
            FieldDefinition(name: "Formed", scope: .tag, tagCategoryID: f.band.id, sortOrder: 10))
        let lesson = try await f.service.createField(FieldDefinition(name: "Lesson", dataType: .number, scope: .mediaItem))
        #expect(try await f.service.fields(scope: .tag, categoryID: f.band.id) == [formed])
        #expect(try await f.service.fields(scope: .tag, categoryID: f.venue.id).isEmpty)
        #expect(try await f.service.fields(scope: .mediaItem, categoryID: nil) == [lesson])

        try await f.service.setFieldValue("1995", tagID: f.alpha.id, field: formed)
        #expect(try await f.service.fieldValues(tagID: f.alpha.id) == [formed.id: "1995"])
        #expect(try await f.service.fieldValues(tagID: f.beta.id).isEmpty)
        // Emptied, it is no value at all.
        try await f.service.setFieldValue("", tagID: f.alpha.id, field: formed)
        #expect(try await f.service.fieldValues(tagID: f.alpha.id).isEmpty)

        try await f.service.setFieldValue("1996", tagID: f.alpha.id, field: formed)
        try await f.service.deleteField(formed.id)
        #expect(try await f.service.fields(scope: .tag, categoryID: f.band.id).isEmpty)
        #expect(try await f.service.fieldValues(tagID: f.alpha.id).isEmpty, "a deleted field left its values")
    }

    /// The library's own rule for a field's name, said through the
    /// service as it is said in the window.
    @Test func aFieldWithNoNameIsRefused() async throws {
        let f = try Fixture()
        await #expect(throws: (any Error).self) {
            _ = try await f.service.createField(FieldDefinition(name: "   ", scope: .mediaItem))
        }
        #expect(try await f.service.fields(scope: .mediaItem, categoryID: nil).isEmpty)
    }
}
