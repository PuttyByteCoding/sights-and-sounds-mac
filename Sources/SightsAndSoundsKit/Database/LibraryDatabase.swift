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
            _ = try writer.writeWithoutTransaction { db in
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

        // Phase 6: duplicate candidates and audio fingerprints. Candidate
        // pairs are order-normalized with a unique index — one row per
        // pair, ever, which is how a rejected pair stays rejected.
        migrator.registerMigration("phase6") { db in
            try db.create(table: "duplicateCandidate") { t in
                t.primaryKey("id", .blob)
                t.column("itemAID", .blob).notNull().indexed()
                    .references("mediaItem", onDelete: .cascade)
                t.column("itemBID", .blob).notNull().indexed()
                    .references("mediaItem", onDelete: .cascade)
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("source", .text).notNull()
                t.column("confidence", .double)
                t.column("offsetSeconds", .double)
                t.column("matchKind", .text)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["itemAID", "itemBID"])
            }

            try db.create(table: "audioFingerprint") { t in
                t.primaryKey("mediaItemID", .blob)
                    .references("mediaItem", onDelete: .cascade)
                t.column("durationSeconds", .double).notNull()
                t.column("fingerprint", .blob).notNull()
                t.column("toolVersion", .text).notNull()
                t.column("computedAt", .datetime).notNull()
            }

            try db.create(table: "fingerprintFailure") { t in
                t.primaryKey("mediaItemID", .blob)
                    .references("mediaItem", onDelete: .cascade)
                t.column("message", .text).notNull()
                t.column("occurredAt", .datetime).notNull()
            }
        }

        // Phase 7: the revertible file-move log. No FK — the log outlives
        // purged rows by design (names are snapshotted for labeling).
        migrator.registerMigration("phase7") { db in
            try db.create(table: "fileMoveLog") { t in
                t.primaryKey("id", .blob)
                t.column("mediaItemID", .blob).notNull().indexed()
                t.column("sourceID", .blob).notNull()
                t.column("fileName", .text).notNull()
                t.column("fromPath", .text).notNull()
                t.column("toPath", .text).notNull()
                t.column("movedAt", .datetime).notNull()
                t.column("revertedAt", .datetime)
            }
        }

        // Phase 7b: embedded clips carry their PARENT's relativePath (their
        // file IS the parent's file), so path uniqueness applies only to
        // rows that own a real file. The original uniqueness was a
        // table-level constraint (an auto-index DROP INDEX can't touch),
        // so this is the standard SQLite rebuild: new table without the
        // constraint, copy, swap, re-index — plus the partial unique index.
        migrator.registerMigration("phase7b") { db in
            try db.create(table: "mediaItem_new") { t in
                t.primaryKey("id", .blob)
                t.column("sourceID", .blob).notNull()
                    .references("source", onDelete: .restrict)
                t.column("kind", .integer).notNull()
                t.column("relativePath", .text).notNull().collate(.nocase)
                t.column("folderPath", .text).notNull().collate(.nocase)
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
                t.column("contentHash", .text)
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
                t.column("exportedToMediaItemID", .blob)
            }
            // Explicit column lists on both sides: SELECT * order is an
            // accident of history, this is not.
            let columns = "id, sourceID, kind, relativePath, folderPath, fileName, fileSize, durationSeconds, width, height, videoCodec, audioCodec, pixelFormat, frameRate, bitrate, videoStreamCount, audioStreamCount, sampleRate, bitDepth, audioChannels, contentCreatedAt, contentHash, ingestDate, notes, watchCount, resumePositionSeconds, completed, lastWatchedAt, needsReview, playbackIssue, markedForDeletion, isFavorite, parentMediaItemID, clipStartSeconds, clipEndSeconds, isClip, isExportedClip, isEdited, clipExported, exportedToMediaItemID"
            try db.execute(sql: "INSERT INTO mediaItem_new (" + columns + ") SELECT " + columns + " FROM mediaItem")
            try db.drop(table: "mediaItem")
            try db.execute(sql: "ALTER TABLE mediaItem_new RENAME TO mediaItem")

            try db.execute(sql: "CREATE INDEX mediaItem_sourceID_7b ON mediaItem(sourceID)")
            try db.execute(sql: "CREATE INDEX mediaItem_folderPath_7b ON mediaItem(folderPath)")
            try db.execute(sql: "CREATE INDEX mediaItem_kind_7b ON mediaItem(kind)")
            try db.execute(sql: "CREATE INDEX mediaItem_contentHash_7b ON mediaItem(contentHash)")
            try db.execute(sql: "CREATE UNIQUE INDEX mediaItem_sourceID_relativePath_files ON mediaItem(sourceID, relativePath) WHERE parentMediaItemID IS NULL")
        }

        // Phase 7c: marked time ranges (hide blocks skip live and drive
        // the removal edit; clip-kind blocks are informational).
        migrator.registerMigration("phase7c") { db in
            try db.create(table: "videoBlock") { t in
                t.primaryKey("id", .blob)
                t.column("mediaItemID", .blob).notNull().indexed()
                    .references("mediaItem", onDelete: .cascade)
                t.column("startSeconds", .double).notNull()
                t.column("endSeconds", .double).notNull()
                t.column("kind", .text).notNull().defaults(to: "hide")
            }
        }

        // Phase 7d: recognized on-screen text. One row per frame that
        // produced text; scan reach lives in ocrProgress (a frame with no
        // text leaves no row, but the scan still advanced past it).
        migrator.registerMigration("phase7d") { db in
            try db.create(table: "ocrTextLine") { t in
                t.primaryKey("id", .blob)
                t.column("mediaItemID", .blob).notNull().indexed()
                    .references("mediaItem", onDelete: .cascade)
                t.column("timeSeconds", .double).notNull()
                t.column("text", .text).notNull()
            }
        }

        // Phase 8: write-back's paper trail — pre-write/pre-restore tag
        // snapshots (the recovery path) and per-run/per-file history.
        migrator.registerMigration("phase8") { db in
            try db.create(table: "embeddedTagSnapshot") { t in
                t.primaryKey("id", .blob)
                t.column("mediaItemID", .blob).notNull().indexed()
                    .references("mediaItem", onDelete: .cascade)
                t.column("capturedAt", .datetime).notNull()
                t.column("source", .text).notNull()
                t.column("tagsJSON", .text).notNull()
            }
            try db.create(table: "tagWriteRun") { t in
                t.primaryKey("id", .blob)
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("scopeDescription", .text).notNull()
                t.column("totalFiles", .integer).notNull().defaults(to: 0)
                t.column("writtenCount", .integer).notNull().defaults(to: 0)
                t.column("failedCount", .integer).notNull().defaults(to: 0)
            }
            // No FK on mediaItemID and a denormalized path: run history
            // outlives moves and deletes (ported).
            try db.create(table: "tagWriteRunFile") { t in
                t.primaryKey("id", .blob)
                t.column("tagWriteRunID", .blob).notNull().indexed()
                    .references("tagWriteRun", onDelete: .cascade)
                t.column("mediaItemID", .blob).notNull()
                t.column("filePath", .text).notNull()
                t.column("status", .text).notNull()
                t.column("error", .text)
                t.column("usedRemuxFallback", .boolean).notNull().defaults(to: false)
            }
        }

        // Phase 8b: validation findings — the latest sweep's observations,
        // recomputed cheaply, never history.
        migrator.registerMigration("phase8b") { db in
            try db.create(table: "validationFinding") { t in
                t.primaryKey("id", .blob)
                t.column("kind", .text).notNull()
                t.column("mediaItemID", .blob)
                t.column("path", .text).notNull()
                t.column("detail", .text).notNull()
            }
        }

        // Per-library import-extension overrides (#69): nullable JSON
        // arrays on the identity row — nil inherits the app-wide lists.
        migrator.registerMigration("extensionOverrides") { db in
            try db.alter(table: "libraryInfo") { t in
                t.add(column: "videoExtensionsOverride", .text)
                t.add(column: "audioExtensionsOverride", .text)
            }
        }

        // A category owns its colour. The design tokens fix a hue per
        // category and the browse sidebar, the tag pills and the filter
        // chips all draw it — but nothing stored one, so every surface
        // was about to invent its own. Existing libraries are dealt
        // hues in browse order (sortOrder, then name), which is the
        // order the sidebar lists them in, so the colours read as
        // deliberate rather than random from the first launch.
        migrator.registerMigration("categoryColors") { db in
            try db.alter(table: "tagCategory") { t in
                t.add(column: "colorIndex", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: """
                UPDATE tagCategory SET colorIndex = (
                    SELECT COUNT(*) FROM tagCategory AS earlier
                    WHERE earlier.sortOrder < tagCategory.sortOrder
                       OR (earlier.sortOrder = tagCategory.sortOrder
                           AND earlier.name < tagCategory.name)
                )
                """)
        }

        // A song and a clip are the same record — a named range inside
        // the parent's file — so the difference between them is a label,
        // not a table. Existing embedded rows were all authored through
        // the clip keys, so they are clips.
        migrator.registerMigration("segmentRoles") { db in
            try db.alter(table: "mediaItem") { t in
                t.add(column: "segmentRole", .text)
            }
            try db.execute(sql: """
                UPDATE mediaItem SET segmentRole = 'clip'
                WHERE parentMediaItemID IS NOT NULL
                """)
        }

        // Display style, and the end of default focus.
        //
        // A single-select category rendered as checkboxes is the wrong
        // control, and radio was the missing one — so the boolean becomes
        // a three-way choice. Focus goes entirely: it is the first
        // visible category by sort order, which removes a setting, a
        // validation rule and the exclusivity cascade that enforced an
        // unrepresentable conflict.
        migrator.registerMigration("categoryDisplayStyle") { db in
            try db.alter(table: "tagCategory") { t in
                t.add(column: "displayStyle", .text).notNull().defaults(to: "search")
            }
            try db.execute(sql: """
                UPDATE tagCategory SET displayStyle = 'checkboxes'
                WHERE displayAsCheckboxes
                """)
            try db.alter(table: "tagCategory") { t in
                t.drop(column: "displayAsCheckboxes")
                t.drop(column: "isDefaultFocus")
            }
        }

        // The import window's assignment boxes: which categories and
        // fields it offers, in what order, and which keep their value
        // for the next import. Per library, because the vocabulary is.
        migrator.registerMigration("importBoxes") { db in
            try db.alter(table: "libraryInfo") { t in
                t.add(column: "importBoxes", .text)
            }
        }

        // "Run next" needs somewhere to write. Priority reorders the
        // queue and never pre-empts: the runner is serialized on purpose.
        migrator.registerMigration("jobPriority") { db in
            try db.alter(table: "job") { t in
                t.add(column: "priority", .integer).notNull().defaults(to: 0)
            }
        }

        // The evidence behind a playback issue, captured when the flag
        // is set. Beside the item rather than on it: only the review
        // queue reads it.
        migrator.registerMigration("playbackIssueEvidence") { db in
            try db.create(table: "playbackIssueEvidence") { t in
                t.primaryKey("mediaItemID", .blob)
                    .references("mediaItem", onDelete: .cascade)
                t.column("capturedAt", .datetime).notNull()
                t.column("probeOutput", .text).notNull()
                t.column("failureKind", .text)
            }
        }

        // Moves belong to runs. A run is the unit anyone undoes, and
        // grouping by template and timestamp breaks the moment two runs
        // share a template a minute apart.
        migrator.registerMigration("moveSessions") { db in
            try db.alter(table: "fileMoveLog") { t in
                t.add(column: "sessionID", .blob)
            }
        }

        // One separator set per library. A category decides whether to
        // convert separators, never which ones — a hyphen that splits
        // Band names but not Venue names is nobody's intention.
        migrator.registerMigration("separatorCharacters") { db in
            try db.alter(table: "libraryInfo") { t in
                t.add(column: "separatorCharacters", .text).notNull().defaults(to: "-._")
            }
        }

        // Tag analysis. Embedded metadata pairs are the candidate
        // queue's largest source and nothing persisted them before: the
        // tag writers already flatten ffprobe's dictionaries, but only
        // ever for a snapshot about to be overwritten.
        //
        // The decision table is what stops an ignored candidate coming
        // back next sweep. Keyed by (source, key, value) rather than by a
        // row id because the queue is DERIVED — it is recomputed from the
        // underlying data every time, so a decision has to survive the
        // disappearance of the row that prompted it.
        migrator.registerMigration("tagAnalysis") { db in
            try db.create(table: "embeddedMetadataPair") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mediaItemID", .blob).notNull()
                    .references("mediaItem", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.uniqueKey(["mediaItemID", "key", "value"], onConflict: .ignore)
            }
            try db.create(indexOn: "embeddedMetadataPair", columns: ["key", "value"])

            try db.create(table: "metadataSweepState") { t in
                t.primaryKey("mediaItemID", .blob)
                    .references("mediaItem", onDelete: .cascade)
                t.column("sweptAt", .datetime).notNull()
                t.column("failureMessage", .text)
            }

            try db.create(table: "tagCandidateDecision") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source", .text).notNull()
                t.column("key", .text)
                t.column("value", .text).notNull()
                t.column("decision", .text).notNull()
                t.column("decidedAt", .datetime).notNull()
                t.uniqueKey(["source", "key", "value"], onConflict: .replace)
            }
        }

        // Named filters: the current three-way filter, saved to apply
        // later. Authored, so it belongs in the library like rules do.
        migrator.registerMigration("savedFilters") { db in
            try db.create(table: "savedFilter") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull().collate(.nocase).unique()
                t.column("filterJSON", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        // The tag-analysis visited marker, versioned by analyzer
        // capability so "analyzed under an older analyzer" is a
        // filterable worklist.
        migrator.registerMigration("tagAnalysisMarker") { db in
            try db.create(table: "tagAnalysisState") { t in
                t.primaryKey("mediaItemID", .blob)
                    .references("mediaItem", onDelete: .cascade)
                t.column("analyzedAt", .datetime).notNull()
                t.column("analyzerVersion", .integer).notNull()
            }
        }

        return migrator
    }

    /// Set (or clear, with nils) this library's import-extension
    /// overrides. The override REPLACES the app-wide list.
    public func setExtensionOverrides(video: [String]?, audio: [String]?) throws {
        try writer.write { db in
            guard var info = try LibraryInfo.fetchOne(db) else { return }
            info.videoExtensionsOverride = video
            info.audioExtensionsOverride = audio
            try info.update(db)
        }
    }

    /// Identifiers of migrations already applied to this database.
    public func appliedMigrations() throws -> Set<String> {
        try writer.read { try Self.migrator.appliedIdentifiers($0) }
    }

    // MARK: - Browse queries

    /// Visible-item counts per folder, for the sidebar tree. Applies the
    /// same baseline as every listing: kind, spent clip rows, enabled
    /// sources. Pass a sourceID to scope the tree to one source — the
    /// sidebar nests a tree under each source row.
    public func folderCounts(
        kinds: MediaKinds, sourceID: UUID? = nil
    ) throws -> [(path: String, count: Int)] {
        let baseline = FilterCompiler.Baseline.sql(kinds)
        return try writer.read { db in
            var sql = """
                SELECT mediaItem.folderPath AS path, COUNT(*) AS n FROM mediaItem \
                WHERE \(baseline.sql)
                """
            var arguments: [any DatabaseValueConvertible] = baseline.args
            if let sourceID {
                sql += " AND mediaItem.sourceID = ?"
                arguments.append(sourceID)
            }
            sql += " GROUP BY mediaItem.folderPath"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
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
    /// `kinds` is a required parameter on purpose: the old app's rule that
    /// every listing surface must hard-filter by media kind failed silently
    /// when forgotten, so here it cannot be omitted — and `MediaKinds`
    /// cannot be empty, so a listing that names several kinds still cannot
    /// name none.
    public func mediaItems(
        matching filter: MediaFilter, kinds: MediaKinds,
        orderedBy ordering: MediaOrdering = .relativePath
    ) throws -> [MediaItem] {
        let compiled = FilterCompiler.compile(filter: filter, kinds: kinds, ordering: ordering)
        return try writer.read { db in
            try MediaItem.fetchAll(db, sql: compiled.sql, arguments: compiled.arguments)
        }
    }
}
