import Foundation
import GRDB

// MARK: - VocabularyManaging

extension LocalLibraryService {
    public func categories() async throws -> [TagCategory] {
        try await library.read { try TagCategory.order(sql: "sortOrder, name").fetchAll($0) }
    }

    public func categoryTable(categoryID: UUID) async throws -> CategoryTable {
        // One read, so the tags, their aliases and their counts are of
        // the same moment.
        try await library.read { db in
            let tags = try Tag.filter(sql: "tagCategoryID = ?", arguments: [categoryID])
                .order(sql: "sortOrder, name").fetchAll(db)
            let aliasRows = try TagAlias.fetchAll(
                db,
                sql: """
                SELECT tagAlias.* FROM tagAlias JOIN tag ON tag.id = tagAlias.tagID \
                WHERE tag.tagCategoryID = ?
                """,
                arguments: [categoryID])
            let counts = try Row.fetchAll(
                db,
                sql: """
                SELECT tag.id AS id, COUNT(mediaItemTag.mediaItemID) AS n FROM tag \
                LEFT JOIN mediaItemTag ON mediaItemTag.tagID = tag.id \
                WHERE tag.tagCategoryID = ? GROUP BY tag.id
                """,
                arguments: [categoryID])
            return CategoryTable(
                tags: tags,
                aliases: Dictionary(grouping: aliasRows, by: \.tagID).mapValues { $0.map(\.alias).sorted() },
                usage: Dictionary(uniqueKeysWithValues: counts.map { ($0["id"] as UUID, $0["n"] as Int) }))
        }
    }

    public func vocabularyIndex() async throws -> VocabularyIndex {
        let vocabulary = try library.vocabulary().map { CategoryTags(category: $0.category, tags: $0.tags) }
        let aliasRows = try await library.read { try TagAlias.fetchAll($0) }
        return VocabularyIndex(
            vocabulary: vocabulary,
            aliases: Dictionary(grouping: aliasRows, by: \.tagID).mapValues { $0.map(\.alias) },
            usage: try library.tagUsageCounts())
    }

    public func fields(scope: FieldScope, categoryID: UUID?) async throws -> [FieldDefinition] {
        try library.fields(scope: scope, categoryID: categoryID)
    }

    public func fieldValues(tagID: UUID) async throws -> [UUID: String] {
        try library.fieldValues(ofTag: tagID)
    }

    public func takenNames(categoryID: UUID) async throws -> Set<String> {
        try await library.read { db in
            let names = try String.fetchAll(
                db, sql: "SELECT name FROM tag WHERE tagCategoryID = ?", arguments: [categoryID])
            // An alias is a name: pasting one must not make a rival
            // spelling of the tag it already points at.
            let aliases = try String.fetchAll(
                db,
                sql: """
                SELECT tagAlias.alias FROM tagAlias \
                JOIN tag ON tag.id = tagAlias.tagID WHERE tag.tagCategoryID = ?
                """,
                arguments: [categoryID])
            return Set((names + aliases).map { $0.lowercased() })
        }
    }

    public func createCategory(_ category: TagCategory) async throws {
        try library.createCategory(category)
    }

    public func updateCategory(_ category: TagCategory) async throws {
        try library.updateCategory(category)
    }

    public func deleteCategory(_ categoryID: UUID) async throws {
        try library.deleteCategory(categoryID)
    }

    public func mergeTags(_ sourceIDs: [UUID], into target: TagMergeTarget) async throws -> Tag {
        let into: LibraryDatabase.MergeTarget = switch target {
        case .existing(let id): .existing(id)
        case .newTag(let name): .newTag(named: name)
        }
        return try library.mergeTags(sourceIDs, into: into, keepNamesAsAliases: true)
    }

    public func setTagHidden(_ tagID: UUID, _ hidden: Bool) async throws {
        try library.setTagHidden(tagID, hidden)
    }

    public func setTagNotes(_ tagID: UUID, _ notes: String) async throws {
        try library.setTagNotes(tagID, notes)
    }

    public func setFieldValue(_ value: String, tagID: UUID, field: FieldDefinition) async throws {
        try library.setFieldValue(value, ofTag: tagID, field: field)
    }

    public func createField(_ field: FieldDefinition) async throws -> FieldDefinition {
        try library.createField(field)
    }

    public func deleteField(_ fieldID: UUID) async throws {
        try library.deleteField(fieldID)
    }
}
