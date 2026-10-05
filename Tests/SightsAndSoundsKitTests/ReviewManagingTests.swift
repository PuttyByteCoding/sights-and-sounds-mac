import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The Review window's reads and decisions, as asked of the library's
/// service. Files are deleted for good here, never to the real Trash.
@Suite struct ReviewManagingTests {
    typealias Tag = SightsAndSoundsKit.Tag

    struct Fixture {
        let root: URL
        let library: LibraryDatabase
        let service: LocalLibraryService
        let source: Source
        let band: TagCategory
        let alpha: Tag
        let a: MediaItem
        let b: MediaItem
        let c: MediaItem
        let pair: DuplicateCandidate

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-review-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["a.mp4", "b.mp4", "c.mp4"] {
                try Data(repeating: 7, count: 1_000).write(to: root.appendingPathComponent(name))
            }
            library = try LibraryDatabase.openInMemory()
            service = LocalLibraryService(library: library, fileAccess: LiveFileAccess(discarding: .permanently))
            source = Source(name: "Here", rootPath: root.path)
            band = TagCategory(name: "Band", sortOrder: 0)
            alpha = Tag(tagCategoryID: band.id, name: "Alpha")
            a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", fileSize: 1_000)
            b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", fileSize: 1_000)
            c = MediaItem(sourceID: source.id, kind: .video, relativePath: "c.mp4", fileSize: 1_000)
            pair = DuplicateCandidate(itemA: a.id, itemB: b.id, source: .contentHash, confidence: 1)
            try library.writer.write { [source, band, alpha, a, b, c, pair] db in
                try source.insert(db)
                try band.insert(db)
                try alpha.insert(db)
                for row in [a, b, c] { try row.insert(db) }
                try pair.insert(db)
            }
            try library.assignTag(alpha.id, to: [b.id])
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }

        func item(_ id: UUID) throws -> MediaItem? { try library.writer.read { try MediaItem.fetchOne($0, key: id) } }
    }

    @Test func theListsAreOneAnswer() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let lists = try await f.service.reviewLists()
        #expect(lists.candidates.map(\.id) == [f.pair.id])
        #expect(Set(lists.candidateItems.keys) == [f.a.id, f.b.id])
        #expect(lists.deleteList.isEmpty && lists.issues.isEmpty)
        #expect(lists.reclaimableBytes == 0)

        #expect(try await f.service.setStaging(.toDelete, on: true, itemIDs: [f.c.id]).isEmpty)
        try await f.library.writer.write { db in
            try db.execute(sql: "UPDATE mediaItem SET playbackIssue = 1 WHERE id = ?", arguments: [f.a.id])
        }
        let after = try await f.service.reviewLists()
        #expect(after.deleteList.map(\.id) == [f.c.id])
        #expect(after.issues.map(\.id) == [f.a.id])
        #expect(after.reclaimableBytes == 1_000)
        #expect(after.candidates.map(\.id) == [f.pair.id])
    }

    // MARK: - Duplicates

    @Test func keepingOneCarriesTheChosenTagsAndMarksTheOther() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.mergeableTags(keeperID: f.a.id, loserID: f.b.id).map(\.id) == [f.alpha.id])
        #expect(try await f.service.mergeableTags(keeperID: f.b.id, loserID: f.a.id).isEmpty)

        let outcome = try await f.service.decideDuplicate(
            keeperID: f.a.id, loserID: f.b.id, candidateID: f.pair.id, mergeTagIDs: [f.alpha.id])
        #expect(outcome.tagsMerged == 1)
        #expect(outcome.stagingWarning == nil, "\(outcome.stagingWarning ?? "")")
        #expect(try f.item(f.b.id)?.markedForDeletion == true)
        #expect(try f.item(f.a.id)?.markedForDeletion == false)
        let lists = try await f.service.reviewLists()
        #expect(lists.candidates.isEmpty)
        #expect(lists.deleteList.map(\.id) == [f.b.id])
        // The outcome crosses to another Mac as it is.
        #expect(try JSONDecoder().decode(DecideOutcome.self, from: JSONEncoder().encode(outcome)) == outcome)
    }

    @Test func aPairSaidNotToBeDuplicatesOrKeptWholeLeavesTheList() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try await f.service.rejectDuplicate(candidateID: f.pair.id)
        #expect(try await f.service.reviewLists().candidates.isEmpty)
        #expect(try f.item(f.b.id)?.markedForDeletion == false)

        let other = DuplicateCandidate(itemA: f.a.id, itemB: f.c.id, source: .contentHash, confidence: 1)
        try await f.library.writer.write { try other.insert($0) }
        try await f.service.keepBothDuplicates(candidateID: other.id)
        #expect(try await f.service.reviewLists().candidates.isEmpty)
        #expect(try f.item(f.c.id)?.markedForDeletion == false)
    }

    // MARK: - The delete list

    @Test func purgingDeletesOnlyWhatWasNamedAndSaysWhatItDid() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.setStaging(.toDelete, on: true, itemIDs: [f.a.id, f.c.id]).isEmpty)
        #expect(try await f.service.unsavedSegmentsOfMarked(itemIDs: [f.a.id, f.c.id]).isEmpty)

        let outcome = try await f.service.purgeMarked(itemIDs: [f.a.id])
        #expect(outcome.rowsDeleted == 1 && outcome.filesDeleted == 1)
        #expect(outcome.fileFailures.isEmpty && outcome.rowFailures.isEmpty && outcome.keptForSegments.isEmpty)
        #expect(try f.item(f.a.id) == nil)
        #expect(try f.item(f.c.id)?.markedForDeletion == true, "an item not named was purged")
        #expect(f.exists("b.mp4"))
        // Naming one that is not marked deletes nothing.
        let none = try await f.service.purgeMarked(itemIDs: [f.b.id])
        #expect(none.rowsDeleted == 0 && none.filesDeleted == 0)
        #expect(f.exists("b.mp4"))
        #expect(try JSONDecoder().decode(
            LibraryDatabase.PurgeOutcome.self, from: JSONEncoder().encode(outcome)) == outcome)
    }

    /// A marked video with a segment nobody has saved: the window is
    /// told before anything is deleted, and the purge leaves it alone.
    @Test func aMarkedVideoWithUnsavedSegmentsIsSaidAndKept() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let song = try f.library.createEmbeddedClip(
            parentID: f.a.id, name: "Song", startSeconds: 1, endSeconds: 2, role: .song)
        #expect(try await f.service.setStaging(.toDelete, on: true, itemIDs: [f.a.id]).isEmpty)

        let unsaved = try await f.service.unsavedSegmentsOfMarked(itemIDs: [f.a.id])
        #expect(unsaved.map(\.parentID) == [f.a.id])
        #expect(unsaved.first?.segmentIDs == [song.id])
        #expect(try await f.service.unsavedSegmentsOfMarked(itemIDs: nil) == unsaved, "nil is every marked item")

        let outcome = try await f.service.purgeMarked(itemIDs: [f.a.id])
        #expect(outcome.rowsDeleted == 0)
        #expect(outcome.keptForSegments.count == 1)
        #expect(try f.item(f.a.id) != nil)
    }

    // MARK: - Playback issues

    @Test func anItemWithNoRecordedFailureHasNoEvidence() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.playbackIssueEvidence(itemID: f.a.id) == nil)
        #expect(try await f.service.playbackIssueEvidence(itemID: UUID()) == nil)
    }

    @Test func aServiceWithoutARunnerStillSaysWhatIsPending() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.repairQueue(startingQueue: true) == RepairQueue(pending: [], isPaused: false))
    }
}
