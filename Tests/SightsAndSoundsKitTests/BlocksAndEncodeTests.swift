import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 7c: segment math (pure), block CRUD, and the ffmpeg jobs —
/// which run end-to-end where ffmpeg exists and degrade to guidance
/// where it doesn't (CI has no ffmpeg; the jobs must handle that).
@Suite struct BlocksAndEncodeTests {

    // MARK: Segment math

    @Test func normalizedMergesOverlapsAndClamps() {
        let merged = SegmentMath.normalized(
            [(5, 10), (8, 12), (20, 25), (-3, 2), (24, 30), (40, 50)], duration: 28)
        #expect(merged.map { [$0.start, $0.end] } == [[0, 2], [5, 12], [20, 28]])
    }

    @Test func keepSegmentsAreTheComplement() {
        let keep = SegmentMath.keepSegments(duration: 30, hidden: [(5, 10), (20, 25)])
        #expect(keep.map { [$0.start, $0.end] } == [[0, 5], [10, 20], [25, 30]])
        // Block at the very start and very end.
        let edges = SegmentMath.keepSegments(duration: 30, hidden: [(0, 3), (27, 30)])
        #expect(edges.map { [$0.start, $0.end] } == [[3, 27]])
        // Everything hidden → nothing kept.
        #expect(SegmentMath.keepSegments(duration: 10, hidden: [(0, 10)]).isEmpty)
        // Nothing hidden → everything kept.
        #expect(SegmentMath.keepSegments(duration: 10, hidden: []).map { $0.end } == [10])
    }

    @Test func skipTargetJumpsOutOfHiddenRanges() {
        let hidden = [(5.0, 10.0), (20.0, 25.0)]
        #expect(SegmentMath.skipTarget(at: 3, hidden: hidden, duration: 30) == nil)
        #expect(SegmentMath.skipTarget(at: 7, hidden: hidden, duration: 30) == 10)
        #expect(SegmentMath.skipTarget(at: 24.9, hidden: hidden, duration: 30) == 25)
        #expect(SegmentMath.skipTarget(at: 10, hidden: hidden, duration: 30) == nil)  // boundary exits
    }

    @Test func filterGraphShape() {
        let graph = BlockRemovalJob.filterGraph(keep: [(0, 5), (10, 20)], hasAudio: true)
        #expect(graph.contains("trim=start=0.000:end=5.000"))
        #expect(graph.contains("atrim=start=10.000:end=20.000"))
        #expect(graph.contains("concat=n=2:v=1:a=1[v][a]"))
        let mute = BlockRemovalJob.filterGraph(keep: [(0, 5)], hasAudio: false)
        #expect(mute.contains("concat=n=1:v=1:a=0[v]"))
        #expect(!mute.contains("atrim"))
    }

    // MARK: Block CRUD

    @Test func blockCrudAndCascade() throws {
        let f = try FilterFixture()
        let block = try f.library.addBlock(to: f.show1995.id, startSeconds: 5, endSeconds: 10)
        _ = try f.library.addBlock(to: f.show1995.id, startSeconds: 20, endSeconds: 22, kind: .clip)
        #expect(try f.library.blocks(of: f.show1995.id).count == 2)

        #expect(throws: (any Error).self) {
            try f.library.addBlock(to: f.show1995.id, startSeconds: 9, endSeconds: 4)
        }

        try f.library.deleteBlock(block.id)
        #expect(try f.library.blocks(of: f.show1995.id).count == 1)

