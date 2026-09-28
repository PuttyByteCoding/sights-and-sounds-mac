import AVFoundation
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Dragging the scrubber sends a position per mouse event. Each used to
/// start an exact seek that cancelled the one before, so the decoder
/// thrashed and the picture lagged the thumb. Apple's chase pattern
/// (Technical Q&A QA1820): one seek in flight, the latest target kept,
/// loose seeks while dragging, an exact one where the drag ends.
@Suite @MainActor struct ScrubChaseTests {
    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition(), "timed out: \(what)")
    }

    @Test func aDragKeepsOneSeekInFlightAndEndsExactlyWhereItStopped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrub-chase-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 8, variant: 0)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Scrub")
        let source = Source(name: "S", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", durationSeconds: 8, needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }
        let model = PlayerModel(
            request: PlayerRequest(libraryID: UUID(), itemID: item.id, playlist: [item.id], name: "One"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil("loaded") { model.item?.id == item.id && model.durationSeconds > 7 }
        let before = model.scrubSeeksIssued

        // A drag: two hundred positions in one burst.
        for step in 0..<200 { model.scrub(to: Double(step) / 200 * 6) }

        #expect(model.scrubSeeksIssued - before == 1, "one seek in flight, the rest waiting as one target")
        #expect(abs(model.currentSeconds - 5.97) < 0.01, "the playhead shows the thumb at once")

        model.endScrub(at: 5.5)
        try await waitUntil("landed exactly") { abs(model.player.currentTime().seconds - 5.5) < 0.05 }
    }
}
