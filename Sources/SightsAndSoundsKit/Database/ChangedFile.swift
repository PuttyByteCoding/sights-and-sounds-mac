import Foundation
import GRDB

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
    /// And what Media Signal read and concluded goes, with its stage marks,
    /// so the next examine reads the file afresh: a repaired file went on
    /// showing the broken one's timing and the conclusions drawn from it,
    /// and Examine skipped it as done. (As the full reset, evidence and
    /// inferences go with the readings they were drawn from.)
    static func forgetReadingsOfChangedFile(_ itemID: UUID, in db: Database) throws {
        for table in [
            "mediaSignalInference", "mediaSignalEvidence", "mediaSignalMeasurement",
            "mediaSignalSeries", "mediaSignalDeclared", "mediaSignalStage",
        ] {
            try db.execute(sql: "DELETE FROM \(table) WHERE mediaItemID = ?", arguments: [itemID])
        }
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
