import Foundation
import SightsAndSoundsKit

/// Queueing Organise's moves — the one way in. (BrowseModel had a second,
/// unused one that waited for the whole queue.)
enum OrganiseMove {
    /// Queue a reorganize and start the queue, returning once it is queued.
    /// It used to wait for `runPending`, which returns only when the whole
    /// queue is empty: behind a sweep that takes days, the window stayed
    /// blocked with no reason given. Now it returns at once; the window
    /// says "Moves queued…" while the run waits (it observes the queue),
    /// and refreshes history and the plan when the moves land (it follows
    /// the library's items).
    static func queue(on runner: JobRunner, template: String, ids: [UUID]) async throws {
        _ = try await ReorganizeJob.enqueue(on: runner, template: template, itemIDs: ids)
        await runner.startDraining()
    }

    /// How many reorganizes of this library are queued or running, as that
    /// changes. Seeing one starts the queue (joining a drain already under
    /// way): nothing else drains a library's queue when it opens, so a Move
    /// queued before a quit would otherwise leave the window on "Moves
    /// queued…" with no way on. A paused runner stays paused — its drain
    /// starts nothing — so watching never runs a queue the user held.
    static func pending(in library: LibraryDatabase, runner: JobRunner) -> AsyncThrowingStream<Int, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await count in library.pendingJobCounts(of: ReorganizeJob.kind) {
                        if count > 0 { await runner.startDraining() }
                        continuation.yield(count)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
