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

    /// Checkpoint and close. GRDB pools keep a persistent WAL sidecar, so
    /// the truncate checkpoint here is what folds every commit into the
    /// main file — the step that makes a library portable as *one* file.
    /// Copy or move a library only after closing it.
    public func close() throws {
        if writer is DatabasePool {
            try writer.writeWithoutTransaction { db in
                try db.checkpoint(.truncate)
            }
        }
        try writer.close()
    }

    /// A fresh in-memory library. Test-only convenience; identical schema.
    public static func openInMemory() throws -> LibraryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        return try LibraryDatabase(writer: queue, fileURL: nil)
    }

    // MARK: - Identity

    /// This library's identity row, if it has been stamped.
    public func info() throws -> LibraryInfo? {
        try writer.read { try LibraryInfo.fetchOne($0) }
    }

    /// Stamp the library's identity on first use; later calls return the
    /// existing row untouched (a library is named once — renames are an
    /// explicit update, not a side effect of opening).
    @discardableResult
    public func ensureInfo(name: String) throws -> LibraryInfo {
        try writer.write { db in
            if let existing = try LibraryInfo.fetchOne(db) { return existing }
            try LibraryInfo(name: name).insert(db)
            // Return the stored row, not the in-memory one — storage
            // truncates Date to millisecond precision and the canonical
            // value is what every later read sees.
            return try LibraryInfo.fetchOne(db)!
        }
    }

    // MARK: - Migrations

    /// Registered migrations, oldest first. Append-only: every schema change
    /// lands as a new registration, and the dev-fixture migration loop
    /// (delete the library file, re-run the migrator against a frozen v8
    /// snapshot) re-exercises them all.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("phase0") { db in
            try db.create(table: "tagCategory") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "tag") { t in
                t.primaryKey("id", .blob)
                t.column("tagCategoryID", .blob).notNull().indexed()
                    .references("tagCategory", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("hiddenByDefault", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "mediaItem") { t in
                t.primaryKey("id", .blob)
                t.column("kind", .integer).notNull()
                t.column("relativePath", .text).notNull().collate(.nocase)
                t.column("folderPath", .text).notNull().collate(.nocase).indexed()
                t.column("fileName", .text).notNull()
                t.column("needsReview", .boolean).notNull().defaults(to: true)
                t.column("playbackIssue", .boolean).notNull().defaults(to: false)
                t.column("markedForDeletion", .boolean).notNull().defaults(to: false)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("parentMediaItemID", .blob).references("mediaItem")
                t.column("isClip", .boolean).notNull().defaults(to: false)
                t.column("isExportedClip", .boolean).notNull().defaults(to: false)
                t.column("isEdited", .boolean).notNull().defaults(to: false)
                t.column("clipExported", .boolean).notNull().defaults(to: false)
            }
            try db.create(
                index: "mediaItem_kind", on: "mediaItem", columns: ["kind"])

            try db.create(table: "mediaItemTag") { t in
                t.column("mediaItemID", .blob).notNull()
                    .references("mediaItem", onDelete: .cascade)
                t.column("tagID", .blob).notNull()
                    .references("tag", onDelete: .cascade)
                t.primaryKey(["mediaItemID", "tagID"])
            }
            try db.create(
                index: "mediaItemTag_tagID_mediaItemID",
                on: "mediaItemTag",
                columns: ["tagID", "mediaItemID"], options: .unique)
        }

        // Phase 1: the schema that holds the whole product — identity,
        // sources with real ownership, full vocabulary configuration,
        // sortable field values, per-feature state tables, jobs.
        //
        // The phase0 entity tables are dropped and rebuilt rather than
        // altered: Phase 0 shipped no real libraries (scratch and test data
        // only), and every real library enters through the Phase 2 migrator
        // against this schema. Append-only discipline holds from here on.
        migrator.registerMigration("phase1") { db in
            try db.drop(table: "mediaItemTag")
            try db.drop(table: "mediaItem")
            try db.drop(table: "tag")
            try db.drop(table: "tagCategory")

            // -- Identity ------------------------------------------------
            try db.create(table: "libraryInfo") { t in
                // CHECK-pinned single row.
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("libraryID", .blob).notNull()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // -- Sources -------------------------------------------------
            try db.create(table: "source") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("rootPath", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("lastSeenAt", .datetime)
            }

            // -- Vocabulary ----------------------------------------------
            try db.create(table: "tagCategory") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull().collate(.nocase)
                t.column("allowMultiple", .boolean).notNull().defaults(to: true)
                t.column("displayAsCheckboxes", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("hiddenFromBrowse", .boolean).notNull().defaults(to: false)
                t.column("sectionLabel", .text)
                t.column("isDefaultFocus", .boolean).notNull().defaults(to: false)
                t.column("textFormat", .integer).notNull().defaults(to: 0)
                t.column("separatorsToSpaces", .boolean).notNull().defaults(to: false)
                t.column("writebackEnabled", .boolean).notNull().defaults(to: true)
                t.column("writebackField", .text)
                t.uniqueKey(["name"])
            }

            try db.create(table: "tag") { t in
                t.primaryKey("id", .blob)
                t.column("tagCategoryID", .blob).notNull().indexed()
                    .references("tagCategory", onDelete: .cascade)
                t.column("name", .text).notNull().collate(.nocase)
                t.column("hiddenByDefault", .boolean).notNull().defaults(to: false)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("notes", .text).notNull().defaults(to: "")
                t.uniqueKey(["tagCategoryID", "name"])
            }

            try db.create(table: "tagAlias") { t in
                t.column("tagID", .blob).notNull()
                    .references("tag", onDelete: .cascade)
                t.column("alias", .text).notNull().collate(.nocase)
                t.primaryKey(["tagID", "alias"])
            }
            try db.create(
                index: "tagAlias_alias", on: "tagAlias", columns: ["alias"])

            // -- Fields --------------------------------------------------
            try db.create(table: "fieldDefinition") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull().collate(.nocase)
                t.column("dataType", .text).notNull()
                t.column("scope", .text).notNull()
                t.column("tagCategoryID", .blob)
                    .references("tagCategory", onDelete: .cascade)
                t.column("required", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("notes", .text).notNull().defaults(to: "")
                // Scope 'tag' has a category; scope 'mediaItem' must not.
                t.check(sql: "(scope = 'tag') = (tagCategoryID IS NOT NULL)")
            }

            // -- Media items ---------------------------------------------
            try db.create(table: "mediaItem") { t in
                t.primaryKey("id", .blob)
                // RESTRICT: removing a source with items is an explicit
                // app-level operation, never a cascade.
                t.column("sourceID", .blob).notNull().indexed()
                    .references("source", onDelete: .restrict)
                t.column("kind", .integer).notNull()
                t.column("relativePath", .text).notNull().collate(.nocase)
                t.column("folderPath", .text).notNull().collate(.nocase).indexed()
                t.column("fileName", .text).notNull()
                t.column("fileSize", .integer).notNull().defaults(to: 0)
                t.column("durationSeconds", .double)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("videoCodec", .text)
                t.column("audioCodec", .text)
                t.column("pixelFormat", .text)
                t.column("frameRate", .double)
                t.column("bitrate", .integer)
                t.column("videoStreamCount", .integer)
                t.column("audioStreamCount", .integer)
                t.column("sampleRate", .integer)
                t.column("bitDepth", .integer)
                t.column("audioChannels", .integer)
                t.column("contentCreatedAt", .datetime)
                // Non-unique: duplicate hashes are review data, not errors.
                t.column("contentHash", .text).indexed()
                t.column("ingestDate", .datetime).notNull()
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("watchCount", .integer).notNull().defaults(to: 0)
                t.column("resumePositionSeconds", .double)
                t.column("completed", .boolean).notNull().defaults(to: false)
                t.column("lastWatchedAt", .datetime)
                t.column("needsReview", .boolean).notNull().defaults(to: true)
                t.column("playbackIssue", .boolean).notNull().defaults(to: false)
                t.column("markedForDeletion", .boolean).notNull().defaults(to: false)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("parentMediaItemID", .blob).references("mediaItem")
                t.column("clipStartSeconds", .double)
                t.column("clipEndSeconds", .double)
                t.column("isClip", .boolean).notNull().defaults(to: false)
                t.column("isExportedClip", .boolean).notNull().defaults(to: false)
                t.column("isEdited", .boolean).notNull().defaults(to: false)
                t.column("clipExported", .boolean).notNull().defaults(to: false)
                // Soft reference by design (breadcrumb semantics) — no FK.
                t.column("exportedToMediaItemID", .blob)
                // One row per file within a source.
                t.uniqueKey(["sourceID", "relativePath"])
            }
            try db.create(
                index: "mediaItem_kind_phase1", on: "mediaItem", columns: ["kind"])

            try db.create(table: "mediaItemTag") { t in
                t.column("mediaItemID", .blob).notNull()
                    .references("mediaItem", onDelete: .cascade)
                t.column("tagID", .blob).notNull()
                    .references("tag", onDelete: .cascade)
                t.primaryKey(["mediaItemID", "tagID"])
            }
            try db.create(
                index: "mediaItemTag_tagID_mediaItemID_phase1",
                on: "mediaItemTag",
                columns: ["tagID", "mediaItemID"], options: .unique)

            // -- Field values --------------------------------------------
            try db.create(table: "tagFieldValue") { t in
                t.column("tagID", .blob).notNull()
                    .references("tag", onDelete: .cascade)
                t.column("fieldDefinitionID", .blob).notNull()
                    .references("fieldDefinition", onDelete: .cascade)
                t.column("value", .text).notNull()
                t.column("numericValue", .double)
                t.primaryKey(["tagID", "fieldDefinitionID"])
            }
            try db.create(
                index: "tagFieldValue_definition_sort",
                on: "tagFieldValue",
                columns: ["fieldDefinitionID", "numericValue", "value"])

            try db.create(table: "mediaItemFieldValue") { t in
                t.column("mediaItemID", .blob).notNull()
                    .references("mediaItem", onDelete: .cascade)
                t.column("fieldDefinitionID", .blob).notNull()
                    .references("fieldDefinition", onDelete: .cascade)
                t.column("value", .text).notNull()
                t.column("numericValue", .double)
                t.primaryKey(["mediaItemID", "fieldDefinitionID"])
            }
            // The Learning lesson-ordering index: sort by a field without
            // touching the value rows of any other field.
            try db.create(
                index: "mediaItemFieldValue_definition_sort",
                on: "mediaItemFieldValue",
                columns: ["fieldDefinitionID", "numericValue", "value"])

            // -- Per-feature state ---------------------------------------
            try db.create(table: "contentHashFailure") { t in
                t.primaryKey("mediaItemID", .blob)
                    .references("mediaItem", onDelete: .cascade)
                t.column("message", .text).notNull()
                t.column("occurredAt", .datetime).notNull()
            }

            try db.create(table: "thumbnailState") { t in
                t.primaryKey("mediaItemID", .blob)
                    .references("mediaItem", onDelete: .cascade)
                t.column("generated", .boolean).notNull().defaults(to: false)
                t.column("failureMessage", .text)
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "ocrProgress") { t in
                t.primaryKey("mediaItemID", .blob)
                    .references("mediaItem", onDelete: .cascade)
                t.column("scannedThroughSeconds", .double).notNull()
            }

            // -- Jobs ----------------------------------------------------
            try db.create(table: "job") { t in
                t.primaryKey("id", .blob)
                t.column("kind", .text).notNull()
                t.column("state", .text).notNull().defaults(to: "queued")
                    .check { ["queued", "running", "succeeded", "failed", "cancelled"].contains($0) }
                t.column("payload", .blob)
                t.column("error", .text)
                t.column("progressCurrent", .integer).notNull().defaults(to: 0)
                t.column("progressTotal", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("startedAt", .datetime)
                t.column("finishedAt", .datetime)
            }
            try db.create(
                index: "job_state_createdAt", on: "job", columns: ["state", "createdAt"])
        }

        // Phase 2: persisted tag-analysis rules. Storage only — the engine
        // ports in Phase 4 — but the table exists now so the migrator can
        // carry the rules (authored data, the one thing the old snapshot
        // gates call out as not self-healing).
        migrator.registerMigration("phase2") { db in
            try db.create(table: "analysisRule") { t in
                t.primaryKey("id", .blob)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("matchJSON", .text).notNull()
                t.column("actionsJSON", .text).notNull()
            }
        }

        // Phase 4: user key -> tag bindings, library-owned (the old app
        // kept them in browser localStorage; the brief moves them into the
        // library, which owns everything that names its tags).
        migrator.registerMigration("phase4") { db in
            try db.create(table: "tagKeyBinding") { t in
                t.primaryKey("key", .text)
                t.column("tagID", .blob).notNull().indexed()
                    .references("tag", onDelete: .cascade)
                t.column("advance", .boolean).notNull().defaults(to: false)
            }
        }

        // Phase 5: jobs gain a human-readable completion summary ("38 new,
        // 2 skipped") so the dashboard can say what happened without
        // re-deriving it.
        migrator.registerMigration("phase5") { db in
            try db.alter(table: "job") { t in
                t.add(column: "summary", .text)
            }
        }

        return migrator
    }

    /// Identifiers of migrations already applied to this database.
    public func appliedMigrations() throws -> Set<String> {
        try writer.read { try Self.migrator.appliedIdentifiers($0) }
    }

    // MARK: - Browse queries

    /// Visible-item counts per folder, for the sidebar tree. Applies the
    /// same baseline as every listing: kind, spent clip rows, enabled
    /// sources.
    public func folderCounts(kind: MediaKind) throws -> [(path: String, count: Int)] {
        try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT mediaItem.folderPath AS path, COUNT(*) AS n FROM mediaItem \
                WHERE mediaItem.kind = ? AND mediaItem.clipExported = 0 \
                AND EXISTS (SELECT 1 FROM source \
                            WHERE source.id = mediaItem.sourceID AND source.enabled) \
                GROUP BY mediaItem.folderPath
                """,
                arguments: [kind.rawValue])
            return rows.map { ($0["path"] as String, $0["n"] as Int) }
        }
    }

    /// The library's vocabulary for the filter panel: categories in sort
    /// order, each with its tags in sort order.
    public func vocabulary() throws -> [(category: TagCategory, tags: [Tag])] {
        try writer.read { db in
            let categories = try TagCategory.order(sql: "sortOrder, name").fetchAll(db)
            let tagsByCategory = Dictionary(
                grouping: try Tag.order(sql: "sortOrder, name").fetchAll(db),
                by: \.tagCategoryID)
            return categories.map { ($0, tagsByCategory[$0.id] ?? []) }
        }
    }

    /// All sources, sidebar order.
    public func sources() throws -> [Source] {
        try writer.read { try Source.order(sql: "name").fetchAll($0) }
    }

    // MARK: - Filtered listing

    /// The visible items for a filter — the product's central query.
    ///
    /// `kind` is a required parameter on purpose: the old app's rule that
    /// every listing surface must hard-filter by media kind failed silently
    /// when forgotten, so here it cannot be omitted.
    public func mediaItems(
        matching filter: MediaFilter, kind: MediaKind,
        orderedBy ordering: MediaOrdering = .relativePath
    ) throws -> [MediaItem] {
        let compiled = FilterCompiler.compile(filter: filter, kind: kind, ordering: ordering)
        return try writer.read { db in
            try MediaItem.fetchAll(db, sql: compiled.sql, arguments: compiled.arguments)
        }
    }
}
