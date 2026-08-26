import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 8b: online backup round-trips, backup verification, and the
/// validation sweep's three finding kinds with their fixes.
@Suite struct BackupValidationTests {

    @Test func backupRoundTripsAndVerifies() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A real on-disk library with content.
        let library = try LibraryDatabase.open(at: dir.appendingPathComponent("Live.sqlite"))
        try library.ensureInfo(name: "Concerts")
        let source = Source(name: "S", rootPath: "/tmp/x")
        let category = TagCategory(name: "Band")
        try await library.writer.write { db in
            try source.insert(db)
            try category.insert(db)
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4").insert(db)
        }

        let backupsDir = dir.appendingPathComponent("Backups")
        let backupURL = try library.backup(into: backupsDir)
        #expect(backupURL.path.contains("Concerts backup"))

        // The backup opens, migrates, and carries the content.
        let info = try LibraryDatabase.verifyBackup(at: backupURL)
        #expect(info?.name == "Concerts")
        let restored = try LibraryDatabase.open(at: backupURL)
        #expect(try await restored.writer.read { try MediaItem.fetchCount($0) } == 1)
        #expect(try await restored.writer.read { try TagCategory.fetchCount($0) } == 1)
        try restored.close()

        // The live library kept working through it all.
        try await library.writer.write { db in
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4").insert(db)
        }
        #expect(try await library.writer.read { try MediaItem.fetchCount($0) } == 2)
        // …and the backup is unaffected by later writes.
        let again = try LibraryDatabase.open(at: backupURL)
        #expect(try await again.writer.read { try MediaItem.fetchCount($0) } == 1)
        try again.close()
        try library.close()
    }

    @Test func verifyRefusesGarbage() throws {
        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-junk-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: junk) }
        try Data("not a database".utf8).write(to: junk)
        #expect(throws: (any Error).self) {
            try LibraryDatabase.verifyBackup(at: junk)
        }
    }

    @Test func validationFindsAllThreeKindsAndFixesWork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-validate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("shows"), withIntermediateDirectories: true)

        // healthy: row + file agree. ghost: row, no file. orphan: file, no
        // row. shrunk: row + file disagree on size.
        try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("shows/healthy.mp4"))
        try Data(repeating: 2, count: 50).write(to: root.appendingPathComponent("shows/orphan.mp4"))
        try Data(repeating: 3, count: 10).write(to: root.appendingPathComponent("shows/shrunk.mp4"))

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "V")
        let source = Source(name: "S", rootPath: root.path)
        let healthy = MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/healthy.mp4", fileSize: 100)
        let ghost = MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/ghost.mp4", fileSize: 5)
        let shrunk = MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/shrunk.mp4", fileSize: 999)
        try await library.writer.write { db in
            try source.insert(db)
            for item in [healthy, ghost, shrunk] { try item.insert(db) }
        }

        let runner = JobRunner(library: library)
        await runner.register(ValidationJob.self)
        _ = try await runner.enqueue(ValidationJob.self)
        try await runner.runPending()

        let findings = try library.validationFindings()
        #expect(findings.count == 3)
        #expect(findings.first { $0.kind == .missingFile }?.path == "shows/ghost.mp4")
        #expect(findings.first { $0.kind == .orphanFile }?.path == "shows/orphan.mp4")
        #expect(findings.first { $0.kind == .sizeMismatch }?.path == "shows/shrunk.mp4")

        // Fix the mismatch: disk wins, hash clears, finding leaves.
        try library.acceptDiskSize(for: shrunk.id)
        let fixed = try await library.writer.read { try MediaItem.fetchOne($0, key: shrunk.id)! }
        #expect(fixed.fileSize == 10)
        #expect(fixed.contentHash == nil)
        #expect(try library.validationFindings().count == 2)

        // A rerun replaces findings (mismatch stays gone; the others remain).
        _ = try await runner.enqueue(ValidationJob.self)
        try await runner.runPending()
        let rerun = try library.validationFindings()
        #expect(rerun.count == 2)
        #expect(!rerun.contains { $0.kind == .sizeMismatch })
    }

    @Test func offlineSourcesAreSkippedWhole() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "V")
        let gone = Source(name: "Gone", rootPath: "/Volumes/Nope-\(UUID())")
        try await library.writer.write { db in
            try gone.insert(db)
            try MediaItem(sourceID: gone.id, kind: .video, relativePath: "x.mp4").insert(db)
        }
        let runner = JobRunner(library: library)
        await runner.register(ValidationJob.self)
        let record = try await runner.enqueue(ValidationJob.self)
        try await runner.runPending()

        // Absence of a drive is not absence of files: zero findings.
        #expect(try library.validationFindings().isEmpty)
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: record.id)! }
        #expect(row.summary?.contains("1 offline sources skipped") == true)
    }
}
