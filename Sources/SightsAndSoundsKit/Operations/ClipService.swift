import Foundation
import GRDB

public enum ClipError: Error, CustomStringConvertible {
    case itemNotFound
    case notAClip
    case invalidRange
    case nestedClip

    public var description: String {
        switch self {
        case .itemNotFound: "the item no longer exists"
        case .notAClip: "this item is not an embedded clip"
        case .invalidRange: "the clip range is empty or reversed"
        case .nestedClip: "clips cannot be created inside clips — author on the parent"
        }
    }
}

extension LibraryDatabase {
    /// The actual media file behind an item. For an embedded clip that's
    /// the PARENT's file — the clip row is a named range, not a file.
    /// Returns nil when the source is disabled/offline or a lookup fails.
    public func resolvedFileURL(
        for item: MediaItem, fileAccess: any FileAccess = LiveFileAccess()
    ) throws -> URL? {
        var target = item
        if let parentID = item.parentMediaItemID {
            guard let parent = try writer.read({ try MediaItem.fetchOne($0, key: parentID) })
            else { return nil }
            target = parent
        }
        guard let source = try writer.read({ try Source.fetchOne($0, key: target.sourceID) }),
              source.enabled, source.isOnline(using: fileAccess)
        else { return nil }
        return URL(fileURLWithPath: source.rootPath, isDirectory: true)
            .appendingPathComponent(target.relativePath)
    }

    /// Author an embedded clip: a named range inside the parent's file.
    /// The row carries the parent's path (its file IS the parent's file —
    /// the path-unique index is partial for exactly this) and inherits the
    /// parent's tags? No — a clip starts untagged; tags are the user's call.
    @discardableResult
    public func createEmbeddedClip(
        parentID: UUID, name: String,
        startSeconds: Double, endSeconds: Double
    ) throws -> MediaItem {
        guard endSeconds > startSeconds, startSeconds >= 0 else { throw ClipError.invalidRange }
        return try writer.write { db in
            guard let parent = try MediaItem.fetchOne(db, key: parentID) else {
                throw ClipError.itemNotFound
            }
            guard parent.parentMediaItemID == nil else { throw ClipError.nestedClip }

            var clip = MediaItem(
                sourceID: parent.sourceID,
                kind: parent.kind,
                relativePath: parent.relativePath,
                fileSize: 0,
                durationSeconds: endSeconds - startSeconds,
                needsReview: false,
                parentMediaItemID: parent.id,
                clipStartSeconds: startSeconds,
                clipEndSeconds: endSeconds,
                isClip: true)
            // Label the clip by note-in-name: the grid shows fileName, so a
            // clip presents as "name (parent file)".
            clip.notes = name
            try clip.insert(db)
            return clip
        }
    }

    /// Embedded clips of one parent, in-range order.
    public func clips(of parentID: UUID) throws -> [MediaItem] {
        try writer.read { db in
            try MediaItem
                .filter(sql: "parentMediaItemID = ? AND clipExported = 0", arguments: [parentID])
                .order(sql: "clipStartSeconds")
                .fetchAll(db)
        }
    }
}
