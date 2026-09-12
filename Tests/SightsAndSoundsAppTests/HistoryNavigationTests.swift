import Foundation
import Testing

@testable import SightsAndSoundsApp

/// ↑ ↓ through the history panel: no wrap, and a first press lands at
/// the end the arrow came from.
@Suite struct HistoryNavigationTests {
    private let ids = (0..<3).map { _ in UUID() }

    @Test func aFirstPressLandsAtTheEndTheArrowCameFrom() {
        #expect(HistoryNavigation.next(after: nil, in: ids, delta: 1) == ids[0])
        #expect(HistoryNavigation.next(after: nil, in: ids, delta: -1) == ids[2])
    }

    @Test func stepsStayInsideTheListAndDoNotWrap() {
        #expect(HistoryNavigation.next(after: ids[0], in: ids, delta: 1) == ids[1])
        #expect(HistoryNavigation.next(after: ids[2], in: ids, delta: 1) == ids[2])
        #expect(HistoryNavigation.next(after: ids[0], in: ids, delta: -1) == ids[0])
    }

    @Test func aSelectionNoLongerListedStartsOver() {
        #expect(HistoryNavigation.next(after: UUID(), in: ids, delta: 1) == ids[0])
        #expect(HistoryNavigation.next(after: ids[0], in: [], delta: 1) == nil)
    }
}
