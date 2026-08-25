import AVFoundation
import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The demo generator: deterministic fake metadata, real synthesized media,
/// and the whole thing queryable through the app's own filter surface.
@Suite struct DemoLibraryTests {

    @Test func seedingIsDeterministic() throws {
        func names(seed: UInt64) throws -> [String] {
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Demo")
            let source = Source(name: "S", rootPath: "/tmp/demo")
            try DemoLibrarySeeder.seed(library: library, source: source, seed: seed)
            return try library.writer.read {
                try MediaItem.order(sql: "relativePath").fetchAll($0).map(\.relativePath)
            }
        }
        #expect(try names(seed: 7) == names(seed: 7))
        #expect(try names(seed: 7) != names(seed: 8))
    }

    @Test func seededLibraryAnswersTheFilterSurface() throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Demo")
        let source = Source(name: "S", rootPath: "/tmp/demo")
        let report = try DemoLibrarySeeder.seed(library: library, source: source)

        #expect(report.shows == 22)
        #expect(report.videoItems > 0 && report.audioItems > 0)

        // Counts in the db match the report.
        let (itemCount, taggingCount) = try library.writer.read { db in
            (try MediaItem.fetchCount(db), try MediaItemTag.fetchCount(db))
        }
        #expect(itemCount == report.videoItems + report.audioItems)
        #expect(taggingCount == report.taggings)

        // Filter by an invented band: only that band's items come back.
        let bandTag = try library.writer.read { db in
            try Tag.filter(sql: "name = ?", arguments: [DemoVocabulary.bands[0]]).fetchOne(db)
        }
        if let bandTag {
            let hits = try library.mediaItems(
                matching: MediaFilter(required: [.tag(bandTag.id)]), kind: .video)
            for hit in hits {
                #expect(hit.relativePath.contains(DemoVocabulary.bands[0]))
            }
        }

        // The folder tree has the shows/<year> shape.
        let tree = FolderTreeBuilder.build(from: try library.folderCounts(kind: .video))
        #expect(tree.contains { $0.name == "shows" })

        // Field values landed and the vocabulary is entirely synthetic.
        #expect(report.fieldValues > 0)
    }

    @Test func synthesizedMediaIsRealPlayableMedia() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-demo-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let videoURL = dir.appendingPathComponent("clip.mp4")
        try DemoMediaFactory.writeVideo(to: videoURL, seconds: 2, variant: 3)
        let videoAsset = AVURLAsset(url: videoURL)
        let videoDuration = CMTimeGetSeconds(videoAsset.duration)
        #expect(abs(videoDuration - 2.0) < 0.5)
        #expect(!videoAsset.tracks(withMediaType: .video).isEmpty)

        let audioURL = dir.appendingPathComponent("track.m4a")
        try DemoMediaFactory.writeAudio(to: audioURL, seconds: 2, variant: 1)
        let audioAsset = AVURLAsset(url: audioURL)
        #expect(abs(CMTimeGetSeconds(audioAsset.duration) - 2.0) < 0.5)
        #expect(!audioAsset.tracks(withMediaType: .audio).isEmpty)

        // Sizes are real and non-trivial.
        let videoSize = try FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as! Int64
        #expect(videoSize > 5_000)
    }

    @Test func makeFileCallbackDrivesSizesAndPaths() throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Demo")
        let source = Source(name: "S", rootPath: "/tmp/demo")
        nonisolated(unsafe) var paths: [String] = []
        try DemoLibrarySeeder.seed(
            library: library, source: source, showCount: 2, audioShowCount: 1
        ) { path, _ in
            paths.append(path)
            return 12345
        }
        #expect(!paths.isEmpty)
        let sizes = try library.writer.read {
            try Int64.fetchAll($0, sql: "SELECT fileSize FROM mediaItem")
        }
        #expect(sizes.allSatisfy { $0 == 12345 })
        #expect(Set(paths).count == paths.count)  // no path collisions
    }
}
