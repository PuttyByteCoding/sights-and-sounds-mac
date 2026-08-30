import Foundation
import GRDB

public enum MoveError: Error, CustomStringConvertible {
    case itemNotFound
    case sourceUnavailable
    case moveFailed(String)
    case logNotFound
    case alreadyReverted

    public var description: String {
        switch self {
        case .itemNotFound: "the item no longer exists"
        case .sourceUnavailable: "the item's source is offline or disabled"
        case .moveFailed(let message): "move failed: \(message)"
        case .logNotFound: "no such move-log entry"
        case .alreadyReverted: "this move has already been reverted"
        }
    }
}

/// The staging folders. Named with a leading underscore so they sort
/// apart and read as machinery, exactly as in the old app.
public enum StagingFolder: String, Sendable {
    case toDelete = "_ToDelete"
    case playbackIssue = "_PlaybackIssue"
}

/// File moves with a paper trail — the reversibility backbone of Phase 7.
///
/// Every physical move: goes through the `FileAccess` boundary, never
/// overwrites (collisions get a timestamp suffix), retries transient IO
/// (6 attempts), updates the item's path triplet, and writes a
/// `fileMoveLog` row that stays revertible until reverted.
///
/// Staging (mark-for-deletion / playback-issue) ports the old
/// `MarkAndMoveAsync` semantics:
///   - embedded clips (a `parentMediaItemID`) flag WITHOUT moving — they
///     share the parent's file;
///   - a file already under the staging folder just flags;
///   - a missing file flags anyway (the file is gone; the row's state
///     should still be honest);
///   - the flag flip and the physical move are SEPARATE steps by design —
///     a failed move must never roll back the user's decision. The flag
///     commits first; a move failure is reported on top of it.
extension LibraryDatabase {
    // MARK: - Core move

    /// Move an item's file to a new source-relative path, logging it.
    @discardableResult
    public func moveFile(
        itemID: UUID, to requestedPath: String,
        fileAccess: any FileAccess = LiveFileAccess()
    ) throws -> FileMoveLog {
        guard let item = try writer.read({ try MediaItem.fetchOne($0, key: itemID) }) else {
            throw MoveError.itemNotFound
        }
        guard let source = try writer.read({ try Source.fetchOne($0, key: item.sourceID) }),
              source.enabled, source.isOnline(using: fileAccess)
        else { throw MoveError.sourceUnavailable }

        let fromPath = item.relativePath
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        let fromURL = root.appendingPathComponent(fromPath)

        var toPath = MediaPath.normalize(requestedPath)
        var toURL = root.appendingPathComponent(toPath)
        // Never overwrite: collision → timestamp suffix, old behavior.
        if FileManager.default.fileExists(atPath: toURL.path) {
            let stamp = Self.collisionStamp()
            let ext = (toPath as NSString).pathExtension
            let stem = (toPath as NSString).deletingPathExtension
            toPath = ext.isEmpty ? "\(stem)-\(stamp)" : "\(stem)-\(stamp).\(ext)"
            toURL = root.appendingPathComponent(toPath)
        }

        try Self.moveWithRetries(fileAccess: fileAccess, from: fromURL, to: toURL)

        AppLog.shared.info("moves", "moved \(fromPath) → \(toPath)")
        let log = FileMoveLog(
            mediaItemID: item.id, sourceID: source.id,
            fileName: item.fileName, fromPath: fromPath, toPath: toPath)
        try writer.write { db in
            var updated = item
            updated.setRelativePath(toPath)
            try updated.update(db)
            try log.insert(db)
        }
        return log
    }

    /// Undo a logged move: file back where it was, path restored, entry
    /// marked reverted. One-shot per entry.
    public func revertMove(
        _ logID: UUID, fileAccess: any FileAccess = LiveFileAccess()
    ) throws {
        guard let log = try writer.read({ try FileMoveLog.fetchOne($0, key: logID) }) else {
            throw MoveError.logNotFound
        }
        guard log.revertedAt == nil else { throw MoveError.alreadyReverted }
        guard let source = try writer.read({ try Source.fetchOne($0, key: log.sourceID) }),
              source.enabled, source.isOnline(using: fileAccess)
        else { throw MoveError.sourceUnavailable }

        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        try Self.moveWithRetries(
            fileAccess: fileAccess,
            from: root.appendingPathComponent(log.toPath),
            to: root.appendingPathComponent(log.fromPath))

        AppLog.shared.info("moves", "reverted \(log.toPath) → \(log.fromPath)")
        try writer.write { db in
            try db.execute(
                sql: "UPDATE fileMoveLog SET revertedAt = ? WHERE id = ?",
                arguments: [Date(), logID])
            if var item = try MediaItem.fetchOne(db, key: log.mediaItemID) {
                item.setRelativePath(log.fromPath)
                try item.update(db)
            }
        }
    }

    public func moveLogs(limit: Int = 200) throws -> [FileMoveLog] {
        try writer.read { db in
            try FileMoveLog.order(sql: "movedAt DESC").limit(limit).fetchAll(db)
        }
    }

    // MARK: - Staging

