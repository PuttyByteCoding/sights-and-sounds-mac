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

    public init(id: UUID, name: String, filePath: String, addedAt: Date = Date(), lastOpenedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.filePath = filePath
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
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
