import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The grid could only be driven with a pointer: its key handler knew
/// `V` and Esc. Arrows move a focus, Return plays it, Space selects it.
@Suite @MainActor struct GridKeyboardFocusTests {

    @Test func theFirstArrowLandsOnTheFirstTile() {
        for move in [GridFocusMove.left, .right, .up, .down] {
            #expect(GridFocus.index(after: move, from: nil, count: 10, columns: 4) == 0)
        }
        #expect(GridFocus.index(after: .right, from: nil, count: 0, columns: 4) == nil)
    }

    @Test func leftAndRightWalkTheListingAndStopAtItsEnds() {
        #expect(GridFocus.index(after: .right, from: 0, count: 10, columns: 4) == 1)
        #expect(GridFocus.index(after: .right, from: 3, count: 10, columns: 4) == 4)  // wraps to the next row
        #expect(GridFocus.index(after: .right, from: 9, count: 10, columns: 4) == 9)
        #expect(GridFocus.index(after: .left, from: 4, count: 10, columns: 4) == 3)
        #expect(GridFocus.index(after: .left, from: 0, count: 10, columns: 4) == 0)
    }

    /// Ten tiles in four columns: rows of 4, 4 and 2.
    @Test func upAndDownKeepTheColumnAndARaggedLastRowTakesTheLastTile() {
        #expect(GridFocus.index(after: .down, from: 1, count: 10, columns: 4) == 5)
        #expect(GridFocus.index(after: .down, from: 5, count: 10, columns: 4) == 9)  // column 1 exists below
        #expect(GridFocus.index(after: .down, from: 6, count: 10, columns: 4) == 9)  // column 2 does not: the last tile
        #expect(GridFocus.index(after: .down, from: 9, count: 10, columns: 4) == 9)
        #expect(GridFocus.index(after: .up, from: 9, count: 10, columns: 4) == 5)
        #expect(GridFocus.index(after: .up, from: 2, count: 10, columns: 4) == 2)
    }

    @Test func aFocusOutsideTheListingStartsAgain() {
        #expect(GridFocus.index(after: .right, from: 42, count: 10, columns: 4) == 0)
        #expect(GridFocus.index(after: .down, from: 3, count: 10, columns: 0) == 4)  // never fewer than one column
    }

    @Test func columnsFollowTheWidthTheWayTheGridLaysThemOut() {
        // 16 pt padding each side, 16 pt between tiles, tiles at least 200.
        #expect(GridFocus.columns(width: 200 + 32, tileMinimum: 200) == 1)
        #expect(GridFocus.columns(width: 2 * 200 + 16 + 32, tileMinimum: 200) == 2)
        #expect(GridFocus.columns(width: 2 * 200 + 16 + 31, tileMinimum: 200) == 1)
        #expect(GridFocus.columns(width: 0, tileMinimum: 200) == 1)
    }

    @Test func theModelMovesSelectsAndForgetsAFocusThatLeftTheListing() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Focus")
        let source = Source(name: "S", rootPath: "/tmp/sas-focus-\(UUID().uuidString)")
        let items = ["a.mp4", "b.mp4", "c.mp4"].map {
            MediaItem(sourceID: source.id, kind: .video, relativePath: $0, needsReview: false)
        }
        try await library.writer.write { db in
            try source.insert(db)
            for item in items { try item.insert(db) }
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        for _ in 0..<400 where model.items.count != 3 { try await Task.sleep(for: .milliseconds(10)) }

        model.moveFocus(.right, columns: 2)
        #expect(model.focusedItemID == items[0].id)
        model.moveFocus(.down, columns: 2)
        #expect(model.focusedItemID == items[2].id)

        model.toggleSelectionOfFocusedItem()
        #expect(model.selection == [items[2].id])

        model.filter.searchText = "a.mp"
        for _ in 0..<400 where model.items.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.focusedItemID == nil)
    }
}
