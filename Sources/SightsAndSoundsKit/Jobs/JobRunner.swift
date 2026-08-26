import Foundation
import GRDB

/// Runs queued jobs for one library, one at a time, oldest first.
///
/// Phase 1 scope: the abstraction and its state machine, proven end to
/// end. Signal-driven waking, per-worker settings and the cross-library
/// dashboard arrive with Phase 5 — as consumers of this runner, not
/// changes to it.
public actor JobRunner {
    private let library: LibraryDatabase
    private var jobTypes: [String: any Job.Type] = [:]
    private var cancelRequested: Set<UUID> = []

    public init(library: LibraryDatabase) {
        self.library = library
    }

    /// Make a job kind runnable. Registering twice replaces (test hook).
    public func register(_ type: any Job.Type) {
        jobTypes[type.kind] = type
    }

    /// Persist a new queued job and return its record.
    public func enqueue(_ type: any Job.Type, payload: Data? = nil) throws -> JobRecord {
        let record = JobRecord(kind: type.kind, payload: payload)
        try library.writer.write { try record.insert($0) }
        return record
    }

    /// Enqueue unless a job of this kind is already queued or running —
    /// the signal-driven pattern: signals arrive freely, work never
    /// duplicates. Returns nil when a pending job made this a no-op.
    @discardableResult
    public func enqueueUnlessPending(_ type: any Job.Type, payload: Data? = nil) throws -> JobRecord? {
        let pending = try library.writer.read { db in
            try JobRecord
                .filter(sql: "kind = ? AND state IN ('queued','running')", arguments: [type.kind])
                .fetchCount(db)
        }
        guard pending == 0 else { return nil }
        return try enqueue(type, payload: payload)
    }

    /// Ask a queued or running job to stop. Queued jobs are cancelled
    /// before they start; running jobs stop at their next cooperative
    /// check.
    public func requestCancel(_ jobID: UUID) {
        cancelRequested.insert(jobID)
    }

    /// Drain the queue: run every queued job, oldest first, serially.
    /// Returns the ids it settled, in order.
    @discardableResult
    public func runPending() async throws -> [UUID] {
        var settled: [UUID] = []
        while let next = try nextQueued() {
            await run(next)
            settled.append(next.id)
        }
        return settled
    }

    // MARK: - Internals

    // Ordered by createdAt with rowid as the tiebreak: several jobs can
    // share a millisecond timestamp, and rowid preserves insertion order.
    private func nextQueued() throws -> JobRecord? {
        try library.writer.read { db in
            try JobRecord
                .filter(sql: "state = ?", arguments: [JobState.queued.rawValue])
                .order(sql: "createdAt, rowid")
                .fetchOne(db)
        }
    }

    private func run(_ record: JobRecord) async {
        if cancelRequested.remove(record.id) != nil {
            AppLog.shared.info("jobs", "\(record.kind): cancelled before start")
            try? transition(record.id) { row in
                row.state = .cancelled
                row.finishedAt = Date()
            }
            return
        }

        guard let type = jobTypes[record.kind] else {
            AppLog.shared.error("jobs", "\(record.kind): no registered job type")
            try? transition(record.id) { row in
                row.state = .failed
                row.error = UnknownJobKindError(kind: record.kind).description
                row.finishedAt = Date()
            }
            return
        }

        do {
            try transition(record.id) { row in
                row.state = .running
                row.startedAt = Date()
            }

            let jobID = record.id
            let context = JobContext(
                library: library,
                jobID: jobID,
                progressHandler: { [weak self] current, total in
                    try? await self?.recordProgress(jobID: jobID, current: current, total: total)
                },
                cancellationCheck: { [weak self] in
                    await self?.isCancelRequested(jobID) ?? true
                },
                summaryHandler: { [weak self] text in
                    try? await self?.recordSummary(jobID: jobID, text: text)
                }
            )

            AppLog.shared.info("jobs", "\(record.kind): started")
            let job = try type.init(payload: record.payload)
            do {
                try await job.run(context)
                let summary = try? await library.writer.read { db -> String? in
                    try String.fetchOne(
                        db, sql: "SELECT summary FROM job WHERE id = ?", arguments: [jobID])
                }
                AppLog.shared.info(
                    "jobs", "\(record.kind): succeeded\(summary.map { " — \($0)" } ?? "")")
                try transition(jobID) { row in
                    row.state = .succeeded
                    row.finishedAt = Date()
                }
            } catch is CancellationError {
                cancelRequested.remove(jobID)
                AppLog.shared.info("jobs", "\(record.kind): cancelled")
                try transition(jobID) { row in
                    row.state = .cancelled
                    row.finishedAt = Date()
                }
                await job.cancelled(context)
            }
        } catch {
            AppLog.shared.error("jobs", "\(record.kind): failed — \(error)")
            try? transition(record.id) { row in
                row.state = .failed
                row.error = String(describing: error)
                row.finishedAt = Date()
            }
        }
    }

    private func isCancelRequested(_ jobID: UUID) -> Bool {
        cancelRequested.contains(jobID)
    }

    private func recordSummary(jobID: UUID, text: String) throws {
        try library.writer.write { db in
            try db.execute(
                sql: "UPDATE job SET summary = ? WHERE id = ?",
                arguments: [text, jobID])
        }
    }

    private func recordProgress(jobID: UUID, current: Int, total: Int?) throws {
        try library.writer.write { db in
            try db.execute(
                sql: "UPDATE job SET progressCurrent = ?, progressTotal = ? WHERE id = ?",
                arguments: [current, total, jobID])
        }
    }

    private func transition(_ jobID: UUID, _ mutate: (inout JobRecord) -> Void) throws {
        try library.writer.write { db in
            guard var row = try JobRecord.fetchOne(db, key: jobID) else { return }
            mutate(&row)
            try row.update(db)
        }
    }
}
