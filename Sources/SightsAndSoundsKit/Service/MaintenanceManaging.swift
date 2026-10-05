import Foundation
import GRDB

/// The Maintenance window: what validation found, the backups, the
/// recent tag writes, and what is staged for deletion; and the few
/// things it does itself.
public protocol MaintenanceManaging: Sendable {
    /// Everything the window shows, as one answer. The list of backups
    /// opens every backup file, so it is only made when asked for.
    func maintenanceSnapshot(includingBackups: Bool) async throws -> MaintenanceSnapshot

    /// The file's size has changed and is right: record it.
    func acceptDiskSize(itemID: UUID) async throws

    /// What writing the library's tags into files would change, without
    /// writing anything. These items, or with nil every item that is a
    /// file of its own. It reads each file's current tags, so it takes
    /// as long as the files are many.
    func previewWriteback(itemIDs: [UUID]?) async throws -> WritebackPreview

    /// Copy the library to a dated file in the backup folder of the Mac
    /// that holds it. Returns where the backup is — on that Mac: from
    /// another, only its name means anything.
    func backUp() async throws -> URL
}

public struct MaintenanceSnapshot: Codable, Equatable, Sendable {
    public var findings: [ValidationFinding]
    /// Newest first; nil when the list was not asked for.
    public var backups: [LibraryDatabase.BackupFile]?
    /// The latest few tag writes, newest first.
    public var runs: [TagWriteRun]
    public var stagedCount: Int
    public var reclaimableBytes: Int64

    public init(
        findings: [ValidationFinding], backups: [LibraryDatabase.BackupFile]?, runs: [TagWriteRun],
        stagedCount: Int, reclaimableBytes: Int64
    ) {
        self.findings = findings
        self.backups = backups
        self.runs = runs
        self.stagedCount = stagedCount
        self.reclaimableBytes = reclaimableBytes
    }
}

// MARK: - On this Mac

extension LocalLibraryService {
    public func maintenanceSnapshot(includingBackups: Bool) async throws -> MaintenanceSnapshot {
        // Each part that cannot be read is shown as nothing rather than
        // taking the others with it: this runs after every button press.
        let findings = (try? library.validationFindings()) ?? []
        let backups = includingBackups
            ? LibraryDatabase.backups(in: LibraryDatabase.defaultBackupDirectory()) : nil
        let runs = (try? await library.writer.read { db in
            try TagWriteRun.order(sql: "startedAt DESC").limit(6).fetchAll(db)
        }) ?? []
        let staged = (try? await library.writer.read { db in
            try MediaItem.filter(sql: "markedForDeletion = 1").fetchCount(db)
        }) ?? 0
        return MaintenanceSnapshot(
            findings: findings, backups: backups, runs: runs, stagedCount: staged,
            reclaimableBytes: (try? library.reclaimableBytes()) ?? 0)
    }

    public func acceptDiskSize(itemID: UUID) async throws {
        try library.acceptDiskSize(for: itemID, fileAccess: fileAccess)
    }

    public func previewWriteback(itemIDs: [UUID]?) async throws -> WritebackPreview {
        let ids: [UUID]
        if let itemIDs {
            ids = itemIDs
        } else {
            ids = try await library.writer.read { db in
                try UUID.fetchAll(db, sql: "SELECT id FROM mediaItem WHERE parentMediaItemID IS NULL")
            }
        }
        return try library.previewWriteback(itemIDs: ids, fileAccess: fileAccess)
    }

    public func backUp() async throws -> URL {
        try await library.backUp(into: LibraryDatabase.defaultBackupDirectory())
    }
}
