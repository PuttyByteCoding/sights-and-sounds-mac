import Foundation
import Testing

@testable import SightsAndSoundsKit

/// A folder is one source. Nothing stopped the same folder being added
/// twice (the table has no uniqueness on its path), and since the scan's
/// "known" set is per source, every file then listed as new and the
/// import inserted a second row per file — rows with no un-import.
@Suite struct SourceRegistrationTests {
    private func library() throws -> LibraryDatabase {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Sources")
        return library
    }

    @Test func theSameFolderIsRefusedASecondTime() throws {
        let library = try library()
        let shows = try library.addSource(named: "Shows", rootPath: "/Volumes/Tapes/shows")
        #expect(throws: SourceError.overlaps(existing: "Shows", relation: .same)) {
            try library.addSource(named: "Shows again", rootPath: "/Volumes/Tapes/shows")
        }
        // Spelled differently, the same folder.
        #expect(throws: SourceError.overlaps(existing: "Shows", relation: .same)) {
            try library.addSource(named: "Trailing", rootPath: "/Volumes/Tapes/shows/")
        }
        #expect(throws: SourceError.overlaps(existing: "Shows", relation: .same)) {
            try library.addSource(named: "Dotted", rootPath: "/Volumes/Tapes/./shows")
        }
        let sources = try library.writer.read { try Source.fetchAll($0) }
        #expect(sources.map(\.id) == [shows.id])
    }

    @Test func aFolderInsideOrAroundASourceIsRefused() throws {
        let library = try library()
        try library.addSource(named: "Shows", rootPath: "/Volumes/Tapes/shows")
        #expect(throws: SourceError.overlaps(existing: "Shows", relation: .inside)) {
            try library.addSource(named: "1995", rootPath: "/Volumes/Tapes/shows/1995")
        }
        #expect(throws: SourceError.overlaps(existing: "Shows", relation: .contains)) {
            try library.addSource(named: "Tapes", rootPath: "/Volumes/Tapes")
        }
        // A sibling is fine, and so is a folder whose name merely starts
        // the same way.
        try library.addSource(named: "Audio", rootPath: "/Volumes/Tapes/audio")
        try library.addSource(named: "Shows 2", rootPath: "/Volumes/Tapes/shows-2")
        #expect(try library.writer.read { try Source.fetchCount($0) } == 3)
    }
}
