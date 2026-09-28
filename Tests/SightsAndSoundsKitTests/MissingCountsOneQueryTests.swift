import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The `Missing — no <Category> tag` counts, filtered and library-wide,
/// must equal asking each category separately — which is how they were
/// computed, re-running the whole filter once per category. Pinned here
/// against that reference on the fixture plus a dozen extra categories
/// (some tagged, some not), so the one-query form cannot drift.
@Suite struct MissingCountsOneQueryTests {
    private func fixture() throws -> FilterFixture {
        let f = try FilterFixture()
        try f.library.writer.write { db in
            let items = try UUID.fetchAll(db, sql: "SELECT id FROM mediaItem")
            for n in 0..<12 {
                let category = TagCategory(name: "Extra \(n)", sortOrder: 10 + n)
                try category.insert(db)
                let tag = SightsAndSoundsKit.Tag(tagCategoryID: category.id, name: "Extra tag \(n)")
                try tag.insert(db)
                // Every third category tags every other item.
                guard n % 3 == 0 else { continue }
                for (index, item) in items.enumerated() where index % 2 == 0 {
                    try MediaItemTag(mediaItemID: item, tagID: tag.id).insert(db)
                }
            }
        }
        return f
    }

    /// The per-category reference: the query the counts used to run.
    private func reference(_ library: LibraryDatabase, where predicate: String, _ arguments: StatementArguments) throws -> [UUID: Int] {
        try library.writer.read { db in
            var counts: [UUID: Int] = [:]
            for id in try UUID.fetchAll(db, sql: "SELECT id FROM tagCategory") {
                counts[id] = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM mediaItem WHERE \(predicate) AND \(FilterCompiler.Baseline.missingCategory)",
                    arguments: arguments + StatementArguments([id])) ?? 0
            }
            return counts
        }
    }

    @Test func filteredMissingCountsMatchAskingEachCategory() throws {
        let f = try fixture()
        for filter in [
            MediaFilter(required: [.tag(f.bandA.id)]),
            MediaFilter(optional: [.tag(f.sbd.id), .tag(f.aud.id)]),
            MediaFilter(excluded: [.tag(f.bandB.id)]),
        ] {
            let compiled = FilterCompiler.compile(filter: filter, kinds: .all)
            let expected = try reference(
                f.library, where: "mediaItem.id IN (SELECT id FROM (\(compiled.sql)))", compiled.arguments)
            #expect(try f.library.filteredMissingCategoryCounts(kinds: .all, filter: filter) == expected)
        }
    }

    @Test func libraryWideMissingCountsMatchAskingEachCategory() throws {
        let f = try fixture()
        for kinds in [MediaKinds.all, .video] {
            let base = FilterCompiler.Baseline.sql(kinds)
            let expected = try reference(
                f.library, where: "\(base.sql) AND \(FilterCompiler.Baseline.notHidden)",
                StatementArguments(base.args))
            #expect(try f.library.browseCounts(kinds: kinds).missingByCategory == expected)
        }
    }
}
