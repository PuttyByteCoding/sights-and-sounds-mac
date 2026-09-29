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

    private(set) var running: JobRecord?
    private(set) var progress: (current: Int, total: Int)?
    private(set) var error: String?
    /// Cancel reaches the whole run, not just the job in flight: a
    /// per-folder import is one job per folder, and every later folder
    /// used to go ahead after Cancel.
    private(set) var isCancelled = false
    /// From `start` until the finish callback — what keeps Import from
    /// being pressed again while a run carries on in the background.
    private(set) var isRunning = false

    private let runner: JobRunner
    private let library: LibraryDatabase

    init(runner: JobRunner, library: LibraryDatabase) {
        self.runner = runner
        self.library = library
    }

    func start(sourceID: UUID, groups: [Group], onFinish: @escaping @MainActor (Tally) -> Void) {
        isRunning = true
        Task {
            var tally = Tally()
            for group in groups where !group.paths.isEmpty {
                guard !isCancelled, !Task.isCancelled else { break }
                do {
                    let record = try await ImportJob.enqueue(
                        on: runner, sourceID: sourceID,
                        relativePaths: group.paths, staging: group.staging)
                    running = record
                    let drain = Task { [runner] in try await runner.runPending() }
                    var settled = false
                    while !settled {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard let row = try await library.writer.read({
                            try JobRecord.fetchOne($0, key: record.id)
                        }) else { break }
                        progress = (row.progressCurrent, row.progressTotal ?? group.paths.count)
                        switch row.state {
                        case .queued, .running: break
                        case .succeeded, .failed, .cancelled:
                            settled = true
                            if let summary = row.summary {
                                let numbers = summary.split(separator: " ").compactMap { Int($0) }
                                tally.inserted += numbers.first ?? 0
                                tally.skipped += numbers.count > 1 ? numbers[1] : 0
                            }
                        }
                    }
                    _ = try? await drain.value
                } catch {
                    self.error = "\(error)"
                }
            }
            isRunning = false
            onFinish(tally)
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
