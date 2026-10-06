import Foundation
import GRDB

/// The Review window: duplicate pairs waiting for a decision, the delete
/// list, and items that will not play, with the repairs queued for them.
public protocol ReviewManaging: Sendable {
    /// Everything the window lists, as one answer.
    func reviewLists() async throws -> ReviewLists

    // MARK: Duplicates

    /// The loser's tags the keeper does not already have: what a
    /// decision can carry over.
    func mergeableTags(keeperID: UUID, loserID: UUID) async throws -> [Tag]

    /// Keep one of a pair: its chosen tags are carried over and the
    /// other is marked for deletion.
    func decideDuplicate(
        keeperID: UUID, loserID: UUID, candidateID: UUID?, mergeTagIDs: Set<UUID>
    ) async throws -> DecideOutcome

    func rejectDuplicate(candidateID: UUID) async throws
    func keepBothDuplicates(candidateID: UUID) async throws

    // MARK: The delete list

    /// Of the items marked for deletion — these, or with nil all of
    /// them — the videos that still have segments not saved as files.
    func unsavedSegmentsOfMarked(itemIDs: [UUID]?) async throws -> [LibraryDatabase.UnsavedSegments]

    /// Delete the marked items' files, to the Trash where the volume
    /// has one, and take the items out of the library. Of these items,
    /// those that are marked; or with nil, every marked item.
    func purgeMarked(itemIDs: [UUID]?) async throws -> LibraryDatabase.PurgeOutcome

    // MARK: Playback issues

    /// What was recorded when an item was found not to play.
    func playbackIssueEvidence(itemID: UUID) async throws -> PlaybackIssueEvidence?

    /// Queue a repair of an item by a recipe, and start the queue.
    @discardableResult
    func queueRepair(itemID: UUID, recipe: RepairRecipe) async throws -> JobRecord

    /// The items with a repair queued or running, and whether the queue
    /// is paused. With `startingQueue`, a queue that has repairs waiting
    /// and is not running is started: one queued before the app last
    /// quit otherwise waits for something unrelated to start it.
    func repairQueue(startingQueue: Bool) async throws -> RepairQueue
}

public struct ReviewLists: Codable, Equatable, Sendable {
    public var candidates: [DuplicateCandidate]
    /// The items the candidates name, by id.
    public var candidateItems: [UUID: MediaItem]
    /// Marked for deletion, by path.
    public var deleteList: [MediaItem]
    /// Flagged as not playing, by path.
    public var issues: [MediaItem]
    /// What deleting the whole delete list would free.
    public var reclaimableBytes: Int64

    public init(
        candidates: [DuplicateCandidate], candidateItems: [UUID: MediaItem], deleteList: [MediaItem],
        issues: [MediaItem], reclaimableBytes: Int64
    ) {
        self.candidates = candidates
        self.candidateItems = candidateItems
        self.deleteList = deleteList
        self.issues = issues
        self.reclaimableBytes = reclaimableBytes
    }
}

public struct RepairQueue: Codable, Equatable, Sendable {
    public var pending: Set<UUID>
    public var isPaused: Bool

    public init(pending: Set<UUID>, isPaused: Bool) {
        self.pending = pending
        self.isPaused = isPaused
    }
}

// MARK: - On this Mac

extension LocalLibraryService {
    public func reviewLists() async throws -> ReviewLists {
        let candidates = try library.pendingCandidates()
        let ids = Array(Set(candidates.flatMap { [$0.itemAID, $0.itemBID] }))
        let (items, marked, flagged) = try await library.read { db in
            (
                Dictionary(uniqueKeysWithValues: try MediaItem.fetchAll(db, keys: ids).map { ($0.id, $0) }),
                try MediaItem.filter(sql: "markedForDeletion = 1").order(sql: "relativePath").fetchAll(db),
                try MediaItem.filter(sql: "playbackIssue = 1").order(sql: "relativePath").fetchAll(db)
            )
        }
        return ReviewLists(
            candidates: candidates, candidateItems: items, deleteList: marked, issues: flagged,
            // A stat of every staged file: a figure that could not be
            // had is nothing to free, not a failure of the whole list.
            reclaimableBytes: (try? library.reclaimableBytes()) ?? 0)
    }

    public func mergeableTags(keeperID: UUID, loserID: UUID) async throws -> [Tag] {
        try library.mergeableTags(keeper: keeperID, loser: loserID)
    }

    public func decideDuplicate(
        keeperID: UUID, loserID: UUID, candidateID: UUID?, mergeTagIDs: Set<UUID>
    ) async throws -> DecideOutcome {
        try library.decide(
            keeper: keeperID, loser: loserID, candidateID: candidateID, mergeTagIDs: mergeTagIDs,
            fileAccess: fileAccess)
    }

    public func rejectDuplicate(candidateID: UUID) async throws {
        try library.rejectCandidate(candidateID)
    }

    public func keepBothDuplicates(candidateID: UUID) async throws {
        try library.keepBothCandidate(candidateID)
    }

    public func unsavedSegmentsOfMarked(itemIDs: [UUID]?) async throws -> [LibraryDatabase.UnsavedSegments] {
        try library.unsavedSegments(ofFlagged: itemIDs)
    }

    public func purgeMarked(itemIDs: [UUID]?) async throws -> LibraryDatabase.PurgeOutcome {
        try library.purgeDeleted(itemIDs: itemIDs, fileAccess: fileAccess)
    }

    public func playbackIssueEvidence(itemID: UUID) async throws -> PlaybackIssueEvidence? {
        try library.playbackIssueEvidence(of: itemID)
    }

    public func queueRepair(itemID: UUID, recipe: RepairRecipe) async throws -> JobRecord {
        guard let runner else { throw ServiceError.noJobRunner }
        let job = try await RepairJob.enqueue(on: runner, itemID: itemID, recipe: recipe)
        await runner.startDraining()
        return job
    }

    public func repairQueue(startingQueue: Bool) async throws -> RepairQueue {
        let pending = try library.currentPendingRepairItems()
        guard let runner else { return RepairQueue(pending: pending, isPaused: false) }
        // Joins a drain under way; a paused runner stays paused, its
        // drain starts nothing.
        if startingQueue, !pending.isEmpty { await runner.startDraining() }
        return RepairQueue(pending: pending, isPaused: await runner.isPaused)
    }
}
