import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The app's registry is one file, and more than one connection can be
/// open on it: a second copy of the app, or — in a test run — every app
/// model the tests make. A write that finds another connection writing
/// has to wait for it, not fail.
@Suite struct AppDatabaseLockTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    @Test(.timeLimit(.minutes(1)))
    func aWriteWaitsForAnotherConnectionToFinishItsOwn() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-registry-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("App.sqlite")
        let first = try AppDatabase.open(at: url)
        let second = try AppDatabase.open(at: url)

        // The first connection begins a write and sits in it.
        let holding = Flag(), letGo = Flag(), finished = Flag()
        let holder = Task.detached {
            try first.writer.write { db in
                try db.execute(sql: "UPDATE libraryRef SET name = name")
                holding.set()
                while !letGo.isSet { Thread.sleep(forTimeInterval: 0.01) }
            }
            finished.set()
        }
        for _ in 0..<500 where !holding.isSet { try await Task.sleep(for: .milliseconds(10)) }
        #expect(holding.isSet)

        // The second writes meanwhile. It is let through a moment later,
        // when the first lets go.
        let writing = Task.detached { try second.touchLastOpened(UUID()) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!finished.isSet)
        letGo.set()

        try await writing.value
        try await holder.value
        // And a read is never held up by a write at all.
        #expect(try second.libraries().isEmpty)
    }
}
