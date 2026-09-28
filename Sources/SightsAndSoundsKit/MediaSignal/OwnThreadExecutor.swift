import Foundation

/// Runs every job it is given on a new thread of its own, never on the
/// cooperative pool.
///
/// For work that may block and never come back: a decoder stuck inside
/// a damaged file. Such a stage is given up on and left behind, still
/// blocked, and on the shared pool that meant one of the few threads
/// every task in the app runs on was gone for good; a few damaged files
/// in a sweep took them all, including the ones the give-up timers
/// needed.
final class OwnThreadExecutor: TaskExecutor, @unchecked Sendable {
    static let shared = OwnThreadExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        Thread.detachNewThread {
            job.runSynchronously(on: executor)
        }
    }
}
