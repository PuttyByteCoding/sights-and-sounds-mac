import Foundation
import SightsAndSoundsKit
import SwiftUI
import Testing

@testable import SightsAndSoundsApp

/// The Universal field's list puts what Tag Analysis found first, then
/// the rest of the vocabulary, one row per tag, capped like autocomplete.
@Suite @MainActor struct UniversalTagFieldTests {
    private func hit(_ name: String, analysis: Bool = false) -> UniversalTagField.Hit {
        UniversalTagField.Hit(
            tag: SightsAndSoundsKit.Tag(tagCategoryID: UUID(), name: name),
            categoryName: "Band", categoryHue: .gray, matchedAlias: nil, fromAnalysis: analysis)
    }

    @Test func analysisRowsLeadAndAreNotRepeatedBelow() {
        let phish = hit("Phish", analysis: true)
        let rest = [hit("Audience"), UniversalTagField.Hit(
            tag: phish.tag, categoryName: "Band", categoryHue: .gray, matchedAlias: nil, fromAnalysis: false),
            hit("Soundboard")]
        let merged = UniversalTagField.merged(analysis: [phish], rest: rest, limit: 10)
        #expect(merged.map(\.tag.name) == ["Phish", "Audience", "Soundboard"])
        #expect(merged.first?.fromAnalysis == true)
    }

    @Test func theCapCountsBothHalves() {
        let analysis = [hit("A", analysis: true), hit("B", analysis: true)]
        let rest = [hit("C"), hit("D"), hit("E")]
        #expect(UniversalTagField.merged(analysis: analysis, rest: rest, limit: 3).map(\.tag.name) == ["A", "B", "C"])
        #expect(UniversalTagField.merged(analysis: analysis, rest: rest, limit: 1).map(\.tag.name) == ["A"])
    }

    private func finding(_ name: String, in line: String) -> ExistingTagFinding {
        ExistingTagFinding(
            tag: SightsAndSoundsKit.Tag(tagCategoryID: UUID(), name: name),
            categoryName: "Band", matchedText: name, foundIn: line, alreadyApplied: false)
    }

    @Test func aScreenReadListsTagsThenTrimmedDedupedLines() {
        let rows = UniversalTagField.screenRows(
            findings: [finding("Phish", in: "phish")],
            lines: ["  Phish  ", "Live at", "phish", "", "Live at", "Red Rocks"], query: "")
        #expect(rows.tags.map(\.tag.name) == ["Phish"])
        #expect(rows.lines == ["Phish", "Live at", "Red Rocks"])
    }

    @Test func termsNarrowBothHalvesOfAScreenRead() {
        let rows = UniversalTagField.screenRows(
            findings: [finding("Phish", in: "x"), finding("Red Rocks", in: "y")],
            lines: ["Phish", "Live at Red Rocks", "AUD source"], query: "red rock")
        #expect(rows.tags.map(\.tag.name) == ["Red Rocks"])
        #expect(rows.lines == ["Live at Red Rocks"])
    }

    @Test func aTagAppliedAlreadyIsLeftOutOfAScreenRead() {
        let phish = finding("Phish", in: "x")
        let rows = UniversalTagField.screenRows(
            findings: [phish], lines: [], query: "", appliedIDs: [phish.tag.id])
        #expect(rows.tags.isEmpty)
    }
}

/// Typed search ranks before it caps: the tag named exactly what was
/// typed is never pushed past the limit by the longer names that merely
/// contain it.
@Suite @MainActor struct TagSearchRankingTests {
    private func entry(_ name: String, aliases: [String] = []) -> TagSearchEntry {
        TagSearchEntry(
            tag: SightsAndSoundsKit.Tag(tagCategoryID: UUID(), name: name),
            categoryID: UUID(), categoryName: "Band", colorIndex: 0,
            foldedName: TagSearchEntry.fold(name),
            foldedAliases: aliases.map { ($0, TagSearchEntry.fold($0)) })
    }

    @Test func anExactNameLeadsHoweverManyNamesContainIt() {
        let crowd = (1...30).map { entry("Seether \($0)") }
        let index = crowd + [entry("ee")]
        let ranked = TagSearchEntry.ranked(index, query: "ee", limit: 15)
        #expect(ranked.first?.entry.tag.name == "ee")
        #expect(ranked.count == 15)
    }

    @Test func prefixBeatsContainsAndNamesBreakTies() {
        let index = [entry("Green Day"), entry("Reed"), entry("Eels"), entry("Beeline")]
        let names = TagSearchEntry.ranked(index, query: "ee", limit: 10).map(\.entry.tag.name)
        #expect(names == ["Eels", "Beeline", "Green Day", "Reed"])
    }

    @Test func anAliasMatchRanksLikeANameMatchAndNamesTheAlias() {
        let index = [entry("Soundboard", aliases: ["SBD"]), entry("Audience")]
        let ranked = TagSearchEntry.ranked(index, query: "sbd", limit: 10)
        #expect(ranked.map(\.entry.tag.name) == ["Soundboard"])
        #expect(ranked.first?.alias == "SBD")
    }

    @Test func everyTermMustHitAndTheNameWinsOverAnAlias() {
        let index = [entry("Tim O'Neil", aliases: ["Tim"]), entry("Tim Reynolds")]
        let ranked = TagSearchEntry.ranked(index, query: "tim oneil", limit: 10)
        #expect(ranked.map(\.entry.tag.name) == ["Tim O'Neil"])
        #expect(ranked.first?.alias == nil)
    }
}
