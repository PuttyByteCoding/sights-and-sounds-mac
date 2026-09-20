import Foundation
import GRDB

/// A snapshot as a menu needs it: when, from what, and the id to restore
/// — never the tag payload, which can be large and is only read by the
/// restore itself.
public struct SnapshotRef: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let capturedAt: Date
    public let source: SnapshotSource
}

/// What a tile's context menu needs to know about the items it may be
/// opened on, asked once for the whole library rather than once per tile.
/// SwiftUI builds a context menu's items whenever the tile's body runs,
/// so a per-item query there is a query per tile per render.
extension LibraryDatabase {
    /// Items with at least one hide block — the ones "Export Copy
    /// Without Hidden Blocks" applies to.
    public func itemIDsWithHideBlocks() throws -> Set<UUID> {
        try writer.read { db in
            Set(try UUID.fetchAll(
                db, sql: "SELECT DISTINCT mediaItemID FROM videoBlock WHERE kind = ?",
                arguments: [VideoBlockKind.hide.rawValue]))
        }
    }

    /// Each item's most recent snapshots, newest first, `limit` at most.
    public func recentSnapshotRefs(perItem limit: Int) throws -> [UUID: [SnapshotRef]] {
        try writer.read { db in
            var refs: [UUID: [SnapshotRef]] = [:]
            // Capped in SQL: a file written many times keeps every
            // snapshot, and the menu only ever offers the latest few.
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, mediaItemID, capturedAt, source FROM ( \
                    SELECT id, mediaItemID, capturedAt, source, \
                           ROW_NUMBER() OVER (PARTITION BY mediaItemID ORDER BY capturedAt DESC) AS n \
                    FROM embeddedTagSnapshot) \
                WHERE n <= ? ORDER BY capturedAt DESC
                """,
                arguments: [limit])
            for row in rows {
                let itemID: UUID = row["mediaItemID"]
                refs[itemID, default: []].append(SnapshotRef(
                    id: row["id"], capturedAt: row["capturedAt"],
                    source: SnapshotSource(rawValue: row["source"]) ?? .preWrite))
            }
            return refs
        }
    }
}
