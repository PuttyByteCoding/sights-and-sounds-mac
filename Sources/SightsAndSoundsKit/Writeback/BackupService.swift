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

    /// Sanity-open a backup file: it must be a readable library whose
    /// migrations apply cleanly. Returns its identity for display.
    public static func verifyBackup(at url: URL) throws -> LibraryInfo? {
        do {
            let library = try LibraryDatabase.open(at: url)
            let info = try library.info()
            try library.close()
            return info
        } catch {
            throw BackupError.backupUnreadable("\(error)")
        }
    }

    /// The backups home: the settings-chosen directory, else Application
    /// Support/SightsAndSounds/Backups.
    public static func defaultBackupDirectory() -> URL {
        if let custom = AppSettingsStore.shared.current.backupDirectory {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SightsAndSounds/Backups", isDirectory: true)
    }
}
