import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// Get Info for a library, as asked of its service: the counts, and the
/// three things the window changes.
@Suite struct PropertiesManagingTests {
    typealias Tag = SightsAndSoundsKit.Tag

    struct Fixture {
        let root: URL
        let library: LibraryDatabase
        let service: LocalLibraryService

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-properties-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = try LibraryDatabase.open(at: root.appendingPathComponent("Props.sqlite"))
            try library.ensureInfo(name: "Props")
            service = LocalLibraryService(library: library)
            let here = Source(name: "Here", rootPath: root.path)
            let off = Source(name: "Away", rootPath: root.path + "-away", enabled: false)
            let band = TagCategory(name: "Band", sortOrder: 0)
            let alpha = Tag(tagCategoryID: band.id, name: "Alpha")
            let a = MediaItem(sourceID: here.id, kind: .video, relativePath: "a.mp4", fileSize: 1_000)
            let b = MediaItem(sourceID: here.id, kind: .video, relativePath: "b.mp4", fileSize: 2_000)
            let c = MediaItem(sourceID: off.id, kind: .audio, relativePath: "c.m4a", fileSize: 300)
            try library.writer.write { db in
                for row in [here, off] { try row.insert(db) }
                try band.insert(db)
                try alpha.insert(db)
                for row in [a, b, c] { try row.insert(db) }
                try DuplicateCandidate(itemA: a.id, itemB: b.id, source: .contentHash, confidence: 1).insert(db)
            }
            _ = try library.createEmbeddedClip(
                parentID: a.id, name: "Song", startSeconds: 1, endSeconds: 2, role: .song)
        }

        func tearDown() {
            try? library.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func theIdentityRowAndTheSearchSettingsAreReadWithoutTheCounting() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.libraryInfo() == (try f.library.info()))
        try await f.service.setExtensionOverrides(video: ["mkv"], audio: nil)
        #expect(try await f.service.libraryInfo()?.videoExtensionsOverride == ["mkv"])

        let settings = try await f.service.searchSettings()
        #expect(settings.formats == (try f.library.searchFormats()))
        #expect(!settings.storedFormatsUnreadable)
        #expect(settings.categories.map(\.name) == ["Band"])
        // The item that sorts first, with its tags, to try a format on.
        #expect(settings.sample?.fileName == "a.mp4")
        let sent = try JSONDecoder().decode(SearchSettings.self, from: JSONEncoder().encode(settings))
        #expect(sent == settings)
    }

    @Test func thePropertiesAreTheLibrarysOwnCount() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let properties = try await f.service.libraryProperties()
        #expect(properties.info?.name == "Props")
        #expect(properties.filePath == f.root.appendingPathComponent("Props.sqlite").path)
        #expect(properties.fileBytes > 0)
        #expect(properties.migrations > 0)
        // A song is a range of its video, not a video of its own:
        // counted as a song and not in the size of the media.
        #expect(properties.videoCount == 3)
        #expect(properties.audioCount == 1)
        #expect(properties.songs == 1 && properties.clips == 0 && properties.exportedClips == 0)
        #expect(properties.mediaBytes == 3_300)
        #expect(properties.hashable == 3 && properties.hashed == 0)
        #expect(properties.pendingDuplicates == 1)
        #expect(properties.categories == 1 && properties.tags == 1 && properties.fields == 0)
        #expect(properties.sources.map(\.name) == ["Away", "Here"])
        #expect(properties.sources.map(\.itemCount) == [1, 3])
        #expect(properties.sources.map(\.enabled) == [false, true])
        // And it crosses to another Mac as it is.
        let sent = try JSONDecoder().decode(LibraryProperties.self, from: JSONEncoder().encode(properties))
        #expect(sent == properties)
    }

    @Test func theNameTheSeparatorsAndTheExtensionsAreChanged() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try await f.service.renameLibrary(to: "  Concerts  ")
        try await f.service.setSeparatorCharacters("-_")
        try await f.service.setExtensionOverrides(video: ["mkv", "mp4"], audio: nil)
        let info = try #require(try await f.service.libraryProperties().info)
        #expect(info.name == "Concerts")
        #expect(info.separatorCharacters == "-_")
        #expect(info.videoExtensionsOverride == ["mkv", "mp4"])
        #expect(info.audioExtensionsOverride == nil)

        // Back to the app's own extensions.
        try await f.service.setExtensionOverrides(video: nil, audio: ["flac"])
        let again = try #require(try await f.service.libraryProperties().info)
        #expect(again.videoExtensionsOverride == nil && again.audioExtensionsOverride == ["flac"])

        await #expect(throws: ServiceError.emptyName) { try await f.service.renameLibrary(to: "   ") }
        #expect(try await f.service.libraryProperties().info?.name == "Concerts")
    }

    /// A library that is not a file — and one another Mac is shown —
    /// has no path of its own to give.
    @Test func aLibraryThatIsNotAFileHasNoPath() async throws {
        let library = try LibraryDatabase.openInMemory()
        let properties = try await LocalLibraryService(library: library).libraryProperties()
        #expect(properties.filePath == nil && properties.fileBytes == 0)
        #expect(properties.info == nil)
        #expect(properties.videoCount == 0 && properties.sources.isEmpty)
    }
}
