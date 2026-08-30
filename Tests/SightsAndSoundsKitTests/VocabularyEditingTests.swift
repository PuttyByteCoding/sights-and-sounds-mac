import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The operations the Categories & Fields window needs and the library
/// did not have: merging, use counts, alias-aware creation, bulk order,
/// field definitions — plus the display style that replaced a boolean.
@Suite struct VocabularyEditingTests {

    // MARK: - Merging

    @Test func mergingRepointsTaggingsAndKeepsNamesAsAliases() throws {
        let f = try FilterFixture()
        // bandA is on three items, bandB on one.
        let keeper = try f.library.mergeTags(
            [f.bandB.id], into: .existing(f.bandA.id), keepNamesAsAliases: true)
        #expect(keeper.id == f.bandA.id)
        // The item that carried Band B now carries Band A.
        #expect(try f.names(MediaFilter(required: [.tag(f.bandA.id)]))
            .contains("c.mp4"))
        // The discarded spelling survives as a way to find the survivor.
        let aliases = try f.library.writer.read { db in
            try TagAlias.filter(sql: "tagID = ?", arguments: [f.bandA.id]).fetchAll(db)
        }
        #expect(aliases.map(\.alias).contains("Band B"))
        // And the source row is gone.
        #expect(try f.library.writer.read { try Tag.fetchOne($0, key: f.bandB.id) } == nil)
    }

    @Test func mergingIntoANewTagFoldsEveryPickIntoIt() throws {
        let f = try FilterFixture()
        let keeper = try f.library.mergeTags(
            [f.bandA.id, f.bandB.id], into: .newTag(named: "Both Bands"))
        #expect(keeper.name == "Both Bands")
        let names = try f.library.writer.read { db in
            try Tag.filter(sql: "tagCategoryID = ?", arguments: [f.band.id]).fetchAll(db)
        }.map(\.name)
        #expect(!names.contains("Band A"))
        #expect(!names.contains("Band B"))
        #expect(names.contains("Both Bands"))
    }

    /// An item that carried two of the merged tags ends with ONE
    /// tagging, not a doubled row.
    @Test func anItemCarryingBothPicksEndsWithOne() throws {
        let f = try FilterFixture()
        try f.library.assignTag(f.bandB.id, to: f.show1995.id)
        try f.library.mergeTags([f.bandB.id], into: .existing(f.bandA.id))
        let taggings = try f.library.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM mediaItemTag WHERE mediaItemID = ? AND tagID = ?",
                arguments: [f.show1995.id, f.bandA.id])
        }
        #expect(taggings == 1)
    }

    @Test func tagsFromTwoCategoriesCannotMerge() throws {
        let f = try FilterFixture()
        #expect(throws: (any Error).self) {
            try f.library.mergeTags([f.bandA.id, f.sbd.id], into: .existing(f.bandA.id))
        }
    }

    /// Convert to alias is the gentler half of delete: the taggings
    /// move rather than disappearing.
    @Test func convertToAliasKeepsTheTaggings() throws {
        let f = try FilterFixture()
        try f.library.convertTagToAlias(f.bandB.id, of: f.bandA.id)
        #expect(try f.names(MediaFilter(required: [.tag(f.bandA.id)])).contains("c.mp4"))
    }

    // MARK: - Counts and creation

    @Test func usageCountsComeFromOneQueryAndIncludeZeroes() throws {
        let f = try FilterFixture()
        let counts = try f.library.tagUsageCounts(inCategory: f.band.id)
        #expect(counts[f.bandA.id] == 3)
        #expect(counts[f.bandB.id] == 1)
        // A tag nobody uses still has a row, reading zero.
        let unused = try f.library.ensureTag(named: "Nobody", inCategory: f.band.id)
        #expect(try f.library.tagUsageCounts(inCategory: f.band.id)[unused.id] == 0)
    }

    /// An alias IS a name: creating a tag whose name matches an existing
    /// alias returns that tag rather than a rival spelling of it.
    @Test func ensureTagResolvesAliases() throws {
        let f = try FilterFixture()
        try f.library.addAlias("SBD Matrix", toTag: f.sbd.id)
        let resolved = try f.library.ensureTag(named: "SBD Matrix", inCategory: f.recordingType.id)
        #expect(resolved.id == f.sbd.id)
    }

    @Test func orderIsWrittenInOnePass() throws {
        let f = try FilterFixture()
        try f.library.setCategoryOrder([f.recordingType.id, f.band.id])
        let ordered = try f.library.vocabulary().map(\.category.name)
        #expect(ordered == ["Recording Type", "Band"])
    }

    // MARK: - Fields

    @Test func fieldsAreScopedToWhatTheyAttachTo() throws {
        let f = try FilterFixture()
        try f.library.createField(
            FieldDefinition(name: "City", scope: .tag, tagCategoryID: f.band.id))
        try f.library.createField(FieldDefinition(name: "Lesson Number", dataType: .number, scope: .mediaItem))
        #expect(try f.library.fields(scope: .tag, categoryID: f.band.id).map(\.name) == ["City"])
        #expect(try f.library.fields(scope: .tag, categoryID: f.recordingType.id).isEmpty)
        #expect(try f.library.fields(scope: .mediaItem).map(\.name) == ["Lesson Number"])
    }

    @Test func aTagsFieldValueRoundTripsAndClears() throws {
        let f = try FilterFixture()
        let field = try f.library.createField(
            FieldDefinition(name: "Capacity", dataType: .number, scope: .tag, tagCategoryID: f.band.id))
        try f.library.setFieldValue("2400", ofTag: f.bandA.id, field: field)
        #expect(try f.library.fieldValues(ofTag: f.bandA.id)[field.id] == "2400")
        try f.library.setFieldValue("  ", ofTag: f.bandA.id, field: field)
        #expect(try f.library.fieldValues(ofTag: f.bandA.id)[field.id] == nil)
    }

    // MARK: - Display style

    @Test func theDisplayStyleReplacedABoolean() throws {
        let library = try LibraryDatabase.openInMemory()
        try library.createCategory(TagCategory(name: "Year", allowMultiple: false, displayStyle: .radio))
        let category = try library.vocabulary().first?.category
        #expect(category?.displayStyle == .radio)
        // Only checkboxes claims the player's Alt+1…9 keys.
        #expect(category?.displayAsCheckboxes == false)
    }

    /// A vocabulary file written before the style existed still loads.
    @Test func aPlanWrittenBeforeTheStyleStillLoads() throws {
        let json = """
        {"name": "Old", "categories": [
            {"id": "\(UUID().uuidString)", "include": true, "name": "Band",
             "originalName": "Band", "allowMultiple": true,
             "displayAsCheckboxes": true, "isDefaultFocus": true,
             "sortOrder": 0, "notes": "", "hiddenFromBrowse": false,
             "textFormat": 0, "separatorsToSpaces": false,
             "writebackEnabled": true, "tags": [], "fields": []}],
         "itemFields": []}
        """
        let plan = try JSONDecoder().decode(LibraryPlan.self, from: Data(json.utf8))
        #expect(plan.categories.first?.displayStyle == .checkboxes)
        #expect(plan.validationErrors().isEmpty)
    }

    // MARK: - Similarity

    /// The drift a migrated library actually has: articles, ampersands
    /// and plurals. Each rule earns its place from a real pair.
    @Test func similarityClustersTheSpellingsOfOneName() {
        #expect(TagSimilarity.key("Ash & Ember") == TagSimilarity.key("Ash and Ember"))
        #expect(TagSimilarity.key("Broadside") == TagSimilarity.key("The Broadside"))
        #expect(TagSimilarity.key("Encore") == TagSimilarity.key("Encores"))
        #expect(TagSimilarity.key("Riverbend") != TagSimilarity.key("Riverside"))
    }

    @Test func clustersOfOneAreNotFindings() {
        let names = ["Ash & Ember", "Ash and Ember", "Broadside", "Solo"]
        let clusters = TagSimilarity.clusters(names, name: { $0 }, uses: { _ in 1 })
        #expect(clusters.count == 1)
        #expect(Set(clusters[0]) == ["Ash & Ember", "Ash and Ember"])
    }

    /// Most-used first, and the winner leads its own cluster — the
    /// header names it, so the merge target is obvious.
    @Test func theMostUsedSpellingLeads() {
        let uses = ["Encore": 12, "Encores": 2]
        let clusters = TagSimilarity.clusters(
            Array(uses.keys), name: { $0 }, uses: { uses[$0] ?? 0 })
        #expect(clusters.first?.first == "Encore")
    }
}

/// One separator set per library — a category decides whether separators
/// apply, never which ones.
@Suite struct SeparatorCharacterTests {

    @Test func theLibraryOwnsTheSeparatorSet() throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Sep")
        #expect(try library.info()?.separatorCharacters == "-._")
    }

    @Test func formattingUsesTheLibrarysSet() {
        // The default set splits all three.
        #expect(
            TagNameFormatter.format(
                "dave-matthews.band_live", textFormat: .noFormatting,
                separatorsToSpaces: true)
                == "dave matthews band live")
        // A narrower set leaves the others alone.
        #expect(
            TagNameFormatter.format(
                "dave-matthews.band_live", textFormat: .noFormatting,
                separatorsToSpaces: true, separatorCharacters: "-")
                == "dave matthews.band_live")
    }

    /// A category that does not convert separators is untouched by the
    /// set, whatever it is — the hyphen stays, and title case only
    /// capitalises across whitespace (ported behaviour).
    @Test func aCategoryThatDoesNotConvertIsUnaffected() {
        #expect(
            TagNameFormatter.format(
                "dave-matthews", textFormat: .titleCase, separatorsToSpaces: false,
                separatorCharacters: "-._")
                == "Dave-matthews")
    }
}
