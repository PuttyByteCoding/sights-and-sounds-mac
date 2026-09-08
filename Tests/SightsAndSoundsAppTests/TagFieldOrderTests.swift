import Foundation
import Testing

@testable import SightsAndSoundsApp

/// The seed for the panel's row order: the search categories in panel
/// order, with the Universal and Tag Analysis Results fields inserted at
/// their positions. Ties keep that declared order.
@Suite @MainActor struct TagFieldOrderTests {
    private let a = UUID(), b = UUID(), c = UUID()
    private let universal = PlayerModel.universalFieldFocusID
    private let results = PlayerModel.analysisResultsFieldFocusID

    private func order(_ ids: [UUID], _ u: Int, _ r: Int) -> [UUID] {
        PlayerModel.tagFieldOrder(searchCategoryIDs: ids, universalPosition: u, resultsPosition: r)
    }

    @Test func defaultsPutUniversalFirstThenResults() {
        #expect(order([a, b, c], 0, 1) == [universal, a, results, b, c])
    }

    @Test func bothAtOneIndexKeepUniversalFirst() {
        #expect(order([a, b], 1, 1) == [a, universal, results, b])
    }

    @Test func resultsBeforeUniversalWhenPositionedSo() {
        #expect(order([a, b], 2, 0) == [results, a, b, universal])
    }

    @Test func positionsPastTheEndMeanLast() {
        #expect(order([a], 9, 9) == [a, universal, results])
    }

    @Test func noCategoriesStillWalksTheTwoFields() {
        #expect(order([], 0, 1) == [universal, results])
    }
}