        // Deleting the item sweeps its blocks.
        try f.library.writer.write { db in
            try db.execute(sql: "DELETE FROM mediaItemTag WHERE mediaItemID = ?", arguments: [f.show1995.id])
            try db.execute(
                sql: "UPDATE mediaItem SET parentMediaItemID = NULL WHERE parentMediaItemID = ?",
                arguments: [f.show1995.id])
            _ = try MediaItem.deleteOne(db, key: f.show1995.id)
        }
        #expect(try f.library.blocks(of: f.show1995.id).isEmpty)
    }

    // MARK: ffmpeg jobs (end-to-end where the tool exists)

    struct FfmpegFixture {
        let library: LibraryDatabase
        let runner: JobRunner
        let root: URL
        let item: MediaItem

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-ffmpeg-\(UUID().uuidString)", isDirectory: true)
            try await DemoMediaFactory.writeVideo(
                to: root.appendingPathComponent("v.mp4"), seconds: 6, variant: 3)
            let lib = try LibraryDatabase.openInMemory()
            try lib.ensureInfo(name: "F")
            let src = Source(name: "R", rootPath: root.path)
            try await lib.writer.write { try src.insert($0) }
            let probe = await MediaProbe.probe(url: root.appendingPathComponent("v.mp4"))
            let media = MediaItem(
                sourceID: src.id, kind: .video, relativePath: "v.mp4",
                durationSeconds: probe.durationSeconds,
                audioStreamCount: probe.audioStreamCount, needsReview: false)
            try await lib.writer.write { try media.insert($0) }
            library = lib
            item = media
            runner = JobRunner(library: lib)
            await runner.register(EncodeJob.self)
            await runner.register(BlockRemovalJob.self)
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        func job(_ id: UUID) async throws -> JobRecord {
            try await library.writer.read { try JobRecord.fetchOne($0, key: id)! }
        }
    }

    @Test func encodeProducesANewItemOrGuidance() async throws {
        let f = try await FfmpegFixture()
        defer { f.tearDown() }
        let record = try await EncodeJob.enqueue(on: f.runner, itemID: f.item.id, preset: .h264)
        try await f.runner.runPending()
        let row = try await f.job(record.id)
        #expect(row.state == .succeeded)

        if FfmpegTool.path() == nil {
            #expect(row.summary?.contains("brew install ffmpeg") == true)
            return
        }
        let encoded = try await f.library.writer.read { db in
            try MediaItem.filter(sql: "relativePath LIKE '%h264%'").fetchOne(db)
        }
        #expect(encoded != nil)
        #expect(encoded!.videoCodec == "h264")
        #expect(abs((encoded!.durationSeconds ?? 0) - 6.0) < 1.0)
        // Additive: the original is untouched.
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("v.mp4").path))
    }

    @Test func blockRemovalCutsTheHiddenRange() async throws {
        let f = try await FfmpegFixture()
        defer { f.tearDown() }
        _ = try f.library.addBlock(to: f.item.id, startSeconds: 2, endSeconds: 4)

        let record = try await BlockRemovalJob.enqueue(on: f.runner, itemID: f.item.id)
        try await f.runner.runPending()
        let row = try await f.job(record.id)
        #expect(row.state == .succeeded)

        if FfmpegTool.path() == nil {
            #expect(row.summary?.contains("brew install ffmpeg") == true)
            return
        }
        let edited = try await f.library.writer.read { db in
            try MediaItem.filter(sql: "isEdited = 1").fetchOne(db)
        }
        #expect(edited != nil)
        // 6s minus the 2s hide ≈ 4s.
        #expect(abs((edited!.durationSeconds ?? 0) - 4.0) < 1.0)
        #expect(row.summary?.contains("2s removed") == true)
        // Original file and its blocks untouched.
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("v.mp4").path))
        #expect(try f.library.blocks(of: f.item.id).count == 1)
    }

    @Test func blockRemovalWithoutBlocksRefuses() async throws {
        let f = try await FfmpegFixture()
        defer { f.tearDown() }
        let record = try await BlockRemovalJob.enqueue(on: f.runner, itemID: f.item.id)
        try await f.runner.runPending()
        let row = try await f.job(record.id)
        if FfmpegTool.path() == nil {
            #expect(row.state == .succeeded)  // guidance note
        } else {
            #expect(row.state == .failed)
            #expect(row.error?.contains("no hide blocks") == true)
        }
    }
}
