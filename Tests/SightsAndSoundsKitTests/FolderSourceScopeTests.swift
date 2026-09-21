import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The sidebar nests a folder tree under each source, with counts for
/// that source — so the term a folder click produces has to know its
/// source too. Two drives both holding a `shows` folder is ordinary.
@Suite struct FolderSourceScopeTests {

    private struct Fixture {
        let library: LibraryDatabase
        let first = Source(name: "First", rootPath: "/tmp/sas-scope-first")
        let second = Source(name: "Second", rootPath: "/tmp/sas-scope-second")

        init() throws {
            library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Scope")
            try library.writer.write { [first, second] db in
                try first.insert(db)
                try second.insert(db)
                for (source, names) in [(first, ["a", "b"]), (second, ["c"])] {
                    for name in names {
                        try MediaItem(
                            sourceID: source.id, kind: .video,
                            relativePath: "shows/\(name).mp4", needsReview: false).insert(db)
                    }
                }
            }
        }

        func names(_ filter: MediaFilter) throws -> [String] {
            try library.mediaItems(matching: filter, kinds: .all).map(\.fileName).sorted()
        }
    }

    @Test func aFolderUnderOneSourceListsOnlyThatSourcesItems() throws {
        let f = try Fixture()
        var filter = MediaFilter()
        filter.selectSubtree("shows", sourceID: f.first.id)

        #expect(try f.names(filter) == ["a.mp4", "b.mp4"])
        // …which is what that source's row in the tree says.
        let count = try f.library.folderCounts(kinds: .all, sourceID: f.first.id)
            .first { $0.path == "shows" }?.count
        #expect(count == 2)
    }

    @Test func theSourceTermStandsOnItsOwn() throws {
        let f = try Fixture()
        #expect(try f.names(MediaFilter(required: [.source(f.second.id)])) == ["c.mp4"])
        #expect(try f.names(MediaFilter(excluded: [.source(f.second.id)])) == ["a.mp4", "b.mp4"])
    }

    @Test func selectingAFolderReplacesTheLastFolderAndItsSource() throws {
        let f = try Fixture()
        var filter = MediaFilter(required: [.tag(UUID())])
        filter.selectSubtree("shows", sourceID: f.first.id)
        filter.selectSubtree("shows", sourceID: f.second.id)

        #expect(filter.required.filter { if case .source = $0 { true } else { false } }
            == [.source(f.second.id)])
        #expect(filter.required.filter { if case .subtree = $0 { true } else { false } }
            == [.subtree("shows")])

        #expect(filter.treeScope?.path == "shows")
        #expect(filter.treeScope?.sourceID == f.second.id)

        // Clearing the chips keeps where you are, source included…
        filter.clearSlots()
        #expect(filter.required == [.source(f.second.id), .subtree("shows")])
        // …the tree's scope is not a chip…
        #expect(filter.slottedTerms.isEmpty)
        // …and clearing the folder clears its source with it.
        filter.selectSubtree(nil, sourceID: nil)
        #expect(filter.required.isEmpty)
        #expect(filter.treeScope == nil)
    }

    @Test func aFilterSavedBeforeTheSourceTermStillDecodes() throws {
        let old = #"{"required":[{"subtree":{"_0":"shows"}}],"optional":[],"excluded":[],"searchText":""}"#
        let decoded = try JSONDecoder().decode(MediaFilter.self, from: Data(old.utf8))
        #expect(decoded.required == [.subtree("shows")])
    }

    @Test func folderCountsLeaveOutWhatTheGridHides() throws {
        let f = try Fixture()
        let category = TagCategory(name: "Flags", sortOrder: 0)
        var hidden = Tag(tagCategoryID: category.id, name: "Private", sortOrder: 0)
        hidden.hiddenByDefault = true
        try f.library.writer.write { [hidden] db in
            try category.insert(db)
            try hidden.insert(db)
            let item = try MediaItem.filter(sql: "fileName = 'a.mp4'").fetchOne(db)!
            try MediaItemTag(mediaItemID: item.id, tagID: hidden.id).insert(db)
        }

        let count = try f.library.folderCounts(kinds: .all, sourceID: f.first.id)
            .first { $0.path == "shows" }?.count
        #expect(count == 1)  // the grid shows b.mp4 only
        var filter = MediaFilter()
        filter.selectSubtree("shows", sourceID: f.first.id)
        #expect(try f.names(filter) == ["b.mp4"])
    }
}
