import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 7a against real files on disk: moves with the paper trail,
/// staging semantics, revert, purge.
@Suite struct MoveServiceTests {

    struct MoveFixture {
        let library: LibraryDatabase
        let source: Source
        let root: URL

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-moves-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("shows/1995"), withIntermediateDirectories: true)

            let lib = try LibraryDatabase.openInMemory()
            try lib.ensureInfo(name: "Moves")
            let src = Source(name: "Root", rootPath: root.path)
            try await lib.writer.write { try src.insert($0) }
            library = lib
            source = src
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func addItem(path: String, withFile: Bool = true, parent: UUID? = nil) async throws -> MediaItem {
            if withFile {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("media-\(path)".utf8).write(to: url)
            }
            let item = MediaItem(
                sourceID: source.id, kind: .video, relativePath: path,
                needsReview: true, parentMediaItemID: parent)
            try await library.writer.write { try item.insert($0) }
            return item
        }

        func reload(_ id: UUID) async throws -> MediaItem {
            try await library.writer.read { try MediaItem.fetchOne($0, key: id)! }
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }
    }

    @Test func moveUpdatesFileRowAndLog() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let item = try await f.addItem(path: "shows/1995/a.mp4")

        let log = try f.library.moveFile(itemID: item.id, to: "shows/renamed/b.mp4")
        #expect(f.exists("shows/renamed/b.mp4"))
        #expect(!f.exists("shows/1995/a.mp4"))

        let updated = try await f.reload(item.id)
        #expect(updated.relativePath == "shows/renamed/b.mp4")
        #expect(updated.folderPath == "shows/renamed")
        #expect(log.fromPath == "shows/1995/a.mp4")
        #expect(log.revertedAt == nil)
    }

    @Test func revertPutsEverythingBack() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let item = try await f.addItem(path: "shows/1995/a.mp4")
        let log = try f.library.moveFile(itemID: item.id, to: "elsewhere/a.mp4")

        try f.library.revertMove(log.id)
        #expect(f.exists("shows/1995/a.mp4"))
        #expect(!f.exists("elsewhere/a.mp4"))
        #expect(try await f.reload(item.id).relativePath == "shows/1995/a.mp4")

        // One-shot: a second revert is refused.
        #expect(throws: (any Error).self) { try f.library.revertMove(log.id) }
    }

    @Test func collisionGetsATimestampSuffixNeverOverwrites() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let item = try await f.addItem(path: "shows/1995/a.mp4")
        _ = try await f.addItem(path: "target/a.mp4")  // occupies the destination

        let log = try f.library.moveFile(itemID: item.id, to: "target/a.mp4")
        #expect(log.toPath != "target/a.mp4")
        #expect(log.toPath.hasPrefix("target/a-"))
        #expect(f.exists("target/a.mp4"))  // untouched
        #expect(f.exists(log.toPath))
    }

    @Test func stagingMovesFlagsAndUnstagesCleanly() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let item = try await f.addItem(path: "shows/1995/a.mp4")

        try f.library.stage(.toDelete, itemID: item.id)
        var staged = try await f.reload(item.id)
        #expect(staged.markedForDeletion)
        #expect(!staged.needsReview)
        #expect(staged.relativePath == "_ToDelete/shows/1995/a.mp4")
        #expect(f.exists("_ToDelete/shows/1995/a.mp4"))

        try f.library.unstage(.toDelete, itemID: item.id)
        staged = try await f.reload(item.id)
        #expect(!staged.markedForDeletion)
        #expect(staged.relativePath == "shows/1995/a.mp4")
        #expect(f.exists("shows/1995/a.mp4"))
    }

    @Test func embeddedClipsAndMissingFilesFlagWithoutMoving() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let parent = try await f.addItem(path: "shows/1995/a.mp4")
        let clip = try await f.addItem(path: "shows/1995/a.mp4#clip", withFile: false, parent: parent.id)
        let ghost = try await f.addItem(path: "gone/b.mp4", withFile: false)

        try f.library.stage(.toDelete, itemID: clip.id)
        let stagedClip = try await f.reload(clip.id)
        #expect(stagedClip.markedForDeletion)
        #expect(stagedClip.relativePath.hasPrefix("shows/"))  // unmoved

        try f.library.stage(.toDelete, itemID: ghost.id)
        let stagedGhost = try await f.reload(ghost.id)
        #expect(stagedGhost.markedForDeletion)
        #expect(stagedGhost.relativePath == "gone/b.mp4")  // unmoved, honestly flagged
    }

    @Test func decideStagesTheLoserPhysically() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let keeper = try await f.addItem(path: "shows/keep.mp4")
        let loser = try await f.addItem(path: "shows/lose.mp4")
        let candidate = DuplicateCandidate(itemA: keeper.id, itemB: loser.id, source: .manual)
        try await f.library.writer.write { try candidate.insert($0) }

        let outcome = try f.library.decide(
            keeper: keeper.id, loser: loser.id, candidateID: candidate.id, mergeTagIDs: [])
        #expect(outcome.stagingWarning == nil)
        #expect(f.exists("_ToDelete/shows/lose.mp4"))
        #expect(try await f.reload(loser.id).relativePath == "_ToDelete/shows/lose.mp4")
    }

    @Test func purgeDeletesOnlyFlaggedAndReportsHonestly() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let doomed = try await f.addItem(path: "shows/doomed.mp4")
        let doomedClip = try await f.addItem(path: "clips/x", withFile: false, parent: doomed.id)
        let survivor = try await f.addItem(path: "shows/survivor.mp4")

        try f.library.stage(.toDelete, itemID: doomed.id)
        try f.library.stage(.toDelete, itemID: doomedClip.id)

        let outcome = try f.library.purgeDeleted()
        #expect(outcome.rowsDeleted == 2)
        #expect(outcome.filesDeleted == 1)  // the clip has no file of its own
        #expect(outcome.fileFailures.isEmpty)
        #expect(!f.exists("_ToDelete/shows/doomed.mp4"))
        #expect(f.exists("shows/survivor.mp4"))

        let remaining = try await f.library.writer.read { try MediaItem.fetchAll($0) }
        #expect(remaining.map(\.id) == [survivor.id])
        // The move log survives the purge, labeled by snapshot.
        let logs = try f.library.moveLogs()
        #expect(logs.contains { $0.fileName == "doomed.mp4" })
    }

    @Test func movedFilesDoNotReimportAsDuplicates() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let item = try await f.addItem(path: "shows/1995/a.mp4")
        try f.library.stage(.toDelete, itemID: item.id)

        // Import again: the staged file's path matches its (moved) row.
        let runner = JobRunner(library: f.library)
        await runner.register(ImportJob.self)
        let record = try await ImportJob.enqueue(on: runner, sourceID: f.source.id)
        try await runner.runPending()
        let row = try await f.library.writer.read { try JobRecord.fetchOne($0, key: record.id)! }
        #expect(row.summary == "0 new, 1 already imported")
    }
}
