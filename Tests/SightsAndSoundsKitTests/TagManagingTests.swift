import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// A tag's own menu and the Edit Tag sheet, as asked of the library's
/// service: what each changes in the library, and what it leaves alone.
@Suite struct TagManagingTests {
    typealias Tag = SightsAndSoundsKit.Tag

    struct Fixture {
        let library: LibraryDatabase
        let service: LocalLibraryService
        let band: TagCategory
        let venue: TagCategory
        let hidden: TagCategory
        let alpha: Tag
        let beta: Tag
        let hall: Tag
        let a: MediaItem
        let b: MediaItem

        init() throws {
            library = try LibraryDatabase.openInMemory()
            service = LocalLibraryService(library: library)
            let source = Source(name: "Here", rootPath: "/tmp/sas-tag-managing")
            band = TagCategory(name: "Band", sortOrder: 0)
            venue = TagCategory(name: "Venue", sortOrder: 1)
            hidden = TagCategory(name: "Internal", sortOrder: 2, hiddenFromBrowse: true)
            alpha = Tag(tagCategoryID: band.id, name: "Alpha")
            beta = Tag(tagCategoryID: band.id, name: "Beta")
            hall = Tag(tagCategoryID: venue.id, name: "The Hall")
            a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4")
            b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4")
            let secret = Tag(tagCategoryID: hidden.id, name: "Secret")
            try library.writer.write { [band, venue, hidden, alpha, beta, hall, a, b] db in
                try source.insert(db)
                for row in [band, venue, hidden] { try row.insert(db) }
                for row in [alpha, beta, hall, secret] { try row.insert(db) }
                for row in [a, b] { try row.insert(db) }
            }
            try library.assignTag(alpha.id, to: [a.id, b.id])
            try library.assignTag(hall.id, to: [a.id])
        }

        func tag(_ id: UUID) throws -> Tag? { try library.writer.read { try Tag.fetchOne($0, key: id) } }

        func tagIDs(on item: MediaItem) throws -> Set<UUID> {
            Set(try library.writer.read { db in
                try UUID.fetchAll(db, sql: "SELECT tagID FROM mediaItemTag WHERE mediaItemID = ?", arguments: [item.id])
            })
        }

        func aliases(of tag: Tag) throws -> [String] {
            try library.writer.read { db in
                try String.fetchAll(db, sql: "SELECT alias FROM tagAlias WHERE tagID = ? ORDER BY alias", arguments: [tag.id])
            }
        }
    }

    // MARK: - Reading

    @Test func theWholeVocabularyIncludesWhatBrowseHides() async throws {
        let f = try Fixture()
        let vocabulary = try await f.service.fullVocabulary()
        #expect(vocabulary.map(\.category.name) == ["Band", "Venue", "Internal"])
        #expect(vocabulary.first?.tags.map(\.name) == ["Alpha", "Beta"])
        #expect(vocabulary.last?.tags.map(\.name) == ["Secret"])
        // Browse's own vocabulary leaves the hidden category out; this does not.
        #expect(try await f.service.browseVocabulary().categories.map(\.category.name) == ["Band", "Venue"])
    }

    @Test func aTagsUsesAreCountedByCategory() async throws {
        let f = try Fixture()
        #expect(try await f.service.tagUsageCounts(categoryID: f.band.id) == [f.alpha.id: 2, f.beta.id: 0])
        #expect(try await f.service.tagUsageCounts(categoryID: f.venue.id) == [f.hall.id: 1])
        #expect(try await f.service.tagUsageCounts(categoryID: UUID()).isEmpty)
    }

