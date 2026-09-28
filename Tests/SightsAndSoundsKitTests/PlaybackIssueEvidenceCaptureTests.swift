import Foundation
import Testing

@testable import SightsAndSoundsKit

/// Flagging an item as won't-play captures what the file said, so the
/// Review queue can match a repair recipe to the failure. The capture
/// existed but nothing called it: every issue showed no evidence and
/// only the last-resort recipes.
@Suite struct PlaybackIssueEvidenceCaptureTests {
    @Test func flaggingAFileCapturesItsProbeOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a movie".utf8).write(to: root.appendingPathComponent("broken.mp4"))

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Evidence")
        let source = Source(name: "Here", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "broken.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }

        try library.stage(.playbackIssue, itemID: item.id)

        var evidence: PlaybackIssueEvidence?
        for _ in 0..<200 {
            evidence = try library.playbackIssueEvidence(of: item.id)
            if evidence != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let captured = try #require(evidence)
        #expect(!captured.probeOutput.isEmpty)
        #expect(captured.failureKind != nil)
    }
}
