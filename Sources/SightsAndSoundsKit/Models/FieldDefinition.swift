import Foundation
import GRDB

/// What a field holds. Stored as text raw values — self-describing in the
/// file, no magic integers.
public enum FieldDataType: String, Codable, Sendable, CaseIterable {
    case text
    case longText
    case number
    case date
    case boolean
    case url
}

/// What a field attaches to: every tag in one category, or every media item.
public enum FieldScope: String, Codable, Sendable, CaseIterable {
    case tag
    case mediaItem
}

/// A user-defined custom field — Lesson Number, Venue Capacity, Course URL.
/// Scope `tag` requires `tagCategoryID`; scope `mediaItem` forbids it
/// (schema CHECK-enforced).
public struct FieldDefinition: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "fieldDefinition"

    public var id: UUID
    public var name: String
    public var dataType: FieldDataType
    public var scope: FieldScope
    public var tagCategoryID: UUID?
    public var required: Bool
    public var sortOrder: Int
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        dataType: FieldDataType = .text,
        scope: FieldScope,
        tagCategoryID: UUID? = nil,
        required: Bool = false,
        sortOrder: Int = 0,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.scope = scope
        self.tagCategoryID = tagCategoryID
        self.required = required
        self.sortOrder = sortOrder
        self.notes = notes
    }
}

/// Shared value-normalization for the two field-value tables.
///
/// Values store as text, but **field values must be sortable** — Learning's
/// lesson ordering is the Phase 1 requirement that settled this design:
///   - `number` fields also populate `numericValue`, so ORDER BY is numeric
///     ("10" sorts after "2", not before).
///   - `date` values are normalized to ISO 8601, which sorts lexically.
///   - everything else sorts as NOCASE text.
enum FieldValueNormalizer {
    static func numericValue(for value: String, dataType: FieldDataType) -> Double? {
        guard dataType == .number else { return nil }
        return Double(value.trimmingCharacters(in: .whitespaces))
    }
}

/// A field value attached to a single tag.
public struct TagFieldValue: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tagFieldValue"

    public var tagID: UUID
    public var fieldDefinitionID: UUID
    public private(set) var value: String
    /// Derived; maintained only through `setValue` / init so it cannot
    /// drift from `value`.
    public private(set) var numericValue: Double?

    public init(tagID: UUID, definition: FieldDefinition, value: String) {
        self.tagID = tagID
        self.fieldDefinitionID = definition.id
        self.value = value
        self.numericValue = FieldValueNormalizer.numericValue(for: value, dataType: definition.dataType)
    }

    public mutating func setValue(_ newValue: String, definition: FieldDefinition) {
        precondition(definition.id == fieldDefinitionID, "definition mismatch")
        value = newValue
        numericValue = FieldValueNormalizer.numericValue(for: newValue, dataType: definition.dataType)
    }
}

/// A field value attached to a single media item.
public struct MediaItemFieldValue: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mediaItemFieldValue"

    public var mediaItemID: UUID
    public var fieldDefinitionID: UUID
    public private(set) var value: String
    public private(set) var numericValue: Double?

    public init(mediaItemID: UUID, definition: FieldDefinition, value: String) {
        self.mediaItemID = mediaItemID
        self.fieldDefinitionID = definition.id
        self.value = value
        self.numericValue = FieldValueNormalizer.numericValue(for: value, dataType: definition.dataType)
    }

    public mutating func setValue(_ newValue: String, definition: FieldDefinition) {
        precondition(definition.id == fieldDefinitionID, "definition mismatch")
        value = newValue
        numericValue = FieldValueNormalizer.numericValue(for: newValue, dataType: definition.dataType)
    }
}
