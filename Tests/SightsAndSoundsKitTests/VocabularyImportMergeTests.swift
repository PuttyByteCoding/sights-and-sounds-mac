import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// Import is additive: it never reconfigures what the library already
/// has. "Already has" is decided the way tagging decides it — the
/// formatted name, then aliases — not by the raw spelling in the file.
@Suite struct VocabularyImportMergeTests {
    private func library() async throws -> (LibraryDatabase, TagCategory, SightsAndSoundsKit.Tag) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Vocab")
        let category = TagCategory(name: "Recording Type")
        try library.createCategory(category)
        let soundboard = try library.ensureTag(named: "Soundboard", inCategory: category.id)
        try library.addAlias("SBD", toTag: soundboard.id)
        return (library, category, soundboard)
    }

    private func importing(_ tags: [PlannedTag], into library: LibraryDatabase) throws -> VocabularyIO.ImportOutcome {
        var plan = try VocabularyIO.exportPlan(from: library)
        plan.categories[0].tags = tags
        return try VocabularyIO.importJSON(try JSONEncoder().encode(plan), into: library)
    }

    private func tag(_ id: UUID, in library: LibraryDatabase) throws -> SightsAndSoundsKit.Tag? {
        try library.writer.read { try SightsAndSoundsKit.Tag.fetchOne($0, key: id) }
    }

    /// "SBD" in the file is the library's Soundboard, by alias: the
    /// file's hidden flag must not hide the tag the user already had,
    /// and it is not counted as created.
    @Test func aTagMatchedByAliasIsNotReconfigured() async throws {
        let (library, _, soundboard) = try await library()

        let outcome = try importing([PlannedTag(name: "SBD", hiddenByDefault: true)], into: library)

        #expect(try tag(soundboard.id, in: library)?.hiddenByDefault == false)
        #expect(outcome.tagsCreated == 0)
    }

    /// An existing tag still gains aliases it is missing — additive, and
    /// what lets a re-run finish an import that stopped partway.
    @Test func anExistingTagGainsItsMissingAliases() async throws {
        let (library, _, soundboard) = try await library()

        _ = try importing([PlannedTag(name: "Soundboard", aliases: ["Board"])], into: library)

        let aliases = try await library.writer.read { db in
            try String.fetchAll(db, sql: "SELECT alias FROM tagAlias WHERE tagID = ?", arguments: [soundboard.id])
        }
        #expect(Set(aliases) == ["SBD", "Board"])
    }

    /// A tag the import creates carries everything the file says about
    /// it — export writes favourite, order and notes, so import keeps them.
    @Test func aCreatedTagKeepsItsFavouriteOrderAndNotes() async throws {
        let (library, category, _) = try await library()

        let outcome = try importing(
            [PlannedTag(name: "Audience", isFavorite: true, sortOrder: 7, notes: "front row", hiddenByDefault: true)],
            into: library)

        let created = try await library.writer.read { db in
            try SightsAndSoundsKit.Tag.filter(sql: "tagCategoryID = ? AND name = ?", arguments: [category.id, "Audience"]).fetchOne(db)
        }
        #expect(outcome.tagsCreated == 1)
        #expect(created?.isFavorite == true)
        #expect(created?.sortOrder == 7)
        #expect(created?.notes == "front row")
        #expect(created?.hiddenByDefault == true)
    }
}
