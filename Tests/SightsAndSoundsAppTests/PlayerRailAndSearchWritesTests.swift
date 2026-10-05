import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The player's writes to the segment rail and the search formats, over
/// a service that can fail or answer late.
///
/// The item is on a source that is not mounted. It cannot play, and it
/// does not need to: the rail and the search panel answer for the item
/// on screen whether or not its file is in reach. So nothing here writes
/// a video, and all of it runs in the merge gate.
@Suite @MainActor struct PlayerRailAndSearchWritesTests {
    struct Fixture {
        let library: LibraryDatabase
        let stub: StubLibraryService
        let video: MediaItem
        let song: MediaItem
        let block: VideoBlock

        init() async throws {
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Rail")
            let away = Source(name: "Away", rootPath: "/tmp/sas-rail-not-mounted-\(UUID().uuidString)")
            let video = MediaItem(
                sourceID: away.id, kind: .video, relativePath: "show.mp4", durationSeconds: 600, needsReview: false)
            try await library.writer.write { db in
                try away.insert(db)
                try video.insert(db)
            }
            song = try library.createEmbeddedClip(
                parentID: video.id, name: "Opener", startSeconds: 10, endSeconds: 20, role: .song)
            block = try library.addBlock(to: video.id, startSeconds: 30, endSeconds: 40)
            self.library = library
            self.video = video
            stub = StubLibraryService(LocalLibraryService(library: library))
        }

        @MainActor func player() -> PlayerModel {
            PlayerModel(
                request: PlayerRequest(libraryID: UUID(), itemID: video.id, playlist: [video.id], name: "One"),
                library: library, appDatabase: nil, service: stub)
        }
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition(), "\(what): never happened")
    }

    /// The player with its item and rail on screen, and nothing on its way.
    private func opened(_ f: Fixture) async throws -> PlayerModel {
        let model = f.player()
        try await waitUntil("the item and its rail") { model.item?.id == f.video.id && model.segments.count == 2 }
        try await waitUntil("settled") { model.isSettled }
        return model
    }

    @Test func aSegmentIsRenamedOnTheRail() async throws {
        let f = try await Fixture()
        let model = try await opened(f)
        defer { model.shutdown() }

        model.renameSegment(f.song.id, to: "Encore")
        try await waitUntil("settled") { model.isSettled }

        #expect(model.segments.first { $0.id == f.song.id }?.name == "Encore")
        #expect(try f.library.clips(of: f.video.id).first?.notes == "Encore")
    }

    @Test func aRowTakenOffTheRailIsGoneWhicheverRecordItWas() async throws {
        let f = try await Fixture()
        let model = try await opened(f)
        defer { model.shutdown() }
        let songRow = try #require(model.segments.first { $0.id == f.song.id })
        let hideRow = try #require(model.segments.first { $0.id == f.block.id })
        model.selectedSegmentID = f.song.id

        model.removeSegment(songRow)
        try await waitUntil("settled") { model.isSettled }
        #expect(model.segments.map(\.id) == [f.block.id])
        #expect(model.selectedSegmentID == nil, "the selection still names a row that is gone")
        #expect(try f.library.clips(of: f.video.id).isEmpty)

        model.removeSegment(hideRow)
        try await waitUntil("settled") { model.isSettled }
        #expect(model.segments.isEmpty && model.hideBlocks.isEmpty)
        #expect(try f.library.blocks(of: f.video.id).isEmpty)
    }

    @Test func aHideBlockDeletedLeavesTheRail() async throws {
        let f = try await Fixture()
        let model = try await opened(f)
        defer { model.shutdown() }

        model.deleteBlock(f.block.id)
        try await waitUntil("settled") { model.isSettled }

        #expect(model.hideBlocks.isEmpty)
        #expect(model.segments.map(\.id) == [f.song.id])
    }

    @Test func aRailWriteThatFailsSaysSoAndKeepsTheRow() async throws {
        let f = try await Fixture()
        let model = try await opened(f)
        defer { model.shutdown() }
        let songRow = try #require(model.segments.first { $0.id == f.song.id })

        f.stub.fail("deleteSegment(_:)")
        model.selectedSegmentID = f.song.id
        model.removeSegment(songRow)
        try await waitUntil("settled") { model.isSettled }

        #expect(model.loadError?.contains("deleteSegment") == true)
        #expect(model.segments.count == 2)
        #expect(model.selectedSegmentID == f.song.id)
    }

    /// The editor closes on Save: the format is in the panel at once, and
    /// in the library when the write has landed.
    @Test func aSearchFormatSavedShowsAtOnceAndIsStored() async throws {
        let f = try await Fixture()
        let model = try await opened(f)
        defer { model.shutdown() }
        let web = SearchRecipe(name: "Web")
        let archive = SearchRecipe(name: "Archive")

        model.saveSearchFormat(web)
        #expect(model.searchFormats.formats.map(\.name) == ["Web"], "not in the panel until the write lands")
        #expect(model.searchFormats.defaultID == web.id, "the first format is the default")
        model.saveSearchFormat(archive)
        model.setDefaultSearchFormat(archive.id)
        var renamed = web
        renamed.name = "The Web"
        model.saveSearchFormat(renamed)
        try await waitUntil("settled") { model.isSettled }

        let stored = try f.library.searchFormats()
        #expect(stored.formats.map(\.name) == ["The Web", "Archive"])
        #expect(stored.defaultID == archive.id)
        #expect(model.searchFormats == stored)
    }

    /// Two saves, the first held up: the second was built on the first,
    /// and lands after it, so both are kept.
    @Test func twoFormatsSavedInARowAreBothKept() async throws {
        let f = try await Fixture()
        let model = try await opened(f)
        defer { model.shutdown() }

        f.stub.delay("setSearchFormats(_:replacingUnreadable:)", by: .milliseconds(250))
        model.saveSearchFormat(SearchRecipe(name: "One"))
        model.saveSearchFormat(SearchRecipe(name: "Two"))
        try await waitUntil("settled") { model.isSettled }

        #expect(try f.library.searchFormats().formats.map(\.name) == ["One", "Two"])
    }

    @Test func aSearchFormatThatCannotBeStoredSaysSoAndShowsWhatTheLibraryHas() async throws {
        let f = try await Fixture()
        let model = try await opened(f)
        defer { model.shutdown() }

        f.stub.fail("setSearchFormats(_:replacingUnreadable:)")
        model.saveSearchFormat(SearchRecipe(name: "Web"))
        #expect(model.searchFormats.formats.count == 1, "shown while it is on its way")
        try await waitUntil("settled") { model.isSettled }

        #expect(model.loadError?.contains("setSearchFormats") == true)
        #expect(model.searchFormats == .empty, "the panel shows a format the library does not have")
    }
}