    /// Flag an item and stage its file under the staging folder. The flag
    /// commits before the move is attempted; a move failure throws AFTER
    /// the decision is safe.
    public func stage(
        _ folder: StagingFolder, itemID: UUID,
        fileAccess: any FileAccess = LiveFileAccess()
    ) throws {
        guard let item = try writer.read({ try MediaItem.fetchOne($0, key: itemID) }) else {
            throw MoveError.itemNotFound
        }
        try writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET \(Self.flagColumn(folder)) = 1, needsReview = 0 WHERE id = ?",
                arguments: [itemID])
        }

        // Embedded clips share the parent's file: flag only.
        guard item.parentMediaItemID == nil else { return }
        // Already staged: flag only.
        guard !item.relativePath.lowercased().hasPrefix(folder.rawValue.lowercased() + "/") else { return }
        // Missing file: flag only (probe through the boundary).
        guard let source = try writer.read({ try Source.fetchOne($0, key: item.sourceID) }),
              source.enabled, source.isOnline(using: fileAccess),
              fileAccess.isReachable(
                URL(fileURLWithPath: source.rootPath, isDirectory: true)
                    .appendingPathComponent(item.relativePath))
        else { return }

        _ = try moveFile(
            itemID: itemID, to: "\(folder.rawValue)/\(item.relativePath)",
            fileAccess: fileAccess)
    }

    /// Clear the flag and, when the latest staging move is still
    /// revertible, put the file back.
    public func unstage(
        _ folder: StagingFolder, itemID: UUID,
        fileAccess: any FileAccess = LiveFileAccess()
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET \(Self.flagColumn(folder)) = 0 WHERE id = ?",
                arguments: [itemID])
        }
        let latest = try writer.read { db in
            try FileMoveLog
                .filter(sql: "mediaItemID = ? AND revertedAt IS NULL", arguments: [itemID])
                .order(sql: "movedAt DESC")
                .fetchOne(db)
        }
        if let latest, latest.toPath.lowercased().hasPrefix(folder.rawValue.lowercased() + "/") {
            try revertMove(latest.id, fileAccess: fileAccess)
        }
    }

    private static func flagColumn(_ folder: StagingFolder) -> String {
        switch folder {
        case .toDelete: "markedForDeletion"
        case .playbackIssue: "playbackIssue"
        }
    }

    // MARK: - Purge

    public struct PurgeOutcome: Sendable, Equatable {
        public var rowsDeleted = 0
        public var filesDeleted = 0
        public var fileFailures: [String] = []
    }

    /// The size of everything currently flagged for deletion — the
    /// review list's headline number.
    public func reclaimableBytes() throws -> Int64 {
        try writer.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT COALESCE(SUM(fileSize), 0) FROM mediaItem WHERE markedForDeletion = 1")
                ?? 0
        }
    }

    /// Permanently delete marked-for-deletion items: files first
    /// (through the boundary; offline sources' items are skipped
    /// entirely), then rows — cascades sweep tags, values, feature state
    /// and candidates. The caller owns the confirmation.
    ///
    /// `itemIDs` narrows it to a reviewed subset; nil means everything
    /// flagged. **The flag check stays the guard either way** — a passed
    /// id that is not flagged is not deleted, so a stale list cannot
    /// take a file nobody marked.
    @discardableResult
    public func purgeDeleted(
        itemIDs: [UUID]? = nil, fileAccess: any FileAccess = LiveFileAccess()
    ) throws -> PurgeOutcome {
        let flagged = try writer.read { db -> [MediaItem] in
            guard let itemIDs else {
                return try MediaItem.filter(sql: "markedForDeletion = 1").fetchAll(db)
            }
            guard !itemIDs.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ", ")
            return try MediaItem.fetchAll(
                db,
                sql: "SELECT * FROM mediaItem WHERE markedForDeletion = 1 AND id IN (\(placeholders))",
                arguments: StatementArguments(itemIDs))
        }
        let sources = try writer.read { db in
            Dictionary(uniqueKeysWithValues: try Source.fetchAll(db).map { ($0.id, $0) })
        }

        var outcome = PurgeOutcome()
        for item in flagged {
            guard let source = sources[item.sourceID] else { continue }
            // An offline source's staged files can't be deleted — skip the
            // whole item so file and row leave together, later.
            let online = source.enabled && source.isOnline(using: fileAccess)
            if item.parentMediaItemID == nil {
                guard online else { continue }
                let url = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                    .appendingPathComponent(item.relativePath)
                if fileAccess.isReachable(url) {
                    do {
                        try fileAccess.removeFile(at: url)
                        outcome.filesDeleted += 1
                    } catch {
                        outcome.fileFailures.append("\(item.fileName): \(error)")
                        continue  // keep the row while the file survives
                    }
                }
            }
            // Embedded clip rows are pure metadata — always removable.
            let removed = try writer.write { db -> Bool in
                // Re-point children (their parent is leaving), then delete.
                try db.execute(
                    sql: "UPDATE mediaItem SET parentMediaItemID = NULL WHERE parentMediaItemID = ?",
                    arguments: [item.id])
                return try MediaItem.deleteOne(db, key: item.id)
            }
            if removed { outcome.rowsDeleted += 1 }
        }
        return outcome
    }

    // MARK: - Mechanics

    static func collisionStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    /// Six attempts for transient IO, ported pacing. A missing source file
    /// surfaces immediately — retrying can't conjure it back.
    static func moveWithRetries(fileAccess: any FileAccess, from: URL, to: URL) throws {
        var lastError: (any Error)?
        for attempt in 1...6 {
            do {
                try fileAccess.moveFile(at: from, to: to)
                return
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                throw MoveError.moveFailed("source file is missing")
            } catch {
                lastError = error
                if attempt < 6 { usleep(useconds_t(100_000 * attempt)) }
            }
        }
        throw MoveError.moveFailed("\(lastError.map(String.init(describing:)) ?? "unknown") after 6 attempts")
    }
}
