import Foundation
import GRDB

public enum VideoBlockKind: String, Codable, Sendable, CaseIterable {
    /// A noteworthy region (informational).
    case clip
    /// Skipped during playback; removed by the block-removal operation.
    case hide
    case other
}

/// A marked time range inside one item. `hide` blocks are the working
/// kind: the player skips them live, and the removal job cuts them out
/// into an edited copy.
public struct VideoBlock: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "videoBlock"

    public var id: UUID
    public var mediaItemID: UUID
    public var startSeconds: Double
    public var endSeconds: Double
    public var kind: VideoBlockKind

    public init(
        id: UUID = UUID(), mediaItemID: UUID,
        startSeconds: Double, endSeconds: Double, kind: VideoBlockKind = .hide
    ) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.kind = kind
    }
}

extension LibraryDatabase {
    @discardableResult
    public func addBlock(
        to itemID: UUID, startSeconds: Double, endSeconds: Double,
        kind: VideoBlockKind = .hide
    ) throws -> VideoBlock {
        guard endSeconds > startSeconds, startSeconds >= 0 else { throw ClipError.invalidRange }
        let block = VideoBlock(
            mediaItemID: itemID, startSeconds: startSeconds, endSeconds: endSeconds, kind: kind)
        try writer.write { try block.insert($0) }
        return block
    }

    public func blocks(of itemID: UUID) throws -> [VideoBlock] {
        try writer.read { db in
            try VideoBlock
                .filter(sql: "mediaItemID = ?", arguments: [itemID])
                .order(sql: "startSeconds")
                .fetchAll(db)
        }
    }

    public func deleteBlock(_ blockID: UUID) throws {
        _ = try writer.write { try VideoBlock.deleteOne($0, key: blockID) }
    }
}

/// Pure range math for hide blocks — shared by the live playback skip and
/// the removal job, so what you hear is what the edit will keep.
public enum SegmentMath {
    /// Merge overlapping/touching ranges and clamp into [0, duration].
    public static func normalized(_ ranges: [(Double, Double)], duration: Double) -> [(start: Double, end: Double)] {
        let clamped = ranges
            .map { (max(0, min($0.0, duration)), max(0, min($0.1, duration))) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for range in clamped {
            if var last = merged.last, range.0 <= last.1 {
                last.1 = max(last.1, range.1)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        return merged.map { (start: $0.0, end: $0.1) }
    }

    /// The segments an edit KEEPS: the whole duration minus the hidden
    /// ranges. Empty when the blocks swallow everything.
    public static func keepSegments(
        duration: Double, hidden: [(Double, Double)]
    ) -> [(start: Double, end: Double)] {
        guard duration > 0 else { return [] }
        var keep: [(Double, Double)] = []
        var cursor = 0.0
        for range in normalized(hidden, duration: duration) {
            if range.start > cursor { keep.append((cursor, range.start)) }
            cursor = max(cursor, range.end)
        }
        if cursor < duration { keep.append((cursor, duration)) }
        return keep.map { (start: $0.0, end: $0.1) }
    }

    /// Live playback: where should the playhead be, given hide blocks? nil
    /// = play on; a value = jump there (the end of the block the time sits
    /// inside — or past the end of content when blocks run to the end).
    public static func skipTarget(
        at seconds: Double, hidden: [(Double, Double)], duration: Double
    ) -> Double? {
        for range in normalized(hidden, duration: duration)
        where seconds >= range.start && seconds < range.end {
            return range.end
        }
        return nil
    }
}
