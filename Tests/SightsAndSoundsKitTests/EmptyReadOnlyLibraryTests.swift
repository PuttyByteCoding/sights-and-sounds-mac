import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The library that stands where there is none to give: for a window on
/// a library another Mac holds. It has the schema, nothing in it, and
/// takes no change by any road.
@Suite struct EmptyReadOnlyLibraryTests {
    @Test func itReadsAsALibraryWithNothingInIt() throws {
        let library = try LibraryDatabase.emptyAndReadOnly()
        #expect(try library.info() == nil)
        #expect(try library.sources().isEmpty)
        #expect(try library.vocabulary().isEmpty)
        #expect(try library.writer.read { try MediaItem.fetchCount($0) } == 0)
    }

    @Test func itTakesNoChangeBeforeOrAfterBeingRead() throws {
        let library = try LibraryDatabase.emptyAndReadOnly()
        #expect(throws: (any Error).self) { try library.ensureInfo(name: "Written") }
        // Reading it does not open it to writing: an earlier version was
        // switched to "query only", and the first read switched it back.
        _ = try library.sources()
        _ = try library.writer.read { try MediaItem.fetchCount($0) }
        #expect(throws: (any Error).self) { try library.ensureInfo(name: "Written") }
        #expect(throws: (any Error).self) {
            try library.writer.write { try Source(name: "S", rootPath: "/tmp/s").insert($0) }
        }
        #expect(throws: (any Error).self) {
            try library.writer.writeWithoutTransaction { try $0.execute(sql: "DELETE FROM mediaItem") }
        }
        #expect(throws: (any Error).self) {
            try library.writer.writeWithoutTransaction { try $0.execute(sql: "CREATE TABLE sneaked (id INTEGER)") }
        }
        #expect(try library.info() == nil)
        #expect(try library.sources().isEmpty)
    }

    @Test func thereIsOneForTheWholeApp() throws {
        #expect(try LibraryDatabase.emptyAndReadOnly() === LibraryDatabase.emptyAndReadOnly())
    }
}
