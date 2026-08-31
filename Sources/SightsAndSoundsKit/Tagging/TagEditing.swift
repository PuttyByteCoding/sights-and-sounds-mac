import Foundation
import GRDB

/// Tagging operations — the single write path for vocabulary and item
/// tagging, so normalization, single-select enforcement and focus
/// exclusivity can never be bypassed by a UI shortcut.
extension LibraryDatabase {

    // MARK: - Tags

    /// Find (case-insensitively) or create a tag in a category. The name is
    /// normalized per the category's TextFormat/separators configuration —
    /// identically for typing, pasting and autocomplete-create.
    @discardableResult
    public func ensureTag(named rawName: String, inCategory categoryID: UUID) throws -> Tag {
        try writer.write { db in
            guard let category = try TagCategory.fetchOne(db, key: categoryID) else {
                throw DatabaseError(message: "no such category")
            }
            let name = TagNameFormatter.format(
                rawName.trimmingCharacters(in: .whitespaces), for: category,
                separatorCharacters: try LibraryInfo.fetchOne(db)?.separatorCharacters ?? "-._")
            guard !name.isEmpty else { throw DatabaseError(message: "empty tag name") }
            if let existing = try Tag
                .filter(sql: "tagCategoryID = ? AND name = ?", arguments: [categoryID, name])
                .fetchOne(db) {
                return existing
            }
            // An alias IS a name. A tag whose name matches an existing
            // alias must resolve to that tag rather than being created
            // as a rival spelling of it — which is exactly what import
            // and paste kept producing.
            if let aliased = try Tag.fetchOne(
                db,
                sql: """
                SELECT tag.* FROM tag \
                JOIN tagAlias ON tagAlias.tagID = tag.id \
                WHERE tag.tagCategoryID = ? AND tagAlias.alias = ? \
                LIMIT 1
                """,
                arguments: [categoryID, name]) {
                return aliased
            }
            let tag = Tag(tagCategoryID: categoryID, name: name)
            try tag.insert(db)
            return tag
        }
    }

    /// Rename a tag, normalized per its category. Renaming onto an existing
    /// name (case-insensitive) is refused — merging is a deliberate,
    /// separate operation, not a rename side effect.
    public func renameTag(_ tagID: UUID, to rawName: String) throws {
        try writer.write { db in
            guard let tag = try Tag.fetchOne(db, key: tagID),
                  let category = try TagCategory.fetchOne(db, key: tag.tagCategoryID)
            else { throw DatabaseError(message: "no such tag") }
            let name = TagNameFormatter.format(
                rawName.trimmingCharacters(in: .whitespaces), for: category,
                separatorCharacters: try LibraryInfo.fetchOne(db)?.separatorCharacters ?? "-._")
            guard !name.isEmpty else { throw DatabaseError(message: "empty tag name") }
            var updated = tag
            updated.name = name
            try updated.update(db)
        }
    }

    public func deleteTag(_ tagID: UUID) throws {
        _ = try writer.write { db in
            try Tag.deleteOne(db, key: tagID)  // links/aliases/values cascade
        }
    }

