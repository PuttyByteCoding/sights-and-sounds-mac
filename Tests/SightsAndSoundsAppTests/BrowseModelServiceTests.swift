import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A Browse window over a service that behaves the way a library on
/// another Mac can and one on this Mac never does: one answer fails, an
/// older answer arrives after a newer one, and the window closes while
/// the library goes on changing.
@Suite @MainActor struct BrowseModelServiceTests {
    struct Fixture {
        let library: LibraryDatabase
        let runner: JobRunner
        let stub: StubLibraryService
        let tag: SightsAndSoundsKit.Tag

        init() async throws {
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Service")
            let source = Source(name: "S", rootPath: "/tmp/sas-browse-service-\(UUID().uuidString)")
            let band = TagCategory(name: "Band")
            let items = ["alpha.mp4", "beta.mp4", "gamma.mp4"].map {
                MediaItem(sourceID: source.id, kind: .video, relativePath: $0, needsReview: false)
            }
            let tag = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Alpha")
            try await library.writer.write { db in
                try source.insert(db)
                try band.insert(db)
                try tag.insert(db)
                for item in items { try item.insert(db) }
            }
            self.tag = tag
            self.library = library
            runner = JobRunner(library: library)
            stub = StubLibraryService(LocalLibraryService(library: library, runner: runner))
        }

        @MainActor func model() -> BrowseModel {
            BrowseModel(libraryID: UUID(), library: library, runner: runner, service: stub)
        }

