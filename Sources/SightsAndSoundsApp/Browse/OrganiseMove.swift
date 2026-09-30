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
}
