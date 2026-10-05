import AVFoundation
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A segment (song or clip) plays inside its parent's file, so its
/// timeline is the parent's. The row's duration is the segment's LENGTH,
/// and the player used to take it as the file's: every seek was clamped
/// to it, so a song at 4–5 s of a 6 s file started at 1 s and looped
/// back to 1 s at its out-point.
@Suite(.writesVideo) @MainActor struct PlayerSegmentTimelineTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    private func makeSegment() async throws -> (LibraryDatabase, MediaItem, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-segment-\(UUID().uuidString)", isDirectory: true)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Segments")
        let source = Source(name: "S", rootPath: root.path)
        try await library.writer.write { try source.insert($0) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("show.mp4"), seconds: 6)
        let parent = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "show.mp4",
            durationSeconds: 6, needsReview: false)
        try await library.writer.write { try parent.insert($0) }
        let song = try library.createEmbeddedClip(
            parentID: parent.id, name: "Song", startSeconds: 4, endSeconds: 5, role: .song)
        return (library, song, root)
    }

    @Test func aSegmentStartsAtItsInPointOnTheParentsTimeline() async throws {
        let (library, song, root) = try await makeSegment()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PlayerModel(
            request: PlayerRequest(libraryID: UUID(), itemID: song.id, playlist: [song.id], name: "Song"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == song.id && model.fileURL != nil }

        #expect(model.currentSeconds >= 4)
        try await waitUntil { model.player.currentTime().seconds >= 3.9 }
        // The scrubber spans the file the segment lives in, not the segment.
        try await waitUntil { model.durationSeconds > 5.5 }
    }

    @Test func seekingToTheStartGoesToTheInPoint() async throws {
        let (library, song, root) = try await makeSegment()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PlayerModel(
            request: PlayerRequest(libraryID: UUID(), itemID: song.id, playlist: [song.id], name: "Song"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == song.id && model.fileURL != nil }
        model.pause()
        model.perform(.seekToStart)
        #expect(model.currentSeconds == 4)
    }
}
