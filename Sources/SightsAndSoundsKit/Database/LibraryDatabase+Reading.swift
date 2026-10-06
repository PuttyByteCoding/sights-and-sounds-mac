import Foundation
import GRDB

extension LibraryDatabase {
    /// A read from async code. Use it instead of `await writer.read`.
    ///
    /// GRDB's async `read` takes one of the pool's few connections and only
    /// then waits for a thread of Swift's shared pool to run on. Every
    /// library method is a plain read, and async code calling one holds a
    /// thread of that pool while it waits for a connection. With enough of
    /// both at once — every window refreshing after a Review purge — the
    /// threads waited for connections and the connections for threads, and
    /// the app stopped for good. `asyncRead` waits for its connection and
    /// runs on GRDB's own queues, so a connection it holds is never waiting
    /// on the shared pool, and a plain read waiting for it always gets it.
    public func read<T: Sendable>(_ value: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writer.asyncRead { database in
                continuation.resume(with: Result { try value(database.get()) })
            }
        }
    }
}
