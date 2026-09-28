import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// A failure row stops a sweep retrying a broken file until someone
/// presses Retry. A drive that goes away mid-sweep, or a file moved
/// while the sweep ran, is not a broken file: recording it poisoned
/// every remaining item of that drive until a manual retry.
@Suite struct SweepDriveGoneTests {
    /// A drive that disappears on the first read.
    private final class UnpluggingDrive: FileAccess, @unchecked Sendable {
        private let lock = NSLock()
        private var unplugged = false
        let brokenFile: String?

        init(brokenFile: String? = nil) { self.brokenFile = brokenFile }

        private var gone: Bool { lock.withLock { unplugged } }
        func isReachable(_ url: URL) -> Bool { !gone }
        func contentsOfDirectory(at url: URL) throws -> [URL] { [] }
        func allFiles(under url: URL) throws -> [URL] { [] }
        func fileSize(at url: URL) throws -> Int64 { 0 }
        func readFile(at url: URL, chunk: (Data) throws -> Void) throws {
            if let brokenFile, url.lastPathComponent == brokenFile {
                throw CocoaError(.fileReadCorruptFile)
            }
            lock.withLock { unplugged = true }
            throw CocoaError(.fileReadNoSuchFile)
        }
        func moveFile(at url: URL, to destination: URL) throws {}
        func removeFile(at url: URL) throws {}
    }

    private func library(_ names: [String]) async throws -> LibraryDatabase {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "DriveGone")
        let source = Source(name: "External", rootPath: "/Volumes/SAS-Test-External")
        try await library.writer.write { db in
            try source.insert(db)
            for name in names {
                try MediaItem(sourceID: source.id, kind: .video, relativePath: name, needsReview: false).insert(db)
            }
        }
        return library
    }

    private func context(_ library: LibraryDatabase) -> JobContext {
        JobContext(
            library: library, jobID: UUID(), progressHandler: { _, _ in },
            cancellationCheck: { false }, summaryHandler: { _ in })
    }

    private func failureCount(_ library: LibraryDatabase) async throws -> Int {
        try await library.writer.read { try ContentHashFailure.fetchCount($0) }
    }

    @Test func aDriveUnpluggedMidSweepRecordsNoFailures() async throws {
        let library = try await library(["a.mp4", "b.mp4", "c.mp4"])

        try await ContentHashJob(fileAccess: UnpluggingDrive()).run(context(library))

        #expect(try await failureCount(library) == 0)
    }

    @Test func aGenuinelyBrokenFileIsStillRecorded() async throws {
        let library = try await library(["a.mp4"])

        try await ContentHashJob(fileAccess: UnpluggingDrive(brokenFile: "a.mp4")).run(context(library))

        #expect(try await failureCount(library) == 1)
    }
}

extension SweepDriveGoneTests {
    /// A file moved while the sweep ran (staged for deletion, say) is
    /// read at its new path next time, not recorded as broken.
    @Test func aFileMovedMidSweepIsNotRecorded() async throws {
        let library = try await library(["a.mp4"])
        let item = try await library.writer.read { try MediaItem.fetchOne($0)! }
        let mover = MovingDrive { try? library.writer.write { db in
            try db.execute(sql: "UPDATE mediaItem SET relativePath = '_ToDelete/a.mp4' WHERE id = ?", arguments: [item.id])
        } }

        try await ContentHashJob(fileAccess: mover).run(context(library))

        #expect(try await failureCount(library) == 0)
    }

    /// Moves the row on the first read, as a staging move would.
    private final class MovingDrive: FileAccess, @unchecked Sendable {
        let move: @Sendable () -> Void
        init(move: @escaping @Sendable () -> Void) { self.move = move }
        func isReachable(_ url: URL) -> Bool { true }
        func contentsOfDirectory(at url: URL) throws -> [URL] { [] }
        func allFiles(under url: URL) throws -> [URL] { [] }
        func fileSize(at url: URL) throws -> Int64 { 0 }
        func readFile(at url: URL, chunk: (Data) throws -> Void) throws {
            move()
            throw CocoaError(.fileReadNoSuchFile)
        }
        func moveFile(at url: URL, to destination: URL) throws {}
        func removeFile(at url: URL) throws {}
    }
}
