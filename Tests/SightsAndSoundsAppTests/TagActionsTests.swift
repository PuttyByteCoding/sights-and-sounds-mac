import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The tag picker's list (alias and replace share it) and the delete
/// confirmation's copy.
@Suite @MainActor struct TagActionsTests {
    private let band = UUID(), venue = UUID()

    private func pick(_ name: String, in category: UUID = UUID(), named categoryName: String = "Band") -> TagPick {
        TagPick(tag: SightsAndSoundsKit.Tag(tagCategoryID: category, name: name), categoryName: categoryName)
    }

    @Test func theCandidatesLeaveOutTheTagItselfAndSortByName() {
        let phish = pick("Phish"), wilco = pick("Wilco"), beck = pick("Beck")
        let shown = TagPickerSheet.candidates([phish, wilco, beck], excluding: phish.id, query: "")
        #expect(shown.map(\.tag.name) == ["Beck", "Wilco"])
    }

    @Test func everyTermMustHitFoldedLikeTheSearchFields() {
        let a = pick("Tim O'Neil"), b = pick("Tim Reynolds"), c = pick("Dave Matthews Band")
        #expect(TagPickerSheet.candidates([a, b, c], excluding: UUID(), query: "tim oneil").map(\.tag.name) == ["Tim O'Neil"])
        #expect(TagPickerSheet.candidates([a, b, c], excluding: UUID(), query: "tim").count == 2)
    }

    /// The library-wide list (replace) narrows on the category name too,
    /// so "venue red" finds Red Rocks the venue and not Red the band.
    @Test func aQueryNarrowsOnTheCategoryNameInTheLibraryWideList() {
        let redBand = pick("Red", in: band, named: "Band")
        let redRocks = pick("Red Rocks", in: venue, named: "Venue")
        let shown = TagPickerSheet.candidates([redBand, redRocks], excluding: UUID(), query: "venue red")
        #expect(shown.map(\.tag.name) == ["Red Rocks"])
    }

    @Test func theDeleteMessageCountsItemsAndPointsAtTheAlternative() {
        #expect(TagActionCopy.deleteMessage(uses: 1).hasPrefix("Removes the tag from 1 item."))
        #expect(TagActionCopy.deleteMessage(uses: 12).hasPrefix("Removes the tag from 12 items."))
        #expect(TagActionCopy.deleteMessage(uses: 0).contains("Add as Alias"))
    }
}
