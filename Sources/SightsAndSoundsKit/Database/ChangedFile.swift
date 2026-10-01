import Foundation
import GRDB

extension LibraryDatabase {
    /// An item's file has new bytes — a tag write, a restore, a remux, a
    /// repair, or a size found changed on disk: forget what was read off
    /// the old ones. The hash no longer describes the file (and kept, it
    /// paired the file with its old twin as byte-identical); a hash failure
    /// was the old file's; and the embedded metadata the sweep read is the
    /// tags just replaced, so the item is swept again. That last one was
    /// missed: a rescan that ran before a tag write left Tag Analysis
    /// showing the old tags until another manual rescan.
    static func forgetReadingsOfChangedFile(_ itemID: UUID, in db: Database) throws {
        try db.execute(sql: "UPDATE mediaItem SET contentHash = NULL WHERE id = ?", arguments: [itemID])
        try db.execute(sql: "DELETE FROM contentHashFailure WHERE mediaItemID = ?", arguments: [itemID])
        try db.execute(sql: "DELETE FROM metadataSweepState WHERE mediaItemID = ?", arguments: [itemID])
    }
}
