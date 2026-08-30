import AVFoundation
import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 7b against real synthesized media: clip authoring + the partial
/// path-unique index, stream-copied clip export, remux with
/// archive-before-write.
@Suite struct OperationsTests {

    struct OpsFixture {
        let library: LibraryDatabase
        let runner: JobRunner
        let source: Source
        let root: URL
        let parent: MediaItem

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-ops-\(UUID().uuidString)", isDirectory: true)
            try await DemoMediaFactory.writeVideo(
                to: root.appendingPathComponent("shows/long.mp4"), seconds: 6, variant: 2)

            let lib = try LibraryDatabase.openInMemory()
            try lib.ensureInfo(name: "Ops")
            let src = Source(name: "Root", rootPath: root.path)
            try await lib.writer.write { try src.insert($0) }
            library = lib
            source = src
            runner = JobRunner(library: lib)
            await runner.register(ClipExportJob.self)
            await runner.register(RemuxJob.self)

            let probe = await MediaProbe.probe(url: root.appendingPathComponent("shows/long.mp4"))
            let size = (try? LiveFileAccess().fileSize(at: root.appendingPathComponent("shows/long.mp4"))) ?? 0
            let item = MediaItem(
                sourceID: src.id, kind: .video, relativePath: "shows/long.mp4",
                fileSize: size, durationSeconds: probe.durationSeconds,
                videoCodec: probe.videoCodec, needsReview: false)
            try await lib.writer.write { try item.insert($0) }
            parent = item
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        func job(_ id: UUID) async throws -> JobRecord {
            try await library.writer.read { try JobRecord.fetchOne($0, key: id)! }
        }
    }

    // MARK: Clip authoring

    @Test func clipsShareTheParentsPathViaThePartialIndex() async throws {
        let f = try await OpsFixture()
        defer { f.tearDown() }

        let clip = try f.library.createEmbeddedClip(
            parentID: f.parent.id, name: "encore", startSeconds: 1, endSeconds: 3)
        #expect(clip.relativePath == f.parent.relativePath)  // same path, allowed
        #expect(clip.isClip && clip.parentMediaItemID == f.parent.id)

        // A second clip on the same parent also shares the path.
        _ = try f.library.createEmbeddedClip(
            parentID: f.parent.id, name: "opener", startSeconds: 0, endSeconds: 1)
        #expect(try f.library.clips(of: f.parent.id).count == 2)

        // Real files at the same path stay refused.
        let dupe = MediaItem(sourceID: f.source.id, kind: .video, relativePath: "shows/long.mp4")
        await #expect(throws: (any Error).self) {
            try await f.library.writer.write { try dupe.insert($0) }
        }

        // Guards: nesting and reversed ranges refuse.
        #expect(throws: (any Error).self) {
            try f.library.createEmbeddedClip(
                parentID: clip.id, name: "nested", startSeconds: 0, endSeconds: 1)
        }
        #expect(throws: (any Error).self) {
            try f.library.createEmbeddedClip(
                parentID: f.parent.id, name: "reversed", startSeconds: 3, endSeconds: 1)
        }
    }

    @Test func clipResolvesToTheParentsFile() async throws {
        let f = try await OpsFixture()
        defer { f.tearDown() }
        let clip = try f.library.createEmbeddedClip(
            parentID: f.parent.id, name: "encore", startSeconds: 1, endSeconds: 3)
        let url = try f.library.resolvedFileURL(for: clip)
        #expect(url?.lastPathComponent == "long.mp4")
    }

    // MARK: Clip export

    @Test func clipExportProducesAStandaloneFileWithBreadcrumbs() async throws {
        let f = try await OpsFixture()
        defer { f.tearDown() }
        let clip = try f.library.createEmbeddedClip(
            parentID: f.parent.id, name: "encore", startSeconds: 1, endSeconds: 4)

        let record = try await ClipExportJob.enqueue(on: f.runner, clipID: clip.id)
        try await f.runner.runPending()
        let row = try await f.job(record.id)
        #expect(row.state == .succeeded)

        // The new standalone item: real file, roughly the clip's length.
        let exported = try await f.library.writer.read { db in
            try MediaItem.filter(sql: "isExportedClip = 1").fetchOne(db)
        }
        #expect(exported != nil)
        #expect(exported!.fileName.contains("encore"))
        #expect(FileManager.default.fileExists(
            atPath: f.root.appendingPathComponent(exported!.relativePath).path))
        #expect(abs((exported!.durationSeconds ?? 0) - 3.0) < 1.5)

        // Breadcrumbs: the clip row is spent but points at its export.
        let spent = try await f.library.writer.read { try MediaItem.fetchOne($0, key: clip.id)! }
        #expect(spent.clipExported)
        #expect(spent.exportedToMediaItemID == exported!.id)
        // Spent rows leave every listing (the phase-0 baseline predicate).
        let visible = try f.library.mediaItems(matching: MediaFilter(), kinds: .video)
        #expect(!visible.contains { $0.id == clip.id })
    }

    // MARK: Remux

    @Test func optimizeReplacesInPlaceWithArchive() async throws {
        let f = try await OpsFixture()
        defer { f.tearDown() }

        let record = try await RemuxJob.enqueue(on: f.runner, itemID: f.parent.id, mode: .optimize)
        try await f.runner.runPending()
        let row = try await f.job(record.id)
        #expect(row.state == .succeeded)
        #expect(row.summary?.contains("_Replaced/shows/long.mp4") == true)

        // The item's path is unchanged, the file is fresh, the original is
        // archived — never at risk.
        let updated = try await f.library.writer.read { try MediaItem.fetchOne($0, key: f.parent.id)! }
        #expect(updated.relativePath == "shows/long.mp4")
        #expect(FileManager.default.fileExists(
            atPath: f.root.appendingPathComponent("shows/long.mp4").path))
        #expect(FileManager.default.fileExists(
            atPath: f.root.appendingPathComponent("_Replaced/shows/long.mp4").path))

        // The replacement still plays: probe agrees on duration.
        let probe = await MediaProbe.probe(url: f.root.appendingPathComponent("shows/long.mp4"))
        #expect(abs((probe.durationSeconds ?? 0) - (updated.durationSeconds ?? 0)) < 2.0)
    }

    @Test func remuxRefusesClipsAndMissingFiles() async throws {
        let f = try await OpsFixture()
        defer { f.tearDown() }
        let clip = try f.library.createEmbeddedClip(
            parentID: f.parent.id, name: "c", startSeconds: 0, endSeconds: 1)

        let clipAttempt = try await RemuxJob.enqueue(on: f.runner, itemID: clip.id, mode: .repair)
        let ghost = MediaItem(sourceID: f.source.id, kind: .video, relativePath: "gone.mp4")
        try await f.library.writer.write { try ghost.insert($0) }
        let ghostAttempt = try await RemuxJob.enqueue(on: f.runner, itemID: ghost.id, mode: .repair)
        try await f.runner.runPending()

        #expect(try await f.job(clipAttempt.id).state == .failed)
        #expect(try await f.job(ghostAttempt.id).state == .failed)
        // The original untouched by either failure.
        #expect(FileManager.default.fileExists(
            atPath: f.root.appendingPathComponent("shows/long.mp4").path))
    }
}
