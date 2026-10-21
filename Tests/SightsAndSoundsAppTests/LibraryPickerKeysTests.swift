import Foundation
import Testing

@testable import SightsAndSoundsApp

/// The picker's rows used to be reachable only with a pointer; ↑ and ↓
/// now move the selection, and Return opens it as before.
@Suite struct LibraryPickerKeysTests {
    private let ids = (0..<3).map { _ in UUID() }

    @Test func downAndUpMoveOneRowAndStopAtTheEnds() {
        #expect(LibraryPickerKeys.selection(after: 1, from: ids[0], in: ids) == ids[1])
        #expect(LibraryPickerKeys.selection(after: 1, from: ids[2], in: ids) == ids[2])
        #expect(LibraryPickerKeys.selection(after: -1, from: ids[1], in: ids) == ids[0])
        #expect(LibraryPickerKeys.selection(after: -1, from: ids[0], in: ids) == ids[0])
    }

    /// Nothing selected, or a selection the list no longer has (a library
    /// forgotten while the dialog was up): either key lands on the first row.
    @Test func noSelectionOrAStaleOneStartsAtTheTop() {
        #expect(LibraryPickerKeys.selection(after: 1, from: nil, in: ids) == ids[0])
        #expect(LibraryPickerKeys.selection(after: -1, from: nil, in: ids) == ids[0])
        #expect(LibraryPickerKeys.selection(after: 1, from: UUID(), in: ids) == ids[0])
    }

    @Test func anEmptyListHasNothingToSelect() {
        #expect(LibraryPickerKeys.selection(after: 1, from: nil, in: []) == nil)
        #expect(LibraryPickerKeys.selection(after: -1, from: ids[0], in: []) == nil)
    }
}
