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
    /// What each of `runs` can be put back from, and how far it has been.
    /// Nil from a library whose Mac predates the question.
    public var runReverts: [TagWriteRunRevert]?

    public init(
        findings: [ValidationFinding], backups: [LibraryDatabase.BackupFile]?, runs: [TagWriteRun],
        stagedCount: Int, reclaimableBytes: Int64, runReverts: [TagWriteRunRevert]? = nil
    ) {
        self.findings = findings
        self.backups = backups
        self.runs = runs
        self.stagedCount = stagedCount
        self.reclaimableBytes = reclaimableBytes
        self.runReverts = runReverts
    }
}

/// A write-back run is the unit of undo: what it can be put back from,
/// and whether it has been.
///
/// Every file a run writes gets a `.preWrite` snapshot first, and that
/// snapshot is what `RestoreTagsJob` writes back. Nothing links a snapshot
/// to its run, so the run's are found by time: the newest pre-write
/// snapshot of each written file taken while the run was running. A file
/// counts as restored once a `.preRestore` snapshot — which only a restore
/// takes — exists for it from after the run began.
public struct TagWriteRunRevert: Codable, Equatable, Sendable, Identifiable {
    public var runID: UUID
    /// One per file the run wrote and still has a snapshot for; what
    /// "Restore embedded tags" queues.
    public var snapshotIDs: [UUID]
    /// Files of the run restored since it ran.
    public var restoredCount: Int

    public var id: UUID { runID }

    public init(runID: UUID, snapshotIDs: [UUID], restoredCount: Int) {
        self.runID = runID
        self.snapshotIDs = snapshotIDs
        self.restoredCount = restoredCount
    }

    /// A half-undone run must never be mistaken for a clean one.
    public enum State: String, Sendable {
        case applied, partlyReverted, reverted

        public var displayName: String {
            switch self {
            case .applied: "applied"
            case .partlyReverted: "partly reverted"
            case .reverted: "reverted"
            }
        }
    }

    public var state: State {
        if restoredCount == 0 { return .applied }
        return restoredCount >= snapshotIDs.count ? .reverted : .partlyReverted
    }
}

extension TagWriteRunRevert {
    /// For each run, its files' pre-write snapshots and how many have been
    /// restored since. One read; the runs are the window's latest few.
    static func of(_ runs: [TagWriteRun], in db: Database) throws -> [TagWriteRunRevert] {
        try runs.map { run in
            let written = try TagWriteRunFile
                .filter(Column("tagWriteRunID") == run.id && Column("status") == WriteRunFileStatus.written.rawValue)
                .fetchAll(db)
                .map(\.mediaItemID)
            let snapshots = try EmbeddedTagSnapshot
                .filter(written.contains(Column("mediaItemID")))
                .order(Column("capturedAt").desc)
                .fetchAll(db)
            // A run that never finished is still "running" for this.
            let end = run.finishedAt ?? .distantFuture
            var snapshotIDs: [UUID] = []
            var restored = 0
            for itemID in written {
                let mine = snapshots.filter { $0.mediaItemID == itemID }
                if let pre = mine.first(where: {
                    $0.source == .preWrite && $0.capturedAt >= run.startedAt && $0.capturedAt <= end
                }) {
                    snapshotIDs.append(pre.id)
                }
                if mine.contains(where: { $0.source == .preRestore && $0.capturedAt > run.startedAt }) {
                    restored += 1
                }
            }
            return TagWriteRunRevert(runID: run.id, snapshotIDs: snapshotIDs, restoredCount: restored)
        }
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
        let runs = (try? await library.read { db in
            try TagWriteRun.order(sql: "startedAt DESC").limit(6).fetchAll(db)
        }) ?? []
        let staged = (try? await library.read { db in
            try MediaItem.filter(sql: "markedForDeletion = 1").fetchCount(db)
        }) ?? 0
        // What each run can be put back from. Read like the rest: a part
        // that cannot be read is shown as nothing, not as a failure.
        let reverts = (try? await library.read { db in try TagWriteRunRevert.of(runs, in: db) }) ?? []
        return MaintenanceSnapshot(
            findings: findings, backups: backups, runs: runs, stagedCount: staged,
            reclaimableBytes: (try? library.reclaimableBytes()) ?? 0, runReverts: reverts)
    }

    public func acceptDiskSize(itemID: UUID) async throws {
        try library.acceptDiskSize(for: itemID, fileAccess: fileAccess)
    }

    public func previewWriteback(itemIDs: [UUID]?) async throws -> WritebackPreview {
        let ids: [UUID]
        if let itemIDs {
            ids = itemIDs
        } else {
            ids = try await library.read { db in
                try UUID.fetchAll(db, sql: "SELECT id FROM mediaItem WHERE parentMediaItemID IS NULL")
            }
        }
        return try library.previewWriteback(itemIDs: ids, fileAccess: fileAccess)
    }

    public func backUp() async throws -> URL {
        try await library.backUp(into: LibraryDatabase.defaultBackupDirectory())
    }
}
