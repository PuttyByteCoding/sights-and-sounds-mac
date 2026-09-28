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
        let backup = try library.backup(into: directory.appendingPathComponent("Backups"))
        try library.close()
        // Scribble over a page near the end: mediaItem rows, not libraryInfo.
        let handle = try FileHandle(forUpdating: backup)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size - 3 * 4096)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 4096))
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
