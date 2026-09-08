import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// What the On-screen Text field lists: the tags the analysis found in
/// the read text first, then the raw lines, both narrowed by typing.
@Suite @MainActor struct OnScreenTextFieldTests {
    private let band = TagCategory(name: "Band")

    private func finding(_ name: String, in line: String) -> ExistingTagFinding {
        ExistingTagFinding(
            tag: SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: name),
            categoryName: band.name, matchedText: name, foundIn: line, alreadyApplied: false)
    }

    @Test func tagsLeadThenTheLinesTrimmedDedupedInReadingOrder() {
        let rows = OnScreenTextField.rows(
            findings: [finding("Phish", in: "phish")],
            lines: ["  Phish  ", "Live at", "phish", "", "Live at", "Red Rocks"], query: "")
        #expect(rows.map(\.label) == ["Phish", "Phish", "Live at", "Red Rocks"])
        #expect(rows.first?.isTag == true)
        #expect(rows.dropFirst().allSatisfy { !$0.isTag })
    }

    @Test func termsNarrowBothSections() {
        let rows = OnScreenTextField.rows(
            findings: [finding("Phish", in: "x"), finding("Red Rocks", in: "y")],
            lines: ["Phish", "Live at Red Rocks", "AUD source"], query: "red rock")
        #expect(rows.map(\.label) == ["Red Rocks", "Live at Red Rocks"])
        #expect(OnScreenTextField.rows(findings: [], lines: ["Phish"], query: "zzz").isEmpty)
    }

    @Test func aTagAppliedAlreadyIsLeftOut() {
        let phish = finding("Phish", in: "x")
        let rows = OnScreenTextField.rows(
            findings: [phish], lines: [], query: "", appliedIDs: [phish.tag.id])
        #expect(rows.isEmpty)
    }
}
