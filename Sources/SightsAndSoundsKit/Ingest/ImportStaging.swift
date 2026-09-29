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

    /// What of this staging still exists, looked up once for a whole run.
    struct Resolved {
        let presentTagIDs: Set<UUID>
        let definitions: [UUID: FieldDefinition]
        /// Staged tags and fields that no longer exist. A value staged
        /// onto five hundred files is still one missing value.
        let missing: Set<UUID>
    }

    func resolve(in library: LibraryDatabase) throws -> Resolved {
        let present: Set<UUID> = tagIDs.isEmpty ? [] : try library.writer.read { db in
            Set(try UUID.fetchAll(
                db, sql: "SELECT id FROM \(Tag.databaseTableName) WHERE id IN (\(tagIDs.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(tagIDs)))
        }
        let definitions = fieldValues.isEmpty ? [:] : Dictionary(
            try library.fields(scope: .mediaItem).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = Set(tagIDs.filter { !present.contains($0) })
            .union(fieldValues.keys.filter { definitions[$0] == nil })
        return Resolved(presentTagIDs: present, definitions: definitions, missing: missing)
    }

    /// Apply to one inserted row. A staged tag or field deleted while the
    /// import waited is skipped, not fatal — it used to fail the job with
    /// the row already in, and a re-run then skipped that row as imported,
    /// so its staging never landed. One deleted while the import RUNS is
    /// skipped too: the write that meets it fails, and if the value is
    /// then gone, that is why. Returns the values found gone this way.
    func apply(to itemID: UUID, in library: LibraryDatabase, resolved: Resolved) throws -> Set<UUID> {
        var vanished: Set<UUID> = []
        for tagID in tagIDs where resolved.presentTagIDs.contains(tagID) {
            do {
                try library.assignTag(tagID, to: itemID)
            } catch {
                guard try !Self.tagExists(tagID, in: library) else { throw error }
                vanished.insert(tagID)
            }
        }
        for (fieldID, value) in fieldValues {
            guard let definition = resolved.definitions[fieldID] else { continue }
            do {
                try library.setFieldValue(value, ofItem: itemID, field: definition)
            } catch {
                guard try !Self.fieldExists(fieldID, in: library) else { throw error }
                vanished.insert(fieldID)
            }
        }
        if clearsNeedsReview {
            try library.setNeedsReview([itemID], false)
        }
        if marksFavorite {
            _ = try library.toggleFlag(.favorite, itemID: itemID)
        }
        return vanished
    }

    private static func tagExists(_ id: UUID, in library: LibraryDatabase) throws -> Bool {
        try library.writer.read { try Tag.exists($0, key: id) }
    }

    private static func fieldExists(_ id: UUID, in library: LibraryDatabase) throws -> Bool {
        try library.writer.read { try FieldDefinition.exists($0, key: id) }
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
