import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// Free-text search used to be four leading-wildcard LIKEs — file name,
/// path, notes, and a probe of every item's recognised text — which no
/// index can serve: every search read every row. It now asks a trigram
/// index. These pin that it finds exactly what LIKE found.
@Suite struct SearchIndexTests {

    private func names(_ f: FilterFixture, _ text: String) throws -> [String] {
        try f.names(MediaFilter(searchText: text)).sorted()
    }

    @Test func aSubstringAnywhereInThePathIsFoundWhateverItsCase() throws {
        let f = try FilterFixture()
        try f.library.writer.write { db in
            try MediaItem(
                sourceID: f.mainSource.id, kind: .video,
                relativePath: "shows/1995/Meadow_Larks-05.mp4", needsReview: false).insert(db)
        }
        #expect(try names(f, "larks-05") == ["Meadow_Larks-05.mp4"])
        #expect(try names(f, "995/MEADOW") == ["Meadow_Larks-05.mp4"])  // across the folder boundary
        #expect(try names(f, "w_l") == ["Meadow_Larks-05.mp4"])          // `_` is a character, not a wildcard
        #expect(try names(f, "meadowlarks").isEmpty)
    }

    /// Three characters is the least a trigram index can answer; shorter
    /// queries take the old route and must still work.
    @Test func aQueryTooShortForTheIndexStillFindsThings() throws {
        let f = try FilterFixture()
        try f.library.writer.write { db in
            try MediaItem(
                sourceID: f.mainSource.id, kind: .video,
                relativePath: "shows/zq.mp4", needsReview: false).insert(db)
        }
        #expect(try names(f, "zq") == ["zq.mp4"])
        #expect(try names(f, "z") .contains("zq.mp4"))
    }

    @Test func theIndexFollowsRenamesNotesRecognisedTextAndDeletes() throws {
        let f = try FilterFixture()
        let item = MediaItem(
            sourceID: f.mainSource.id, kind: .video, relativePath: "inbox/plainname.mp4", needsReview: false)
        try f.library.writer.write { try item.insert($0) }
        #expect(try names(f, "plainname") == ["plainname.mp4"])

        // Moved: found where it is, not where it was.
        try f.library.writer.write { db in
            var moved = item
            moved.setRelativePath("shows/renamed-file.mp4")
            moved.notes = "second encore was the good one"
            try moved.update(db)
        }
        #expect(try names(f, "plainname").isEmpty)
        #expect(try names(f, "renamed-fi") == ["renamed-file.mp4"])
        #expect(try names(f, "SECOND ENCORE") == ["renamed-file.mp4"])

        // Recognised on-screen text.
        let lineID = UUID()
        try f.library.writer.write { db in
            try db.execute(
                sql: "INSERT INTO ocrTextLine (id, mediaItemID, timeSeconds, text) VALUES (?, ?, 12, 'Live at the Orpheum')",
                arguments: [lineID, item.id])
        }
        #expect(try names(f, "orpheum") == ["renamed-file.mp4"])
        try f.library.writer.write { db in
            try db.execute(sql: "DELETE FROM ocrTextLine WHERE id = ?", arguments: [lineID])
        }
        #expect(try names(f, "orpheum").isEmpty)

        // Deleted: gone from the index too, with nothing left behind.
        try f.library.writer.write { db in _ = try MediaItem.deleteOne(db, key: item.id) }
        #expect(try names(f, "renamed-fi").isEmpty)
        let orphans = try f.library.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM searchText WHERE rowid NOT IN (SELECT id FROM searchRow)
                """) ?? -1
        }
        #expect(orphans == 0)
    }

    @Test func quotesAndOperatorsInAQueryAreJustText() throws {
        let f = try FilterFixture()
        try f.library.writer.write { db in
            try MediaItem(
                sourceID: f.mainSource.id, kind: .video,
                relativePath: "shows/the \"big\" AND loud one.mp4", needsReview: false).insert(db)
        }
        #expect(try names(f, "\"big\" AND") == ["the \"big\" AND loud one.mp4"])
        #expect(try names(f, "big OR nothing").isEmpty)  // OR is text, not an operator
        #expect(try names(f, "loud*").isEmpty)
    }

    @Test func aSearchIsAnIndexLookupNotAScan() throws {
        let f = try FilterFixture()
        let compiled = FilterCompiler.compile(filter: MediaFilter(searchText: "encore"), kinds: .all)
        let plan = try f.library.writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + compiled.sql, arguments: compiled.arguments)
                .map { $0["detail"] as String }.joined(separator: "\n")
        }
        #expect(plan.contains("searchText VIRTUAL TABLE INDEX"))
        #expect(!plan.contains("ocrTextLine"))
    }

    /// A library from before the index: everything already in it is
    /// searchable after the upgrade, recognised text included.
    @Test func anExistingLibraryIsIndexedByTheMigration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-search-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Old.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try LibraryDatabase.migrator.migrate(queue, upTo: "moveJournalRevertsAndSwaps")
        let source = Source(name: "S", rootPath: TestRoots.unreachable("search"))
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "old/before-the-index.mp4",
            notes: "with a note", needsReview: false)
        try queue.write { db in
            try source.insert(db)
            try item.insert(db)
            try db.execute(
                sql: "INSERT INTO ocrTextLine (id, mediaItemID, timeSeconds, text) VALUES (?, ?, 1, 'burned in caption')",
                arguments: [UUID(), item.id])
        }
        try queue.close()

        let library = try LibraryDatabase.open(at: url)
        defer { try? library.close() }
        for query in ["before-the", "a note", "caption"] {
            let found = try library.mediaItems(matching: MediaFilter(searchText: query), kinds: .all)
            #expect(found.map(\.id) == [item.id])
        }
    }
}
