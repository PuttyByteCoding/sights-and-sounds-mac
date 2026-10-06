import Foundation

/// The Organise window: what a template would move where, the moves
/// already made, and putting them back. The moving itself is a job,
/// asked for like any other.
public protocol OrganiseManaging: Sendable {
    /// What moving these items by a template would do to each, without
    /// moving anything.
    func organisePlan(template: String, itemIDs: [UUID]) async throws -> [ReorganizePlanEntry]

    /// The runs of moves made so far, newest first.
    func moveSessions() async throws -> [LibraryDatabase.MoveSession]

    /// Put one moved file back where it was.
    func revertMove(logID: UUID) async throws

    /// Put a whole run back. A file that cannot be put back is said, and
    /// the rest are still done.
    func revertMoveSession(sessionID: UUID) async throws -> MoveRevertOutcome

    /// How many jobs of one kind are queued or running, and whether the
    /// queue is paused. With `startingQueue`, a queue that has such jobs
    /// waiting and is not running is started; a paused one stays paused.
    func jobQueue(kind: String, startingQueue: Bool) async throws -> JobQueueState
}

public struct MoveRevertOutcome: Codable, Equatable, Sendable {
    public var reverted: Int
    public var failures: [String]

    public init(reverted: Int, failures: [String]) {
        self.reverted = reverted
        self.failures = failures
    }
}

public struct JobQueueState: Codable, Equatable, Sendable {
    public var pendingCount: Int
    public var isPaused: Bool

    public init(pendingCount: Int, isPaused: Bool) {
        self.pendingCount = pendingCount
        self.isPaused = isPaused
    }
}

// MARK: - On this Mac

extension LocalLibraryService {
    public func organisePlan(template: String, itemIDs: [UUID]) async throws -> [ReorganizePlanEntry] {
        try library.previewReorganize(template: template, itemIDs: itemIDs)
    }

    public func moveSessions() async throws -> [LibraryDatabase.MoveSession] {
        try library.moveSessions()
    }

    public func revertMove(logID: UUID) async throws {
        try library.revertMove(logID, fileAccess: fileAccess)
    }

    public func revertMoveSession(sessionID: UUID) async throws -> MoveRevertOutcome {
        let outcome = try library.revertSession(sessionID, fileAccess: fileAccess)
        return MoveRevertOutcome(reverted: outcome.reverted, failures: outcome.failures)
    }

    public func jobQueue(kind: String, startingQueue: Bool) async throws -> JobQueueState {
        let pending = try await library.read { db in
            try JobRecord
                .filter(sql: "kind = ? AND state IN (?, ?)",
                        arguments: [kind, JobState.queued.rawValue, JobState.running.rawValue])
                .fetchCount(db)
        }
        guard let runner else { return JobQueueState(pendingCount: pending, isPaused: false) }
        if startingQueue, pending > 0 { await runner.startDraining() }
        return JobQueueState(pendingCount: pending, isPaused: await runner.isPaused)
    }
}
