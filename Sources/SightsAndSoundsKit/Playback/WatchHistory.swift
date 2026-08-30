import Foundation
import GRDB

extension LibraryDatabase {
    /// What has been watched, most recent first.
    ///
    /// Built on the columns the player already maintains —
    /// `lastWatchedAt`, `watchCount`, `completed`, `resumePositionSeconds`
    /// — rather than a per-view event log. That choice decides what this
    /// can answer and what it cannot, so it is worth stating plainly:
    ///
    /// It answers "what have I watched, when was the last time, and where
    /// did I stop". One row per item.
    ///
    /// It cannot answer "what did I watch last Tuesday". Something
    /// watched three times is a single row reading 3, carrying only the
    /// most recent date. A real timeline needs a table with a row per
    /// viewing, which would start empty on the day it shipped and know
    /// nothing about anything watched before — whereas this works on
    /// everything already recorded.
    ///
    /// `limit` is a display bound. Items never watched are absent rather
    /// than present with a null date: "not in the history" and "watched
    /// at an unknown time" are different facts and only one of them is
    /// true here.
    public func recentlyWatched(limit: Int = 500) throws -> [MediaItem] {
        try writer.read { db in
            try MediaItem
                .filter(sql: "lastWatchedAt IS NOT NULL")
                .order(sql: "lastWatchedAt DESC, relativePath")
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// How many items carry a watch date at all — the history's true size,
    /// independent of the display limit, so the window can say when it is
    /// showing you a slice rather than everything.
    public func watchedItemCount() throws -> Int {
        try writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM mediaItem WHERE lastWatchedAt IS NOT NULL") ?? 0
        }
    }
}
