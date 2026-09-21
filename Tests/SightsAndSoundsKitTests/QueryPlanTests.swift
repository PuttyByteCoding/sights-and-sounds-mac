import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// The plans behind the queries the app issues most. Asserted as plans
/// because the cost only shows on a large library, long after a test
/// with six rows has passed.
@Suite struct QueryPlanTests {

    private func plan(_ library: LibraryDatabase, _ sql: String, _ arguments: StatementArguments = []) throws -> String {
        try library.writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                .map { $0["detail"] as String }.joined(separator: "\n")
        }
    }

    /// Every deleted item makes SQLite look for rows whose parent it was
    /// (the self-referencing foreign key), and every segment lookup asks
    /// the same question. Without an index each is a scan of the table.
    @Test func lookingUpAnItemsSegmentsUsesAnIndex() throws {
        let f = try FilterFixture()
        let detail = try plan(
            f.library, "SELECT id FROM mediaItem WHERE parentMediaItemID = ?", [UUID()])
        #expect(detail.contains("USING") && detail.contains("INDEX"))
        #expect(!detail.contains("SCAN mediaItem"))
    }

    /// A required tag is usually the most selective thing in a filter.
    /// As a correlated EXISTS it could only be checked per candidate row,
    /// so the query walked the items; as a membership list the tag's own
    /// index produces the candidates and the items are fetched by key.
    @Test func aRequiredTagDrivesTheListing() throws {
        let f = try FilterFixture()
        // Enough rows for the choice to matter, a tag on a handful of
        // them, and the statistics a library gets when it is closed.
        try f.library.writer.write { db in
            for n in 0..<3_000 {
                try MediaItem(
                    sourceID: f.mainSource.id, kind: .video,
                    relativePath: "bulk/\(n).mp4", needsReview: false).insert(db)
            }
            try db.execute(sql: "ANALYZE")
        }
        let compiled = FilterCompiler.compile(
            filter: MediaFilter(required: [.tag(f.bandA.id)]), kinds: .all)
        let detail = try plan(f.library, compiled.sql, compiled.arguments)
        // Items are reached by their key, from the tag's membership list —
        // not by walking every item of the selected kinds.
        #expect(detail.contains("SEARCH mediaItem USING INDEX sqlite_autoindex_mediaItem_1 (id=?)"))
        #expect(!detail.contains("mediaItem_kind"))
        #expect(!detail.contains("SCAN mediaItem"))
    }

    /// The rewrite is only a plan change: the listing it produces is the
    /// one the semantics tests pin, here with a tag in every slot.
    @Test func theListingIsUnchangedByHowATagIsAsked() throws {
        let f = try FilterFixture()
        let filter = MediaFilter(
            required: [.tag(f.bandA.id)], optional: [.tag(f.sbd.id), .tag(f.aud.id)],
            excluded: [.tag(f.bandB.id)])
        let listed = Set(try f.library.mediaItems(matching: filter, kinds: .all).map(\.id))
        // Worked out by hand from the link table, without the compiler.
        let expected = try f.library.writer.read { db -> Set<UUID> in
            let links = try Row.fetchAll(db, sql: "SELECT mediaItemID, tagID FROM mediaItemTag")
            var tags: [UUID: Set<UUID>] = [:]
            for link in links { tags[link["mediaItemID"], default: []].insert(link["tagID"]) }
            return Set(tags.filter { _, held in
                held.contains(f.bandA.id) && !held.contains(f.bandB.id)
                    && (held.contains(f.sbd.id) || held.contains(f.aud.id))
            }.keys)
        }
        // …within what any listing shows (the baseline hides some rows).
        let visible = Set(try f.library.mediaItems(matching: MediaFilter(), kinds: .all).map(\.id))
        #expect(listed == expected.intersection(visible))
        #expect(!listed.isEmpty)
    }
}
