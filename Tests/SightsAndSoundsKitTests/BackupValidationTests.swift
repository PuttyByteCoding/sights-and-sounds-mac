import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// Phase 8b: online backup round-trips, backup verification, and the
/// validation sweep's three finding kinds with their fixes.
@Suite struct BackupValidationTests {

    @Test func backupRoundTripsAndVerifies() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A real on-disk library with content.
        let library = try LibraryDatabase.open(at: dir.appendingPathComponent("Live.sqlite"))
        try library.ensureInfo(name: "Concerts")
        let source = Source(name: "S", rootPath: "/tmp/x")
        let category = TagCategory(name: "Band")
        try await library.writer.write { db in
            try source.insert(db)
            try category.insert(db)
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4").insert(db)
        }

        let backupsDir = dir.appendingPathComponent("Backups")
        let backupURL = try library.backup(into: backupsDir)
        #expect(backupURL.path.contains("Concerts backup"))

        // The backup opens, migrates, and carries the content.
        let info = try LibraryDatabase.verifyBackup(at: backupURL)
        #expect(info?.name == "Concerts")
        let restored = try LibraryDatabase.open(at: backupURL)
        #expect(try await restored.writer.read { try MediaItem.fetchCount($0) } == 1)
        #expect(try await restored.writer.read { try TagCategory.fetchCount($0) } == 1)
        try restored.close()

