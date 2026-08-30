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

    /// Author a segment: a named range inside the parent's file, as a
    /// song or a clip. The row carries the parent's path (its file IS the
    /// parent's file — the path-unique index is partial for exactly this)
    /// and inherits the parent's tags? No — a segment starts untagged;
    /// tags are the user's call.
    ///
    /// The name is optional because the rail renames in place: closing a
    /// segment must never be blocked on a text field, or overshooting the
    /// out-point costs you the range. An empty name takes the role's
    /// default ("New song") and can be edited afterwards.
    @discardableResult
    public func createEmbeddedClip(
        parentID: UUID, name: String = "",
        startSeconds: Double, endSeconds: Double,
        role: SegmentRole = .clip
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
                isClip: true,
                segmentRole: role)
            // Label the segment by note-in-name: the grid shows fileName,
            // so it presents as "name (parent file)".
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            clip.notes = trimmed.isEmpty ? role.defaultName : trimmed
            try clip.insert(db)
            return clip
        }
    }

    /// Rename a segment. The rail edits in place, and the name is the
    /// only thing about a segment that changes after it is closed.
    public func renameSegment(_ itemID: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        try writer.write { db in
            guard let item = try MediaItem.fetchOne(db, key: itemID),
                  item.parentMediaItemID != nil
            else { throw ClipError.notAClip }
            var updated = item
            updated.notes = trimmed.isEmpty
                ? (item.segmentRole ?? .clip).defaultName : trimmed
            try updated.update(db)
        }
    }

    /// Delete a segment row. The parent's file is untouched — a segment
    /// is a named range, so removing one removes only the name.
    public func deleteSegment(_ itemID: UUID) throws {
        _ = try writer.write { db in
            guard let item = try MediaItem.fetchOne(db, key: itemID),
                  item.parentMediaItemID != nil
            else { throw ClipError.notAClip }
            return try MediaItem.deleteOne(db, key: itemID)
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
