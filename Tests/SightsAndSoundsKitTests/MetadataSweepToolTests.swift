import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The metadata sweep reads tags with ffprobe. Without it every read
/// threw, each throw was taken for a broken FILE, and a failure marker
/// went down for every item — the whole library showed as failed, and
/// installing ffmpeg afterwards changed nothing until someone pressed
/// Retry. The sweep now checks for the tool first, as write-back does.
@Suite struct MetadataSweepToolTests {
    private actor Summary {
        var text: String?
        func set(_ value: String) { text = value }
    }

    @Test func withoutFfprobeTheSweepMarksNothingAndSaysWhy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-meta-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not really video".utf8).write(to: root.appendingPathComponent("a.mp4"))
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "MetaTool")
        let source = Source(name: "Here", rootPath: root.path)
        try await library.writer.write { db in
            try source.insert(db)
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false).insert(db)
        }
        let summary = Summary()
        let context = JobContext(
            library: library, jobID: UUID(), progressHandler: { _, _ in },
            cancellationCheck: { false }, summaryHandler: { await summary.set($0) })

        try await MetadataSweepJob(ffprobeAvailable: { false }).run(context)

        #expect(try library.itemsNeedingMetadataSweep(limit: 10).count == 1, "no marker may go down")
        #expect(await summary.text == FfmpegTool.installHint)
    }
}
