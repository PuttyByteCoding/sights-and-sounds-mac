import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The rows the Tag Analysis Results field offers: the companion's
/// existing-tag findings, one per tag, minus what the video already
/// wears, in category order, narrowed by the typed terms.
@Suite @MainActor struct AnalysisResultsFieldTests {
    private let band = TagCategory(name: "Band")
    private let taper = TagCategory(name: "Taper")

    private func finding(_ tag: SightsAndSoundsKit.Tag, in category: TagCategory, matched: String? = nil,
                         applied: Bool = false) -> ExistingTagFinding {
        ExistingTagFinding(
            tag: tag, categoryName: category.name, matchedText: matched ?? tag.name,
            foundIn: "somewhere", alreadyApplied: applied)
    }

    private func analysis(_ findings: [ExistingTagFinding]) -> ItemAnalysis {
        ItemAnalysis(
            suggested: [], existing: findings, unmapped: [], md5s: [], matchedSchemas: [],
            readerReports: [], truncated: false, provenance: [])
    }

    @Test func oneRowPerTagInCategoryOrderMinusApplied() {
        let mike = SightsAndSoundsKit.Tag(tagCategoryID: taper.id, name: "Mike Jones")
        let phish = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Phish")
        let worn = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Worn Already")
        let rows = AnalysisResultsField.candidates(
            analysis: analysis([
                finding(mike, in: taper), finding(mike, in: taper),  // twice: two strings
                finding(phish, in: band), finding(worn, in: band, applied: true),
            ]),
            appliedIDs: [worn.id], categories: [band, taper], query: "")
        #expect(rows.map(\.tag.name) == ["Phish", "Mike Jones"])
        #expect(rows.map(\.categoryName) == ["Band", "Taper"])
    }

    @Test func termsNarrowByNameOrTheAliasThatMatched() {
        let sbd = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Soundboard")
        let aud = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Audience")
        let all = analysis([finding(sbd, in: band, matched: "SBD"), finding(aud, in: band)])
        #expect(AnalysisResultsField.candidates(
            analysis: all, appliedIDs: [], categories: [band], query: "sbd").map(\.tag.name)
            == ["Soundboard"])
        #expect(AnalysisResultsField.candidates(
            analysis: all, appliedIDs: [], categories: [band], query: "aud ien").map(\.tag.name)
            == ["Audience"])
        #expect(AnalysisResultsField.candidates(
            analysis: all, appliedIDs: [], categories: [band], query: "zzz").isEmpty)
    }

    @Test func aTagWhoseCategoryIsUnknownGoesLast() {
        let orphan = SightsAndSoundsKit.Tag(tagCategoryID: UUID(), name: "Orphan")
        let phish = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Phish")
        let rows = AnalysisResultsField.candidates(
            analysis: analysis([finding(orphan, in: taper), finding(phish, in: band)]),
            appliedIDs: [], categories: [band], query: "")
        #expect(rows.map(\.tag.name) == ["Phish", "Orphan"])
    }
}
