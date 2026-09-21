import Foundation
import GRDB
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

        /// Purge in tests deletes outright: the default moves files to
        /// the Trash, and a test run must not fill the real one.
        static let deleting = LiveFileAccess(discarding: .permanently)

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

    // MARK: Segments follow their file

    /// A segment is a range inside its show's file, and carries that
    /// file's path so it lists in the same folder. When the show moved,
    /// only the show's row was updated: its songs stayed listed under the
    /// folder the show had left.
    @Test func aShowsSegmentsMoveWithItAndComeBackWithIt() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let show = try await f.addItem(path: "inbox/show.mp4")
        let song = try f.library.createEmbeddedClip(
            parentID: show.id, name: "Song", startSeconds: 0, endSeconds: 5, role: .song)

        let log = try f.library.moveFile(itemID: show.id, to: "shows/1995/show.mp4")
        var moved = try await f.reload(song.id)
        #expect(moved.relativePath == "shows/1995/show.mp4")
        #expect(moved.folderPath == "shows/1995")
        #expect(moved.fileName == "show.mp4")
        #expect(moved.notes == "Song")  // the segment's own name is untouched

        try f.library.revertMove(log.id)
        moved = try await f.reload(song.id)
        #expect(moved.relativePath == "inbox/show.mp4")
        #expect(moved.folderPath == "inbox")
    }

    @Test func stagingAShowTakesItsSegmentsPathsAlong() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let show = try await f.addItem(path: "shows/show.mp4")
        let song = try f.library.createEmbeddedClip(
            parentID: show.id, name: "Song", startSeconds: 0, endSeconds: 5, role: .song)

        try f.library.stage(.toDelete, itemID: show.id)
        #expect(try await f.reload(song.id).relativePath == "_ToDelete/shows/show.mp4")
        #expect(try await f.reload(song.id).markedForDeletion == false)  // only its path moved

        try f.library.unstage(.toDelete, itemID: show.id)
        #expect(try await f.reload(song.id).relativePath == "shows/show.mp4")
    }

    @Test func segmentsLeftBehindByEarlierMovesAreBroughtHome() async throws {
        // A library from before this fix: the show moved, its song did not.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-segment-heal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Old.sqlite")

        let queue = try DatabaseQueue(path: url.path)
        try LibraryDatabase.migrator.migrate(queue, upTo: "searchRecipe")
        let source = Source(name: "S", rootPath: "/tmp/sas-segment-heal-media")
        let show = MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/1995/show.mp4")
        let song = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "inbox/show.mp4",
            parentMediaItemID: show.id, clipStartSeconds: 0, clipEndSeconds: 5, isClip: true)
        try await queue.write { db in
            try source.insert(db)
            try show.insert(db)
            try song.insert(db)
        }
        try queue.close()

        let upgraded = try LibraryDatabase.open(at: url)
        let healed = try await upgraded.writer.read { try MediaItem.fetchOne($0, key: song.id)! }
        #expect(healed.relativePath == "shows/1995/show.mp4")
        #expect(healed.folderPath == "shows/1995")
        #expect(healed.fileName == "show.mp4")
        try upgraded.close()
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

        let outcome = try f.library.purgeDeleted(fileAccess: MoveFixture.deleting)
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

    // MARK: Purge goes to the Trash

    /// A stand-in Trash: a folder the test owns.
    private func trashingAccess(into trash: URL) -> LiveFileAccess {
        LiveFileAccess(discarding: .toTrash) { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
    }

    @Test func purgedFilesGoToTheTrashNotIntoThinAir() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let item = try await f.addItem(path: "shows/doomed.mp4")
        try f.library.stage(.toDelete, itemID: item.id)
        let trash = f.root.appendingPathComponent(".test-trash", isDirectory: true)

        let outcome = try f.library.purgeDeleted(fileAccess: trashingAccess(into: trash))

        #expect(outcome.filesDeleted == 1)
        #expect(outcome.filesTrashed == 1)
        #expect(!f.exists("_ToDelete/shows/doomed.mp4"))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("doomed.mp4").path))
    }

    /// Some volumes have no Trash (many network shares). The file still
    /// goes, and the outcome says it went for good.
    @Test func aVolumeWithNoTrashDeletesAndSaysSo() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let item = try await f.addItem(path: "shows/doomed.mp4")
        try f.library.stage(.toDelete, itemID: item.id)
        struct NoTrashHere: Error {}
        let noTrash = LiveFileAccess(discarding: .toTrash) { _ in throw NoTrashHere() }

        let outcome = try f.library.purgeDeleted(fileAccess: noTrash)

        #expect(outcome.filesDeleted == 1)
        #expect(outcome.filesTrashed == 0)
        #expect(!f.exists("_ToDelete/shows/doomed.mp4"))
    }

    // MARK: A show with segments

    /// A segment plays from its show's file. Until it has been saved as
    /// a file of its own, deleting the show would take it too — so the
    /// purge leaves that show alone and says why.
    @Test func aShowWithUnsavedSegmentsIsKeptAndThePurgeCarriesOn() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let show = try await f.addItem(path: "shows/1995/show.mp4")
        for start in [0.0, 10.0] {
            try f.library.createEmbeddedClip(
                parentID: show.id, name: "Song", startSeconds: start, endSeconds: start + 5, role: .song)
        }
        let plain = try await f.addItem(path: "shows/plain.mp4")
        try f.library.stage(.toDelete, itemID: show.id)
        try f.library.stage(.toDelete, itemID: plain.id)

        let outcome = try f.library.purgeDeleted(fileAccess: MoveFixture.deleting)

        #expect(outcome.keptForSegments == ["show.mp4: 2 segments are not saved as files"])
        #expect(outcome.filesDeleted == 1)  // the plain one
        #expect(outcome.rowsDeleted == 1)
        #expect(f.exists("_ToDelete/shows/1995/show.mp4"))
        #expect(!f.exists("_ToDelete/shows/plain.mp4"))
        let remaining = try await f.library.writer.read { try MediaItem.fetchCount($0) }
        #expect(remaining == 3)  // the show and both songs
    }

    @Test func aFlagOnlyShowWithOneSegmentIsKeptToo() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        // The file is already gone, so staging flags without moving and
        // the segment still shares the show's exact path — the case that
        // used to fail on the path-unique index.
        let show = try await f.addItem(path: "gone/show.mp4", withFile: false)
        try f.library.createEmbeddedClip(
            parentID: show.id, name: "Song", startSeconds: 0, endSeconds: 5, role: .song)
        try f.library.stage(.toDelete, itemID: show.id)

        let outcome = try f.library.purgeDeleted(fileAccess: MoveFixture.deleting)

        #expect(outcome.rowsDeleted == 0)
        #expect(outcome.keptForSegments.count == 1)
    }

    @Test func theDeleteListSaysWhichShowsStillHaveUnsavedSegments() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let show = try await f.addItem(path: "shows/show.mp4")
        let song = try f.library.createEmbeddedClip(
            parentID: show.id, name: "Song", startSeconds: 0, endSeconds: 5, role: .song)
        let unflagged = try await f.addItem(path: "shows/other.mp4")
        try f.library.createEmbeddedClip(
            parentID: unflagged.id, name: "Song", startSeconds: 0, endSeconds: 5, role: .song)
        try f.library.stage(.toDelete, itemID: show.id)

        let unsaved = try f.library.unsavedSegments(ofFlagged: nil)
        #expect(unsaved.map(\.parentID) == [show.id])
        #expect(unsaved.first?.segmentIDs == [song.id])
        // Narrowed to a reviewed subset, like the purge itself.
        #expect(try f.library.unsavedSegments(ofFlagged: [unflagged.id]).isEmpty)
    }

    @Test func onceItsSegmentsAreSavedTheShowPurges() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let show = try await f.addItem(path: "shows/show.mp4")
        let song = try f.library.createEmbeddedClip(
            parentID: show.id, name: "Song", startSeconds: 0, endSeconds: 5, role: .song)
        // What the export job leaves: a file of its own, and the segment
        // marked as the breadcrumb that points at it.
        let saved = try await f.addItem(path: "shows/show - Song.mp4")
        try await f.library.writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET clipExported = 1, exportedToMediaItemID = ? WHERE id = ?",
                arguments: [saved.id, song.id])
        }
        try f.library.stage(.toDelete, itemID: show.id)

        let outcome = try f.library.purgeDeleted(fileAccess: MoveFixture.deleting)

        #expect(outcome.keptForSegments.isEmpty)
        #expect(outcome.filesDeleted == 1)
        #expect(!f.exists("_ToDelete/shows/show.mp4"))
        // The saved song stays; the breadcrumb left with the timeline it marked.
        let remaining = try await f.library.writer.read { try MediaItem.fetchAll($0) }
        #expect(remaining.map(\.id) == [saved.id])
        #expect(f.exists("shows/show - Song.mp4"))
    }

    @Test func segmentsTheUserMarkedGoWithTheirShow() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let show = try await f.addItem(path: "shows/show.mp4")
        let song = try f.library.createEmbeddedClip(
            parentID: show.id, name: "Song", startSeconds: 0, endSeconds: 5, role: .song)
        // Marking the segment itself is the user saying it can go.
        try f.library.stage(.toDelete, itemID: show.id)
        try f.library.stage(.toDelete, itemID: song.id)

        let outcome = try f.library.purgeDeleted(fileAccess: MoveFixture.deleting)

        #expect(outcome.keptForSegments.isEmpty)
        #expect(outcome.rowsDeleted == 2)
        #expect(outcome.filesDeleted == 1)
    }

    @Test func aMarkedSegmentLeftOutOfTheReviewedSubsetStillLeavesCleanly() async throws {
        let f = try await MoveFixture()
        defer { f.tearDown() }
        let show = try await f.addItem(path: "shows/show.mp4")
        let song = try f.library.createEmbeddedClip(
            parentID: show.id, name: "Song", startSeconds: 0, endSeconds: 5, role: .song)
        try f.library.stage(.toDelete, itemID: show.id)
        try f.library.stage(.toDelete, itemID: song.id)

        // Only the show was ticked.
        let outcome = try f.library.purgeDeleted(itemIDs: [show.id], fileAccess: MoveFixture.deleting)

        #expect(outcome.rowFailures.isEmpty)
        #expect(outcome.filesDeleted == 1)
        let remaining = try await f.library.writer.read { try MediaItem.fetchCount($0) }
        #expect(remaining == 0)
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
