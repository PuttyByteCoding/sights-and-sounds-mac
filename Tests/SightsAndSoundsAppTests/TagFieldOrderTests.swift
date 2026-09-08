import Foundation
import Testing

@testable import SightsAndSoundsApp

/// The tag panel's Tab walk: the search categories in panel order, with
/// the Universal and Tag Analysis Results fields inserted at their
/// positions. Universal first when both land on one index.
@Suite @MainActor struct TagFieldOrderTests {
    private let a = UUID(), b = UUID(), c = UUID()
    private let universal = PlayerModel.universalFieldFocusID
    private let results = PlayerModel.analysisResultsFieldFocusID

    @Test func defaultsPutUniversalFirstThenResults() {
        let order = PlayerModel.tagFieldOrder(
            searchCategoryIDs: [a, b, c], universalPosition: 0, resultsPosition: 1)
        #expect(order == [universal, a, results, b, c])
    }

    @Test func bothAtOneIndexKeepUniversalFirst() {
        let order = PlayerModel.tagFieldOrder(
            searchCategoryIDs: [a, b], universalPosition: 1, resultsPosition: 1)
        #expect(order == [a, universal, results, b])
    }

    @Test func resultsBeforeUniversalWhenPositionedSo() {
        let order = PlayerModel.tagFieldOrder(
            searchCategoryIDs: [a, b], universalPosition: 2, resultsPosition: 0)
        #expect(order == [results, a, b, universal])
    }

    @Test func positionsPastTheEndMeanLast() {
        let order = PlayerModel.tagFieldOrder(
            searchCategoryIDs: [a], universalPosition: 9, resultsPosition: 9)
        #expect(order == [a, universal, results])
    }

    @Test func noCategoriesStillWalksTheTwoFields() {
        let order = PlayerModel.tagFieldOrder(
            searchCategoryIDs: [], universalPosition: 0, resultsPosition: 1)
        #expect(order == [universal, results])
    }
}
