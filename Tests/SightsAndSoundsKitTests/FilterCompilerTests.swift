import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// Proves the compiled statement is the SQL we expect: one statement, no
/// in-memory pass, wildcards escaped, and the folder/tag probes running on
/// indexes. This is the Phase 0 "confirm it compiles to the SQL you expect"
/// gate — if these fail, the storage choice is wrong.
@Suite struct FilterCompilerTests {

    private func fullFilter(_ f: FilterFixture) -> MediaFilter {
        MediaFilter(
            required: [.tag(f.bandA.id), .folder("shows/1995"), .status(.favorite)],
            optional: [.subtree("shows"), .missingCategory(f.recordingType.id)],
            excluded: [.tag(f.secret.id)])
    }

    @Test func everyTermCompilesIntoOneStatement() throws {
        let f = try FilterFixture()
        let compiled = FilterCompiler.compile(filter: fullFilter(f), kind: .video)

        // The baseline predicates every listing carries.
        #expect(compiled.sql.contains("mediaItem.kind = ?"))
        #expect(compiled.sql.contains("mediaItem.clipExported = 0"))
        // Term shapes.
        #expect(compiled.sql.contains("EXISTS (SELECT 1 FROM mediaItemTag"))
        #expect(compiled.sql.contains("mediaItem.folderPath = ?"))
        #expect(compiled.sql.contains("LIKE ? ESCAPE '\\'"))
        #expect(compiled.sql.contains("tag.tagCategoryID = ?"))
        #expect(compiled.sql.contains("mediaItem.isFavorite"))
        // Auto-hide with the referenced-tag exemption.
        #expect(compiled.sql.contains("tag.hiddenByDefault"))
        #expect(compiled.sql.contains("tag.id NOT IN (?, ?)"))
        // One statement, no second pass.
        #expect(!compiled.sql.contains(";"))

        // The statement prepares and the argument count matches — SQLite
        // itself validates what string assertions cannot.
        try f.library.writer.read { db in
            let statement = try db.makeStatement(sql: compiled.sql)
            try statement.setArguments(compiled.arguments)
        }
    }

    @Test func probesRunOnIndexes() throws {
        let f = try FilterFixture()
        let filter = MediaFilter(required: [.tag(f.bandA.id), .folder("shows/1995")])
        let compiled = FilterCompiler.compile(filter: filter, kind: .video)

        let plan = try f.library.writer.read { db in
            try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN " + compiled.sql,
                arguments: compiled.arguments
            ).map { $0["detail"] as String }.joined(separator: "\n")
        }
        // The tag membership probe hits the join table's primary-key index...
        #expect(plan.contains("COVERING INDEX"))
        // ...and nothing in the plan is a full-table scan of the join table.
        #expect(!plan.contains("SCAN mediaItemTag"))
    }

    @Test func likeEscapingIsExact() {
        #expect(FilterCompiler.escapeLike("a_b") == "a\\_b")
        #expect(FilterCompiler.escapeLike("a%b") == "a\\%b")
        #expect(FilterCompiler.escapeLike("a\\b") == "a\\\\b")
        #expect(FilterCompiler.escapeLike("plain") == "plain")
    }

    @Test func malformedValuesAreUnrepresentable() {
        // The old app's "malformed Tag/Missing/Status value matches nothing"
        // rule has no equivalent here: payloads are UUID / enum typed, so the
        // compiler never sees an unparseable term. Recorded as a test so the
        // intent survives.
        let term: FilterTerm = .tag(UUID())
        #expect(term == term)
    }
}
