import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// A library on disk reads through a pool of a few connections. An async
/// read that went through GRDB's `read` took a connection and then
/// waited for a thread of Swift's shared pool to run on, while a plain
/// read made from async code held one of those threads waiting for a
/// connection. Enough of both at once — every window refreshing after a
/// Review purge — and each waited on the other: the app stopped for good.
@Suite struct ReaderPoolDeadlockTests {
    /// Waits on a thread of its own, so a wedged shared pool cannot keep
    /// the verdict from being given.
    private func finishes(within seconds: Double, _ work: @escaping @Sendable () async -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await work()
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success
    }

    /// Not async, so it is GRDB's blocking read — as every library
    /// method is when async code calls it.
    private func plainRead(_ library: LibraryDatabase) throws -> Int {
        try library.writer.read { db in
            usleep(2_000)
            return try Int.fetchOne(db, sql: "SELECT 1") ?? 0
        }
    }

    @Test func plainAndAsyncReadsTogetherNeverWaitOnEachOtherForever() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-reader-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LibraryDatabase.open(at: folder.appendingPathComponent("library.sqlite"))
        try library.ensureInfo(name: "Pool")

        // Far more of each than the shared pool has threads or the
        // library has connections, each holding its connection a moment.
        let finished = finishes(within: 30) { [self] in
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<400 {
                    group.addTask {
                        if index.isMultiple(of: 2) {
                            _ = try? plainRead(library)
                        } else {
                            _ = try? await library.read { db -> Int in
                                usleep(2_000)
                                return try Int.fetchOne(db, sql: "SELECT 1") ?? 0
                            }
                        }
                    }
                }
            }
        }
        // Not an expectation: with the shared pool wedged nothing could
        // report one, and the run would hang instead of failing.
        precondition(finished, "reader pool deadlock: the reads waited on each other and never finished")
    }
}
