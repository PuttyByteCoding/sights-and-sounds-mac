import Foundation

/// A long-running operation. Conformances are small: decode the payload,
/// do the work, report progress, check for cancellation at natural
/// boundaries. Everything else — persistence, state transitions, failure
/// capture — is the runner's.
public protocol Job: Sendable {
    /// Stable identifier stored in `JobRecord.kind`. Never rename a shipped
    /// kind; queued rows outlive code.
    static var kind: String { get }

    init(payload: Data?) throws

    func run(_ context: JobContext) async throws

    /// Optional cleanup after cancellation was honored.
    func cancelled(_ context: JobContext) async
}

extension Job {
    public func cancelled(_ context: JobContext) async {}
}

/// What a running job may touch: its library, its identity, progress
/// reporting, and the cooperative cancellation flag.
public struct JobContext: Sendable {
    public let library: LibraryDatabase
    public let jobID: UUID

    let progressHandler: @Sendable (Int, Int?) async -> Void
    let cancellationCheck: @Sendable () async -> Bool
    let summaryHandler: @Sendable (String) async -> Void

    /// Persist progress. Throttling is the job's concern (report at natural
    /// batch boundaries, not per byte).
    public func reportProgress(current: Int, total: Int? = nil) async {
        await progressHandler(current, total)
    }

    /// Cooperative cancellation: jobs check this at safe points and throw
    /// `CancellationError` to stop.
    public var isCancelled: Bool {
        get async { await cancellationCheck() }
    }

    /// Convenience: throw if cancellation was requested.
    public func checkCancellation() async throws {
        if await isCancelled { throw CancellationError() }
    }

    /// Record the job's one-line outcome ("38 new, 2 skipped").
    public func setSummary(_ text: String) async {
        await summaryHandler(text)
    }
}

/// Thrown when a queued row names a kind no registered conformance claims.
public struct UnknownJobKindError: Error, CustomStringConvertible {
    public let kind: String
    public var description: String { "no registered job type for kind '\(kind)'" }
}