        // The live library kept working through it all.
        try await library.writer.write { db in
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4").insert(db)
        }
        #expect(try await library.writer.read { try MediaItem.fetchCount($0) } == 2)
        // …and the backup is unaffected by later writes.
        let again = try LibraryDatabase.open(at: backupURL)
        #expect(try await again.writer.read { try MediaItem.fetchCount($0) } == 1)
        try again.close()
        try library.close()
    }

    /// SQLite reads a `-wal` file it finds beside a database as that
    /// database's pending writes. Left next to a restored file, the old
    /// library's WAL belongs to a different database — a documented way
    /// to corrupt one.
    @Test func restoreArchivesTheOldFileWithItsSidecarsAndLeavesNoneBehind() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let libraryURL = dir.appendingPathComponent("Library.sqlite")
        let archiveDir = dir.appendingPathComponent("Backups/Library", isDirectory: true)

        // The backup holds one item; the live library moves on to two.
        let library = try LibraryDatabase.open(at: libraryURL)
        try library.ensureInfo(name: "Library")
        let source = Source(name: "S", rootPath: "/tmp/sas-restore-media")
        try await library.writer.write { db in
            try source.insert(db)
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4").insert(db)
        }
        let backupURL = try library.backup(into: dir.appendingPathComponent("Backups"))
        try await library.writer.write { db in
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4").insert(db)
        }
        try library.close()
        // What a close that failed to checkpoint leaves behind.
        try Data("stale wal".utf8).write(to: URL(fileURLWithPath: libraryURL.path + "-wal"))
        try Data("stale shm".utf8).write(to: URL(fileURLWithPath: libraryURL.path + "-shm"))

        let archived = try LibraryDatabase.restore(
            backup: backupURL, over: libraryURL, archivingInto: archiveDir)

        let archivedURL = try #require(archived)
        #expect(FileManager.default.fileExists(atPath: archivedURL.path))
        #expect(FileManager.default.fileExists(atPath: archivedURL.path + "-wal"))
        #expect(FileManager.default.fileExists(atPath: archivedURL.path + "-shm"))
        #expect(!FileManager.default.fileExists(atPath: libraryURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: libraryURL.path + "-shm"))

        let restored = try LibraryDatabase.open(at: libraryURL)
        #expect(try await restored.writer.read { try MediaItem.fetchCount($0) } == 1)
        try restored.close()
    }

    @Test func restoreRefusesABackupThatIsNotALibraryAndTouchesNothing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-restore-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let libraryURL = dir.appendingPathComponent("Library.sqlite")
        let library = try LibraryDatabase.open(at: libraryURL)
        try library.ensureInfo(name: "Library")
        try library.close()
        let junk = dir.appendingPathComponent("junk.sqlite")
        try Data("not a database".utf8).write(to: junk)

        #expect(throws: (any Error).self) {
            try LibraryDatabase.restore(
                backup: junk, over: libraryURL, archivingInto: dir.appendingPathComponent("Archive"))
        }
        let untouched = try LibraryDatabase.open(at: libraryURL)
        #expect(try untouched.info()?.name == "Library")
        try untouched.close()
    }

    /// `backup(into:)` files each library's backups under a folder named
    /// for it. The listing looked only at the top level, so it never saw
    /// a backup the app itself had made and "last backup" stayed empty.
    @Test func theListingFindsTheBackupsTheAppMakes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-backup-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = try LibraryDatabase.open(at: dir.appendingPathComponent("Concerts.sqlite"))
        try library.ensureInfo(name: "Concerts")
        let backupsDir = dir.appendingPathComponent("Backups", isDirectory: true)
        let made = try library.backup(into: backupsDir)
        try library.close()

        let listed = LibraryDatabase.backups(in: backupsDir)

        #expect(listed.map(\.url.lastPathComponent) == [made.lastPathComponent])
        #expect(listed.first?.libraryName == "Concerts")
    }

    /// Looking at a backup must not change it. Opening one through the
    /// ordinary path ran every newer migration on it and left -wal/-shm
    /// files beside it — so showing the list upgraded every old backup
    /// in place, and one bad migration would have reached them all.
    @Test func lookingAtABackupNeverMigratesOrWritesBesideIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-backup-readonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A backup from an older build: stopped two migrations short.
        let url = dir.appendingPathComponent("Old backup.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try LibraryDatabase.migrator.migrate(queue, upTo: "fingerprintUnsignedRetry")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO libraryInfo (id, libraryID, name, createdAt) VALUES (1, ?, 'Old', ?)",
                arguments: [UUID(), Date()])
        }
        let before = try queue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        try queue.close()

        #expect(try LibraryDatabase.verifyBackup(at: url)?.name == "Old")
        #expect(LibraryDatabase.backups(in: dir).first?.libraryName == "Old")

        let reopened = try DatabaseQueue(path: url.path)
        let after = try reopened.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        try reopened.close()
        #expect(after == before)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    @Test func verifyRefusesGarbage() throws {
        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-junk-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: junk) }
        try Data("not a database".utf8).write(to: junk)
        #expect(throws: (any Error).self) {
            try LibraryDatabase.verifyBackup(at: junk)
        }
    }

    @Test func validationFindsAllThreeKindsAndFixesWork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-validate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("shows"), withIntermediateDirectories: true)

        // healthy: row + file agree. ghost: row, no file. orphan: file, no
        // row. shrunk: row + file disagree on size.
        try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("shows/healthy.mp4"))
        try Data(repeating: 2, count: 50).write(to: root.appendingPathComponent("shows/orphan.mp4"))
        try Data(repeating: 3, count: 10).write(to: root.appendingPathComponent("shows/shrunk.mp4"))

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "V")
        let source = Source(name: "S", rootPath: root.path)
        let healthy = MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/healthy.mp4", fileSize: 100)
        let ghost = MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/ghost.mp4", fileSize: 5)
        let shrunk = MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/shrunk.mp4", fileSize: 999)
        try await library.writer.write { db in
            try source.insert(db)
            for item in [healthy, ghost, shrunk] { try item.insert(db) }
        }

        let runner = JobRunner(library: library)
        await runner.register(ValidationJob.self)
        _ = try await runner.enqueue(ValidationJob.self)
        try await runner.runPending()

        let findings = try library.validationFindings()
        #expect(findings.count == 3)
        #expect(findings.first { $0.kind == .missingFile }?.path == "shows/ghost.mp4")
        #expect(findings.first { $0.kind == .orphanFile }?.path == "shows/orphan.mp4")
        #expect(findings.first { $0.kind == .sizeMismatch }?.path == "shows/shrunk.mp4")

        // Fix the mismatch: disk wins, hash clears, finding leaves.
        try library.acceptDiskSize(for: shrunk.id)
        let fixed = try await library.writer.read { try MediaItem.fetchOne($0, key: shrunk.id)! }
        #expect(fixed.fileSize == 10)
        #expect(fixed.contentHash == nil)
        #expect(try library.validationFindings().count == 2)

        // A rerun replaces findings (mismatch stays gone; the others remain).
        _ = try await runner.enqueue(ValidationJob.self)
        try await runner.runPending()
        let rerun = try library.validationFindings()
        #expect(rerun.count == 2)
        #expect(!rerun.contains { $0.kind == .sizeMismatch })
    }

    @Test func offlineSourcesAreSkippedWhole() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "V")
        let gone = Source(name: "Gone", rootPath: "/Volumes/Nope-\(UUID())")
        try await library.writer.write { db in
            try gone.insert(db)
            try MediaItem(sourceID: gone.id, kind: .video, relativePath: "x.mp4").insert(db)
        }
        let runner = JobRunner(library: library)
        await runner.register(ValidationJob.self)
        let record = try await runner.enqueue(ValidationJob.self)
        try await runner.runPending()

        // Absence of a drive is not absence of files: zero findings.
        #expect(try library.validationFindings().isEmpty)
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: record.id)! }
        #expect(row.summary?.contains("1 offline sources skipped") == true)
    }
}
