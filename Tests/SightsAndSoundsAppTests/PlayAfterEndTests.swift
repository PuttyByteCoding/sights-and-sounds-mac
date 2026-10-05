import AVFoundation
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Play on a finished item starts it again, as QuickTime does. It used
/// to call `player.play()` at the end of the file: nothing moved, while
/// the button said Pause.
@Suite(.writesVideo) @MainActor struct PlayAfterEndTests {
    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition(), "timed out: \(what)")
    }

    @Test func playAtTheEndStartsFromTheTop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("play-after-end-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 2, variant: 0)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "End")
        let source = Source(name: "Here", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }
        let model = PlayerModel(
            request: PlayerRequest(libraryID: UUID(), itemID: item.id, playlist: [item.id], name: "One"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil("loaded") { model.item?.id == item.id && model.durationSeconds > 1 }
        if model.isLooping { model.toggleLoop() }

        model.seek(to: model.durationSeconds - 0.2)
        model.play()
        try await waitUntil("reached the end") { !model.isPlaying }

        model.play()
        // Waited for, not slept on: on a loaded machine the seek back to
        // the top can take longer than any fixed pause. Without the fix
        // the playhead never leaves the end, so this still fails.
        try await waitUntil("back at the top") { model.player.currentTime().seconds < 1.0 }
        #expect(model.isPlaying)
    }
}
