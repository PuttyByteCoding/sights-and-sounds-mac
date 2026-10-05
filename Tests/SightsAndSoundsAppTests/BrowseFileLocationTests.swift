import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Where the Browse window says an item's file is. The Finder, a drag
/// out of the grid and Quick Look need a file on this Mac; a thumbnail
/// needs something it can read frames from, which for a library on
/// another Mac is not a file at all.
@Suite @MainActor struct BrowseFileLocationTests {
    struct Fixture {
        let library: LibraryDatabase
        let stub: StubLibraryService
        let root: URL
        let here: MediaItem
        let segment: MediaItem
        let away: MediaItem
        let off: MediaItem

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("browse-file-location-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Location")
            let online = Source(name: "Here", rootPath: root.path)
            let unmounted = Source(name: "Away", rootPath: root.path + "-not-mounted")
            var switchedOff = Source(name: "Off", rootPath: root.path)
            switchedOff.enabled = false
            let disabled = switchedOff
            let here = MediaItem(sourceID: online.id, kind: .video, relativePath: "a.mp4", needsReview: false)
            let away = MediaItem(sourceID: unmounted.id, kind: .video, relativePath: "b.mp4", needsReview: false)
            let off = MediaItem(sourceID: disabled.id, kind: .video, relativePath: "c.mp4", needsReview: false)
            try await library.writer.write { db in
                for source in [online, unmounted, disabled] { try source.insert(db) }
                for item in [here, away, off] { try item.insert(db) }
            }
            segment = try library.createEmbeddedClip(parentID: here.id, name: "Song", startSeconds: 1, endSeconds: 2)
            self.library = library
            self.here = here
            self.away = away
            self.off = off
            stub = StubLibraryService(LocalLibraryService(library: library))
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        @MainActor func model() -> BrowseModel {
            BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library), service: stub)
        }
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "\(what): never happened")
    }

    @Test func aFileOnThisMacIsNamedOnlyWhileItsSourceIsInReach() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.model()
        try await waitUntil("the sources") { model.sources.count == 3 }

        #expect(model.fileURL(for: f.here) == f.root.appendingPathComponent("a.mp4"))
        #expect(model.fileURL(for: f.here) == (try f.library.resolvedFileURL(for: f.here)))
        #expect(model.fileURL(for: f.segment) == f.root.appendingPathComponent("a.mp4"), "a segment is its video's file")
        #expect(model.fileURL(for: f.away) == nil)
        #expect(model.fileURL(for: f.off) == nil, "a disabled source is not in reach")
        // Dragged out as the file itself; a segment is not a file of its own.
        #expect(model.dragFileURL(for: f.here) == f.root.appendingPathComponent("a.mp4"))
        #expect(model.dragFileURL(for: f.segment) == nil)
    }

    /// The paths a library on another Mac knows are that Mac's. Nothing
    /// here may hand one to the Finder.
    @Test func aLibraryHeldElsewhereHasNoFilesHere() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        f.stub.filesAreOnThisMac = false
        let model = f.model()
        try await waitUntil("the sources") { model.sources.count == 3 }

        #expect(model.fileURL(for: f.here) == nil)
        #expect(model.dragFileURL(for: f.here) == nil)
    }

    /// A thumbnail is rendered from wherever the service says the item
    /// plays from, asked only when one has to be rendered.
    @Test func aThumbnailsSourceIsAskedOfTheService() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.model()
        try await waitUntil("the sources") { model.sources.count == 3 }

        let resolve = model.fileResolver(for: f.here)
        #expect(f.stub.calls("playable(itemID:)") == 0, "asked before anything needed rendering")
        #expect(await resolve() == f.root.appendingPathComponent("a.mp4"))
        #expect(f.stub.calls("playable(itemID:)") == 1)
        #expect(await model.fileResolver(for: f.away)() == nil)
    }

    /// A library on this Mac has its thumbnails here, as files. One held
    /// elsewhere is asked for each, and only when a tile wants it.
    @Test func onlyALibraryHeldElsewhereIsAskedForItsThumbnails() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.model()
        try await waitUntil("the sources") { model.sources.count == 3 }
        #expect(model.storedThumbnail(for: f.here) == nil)

        f.stub.filesAreOnThisMac = false
        let fetch = try #require(model.storedThumbnail(for: f.here))
        #expect(f.stub.calls("storedThumbnail(itemID:)") == 0)
        #expect(await fetch() == nil, "the library has made none")
        #expect(f.stub.calls("storedThumbnail(itemID:)") == 1)
    }
}
