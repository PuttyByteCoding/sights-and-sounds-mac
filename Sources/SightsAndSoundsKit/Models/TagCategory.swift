import Foundation
import GRDB

/// A classification within one library's vocabulary — Band, Venue, Subject.
/// Owns its tags. Phase 0 carries only what the filter needs; selection
/// rules, display mode, write-back configuration and field definitions
/// arrive with the Phase 1 schema.
public struct TagCategory: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tagCategory"

    public var id: UUID
    public var name: String
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}
