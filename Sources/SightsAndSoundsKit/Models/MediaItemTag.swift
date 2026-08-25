import Foundation
import GRDB

/// Join row: a media item carries a tag.
public struct MediaItemTag: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mediaItemTag"

    public var mediaItemID: UUID
    public var tagID: UUID

    public init(mediaItemID: UUID, tagID: UUID) {
        self.mediaItemID = mediaItemID
        self.tagID = tagID
    }
}
