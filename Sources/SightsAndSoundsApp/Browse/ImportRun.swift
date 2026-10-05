import Foundation
import Observation
import SightsAndSoundsKit

/// One import from the Import window: a job per staging group (one
/// group, or one per folder), run in turn, with progress and a total.
/// The jobs are the library's, asked for through its service, so the
/// run is the same for a library another Mac holds.
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

    struct NotQueued: Error, CustomStringConvertible {
        var description: String { "the import could not be queued" }
    }

    /// The job is the library's and goes on whether or not it can be
    /// asked about, so this is not "failed".
    struct LostTouch: Error, CustomStringConvertible {
        let reason: String
        var description: String {
            "could not ask how the import is going (\(reason)); it may still be running — see Background Tasks"
        }
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

    private let service: any LibraryService

    /// How a group's job is queued; tests hold it at a gate. Queued and
    /// not started: the run starts the queue once it knows the job is
    /// still wanted.
    var enqueue: @Sendable (any LibraryService, UUID, [String], ImportStaging?) async throws -> JobRecord = {
        let request = JobRequest.importFiles(sourceID: $1, relativePaths: $2, staging: $3)
        guard let job = try await $0.run(request, wait: .queued) else { throw NotQueued() }
        return job
    }

    /// How often a job's row is read while it runs.
    var pollInterval: Duration = .milliseconds(250)
    /// How many readings in a row may go unanswered — a library on
    /// another Mac, out of reach for a moment — before the run gives up
    /// watching.
    var patience = 20

    init(service: any LibraryService) {
        self.service = service
    }

    func start(sourceID: UUID, groups: [Group], onFinish: @escaping @MainActor (Outcome) -> Void) {
        start(sourceID: sourceID, preparing: { groups }, onFinish: onFinish)
    }

    /// The same, for groups that take a moment to make ready: the words
    /// staged become tags first, and that is asked of the service. The
    /// run counts as running from the press, not from when they are.
    func start(
        sourceID: UUID, preparing groups: @escaping @MainActor () async -> [Group],
        onFinish: @escaping @MainActor (Outcome) -> Void
    ) {
        isRunning = true
        let service = service
        Task {
            var outcome = Outcome()
            let groups = await groups().filter { !$0.paths.isEmpty }
            let total = groups.reduce(0) { $0 + $1.paths.count }
            var completedBefore = 0
            for group in groups {
                guard !isCancelled, !Task.isCancelled else { break }
                defer { completedBefore += group.paths.count }
                do {
                    let record = try await enqueue(service, sourceID, group.paths, group.staging)
                    running = record
                    do {
                        // Cancel pressed while it was being queued found no
                        // job to cancel; this one is cancelled now, before it
                        // can run, and settles like any other.
                        if isCancelled { try await service.cancelJob(id: record.id) }
                        // Started, not waited for: waiting for the drain meant
                        // waiting for the whole queue, so a cancelled or
                        // finished folder still held the run until every job
                        // queued ahead or after it had finished. Its own row,
                        // polled below, says when it is done.
                        _ = try await service.jobQueue(kind: ImportJob.kind, startingQueue: true)
                    } catch {
                        // Queued and not started: taken back, or it would
                        // run later, behind a window that said it failed.
                        try? await service.cancelJob(id: record.id)
                        throw error
                    }
                    var settled = false
                    var unanswered = 0
                    while !settled {
                        try? await Task.sleep(for: pollInterval)
                        let asked: JobRecord?
                        do {
                            asked = try await service.job(id: record.id)
                            unanswered = 0
                        } catch {
                            unanswered += 1
                            guard unanswered < patience else { throw LostTouch(reason: "\(error)") }
                            continue
                        }
                        guard let row = asked else { break }
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
        let service = service
        Task { try? await service.cancelJob(id: running.id) }
    }
}
