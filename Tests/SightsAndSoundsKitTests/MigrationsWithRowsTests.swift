import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// Migrations that rewrite data, run against data. The upgrade tests
/// elsewhere migrate an EMPTY database and check the list of names —
/// which a table rebuild that dropped a column, or lost every child row
/// to a cascade, would pass.
@Suite struct MigrationsWithRowsTests {

    /// A library stopped just before `stoppingBefore`, on disk, with rows.
    private func oldLibrary(
        stoppingAt last: String, seed: (Database) throws -> Void
    ) throws -> (url: URL, cleanUp: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-migrate-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Old.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try LibraryDatabase.migrator.migrate(queue, upTo: last)
        try queue.write(seed)
        try queue.close()
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    /// phase7b copies all of `mediaItem` into a new table, drops the old
    /// one and renames. Everything that points at an item points at its
    /// id, so every one of those rows has to come through.
    @Test func theItemTableRebuildKeepsEveryRowAndWhatHangsOffIt() throws {
        let sourceID = UUID(), showID = UUID(), clipID = UUID()
        let categoryID = UUID(), tagID = UUID()
        let (url, cleanUp) = try oldLibrary(stoppingAt: "phase7") { db in
            try db.execute(
                sql: "INSERT INTO source (id, name, rootPath, kind, enabled) VALUES (?, 'S', '/nowhere', 0, 1)",
                arguments: [sourceID])
            for (id, path, parent) in [(showID, "shows/show.mp4", nil as UUID?), (clipID, "shows/show.mp4#clip", showID)] {
                try db.execute(
                    sql: """
                    INSERT INTO mediaItem (id, sourceID, kind, relativePath, folderPath, fileName, \
                        fileSize, ingestDate, notes, watchCount, completed, needsReview, playbackIssue, \
                        markedForDeletion, isFavorite, parentMediaItemID, isClip, isExportedClip, \
                        isEdited, clipExported) \
                    VALUES (?, ?, 0, ?, 'shows', 'show.mp4', 1234, ?, 'a note', 3, 0, 1, 0, 0, 1, ?, ?, 0, 0, 0)
                    """,
                    arguments: [id, sourceID, path, Date(), parent, parent != nil])
            }
            try db.execute(
                sql: "INSERT INTO tagCategory (id, name, sortOrder, allowMultiple) VALUES (?, 'Band', 0, 1)",
                arguments: [categoryID])
            try db.execute(
                sql: "INSERT INTO tag (id, tagCategoryID, name, sortOrder) VALUES (?, ?, 'Band A', 0)",
                arguments: [tagID, categoryID])
            try db.execute(
                sql: "INSERT INTO mediaItemTag (mediaItemID, tagID) VALUES (?, ?)",
                arguments: [showID, tagID])
        }
        defer { cleanUp() }

        let library = try LibraryDatabase.open(at: url)
        defer { try? library.close() }

        let items = try library.writer.read { try MediaItem.order(sql: "relativePath").fetchAll($0) }
        #expect(items.map(\.id) == [showID, clipID])
        let show = try #require(items.first)
        #expect(show.fileSize == 1234)
        #expect(show.notes == "a note")
        #expect(show.watchCount == 3)
        #expect(show.needsReview && show.isFavorite)
        // The clip is still the show's, and became a segment with a role.
        #expect(items[1].parentMediaItemID == showID)
        #expect(items[1].segmentRole == .clip)
        // What hung off the item's id still does.
        let links = try library.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM mediaItemTag WHERE mediaItemID = ?", arguments: [showID])
        }
        #expect(links == 1)
        #expect(try library.writer.read { try Database.foreignKeyViolations($0) }.isEmpty)
    }

    /// categoryDisplayStyle turns a boolean into a three-way choice and
    /// then drops the boolean: the backfill has to run before the drop,
    /// and only a row that had the boolean set can show that it did.
    @Test func theDisplayStyleIsBackfilledFromTheBooleanItReplaced() throws {
        let checkboxes = UUID(), plain = UUID()
        let (url, cleanUp) = try oldLibrary(stoppingAt: "segmentRoles") { db in
            for (id, name, flag) in [(checkboxes, "Flags", true), (plain, "Band", false)] {
                try db.execute(
                    sql: """
                    INSERT INTO tagCategory (id, name, sortOrder, allowMultiple, displayAsCheckboxes)                     VALUES (?, ?, 0, 1, ?)
                    """,
                    arguments: [id, name, flag])
            }
        }
        defer { cleanUp() }

        let library = try LibraryDatabase.open(at: url)
        defer { try? library.close() }

        let styles = try library.writer.read { db in
            Dictionary(uniqueKeysWithValues: try TagCategory.fetchAll(db).map { ($0.id, $0.displayStyle) })
        }
        #expect(styles[checkboxes] == .checkboxes)
        #expect(styles[plain] == .search)
    }
}

extension Database {
    /// Rows `PRAGMA foreign_key_check` complains about.
    static func foreignKeyViolations(_ db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
    }
}
