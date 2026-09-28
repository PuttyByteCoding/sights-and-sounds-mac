import GRDB
import Testing

@testable import SightsAndSoundsKit

/// Every foreign key's child column leads an index. Without one, each
/// delete of a parent row scans the whole child table for its cascade:
/// `mediaSignalInferenceEvidence.evidenceID` had none, so re-concluding
/// the library grew quadratically with its evidence.
@Suite struct ForeignKeyIndexTests {
    private func unindexedForeignKeys(_ db: Database) throws -> [String] {
        let tables = try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        var missing: [String] = []
        for table in tables {
            let foreignColumns = Set(try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table.quotedDatabaseIdentifier))")
                .map { $0["from"] as String })
            guard !foreignColumns.isEmpty else { continue }
            // Leading columns of every index, the primary key included.
            var leading: Set<String> = []
            for index in try Row.fetchAll(db, sql: "PRAGMA index_list(\(table.quotedDatabaseIdentifier))") {
                let name: String = index["name"]
                if let first = try Row.fetchOne(
                    db, sql: "SELECT name FROM pragma_index_info(?) WHERE seqno = 0", arguments: [name]) {
                    leading.insert(first["name"])
                }
            }
            // A rowid table's INTEGER PRIMARY KEY is the rowid itself.
            for column in try Row.fetchAll(db, sql: "PRAGMA table_info(\(table.quotedDatabaseIdentifier))")
            where (column["pk"] as Int) == 1 {
                leading.insert(column["name"])
            }
            for column in foreignColumns.subtracting(leading).sorted() {
                missing.append("\(table).\(column)")
            }
        }
        return missing
    }

    @Test func everyLibraryForeignKeyIsIndexed() throws {
        let library = try LibraryDatabase.openInMemory()
        let missing = try library.writer.read(unindexedForeignKeys)
        #expect(missing.isEmpty, "unindexed foreign keys: \(missing)")
    }

    @Test func everyAppForeignKeyIsIndexed() throws {
        let app = try AppDatabase.openInMemory()
        let missing = try app.writer.read(unindexedForeignKeys)
        #expect(missing.isEmpty, "unindexed foreign keys: \(missing)")
    }
}
