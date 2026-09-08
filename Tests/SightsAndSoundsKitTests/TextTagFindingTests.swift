import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Existing tags named inside free text — the Universal field's screen
/// read's pass over what Vision read, through the same word-run match the
/// per-item analysis uses.
@Suite struct TextTagFindingTests {
    @Test func tagsAndAliasesInsideLinesAreFoundOncePerTag() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Text")
        let band = TagCategory(name: "Band"), venue = TagCategory(name: "Venue")
        let phish = Tag(tagCategoryID: band.id, name: "Phish")
        let rocks = Tag(tagCategoryID: venue.id, name: "Red Rocks Amphitheatre")
        try await library.writer.write { db in
            try band.insert(db); try venue.insert(db); try phish.insert(db); try rocks.insert(db)
        }
        try library.addAlias("Red Rocks", toTag: rocks.id)

        let findings = try library.existingTags(inLines: [
            "LIVE AT RED ROCKS", "phish", "Phish again", "nothing here",
        ])
        #expect(findings.map(\.tag.name) == ["Red Rocks Amphitheatre", "Phish"])
        #expect(findings[0].matchedText == "Red Rocks")
        #expect(findings[0].foundIn == "LIVE AT RED ROCKS")
        #expect(findings[1].categoryName == "Band")
        #expect(try library.existingTags(inLines: []).isEmpty)
    }
}
