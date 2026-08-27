import CryptoKit
import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 5b: the background workers — content hashing and thumbnail
/// sweeps — plus the signal-driven enqueue dedupe.
@Suite struct WorkerTests {

    struct WorkerFixture {
        let library: LibraryDatabase
        let runner: JobRunner
        let source: Source
        let root: URL
        let libraryID = UUID()

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-workers-\(UUID().uuidString)", isDirectory: true)
            try await DemoMediaFactory.writeVideo(
                to: root.appendingPathComponent("a.mp4"), seconds: 2, variant: 1)
            try DemoMediaFactory.writeAudio(
                to: root.appendingPathComponent("b.m4a"), seconds: 2, variant: 1)

            let lib = try LibraryDatabase.openInMemory()
            try lib.ensureInfo(name: "Workers")
            let src = Source(name: "Root", rootPath: root.path)
            try await lib.writer.write { try src.insert($0) }
            library = lib
            source = src
            runner = JobRunner(library: lib)
            await runner.register(ImportJob.self)
            await runner.register(ContentHashJob.self)
            await runner.register(ThumbnailBatchJob.self)
        }

        func importAll() async throws {
            _ = try await ImportJob.enqueue(on: runner, sourceID: source.id)
            try await runner.runPending()
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(
                at: ThumbnailStore.root.appendingPathComponent(libraryID.uuidString))
        }

        var items: [MediaItem] {
            get async throws {
                try await library.writer.read { try MediaItem.order(sql: "relativePath").fetchAll($0) }
            }
        }
    }

    // MARK: Pause

    @Test func pausedRunnerHoldsTheQueueAndResumingDrainsIt() async throws {
        let f = try await WorkerFixture()
        defer { f.tearDown() }

        await f.runner.setPaused(true)
        let job = try await ImportJob.enqueue(on: f.runner, sourceID: f.source.id)
        let settled = try await f.runner.runPending()
        #expect(settled.isEmpty)
        let held = try await f.library.writer.read { try JobRecord.fetchOne($0, key: job.id)! }
        #expect(held.state == .queued)  // pause is not cancel — the job waits

        await f.runner.setPaused(false)
        let drained = try await f.runner.runPending()
        #expect(drained == [job.id])
        let done = try await f.library.writer.read { try JobRecord.fetchOne($0, key: job.id)! }
        #expect(done.state == .succeeded)
    }

    // MARK: Content hashing

    @Test func hashSweepComputesRealMD5AndSkipsHashed() async throws {
        let f = try await WorkerFixture()
        defer { f.tearDown() }
        try await f.importAll()

        let job = try await f.runner.enqueue(ContentHashJob.self)
        try await f.runner.runPending()
        let row = try await f.library.writer.read { try JobRecord.fetchOne($0, key: job.id)! }
        #expect(row.state == .succeeded)
        #expect(row.summary == "2 hashed")

        // The stored hash equals an independently computed MD5.
        let items = try await f.items
        let fileData = try Data(contentsOf: f.root.appendingPathComponent("a.mp4"))
        let expected = Insecure.MD5.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        #expect(items[0].contentHash == expected)
        #expect(items[1].contentHash != nil)

        // Second sweep finds nothing to do.
        let second = try await f.runner.enqueue(ContentHashJob.self)
        try await f.runner.runPending()
        let secondRow = try await f.library.writer.read { try JobRecord.fetchOne($0, key: second.id)! }
        #expect(secondRow.summary == "0 hashed")
    }

    @Test func hashFailureIsRecordedAndSweepContinues() async throws {
        let f = try await WorkerFixture()
        defer { f.tearDown() }
        try await f.importAll()
        // An item whose file vanished after import.
        let ghost = MediaItem(sourceID: f.source.id, kind: .video, relativePath: "gone.mp4")
        try await f.library.writer.write { try ghost.insert($0) }

        let job = try await f.runner.enqueue(ContentHashJob.self)
        try await f.runner.runPending()
        let row = try await f.library.writer.read { try JobRecord.fetchOne($0, key: job.id)! }
        #expect(row.state == .succeeded)  // per-item failure never fails the sweep
        #expect(row.summary == "2 hashed, 1 failed")

        let failure = try await f.library.writer.read {
            try ContentHashFailure.fetchOne($0, key: ghost.id)
        }
        #expect(failure != nil)

        // The failure row stops re-tries on the next sweep.
        let second = try await f.runner.enqueue(ContentHashJob.self)
        try await f.runner.runPending()
        let secondRow = try await f.library.writer.read { try JobRecord.fetchOne($0, key: second.id)! }
        #expect(secondRow.summary == "0 hashed")
    }

    // MARK: Thumbnail sweep

    @Test func thumbnailSweepGeneratesFromDiskStateAndSelfHeals() async throws {
        let f = try await WorkerFixture()
        defer { f.tearDown() }
        try await f.importAll()

        func sweep() async throws -> JobRecord {
            let job = try await f.runner.enqueue(
                ThumbnailBatchJob.self,
                payload: JSONEncoder().encode(ThumbnailBatchJob.Payload(libraryID: f.libraryID)))
            try await f.runner.runPending()
            return try await f.library.writer.read { try JobRecord.fetchOne($0, key: job.id)! }
        }

        let first = try await sweep()
        #expect(first.summary == "1 generated")  // video only; audio has no frames

        let items = try await f.items
        let videoID = items.first { $0.kind == .video }!.id
        let thumbURL = ThumbnailStore.url(libraryID: f.libraryID, itemID: videoID)
        #expect(FileManager.default.fileExists(atPath: thumbURL.path))
        let state = try await f.library.writer.read { try ThumbnailState.fetchOne($0, key: videoID) }
        #expect(state?.generated == true)

        // Disk state decides: file present → nothing to do…
        #expect(try await sweep().summary == "0 generated")
        // …file deleted → regenerated, even though the DB row says done.
        try FileManager.default.removeItem(at: thumbURL)
        #expect(try await sweep().summary == "1 generated")
        #expect(FileManager.default.fileExists(atPath: thumbURL.path))
    }

    // MARK: Signal dedupe

    @Test func enqueueUnlessPendingCollapsesSignals() async throws {
        let f = try await WorkerFixture()
        defer { f.tearDown() }

        let first = try await f.runner.enqueueUnlessPending(ContentHashJob.self)
        #expect(first != nil)
        // Signal again before the queue drains: no duplicate.
        let second = try await f.runner.enqueueUnlessPending(ContentHashJob.self)
        #expect(second == nil)

        try await f.runner.runPending()
        // Queue drained: the next signal enqueues again.
        let third = try await f.runner.enqueueUnlessPending(ContentHashJob.self)
        #expect(third != nil)
    }
}
