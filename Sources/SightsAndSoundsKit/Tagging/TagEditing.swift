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
                rawName.trimmingCharacters(in: .whitespaces), for: category)
            guard !name.isEmpty else { throw DatabaseError(message: "empty tag name") }
            if let existing = try Tag
                .filter(sql: "tagCategoryID = ? AND name = ?", arguments: [categoryID, name])
                .fetchOne(db) {
                return existing
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
                rawName.trimmingCharacters(in: .whitespaces), for: category)
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

    /// Update a category's configuration. Setting `isDefaultFocus` clears
    /// it on every other category — at most one holds it (the write path
    /// enforces what the old PUT endpoint enforced).
    public func updateCategory(_ category: TagCategory) throws {
        try writer.write { db in
            if category.isDefaultFocus {
                try db.execute(
                    sql: "UPDATE tagCategory SET isDefaultFocus = 0 WHERE id <> ?",
                    arguments: [category.id])
            }
            try category.update(db)
        }
    }

    public func createCategory(_ category: TagCategory) throws {
        try writer.write { db in
            if category.isDefaultFocus {
                try db.execute(sql: "UPDATE tagCategory SET isDefaultFocus = 0")
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
