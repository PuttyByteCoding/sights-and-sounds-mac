import Foundation
import GRDB

/// An audit record of one file move: logged AND reversible. `revertedAt`
/// is nil while the move can still be undone. Deliberately no foreign key
/// — the log outlives its item (purge deletes rows; the history of what
/// moved where should survive), so the name is snapshotted for labeling.
public struct FileMoveLog: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "fileMoveLog"

    public var id: UUID
    public var mediaItemID: UUID
    public var sourceID: UUID
    /// Snapshot at move time, so the list stays labeled after purge.
    public var fileName: String
    public var fromPath: String
    public var toPath: String
    public var movedAt: Date
    public var revertedAt: Date?

    public init(
        id: UUID = UUID(), mediaItemID: UUID, sourceID: UUID,
        fileName: String, fromPath: String, toPath: String,
        movedAt: Date = Date(), revertedAt: Date? = nil
    ) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.sourceID = sourceID
        self.fileName = fileName
        self.fromPath = fromPath
        self.toPath = toPath
        self.movedAt = movedAt
        self.revertedAt = revertedAt
    }
}
