import Foundation

/// Writes to a library, sent one at a time in the order they were asked
/// for.
///
/// A write used to be a call that had finished by the next line. Through
/// a `LibraryService` it is a request that takes its time, and two sent
/// side by side can land in either order — an untag overtaking the
/// tagging it was meant to undo. One at a time, in the order asked, is
/// what the buttons mean. Each window's model has a queue of its own:
/// order matters within a window, not across them.
///
/// The work a queue has been sent outlives the queue. A window that
/// closes lets go of its queue with a resume position still on its way,
/// and the app waits for every such write before it quits.
@MainActor
final class WriteQueue {
    /// The last write queued here; the next one waits for it.
    private var last: Task<Void, Never>?

    /// Every write queued on any queue and not yet finished.
    private static var inFlight: [UUID: Task<Void, Never>] = [:]

    static var inFlightCount: Int { inFlight.count }

    /// Run `work` after every write queued here before it, and wait for
    /// it. Returns what it returned, or the error it threw; either way
    /// the writes queued after it go ahead.
    func run<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        let previous = last
        let attempt = Task { () -> Result<T, any Error> in
            await previous?.value
            do {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        track(Task { _ = await attempt.value })
        return await attempt.value
    }

    /// Queue `work` and return at once, for a write nobody waits on.
    /// `failed` is told if it throws.
    func send(
        _ work: @escaping @Sendable () async throws -> Void,
        failed: @escaping @MainActor (any Error) -> Void = { _ in }
    ) {
        let previous = last
        track(Task {
            await previous?.value
            do {
                try await work()
            } catch {
                failed(error)
            }
        })
    }

    private func track(_ link: Task<Void, Never>) {
        last = link
        let key = UUID()
        Self.inFlight[key] = link
        Task {
            await link.value
            Self.inFlight[key] = nil
        }
    }

    /// Returns when every write queued on every queue has finished,
    /// including any queued while this waited.
    static func settleAll() async {
        while let (key, link) = inFlight.first {
            await link.value
            inFlight[key] = nil
        }
    }

    /// The same, but gives up after `limit`: a quit must not hang on a
    /// library that has stopped answering.
    static func settleAll(within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while !inFlight.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
