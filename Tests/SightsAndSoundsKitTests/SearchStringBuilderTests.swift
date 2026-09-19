import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The builder: a recipe and an item in, one string out. Replacements
/// first, exclusions second, formatting last; literals are prose for
/// the search engine and never reach the bookmark terms.
@Suite struct SearchStringBuilderTests {
    let band = UUID()
    let year = UUID()
    let venue = UUID()
    let taper = UUID()

    private func subject(_ fileName: String = "sdg_BenFoldsFive_OnStage_2019.mp4") -> SearchSubject {
        SearchSubject(
            fileName: fileName,
            tags: [
                SearchSubjectTag(categoryID: band, name: "Ben Folds Five"),
                SearchSubjectTag(categoryID: year, name: "2019"),
                SearchSubjectTag(categoryID: venue, name: "On Stage"),
                SearchSubjectTag(categoryID: taper, name: "Mike Jones"),
            ])
    }

    private func tags(_ id: UUID?, _ letterCase: SearchLetterCase = .asIs, _ quoting: SearchQuoting = .never,
                      joiner: String = " ") -> SearchPart {
        SearchPart(kind: .tags(categoryID: id, joiner: joiner), format: SearchFormat(letterCase: letterCase, quoting: quoting))
    }

    /// The spec's example, verbatim.
    @Test func theExampleFromTheSpec() {
        let recipe = SearchRecipe(parts: [
            tags(band, .asIs, .multiWord),
            tags(year),
            SearchPart(kind: .literal("at the venue")),
            tags(venue, .lowercase, .multiWord),
        ])
        #expect(SearchStringBuilder.string(recipe: recipe, subject: subject())
            == #""Ben Folds Five" 2019 at the venue "on stage""#)
        #expect(SearchStringBuilder.bookmarkTerms(recipe: recipe, subject: subject())
            == ["Ben Folds Five", "2019", "on stage"])
    }

    @Test func theFileNameComesWholeOrInPiecesWithOrWithoutItsExtension() {
        let whole = SearchRecipe(parts: [SearchPart(kind: .fileName(includesExtension: true, splitsPieces: false))])
        #expect(SearchStringBuilder.string(recipe: whole, subject: subject()) == "sdg_BenFoldsFive_OnStage_2019.mp4")
        let stem = SearchRecipe(parts: [SearchPart(kind: .fileName(includesExtension: false, splitsPieces: false))])
        #expect(SearchStringBuilder.string(recipe: stem, subject: subject()) == "sdg_BenFoldsFive_OnStage_2019")
        let pieces = SearchRecipe(
            parts: [SearchPart(kind: .fileName(includesExtension: false, splitsPieces: true), format: SearchFormat(quoting: .multiWord))],
            rules: [SearchRule(kind: .exclude("SDG"))])
        #expect(SearchStringBuilder.string(recipe: pieces, subject: subject()) == #""Ben Folds Five" "On Stage" 2019"#)
        // A name with no underscore has no pieces: the stem stands as one value.
        #expect(SearchStringBuilder.string(recipe: pieces, subject: subject("Ben Folds.mp4")) == #""Ben Folds""#)
    }

    @Test func everyCaseAndEveryQuoting() {
        func one(_ letterCase: SearchLetterCase, _ quoting: SearchQuoting) -> String {
            SearchStringBuilder.string(recipe: SearchRecipe(parts: [tags(band, letterCase, quoting), tags(year, letterCase, quoting)]), subject: subject())
        }
        #expect(one(.asIs, .never) == "Ben Folds Five 2019")
        #expect(one(.lowercase, .never) == "ben folds five 2019")
        #expect(one(.uppercase, .never) == "BEN FOLDS FIVE 2019")
        #expect(one(.titleCase, .never) == "Ben Folds Five 2019")
        #expect(one(.asIs, .multiWord) == #""Ben Folds Five" 2019"#)
        #expect(one(.asIs, .always) == #""Ben Folds Five" "2019""#)
    }

    @Test func allCategoriesListsEveryTagWithTheJoiner() {
        let recipe = SearchRecipe(parts: [tags(nil, joiner: ", ")])
        #expect(SearchStringBuilder.string(recipe: recipe, subject: subject()) == "Ben Folds Five, 2019, On Stage, Mike Jones")
    }

    /// The rules run in THEIR order, one value at a time. Replace then
    /// exclude drops "Ben-Folds-Five" once it reads "Ben Folds Five";
    /// exclude then replace never sees the spaced form and keeps it.
    @Test func rulesRunInTheOrderTheyAreListed() {
        let parts = [SearchPart(kind: .fileName(includesExtension: false, splitsPieces: true))]
        let replace = SearchRule(kind: .replace(from: "-", to: " "))
        let exclude = SearchRule(kind: .exclude("ben folds five"))
        let name = "Ben-Folds-Five_OnStage_2019.mp4"
        #expect(SearchStringBuilder.string(recipe: SearchRecipe(parts: parts, rules: [replace, exclude]), subject: subject(name))
            == "On Stage 2019")
        #expect(SearchStringBuilder.string(recipe: SearchRecipe(parts: parts, rules: [exclude, replace]), subject: subject(name))
            == "Ben Folds Five On Stage 2019")
    }

    /// An exclusion removes its text wherever it appears in a value,
    /// ignoring case — inside a word as much as standing alone — and a
    /// value left empty by it is dropped. A replacement with nothing on
    /// the right removes text the same way, case-sensitively.
    @Test func anExclusionRemovesTheTextWhereverItAppears() {
        let whole = SearchRecipe(
            parts: [SearchPart(kind: .fileName(includesExtension: false, splitsPieces: false))],
            rules: [SearchRule(kind: .exclude("sdg"))])
        #expect(SearchStringBuilder.string(recipe: whole, subject: subject("sdgBenFoldsSDG.mp4")) == "BenFolds")
        #expect(SearchStringBuilder.string(recipe: whole, subject: subject("Ben sdg Folds.mp4")) == "Ben  Folds")

        let pieces = SearchRecipe(
            parts: [SearchPart(kind: .fileName(includesExtension: false, splitsPieces: true))],
            rules: [SearchRule(kind: .exclude("sdg")), SearchRule(kind: .replace(from: "Stage", to: ""))])
        // "sdg" as a whole piece vanishes; "On Stage" loses "Stage".
        #expect(SearchStringBuilder.string(recipe: pieces, subject: subject("sdg_OnStage_2019.mp4")) == "On 2019")
        // Case: the exclusion ignores it, the replacement does not.
        let cased = SearchRecipe(
            parts: [SearchPart(kind: .fileName(includesExtension: false, splitsPieces: false))],
            rules: [SearchRule(kind: .replace(from: "stage", to: ""))])
        #expect(SearchStringBuilder.string(recipe: cased, subject: subject("OnStage.mp4")) == "OnStage")
    }

    /// The editor shows, under each rule, the string as it stands once
    /// that rule and the ones above it have run: one string per rule,
    /// in rule order, the last one being the whole recipe's string.
    @Test func theStringAfterEachRuleIsTheRecipeCutOffThere() {
        let recipe = SearchRecipe(
            parts: [SearchPart(kind: .fileName(includesExtension: false, splitsPieces: true), format: SearchFormat(quoting: .multiWord))],
            rules: [
                SearchRule(kind: .replace(from: "-", to: " ")),
                SearchRule(kind: .exclude("sdg")),
                SearchRule(kind: .exclude("ben folds five")),
            ])
        let steps = SearchStringBuilder.stringsAfterEachRule(recipe: recipe, subject: subject("sdg_Ben-Folds-Five_OnStage_2019.mp4"))
        #expect(steps == [
            #"sdg "Ben Folds Five" "On Stage" 2019"#,
            #""Ben Folds Five" "On Stage" 2019"#,
            #""On Stage" 2019"#,
        ])
        #expect(steps.last == SearchStringBuilder.string(recipe: recipe, subject: subject("sdg_Ben-Folds-Five_OnStage_2019.mp4")))
        #expect(SearchStringBuilder.stringsAfterEachRule(recipe: SearchRecipe(parts: recipe.parts), subject: subject()).isEmpty)
    }

    /// Split is a rule like the others, so it can come after a replace
    /// or an exclude: each value breaks at the separator into pieces,
    /// optionally at the capitals inside a run as well, and every rule
    /// below works on the pieces. Empty pieces vanish.
    @Test func aSplitRuleBreaksValuesIntoPiecesInItsPlaceInTheOrder() {
        let whole = SearchPart(kind: .fileName(includesExtension: false, splitsPieces: false), format: SearchFormat(quoting: .multiWord))
        let name = "sdg_Ben-Folds-Five_OnStage__2019.mp4"

        // Split alone: at the separator, words left as they are.
        let plain = SearchRecipe(parts: [whole], rules: [SearchRule(kind: .split(separator: "_", titleCaseWords: false, keep: .all))])
        #expect(SearchStringBuilder.string(recipe: plain, subject: subject(name)) == "sdg Ben-Folds-Five OnStage 2019")

        // Split with the capitals: the squashed name gets its spaces back.
        let words = SearchRecipe(parts: [whole], rules: [SearchRule(kind: .split(separator: "_", titleCaseWords: true, keep: .all))])
        #expect(SearchStringBuilder.string(recipe: words, subject: subject(name)) == #"sdg Ben-Folds-Five "On Stage" 2019"#)

        // Replace, then split, then exclude: the pieces are what the
        // exclude sees, so "sdg" goes as a piece of its own.
        let ordered = SearchRecipe(parts: [whole], rules: [
            SearchRule(kind: .replace(from: "-", to: " ")),
            SearchRule(kind: .split(separator: "_", titleCaseWords: true, keep: .all)),
            SearchRule(kind: .exclude("sdg")),
        ])
        #expect(SearchStringBuilder.string(recipe: ordered, subject: subject(name)) == #""Ben Folds Five" "On Stage" 2019"#)
        #expect(SearchStringBuilder.stringsAfterEachRule(recipe: ordered, subject: subject(name)) == [
            #""sdg_Ben Folds Five_OnStage__2019""#,
            #"sdg "Ben Folds Five" "On Stage" 2019"#,
            #""Ben Folds Five" "On Stage" 2019"#,
        ])

        // An empty separator splits nothing.
        let none = SearchRecipe(parts: [whole], rules: [SearchRule(kind: .split(separator: "", titleCaseWords: false, keep: .all))])
        #expect(SearchStringBuilder.string(recipe: none, subject: subject(name)) == "sdg_Ben-Folds-Five_OnStage__2019")
    }

    /// Split can keep every piece, only the first, or only the last —
    /// "the band is before the first underscore", "the date is after
    /// the last". First and last mean the first and last piece with
    /// something in it, so a doubled separator does not choose nothing.
    @Test func aSplitRuleCanKeepTheFirstOrTheLastPiece() {
        let whole = SearchPart(kind: .fileName(includesExtension: false, splitsPieces: false))
        let name = "sdg_BenFolds_OnStage__2019.mp4"
        func split(_ keep: SearchSplitKeep) -> SearchRecipe {
            SearchRecipe(parts: [whole], rules: [SearchRule(kind: .split(separator: "_", titleCaseWords: true, keep: keep))])
        }
        #expect(SearchStringBuilder.string(recipe: split(.all), subject: subject(name)) == "sdg Ben Folds On Stage 2019")
        #expect(SearchStringBuilder.string(recipe: split(.first), subject: subject(name)) == "sdg")
        #expect(SearchStringBuilder.string(recipe: split(.last), subject: subject(name)) == "2019")
        // Keep last, then exclude what is left, is still nothing.
        let lastThenGone = SearchRecipe(parts: [whole], rules: [
            SearchRule(kind: .split(separator: "_", titleCaseWords: false, keep: .last)),
            SearchRule(kind: .exclude("2019")),
        ])
        #expect(SearchStringBuilder.string(recipe: lastThenGone, subject: subject(name)) == "")
    }

    @Test func aMissingCategoryIsSkippedAndNamed() {
        let gone = UUID()
        let recipe = SearchRecipe(parts: [tags(band), tags(gone), SearchPart(kind: .literal("live"))])
        #expect(SearchStringBuilder.string(recipe: recipe, subject: subject()) == "Ben Folds Five live")
        #expect(SearchStringBuilder.missingCategoryIDs(in: recipe, known: [band, year, venue, taper]) == [gone])
    }

    @Test func anEmptyValueLeavesNoGap() {
        let recipe = SearchRecipe(
            parts: [tags(band), SearchPart(kind: .literal("")), tags(year)],
            rules: [SearchRule(kind: .replace(from: "2019", to: ""))])
        #expect(SearchStringBuilder.string(recipe: recipe, subject: subject()) == "Ben Folds Five")
        #expect(SearchStringBuilder.bookmarkTerms(recipe: recipe, subject: subject()) == ["Ben Folds Five"])
    }

    @Test func theSubjectComesFromTheLibrary() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Subject")
        let source = Source(name: "S", rootPath: "/tmp/subject")
        let category = TagCategory(name: "Band")
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/a_b.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try category.insert(db)
            try item.insert(db)
        }
        let tag = try library.ensureTag(named: "Phish", inCategory: category.id)
        try library.assignTag(tag.id, to: item.id)
        let found = try #require(try library.searchSubject(for: item.id))
        #expect(found.fileName == "a_b.mp4")
        #expect(found.tags == [SearchSubjectTag(categoryID: category.id, name: "Phish")])
        #expect(try library.searchSubject(for: UUID()) == nil)
    }
}
