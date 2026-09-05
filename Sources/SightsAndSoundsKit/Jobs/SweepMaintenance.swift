import Foundation
import GRDB

/// One derived-data kind's health: how many items still lack the data,
/// and how many failed last time — the numbers beside the sweep buttons.
public struct SweepStatus: Equatable, Sendable {
    public let missing: Int
    public let failed: Int
}

/// The maintenance surface behind the Background Tasks sweeps panel.
///
/// Every sweep in the app fills MISSING data only, and every failure
/// lands in a side table so the sweep stops retrying a broken file.
/// That makes the three buttons the same three moves everywhere:
/// verify = run the sweep as-is; retry = delete the failure rows, then
/// sweep; recalculate = forget the data itself, then sweep.
extension LibraryDatabase {

    // MARK: - Status

    public func contentHashStatus() throws -> SweepStatus {
        try writer.read { db in
            SweepStatus(
                missing: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM mediaItem WHERE contentHash IS NULL") ?? 0,
                failed: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM contentHashFailure") ?? 0)
        }
    }

    public func fingerprintStatus() throws -> SweepStatus {
        try writer.read { db in
            SweepStatus(
                missing: try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM mediaItem \
                    WHERE NOT EXISTS (SELECT 1 FROM audioFingerprint \
                                      WHERE audioFingerprint.mediaItemID = mediaItem.id) \
                    AND NOT EXISTS (SELECT 1 FROM fingerprintFailure \
                                    WHERE fingerprintFailure.mediaItemID = mediaItem.id)
                    """) ?? 0,
                failed: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM fingerprintFailure") ?? 0)
        }
    }

    public func metadataSweepStatus() throws -> SweepStatus {
        try writer.read { db in
            SweepStatus(
                missing: try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM mediaItem \
                    LEFT JOIN metadataSweepState ON metadataSweepState.mediaItemID = mediaItem.id \
                    WHERE metadataSweepState.mediaItemID IS NULL \
                    AND mediaItem.parentMediaItemID IS NULL
                    """) ?? 0,
                failed: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM metadataSweepState WHERE failureMessage IS NOT NULL")
                    ?? 0)
        }
    }

    // MARK: - Retry failed

    /// A failure row is what stops the sweep re-probing a broken file
    /// every signal — so a retry IS a row deletion, everywhere.
    public func retryContentHashFailures() throws {
        _ = try writer.write { db in
            try ContentHashFailure.deleteAll(db)
        }
    }

    public func retryFingerprintFailures() throws {
        _ = try writer.write { db in
            try FingerprintFailure.deleteAll(db)
        }
    }

    public func retryMetadataSweepFailures() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM metadataSweepState WHERE failureMessage IS NOT NULL")
        }
    }

    // MARK: - Recalculate all

    /// Forget the data itself; the next sweep rebuilds every item.
    public func resetContentHashes() throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE mediaItem SET contentHash = NULL")
            try ContentHashFailure.deleteAll(db)
        }
    }

    public func resetFingerprints() throws {
        try writer.write { db in
            try AudioFingerprintRecord.deleteAll(db)
            try FingerprintFailure.deleteAll(db)
        }
    }

    public func resetMetadataSweepAll() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM metadataSweepState")
        }
    }
}

extension LibraryDatabase {
    /// Thumbnails are disk-state driven — the cache directory IS the
    /// record — so recalculating is deleting the library's cache folder
    /// (plus the state rows) and letting the sweep self-heal.
    public func resetThumbnails(libraryID: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM thumbnailState")
        }
        let folder = ThumbnailStore.root.appendingPathComponent(
            libraryID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    public func thumbnailStatus(libraryID: UUID) throws -> SweepStatus {
        // Missing is judged the way the sweep judges it: a video item
        // whose cache file is absent. Failures self-heal by design, so
        // the failed column is always zero here.
        let items = try writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT id FROM mediaItem WHERE kind = ?",
                arguments: [MediaKind.video.rawValue])
                .map { $0["id"] as UUID }
        }
        let missing = items.count { itemID in
            !FileManager.default.fileExists(
                atPath: ThumbnailStore.url(libraryID: libraryID, itemID: itemID).path)
        }
        return SweepStatus(missing: missing, failed: 0)
    }
}
