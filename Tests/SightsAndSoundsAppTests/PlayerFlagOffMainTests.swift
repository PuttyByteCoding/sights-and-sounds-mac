import AVFoundation
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A deletion or won't-play mark moves the file into its staging folder.
/// That move — with retries on a busy or network volume — ran on the
/// main thread, so a triage key press could freeze the window for as
/// long as the move took. The mark shows at once; the move follows.
@Suite(.writesVideo) @MainActor struct PlayerFlagOffMainTests {
    /// A volume where every move takes a while.
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

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test func aSlowMoveDoesNotHoldUpTheKeyPress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-flag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 2, variant: 0)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Flags")
        let source = Source(name: "S", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", durationSeconds: 2, needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }
        let model = PlayerModel(
            request: PlayerRequest(libraryID: UUID(), itemID: item.id, playlist: [item.id], name: "One"),
            library: library, appDatabase: nil, fileAccess: SlowMoves())
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == item.id && model.fileURL != nil }

        let clock = ContinuousClock()
        let elapsed = clock.measure { model.perform(.toggleMarkedForDeletion) }

        #expect(elapsed < .milliseconds(500), "the key press took \(elapsed)")
        #expect(model.item?.markedForDeletion == true)  // shown at once
        let staged = { try? library.writer.read { try MediaItem.fetchOne($0, key: item.id) } }
        try await waitUntil { staged()?.relativePath == "_ToDelete/a.mp4" }
        #expect(staged()?.markedForDeletion == true)
    }

    /// The mark moves the file, and the player stays on it. Save a Copy,
    /// Live Text on a paused frame, the screen read and scrub previews all
    /// read `fileURL` — which kept naming the path the file had left.
    @Test func afterAMarkMovesTheFileThePlayerNamesItsNewPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-flag-url-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 2, variant: 0)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Flags")
        let source = Source(name: "S", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", durationSeconds: 2, needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }
        let model = PlayerModel(
            request: PlayerRequest(libraryID: UUID(), itemID: item.id, playlist: [item.id], name: "One"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == item.id && model.fileURL != nil }

        model.perform(.togglePlaybackIssue)
        try await waitUntil { model.item?.relativePath.hasSuffix("/a.mp4") == true && model.item?.relativePath != "a.mp4" }
        try await waitUntil { model.fileURL?.lastPathComponent == "a.mp4" && model.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true }

        model.perform(.togglePlaybackIssue)
        try await waitUntil { model.item?.relativePath == "a.mp4" }
        try await waitUntil { model.fileURL?.standardizedFileURL == root.appendingPathComponent("a.mp4").standardizedFileURL }
    }
}

