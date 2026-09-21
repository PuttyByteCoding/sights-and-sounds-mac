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
    /// Set when this move is a REVERT of that log row: finishing it marks
    /// the row reverted instead of logging a second move.
    public var revertsLogID: UUID?
    /// Set when this is a file SWAP (Remux, Repair): the original at
    /// `fromPath` goes to this archive path and a new file lands at
    /// `toPath`. Between those two steps the item has no file at all.
    public var archivePath: String?

    public init(
        id: UUID = UUID(), mediaItemID: UUID, sourceID: UUID, fileName: String,
        fromPath: String, toPath: String, sessionID: UUID?, startedAt: Date = Date(),
        revertsLogID: UUID? = nil, archivePath: String? = nil
    ) {
        self.revertsLogID = revertsLogID
        self.archivePath = archivePath
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
        /// A swap had archived the original and never landed its
        /// replacement: the original was moved back to where its row says.
        public var restored = 0
    }

    /// Settle the moves the app was in the middle of when it last
    /// stopped. Where the file is decides which way each one goes. For a
    /// move or a revert the disk is never touched, only the database
    /// brought into line with it. A swap stopped halfway is the exception:
    /// its item has no file where the row says, so the archived original
    /// is moved back.
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
            if let archivePath = move.archivePath {
                try settleSwap(move, archivePath: archivePath, root: root, fileAccess: fileAccess, &outcome)
                continue
            }
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
    static func finish(_ move: PendingMove, _ db: Database) throws -> FileMoveLog? {
        if let revertedLogID = move.revertsLogID {
            // A revert marks the move it undoes; it is not a second move.
            try db.execute(
                sql: "UPDATE fileMoveLog SET revertedAt = ? WHERE id = ?",
                arguments: [Date(), revertedLogID])
            if var item = try MediaItem.fetchOne(db, key: move.mediaItemID) {
                item.setRelativePath(move.toPath)
                try item.updateWithSegmentPaths(db)
            }
            _ = try PendingMove.deleteOne(db, key: move.id)
            return nil
        }
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

    /// A swap, by where its two files are. The archive is the witness:
    /// it exists only once the original has left its place.
    private func settleSwap(
        _ move: PendingMove, archivePath: String, root: URL,
        fileAccess: any FileAccess, _ outcome: inout ReconcileOutcome
    ) throws {
        let archiveURL = root.appendingPathComponent(archivePath)
        let originalURL = root.appendingPathComponent(move.fromPath)
        let landedURL = root.appendingPathComponent(move.toPath)

        guard fileAccess.isReachable(archiveURL) else {
            // Never archived, or already rolled back: nothing happened.
            try writer.write { db in _ = try PendingMove.deleteOne(db, key: move.id) }
            outcome.forgotten += 1
            return
        }
        if fileAccess.isReachable(landedURL) {
            // Archived and landed: only the row was left behind.
            let size = (try? fileAccess.fileSize(at: landedURL)) ?? 0
            try writer.write { db in
                if var item = try MediaItem.fetchOne(db, key: move.mediaItemID) {
                    item.setRelativePath(move.toPath)
                    item.fileSize = size
                    // The bytes are new; the stored hash is the old file's.
                    item.contentHash = nil
                    try item.updateWithSegmentPaths(db)
                }
                _ = try PendingMove.deleteOne(db, key: move.id)
            }
            AppLog.shared.warning("moves", "finished an interrupted file swap at \(move.toPath)")
            outcome.finished += 1
            return
        }
        // Archived, nothing landed: the item has no file. Put it back.
        do {
            try fileAccess.moveFile(at: archiveURL, to: originalURL)
            try writer.write { db in _ = try PendingMove.deleteOne(db, key: move.id) }
            AppLog.shared.warning(
                "moves", "an interrupted file swap was undone: \(move.fromPath) is back from the archive")
            outcome.restored += 1
        } catch {
            AppLog.shared.error(
                "moves", "\(move.fileName) is in the archive at \(archivePath) and could not be moved back: \(error)")
            outcome.undecided += 1
        }
    }

    /// What a journaled swap hands back: where the original went, and
    /// the intent for the caller to clear in the same transaction that
    /// records the new file.
    struct JournaledSwap: Sendable {
        let archiveRelative: String
        let intentID: UUID

        func clear(_ db: Database) throws {
            _ = try PendingMove.deleteOne(db, key: intentID)
        }
    }

    /// `replaceFile`, written down first. If the swap fails and rolled
    /// itself back, or never started, the intent goes at once; if it left
    /// the original in the archive, the intent stays so the next launch
    /// can put it back.
    func journaledReplace(
        item: MediaItem, under root: URL, newRelative: String,
        with replacement: URL, fileAccess: any FileAccess
    ) throws -> JournaledSwap {
        let archiveRelative = Self.archivePath(
            for: item.relativePath, under: root, fileAccess: fileAccess)
        let intent = PendingMove(
            mediaItemID: item.id, sourceID: item.sourceID, fileName: item.fileName,
            fromPath: item.relativePath, toPath: newRelative, sessionID: nil,
            archivePath: archiveRelative)
        try writer.write { try intent.insert($0) }
        do {
            try Self.replaceFile(
                under: root, currentRelative: item.relativePath, newRelative: newRelative,
                with: replacement, archiveRelative: archiveRelative, fileAccess: fileAccess)
        } catch FileReplacementError.originalLeftInArchive(let archive, let reason) {
            throw FileReplacementError.originalLeftInArchive(archive: archive, reason: reason)
        } catch {
            _ = try? writer.write { try PendingMove.deleteOne($0, key: intent.id) }
            throw error
        }
        return JournaledSwap(archiveRelative: archiveRelative, intentID: intent.id)
    }
}
