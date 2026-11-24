import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// Hashing is a library's choice, and Verify Integrity checks each file
/// against the hash stored when it was first hashed.
@Suite struct IntegrityCheckTests {
    struct Fixture {
        let library: LibraryDatabase
        let runner: JobRunner
        let root: URL
        let items: [MediaItem]

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-integrity-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Integrity")
            let source = Source(name: "Root", rootPath: root.path)
            var made: [MediaItem] = []
            for name in ["a.mp4", "b.mp4", "c.mp4"] {
                let bytes = Data("the bytes of \(name)".utf8)
                try bytes.write(to: root.appendingPathComponent(name))
                made.append(MediaItem(
                    sourceID: source.id, kind: .video, relativePath: name, fileSize: Int64(bytes.count)))
            }
            try await library.writer.write { [made] db in
                try source.insert(db)
                for item in made { try item.insert(db) }
            }
            self.library = library
            self.items = made
            runner = JobRunner(library: library)
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        func run(_ type: any Job.Type) async throws -> JobRecord? {
            let id = try await runner.enqueue(type).id
            try await runner.runPending()
            return try await library.read { try JobRecord.fetchOne($0, key: id) }
        }
    }

    @Test func aChangedFileAndAnUnreadableOneAreReportedAndTheRestVerified() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let hashing = try await f.run(ContentHashJob.self)
        #expect(hashing?.summary == "3 hashed")
        #expect(try f.library.integrityStatus() == SweepStatus(missing: 3, failed: 0))

        // b's bytes change behind the app's back; c cannot be read.
        try Data("rotted".utf8).write(to: f.root.appendingPathComponent("b.mp4"))
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("c.mp4"))
        let check = try await f.run(IntegrityCheckJob.self)
        #expect(check?.state == .succeeded)
        #expect(check?.summary == "1 verified, 1 changed (b.mp4), 1 unreadable")
        #expect(try f.library.integrityStatus() == SweepStatus(missing: 0, failed: 2))
        let failures = try f.library.integrityFailures()
        #expect(failures.map(\.item.relativePath) == ["b.mp4", "c.mp4"])
        #expect(failures[0].check.actualHash != nil && failures[1].check.actualHash == nil)

        // The stored hash is the reference: a check never replaces it.
        let stored = try await f.library.read {
            try String.fetchOne($0, sql: "SELECT contentHash FROM mediaItem WHERE relativePath = 'b.mp4'")
        }
        #expect(stored != nil && stored != failures[0].check.actualHash)

        // Verify again checks nothing new; Retry Failed checks the two
        // again; Recalculate All reads every hashed file again.
        let again = try await f.run(IntegrityCheckJob.self)
        #expect(again?.summary == "0 verified")
        try f.library.retryIntegrityFailures()
        #expect(try f.library.integrityStatus() == SweepStatus(missing: 2, failed: 0))
        try f.library.resetIntegrityChecks()
        #expect(try f.library.integrityStatus() == SweepStatus(missing: 3, failed: 0))
    }

    /// Recalculating the hashes makes new references, so the checks made
    /// against the old ones go too.
    @Test func recalculatingTheHashesForgetsTheChecks() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        _ = try await f.run(ContentHashJob.self)
        _ = try await f.run(IntegrityCheckJob.self)
        #expect(try await f.library.read { try IntegrityCheck.fetchCount($0) } == 3)
        try f.library.resetContentHashes()
        #expect(try await f.library.read { try IntegrityCheck.fetchCount($0) } == 0)
    }

    @Test func hashingIsOffUnlessChosenAndHomeVideosChoosesIt() throws {
        #expect(LibraryTemplate.homeVideos.plan(named: "H").hashesFiles == true)
        for template in LibraryTemplate.allCases where template != .homeVideos {
            #expect(template.plan(named: "x").hashesFiles != true, "\(template)")
        }
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Off")
        #expect(try !library.hashesFiles())
        try library.setHashesFiles(true)
        #expect(try library.hashesFiles())
        #expect(try library.info()?.hashesFiles == true)
    }

    /// Turned on from Library Properties, the files not hashed yet are
    /// queued for hashing at once.
    @Test func turningHashingOnQueuesTheHashing() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "On")
        let runner = JobRunner(library: library, paused: true)
        let service = LocalLibraryService(library: library, runner: runner)
        try await service.setHashesFiles(false)
        #expect(try await library.read { try JobRecord.fetchCount($0) } == 0)
        try await service.setHashesFiles(true)
        let kinds = try await library.read { try JobRecord.fetchAll($0) }.map(\.kind)
        #expect(kinds == [ContentHashJob.kind])
    }
}
