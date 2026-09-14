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
            exclusions: ["sdg"],
            replacements: [SearchReplacement(from: "-", to: " ")])
        try library.setSearchRecipe(recipe)
        #expect(try library.searchRecipe() == recipe)
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
