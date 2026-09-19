import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The search formats live in the library file, because their parts
/// name categories and categories are the library's. Several named
/// formats, one of them the default ⌘⇧C uses. A library without any
/// answers with the empty set, never an error.
@Suite struct SearchRecipeTests {
    private func makeLibrary() throws -> LibraryDatabase {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Recipe")
        return library
    }

    @Test func theFormatsRoundTripThroughTheLibrary() throws {
        let library = try makeLibrary()
        #expect(try library.searchFormats() == .empty)
        #expect(try library.searchRecipe() == .empty)

        let band = UUID()
        let web = SearchRecipe(
            name: "Web",
            parts: [
                SearchPart(kind: .tags(categoryID: band, joiner: " "), format: SearchFormat(letterCase: .asIs, quoting: .multiWord)),
                SearchPart(kind: .literal("at the venue")),
            ],
            rules: [
                SearchRule(kind: .replace(from: "-", to: " ")),
                SearchRule(kind: .split(separator: "_", titleCaseWords: true, keep: .last)),
                SearchRule(kind: .exclude("sdg")),
            ])
        let bare = SearchRecipe(name: "Bare", parts: [SearchPart(kind: .fileName(includesExtension: false, splitsPieces: false))])
        let formats = SearchFormats(formats: [web, bare], defaultID: bare.id)
        try library.setSearchFormats(formats)
        #expect(try library.searchFormats() == formats)
        // ⌘⇧C's recipe is the default format.
        #expect(try library.searchRecipe() == bare)
    }

    /// No default marked, or a default that no longer exists, means the
    /// first format — never nothing while there is a format to use.
    @Test func theDefaultFallsBackToTheFirstFormat() throws {
        let library = try makeLibrary()
        let a = SearchRecipe(name: "A", parts: [SearchPart(kind: .literal("a"))])
        let b = SearchRecipe(name: "B", parts: [SearchPart(kind: .literal("b"))])
        try library.setSearchFormats(SearchFormats(formats: [a, b], defaultID: nil))
        #expect(try library.searchRecipe() == a)
        try library.setSearchFormats(SearchFormats(formats: [a, b], defaultID: UUID()))
        #expect(try library.searchRecipe() == a)
        #expect(SearchFormats(formats: [a, b], defaultID: b.id).defaultFormat == b)
    }

    /// A library that stored ONE recipe before formats existed — bare
    /// parts and rules at the top level — reads as one format named
    /// Default, marked as the default.
    @Test func aStoredSingleRecipeBecomesTheDefaultFormat() throws {
        let library = try makeLibrary()
        try library.writer.write { db in
            try db.execute(sql: """
                UPDATE libraryInfo SET searchRecipe = \
                '{"parts":[{"format":{"letterCase":"asIs","quoting":"never"},"id":"6B4D2C0A-6C0E-4E4B-9C4E-1B7C6A1B2C3D","kind":{"literal":{"_0":"live"}}}],"exclusions":["sdg"],"replacements":[{"from":"-","id":"6B4D2C0A-6C0E-4E4B-9C4E-1B7C6A1B2C3E","to":" "}]}'
                """)
        }
        let formats = try library.searchFormats()
        #expect(formats.formats.count == 1)
        #expect(formats.formats.first?.name == "Default")
        #expect(formats.defaultID == formats.formats.first?.id)
        #expect(formats.formats.first?.parts.map(\.kind) == [.literal("live")])
        #expect(formats.formats.first?.rules.map(\.kind) == [.replace(from: "-", to: " "), .exclude("sdg")])
        #expect(try library.searchRecipe().parts.map(\.kind) == [.literal("live")])
    }

    /// A Split rule stored before it had a keep option reads as keep
    /// all, and an Exclude stored before its option reads as keep none
    /// — the shape a build wrote yesterday must not empty the list.
    @Test func aStoredSplitRuleWithoutKeepReadsAsKeepAll() throws {
        let json = #"{"formats":[{"id":"6B4D2C0A-6C0E-4E4B-9C4E-1B7C6A1B2C3D","name":"F","parts":[],"rules":[{"id":"6B4D2C0A-6C0E-4E4B-9C4E-1B7C6A1B2C3E","kind":{"split":{"separator":"_","titleCaseWords":true}}},{"id":"6B4D2C0A-6C0E-4E4B-9C4E-1B7C6A1B2C3F","kind":{"exclude":{"_0":"sdg"}}},{"id":"6B4D2C0A-6C0E-4E4B-9C4E-1B7C6A1B2C40","kind":{"replace":{"from":"-","to":" "}}}]}]}"#
        let formats = try JSONDecoder().decode(SearchFormats.self, from: Data(json.utf8))
        #expect(formats.formats.first?.rules.map(\.kind) == [
            .split(separator: "_", titleCaseWords: true, keep: .all),
            .exclude("sdg", keep: .none, regex: false),
            .replace(from: "-", to: " ", regex: false),
        ])
        // And every kind re-encodes in the shape it was read in.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(data: try encoder.encode(formats), encoding: .utf8) ?? ""
        #expect(encoded.contains(#""exclude":{"_0":"sdg","keep":"none","regex":false}"#))
        #expect(encoded.contains(#""replace":{"from":"-","regex":false,"to":" "}"#))
        #expect(encoded.contains(#""keep":"all""#))
    }

    /// A stored recipe an older build cannot read is the empty set, not
    /// a crash: the column is JSON and the shape may grow.
    @Test func anUnreadableStoredRecipeIsEmpty() throws {
        let library = try makeLibrary()
        try library.writer.write { db in
            try db.execute(sql: "UPDATE libraryInfo SET searchRecipe = '{not json'")
        }
        #expect(try library.searchFormats() == .empty)
        #expect(try library.searchRecipe() == .empty)
    }
}