    public func setTagHidden(_ tagID: UUID, _ hidden: Bool) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE tag SET hiddenByDefault = ? WHERE id = ?",
                arguments: [hidden, tagID])
        }
    }

    public func setTagFavorite(_ tagID: UUID, _ favorite: Bool) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE tag SET isFavorite = ? WHERE id = ?",
                arguments: [favorite, tagID])
        }
    }

    public func setTagNotes(_ tagID: UUID, _ notes: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE tag SET notes = ? WHERE id = ?",
                arguments: [notes, tagID])
        }
    }

    // MARK: - Aliases

    public func addAlias(_ alias: String, toTag tagID: UUID) throws {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try writer.write { db in
            try TagAlias(tagID: tagID, alias: trimmed).insert(db, onConflict: .ignore)
        }
    }

    public func removeAlias(_ alias: String, fromTag tagID: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM tagAlias WHERE tagID = ? AND alias = ?",
                arguments: [tagID, alias])
        }
    }

    // MARK: - Item tagging

    /// Apply a tag to an item. In a single-select category (allowMultiple
    /// false) this replaces any other tag of that category on the item —
    /// Year 1995 supersedes Year 1994 rather than joining it.
    public func assignTag(_ tagID: UUID, to itemID: UUID) throws {
        try writer.write { db in
            guard let tag = try Tag.fetchOne(db, key: tagID),
                  let category = try TagCategory.fetchOne(db, key: tag.tagCategoryID)
            else { throw DatabaseError(message: "no such tag") }
            if !category.allowMultiple {
                try db.execute(
                    sql: """
                    DELETE FROM mediaItemTag WHERE mediaItemID = ? AND tagID IN \
                    (SELECT id FROM tag WHERE tagCategoryID = ?)
                    """,
                    arguments: [itemID, category.id])
            }
            try MediaItemTag(mediaItemID: itemID, tagID: tagID).insert(db, onConflict: .ignore)
        }
    }

    public func removeTag(_ tagID: UUID, from itemID: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM mediaItemTag WHERE mediaItemID = ? AND tagID = ?",
                arguments: [itemID, tagID])
        }
    }

    /// Toggle; returns the new state (true = now applied).
    @discardableResult
    public func toggleTag(_ tagID: UUID, on itemID: UUID) throws -> Bool {
        let has = try writer.read { db in
            try MediaItemTag
                .filter(sql: "mediaItemID = ? AND tagID = ?", arguments: [itemID, tagID])
                .fetchOne(db) != nil
        }
        if has {
            try removeTag(tagID, from: itemID)
            return false
        }
        try assignTag(tagID, to: itemID)
        return true
    }

    /// The item's tags grouped by category, browse-panel order.
    public func tags(of itemID: UUID) throws -> [(category: TagCategory, tags: [Tag])] {
        try writer.read { db in
            let rows = try Tag.fetchAll(
                db,
                sql: """
                SELECT tag.* FROM tag \
                JOIN mediaItemTag ON mediaItemTag.tagID = tag.id \
                WHERE mediaItemTag.mediaItemID = ? \
                ORDER BY tag.sortOrder, tag.name
                """,
                arguments: [itemID])
            let byCategory = Dictionary(grouping: rows, by: \.tagCategoryID)
            let categories = try TagCategory.order(sql: "sortOrder, name").fetchAll(db)
            return categories.compactMap { category in
                guard let tags = byCategory[category.id] else { return nil }
                return (category, tags)
            }
        }
    }

    // MARK: - Categories

    /// Update a category's configuration.
    ///
    /// The focus-exclusivity cascade that used to live here is gone with
    /// `isDefaultFocus`: focus is the first visible category by sort
    /// order, so there is no longer a setting two categories can hold at
    /// once and no cascade to enforce it.
    public func updateCategory(_ category: TagCategory) throws {
        try writer.write { db in
            try category.update(db)
        }
    }

    /// Create a category.
    ///
    /// A category created without a colour (`colorIndex` at its default of
    /// 0) is dealt the next hue in rotation, so the fifth category added
    /// by hand is not the same colour as the first. Pass a non-zero index
    /// to keep one; change one later with `updateCategory`.
    public func createCategory(_ category: TagCategory) throws {
        try writer.write { db in
            var category = category
            if category.colorIndex == 0 {
                category.colorIndex = try Int.fetchOne(
                    db, sql: "SELECT COALESCE(MAX(colorIndex) + 1, 0) FROM tagCategory") ?? 0
            }
            try category.insert(db)
        }
    }

    /// Delete a category and everything under it (tags, links, values —
    /// FK cascades). The caller confirms with the user; this is the
    /// mechanical part.
    public func deleteCategory(_ categoryID: UUID) throws {
        _ = try writer.write { db in
            try TagCategory.deleteOne(db, key: categoryID)
        }
    }

    // MARK: - Merging

    /// Where merged tags land: one of the picks, or a new tag they all
    /// fold into.
    public enum MergeTarget: Sendable {
        case existing(UUID)
        case newTag(named: String)
    }

    /// Fold several tags into one, in a single transaction.
    ///
    /// Taggings re-point, the discarded spellings become aliases of the
    /// target (so search and import still resolve them), and the source
    /// rows are deleted. In a single-select category an item that
    /// carried two of the merged tags ends with one, not two — the
    /// insert is `ignore`-conflicted on the (item, tag) key, which is
    /// what collapses them.
    ///
    /// This is deliberately NOT `DuplicateReview.mergeableTags`: that
    /// merges tags between two media ITEMS during duplicate resolution,
    /// which is a different operation on different rows.
    @discardableResult
    public func mergeTags(
        _ sourceIDs: [UUID], into target: MergeTarget, keepNamesAsAliases: Bool = true
    ) throws -> Tag {
        try writer.write { db in
            let sources = try Tag.fetchAll(db, keys: sourceIDs)
            guard let first = sources.first else { throw DatabaseError(message: "nothing to merge") }
            let categoryID = first.tagCategoryID
            guard sources.allSatisfy({ $0.tagCategoryID == categoryID }) else {
                throw DatabaseError(message: "tags from two categories cannot merge")
            }
            guard let category = try TagCategory.fetchOne(db, key: categoryID) else {
                throw DatabaseError(message: "no such category")
            }

            let keeper: Tag
            switch target {
            case .existing(let id):
                guard let existing = try Tag.fetchOne(db, key: id),
                      existing.tagCategoryID == categoryID
                else { throw DatabaseError(message: "the target is not in this category") }
                keeper = existing
            case .newTag(let rawName):
                let name = TagNameFormatter.format(
                    rawName.trimmingCharacters(in: .whitespaces), for: category,
                    separatorCharacters: try LibraryInfo.fetchOne(db)?.separatorCharacters ?? "-._")
                guard !name.isEmpty else { throw DatabaseError(message: "empty tag name") }
                if let existing = try Tag
                    .filter(sql: "tagCategoryID = ? AND name = ?", arguments: [categoryID, name])
                    .fetchOne(db) {
                    keeper = existing
                } else {
                    let created = Tag(tagCategoryID: categoryID, name: name)
                    try created.insert(db)
                    keeper = created
                }
            }

            for source in sources where source.id != keeper.id {
                // Re-point taggings. `ignore` is what collapses an item
                // that carried both spellings into one tagging.
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO mediaItemTag (mediaItemID, tagID) \
                    SELECT mediaItemID, ? FROM mediaItemTag WHERE tagID = ?
                    """,
                    arguments: [keeper.id, source.id])
                // The discarded spelling, and anything already pointing
                // at it, become aliases of the keeper.
                if keepNamesAsAliases {
                    try TagAlias(tagID: keeper.id, alias: source.name)
                        .insert(db, onConflict: .ignore)
                    try db.execute(
                        sql: """
                        INSERT OR IGNORE INTO tagAlias (tagID, alias) \
                        SELECT ?, alias FROM tagAlias WHERE tagID = ?
                        """,
                        arguments: [keeper.id, source.id])
                }
                // Cascades take the taggings, aliases and field values
                // still hanging off the source row.
                try Tag.deleteOne(db, key: source.id)
            }
            return keeper
        }
    }

    /// Convert a tag into an alias of another: the taggings move, the
    /// name is kept as a way to find the survivor. The gentler half of
    /// "delete" — offered above it for exactly that reason.
    public func convertTagToAlias(_ tagID: UUID, of targetID: UUID) throws {
        try mergeTags([tagID], into: .existing(targetID), keepNamesAsAliases: true)
    }

    // MARK: - Counts and order

    /// Items per tag for one category, in one grouped query. The table
    /// shows a use count per row, and a count per row is the N+1 that
    /// makes a thousand-tag category unopenable.
    public func tagUsageCounts(inCategory categoryID: UUID) throws -> [UUID: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT tag.id AS id, COUNT(mediaItemTag.mediaItemID) AS n FROM tag \
                LEFT JOIN mediaItemTag ON mediaItemTag.tagID = tag.id \
                WHERE tag.tagCategoryID = ? GROUP BY tag.id
                """,
                arguments: [categoryID])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as UUID, $0["n"] as Int) })
        }
    }

    /// Write a whole order at once — drag-reorder is one write of every
    /// row's position, not N saves racing each other.
    public func setCategoryOrder(_ ids: [UUID]) throws {
        try writer.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE tagCategory SET sortOrder = ? WHERE id = ?",
                    arguments: [index * 10, id])
            }
        }
    }

    public func setTagOrder(_ ids: [UUID]) throws {
        try writer.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE tag SET sortOrder = ? WHERE id = ?",
                    arguments: [index * 10, id])
            }
        }
    }

    // MARK: - Fields

    /// Field definitions for one scope. Tag fields belong to a category;
    /// item fields belong to the library — the schema CHECK says a field
    /// is one or the other, never both.
    public func fields(scope: FieldScope, categoryID: UUID? = nil) throws -> [FieldDefinition] {
        try writer.read { db in
            switch scope {
            case .tag:
                guard let categoryID else { return [] }
                return try FieldDefinition
                    .filter(sql: "scope = ? AND tagCategoryID = ?",
                            arguments: [FieldScope.tag.rawValue, categoryID])
                    .order(sql: "sortOrder, name").fetchAll(db)
            case .mediaItem:
                return try FieldDefinition
                    .filter(sql: "scope = ?", arguments: [FieldScope.mediaItem.rawValue])
                    .order(sql: "sortOrder, name").fetchAll(db)
            }
        }
    }

    @discardableResult
    public func createField(_ field: FieldDefinition) throws -> FieldDefinition {
        try writer.write { db in
            var field = field
            let name = field.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw DatabaseError(message: "empty field name") }
            field.name = name
            try field.insert(db)
            return field
        }
    }

    public func updateField(_ field: FieldDefinition) throws {
        try writer.write { db in
            var field = field
            field.name = field.name.trimmingCharacters(in: .whitespaces)
            guard !field.name.isEmpty else { throw DatabaseError(message: "empty field name") }
            try field.update(db)
        }
    }

    /// Delete a field and every value stored under it (values cascade).
    public func deleteField(_ fieldID: UUID) throws {
        _ = try writer.write { db in
            try FieldDefinition.deleteOne(db, key: fieldID)
        }
    }

    /// A tag's field values, keyed by definition. The tag inspector
    /// edits these; upsert keeps the numeric mirror in step, which is
    /// what makes ordering by a number field numeric.
    public func fieldValues(ofTag tagID: UUID) throws -> [UUID: String] {
        try writer.read { db in
            let rows = try TagFieldValue
                .filter(sql: "tagID = ?", arguments: [tagID]).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.fieldDefinitionID, $0.value) })
        }
    }

    /// Set (or clear, with an empty value) one field value on a tag.
    public func setFieldValue(
        _ value: String, ofTag tagID: UUID, field: FieldDefinition
    ) throws {
        try writer.write { db in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                try db.execute(
                    sql: "DELETE FROM tagFieldValue WHERE tagID = ? AND fieldDefinitionID = ?",
                    arguments: [tagID, field.id])
                return
            }
            try TagFieldValue(tagID: tagID, definition: field, value: trimmed).upsert(db)
        }
    }

    // MARK: - Bulk item edits

    /// Mark items reviewed (or send them back to the queue). The browse
    /// grid's bulk bar is the only caller today; it lives here because a
    /// flag every surface reads should have one write path.
    public func setNeedsReview(_ itemIDs: [UUID], _ needsReview: Bool) throws {
        guard !itemIDs.isEmpty else { return }
        try writer.write { db in
            let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ", ")
            try db.execute(
                sql: "UPDATE mediaItem SET needsReview = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments([needsReview] + itemIDs.map { $0 as any DatabaseValueConvertible }))
        }
    }

    // MARK: - Key bindings

    public func keyBindings() throws -> [TagKeyBinding] {
        try writer.read { try TagKeyBinding.order(sql: "key").fetchAll($0) }
    }

    /// Bind a key (replacing any prior binding on it). Refuses keys outside
    /// the bindable set so a stale payload can't claim a fixed player key.
    public func setKeyBinding(_ key: String, tagID: UUID, advance: Bool = false) throws {
        let canonical = key.count == 1 ? key.lowercased() : key
        guard TagKeyBinding.bindableKeys.contains(canonical) else {
            throw DatabaseError(message: "key '\(canonical)' is not bindable")
        }
        try writer.write { db in
            try TagKeyBinding(key: canonical, tagID: tagID, advance: advance).upsert(db)
        }
    }

    public func removeKeyBinding(_ key: String) throws {
        _ = try writer.write { db in
            try TagKeyBinding.deleteOne(db, key: key)
        }
    }
}

extension LibraryDatabase {
    /// The items carrying one tag, for "is this tag right?" — seeing the
    /// company a tag keeps is how a doubtful tagging gets confirmed.
    /// Bounded, with the true total alongside, newest-imported first so
    /// recent mistakes surface at the top.
    public func items(withTag tagID: UUID, limit: Int = 60) throws -> (items: [MediaItem], total: Int) {
        try writer.read { db in
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM mediaItemTag WHERE tagID = ?",
                arguments: [tagID]) ?? 0
            let items = try MediaItem.fetchAll(
                db,
                sql: """
                SELECT mediaItem.* FROM mediaItem \
                JOIN mediaItemTag ON mediaItemTag.mediaItemID = mediaItem.id \
                WHERE mediaItemTag.tagID = ? \
                ORDER BY mediaItem.ingestDate DESC, mediaItem.relativePath LIMIT ?
                """,
                arguments: [tagID, limit])
            return (items, total)
        }
    }
}
