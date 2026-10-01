import Foundation
import GRDB

/// What a file's new bytes are.
enum FileChange {
    /// The same streams, copied: a tag write, a restore, a remux.
    case sameStreams
    /// The streams themselves may be new: a repair, a size found changed on
    /// disk, a swap finished after a crash.
    case newStreams
}

extension LibraryDatabase {
    /// An item's file has new bytes — a tag write, a restore, a remux, a
    /// repair, or a size found changed on disk: forget what was read off
    /// the old ones. The hash no longer describes the file (and kept, it
    /// paired the file with its old twin as byte-identical); a hash failure
    /// was the old file's; and the embedded metadata the sweep read is the
    /// tags just replaced, so the item is swept again. That one was missed:
    /// a rescan that ran before a tag write left Tag Analysis showing the
    /// old tags until another manual rescan.
    ///
    /// An unreviewed pair the hash sweep made from the old bytes goes too.
    /// It offered the changed file as byte-identical to its twin at full
    /// confidence — delete one, lose the new tags or the repair — and the
    /// sweep never pairs a pair twice, so it was never corrected. If the
    /// bytes still match, the next hash sweep pairs them again. A pair
    /// somebody answered stays; fingerprint pairs compare the sound, which
    /// these changes keep.
    ///
    /// The old file's fingerprint and thumbnail failures go too: they were
    /// the old bytes' (a broken file, repaired, was never fingerprinted or
    /// thumbnailed again), and the sweeps skip an item marked failed.
    ///
    /// What Media Signal read goes only when the streams are new (a repair
    /// re-encodes; a size found changed on disk, or a swap finished after a
    /// crash, may be one): a repaired file went on showing the broken one's
    /// timing, and Examine skipped it as done. A tag write, a restore and a
    /// remux copy the streams untouched, so those readings stand — and
    /// examined again, the file would show this app's own muxer stamp as
    /// its transcoder.
    static func forgetReadingsOfChangedFile(_ itemID: UUID, _ change: FileChange, in db: Database) throws {
        if change == .newStreams {
            // As the full reset: evidence and inferences go with the
            // readings they were drawn from.
            for table in [
                "mediaSignalInference", "mediaSignalEvidence", "mediaSignalMeasurement",
                "mediaSignalSeries", "mediaSignalDeclared", "mediaSignalStage",
            ] {
                try db.execute(sql: "DELETE FROM \(table) WHERE mediaItemID = ?", arguments: [itemID])
            }
        }
        try db.execute(sql: "DELETE FROM fingerprintFailure WHERE mediaItemID = ?", arguments: [itemID])
        try db.execute(
            sql: "DELETE FROM thumbnailState WHERE mediaItemID = ? AND failureMessage IS NOT NULL",
            arguments: [itemID])
        try db.execute(sql: "UPDATE mediaItem SET contentHash = NULL WHERE id = ?", arguments: [itemID])
        try db.execute(sql: "DELETE FROM contentHashFailure WHERE mediaItemID = ?", arguments: [itemID])
        try db.execute(sql: "DELETE FROM metadataSweepState WHERE mediaItemID = ?", arguments: [itemID])
        try db.execute(
            sql: """
            DELETE FROM duplicateCandidate
            WHERE status = ? AND source = ? AND (itemAID = ? OR itemBID = ?)
            """,
            arguments: [DuplicateStatus.pending.rawValue, CandidateSource.contentHash.rawValue, itemID, itemID])
    }
}
