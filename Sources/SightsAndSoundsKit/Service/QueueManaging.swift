import Foundation
import GRDB

/// The library's queue of background work, as Background Tasks shows
/// and steers it: the jobs, the pause, and the sweeps that keep the
/// data derived from the files up to date. The queue belongs to the Mac
/// that holds the library, and the work is done there.
public protocol QueueManaging: Sendable {
    /// The newest jobs, newest first, and whether the queue is paused.
    func jobLane(limit: Int) async throws -> JobLane

    /// Move a queued job ahead of the others waiting. It changes what
    /// starts next, never what stops.
    func moveJobToFront(id: UUID) async throws

    /// Queue a failed or finished job's work again, as a job of its
    /// own — the one retried stays in the list as it ended — and start
    /// the queue.
    func retryJob(id: UUID) async throws

    /// Take the succeeded and cancelled rows off the list. Failed jobs
    /// stay: their evidence is the point.
    func clearFinishedJobs() async throws

    /// Hold the queue — the running job finishes, nothing new starts —
    /// or let it go again.
    func setQueuePaused(_ paused: Bool) async throws

    /// How much each sweep still has to do, and how much it could not.
    /// A kind that keeps no such count, or whose count could not be
    /// read, is not in the answer.
    func sweepStatuses() async throws -> [SweepKind: SweepStatus]

    /// Queue a sweep, unless one of its kind is already pending, and
    /// start the queue; first forgetting what `preparation` says to. It
    /// returns once the sweep is queued, not when it is done:
    /// `jobQueue(kind:startingQueue:)` says when none of
    /// `SweepKind.jobKinds` is pending.
    func startSweep(_ kind: SweepKind, after preparation: SweepPreparation) async throws
}

public struct JobLane: Codable, Equatable, Sendable {
    public var jobs: [JobRecord]
    /// Nil when nothing has started this library's queue since the app
    /// was opened: there is no queue yet to be paused or not.
    public var isPaused: Bool?

    public init(jobs: [JobRecord], isPaused: Bool?) {
        self.jobs = jobs
        self.isPaused = isPaused
    }
}

/// The data the library derives from its files, one sweep for each.
public enum SweepKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case contentHash, fingerprint, metadata, signal, thumbnails, duplicates

    public var id: String { rawValue }

    /// The jobs that do this sweep's work.
    public var jobKinds: [String] {
        switch self {
        case .contentHash: [ContentHashJob.kind]
        case .fingerprint: [FingerprintCaptureJob.kind]
        case .metadata: [MetadataSweepJob.kind]
        case .signal: [MediaSignalJob.kind]
        case .thumbnails: [ThumbnailBatchJob.kind]
        case .duplicates: [HashDuplicateSweepJob.kind, FingerprintMatchSweepJob.kind]
        }
    }

    /// Rejected pairs stay rejected, and the check records no failures.
    public var canRecalculate: Bool { self != .duplicates }
    public var canRetry: Bool { self != .duplicates }
}

/// What a sweep forgets before it runs.
public enum SweepPreparation: String, Codable, Sendable {
    /// Nothing: the sweep fills in what is missing.
    case nothing
    /// The record of what failed, so that those files are tried again.
    case forgetFailures
    /// Every item's stored data of this kind, so that all of it is made
    /// again.
    case forgetEverything
}

// MARK: - On this Mac

extension LocalLibraryService {
    public func jobLane(limit: Int) async throws -> JobLane {
        let jobs = try await library.writer.read { db in
            try JobRecord.order(sql: "createdAt DESC").limit(limit).fetchAll(db)
        }
        return JobLane(jobs: jobs, isPaused: await runner?.isPaused)
    }

    public func moveJobToFront(id: UUID) async throws {
        _ = try await queue().runNext(id)
    }

    public func retryJob(id: UUID) async throws {
        let runner = try queue()
        _ = try await runner.retry(id)
        // Started, not waited for.
        await runner.startDraining()
    }

    public func clearFinishedJobs() async throws {
        _ = try await queue().deleteFinished()
    }

    public func setQueuePaused(_ paused: Bool) async throws {
        let runner = try queue()
        await runner.setPaused(paused)
        if !paused { await runner.startDraining() }
    }

    public func sweepStatuses() async throws -> [SweepKind: SweepStatus] {
        // Each on its own: a count that cannot be read leaves its row
        // without one, and the others still say theirs.
        var statuses: [SweepKind: SweepStatus] = [:]
        statuses[.contentHash] = try? library.contentHashStatus()
        statuses[.fingerprint] = try? library.fingerprintStatus()
        statuses[.metadata] = try? library.metadataSweepStatus()
        statuses[.signal] = try? library.signalStatus()
        if let libraryID = try library.info()?.libraryID {
            statuses[.thumbnails] = try? library.thumbnailStatus(libraryID: libraryID)
        }
        return statuses
    }

    public func startSweep(_ kind: SweepKind, after preparation: SweepPreparation) async throws {
        let runner = try queue()
        let libraryID = try library.info()?.libraryID
        switch (preparation, kind) {
        case (.nothing, _), (_, .duplicates): break
        case (.forgetFailures, .contentHash): try library.retryContentHashFailures()
        case (.forgetFailures, .fingerprint): try library.retryFingerprintFailures()
        case (.forgetFailures, .metadata): try library.retryMetadataSweepFailures()
        case (.forgetFailures, .signal): try library.retrySignalFailures()
        case (.forgetFailures, .thumbnails): try library.retryThumbnailFailures()
        case (.forgetEverything, .contentHash): try library.resetContentHashes()
        case (.forgetEverything, .fingerprint): try library.resetFingerprints()
        case (.forgetEverything, .metadata): try library.resetMetadataSweepAll()
        case (.forgetEverything, .signal): try library.resetSignalFindings()
        case (.forgetEverything, .thumbnails):
            if let libraryID { try library.resetThumbnails(libraryID: libraryID) }
        }
        switch kind {
        case .contentHash: _ = try await runner.enqueueUnlessPending(ContentHashJob.self)
        case .fingerprint: _ = try await runner.enqueueUnlessPending(FingerprintCaptureJob.self)
        case .metadata: _ = try await runner.enqueueUnlessPending(MetadataSweepJob.self)
        case .signal: _ = try await runner.enqueueUnlessPending(MediaSignalJob.self)
        case .thumbnails:
            if let libraryID { _ = try await ThumbnailBatchJob.enqueueUnlessPending(on: runner, libraryID: libraryID) }
        case .duplicates:
            _ = try await runner.enqueueUnlessPending(HashDuplicateSweepJob.self)
            _ = try await runner.enqueueUnlessPending(FingerprintMatchSweepJob.self)
        }
        await runner.startDraining()
    }

    private func queue() throws -> JobRunner {
        guard let runner else { throw ServiceError.noJobRunner }
        return runner
    }
}
