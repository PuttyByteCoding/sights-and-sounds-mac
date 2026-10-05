import Foundation

/// Authoring the vocabulary: what the Tag Manager reads and changes —
/// the categories, a category's table of tags, the fields tags and items
/// carry, and the merges and deletions that reshape them.
public protocol VocabularyManaging: Sendable {
    /// Every category, in the order they are shown.
    func categories() async throws -> [TagCategory]

    /// One category's tags in table order, with each tag's aliases and
    /// how many items wear it. One answer, so the three cannot be from
    /// different moments.
    func categoryTable(categoryID: UUID) async throws -> CategoryTable

    /// The whole vocabulary with every alias and library-wide use
    /// counts: what a search across all categories ranks.
    func vocabularyIndex() async throws -> VocabularyIndex

    /// The fields of a scope: a category's tag fields, or — with no
    /// category — the fields every item carries.
    func fields(scope: FieldScope, categoryID: UUID?) async throws -> [FieldDefinition]

    /// A tag's field values, by field.
    func fieldValues(tagID: UUID) async throws -> [UUID: String]

    /// Every name and alias a category already has, lowercased: what a
    /// pasted list is checked against so it makes no rival spelling.
    func takenNames(categoryID: UUID) async throws -> Set<String>

    func createCategory(_ category: TagCategory) async throws
    func updateCategory(_ category: TagCategory) async throws
    /// The category goes, and its tags with it.
    func deleteCategory(_ categoryID: UUID) async throws

    /// Fold several tags into one. Their items move to it and their
    /// names stay as its aliases. Returns the tag they became.
    func mergeTags(_ sourceIDs: [UUID], into target: TagMergeTarget) async throws -> Tag

    func setTagHidden(_ tagID: UUID, _ hidden: Bool) async throws
    func setTagNotes(_ tagID: UUID, _ notes: String) async throws
    func setFieldValue(_ value: String, tagID: UUID, field: FieldDefinition) async throws
    func createField(_ field: FieldDefinition) async throws -> FieldDefinition
    func deleteField(_ fieldID: UUID) async throws
}

public struct CategoryTable: Codable, Equatable, Sendable {
    public var tags: [Tag]
    /// By tag, each sorted.
    public var aliases: [UUID: [String]]
    /// By tag; an entry for every tag, zero for one no item wears.
    public var usage: [UUID: Int]

    public init(tags: [Tag], aliases: [UUID: [String]], usage: [UUID: Int]) {
        self.tags = tags
        self.aliases = aliases
        self.usage = usage
    }
}

public struct VocabularyIndex: Codable, Equatable, Sendable {
    public var vocabulary: [CategoryTags]
    public var aliases: [UUID: [String]]
    public var usage: [UUID: Int]

    public init(vocabulary: [CategoryTags], aliases: [UUID: [String]], usage: [UUID: Int]) {
        self.vocabulary = vocabulary
        self.aliases = aliases
        self.usage = usage
    }
}

/// What several tags are merged into.
public enum TagMergeTarget: Codable, Equatable, Sendable {
    /// One of the library's tags — usually one of those being merged.
    case existing(UUID)
    /// A new tag of this name, in the category of the tags merged.
    case newTag(named: String)
}
