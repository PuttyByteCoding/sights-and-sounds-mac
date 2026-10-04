import Foundation
import GRDB

// MARK: - BrowseWriting

extension LocalLibraryService {
    public func renameSource(_ id: UUID, to rawName: String) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ServiceError.emptyName }
        // The one column, by id: the caller's copy of the row can be
        // behind this one, and writing it back whole undid what had
        // changed since. Nothing is written for a name already in place.
        try await library.writer.write { db in
            try db.execute(
                sql: "UPDATE source SET name = ? WHERE id = ? AND name <> ?", arguments: [name, id, name])
        }
    }

    public func setSourceEnabled(_ id: UUID, _ enabled: Bool) async throws {
        try await library.writer.write { db in
            try db.execute(
                sql: "UPDATE source SET enabled = ? WHERE id = ? AND enabled <> ?",
                arguments: [enabled, id, enabled])
        }
    }

    public func addSource(named name: String, rootPath: String) async throws -> Source {
        try library.addSource(named: name, rootPath: rootPath)
    }

    @discardableResult
    public func saveFilter(named name: String, _ filter: MediaFilter) async throws -> SavedFilter {
        try library.saveFilter(named: name, filter)
    }

    public func updateSavedFilter(_ id: UUID, to filter: MediaFilter) async throws {
        try library.updateSavedFilter(id, to: filter)
    }

    public func renameSavedFilter(_ id: UUID, to name: String) async throws {
        try library.renameSavedFilter(id, to: name)
    }

    public func deleteSavedFilter(_ id: UUID) async throws {
        try library.deleteSavedFilter(id)
    }

    public func assignTag(_ tagID: UUID, to itemIDs: [UUID]) async throws {
        try library.assignTag(tagID, to: itemIDs)
    }

    public func removeTag(_ tagID: UUID, from itemIDs: [UUID]) async throws {
        try library.removeTag(tagID, from: itemIDs)
    }

    public func setFavorite(_ itemIDs: [UUID], _ isFavorite: Bool) async throws {
        try library.setFavorite(itemIDs, isFavorite)
    }

    public func setNeedsReview(_ itemIDs: [UUID], _ needsReview: Bool) async throws {
        try library.setNeedsReview(itemIDs, needsReview)
    }

    public func setStaging(
        _ folder: StagingFolder, on: Bool, itemIDs: [UUID]
    ) async throws -> [StagingFailure] {
        var failures: [StagingFailure] = []
        for id in itemIDs {
            do {
                if on {
                    try library.stage(folder, itemID: id, fileAccess: fileAccess)
                } else {
                    try library.unstage(folder, itemID: id, fileAccess: fileAccess)
                }
            } catch {
                failures.append(StagingFailure(itemID: id, reason: "\(error)"))
            }
        }
        return failures
    }
}
