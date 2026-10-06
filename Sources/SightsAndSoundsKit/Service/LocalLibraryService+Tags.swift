import Foundation
import GRDB

// MARK: - TagManaging

extension LocalLibraryService {
    public func fullVocabulary() async throws -> [CategoryTags] {
        try library.vocabulary().map { CategoryTags(category: $0.category, tags: $0.tags) }
    }

    public func tagUsageCounts(categoryID: UUID) async throws -> [UUID: Int] {
        try library.tagUsageCounts(inCategory: categoryID)
    }

    public func tagDetails(tagID: UUID) async throws -> TagDetails {
        let aliases = try await library.read { db in
            try TagAlias.filter(sql: "tagID = ?", arguments: [tagID]).fetchAll(db).map(\.alias)
        }
        return TagDetails(aliases: aliases, fieldValueCount: try library.fieldValues(ofTag: tagID).count)
    }

    public func setTagFavorite(_ tagID: UUID, _ isFavorite: Bool) async throws {
        try library.setTagFavorite(tagID, isFavorite)
    }

    public func convertTagToAlias(_ tagID: UUID, of targetID: UUID) async throws {
        try library.convertTagToAlias(tagID, of: targetID)
    }

    public func replaceTag(_ tagID: UUID, with targetID: UUID, on itemID: UUID?) async throws {
        if let itemID {
            try library.replaceTag(tagID, with: targetID, on: itemID)
        } else {
            try library.replaceTagEverywhere(tagID, with: targetID)
        }
    }

    public func deleteTag(_ tagID: UUID) async throws {
        try library.deleteTag(tagID)
    }

    public func removeAlias(_ alias: String, fromTag tagID: UUID) async throws {
        try library.removeAlias(alias, fromTag: tagID)
    }

    public func saveTag(_ draft: TagDraft) async throws -> Tag {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let tagID: UUID
        if let existingID = draft.tagID {
            guard let existing = try await library.read({ try Tag.fetchOne($0, key: existingID) }) else {
                throw ServiceError.noSuchTag
            }
            // Only what differs is written, each through the library's
            // one way of doing it. The move first: the rename then
            // normalizes against the category the tag is IN.
            if draft.categoryID != existing.tagCategoryID {
                try library.moveTag(existing.id, toCategory: draft.categoryID)
            }
            if name != existing.name { try library.renameTag(existing.id, to: name) }
            if draft.hiddenByDefault != existing.hiddenByDefault {
                try library.setTagHidden(existing.id, draft.hiddenByDefault)
            }
            if draft.ignoredByAnalysis != existing.ignoredByAnalysis {
                try library.setTagAnalysisIgnored(existing.id, draft.ignoredByAnalysis)
            }
            if draft.isFavorite != existing.isFavorite { try library.setTagFavorite(existing.id, draft.isFavorite) }
            if draft.notes != existing.notes { try library.setTagNotes(existing.id, draft.notes) }
            tagID = existing.id
        } else {
            let created = try library.ensureTag(named: name, inCategory: draft.categoryID)
            for alias in draft.aliases { try library.addAlias(alias, toTag: created.id) }
            if draft.hiddenByDefault { try library.setTagHidden(created.id, true) }
            if draft.ignoredByAnalysis { try library.setTagAnalysisIgnored(created.id, true) }
            if draft.isFavorite { try library.setTagFavorite(created.id, true) }
            if !draft.notes.isEmpty { try library.setTagNotes(created.id, draft.notes) }
            tagID = created.id
        }
        guard let saved = try await library.read({ try Tag.fetchOne($0, key: tagID) }) else {
            throw ServiceError.noSuchTag
        }
        return saved
    }
}
