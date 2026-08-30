import Foundation
import GRDB

/// A library the app knows about — the registry row, cached from the
/// library file's own `LibraryInfo` and reconciled by `libraryID`.
public struct LibraryRef: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "libraryRef"

    /// The library's own id (`LibraryInfo.libraryID`), not a registry id —
    /// so a moved file re-registers as the same library.
    public var id: UUID
    public var name: String
    public var filePath: String
    public var addedAt: Date
    public var lastOpenedAt: Date?

    // What the library held at its last close. Flat columns rather than a
    // JSON blob so the registry stays queryable, wrapped by `summary`
    // below — `summaryCapturedAt` is the presence flag: a library added
    // but never opened has counts of zero, which is not the same as
    // "nothing is known yet".
    public var summaryCapturedAt: Date?
    public var summaryItemCount: Int?
    public var summaryTotalBytes: Int64?
    public var summarySourceCount: Int?
    public var summaryCategoryCount: Int?
    public var summaryTagCount: Int?

    public init(id: UUID, name: String, filePath: String, addedAt: Date = Date(), lastOpenedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.filePath = filePath
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }

    /// The cached counts, or `nil` for a library that has not been closed
    /// since the cache arrived. The picker shows a row either way; only
    /// the summary line differs.
    public var summary: LibrarySummary? {
        guard let capturedAt = summaryCapturedAt else { return nil }
        return LibrarySummary(
            itemCount: summaryItemCount ?? 0,
            totalBytes: summaryTotalBytes ?? 0,
            sourceCount: summarySourceCount ?? 0,
            categoryCount: summaryCategoryCount ?? 0,
            tagCount: summaryTagCount ?? 0,
            capturedAt: capturedAt)
    }
}

/// The small app-level store: the library registry and preferences.
/// Paired devices and worker settings join it in their phases (9 and 5).
///
/// Never library content — everything about media, tags and sources lives
/// in the library's own file so a library stays portable.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(writer: pool)
    }

    public static func openInMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("phase1") { db in
            try db.create(table: "libraryRef") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("filePath", .text).notNull()
                t.column("addedAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime)
            }
            try db.create(table: "preference") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        // The picker's row summary, cached on close so opening the app
        // does not mean opening every library and waking every drive.
        // Nullable throughout: an existing registry has no counts yet, and
        // a row with none is a legitimate state, not a broken one.
        migrator.registerMigration("librarySummaryCache") { db in
            try db.alter(table: "libraryRef") { t in
                t.add(column: "summaryCapturedAt", .datetime)
                t.add(column: "summaryItemCount", .integer)
                t.add(column: "summaryTotalBytes", .integer)
                t.add(column: "summarySourceCount", .integer)
                t.add(column: "summaryCategoryCount", .integer)
                t.add(column: "summaryTagCount", .integer)
            }
        }
        // Repair recipes are data: a match, a tool, a command template,
        // an estimate and a risk label. App-level because the tools are
        // machine-wide, and editable so adding one is a settings change
        // rather than a release.
        migrator.registerMigration("repairRecipes") { db in
            try db.create(table: "repairRecipe") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("matchesFailureKind", .text)
                t.column("tool", .text).notNull()
                t.column("argumentTemplate", .text).notNull()
                t.column("estimate", .text).notNull()
                t.column("risk", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("notes", .text).notNull().defaults(to: "")
            }
        }

        // External tools are declared once and referenced by name, so a
        // recipe whose binary is missing can be flagged in place rather
        // than silently never matching.
        migrator.registerMigration("externalTools") { db in
            try db.create(table: "externalTool") { t in
                t.primaryKey("name", .text)
                t.column("path", .text)
                t.column("version", .text)
                t.column("lastVerifiedAt", .datetime)
            }
            try db.alter(table: "repairRecipe") { t in
                t.add(column: "enabled", .boolean).notNull().defaults(to: true)
                t.add(column: "matchPattern", .text)
            }
        }

        return migrator
    }

    // MARK: - Registry

    /// Register (or refresh) a library from its open handle. Reconciles by
    /// the library's own id, so re-adding a moved file updates the path
    /// instead of duplicating the entry.
    @discardableResult
    public func register(_ library: LibraryDatabase) throws -> LibraryRef {
        guard let info = try library.info() else {
            throw DatabaseError(message: "library has no identity row; call ensureInfo(name:) first")
        }
        guard let url = library.fileURL else {
            throw DatabaseError(message: "in-memory libraries cannot be registered")
        }
        return try writer.write { db in
            if var existing = try LibraryRef.fetchOne(db, key: info.libraryID) {
                existing.name = info.name
                existing.filePath = url.path
                try existing.update(db)
                return existing
            }
            let ref = LibraryRef(id: info.libraryID, name: info.name, filePath: url.path)
            try ref.insert(db)
            return ref
        }
    }

    public func libraries() throws -> [LibraryRef] {
        try writer.read { try LibraryRef.order(sql: "addedAt, name").fetchAll($0) }
    }

    /// Remove a library from the registry. The library FILE is untouched
    /// — this forgets the entry, nothing more; Add Existing re-registers
    /// it (reconciled by the library's own id, never a duplicate).
    public func unregister(_ libraryID: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM libraryRef WHERE id = ?", arguments: [libraryID])
        }
    }

    /// Record what a library held, so the picker can show it without
    /// opening the file. Called when a library closes — the one moment
    /// the counts are both current and free, because the handle is
    /// already open and about to go away.
    ///
    /// A library that is no longer registered is not an error: it was
    /// forgotten while open, and the write simply has nowhere to land.
    public func cacheSummary(_ summary: LibrarySummary, for libraryID: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE libraryRef SET
                        summaryCapturedAt = ?, summaryItemCount = ?, summaryTotalBytes = ?,
                        summarySourceCount = ?, summaryCategoryCount = ?, summaryTagCount = ?
                    WHERE id = ?
                    """,
                arguments: [
                    summary.capturedAt, summary.itemCount, summary.totalBytes,
                    summary.sourceCount, summary.categoryCount, summary.tagCount,
                    libraryID,
                ])
        }
    }

    public func touchLastOpened(_ libraryID: UUID, at date: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE libraryRef SET lastOpenedAt = ? WHERE id = ?",
                arguments: [date, libraryID])
        }
    }

    // MARK: - Preferences

    public func preference(_ key: String) throws -> String? {
        try writer.read {
            try String.fetchOne($0, sql: "SELECT value FROM preference WHERE key = ?", arguments: [key])
        }
    }

    public func setPreference(_ key: String, to value: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO preference (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value])
        }
    }
}
