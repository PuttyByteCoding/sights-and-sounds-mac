import Foundation
import GRDB

/// What an import applies to every row it inserts.
///
/// Staging exists because the alternative is a second trip through the
/// grid: import four hundred files, then find them again and tag them.
/// A drive of shows is one Band per folder and one Recording Type
/// overall, so the window sends one payload per folder when the scope is
/// per-folder — several payloads, not a second code path.
public struct ImportStaging: Codable, Sendable, Equatable {
    /// Tag ids to apply, grouped by the category they came from. Applied
    /// through `assignTag`, so a single-select category replaces rather
    /// than accumulating.
    public var tagIDs: [UUID]
    /// Media-item field values, by field definition.
    public var fieldValues: [UUID: String]
    /// Mark what comes in as already looked at. `needsReview` is true on
    /// insert by default — it is what the browse Missing filters and the
    /// triage pass are for — but an import of already-sorted material
    /// can say so.
    public var clearsNeedsReview: Bool
    public var marksFavorite: Bool

    public init(
        tagIDs: [UUID] = [],
        fieldValues: [UUID: String] = [:],
        clearsNeedsReview: Bool = false,
        marksFavorite: Bool = false
    ) {
        self.tagIDs = tagIDs
        self.fieldValues = fieldValues
        self.clearsNeedsReview = clearsNeedsReview
        self.marksFavorite = marksFavorite
    }

    public var isEmpty: Bool {
        tagIDs.isEmpty && fieldValues.isEmpty && !clearsNeedsReview && !marksFavorite
    }

    /// Apply to one freshly inserted item.
    func apply(to itemID: UUID, in library: LibraryDatabase) throws {
        for tagID in tagIDs {
            try library.assignTag(tagID, to: itemID)
        }
        if !fieldValues.isEmpty {
            let definitions = try library.fields(scope: .mediaItem)
            for (fieldID, value) in fieldValues {
                guard let definition = definitions.first(where: { $0.id == fieldID }) else {
                    continue
                }
                try library.setFieldValue(value, ofItem: itemID, field: definition)
            }
        }
        if clearsNeedsReview {
            try library.setNeedsReview([itemID], false)
        }
        if marksFavorite {
            _ = try library.toggleFlag(.favorite, itemID: itemID)
        }
    }
}

/// One assignment box in the import window's stage rail.
///
/// Which boxes appear is per library and saved: a Concerts library wants
/// Band, Venue and Year; a Learning library wants Course. `sticky` keeps
/// a box's value for the next import — explicitly, per box, because a
/// global "remember my last import" is a setting nobody can predict
/// (Venue and Year usually; Band never).
public struct ImportBox: Codable, Sendable, Equatable, Identifiable {
    public enum Source: Codable, Sendable, Equatable {
        case category(UUID)
        case itemField(UUID)
    }

    public var id: UUID
    public var source: Source
    public var sticky: Bool
    /// What sticky kept from the last import.
    public var stickyTagIDs: [UUID]
    public var stickyValue: String?

    public init(
        id: UUID = UUID(), source: Source, sticky: Bool = false,
        stickyTagIDs: [UUID] = [], stickyValue: String? = nil
    ) {
        self.id = id
        self.source = source
        self.sticky = sticky
        self.stickyTagIDs = stickyTagIDs
        self.stickyValue = stickyValue
    }

    public var categoryID: UUID? {
        if case .category(let id) = source { return id }
        return nil
    }

    public var fieldID: UUID? {
        if case .itemField(let id) = source { return id }
        return nil
    }
}

extension LibraryDatabase {
    /// The import window's box configuration for this library.
    public func importBoxes() throws -> [ImportBox] {
        try writer.read { db in
            guard let raw = try LibraryInfo.fetchOne(db)?.importBoxes,
                  let data = raw.data(using: .utf8),
                  let boxes = try? JSONDecoder().decode([ImportBox].self, from: data)
            else { return [] }
            return boxes
        }
    }

    public func setImportBoxes(_ boxes: [ImportBox]) throws {
        let encoded = String(data: try JSONEncoder().encode(boxes), encoding: .utf8)
        try writer.write { db in
            guard var info = try LibraryInfo.fetchOne(db) else { return }
            info.importBoxes = encoded
            try info.update(db)
        }
    }

    /// Set (or clear) one media-item field value.
    public func setFieldValue(
        _ value: String, ofItem itemID: UUID, field: FieldDefinition
    ) throws {
        try writer.write { db in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                try db.execute(
                    sql: """
                    DELETE FROM mediaItemFieldValue \
                    WHERE mediaItemID = ? AND fieldDefinitionID = ?
                    """,
                    arguments: [itemID, field.id])
                return
            }
            try MediaItemFieldValue(mediaItemID: itemID, definition: field, value: trimmed)
                .upsert(db)
        }
    }
}
