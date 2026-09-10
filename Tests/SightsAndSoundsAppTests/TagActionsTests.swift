import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The alias picker's list and the delete confirmation's copy.
@Suite @MainActor struct TagActionsTests {
    private let category = UUID()

    private func tag(_ name: String) -> SightsAndSoundsKit.Tag {
        SightsAndSoundsKit.Tag(tagCategoryID: category, name: name)
    }

    @Test func theCandidatesLeaveOutTheTagItselfAndSortByName() {
        let phish = tag("Phish"), wilco = tag("Wilco"), beck = tag("Beck")
        let shown = AliasTargetSheet.candidates([phish, wilco, beck], excluding: phish.id, query: "")
        #expect(shown.map(\.name) == ["Beck", "Wilco"])
    }

    @Test func everyTermMustHitFoldedLikeTheSearchFields() {
        let a = tag("Tim O'Neil"), b = tag("Tim Reynolds"), c = tag("Dave Matthews Band")
        #expect(AliasTargetSheet.candidates([a, b, c], excluding: UUID(), query: "tim oneil").map(\.name) == ["Tim O'Neil"])
        #expect(AliasTargetSheet.candidates([a, b, c], excluding: UUID(), query: "tim").count == 2)
    }

    @Test func theDeleteMessageCountsItemsAndPointsAtTheAlternative() {
        #expect(TagActionCopy.deleteMessage(uses: 1).hasPrefix("Removes the tag from 1 item."))
        #expect(TagActionCopy.deleteMessage(uses: 12).hasPrefix("Removes the tag from 12 items."))
        #expect(TagActionCopy.deleteMessage(uses: 0).contains("Add as Alias"))
    }
}
