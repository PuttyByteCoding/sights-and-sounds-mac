import Foundation
import GRDB

/// A value within a TagCategory. Aliases, favorites and notes arrive with
/// the Phase 1 schema; `hiddenByDefault` is here because the filter's
/// auto-hide pass depends on it.
public struct Tag: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tag"

    public var id: UUID
    public var tagCategoryID: UUID
    public var name: String
    /// Items carrying this tag are suppressed from listings unless the tag is
    /// explicitly referenced by the active filter.
    public var hiddenByDefault: Bool

    public init(id: UUID = UUID(), tagCategoryID: UUID, name: String, hiddenByDefault: Bool = false) {
        self.id = id
        self.tagCategoryID = tagCategoryID
        self.name = name
        self.hiddenByDefault = hiddenByDefault
    }
}
