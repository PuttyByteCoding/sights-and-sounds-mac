import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// What the Browse window asks its library to change, through the
/// service. The rules are the library's own — a single-select category
/// replaces, an overlapping source is refused — and reaching them through
/// the service must not be a way round any of them.
@Suite struct LocalLibraryServiceWritingTests {
    struct Fixture {
        let library: LibraryDatabase
        let service: LocalLibraryService
        let root: URL
        let source: Source
        let a: MediaItem
        let b: MediaItem
        let ghost: MediaItem
        let yearA: SightsAndSoundsKit.Tag
        let yearB: SightsAndSoundsKit.Tag

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-service-writing-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("a".utf8).write(to: root.appendingPathComponent("a.mp4"))
            try Data("b".utf8).write(to: root.appendingPathComponent("b.mp4"))
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Writing")
            let source = Source(name: "Here", rootPath: root.path)
            let year = TagCategory(name: "Year", allowMultiple: false)
            let yearA = SightsAndSoundsKit.Tag(tagCategoryID: year.id, name: "1995")
            let yearB = SightsAndSoundsKit.Tag(tagCategoryID: year.id, name: "1996")
            let a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: true)
            let b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", needsReview: true)
            // A row whose file is not on disk.
            let ghost = MediaItem(sourceID: source.id, kind: .video, relativePath: "ghost.mp4", needsReview: true)
            try await library.writer.write { db in
                try source.insert(db)
                try year.insert(db)
                try yearA.insert(db)
                try yearB.insert(db)
                for item in [a, b, ghost] { try item.insert(db) }
            }
            self.library = library
            self.source = source
            self.a = a
            self.b = b
            self.ghost = ghost
            self.yearA = yearA
            self.yearB = yearB
            service = LocalLibraryService(library: library, runner: JobRunner(library: library))
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        func tagIDs(of item: MediaItem) throws -> [UUID] {
            try library.writer.read { db in
                try UUID.fetchAll(
                    db, sql: "SELECT tagID FROM mediaItemTag WHERE mediaItemID = ?", arguments: [item.id])
            }
        }

        func row(_ item: MediaItem) throws -> MediaItem {
            try #require(try library.writer.read { try MediaItem.fetchOne($0, key: item.id) })
        }

        func sourceRow() throws -> Source {
            try #require(try library.writer.read { try Source.fetchOne($0, key: source.id) })
        }
    }

    /// The window's copy of a source can be behind the database's. The
    /// app used to write its whole copy back, and a rename undid whatever
    /// had changed since.
    @Test func renamingASourceChangesOnlyItsName() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try await f.library.writer.write { db in
            try db.execute(sql: "UPDATE source SET enabled = 0 WHERE id = ?", arguments: [f.source.id])
        }
        try await f.service.renameSource(f.source.id, to: "  Shows  ")
        let row = try f.sourceRow()
        #expect(row.name == "Shows")
        #expect(row.enabled == false, "the rename wrote back a stale copy of the row")
    }

    @Test func anEmptySourceNameIsRefused() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        await #expect(throws: ServiceError.emptyName) {
            try await f.service.renameSource(f.source.id, to: "   ")
        }
        #expect(try f.sourceRow().name == "Here")
    }

    @Test func enablingASourceChangesOnlyThat() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try await f.library.writer.write { db in
            try db.execute(sql: "UPDATE source SET name = 'Renamed' WHERE id = ?", arguments: [f.source.id])
        }
        try await f.service.setSourceEnabled(f.source.id, false)
        let row = try f.sourceRow()
        #expect(row.enabled == false)
        #expect(row.name == "Renamed", "the switch wrote back a stale copy of the row")
    }

    @Test func addingASourceThatIsAlreadyOneIsRefused() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        await #expect(throws: SourceError.self) {
            _ = try await f.service.addSource(named: "Again", rootPath: f.source.rootPath)
        }
        let other = f.root.deletingLastPathComponent()
            .appendingPathComponent("sas-service-writing-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let added = try await f.service.addSource(named: "Other", rootPath: other.path)
        #expect(added.name == "Other")
        #expect(try f.library.sources().count == 2)
    }

    @Test func savedFiltersAreSavedUpdatedRenamedAndDeleted() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let saved = try await f.service.saveFilter(named: "One", MediaFilter())
        var narrowed = MediaFilter()
        narrowed.searchText = "a"
        try await f.service.updateSavedFilter(saved.id, to: narrowed)
        try await f.service.renameSavedFilter(saved.id, to: "Two")
        #expect(try f.library.savedFilters().map(\.name) == ["Two"])
        #expect(try f.library.savedFilters().first?.filter == narrowed)
        try await f.service.deleteSavedFilter(saved.id)
        #expect(try f.library.savedFilters().isEmpty)
    }

    @Test func aSingleSelectCategoryStillReplacesWhenTaggedThroughTheService() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try await f.service.assignTag(f.yearA.id, to: [f.a.id, f.b.id])
        try await f.service.assignTag(f.yearB.id, to: [f.a.id])
        #expect(try f.tagIDs(of: f.a) == [f.yearB.id])
        #expect(try f.tagIDs(of: f.b) == [f.yearA.id])
        try await f.service.removeTag(f.yearA.id, from: [f.a.id, f.b.id])
        #expect(try f.tagIDs(of: f.a) == [f.yearB.id])
        #expect(try f.tagIDs(of: f.b).isEmpty)
    }

    @Test func flagsAreSetForEveryItemNamed() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try await f.service.setFavorite([f.a.id, f.b.id], true)
        try await f.service.setNeedsReview([f.a.id], false)
        #expect(try f.row(f.a).isFavorite && f.row(f.b).isFavorite)
        #expect(try !f.row(f.ghost).isFavorite)
        #expect(try !f.row(f.a).needsReview)
        #expect(try f.row(f.b).needsReview)
    }

    @Test func stagingReportsTheItemsItCouldNotStageAndStagesTheRest() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        // One with its file, one whose file is gone (flagged, not moved:
        // the library's rule), and one that is no longer in the library.
        let removed = UUID()
        let failures = try await f.service.setStaging(
            .toDelete, on: true, itemIDs: [f.a.id, removed, f.ghost.id])
        #expect(failures == [StagingFailure(itemID: removed, reason: "\(MoveError.itemNotFound)")])
        #expect(try f.row(f.ghost).markedForDeletion)
        #expect(try f.row(f.ghost).relativePath == "ghost.mp4")
        #expect(try f.row(f.a).markedForDeletion)
        #expect(FileManager.default.fileExists(
            atPath: f.root.appendingPathComponent(try f.row(f.a).relativePath).path))
        #expect(try f.row(f.a).relativePath.hasPrefix(StagingFolder.toDelete.rawValue + "/"))

        // And back out again.
        #expect(try await f.service.setStaging(.toDelete, on: false, itemIDs: [f.a.id]).isEmpty)
        #expect(try !f.row(f.a).markedForDeletion)
        #expect(try f.row(f.a).relativePath == "a.mp4")
    }

    @Test func aStagingFolderSurvivesEncodingAndDecoding() throws {
        for folder in [StagingFolder.toDelete, .playbackIssue] {
            #expect(try JSONDecoder().decode(StagingFolder.self, from: JSONEncoder().encode(folder)) == folder)
        }
    }
}
