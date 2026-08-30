import Foundation
import GRDB

/// The numbers down the browse sidebar: how many items each source,
/// folder-free tag, empty category and status flag would show.
///
/// They are counted under the **listing baseline** — the selected media
/// kinds, enabled sources, live rows — and deliberately *not* under the
/// active filter. A count that fell to zero the moment you started
/// filtering would answer a question nobody asked; what these answer is
/// "if I clicked this, what is behind it".
///
/// Zero is a value, not an absence: a tag with no items under the current
/// kinds renders dimmed rather than disappearing, because "exists but
/// unused for this kind" is exactly the information (#96).
public struct BrowseCounts: Sendable, Equatable {
    public var total: Int = 0
    public var bySource: [UUID: Int] = [:]
    public var byTag: [UUID: Int] = [:]
    /// Items carrying no tag at all from that category — the count on the
    /// `Missing — no <Category> tag` row.
    public var missingByCategory: [UUID: Int] = [:]
    public var byStatus: [StatusFlag: Int] = [:]
    /// Counted across EVERY kind, not just the selected ones — the media
    /// type rows are the one place the selection must not narrow the
    /// numbers, or an unselected kind would always read zero and look
    /// empty rather than unselected.
    public var byKind: [MediaKind: Int] = [:]

    public init() {}
}

extension LibraryDatabase {
    /// Every sidebar count in one read. One pass rather than a query per
    /// row: at library size, a count per tag row is the N+1 that made the
    /// web app's browse panel take seconds to open.
    public func browseCounts(kinds: MediaKinds) throws -> BrowseCounts {
        let base = FilterCompiler.Baseline.sql(kinds)
        // Auto-hide is part of every listing, so it is part of every
        // count: "All Items 10" over a grid of 9 is a number that lies.
        let baseline = (
            sql: "\(base.sql) AND \(FilterCompiler.Baseline.notHidden)", args: base.args)
        return try writer.read { db in
            var counts = BrowseCounts()

            counts.total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM mediaItem WHERE \(baseline.sql)",
                arguments: StatementArguments(baseline.args)) ?? 0

            let sourceRows = try Row.fetchAll(
                db,
                sql: """
                SELECT mediaItem.sourceID AS id, COUNT(*) AS n FROM mediaItem \
                WHERE \(baseline.sql) GROUP BY mediaItem.sourceID
                """,
                arguments: StatementArguments(baseline.args))
            counts.bySource = Dictionary(
                uniqueKeysWithValues: sourceRows.map { ($0["id"] as UUID, $0["n"] as Int) })

            let tagRows = try Row.fetchAll(
                db,
                sql: """
                SELECT mediaItemTag.tagID AS id, COUNT(*) AS n FROM mediaItemTag \
                JOIN mediaItem ON mediaItem.id = mediaItemTag.mediaItemID \
                WHERE \(base.sql) \
                AND \(FilterCompiler.Baseline.notHiddenExceptCountedTag) \
                GROUP BY mediaItemTag.tagID
                """,
                arguments: StatementArguments(base.args))
            counts.byTag = Dictionary(
                uniqueKeysWithValues: tagRows.map { ($0["id"] as UUID, $0["n"] as Int) })

            // One correlated count per category — there are a handful of
            // categories, and the alternative (fetch every link and diff
            // in memory) is the query this file exists to avoid.
            let categoryIDs = try UUID.fetchAll(db, sql: "SELECT id FROM tagCategory")
            for id in categoryIDs {
                counts.missingByCategory[id] = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM mediaItem \
                    WHERE \(baseline.sql) AND \(FilterCompiler.Baseline.missingCategory)
                    """,
                    arguments: StatementArguments(baseline.args + [id])) ?? 0
            }

            // Every flag in one row: eight SUMs over the same scan, not
            // eight scans.
            let sums = StatusFlag.allCases.enumerated().map { index, flag in
                "SUM(CASE WHEN \(FilterCompiler.Baseline.status(flag)) THEN 1 ELSE 0 END) AS f\(index)"
            }
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT \(sums.joined(separator: ", ")) FROM mediaItem WHERE \(baseline.sql)",
                arguments: StatementArguments(baseline.args)) {
                for (index, flag) in StatusFlag.allCases.enumerated() {
                    counts.byStatus[flag] = row["f\(index)"] as Int? ?? 0
                }
            }

            let base = FilterCompiler.Baseline.sql(.all)
            let allKinds = (
                sql: "\(base.sql) AND \(FilterCompiler.Baseline.notHidden)", args: base.args)
            let kindRows = try Row.fetchAll(
                db,
                sql: """
                SELECT mediaItem.kind AS kind, COUNT(*) AS n FROM mediaItem \
                WHERE \(allKinds.sql) GROUP BY mediaItem.kind
                """,
                arguments: StatementArguments(allKinds.args))
            for row in kindRows {
                if let kind = MediaKind(rawValue: row["kind"] as Int) {
                    counts.byKind[kind] = row["n"] as Int
                }
            }

            return counts
        }
    }
}
