import Foundation
import SightsAndSoundsKit

/// Queueing Organise's moves.
enum OrganiseMove {
    /// Queue a reorganize and start the queue, returning once it is queued.
    /// It used to wait for `runPending`, which returns only when the whole
    /// queue is empty: behind a sweep that takes days, Move stayed disabled
    /// long after the moves themselves were done. The window follows the
    /// library, so history and the plan refresh when the moves land.
    static func queue(on runner: JobRunner, template: String, ids: [UUID]) async throws {
        _ = try await ReorganizeJob.enqueue(on: runner, template: template, itemIDs: ids)
        await runner.startDraining()
    }
}