    @Test func whatTheSheetShowsOfATag() async throws {
        let f = try Fixture()
        #expect(try await f.service.tagDetails(tagID: f.alpha.id) == TagDetails(aliases: [], fieldValueCount: 0))

        try f.library.addAlias("A", toTag: f.alpha.id)
        try f.library.addAlias("Al", toTag: f.alpha.id)
        let field = try f.library.createField(
            FieldDefinition(name: "Formed", scope: .tag, tagCategoryID: f.band.id))
        try f.library.setFieldValue("1995", ofTag: f.alpha.id, field: field)
        let details = try await f.service.tagDetails(tagID: f.alpha.id)
        #expect(Set(details.aliases) == ["A", "Al"])
        #expect(details.fieldValueCount == 1)
        #expect(try await f.service.tagDetails(tagID: UUID()) == TagDetails(aliases: [], fieldValueCount: 0))
    }

    // MARK: - The menu

    @Test func aFavouriteIsSetAndUnset() async throws {
        let f = try Fixture()
        try await f.service.setTagFavorite(f.alpha.id, true)
        #expect(try f.tag(f.alpha.id)?.isFavorite == true)
        try await f.service.setTagFavorite(f.alpha.id, false)
        #expect(try f.tag(f.alpha.id)?.isFavorite == false)
    }

    @Test func replacingOnOneItemLeavesTheOthers() async throws {
        let f = try Fixture()
        try await f.service.replaceTag(f.alpha.id, with: f.beta.id, on: f.a.id)
        #expect(try f.tagIDs(on: f.a) == [f.beta.id, f.hall.id])
        #expect(try f.tagIDs(on: f.b) == [f.alpha.id])
    }

    @Test func replacingEverywhereKeepsTheTagInTheVocabulary() async throws {
        let f = try Fixture()
        try await f.service.replaceTag(f.alpha.id, with: f.beta.id, on: nil)
        #expect(try f.tagIDs(on: f.a) == [f.beta.id, f.hall.id])
        #expect(try f.tagIDs(on: f.b) == [f.beta.id])
        #expect(try f.tag(f.alpha.id) != nil, "the replaced tag went with its taggings")
        #expect(try await f.service.tagUsageCounts(categoryID: f.band.id) == [f.alpha.id: 0, f.beta.id: 2])
    }

