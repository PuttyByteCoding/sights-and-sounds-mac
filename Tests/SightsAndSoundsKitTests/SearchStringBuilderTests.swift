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
