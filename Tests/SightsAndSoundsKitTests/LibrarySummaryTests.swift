import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// The picker's row summary: counted from the library, cached in the
/// registry, so opening the app does not mean opening every library file
/// and waking every drive.
@Suite struct LibrarySummaryTests {

    /// Build a small library with a source, vocabulary, two top-level
    /// items and one embedded clip.
    private func seededLibrary() throws -> LibraryDatabase {
        let library = try LibraryDatabase.openInMemory()
        let source = Source(name: "Main", rootPath: "/Volumes/Media/Concerts")
        let band = TagCategory(name: "Band")
        let parent = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "a.mp4",
            fileSize: 1_000, needsReview: false)
        let second = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "b.mp4",
            fileSize: 2_500, needsReview: false)
        // An embedded clip: a row of its own, but its bytes live inside
        // its parent's file.
        let clip = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "a.mp4",
            fileSize: 9_999, needsReview: false, parentMediaItemID: parent.id)

        try library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
            try Tag(tagCategoryID: band.id, name: "Band A").insert(db)
            try Tag(tagCategoryID: band.id, name: "Band B").insert(db)
            try parent.insert(db)
            try second.insert(db)
            try clip.insert(db)
        }
        return library
    }

    @Test func summaryCountsTopLevelItemsAndTheirBytes() throws {
        let summary = try seededLibrary().summary()

        // The clip is a row but not an item on disk — counting it would
        // both inflate the count and double-count its parent's bytes.
        #expect(summary.itemCount == 2)
        #expect(summary.totalBytes == 3_500)
        #expect(summary.sourceCount == 1)
        #expect(summary.categoryCount == 1)
        #expect(summary.tagCount == 2)
    }

    @Test func cachedSummarySurvivesARegistryRefresh() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = try AppDatabase.openInMemory()
        let library = try LibraryDatabase.open(at: dir.appendingPathComponent("Concerts.sqlite"))
        try library.ensureInfo(name: "Concerts")
        let ref = try app.register(library)

        // Nothing is known until a library has been closed once — which is
        // not the same as a library that is genuinely empty.
        #expect(ref.summary == nil)

        let captured = LibrarySummary(
            itemCount: 9_847, totalBytes: 41_700_000_000, sourceCount: 3,
            categoryCount: 6, tagCount: 693)
        try app.cacheSummary(captured, for: ref.id)

        let reread = try #require(try app.libraries().first)
        let summary = try #require(reread.summary)
        #expect(summary.itemCount == 9_847)
        #expect(summary.totalBytes == 41_700_000_000)
        #expect(summary.sourceCount == 3)
        #expect(summary.categoryCount == 6)
        #expect(summary.tagCount == 693)
    }

    /// Re-registering happens whenever a library file is opened from a new
    /// path. It must not wipe the counts the picker is about to draw.
    @Test func reRegisteringKeepsTheCachedSummary() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = try AppDatabase.openInMemory()
        let url = dir.appendingPathComponent("Concerts.sqlite")
        let library = try LibraryDatabase.open(at: url)
        try library.ensureInfo(name: "Concerts")
        let ref = try app.register(library)
        try app.cacheSummary(
            LibrarySummary(
                itemCount: 12, totalBytes: 340, sourceCount: 1,
                categoryCount: 2, tagCount: 5),
            for: ref.id)

        try library.close()
        let movedURL = dir.appendingPathComponent("Moved.sqlite")
        try FileManager.default.moveItem(at: url, to: movedURL)
        try app.register(try LibraryDatabase.open(at: movedURL))

        let reread = try #require(try app.libraries().first)
        #expect(reread.filePath == movedURL.path)
        #expect(reread.summary?.itemCount == 12)
    }

    /// A library forgotten while its window was still open still gets a
    /// summary write when that window goes away. It has nowhere to land,
    /// and that is not a failure.
    @Test func cachingASummaryForAnUnknownLibraryIsHarmless() throws {
        let app = try AppDatabase.openInMemory()
        try app.cacheSummary(
            LibrarySummary(
                itemCount: 1, totalBytes: 1, sourceCount: 1,
                categoryCount: 1, tagCount: 1),
            for: UUID())
        #expect(try app.libraries().isEmpty)
    }
}
