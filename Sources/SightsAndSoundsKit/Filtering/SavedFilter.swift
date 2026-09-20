import Foundation
import GRDB

/// A named, saved three-way filter — authored, like analysis rules, so
/// it migrates where derived state would not.
///
/// The filter itself is stored as JSON: terms hold tag and category
/// UUIDs, and a term whose tag has since been deleted simply matches
/// nothing when compiled — a stale saved filter degrades to fewer
/// results, never to an error.
public struct SavedFilter: Codable, Equatable, Identifiable, Sendable,
    FetchableRecord, PersistableRecord
{
    public static let databaseTableName = "savedFilter"

    public var id: UUID
    public var name: String
    public var filterJSON: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, filterJSON: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.filterJSON = filterJSON
        self.createdAt = createdAt
    }

    public var filter: MediaFilter? {
        try? JSONDecoder().decode(MediaFilter.self, from: Data(filterJSON.utf8))
    }
}

extension MediaFilter {
    /// The same filter after `sources` were merged into `keeper`: every
    /// term naming a merged tag names the keeper instead, once per slot.
    /// If that leaves the keeper both wanted (required or optional) and
    /// excluded, the exclusion goes — "A but not B" cannot be said once B
    /// is A, and a filter that lists A is a better guess at what was
    /// meant than one that can never list anything.
    func remappingTags(_ sources: Set<UUID>, to keeper: UUID) -> MediaFilter {
        func remap(_ terms: [FilterTerm]) -> [FilterTerm] {
            var seen = Set<FilterTerm>()
            return terms.map { term -> FilterTerm in
                if case .tag(let id) = term, sources.contains(id) { return .tag(keeper) }
                return term
            }.filter { seen.insert($0).inserted }
        }
        var copy = self
        copy.required = remap(required)
        copy.optional = remap(optional)
        copy.excluded = remap(excluded)
        if copy.required.contains(.tag(keeper)) || copy.optional.contains(.tag(keeper)) {
            copy.excluded.removeAll { $0 == .tag(keeper) }
        }
        return copy
    }
}

extension SavedFilter {
    /// Saved filters name tags inside JSON, where no foreign key can
    /// follow a merge. Rewrite the ones that name a merged tag; a filter
    /// this build cannot decode is left exactly as it is.
    static func remapTags(_ db: Database, from sources: Set<UUID>, to keeper: UUID) throws {
        for var saved in try SavedFilter.fetchAll(db) {
            guard let filter = saved.filter,
                  !filter.referencedTagIDs.isDisjoint(with: sources) else { continue }
            let remapped = filter.remappingTags(sources, to: keeper)
            saved.filterJSON = String(
                data: try JSONEncoder().encode(remapped), encoding: .utf8) ?? saved.filterJSON
            try saved.update(db)
        }
    }
}

extension LibraryDatabase {

    public func savedFilters() throws -> [SavedFilter] {
        try writer.read { db in
            try SavedFilter.order(sql: "name COLLATE NOCASE").fetchAll(db)
        }
    }

    /// Save under a name. Saving an existing name REPLACES that filter —
    /// "save as Favorites again" means update it, and two rows with one
    /// name would make the sidebar a guessing game.
    @discardableResult
    public func saveFilter(named rawName: String, _ filter: MediaFilter) throws -> SavedFilter {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DatabaseError(message: "a saved filter needs a name")
        }
        let json = String(
            data: try JSONEncoder().encode(filter), encoding: .utf8) ?? "{}"
        return try writer.write { db in
            if var existing = try SavedFilter
                .filter(sql: "name = ? COLLATE NOCASE", arguments: [name])
                .fetchOne(db)
            {
                existing.name = name
                existing.filterJSON = json
                try existing.update(db)
                return existing
            }
            let made = SavedFilter(name: name, filterJSON: json)
            try made.insert(db)
            return made
        }
    }

    /// Update the definition in place — "make this saved filter mean
    /// what is on screen". The row keeps its name and identity, so the
    /// sidebar and anything holding the id stay put. An unknown id
    /// changes nothing.
    public func updateSavedFilter(_ id: UUID, to filter: MediaFilter) throws {
        let json = String(
            data: try JSONEncoder().encode(filter), encoding: .utf8) ?? "{}"
        try writer.write { db in
            guard var existing = try SavedFilter.fetchOne(db, key: id) else { return }
            existing.filterJSON = json
            try existing.update(db)
        }
    }

    /// Rename in place. A name already worn by a DIFFERENT filter is
    /// refused rather than merged — renaming is about the label, and
    /// silently overwriting another filter under it would destroy one.
    public func renameSavedFilter(_ id: UUID, to rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DatabaseError(message: "a saved filter needs a name")
        }
        try writer.write { db in
            if let rival = try SavedFilter
                .filter(sql: "name = ? COLLATE NOCASE", arguments: [name])
                .fetchOne(db), rival.id != id
            {
                throw DatabaseError(message: "another filter is already named “\(name)”")
            }
            guard var filter = try SavedFilter.fetchOne(db, key: id) else { return }
            filter.name = name
            try filter.update(db)
        }
    }

    public func deleteSavedFilter(_ id: UUID) throws {
        _ = try writer.write { db in
            try SavedFilter.deleteOne(db, key: id)
        }
    }
}
