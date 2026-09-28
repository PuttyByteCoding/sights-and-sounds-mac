import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A tile's "Restore from Deletion Staging" moves the file back. It ran
/// on the main thread; over a slow or network volume the window froze
/// for the length of the move. It goes through the same off-main path
/// as the bulk actions.
@Suite @MainActor struct SingleItemStagingTests {
    struct SlowMoves: FileAccess {
        let live = LiveFileAccess()
        func isReachable(_ url: URL) -> Bool { live.isReachable(url) }
        func contentsOfDirectory(at url: URL) throws -> [URL] { try live.contentsOfDirectory(at: url) }
        func allFiles(under url: URL) throws -> [URL] { try live.allFiles(under: url) }
        func fileSize(at url: URL) throws -> Int64 { try live.fileSize(at: url) }
        func readFile(at url: URL, chunk: (Data) throws -> Void) throws { try live.readFile(at: url, chunk: chunk) }
        func moveFile(at url: URL, to destination: URL) throws {
            Thread.sleep(forTimeInterval: 1.5)
            try live.moveFile(at: url, to: destination)
        }
        func removeFile(at url: URL) throws { try live.removeFile(at: url) }
    }

    @Test func restoringOneItemReturnsBeforeTheMoveFinishes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: root.appendingPathComponent("a.mp4"))
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Staging")
        let source = Source(name: "S", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }
        try library.stage(.toDelete, itemID: item.id)
        let staged = try #require(try await library.writer.read { try MediaItem.fetchOne($0, key: item.id) })
        let model = BrowseModel(
            libraryID: UUID(), library: library, runner: JobRunner(library: library), fileAccess: SlowMoves())

        let clock = ContinuousClock()
        let elapsed = clock.measure { model.setStaging(.toDelete, on: false, for: [staged]) }

        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
        for _ in 0..<400 {
            let now = try await library.writer.read { try MediaItem.fetchOne($0, key: item.id) }
            if now?.markedForDeletion == false, now?.relativePath == "a.mp4" { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("the restore never landed")
    }
}
