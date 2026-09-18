import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The search recipe lives in the library file, because its parts name
/// categories and categories are the library's. A library without one
/// answers with the empty recipe, never an error.
@Suite struct SearchRecipeTests {
    @Test func aRecipeRoundTripsThroughTheLibrary() throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Recipe")
        #expect(try library.searchRecipe() == .empty)

        let band = UUID()
        let recipe = SearchRecipe(
            parts: [
                SearchPart(
                    kind: .tags(categoryID: band, joiner: " "),
                    format: SearchFormat(letterCase: .asIs, quoting: .multiWord)),
                SearchPart(kind: .literal("at the venue")),
                SearchPart(
                    kind: .fileName(includesExtension: false, splitsPieces: true),
                    format: SearchFormat(letterCase: .lowercase, quoting: .never)),
            ],
            rules: [
                SearchRule(kind: .replace(from: "-", to: " ")),
                SearchRule(kind: .exclude("sdg")),
            ])
        try library.setSearchRecipe(recipe)
        #expect(try library.searchRecipe() == recipe)
    }

    /// A recipe stored before the rules were one ordered list carried
    /// `replacements` and `exclusions` apart, and ran them in that
    /// order. It decodes to the same rules in the same order.
    @Test func aStoredRecipeFromBeforeTheRuleListDecodesInItsOldOrder() throws {
        let json = #"{"exclusions":["sdg"],"parts":[],"replacements":[{"from":"-","id":"6B4D2C0A-6C0E-4E4B-9C4E-1B7C6A1B2C3D","to":" "}]}"#
        let recipe = try JSONDecoder().decode(SearchRecipe.self, from: Data(json.utf8))
        #expect(recipe.rules.map(\.kind) == [.replace(from: "-", to: " "), .exclude("sdg")])
        // And it re-encodes in the new shape only.
        let encoded = String(data: try JSONEncoder().encode(recipe), encoding: .utf8) ?? ""
        #expect(encoded.contains("\"rules\""))
        #expect(!encoded.contains("\"exclusions\"") && !encoded.contains("\"replacements\""))
    }

    /// A stored recipe an older build cannot read is the empty recipe,
    /// not a crash: the column is JSON and the shape may grow.
    @Test func anUnreadableStoredRecipeIsEmpty() throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Recipe")
        try library.writer.write { db in
            try db.execute(sql: "UPDATE libraryInfo SET searchRecipe = '{not json'")
        }
        #expect(try library.searchRecipe() == .empty)
    }
}
