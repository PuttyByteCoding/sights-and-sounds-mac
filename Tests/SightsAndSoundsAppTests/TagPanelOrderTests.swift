import Foundation
import Testing

@testable import SightsAndSoundsApp

/// One list of rows — categories and the three pseudo-fields — is the
/// panel's order. It reconciles against the vocabulary, seeds itself
/// from the older per-field numbers, and moves rows by intent.
@Suite @MainActor struct TagPanelOrderTests {
    private let a = UUID(), b = UUID(), c = UUID()

    @Test func anEmptyStoredOrderSeedsFromTheOldPositions() {
        let rows = TagPanelOrder.rows(
            vocabulary: [a, b], stored: [], seed: (universal: 0, results: 1, onScreen: 2))
        #expect(rows == [.universal, .category(a), .results, .category(b), .onScreen])
    }

    @Test func aStoredOrderIsKeptAndReconciled() {
        let stored = [PanelRow.category(b).key, PanelRow.onScreen.key, PanelRow.category(a).key,
                      PanelRow.universal.key, PanelRow.results.key]
        // c is new (appended), a stored id that no longer exists is dropped.
        let rows = TagPanelOrder.rows(
            vocabulary: [a, c, b], stored: stored + [UUID().uuidString],
            seed: (universal: 0, results: 1, onScreen: 2))
        #expect(rows == [.category(b), .onScreen, .category(a), .universal, .results, .category(c)])
    }

    @Test func aStoredOrderMissingAPseudoRowGetsItAppended() {
        let rows = TagPanelOrder.rows(
            vocabulary: [a], stored: [PanelRow.category(a).key, PanelRow.universal.key],
            seed: (universal: 0, results: 0, onScreen: 0))
        #expect(rows == [.category(a), .universal, .results, .onScreen])
    }

    @Test func movingBeforeAfterToTheEndAndOntoItself() {
        let rows: [PanelRow] = [.universal, .category(a), .results, .category(b)]
        #expect(TagPanelOrder.moved(rows, .category(b), before: .universal)
            == [.category(b), .universal, .category(a), .results])
        #expect(TagPanelOrder.moved(rows, .universal, before: .category(b))
            == [.category(a), .results, .universal, .category(b)])
        #expect(TagPanelOrder.moved(rows, .universal, before: nil)
            == [.category(a), .results, .category(b), .universal])
        #expect(TagPanelOrder.moved(rows, .results, before: .results) == rows)
    }

    @Test func rowKeysAndFocusIDsRoundTrip() {
        for row in [PanelRow.universal, .results, .onScreen, .category(a)] {
            #expect(PanelRow(key: row.key) == row)
            #expect(PanelRow(focusID: row.focusID) == row)
        }
        #expect(PanelRow(key: "nonsense") == nil)
    }
}
