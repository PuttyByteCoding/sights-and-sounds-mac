import Foundation

/// Blocking work — a tool run, a whole-file read — on a thread of its
/// own, awaited.
///
/// Called straight from an async job, blocking work holds one of the
/// cooperative pool's threads (one per core; three on CI) for as long as
/// it runs. Every task in the app shares that pool, so a few slow files
/// or a hung tool stalled database observation, UI tasks and the other
/// job lanes with it.
enum Blocking {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
