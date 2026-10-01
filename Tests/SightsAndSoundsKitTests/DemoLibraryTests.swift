import AVFoundation
import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The demo generator: deterministic fake metadata, real synthesized media,
/// and the whole thing queryable through the app's own filter surface.
@Suite struct DemoLibraryTests {

    @Test func seedingIsDeterministic() async throws {
        func names(seed: UInt64) async throws -> [String] {
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Demo")
            let source = Source(name: "S", rootPath: TestRoots.unreachable("demo"))
            try await DemoLibrarySeeder.seed(library: library, source: source, seed: seed)
            return try await library.writer.read {
                try MediaItem.order(sql: "relativePath").fetchAll($0).map(\.relativePath)
            }
        }
        let a = try await names(seed: 7)
        let b = try await names(seed: 7)
        let c = try await names(seed: 8)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func seededLibraryAnswersTheFilterSurface() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Demo")
        let source = Source(name: "S", rootPath: TestRoots.unreachable("demo"))
        let report = try await DemoLibrarySeeder.seed(library: library, source: source)

        #expect(report.shows == 22)
        #expect(report.videoItems > 0 && report.audioItems > 0)

        // Counts in the db match the report.
        let (itemCount, taggingCount) = try await library.writer.read { db in
            (try MediaItem.fetchCount(db), try MediaItemTag.fetchCount(db))
        }
        #expect(itemCount == report.videoItems + report.audioItems)
        #expect(taggingCount == report.taggings)

        // Filter by an invented band: only that band's items come back.
        let bandTag = try await library.writer.read { db in
            try Tag.filter(sql: "name = ?", arguments: [DemoVocabulary.bands[0]]).fetchOne(db)
        }
        if let bandTag {
            let hits = try library.mediaItems(
                matching: MediaFilter(required: [.tag(bandTag.id)]), kinds: .video)
            for hit in hits {
                #expect(hit.relativePath.contains(DemoVocabulary.bands[0]))
            }
        }

        // The folder tree has the shows/<year> shape.
        let tree = FolderTreeBuilder.build(from: try library.folderCounts(kinds: .video))
        #expect(tree.contains { $0.name == "shows" })

        // Field values landed and the vocabulary is entirely synthetic.
        #expect(report.fieldValues > 0)
    }

    @Test func synthesizedMediaIsRealPlayableMedia() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-demo-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let videoURL = dir.appendingPathComponent("clip.mp4")
        try await DemoMediaFactory.writeVideo(to: videoURL, seconds: 2, variant: 3)
        let videoAsset = AVURLAsset(url: videoURL)
        let videoDuration = CMTimeGetSeconds(try await videoAsset.load(.duration))
        #expect(abs(videoDuration - 2.0) < 0.5)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        #expect(!videoTracks.isEmpty)

        let audioURL = dir.appendingPathComponent("track.m4a")
        try DemoMediaFactory.writeAudio(to: audioURL, seconds: 2, variant: 1)
        let audioAsset = AVURLAsset(url: audioURL)
        let audioDuration = CMTimeGetSeconds(try await audioAsset.load(.duration))
        #expect(abs(audioDuration - 2.0) < 0.5)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        #expect(!audioTracks.isEmpty)

        // Sizes are real and non-trivial.
        let videoSize = try FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as! Int64
        #expect(videoSize > 5_000)
    }

    @Test func makeFileCallbackDrivesSizesAndPaths() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Demo")
        let source = Source(name: "S", rootPath: TestRoots.unreachable("demo"))
        final class PathBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [String] = []
            func append(_ path: String) { lock.lock(); stored.append(path); lock.unlock() }
            var paths: [String] { lock.lock(); defer { lock.unlock() }; return stored }
        }
        let box = PathBox()
        try await DemoLibrarySeeder.seed(
            library: library, source: source, showCount: 2, audioShowCount: 1
        ) { path, _ in
            box.append(path)
            return 12345
        }
        let paths = box.paths
        #expect(!paths.isEmpty)
        let sizes = try await library.writer.read {
            try Int64.fetchAll($0, sql: "SELECT fileSize FROM mediaItem")
        }
        #expect(sizes.allSatisfy { $0 == 12345 })
        #expect(Set(paths).count == paths.count)  // no path collisions
    }
}

/// The Demo Concerts library was opened with `open(at:)`: choosing the same
/// folder twice opened the existing library, migrated it and seeded a
/// second source into it before the template collided, leaving it changed.
/// A failed run left a half-made file that blocked every retry. It is made
/// like every other new library now: never over a file, whole or not at all.
@Suite struct DemoLibraryCreationTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-demo-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aSecondDemoInTheSameFolderLeavesTheFirstAlone() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Demo Concerts.sqlite")
        let media = dir.appendingPathComponent("Demo Media", isDirectory: true)
        let first = try await DemoLibrarySeeder.makeLibrary(at: url, mediaFolder: media)
        let before = try await first.writer.read { try Source.fetchCount($0) }
        try first.close()

        await #expect(throws: LibraryCreationError.fileExists("Demo Concerts.sqlite")) {
            try await DemoLibrarySeeder.makeLibrary(at: url, mediaFolder: media)
        }
        let reopened = try LibraryDatabase.open(at: url)
        defer { try? reopened.close() }
        #expect(try await reopened.writer.read { try Source.fetchCount($0) } == before)
    }

    @Test func aFailedDemoLeavesNoFileBehind() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Demo Concerts.sqlite")
        struct Broken: Error {}
        await #expect(throws: Broken.self) {
            try await DemoLibrarySeeder.makeLibrary(
                at: url, mediaFolder: dir.appendingPathComponent("Demo Media")
            ) { _, _ in throw Broken() }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path), "a failed run left its file")
    }
}

/// A demo run that failed part-way removed its library file but left the
/// videos it had made, and a retry in the same folder writes the same
/// paths: the video writer refused a file that was already there, so
/// every retry failed at its first video ("startWriting") until the media
/// folder was found and deleted by hand.
@Suite struct DemoMediaRewriteTests {
    @Test func aVideoIsWrittenOverOneAlreadyThere() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-demo-rewrite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("show/clip.mp4")
        try await DemoMediaFactory.writeVideo(to: url, seconds: 1)
        try await DemoMediaFactory.writeVideo(to: url, seconds: 1, variant: 1)
        let probe = await MediaProbe.probe(url: url)
        #expect(probe.durationSeconds != nil, "the rewritten video does not play")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == ["clip.mp4"], "a working file was left behind: \(leftovers)")
    }
}
