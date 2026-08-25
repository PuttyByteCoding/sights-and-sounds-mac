import Foundation
import GRDB

extension LibraryDatabase {
    /// Record where playback stopped. The resume position is cleared near
    /// either edge — under 15 seconds in, or past 95% — so reopening a
    /// finished or barely-started item starts clean. Stamps `lastWatchedAt`.
    public func recordPlaybackStop(
        itemID: UUID, positionSeconds: Double, durationSeconds: Double?, at date: Date = Date()
    ) throws {
        var resume: Double? = positionSeconds
        if positionSeconds < 15 { resume = nil }
        if let duration = durationSeconds, duration > 0, positionSeconds > duration * 0.95 {
            resume = nil
        }
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE mediaItem SET resumePositionSeconds = ?, lastWatchedAt = ? WHERE id = ?
                """,
                arguments: [resume, date, itemID])
        }
    }

    /// Record that a play-through happened (the player calls this once per
    /// session, on first crossing 90%): tally the watch, mark completed.
    public func recordPlaybackCompletion(itemID: UUID, at date: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE mediaItem SET watchCount = watchCount + 1, completed = 1, lastWatchedAt = ? \
                WHERE id = ?
                """,
                arguments: [date, itemID])
        }
    }

    /// Flip one of the four structural flags the player's keyboard map
    /// toggles. Returns the new value.
    @discardableResult
    public func toggleFlag(_ flag: PlayerToggleFlag, itemID: UUID) throws -> Bool {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET \(flag.column) = NOT \(flag.column) WHERE id = ?",
                arguments: [itemID])
            return try Bool.fetchOne(
                db, sql: "SELECT \(flag.column) FROM mediaItem WHERE id = ?",
                arguments: [itemID]) ?? false
        }
    }
}

/// The flags the player can toggle from the keyboard. Column names are a
/// fixed vocabulary — never interpolated from user input.
public enum PlayerToggleFlag: Sendable {
    case favorite, needsReview, markedForDeletion, playbackIssue

    var column: String {
        switch self {
        case .favorite: "isFavorite"
        case .needsReview: "needsReview"
        case .markedForDeletion: "markedForDeletion"
        case .playbackIssue: "playbackIssue"
        }
    }
}
