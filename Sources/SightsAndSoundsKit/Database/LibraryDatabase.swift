import Foundation
import GRDB

/// One open library — one SQLite file, one connection pool, one vocabulary.
///
/// Libraries are structurally isolated: each `LibraryDatabase` owns its own
/// file and pool, there is no ATTACH, and no query can name another library's
/// tables. Opening several libraries at once means holding several instances.
/// (Locked decision 02: separate files make cross-library leakage impossible
/// rather than merely forbidden.)
public final class LibraryDatabase: Sendable {
    /// The underlying writer. `DatabasePool` (WAL) for on-disk libraries,
    /// `DatabaseQueue` for in-memory test databases.
    public let writer: any DatabaseWriter

    /// The file this library lives in; nil for in-memory databases.
    public let fileURL: URL?

    private init(writer: any DatabaseWriter, fileURL: URL?) throws {
        self.writer = writer
        self.fileURL = fileURL
        try Self.migrator.migrate(writer)
    }

    /// Open (creating if absent) the library file at `url`.
    public static func open(at url: URL) throws -> LibraryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try LibraryDatabase(writer: pool, fileURL: url)
    }

    /// A fresh in-memory library. Test-only convenience; identical schema.
    public static func openInMemory() throws -> LibraryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        return try LibraryDatabase(writer: queue, fileURL: nil)
    }

    // MARK: - Migrations

    /// Registered migrations, oldest first. The mechanism is the deliverable
    /// in Phase 0: every future schema change lands as a new registration,
    /// and the dev-fixture migration loop re-runs against them all.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("phase0") { db in
            try db.create(table: TagCategory.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: Tag.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.column("tagCategoryID", .blob).notNull().indexed()
                    .references(TagCategory.databaseTableName, onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("hiddenByDefault", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: MediaItem.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.column("kind", .integer).notNull()
                // NOCASE so folder equality and subtree prefix match the old
                // app's OrdinalIgnoreCase path semantics in pure SQL.
                t.column("relativePath", .text).notNull().collate(.nocase)
                t.column("folderPath", .text).notNull().collate(.nocase).indexed()
                t.column("fileName", .text).notNull()
                t.column("needsReview", .boolean).notNull().defaults(to: true)
                t.column("playbackIssue", .boolean).notNull().defaults(to: false)
                t.column("markedForDeletion", .boolean).notNull().defaults(to: false)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("parentMediaItemID", .blob)
                    .references(MediaItem.databaseTableName)
                t.column("isClip", .boolean).notNull().defaults(to: false)
                t.column("isExportedClip", .boolean).notNull().defaults(to: false)
                t.column("isEdited", .boolean).notNull().defaults(to: false)
                t.column("clipExported", .boolean).notNull().defaults(to: false)
            }
            // Every listing query hard-filters by kind (the two-dimension
            // scoping lesson), so give that predicate an index from day one.
            try db.create(
                index: "mediaItem_kind", on: MediaItem.databaseTableName,
                columns: ["kind"])

            try db.create(table: MediaItemTag.databaseTableName) { t in
                t.column("mediaItemID", .blob).notNull()
                    .references(MediaItem.databaseTableName, onDelete: .cascade)
                t.column("tagID", .blob).notNull()
                    .references(Tag.databaseTableName, onDelete: .cascade)
                t.primaryKey(["mediaItemID", "tagID"])
            }
            // Covering index in tag→item direction: the filter's EXISTS
            // probes are (mediaItemID, tagID) via the primary key; tag
            // deletion and per-tag counts walk this one.
            try db.create(
                index: "mediaItemTag_tagID_mediaItemID",
                on: MediaItemTag.databaseTableName,
                columns: ["tagID", "mediaItemID"], options: .unique)
        }

        return migrator
    }

    /// Identifiers of migrations already applied to this database.
    public func appliedMigrations() throws -> Set<String> {
        try writer.read { try Self.migrator.appliedIdentifiers($0) }
    }

    // MARK: - Filtered listing

    /// The visible items for a filter — the Phase 0 spike surface.
    ///
    /// `kind` is a required parameter on purpose: the old app's rule that
    /// every listing surface must hard-filter by media kind failed silently
    /// when forgotten, so here it cannot be omitted.
    public func mediaItems(
        matching filter: MediaFilter, kind: MediaKind
    ) throws -> [MediaItem] {
        let compiled = FilterCompiler.compile(filter: filter, kind: kind)
        return try writer.read { db in
            try MediaItem.fetchAll(db, sql: compiled.sql, arguments: compiled.arguments)
        }
    }
}
