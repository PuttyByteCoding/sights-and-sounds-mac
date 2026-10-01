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

    /// Answers "cancelled?" from a script, one answer per question, and
    /// counts the questions.
    private actor CancelScript {
        private var answers: [Bool]
        private(set) var asked = 0
        init(_ answers: [Bool]) { self.answers = answers }
        func next() -> Bool {
            asked += 1
            return answers.isEmpty ? true : answers.removeFirst()
        }
    }

    /// A clip export writes the new file beside its show, and it used to
    /// write it THERE from the first byte: a failed export, or a quit or
    /// cancel mid-way, left a partial .mp4 in the library folder for the
    /// next scan to import. It could not be cancelled either. It now
    /// writes in a working folder on the same volume and moves the file
    /// into place only once it is whole — and a cancelled run leaves
    /// nothing behind.
    ///
    /// Cancelled before the export starts, and cancelled while it runs
    /// (the export itself cannot be interrupted, so that is honoured once
    /// it is done — after the file is written, before it is moved in).
    /// Either way nothing reaches the library: the second case is the one
    /// that proves the export writes aside, and it failed when the export
    /// wrote straight into the show's folder.
    @Test(arguments: [[true], [false, true]])
    func aCancelledClipExportLeavesNothingInTheLibrary(_ answers: [Bool]) async throws {
        let f = try await OpsFixture()
        defer { f.tearDown() }
        let clip = try f.library.createEmbeddedClip(
            parentID: f.parent.id, name: "encore", startSeconds: 1, endSeconds: 4)
        let job = try ClipExportJob(payload: JSONEncoder().encode(ClipExportJob.Payload(clipID: clip.id)))
        let script = CancelScript(answers)
        let context = JobContext(
            library: f.library, jobID: UUID(), progressHandler: { _, _ in },
            cancellationCheck: { await script.next() }, summaryHandler: { _ in })

        await #expect(throws: CancellationError.self) { try await job.run(context) }

        #expect(await script.asked == answers.count, "cancellation was not asked where expected")
        let files = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("shows").path)
        #expect(files == ["long.mp4"])
        let exported = try await f.library.writer.read { db in
            try MediaItem.filter(sql: "isExportedClip = 1").fetchCount(db)
        }
        #expect(exported == 0)
    }

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

    /// A replaced file is new bytes. Keeping the old hash told the
    /// duplicate sweep the changed file was still byte-identical to its
    /// old twin — the pair offered for deletion at full confidence.
    private func stampOldHash(_ f: OpsFixture) async throws {
        try await f.library.writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET contentHash = 'old-bytes' WHERE id = ?",
                arguments: [f.parent.id])
            try ContentHashFailure(mediaItemID: f.parent.id, message: "an earlier timeout").insert(db)
            // Swept: its embedded metadata was read off the old bytes.
            try MetadataSweepState(mediaItemID: f.parent.id, failureMessage: nil).insert(db)
            // And paired, unreviewed, with a byte-identical twin.
            let twin = MediaItem(
                sourceID: f.parent.sourceID, kind: .video, relativePath: "shows/twin.mp4",
                fileSize: 1, contentHash: "old-bytes", needsReview: false)
            try twin.insert(db)
            try DuplicateCandidate(itemA: f.parent.id, itemB: twin.id, source: .contentHash, confidence: 1).insert(db)
            // Pairs that must survive: one somebody answered (it blocks
            // re-flagging for good), and one matched by sound, which a
            // change of bytes keeps.
            let answered = MediaItem(
                sourceID: f.parent.sourceID, kind: .video, relativePath: "shows/answered.mp4",
                fileSize: 1, contentHash: "old-bytes", needsReview: false)
            let soundAlike = MediaItem(
                sourceID: f.parent.sourceID, kind: .video, relativePath: "shows/sound-alike.mp4",
                fileSize: 1, needsReview: false)
            try answered.insert(db)
            try soundAlike.insert(db)
            var rejected = DuplicateCandidate(itemA: f.parent.id, itemB: answered.id, source: .contentHash, confidence: 1)
            rejected.status = .rejected
            try rejected.insert(db)
            try DuplicateCandidate(itemA: f.parent.id, itemB: soundAlike.id, source: .fingerprint, confidence: 0.9).insert(db)
        }
        // Failed to fingerprint and to thumbnail — the old bytes did.
        try await f.library.writer.write { db in
            try FingerprintFailure(mediaItemID: f.parent.id, message: "fpcalc could not decode").insert(db)
            try ThumbnailState(mediaItemID: f.parent.id, generated: false, failureMessage: "no frame").upsert(db)
        }
        // Examined: Media Signal read the old file's declarations and timing.
        var findings = SignalFindings()
        findings.declare("video.codecTag", "avc1")
        findings.measure("timing.frameCount", 10)
        try f.library.recordSignalStage(itemID: f.parent.id, stage: "declared", version: 1, findings: findings)
    }

    private func hashState(_ f: OpsFixture) async throws -> (hash: String?, failures: Int, swept: Bool, twinPairs: Int, kept: Int, signalRows: Int, failureMarks: Int) {
        try await f.library.writer.read { db in
            let item = try MediaItem.fetchOne(db, key: f.parent.id)!
            let failures = try ContentHashFailure
                .filter(sql: "mediaItemID = ?", arguments: [f.parent.id]).fetchCount(db)
            let swept = try MetadataSweepState.fetchOne(db, key: f.parent.id) != nil
            let twinPairs = try DuplicateCandidate
                .filter(sql: "status = 'pending' AND source = 'contentHash' AND (itemAID = ? OR itemBID = ?)",
                        arguments: [f.parent.id, f.parent.id])
                .fetchCount(db)
            let kept = try DuplicateCandidate
                .filter(sql: "(status <> 'pending' OR source <> 'contentHash') AND (itemAID = ? OR itemBID = ?)",
                        arguments: [f.parent.id, f.parent.id])
                .fetchCount(db)
            var signalRows = 0
            for table in ["mediaSignalStage", "mediaSignalDeclared", "mediaSignalMeasurement"] {
                signalRows += try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(table) WHERE mediaItemID = ?", arguments: [f.parent.id]) ?? 0
            }
            let failureMarks = try FingerprintFailure.filter(key: f.parent.id).fetchCount(db)
                + ThumbnailState.filter(sql: "mediaItemID = ? AND failureMessage IS NOT NULL", arguments: [f.parent.id]).fetchCount(db)
            return (item.contentHash, failures, swept, twinPairs, kept, signalRows, failureMarks)
        }
    }

    @Test func aRemuxedFileForgetsTheOldFilesHash() async throws {
        let f = try await OpsFixture()
        defer { f.tearDown() }
        try await stampOldHash(f)

        let record = try await RemuxJob.enqueue(on: f.runner, itemID: f.parent.id, mode: .optimize)
        try await f.runner.runPending()
        #expect(try await f.job(record.id).state == .succeeded)

        let state = try await hashState(f)
        #expect(state.hash == nil)
        #expect(state.failures == 0)
        #expect(!state.swept, "the metadata read off the old bytes still counts as swept")
        #expect(state.twinPairs == 0, "still offered as byte-identical to its old twin")
        #expect(state.kept == 2, "an answered pair or a sound-matched pair was dropped too")
        #expect(state.signalRows > 0, "a stream copy threw away Media Signal's readings of the same streams")
        #expect(state.failureMarks == 0, "the old file's fingerprint or thumbnail failure still blocks the new one")
    }

    @Test func aRepairedFileForgetsTheOldFilesHash() async throws {
        let f = try await OpsFixture()
        defer { f.tearDown() }
        await f.runner.register(RepairJob.self)
        try await stampOldHash(f)

        let record = try await RepairJob.enqueue(
            on: f.runner, itemID: f.parent.id, recipe: RepairRecipe.shipped[0])
        try await f.runner.runPending()
        #expect(try await f.job(record.id).state == .succeeded)

        let state = try await hashState(f)
        #expect(state.hash == nil)
        #expect(state.failures == 0)
        #expect(!state.swept, "the metadata read off the old bytes still counts as swept")
        #expect(state.twinPairs == 0, "still offered as byte-identical to its old twin")
        #expect(state.kept == 2, "an answered pair or a sound-matched pair was dropped too")
        #expect(state.signalRows == 0, "Media Signal still describes the old file")
        #expect(state.failureMarks == 0, "the old file's fingerprint or thumbnail failure still blocks the new one")
    }

    /// The repair swaps the file first, then puts the flagged file back
    /// out of the playback-issues folder. That put-back can fail — here a
    /// new file already sits at the original path — and the row used to
    /// be updated only AFTER it, so a failure left the repaired file
    /// described by the OLD file's hash, and the duplicate sweep paired
    /// it with its old twin as byte-identical.
    @Test func aRepairWhosePutBackFailsStillForgetsTheOldHash() async throws {
        let f = try await OpsFixture()
        defer { f.tearDown() }
        await f.runner.register(RepairJob.self)
        try f.library.stage(.playbackIssue, itemID: f.parent.id)
        try await stampOldHash(f)
        // Something new at the original path blocks the put-back.
        try Data("squatter".utf8).write(to: f.root.appendingPathComponent("shows/long.mp4"))

        let record = try await RepairJob.enqueue(
            on: f.runner, itemID: f.parent.id, recipe: RepairRecipe.shipped[0])
        try await f.runner.runPending()
        // The repair happened; only the put-back did not. A failed job
        // invited a retry that would repair the repaired file again, and
        // said nothing about where it was left.
        let job = try await f.job(record.id)
        #expect(job.state == .succeeded, "\(job.error ?? "")")
        #expect(job.summary?.contains("could not be moved back") == true, "\(job.summary ?? "")")

        let state = try await hashState(f)
        #expect(state.hash == nil)
        #expect(state.failures == 0)
        #expect(!state.swept, "the metadata read off the old bytes still counts as swept")
        #expect(state.twinPairs == 0, "still offered as byte-identical to its old twin")
        #expect(state.kept == 2, "an answered pair or a sound-matched pair was dropped too")
        #expect(state.signalRows == 0, "Media Signal still describes the old file")
        #expect(state.failureMarks == 0, "the old file's fingerprint or thumbnail failure still blocks the new one")
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