    @Test func madeAnAliasATagsItemsAndNameGoToTheOther() async throws {
        let f = try Fixture()
        try await f.service.convertTagToAlias(f.alpha.id, of: f.beta.id)
        #expect(try f.tag(f.alpha.id) == nil)
        #expect(try f.tagIDs(on: f.a) == [f.beta.id, f.hall.id])
        #expect(try f.tagIDs(on: f.b) == [f.beta.id])
        #expect(try f.aliases(of: f.beta) == ["Alpha"])
        // Only within its category: the library's rule, said as an error.
        await #expect(throws: (any Error).self) {
            try await f.service.convertTagToAlias(f.beta.id, of: f.hall.id)
        }
        #expect(try f.tag(f.beta.id) != nil)
    }

    @Test func deletingATagTakesItOffItsItems() async throws {
        let f = try Fixture()
        try await f.service.deleteTag(f.alpha.id)
        #expect(try f.tag(f.alpha.id) == nil)
        #expect(try f.tagIDs(on: f.a) == [f.hall.id])
        #expect(try f.tagIDs(on: f.b).isEmpty)
    }

    @Test func anAliasIsTakenAway() async throws {
        let f = try Fixture()
        try f.library.addAlias("A", toTag: f.alpha.id)
        try f.library.addAlias("Al", toTag: f.alpha.id)
        try await f.service.removeAlias("A", fromTag: f.alpha.id)
        #expect(try f.aliases(of: f.alpha) == ["Al"])
    }

    // MARK: - The sheet's Save

    @Test func aNewTagIsMadeWithEverythingTheSheetHeld() async throws {
        let f = try Fixture()
        let made = try await f.service.saveTag(TagDraft(
            tagID: nil, categoryID: f.band.id, name: "  Gamma  ", notes: "From the north.",
            hiddenByDefault: true, ignoredByAnalysis: true, isFavorite: true, aliases: ["G", "Gam"]))
        #expect(made.name == "Gamma")
        #expect(made.tagCategoryID == f.band.id)
        #expect(made.notes == "From the north.")
        #expect(made.hiddenByDefault && made.ignoredByAnalysis && made.isFavorite)
        #expect(try f.tag(made.id) == made, "what came back is not what is in the library")
        #expect(try f.aliases(of: made) == ["G", "Gam"])
    }

    /// A name the category already has is that tag, not a rival spelling
    /// of it: the library's one rule, the same through the sheet.
    @Test func aNameTheCategoryHasIsThatTag() async throws {
        let f = try Fixture()
        let same = try await f.service.saveTag(TagDraft(
            tagID: nil, categoryID: f.band.id, name: "alpha", notes: "",
            hiddenByDefault: false, ignoredByAnalysis: false, isFavorite: false, aliases: []))
        #expect(same.id == f.alpha.id)
        let tags = try await f.library.writer.read { try Tag.fetchCount($0) }
        #expect(tags == 4)
    }

    @Test func aTagIsChangedInWhatDiffersAndNothingElse() async throws {
        let f = try Fixture()
        try f.library.addAlias("A", toTag: f.alpha.id)
        let saved = try await f.service.saveTag(TagDraft(
            tagID: f.alpha.id, categoryID: f.band.id, name: "Alpha Prime", notes: "Renamed.",
            hiddenByDefault: false, ignoredByAnalysis: true, isFavorite: true,
            // A tag being changed has its aliases handled one at a time
            // by the sheet; a list here must not be read as "add these".
            aliases: ["Not Added"]))
        #expect(saved.id == f.alpha.id)
        #expect(saved.name == "Alpha Prime" && saved.notes == "Renamed.")
        #expect(saved.ignoredByAnalysis && saved.isFavorite && !saved.hiddenByDefault)
        #expect(try f.aliases(of: f.alpha) == ["A"])
        #expect(try f.tagIDs(on: f.a).contains(f.alpha.id), "the tag came off its items")

        // The same again changes nothing.
        let again = try await f.service.saveTag(TagDraft(
            tagID: f.alpha.id, categoryID: f.band.id, name: "Alpha Prime", notes: "Renamed.",
            hiddenByDefault: false, ignoredByAnalysis: true, isFavorite: true, aliases: []))
        #expect(again == saved)
    }

    @Test func aTagIsMovedToAnotherCategory() async throws {
        let f = try Fixture()
        let moved = try await f.service.saveTag(TagDraft(
            tagID: f.alpha.id, categoryID: f.venue.id, name: "Alpha", notes: "",
            hiddenByDefault: false, ignoredByAnalysis: false, isFavorite: false, aliases: []))
        #expect(moved.tagCategoryID == f.venue.id)
        #expect(try f.tagIDs(on: f.b) == [f.alpha.id], "moving a tag took it off its items")
    }

    @Test func renamingOntoANameTheCategoryHasIsRefused() async throws {
        let f = try Fixture()
        await #expect(throws: (any Error).self) {
            _ = try await f.service.saveTag(TagDraft(
                tagID: f.beta.id, categoryID: f.band.id, name: "Alpha", notes: "changed",
                hiddenByDefault: false, ignoredByAnalysis: false, isFavorite: false, aliases: []))
        }
        #expect(try f.tag(f.beta.id)?.name == "Beta")
    }

    @Test func aTagThatHasGoneIsSaidToHaveGone() async throws {
        let f = try Fixture()
        try f.library.deleteTag(f.beta.id)
        await #expect(throws: ServiceError.noSuchTag) {
            _ = try await f.service.saveTag(TagDraft(
                tagID: f.beta.id, categoryID: f.band.id, name: "Beta", notes: "",
                hiddenByDefault: false, ignoredByAnalysis: false, isFavorite: false, aliases: []))
        }
        #expect("\(ServiceError.noSuchTag)" == "that tag is no longer in the library")
    }
}
