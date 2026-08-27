import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// The other two Phase 0 proofs: the migration mechanism works against real
/// files, and two libraries open at once are structurally isolated.
@Suite struct LibraryStoreTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func migrationsApplyAndPersist() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Concerts.sqlite")

        let first = try LibraryDatabase.open(at: url)
        #expect(try first.appliedMigrations() == ["phase0", "phase1", "phase2", "phase4", "phase5", "phase6", "phase7", "phase7b", "phase7c", "phase7d", "phase8", "phase8b", "extensionOverrides"])
        let category = TagCategory(name: "Band")
        try first.writer.write { try category.insert($0) }

        // Reopen the same file: migrations recognized, data intact.
        let second = try LibraryDatabase.open(at: url)
        #expect(try second.appliedMigrations() == ["phase0", "phase1", "phase2", "phase4", "phase5", "phase6", "phase7", "phase7b", "phase7c", "phase7d", "phase8", "phase8b", "extensionOverrides"])
        let reread = try second.writer.read { try TagCategory.fetchOne($0) }
        #expect(reread == category)
    }

    @Test func twoLibrariesOpenAtOnceCannotSeeEachOther() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let concerts = try LibraryDatabase.open(at: dir.appendingPathComponent("Concerts.sqlite"))
        let learning = try LibraryDatabase.open(at: dir.appendingPathComponent("Learning.sqlite"))

        // Distinct vocabularies, written while both are open.
        let bandCat = TagCategory(name: "Band")
        let subjectCat = TagCategory(name: "Subject")
        let concertSource = Source(name: "Shows", rootPath: "/Volumes/Media/Shows")
        let courseSource = Source(name: "Courses", rootPath: "/Volumes/Media/Courses")
        let concert = MediaItem(sourceID: concertSource.id, kind: .video, relativePath: "shows/x.mp4")
        let lesson = MediaItem(sourceID: courseSource.id, kind: .video, relativePath: "swift/lesson-01.mp4")
        try concerts.writer.write { db in
            try bandCat.insert(db)
            try concertSource.insert(db)
            try concert.insert(db)
        }
        try learning.writer.write { db in
            try subjectCat.insert(db)
            try courseSource.insert(db)
            try lesson.insert(db)
        }

        // Each library sees exactly its own rows — by id, not just by count.
        let concertsSees = try concerts.writer.read { try MediaItem.fetchAll($0).map(\.id) }
        let learningSees = try learning.writer.read { try MediaItem.fetchAll($0).map(\.id) }
        #expect(concertsSees == [concert.id])
        #expect(learningSees == [lesson.id])
        #expect(try concerts.writer.read { try TagCategory.fetchAll($0).map(\.name) } == ["Band"])
        #expect(try learning.writer.read { try TagCategory.fetchAll($0).map(\.name) } == ["Subject"])

        // And the filter surface is scoped the same way.
        let concertNames = try concerts.mediaItems(matching: MediaFilter(), kind: .video).map(\.fileName)
        #expect(concertNames == ["x.mp4"])
    }

    @Test func mediaPathTripletStaysInLockstep() throws {
        var item = MediaItem(sourceID: UUID(), kind: .video, relativePath: "a\\b//c.mp4")
        #expect(item.relativePath == "a/b/c.mp4")
        #expect(item.folderPath == "a/b")
        #expect(item.fileName == "c.mp4")

        item.setRelativePath("root.mp4")
        #expect(item.folderPath == "")
        #expect(item.fileName == "root.mp4")
    }
}
