import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 3a kit support: the folder tree, the browse queries' shared
/// baseline, and the filter panel's mutation helpers.
@Suite struct BrowseSupportTests {

    // MARK: Folder tree

    @Test func treeNestsAndCountsIncludingImplicitParents() {
        let tree = FolderTreeBuilder.build(from: [
            ("shows/1995", 2),
            ("shows/1995/disc2", 1),
            ("shows/2001", 3),
            ("deep/a/b", 1),        // "deep" and "deep/a" hold no files directly
        ])
        #expect(tree.map(\.name) == ["deep", "shows"])

        let shows = tree[1]
        #expect(shows.directCount == 0)
        #expect(shows.subtreeCount == 6)
        #expect(shows.children.map(\.path) == ["shows/1995", "shows/2001"])
        #expect(shows.children[0].subtreeCount == 3)

        let deep = tree[0]
        #expect(deep.children[0].name == "a")
        #expect(deep.children[0].children[0].path == "deep/a/b")
        #expect(deep.subtreeCount == 1)
    }

    @Test func rootLevelFilesAndEmptyInput() {
        #expect(FolderTreeBuilder.build(from: []).isEmpty)
        // Items at the library root ("" folder) create no node — the grid's
        // "All Items" row covers them.
        let tree = FolderTreeBuilder.build(from: [("", 4), ("x", 1)])
        #expect(tree.map(\.path) == ["x"])
    }

    @Test func folderCountsRespectTheListingBaseline() throws {
        let f = try FilterFixture()
        let counts = Dictionary(
            uniqueKeysWithValues: try f.library.folderCounts(kind: .video).map { ($0.path, $0.count) })
        #expect(counts["shows/1995"] == 1)
        // The spent clip row (clips/l.mp4) is excluded: clips has i, j, k only.
        #expect(counts["clips"] == 3)
        // Audio kind is a separate tree.
        #expect(counts["misc"] == nil)

        // Disabling the source empties the tree.
        try f.library.writer.write { db in
            var off = f.mainSource
            off.enabled = false
            try off.update(db)
        }
        #expect(try f.library.folderCounts(kind: .video).isEmpty)
    }

    // MARK: Vocabulary

    @Test func vocabularyOrdersCategoriesAndTags() throws {
        let f = try FilterFixture()
        let vocabulary = try f.library.vocabulary()
        #expect(vocabulary.map(\.category.name) == ["Band", "Recording Type"])
        #expect(vocabulary[0].tags.map(\.name).sorted() == ["Band A", "Band B", "Secret"])
    }

    // MARK: Filter mutation helpers

    @Test func tagCycleWalksRequiredExcludedCleared() {
        var filter = MediaFilter()
        let id = UUID()

        filter.cycleTag(id)
        #expect(filter.slot(of: id) == .required)
        filter.cycleTag(id)
        #expect(filter.slot(of: id) == .excluded)
        filter.cycleTag(id)
        #expect(filter.slot(of: id) == nil)
        #expect(filter.isEmpty)
    }

    @Test func cycleFromOptionalMovesToExcluded() {
        let id = UUID()
        var filter = MediaFilter(optional: [.tag(id)])
        filter.cycleTag(id)
        #expect(filter.slot(of: id) == .excluded)
        #expect(filter.optional.isEmpty)
    }

    @Test func statusToggleFlips() {
        var filter = MediaFilter()
        filter.toggleStatus(.favorite)
        #expect(filter.required == [.status(.favorite)])
        filter.toggleStatus(.favorite)
        #expect(filter.isEmpty)
    }

    @Test func subtreeSelectionReplacesAnyFolderTerm() {
        var filter = MediaFilter(required: [.folder("a/b"), .status(.favorite)])
        filter.selectSubtree("shows")
        // The status term survives; the folder term is replaced.
        #expect(filter.required.contains(.status(.favorite)))
        #expect(filter.required.contains(.subtree("shows")))
        #expect(!filter.required.contains(.folder("a/b")))

        filter.selectSubtree(nil)
        #expect(filter.required == [.status(.favorite)])
    }
}
