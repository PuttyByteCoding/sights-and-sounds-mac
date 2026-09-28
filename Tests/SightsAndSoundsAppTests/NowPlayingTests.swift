import AVFoundation
import Foundation
import MediaPlayer
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The player tells the system what is playing — Control Center's Now
/// Playing, the keyboard's media keys, headphone buttons — and answers
/// them. It did neither: play/pause on the keyboard went to whatever
/// else had last played.
@Suite(.serialized) @MainActor struct NowPlayingTests {
    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition(), "timed out: \(what)")
    }

    @Test func aPlayingPlayerIsNowPlayingAndAnswersTheMediaKeys() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-playing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("Opening Night.mp4"), seconds: 4, variant: 0)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "NowPlaying")
        let source = Source(name: "S", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "Opening Night.mp4", durationSeconds: 4, needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }
        // A live bridge of its own: the app's is inert in a test run.
        let nowPlaying = NowPlaying(live: true)
        let model = PlayerModel(
            request: PlayerRequest(libraryID: UUID(), itemID: item.id, playlist: [item.id], name: "One"),
            library: library, appDatabase: nil, nowPlaying: nowPlaying)
        try await waitUntil("playing") { model.item?.id == item.id && model.isPlaying }

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect(info[MPMediaItemPropertyTitle] as? String == "Opening Night.mp4")
        #expect((info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0) > 3)
        #expect(MPNowPlayingInfoCenter.default().playbackState == .playing)

        // What the media key's toggle does.
        nowPlaying.perform(.togglePlayPause)
        #expect(!model.isPlaying)
        #expect(MPNowPlayingInfoCenter.default().playbackState == .paused)

        model.shutdown()
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    }
}
