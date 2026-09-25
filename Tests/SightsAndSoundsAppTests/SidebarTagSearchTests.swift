import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The search box at the top of the sidebar finds tags across every
/// category as you type.
@Suite struct SidebarTagSearchTests {
    private let band = TagCategory(name: "Band", colorIndex: 0)
    private let venue = TagCategory(name: "Venue", colorIndex: 2)
    private let year = TagCategory(name: "Year", colorIndex: 3)

    // Built once: the tags' ids are what the alias and slot tests key on.
    private let vocabulary: [CategoryTags]

    init() {
        vocabulary = [
            CategoryTags(category: band, tags: [
                SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Blue Orchestra"),
                SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Red Quartet"),
            ]),
            CategoryTags(category: venue, tags: [
                SightsAndSoundsKit.Tag(tagCategoryID: venue.id, name: "Bluebird Hall"),
                SightsAndSoundsKit.Tag(tagCategoryID: venue.id, name: "The Barn"),
            ]),
            CategoryTags(category: year, tags: [
                SightsAndSoundsKit.Tag(tagCategoryID: year.id, name: "1999"),
            ]),
        ]
    }

    @Test func aQueryFindsTagsInEveryCategoryAndKeepsCategoryOrder() {
        let found = SidebarTagSearch.matches("blue", in: vocabulary, aliases: [:], isSlotted: { _ in false })
        #expect(found.map(\.category.name) == ["Band", "Venue"])
        #expect(found.flatMap(\.tags).map(\.name) == ["Blue Orchestra", "Bluebird Hall"])
    }

    @Test func caseAccentsAndPunctuationDoNotMatter() {
        for query in ["BLUE", "bLuE", "blue", "Blüe", "b.l.u.e"] {
            let found = SidebarTagSearch.matches(query, in: vocabulary, aliases: [:], isSlotted: { _ in false })
            #expect(found.flatMap(\.tags).map(\.name) == ["Blue Orchestra", "Bluebird Hall"], "query \(query) found \(found.flatMap(\.tags).map(\.name))")
        }
        // Upper-case in the tag, lower in the query.
        let found = SidebarTagSearch.matches("the barn", in: vocabulary, aliases: [:], isSlotted: { _ in false })
        #expect(found.flatMap(\.tags).map(\.name) == ["The Barn"])
    }

    @Test func anAliasFindsItsTag() {
        let barn = vocabulary[1].tags[1]
        let found = SidebarTagSearch.matches("shed", in: vocabulary, aliases: [barn.id: ["The Shed"]], isSlotted: { _ in false })
        #expect(found.flatMap(\.tags).map(\.name) == ["The Barn"])
    }

    @Test func aTagInTheFilterIsAlwaysFound() {
        let quartet = vocabulary[0].tags[1]
        let found = SidebarTagSearch.matches("zzz", in: vocabulary, aliases: [:], isSlotted: { $0 == quartet.id })
        #expect(found.flatMap(\.tags).map(\.name) == ["Red Quartet"])
    }

    @Test func blankAndUnmatchedQueriesFindNothing() {
        #expect(SidebarTagSearch.matches("   ", in: vocabulary, aliases: [:], isSlotted: { _ in false }).isEmpty)
        #expect(SidebarTagSearch.matches("purple", in: vocabulary, aliases: [:], isSlotted: { _ in false }).isEmpty)
    }

    @Test func aBroadQueryIsCapped() {
        let many = CategoryTags(category: band, tags: (0..<200).map {
            SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Band \($0)")
        })
        let found = SidebarTagSearch.matches("band", in: [many, vocabulary[1]], aliases: [:], isSlotted: { _ in false })
        #expect(found.reduce(0) { $0 + $1.tags.count } == SidebarTagSearch.limit)
        #expect(found.count == 1)  // the budget was spent before Venue
    }
}
