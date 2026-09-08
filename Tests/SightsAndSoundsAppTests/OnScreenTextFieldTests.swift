import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// What the On-screen Text field lists and what Enter resolves to.
@Suite @MainActor struct OnScreenTextFieldTests {
    @Test func linesAreTrimmedDedupedAndKeptInReadingOrder() {
        let rows = OnScreenTextField.rows(
            lines: ["  Phish  ", "Live at", "phish", "", "Live at", "Red Rocks"], query: "")
        #expect(rows == ["Phish", "Live at", "Red Rocks"])
    }

    @Test func termsNarrowTheLines() {
        let lines = ["Phish", "Live at Red Rocks", "AUD source"]
        #expect(OnScreenTextField.rows(lines: lines, query: "red rock") == ["Live at Red Rocks"])
        #expect(OnScreenTextField.rows(lines: lines, query: "zzz").isEmpty)
    }

    @Test func aLineResolvesToATagByNameOrAliasThroughTheFold() {
        let band = TagCategory(name: "Band")
        let phish = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Phish")
        let sbd = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Soundboard")
        let index = TagSearchEntry.index(
            vocabulary: [(band, [phish, sbd])], aliases: [sbd.id: ["SBD"]])
        #expect(OnScreenTextField.resolve("PHISH", in: index)?.id == phish.id)
        #expect(OnScreenTextField.resolve("sbd", in: index)?.id == sbd.id)
        #expect(OnScreenTextField.resolve("Phishy", in: index) == nil)
    }
}
