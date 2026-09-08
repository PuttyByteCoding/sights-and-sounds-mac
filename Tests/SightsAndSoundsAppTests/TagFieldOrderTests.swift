import Foundation
import Testing

@testable import SightsAndSoundsApp

/// The tag panel's Tab walk: the search categories in panel order, with
/// the Universal, Tag Analysis Results and On-screen Text fields
/// inserted at their positions. Ties keep that declared order.
@Suite @MainActor struct TagFieldOrderTests {
    private let a = UUID(), b = UUID(), c = UUID()
    private let universal = PlayerModel.universalFieldFocusID
    private let results = PlayerModel.analysisResultsFieldFocusID
    private let onScreen = PlayerModel.onScreenTextFieldFocusID

    private func order(_ ids: [UUID], _ u: Int, _ r: Int, _ o: Int) -> [UUID] {
        PlayerModel.tagFieldOrder(
            searchCategoryIDs: ids, universalPosition: u, resultsPosition: r, onScreenPosition: o)
    }

    @Test func defaultsPutTheThreeFieldsFirstThenTheCategories() {
        #expect(order([a, b, c], 0, 1, 2) == [universal, a, results, b, onScreen, c])
    }

    @Test func aThreeWayTieKeepsTheDeclaredOrder() {
        #expect(order([a, b], 1, 1, 1) == [a, universal, results, onScreen, b])
    }

    @Test func anyPermutationLandsWhereItsPositionSays() {
        #expect(order([a, b], 2, 0, 1) == [results, a, onScreen, b, universal])
    }

    @Test func positionsPastTheEndMeanLast() {
        #expect(order([a], 9, 9, 9) == [a, universal, results, onScreen])
    }

    @Test func noCategoriesStillWalksTheThreeFields() {
        #expect(order([], 0, 1, 2) == [universal, results, onScreen])
    }
}
