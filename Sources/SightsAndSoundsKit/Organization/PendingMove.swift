import Foundation
import GRDB

/// A move that has been decided and not yet finished: written before the
/// file is touched, removed in the same transaction that records the
/// move. A row that survives a launch is a move the app was in the middle
/// of when it stopped.
public struct PendingMove: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pendingMove"

    public var id: UUID
    public var mediaItemID: UUID
    public var sourceID: UUID
    public var fileName: String
    public var fromPath: String
    public var toPath: String
    public var sessionID: UUID?
    public var startedAt: Date

    public init(
        id: UUID = UUID(), mediaItemID: UUID, sourceID: UUID, fileName: String,
        fromPath: String, toPath: String, sessionID: UUID?, startedAt: Date = Date()
    ) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.sourceID = sourceID
        self.fileName = fileName
        self.fromPath = fromPath
        self.toPath = toPath
        self.sessionID = sessionID
        self.startedAt = startedAt
    }
}

extension LibraryDatabase {
    public struct ReconcileOutcome: Sendable, Equatable {
        /// The file had moved: the row followed it and the move is logged.
        public var finished = 0
        /// The file had not moved: the intent was dropped.
        public var forgotten = 0
        /// Neither place, both places, or the source is offline: left
        /// pending for a later launch to decide.
        public var undecided = 0
    }

    /// Settle the moves the app was in the middle of when it last
    /// stopped. Where the file is decides which way each one goes; the
    /// disk is never touched here, only the database brought into line
    /// with it.
    @discardableResult
    public func reconcileInterruptedMoves(
        fileAccess: any FileAccess = LiveFileAccess()
    ) throws -> ReconcileOutcome {
        let pending = try writer.read { try PendingMove.order(sql: "startedAt").fetchAll($0) }
        guard !pending.isEmpty else { return ReconcileOutcome() }
        let sources = try writer.read { db in
            Dictionary(uniqueKeysWithValues: try Source.fetchAll(db).map { ($0.id, $0) })
        }

        var outcome = ReconcileOutcome()
        for move in pending {
            guard let source = sources[move.sourceID], source.enabled,
                  source.isOnline(using: fileAccess)
            else {
                outcome.undecided += 1
                continue
            }
            let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
            let atOld = fileAccess.isReachable(root.appendingPathComponent(move.fromPath))
            let atNew = fileAccess.isReachable(root.appendingPathComponent(move.toPath))
            // A rename that only changes case is one file under both names
            // on a case-insensitive volume: it reads as "both", and it moved.
            let caseOnly = move.fromPath.caseInsensitiveCompare(move.toPath) == .orderedSame

            if atNew && (!atOld || caseOnly) {
                _ = try writer.write { db in try Self.finish(move, db) }
                AppLog.shared.warning(
                    "moves", "finished an interrupted move: \(move.fromPath) → \(move.toPath)")
                outcome.finished += 1
            } else if atOld && !atNew {
                try writer.write { db in _ = try PendingMove.deleteOne(db, key: move.id) }
                AppLog.shared.warning(
                    "moves", "an interrupted move never reached the disk: \(move.fromPath)")
                outcome.forgotten += 1
            } else {
                AppLog.shared.error(
                    "moves",
                    "cannot settle an interrupted move of \(move.fileName): "
                        + (atOld ? "a file is at both paths" : "no file is at either path"))
                outcome.undecided += 1
            }
        }
        return outcome
    }

    /// What a completed move writes, in one transaction: the item (and
    /// its segments) at the new path, the log row, the intent gone.
    @discardableResult
    static func finish(_ move: PendingMove, _ db: Database) throws -> FileMoveLog {
        let log = FileMoveLog(
            mediaItemID: move.mediaItemID, sourceID: move.sourceID,
            fileName: move.fileName, fromPath: move.fromPath, toPath: move.toPath,
            sessionID: move.sessionID)
        if var item = try MediaItem.fetchOne(db, key: move.mediaItemID) {
            item.setRelativePath(move.toPath)
            try item.updateWithSegmentPaths(db)
        }
        try log.insert(db)
        _ = try PendingMove.deleteOne(db, key: move.id)
        return log
    }
}
