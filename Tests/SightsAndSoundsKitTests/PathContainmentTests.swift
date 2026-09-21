import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Nothing a user types — a template, a segment's name, an imported list
/// — can steer a file out of the source it belongs to.
@Suite struct PathContainmentTests {

    @Test func parentSegmentsNeverSurviveNormalizing() {
        #expect(MediaPath.normalize("../../outside/a.mp4") == "outside/a.mp4")
        #expect(MediaPath.normalize("shows/../../a.mp4") == "shows/a.mp4")
        #expect(MediaPath.normalize("shows/..hidden/a..mp4") == "shows/..hidden/a..mp4")  // only whole segments
    }

    @Test func aMoveCannotLandOutsideTheSourceRoot() async throws {
        // Two levels down, so "../../" has somewhere real to climb to.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-contain-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("drive/media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("shows"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("media".utf8).write(to: root.appendingPathComponent("shows/a.mp4"))

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Contain")
        let source = Source(name: "S", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/a.mp4")
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }

        try library.moveFile(itemID: item.id, to: "../../escaped/a.mp4")

        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("escaped/a.mp4").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped/a.mp4").path))
        let moved = try await library.writer.read { try MediaItem.fetchOne($0, key: item.id)! }
        #expect(moved.relativePath == "escaped/a.mp4")
    }

    @Test func aSegmentsNameCannotSteerWhereItsExportLands() {
        // A song called "Medley: A/B", or worse.
        #expect(ClipExportJob.outputRelativePath(
            parentFolder: "shows/1995", parentFileName: "show.mkv", label: "Medley: A/B")
            == "shows/1995/show - Medley_ A_B.mp4")
        #expect(ClipExportJob.outputRelativePath(
            parentFolder: "shows", parentFileName: "show.mkv", label: "../../../escape")
            == "shows/show - _.._.._escape.mp4")
        #expect(ClipExportJob.outputRelativePath(
            parentFolder: "", parentFileName: "show.mkv", label: "  ")
            == "show - clip.mp4")
    }

    /// Counts attempts and always fails the same way.
    private final class AlwaysFails: FileAccess, @unchecked Sendable {
        let error: any Error
        private let lock = NSLock()
        private var count = 0
        var attempts: Int { lock.withLock { count } }
        init(_ error: any Error) { self.error = error }
        func isReachable(_ url: URL) -> Bool { true }
        func contentsOfDirectory(at url: URL) throws -> [URL] { [] }
        func allFiles(under url: URL) throws -> [URL] { [] }
        func fileSize(at url: URL) throws -> Int64 { 0 }
        func readFile(at url: URL, chunk: (Data) throws -> Void) throws {}
        func removeFile(at url: URL) throws {}
        func moveFile(at url: URL, to destination: URL) throws {
            lock.withLock { count += 1 }
            throw error
        }
    }

    /// Retrying is for a volume that hiccuped. "Something is already
    /// there" and "you may not write here" will be just as true in a
    /// tenth of a second, and each retry slept: a revert of a few
    /// thousand moves that could not land spent a second and a half on
    /// every one of them.
    @Test func aMoveThatCanNeverSucceedIsNotRetried() {
        for code in [CocoaError.Code.fileWriteFileExists, .fileWriteNoPermission, .fileWriteVolumeReadOnly] {
            let files = AlwaysFails(CocoaError(code))
            #expect(throws: (any Error).self) {
                try LibraryDatabase.moveWithRetries(
                    fileAccess: files, from: URL(fileURLWithPath: "/tmp/a"), to: URL(fileURLWithPath: "/tmp/b"))
            }
            #expect(files.attempts == 1)
        }
    }

    @Test func aMoveThatMightSucceedNextTimeIsRetried() {
        let files = AlwaysFails(CocoaError(.fileWriteUnknown))
        #expect(throws: (any Error).self) {
            try LibraryDatabase.moveWithRetries(
                fileAccess: files, from: URL(fileURLWithPath: "/tmp/a"), to: URL(fileURLWithPath: "/tmp/b"))
        }
        #expect(files.attempts == 6)
    }
}
