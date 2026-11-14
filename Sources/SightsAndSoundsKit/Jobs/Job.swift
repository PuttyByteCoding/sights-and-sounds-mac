import Foundation

/// A long-running operation. Conformances are small: decode the payload,
/// do the work, report progress, check for cancellation at natural
/// boundaries. Everything else — persistence, state transitions, failure
/// capture — is the runner's.
public protocol Job: Sendable {
    /// Stable identifier stored in `JobRecord.kind`. Never rename a shipped
    /// kind; queued rows outlive code.
    static var kind: String { get }

    /// A job someone is waiting on in a window: it goes to the front of
    /// the lane, ahead of background work, and a sweep that is running
    /// steps aside for it between files. Imports; nothing else.
    static var jumpsQueue: Bool { get }

    init(payload: Data?) throws

    func run(_ context: JobContext) async throws

    /// Optional cleanup after cancellation was honored.
    func cancelled(_ context: JobContext) async
}

extension Job {
    public static var jumpsQueue: Bool { false }

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
    /// Whether a queue-jumping job is waiting. Off without a runner.
    var waitingCheck: @Sendable () async -> Bool = { false }
    /// Queues another job on this library's lane. Without a runner, a
    /// test's context, there is no lane and nothing is queued.
    var enqueueHandler: @Sendable (any Job.Type, Data?) async throws -> Void = { _, _ in }

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

    /// Background work calls this between files. With an import waiting
    /// it throws `SteppingAside`, and the runner puts this job back in
    /// the queue, behind the import, to start again where the work
    /// stands: a sweep decides its work per run, so what it finished
    /// stays finished. Never between the halves of a write.
    public func stepAsideIfAnImportIsWaiting() async throws {
        if await waitingCheck() { throw SteppingAside() }
    }

    /// Queue a follow-up job on this library's lane, behind the jobs
    /// already waiting; the runner starts it in its turn.
    public func enqueue(_ type: any Job.Type, payload: Data? = nil) async throws {
        try await enqueueHandler(type, payload)
    }

    /// Record the job's one-line outcome ("38 new, 2 skipped").
    public func setSummary(_ text: String) async {
        await summaryHandler(text)
    }
}

/// Thrown by `stepAsideIfAnImportIsWaiting`: not a failure and not a
/// cancel. The runner queues the job again.
public struct SteppingAside: Error {}

/// Thrown when a queued row names a kind no registered conformance claims.
public struct UnknownJobKindError: Error, CustomStringConvertible {
    public let kind: String
    public var description: String { "no registered job type for kind '\(kind)'" }
}
