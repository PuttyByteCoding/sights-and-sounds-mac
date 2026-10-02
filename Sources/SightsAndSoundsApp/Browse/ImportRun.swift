import Foundation
import Observation
import SightsAndSoundsKit

/// One import from the Import window: a job per staging group (one
/// group, or one per folder), run in turn, with progress and a total.
@Observable @MainActor
final class ImportRun {
    struct Group {
        var paths: [String]
        var staging: ImportStaging?
    }

    struct Tally: Equatable {
        var inserted = 0
        var skipped = 0
    }

    /// What a run came to. The window showed "Import finished · 0 inserted"
    /// for a run whose job failed, or that was cancelled: a settled row's
    /// error was never read, and a cancel was not told apart from a finish.
    struct Outcome: Equatable {
        var tally = Tally()
        var cancelled = false
        /// One line per job that failed, or could not be queued.
        var failures: [String] = []
    }

    private(set) var running: JobRecord?
    /// Across the whole run: a per-folder import is one job per folder,
    /// and the overlay restarted at "0 of 12" for each with no sense of
    /// the whole.
    private(set) var progress: (current: Int, total: Int)?
    /// Cancel reaches the whole run, not just the job in flight: a
    /// per-folder import is one job per folder, and every later folder
    /// used to go ahead after Cancel.
    private(set) var isCancelled = false
    /// From `start` until the finish callback — what keeps Import from
    /// being pressed again while a run carries on in the background.
    private(set) var isRunning = false

    private let runner: JobRunner
    private let library: LibraryDatabase

    /// How a group's job is queued; tests hold it at a gate.
    var enqueue: @Sendable (JobRunner, UUID, [String], ImportStaging?) async throws -> JobRecord = {
        try await ImportJob.enqueue(on: $0, sourceID: $1, relativePaths: $2, staging: $3)
    }

    init(runner: JobRunner, library: LibraryDatabase) {
        self.runner = runner
        self.library = library
    }

    func start(sourceID: UUID, groups: [Group], onFinish: @escaping @MainActor (Outcome) -> Void) {
        isRunning = true
        Task {
            var outcome = Outcome()
            let groups = groups.filter { !$0.paths.isEmpty }
            let total = groups.reduce(0) { $0 + $1.paths.count }
            var completedBefore = 0
            for group in groups {
                guard !isCancelled, !Task.isCancelled else { break }
                defer { completedBefore += group.paths.count }
                do {
                    let record = try await enqueue(runner, sourceID, group.paths, group.staging)
                    running = record
                    // Cancel pressed while it was being queued found no
                    // job to cancel; this one is cancelled now, before it
                    // can run, and settles like any other.
                    if isCancelled { await runner.requestCancel(record.id) }
                    // Started, not waited for: waiting for the drain meant
                    // waiting for the whole queue, so a cancelled or
                    // finished folder still held the run until every job
                    // queued ahead or after it had finished. Its own row,
                    // polled below, says when it is done.
                    await runner.startDraining()
                    var settled = false
                    while !settled {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard let row = try await library.writer.read({
                            try JobRecord.fetchOne($0, key: record.id)
                        }) else { break }
                        progress = (completedBefore + row.progressCurrent, total)
                        switch row.state {
                        case .queued, .running: break
                        case .succeeded, .failed, .cancelled:
                            settled = true
                            if let summary = row.summary {
                                let numbers = summary.split(separator: " ").compactMap { Int($0) }
                                outcome.tally.inserted += numbers.first ?? 0
                                outcome.tally.skipped += numbers.count > 1 ? numbers[1] : 0
                            }
                            if row.state == .failed { outcome.failures.append(row.error ?? "failed") }
                            if row.state == .cancelled { outcome.cancelled = true }
                        }
                    }
                } catch {
                    outcome.failures.append("\(error)")
                }
            }
            if isCancelled { outcome.cancelled = true }
            isRunning = false
            onFinish(outcome)
        }
    }

    /// Stops the run: no further group starts, and the job in flight
    /// stops between files, so nothing is half-inserted.
    func cancel() {
        isCancelled = true
        guard let running else { return }
        Task { await runner.requestCancel(running.id) }
    }
}
