import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// Phase 1 schema behavior: sources, integrity constraints, sortable field
/// values, feature-state tables, identity, and the upgrade path from a
/// phase0 database.
@Suite struct Phase1SchemaTests {

    // MARK: Migration chain

    @Test func freshLibraryAppliesBothMigrations() throws {
        let library = try LibraryDatabase.openInMemory()
        #expect(try library.appliedMigrations() == ["phase0", "phase1", "phase2", "phase4", "phase5", "phase6", "phase7", "phase7b", "phase7c", "phase7d", "phase8", "phase8b"])
    }

    @Test func phase0DatabaseUpgradesToPhase1() throws {
        // Build a database stopped at phase0 (as an on-disk library from the
        // Phase 0 PR would be), then reopen through the full migrator.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Old.sqlite")

        let queue = try DatabaseQueue(path: url.path)
        try LibraryDatabase.migrator.migrate(queue, upTo: "phase0")
        try queue.close()

        let upgraded = try LibraryDatabase.open(at: url)
        #expect(try upgraded.appliedMigrations() == ["phase0", "phase1", "phase2", "phase4", "phase5", "phase6", "phase7", "phase7b", "phase7c", "phase7d", "phase8", "phase8b"])
        // Phase 1 tables exist and are usable.
        try upgraded.writer.write { db in
            try Source(name: "S", rootPath: "/tmp/media").insert(db)
        }
    }

    // MARK: Identity

    @Test func libraryIdentityIsStampedOnceAndSingleRow() throws {
        let library = try LibraryDatabase.openInMemory()
        #expect(try library.info() == nil)

        let first = try library.ensureInfo(name: "Concerts")
        let second = try library.ensureInfo(name: "Renamed")
        #expect(second == first)
        #expect(try library.info()?.name == "Concerts")

        // The CHECK pins the table to one row.
        #expect(throws: (any Error).self) {
            try library.writer.write { db in
                var rogue = LibraryInfo(name: "Second")
                rogue.id = 2
                try rogue.insert(db)
            }
        }
    }

    // MARK: Sources

    @Test func disabledSourceLeavesEveryListing() throws {
        let f = try FilterFixture()
        let extra = Source(name: "External", rootPath: "/Volumes/Ext", kind: .externalDrive)
        let extraItem = MediaItem(sourceID: extra.id, kind: .video, relativePath: "more/z.mp4", needsReview: false)
        try f.library.writer.write { db in
            try extra.insert(db)
            try extraItem.insert(db)
        }
        #expect(try f.names(MediaFilter()).contains("z.mp4"))

        try f.library.writer.write { db in
            var off = extra
            off.enabled = false
            try off.update(db)
        }
        #expect(try !f.names(MediaFilter()).contains("z.mp4"))
        // The main source's items are untouched — per-source, not global.
        #expect(try f.names(MediaFilter()).contains("a.mp4"))
    }

    @Test func deletingSourceWithItemsIsRefused() throws {
        let f = try FilterFixture()
        #expect(throws: (any Error).self) {
            try f.library.writer.write { db in
                _ = try f.mainSource.delete(db)
            }
        }
    }

    @Test func duplicatePathWithinSourceIsRefused() throws {
        let f = try FilterFixture()
        let dupe = MediaItem(sourceID: f.mainSource.id, kind: .video, relativePath: "SHOWS/1995/A.MP4")
        #expect(throws: (any Error).self) {
            try f.library.writer.write { try dupe.insert($0) }
        }
    }

    @Test func onlineIsObservedNotStored() throws {
        struct FakeAccess: FileAccess {
            let reachable: Bool
            func isReachable(_ url: URL) -> Bool { reachable }
            func contentsOfDirectory(at url: URL) throws -> [URL] { [] }
            func allFiles(under url: URL) throws -> [URL] { [] }
            func fileSize(at url: URL) throws -> Int64 { 0 }
            func readFile(at url: URL, chunk: (Data) throws -> Void) throws {}
            func moveFile(at url: URL, to destination: URL) throws {}
            func removeFile(at url: URL) throws {}
        }
        let source = Source(name: "Ext", rootPath: "/Volumes/Gone")
        #expect(source.isOnline(using: FakeAccess(reachable: true)))
        #expect(!source.isOnline(using: FakeAccess(reachable: false)))
    }

    // MARK: Vocabulary integrity

    @Test func tagNamesUniquePerCategoryCaseInsensitive() throws {
        let f = try FilterFixture()
        #expect(throws: (any Error).self) {
            try f.library.writer.write { db in
                try Tag(tagCategoryID: f.band.id, name: "band a").insert(db)
            }
        }
        // Same name in another category is fine.
        try f.library.writer.write { db in
            try Tag(tagCategoryID: f.recordingType.id, name: "Band A").insert(db)
        }
    }

    @Test func aliasesRoundTrip() throws {
        let f = try FilterFixture()
        try f.library.writer.write { db in
            try TagAlias(tagID: f.sbd.id, alias: "Soundboard").insert(db)
            try TagAlias(tagID: f.sbd.id, alias: "Board").insert(db)
        }
        let aliases = try f.library.writer.read {
            try TagAlias.filter(sql: "tagID = ?", arguments: [f.sbd.id]).fetchAll($0).map(\.alias)
        }
        #expect(Set(aliases) == ["Soundboard", "Board"])
    }

    @Test func fieldScopeCheckIsEnforced() throws {
        let f = try FilterFixture()
        // mediaItem scope with a category: refused.
        #expect(throws: (any Error).self) {
            try f.library.writer.write { db in
                try FieldDefinition(
                    name: "Bad", scope: .mediaItem, tagCategoryID: f.band.id).insert(db)
            }
        }
        // tag scope without a category: refused.
        #expect(throws: (any Error).self) {
            try f.library.writer.write { db in
                try FieldDefinition(name: "AlsoBad", scope: .tag).insert(db)
            }
        }
    }

    // MARK: Feature state

    @Test func featureStateLivesBesideTheFeature() throws {
        let f = try FilterFixture()
        try f.library.writer.write { db in
            try ContentHashFailure(mediaItemID: f.show1995.id, message: "timed out").insert(db)
            try ThumbnailState(mediaItemID: f.show1995.id, generated: true).insert(db)
            try OcrProgress(mediaItemID: f.show1995.id, scannedThroughSeconds: 42.5).insert(db)
        }
        // Deleting the item sweeps its feature state — no orphan flags.
        try f.library.writer.write { db in
            try db.execute(sql: "DELETE FROM mediaItemTag WHERE mediaItemID = ?", arguments: [f.show1995.id])
            try db.execute(
                sql: "UPDATE mediaItem SET parentMediaItemID = NULL WHERE parentMediaItemID = ?",
                arguments: [f.show1995.id])
            _ = try f.show1995.delete(db)
        }
        let counts = try f.library.writer.read { db in
            try (
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM contentHashFailure")!,
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thumbnailState")!,
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocrProgress")!
            )
        }
        #expect(counts == (0, 0, 0))
    }
}
