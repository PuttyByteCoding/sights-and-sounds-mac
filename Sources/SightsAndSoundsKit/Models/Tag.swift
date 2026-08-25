import Foundation
import GRDB

/// A value within a TagCategory. Name is unique within its category
/// (case-insensitive, schema-enforced).
public struct Tag: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tag"

    public var id: UUID
    public var tagCategoryID: UUID
    public var name: String
    /// Items carrying this tag are suppressed from listings unless the tag
    /// is explicitly referenced by the active filter.
    public var hiddenByDefault: Bool
    public var isFavorite: Bool
    public var sortOrder: Int
    public var notes: String

    public init(
        id: UUID = UUID(),
        tagCategoryID: UUID,
        name: String,
        hiddenByDefault: Bool = false,
        isFavorite: Bool = false,
        sortOrder: Int = 0,
        notes: String = ""
    ) {
        self.id = id
        self.tagCategoryID = tagCategoryID
        self.name = name
        self.hiddenByDefault = hiddenByDefault
        self.isFavorite = isFavorite
        self.sortOrder = sortOrder
        self.notes = notes
    }
}

/// An alternative name for a tag (SBD ↔ Soundboard). Its own table — the
/// old app kept aliases in a Postgres string array, which SQLite doesn't
/// have and which couldn't be indexed for lookup anyway.
public struct TagAlias: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tagAlias"

    public var tagID: UUID
    public var alias: String

    public init(tagID: UUID, alias: String) {
        self.tagID = tagID
        self.alias = alias
    }
}