        func isTagged(_ itemID: UUID) throws -> Bool {
            try library.writer.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM mediaItemTag WHERE mediaItemID = ? AND tagID = ?",
                    arguments: [itemID, tag.id]) ?? 0
            } > 0
        }
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<800 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "\(what): never happened")
    }

    /// The parts of a refresh load on their own: one that fails keeps
    /// what is on screen and says so, and the listing is not its victim.
    @Test func oneFailedPartLeavesTheOthersLoaded() async throws {
        let f = try await Fixture()
        f.stub.fail("savedFilters()")
        let model = f.model()
        try await waitUntil("listing and sources") { model.items.count == 3 && model.sources.count == 1 }
        try await waitUntil("vocabulary") { model.vocabulary.map(\.category.name) == ["Band"] }
        try await waitUntil("error line") { model.errorMessage?.contains("saved filters") == true }
        #expect(model.listingError == nil)
        #expect(model.counts.total == 3)
    }

    /// A listing that fails is the listing's own failure, and the grid
    /// keeps what it showed.
    @Test func aFailedListingSaysSoAndKeepsTheGrid() async throws {
        let f = try await Fixture()
        let model = f.model()
        try await waitUntil("first listing") { model.items.count == 3 }
        f.stub.fail("listing(_:)")
        model.filter.searchText = "alpha"
        try await waitUntil("listing error") { model.listingError != nil }
        #expect(model.items.count == 3)
    }

    /// Asked for "alpha" and then for everything, with the first answer
    /// held up: the answer to the question no longer being asked must
    /// not land on top of the one that is.
    @Test func aSlowOlderListingDoesNotReplaceANewerOne() async throws {
        let f = try await Fixture()
        let model = f.model()
        try await waitUntil("first listing") { model.items.count == 3 }
        let before = f.stub.answered("listing(_:)")

        f.stub.delay("listing(_:)", by: .milliseconds(400))
        model.filter.searchText = "alpha"   // held up; would list one item
        try await waitUntil("the slow listing was asked for") { f.stub.calls("listing(_:)") == before + 1 }
        model.filter.searchText = ""        // answered at once; lists three
        try await waitUntil("both answered") { f.stub.answered("listing(_:)") == before + 2 }
        // Let whatever the late answer was going to do, happen.
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.items.count == 3)
    }

    /// A closed window lets go of the library's change stream; it used
    /// to be a subscription the model held, and is now a task reading a
    /// stream, which has to end with the model.
    @Test func closingTheWindowEndsItsSubscription() async throws {
        let f = try await Fixture()
        var model: BrowseModel? = f.model()
        try await waitUntil("first listing") { model?.items.count == 3 }
        #expect(f.stub.openChangeStreams == 1)
        model = nil
        try await waitUntil("the stream was let go of") { f.stub.openChangeStreams == 0 }
    }

    /// While the window is open, a write made by anything reaches it.
    @Test func aWriteElsewhereStillRefreshesTheWindow() async throws {
        let f = try await Fixture()
        let model = f.model()
        try await waitUntil("first listing") { model.items.count == 3 }
        let sourceID = try #require(model.sources.first?.id)
        let added = MediaItem(sourceID: sourceID, kind: .video, relativePath: "delta.mp4", needsReview: false)
        try await f.library.writer.write { try added.insert($0) }
        try await waitUntil("the new item") { model.items.count == 4 }
    }

    // MARK: - Writes

    /// Tag, then untag at once, with the tagging held up on its way. The
    /// untagging was asked for second and must land second: sent side by
    /// side, it would find nothing to remove and the tag would then
    /// arrive and stay.
    @Test func writesLandInTheOrderTheyWereAskedFor() async throws {
        let f = try await Fixture()
        let model = f.model()
        try await waitUntil("first listing") { model.items.count == 3 }
        let item = try #require(model.items.first)
        model.click(item.id, extend: true, range: false)

        f.stub.delay("assignTag(_:to:)", by: .milliseconds(300))
        let tagging = Task { await model.applyTagToSelection(f.tag.id) }
        try await waitUntil("the tagging was asked for") { f.stub.calls("assignTag(_:to:)") == 1 }
        await model.removeTagFromSelection(f.tag.id)
        await tagging.value

        #expect(try !f.isTagged(item.id), "the removal overtook the tagging it followed")
    }

    @Test func aFailedWriteSaysSoAndKeepsTheSelection() async throws {
        let f = try await Fixture()
        let model = f.model()
        try await waitUntil("first listing") { model.items.count == 3 }
        let item = try #require(model.items.first)
        model.click(item.id, extend: true, range: false)

        f.stub.fail("setNeedsReview(_:_:)")
        await model.markSelectionReviewed()

        #expect(model.errorMessage?.contains("setNeedsReview") == true)
        #expect(model.selection == [item.id], "the selection was cleared for an action that did not happen")
    }

    @Test func aWriteThatLandsClearsTheSelectionItActedOn() async throws {
        let f = try await Fixture()
        let model = f.model()
        try await waitUntil("first listing") { model.items.count == 3 }
        let item = try #require(model.items.first)
        model.click(item.id, extend: true, range: false)

        await model.markSelectionReviewed()

        #expect(model.errorMessage == nil)
        #expect(model.selection.isEmpty)
    }

    /// The list is the library's by the time the call returns, as it was
    /// when the write was made in place.
    @Test func savedFiltersAreInTheListWhenTheCallReturns() async throws {
        let f = try await Fixture()
        let model = f.model()
        try await waitUntil("first listing") { model.items.count == 3 }

        model.filter.searchText = "alpha"
        await model.saveCurrentFilter(named: "Alphas")
        let saved = try #require(model.savedFilters.first)
        #expect(saved.name == "Alphas" && saved.filter?.searchText == "alpha")

        model.filter.searchText = "beta"
        await model.updateSavedFilter(saved)
        #expect(model.savedFilters.first?.filter?.searchText == "beta")

        await model.renameSavedFilter(saved, to: "Betas")
        #expect(model.savedFilters.map(\.name) == ["Betas"])

        await model.deleteSavedFilter(saved)
        #expect(model.savedFilters.isEmpty)
        #expect(try f.library.savedFilters().isEmpty)
    }

    /// An empty or unchanged name is not a write at all.
    @Test func aSourceRenameThatChangesNothingAsksNothing() async throws {
        let f = try await Fixture()
        let model = f.model()
        try await waitUntil("sources") { model.sources.count == 1 }
        let source = try #require(model.sources.first)

        await model.renameSource(source, to: "   ")
        await model.renameSource(source, to: " S ")
        #expect(f.stub.calls("renameSource(_:to:)") == 0)
        #expect(model.errorMessage == nil)

        await model.renameSource(source, to: " Shows ")
        try await waitUntil("the new name") { model.sources.first?.name == "Shows" }
    }

    @Test func aSourceThatCannotBeAddedSaysWhich() async throws {
        let f = try await Fixture()
        let model = f.model()
        try await waitUntil("sources") { model.sources.count == 1 }
        let existing = try #require(model.sources.first)

        let added = await model.addSource(at: URL(fileURLWithPath: existing.rootPath, isDirectory: true))

        #expect(added == nil)
        #expect(model.errorMessage?.hasPrefix("Could not add ") == true, "\(model.errorMessage ?? "nil")")
    }
}
