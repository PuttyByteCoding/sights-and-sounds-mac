import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The Universal row is the one place a tag in ANY category is found —
/// including one already on the item, which it lists marked `applied`
/// so the pick (a toggle in the player) takes it off. The ↑ ↓ lists
/// stay suggestions and never offer an applied tag.
@Suite @MainActor struct TagUniversalToggleTests {
    private let band = TagCategory(name: "Band", colorIndex: 0)

    private func entry(_ tag: SightsAndSoundsKit.Tag) -> TagSearchEntry {
        TagSearchEntry(
            tag: tag, categoryID: band.id, categoryName: band.name, colorIndex: band.colorIndex,
            foldedName: TagSearchEntry.fold(tag.name), foldedAliases: [])
    }

    @Test func aTypedSearchListsAnAppliedTagMarkedApplied() {
        let phish = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Phish")
        let phil = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Phil Lesh")
        let hits = UniversalTagField.searchHits(
            index: [entry(phish), entry(phil)], appliedIDs: [phish.id], analysisTagIDs: [],
            query: "ph", limit: 10)
        #expect(hits.map(\.tag.name) == ["Phil Lesh", "Phish"])
        #expect(hits.first { $0.tag.name == "Phish" }?.applied == true)
        #expect(hits.first { $0.tag.name == "Phil Lesh" }?.applied == false)
    }

    /// An exact name typed selects its row for Enter; when that tag is
    /// on the item the row is the applied one, so Enter removes it
    /// rather than offering to create a duplicate.
    @Test func anExactlyTypedAppliedTagIsStillTheMatch() {
        let phish = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Phish")
        let hits = UniversalTagField.searchHits(
            index: [entry(phish)], appliedIDs: [phish.id], analysisTagIDs: [],
            query: "phish", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.applied == true)
    }

    /// What Tag Analysis found is a SUGGESTION: an applied finding does
    /// not lead the list as analysis; it appears once, as applied, with
    /// the rest of the vocabulary.
    @Test func anAppliedAnalysisFindingIsNotOfferedAsASuggestion() {
        let phish = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Phish")
        let hits = UniversalTagField.searchHits(
            index: [entry(phish)], appliedIDs: [phish.id], analysisTagIDs: [phish.id],
            query: "ph", limit: 10)
        #expect(hits.map(\.tag.name) == ["Phish"])
        #expect(hits.first?.fromAnalysis == false)
        #expect(hits.first?.applied == true)
    }
}
