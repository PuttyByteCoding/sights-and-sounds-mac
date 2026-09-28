import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// Listing backups reads each one's identity; the full integrity check
/// belongs to Restore. The list used to run `PRAGMA quick_check` —
/// a read of the whole file — for every backup on every reload, so ten
/// backups of a large library meant gigabytes read to draw a list.
@Suite struct BackupListIdentityTests {
    /// A backup whose identity table is intact and whose bulk is not.
    private func damagedBackup() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-backup-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = try LibraryDatabase.open(at: directory.appendingPathComponent("live.sqlite"))
        try library.ensureInfo(name: "Listed Library")
        let source = Source(name: "S", rootPath: "/tmp/sas-backup-list-source")
        try library.writer.write { db in
            try source.insert(db)
            for n in 0..<4_000 {
                try MediaItem(sourceID: source.id, kind: .video,
                              relativePath: "bulk/\(n)/a-long-enough-name-to-fill-pages-\(n).mp4",
                              needsReview: false).insert(db)
            }
        }
        // Where the damage goes: the root page of the items table. A
        // backup keeps page numbers, so that page is live in the copy
        // too. (Scribbling "near the end" hit unused pages on CI's build,
        // and the check passed.) libraryInfo lives on another page, so
        // the identity read still works.
        let (rootPage, pageSize) = try library.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT rootpage FROM sqlite_master WHERE name = 'mediaItem'") ?? 0,
             try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096)
        }
        try #require(rootPage > 1)
        let backup = try library.backup(into: directory.appendingPathComponent("Backups"))
        try library.close()
        let handle = try FileHandle(forUpdating: backup)
        try handle.seek(toOffset: UInt64((rootPage - 1) * pageSize))
        try handle.write(contentsOf: Data(repeating: 0xA5, count: pageSize))
        try handle.close()
        return (directory, backup)
    }

    @Test func theListNamesABackupWithoutCheckingItsWholeFile() throws {
        let (directory, backup) = try damagedBackup()
        defer { try? FileManager.default.removeItem(at: directory) }

        let listed = LibraryDatabase.backups(in: directory.appendingPathComponent("Backups"))

        #expect(listed.first { $0.url.lastPathComponent == backup.lastPathComponent }?.libraryName == "Listed Library")
    }

    @Test func restoreStillRefusesADamagedBackup() throws {
        let (directory, backup) = try damagedBackup()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: BackupError.self) { try LibraryDatabase.verifyBackup(at: backup) }
    }
}
