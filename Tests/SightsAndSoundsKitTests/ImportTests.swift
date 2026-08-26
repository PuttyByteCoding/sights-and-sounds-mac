import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 5a: directory scan + import against real synthesized files —
/// discovery, probing, idempotence, the serialized queue, offline refusal.
@Suite struct ImportTests {

    /// A source folder on disk with generated media and decoys, plus a
    /// library wired to it.
    struct ImportFixture {
        let library: LibraryDatabase
        let runner: JobRunner
        let source: Source
        let root: URL

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-import-\(UUID().uuidString)", isDirectory: true)
            try await DemoMediaFactory.writeVideo(
                to: root.appendingPathComponent("shows/1995/d1t01.mp4"), seconds: 2, variant: 1)
            try await DemoMediaFactory.writeVideo(
                to: root.appendingPathComponent("shows/1995/disc2/d2t01.mp4"), seconds: 2, variant: 2)
            try DemoMediaFactory.writeAudio(
                to: root.appendingPathComponent("audio/t01.m4a"), seconds: 2, variant: 1)
            // Decoys the importer must ignore.
            try "not media".write(
                to: root.appendingPathComponent("shows/1995/info.txt"),
                atomically: true, encoding: .utf8)
            try "{}".write(
                to: root.appendingPathComponent("shows/1995/metadata.json"),
                atomically: true, encoding: .utf8)

            let lib = try LibraryDatabase.openInMemory()
            try lib.ensureInfo(name: "Import Test")
            let src = Source(name: "Root", rootPath: root.path)
            try await lib.writer.write { try src.insert($0) }
            library = lib
            source = src
            runner = JobRunner(library: lib)
            await runner.register(ImportJob.self)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func runImport() async throws -> JobRecord {
            let record = try await ImportJob.enqueue(on: runner, sourceID: source.id)
            try await runner.runPending()
            return try await library.writer.read { try JobRecord.fetchOne($0, key: record.id)! }
        }

        var items: [MediaItem] {
            get throws {
                try library.writer.read { try MediaItem.order(sql: "relativePath").fetchAll($0) }
            }
        }
    }

    @Test func importDiscoversProbesAndInserts() async throws {
        let f = try await ImportFixture()
        defer { f.tearDown() }

        let job = try await f.runImport()
        #expect(job.state == .succeeded)
        #expect(job.summary == "3 new, 0 already imported")
        #expect(job.progressTotal == 3)

        let items = try f.items
        #expect(items.map(\.relativePath) == [
            "audio/t01.m4a", "shows/1995/d1t01.mp4", "shows/1995/disc2/d2t01.mp4",
        ])
        let video = items[1]
        #expect(video.kind == .video)
        #expect(video.folderPath == "shows/1995")
        #expect(video.fileSize > 0)
        #expect(video.needsReview)
        // Probe results from the real file.
        #expect(abs((video.durationSeconds ?? 0) - 2.0) < 0.5)
        #expect(video.width == 320 && video.height == 180)
        #expect(video.videoCodec == "h264")

        let audio = items[0]
        #expect(audio.kind == .audio)
        #expect(audio.audioCodec == "aac")
        #expect(audio.sampleRate == 44_100)

        // Source stamped as seen.
        let seen = try await f.library.writer.read { try Source.fetchOne($0, key: f.source.id)?.lastSeenAt }
        #expect(seen != nil)
    }

    @Test func reimportIsIdempotentAndFindsOnlyNewFiles() async throws {
        let f = try await ImportFixture()
        defer { f.tearDown() }
        _ = try await f.runImport()

        let second = try await f.runImport()
        #expect(second.summary == "0 new, 3 already imported")
        #expect(try f.items.count == 3)

        try DemoMediaFactory.writeAudio(
            to: f.root.appendingPathComponent("audio/t02.m4a"), seconds: 2, variant: 3)
        let third = try await f.runImport()
        #expect(third.summary == "1 new, 3 already imported")
        #expect(try f.items.count == 4)
    }

    @Test func serializedQueueRunsBackToBack() async throws {
        let f = try await ImportFixture()
        defer { f.tearDown() }

        // Two imports enqueued before the drain: the runner serializes, the
        // second sees the first's rows — no duplicates, no interleaving.
        let first = try await ImportJob.enqueue(on: f.runner, sourceID: f.source.id)
        let second = try await ImportJob.enqueue(on: f.runner, sourceID: f.source.id)
        try await f.runner.runPending()

        let rows = try await f.library.writer.read { db in
            (try JobRecord.fetchOne(db, key: first.id)!, try JobRecord.fetchOne(db, key: second.id)!)
        }
        #expect(rows.0.state == .succeeded && rows.1.state == .succeeded)
        #expect(rows.0.summary == "3 new, 0 already imported")
        #expect(rows.1.summary == "0 new, 3 already imported")
        #expect(try f.items.count == 3)
    }

    @Test func offlineAndDisabledSourcesRefuseClearly() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "T")
        let gone = Source(name: "Gone", rootPath: "/Volumes/DoesNotExist-\(UUID())")
        try await library.writer.write { try gone.insert($0) }
        let runner = JobRunner(library: library)
        await runner.register(ImportJob.self)

        let offline = try await ImportJob.enqueue(on: runner, sourceID: gone.id)
        try await runner.runPending()
        let offlineRow = try await library.writer.read { try JobRecord.fetchOne($0, key: offline.id)! }
        #expect(offlineRow.state == .failed)
        #expect(offlineRow.error?.contains("offline") == true)

        try await library.writer.write { db in
            var off = gone
            off.enabled = false
            try off.update(db)
        }
        let disabled = try await ImportJob.enqueue(on: runner, sourceID: gone.id)
        try await runner.runPending()
        let disabledRow = try await library.writer.read { try JobRecord.fetchOne($0, key: disabled.id)! }
        #expect(disabledRow.error?.contains("disabled") == true)
    }

    @Test func extensionKindMapping() {
        #expect(MediaProbe.kind(forExtension: "MP4") == .video)
        #expect(MediaProbe.kind(forExtension: "flac") == .audio)
        #expect(MediaProbe.kind(forExtension: "mkv") == .video)  // odd container still imports
        #expect(MediaProbe.kind(forExtension: "txt") == nil)
        #expect(MediaProbe.kind(forExtension: "json") == nil)
        #expect(MediaProbe.kind(forExtension: "") == nil)
    }
}
