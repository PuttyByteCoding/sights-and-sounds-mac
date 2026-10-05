import Foundation

/// Changing the vocabulary one tag at a time: what a tag's own menu does
/// (favourite, replace, make an alias, delete) and what the Edit Tag
/// sheet reads and saves.
public protocol TagManaging: Sendable {
    /// Every category in order, each with all of its tags — those hidden
    /// from Browse included. What a tag can be replaced by, or made an
    /// alias of, is chosen from here.
    func fullVocabulary() async throws -> [CategoryTags]

    /// How many items wear each tag of a category: an entry for every
    /// tag in it, zero for one no item wears.
    func tagUsageCounts(categoryID: UUID) async throws -> [UUID: Int]

    /// What the Edit Tag sheet shows that the tag itself does not carry.
    func tagDetails(tagID: UUID) async throws -> TagDetails

    func setTagFavorite(_ tagID: UUID, _ isFavorite: Bool) async throws

    /// The tag's items move to `targetID`, and its name stays as an
    /// alias of that tag. Same category only.
    func convertTagToAlias(_ tagID: UUID, of targetID: UUID) async throws

    /// Put `targetID` where `tagID` is: on one item, or — with no item —
    /// on every item wearing it. The replaced tag stays in the
    /// vocabulary.
    func replaceTag(_ tagID: UUID, with targetID: UUID, on itemID: UUID?) async throws

    func deleteTag(_ tagID: UUID) async throws

    func removeAlias(_ alias: String, fromTag tagID: UUID) async throws

    /// Create a tag, or change one, as the Edit Tag sheet's Save does:
    /// every field of the sheet in one request. Returns the tag as it
    /// now is.
    func saveTag(_ draft: TagDraft) async throws -> Tag
}

public struct TagDetails: Codable, Equatable, Sendable {
    public var aliases: [String]
    /// How many field values the tag has. Moving it to another category
    /// drops them, and the sheet says how many before it is done.
    public var fieldValueCount: Int

    public init(aliases: [String], fieldValueCount: Int) {
        self.aliases = aliases
        self.fieldValueCount = fieldValueCount
    }
}

/// The Edit Tag sheet's fields, as they stand when Save is pressed.
public struct TagDraft: Codable, Equatable, Sendable {
    /// The tag being changed; nil to create one.
    public var tagID: UUID?
    public var categoryID: UUID
    public var name: String
    public var notes: String
    public var hiddenByDefault: Bool
    public var ignoredByAnalysis: Bool
    public var isFavorite: Bool
    /// For a new tag: the aliases to give it. A tag being changed has
    /// its aliases added and removed one at a time as the sheet is
    /// used, so this is not read for one.
    public var aliases: [String]

    public init(
        tagID: UUID?, categoryID: UUID, name: String, notes: String,
        hiddenByDefault: Bool, ignoredByAnalysis: Bool, isFavorite: Bool, aliases: [String]
    ) {
        self.tagID = tagID
        self.categoryID = categoryID
        self.name = name
        self.notes = notes
        self.hiddenByDefault = hiddenByDefault
        self.ignoredByAnalysis = ignoredByAnalysis
        self.isFavorite = isFavorite
        self.aliases = aliases
    }
}
