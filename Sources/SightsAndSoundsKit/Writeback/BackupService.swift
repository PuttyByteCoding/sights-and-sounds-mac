import Foundation
import GRDB

public enum BackupError: Error, CustomStringConvertible {
    case libraryHasNoFile
    case backupUnreadable(String)

    public var description: String {
        switch self {
        case .libraryHasNoFile: "in-memory libraries cannot be backed up"
        case .backupUnreadable(let message): "the backup could not be opened: \(message)"
        }
    }
}

/// Per-library backup: GRDB's online backup writes a consistent copy of
/// the live database — no closing, no WAL sidecar worries, safe while
/// jobs are running. Restore is the app-level swap (close → archive
/// current → copy backup into place); the kit's half verifies a backup
/// actually opens and migrates before anything is swapped.
extension LibraryDatabase {
    /// Copy the live library into `directory` as a dated file. Returns
    /// the backup's URL.
    @discardableResult
    public func backup(into directory: URL) throws -> URL {
        guard fileURL != nil else { throw BackupError.libraryHasNoFile }
        let name = (try? info()?.name) ?? "Library"
        let stamp = Self.collisionStamp()
        let destination = directory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("\(name) backup \(stamp).sqlite")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let target = try DatabaseQueue(path: destination.path)
        try writer.backup(to: target)
        try target.close()
        return destination
    }

    /// Sanity-open a backup file: it must be a database SQLite accepts
    /// and a library (it has the identity and migration tables). Returns
    /// its identity for display.
    ///
    /// Read-only, always. The ordinary `open` migrates, and a backup is
    /// the one file that must stay exactly as it was written: looking at
    /// the list used to bring every old backup up to the current schema
    /// in place, and leave -wal/-shm files beside each. A restored backup
    /// is migrated when the app next opens it as the library, with the
    /// pre-restore archive still there if that goes wrong.
    public static func verifyBackup(at url: URL) throws -> LibraryInfo? {
        do {
            var config = Configuration()
            config.readonly = true
            // `immutable`: a backup is a copy of a WAL-mode database and
            // carries that mode in its header. Read-only is not enough for
            // such a file — SQLite still wants to create the -shm beside
            // it, and fails where it cannot. Immutable tells it the file
            // will not change under it, so it needs no sidecars at all.
            var components = URLComponents()
            components.scheme = "file"
            components.path = url.path
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            let queue = try DatabaseQueue(
                path: components.string ?? url.path, configuration: config)
            defer { try? queue.close() }
            return try queue.read { db in
                guard try db.tableExists("grdb_migrations"), try db.tableExists("libraryInfo") else {
                    throw BackupError.backupUnreadable("not a library file")
                }
                guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" else {
                    throw BackupError.backupUnreadable("the file is damaged")
                }
                // Only the columns every schema version has: a newer
                // column the backup predates must not make it unreadable.
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT libraryID, name, createdAt FROM libraryInfo LIMIT 1")
                else { return nil }
                return LibraryInfo(
                    libraryID: row["libraryID"], name: row["name"], createdAt: row["createdAt"])
            }
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.backupUnreadable("\(error)")
        }
    }

    /// SQLite's sidecar files for a database at `url`.
    static func sidecars(of url: URL) -> [URL] {
        ["-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
    }

    /// Put `backup` in place of the CLOSED library file at `libraryURL`.
    /// The current file is moved into `archiveDirectory` first (never
    /// deleted) and its URL returned; nil when there was no current file.
    ///
    /// The sidecars travel with the file they belong to. A `-wal` left
    /// beside the restored file would be read by SQLite as the restored
    /// database's pending writes, though it belongs to the old one —
    /// which is how a database gets corrupted by a restore. The backup is
    /// verified before anything moves, so a bad backup changes nothing.
    @discardableResult
    public static func restore(
        backup: URL, over libraryURL: URL, archivingInto archiveDirectory: URL
    ) throws -> URL? {
        _ = try verifyBackup(at: backup)
        let files = FileManager.default
        var archived: URL?
        if files.fileExists(atPath: libraryURL.path) {
            try files.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
            let name = libraryURL.deletingPathExtension().lastPathComponent
            let archive = archiveDirectory.appendingPathComponent(
                "\(name) pre-restore \(collisionStamp())-\(UUID().uuidString.prefix(8)).sqlite")
            try files.moveItem(at: libraryURL, to: archive)
            archived = archive
            for (sidecar, destination) in zip(sidecars(of: libraryURL), sidecars(of: archive))
            where files.fileExists(atPath: sidecar.path) {
                try files.moveItem(at: sidecar, to: destination)
            }
        } else {
            // No main file, but a stray sidecar would still be adopted.
            for sidecar in sidecars(of: libraryURL) { try? files.removeItem(at: sidecar) }
        }
        try files.copyItem(at: backup, to: libraryURL)
        return archived
    }

    /// The backups home: the settings-chosen directory, else Application
    /// Support/SightsAndSounds/Backups.
    /// One backup on disk, as the list shows it.
    public struct BackupFile: Sendable, Equatable, Identifiable {
        public var url: URL
        public var createdAt: Date
        public var bytes: Int64
        /// Read from the backup itself — a file whose name says
        /// "Concerts" but whose contents say otherwise is worth
        /// catching before a restore, not after.
        public var libraryName: String?
        public var itemCount: Int?

        public var id: URL { url }
    }

    /// What is in the backup directory, newest first.
    ///
    /// `backup(into:)` writes dated files and `verifyBackup` opens one,
    /// but nothing enumerated them for display — so the list existed
    /// only in the Finder.
    public static func backups(in directory: URL) -> [BackupFile] {
        // `backup(into:)` files each library's backups in a folder named
        // for it, so the list is the directory and one level below.
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .isDirectoryKey]
        let top = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        let contents = top.flatMap { url -> [URL] in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return [url] }
            return (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys)) ?? []
        }
        return contents
            .filter { $0.pathExtension.lowercased() == "sqlite" }
            .map { url in
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .creationDateKey])
                var file = BackupFile(
                    url: url,
                    createdAt: values?.creationDate ?? Date.distantPast,
                    bytes: Int64(values?.fileSize ?? 0))
                // Opening each backup to count items would be slow and
                // pointless for a list; the identity read is cheap and
                // is the part worth verifying.
                if let info = try? verifyBackup(at: url) {
                    file.libraryName = info.name
                }
                return file
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public static func defaultBackupDirectory() -> URL {
        if let custom = AppSettingsStore.shared.current.backupDirectory {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if AppSettingsStore.isUnderTest {
            return AppSettingsStore.testScratch.appendingPathComponent("Backups", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SightsAndSounds/Backups", isDirectory: true)
    }
}
