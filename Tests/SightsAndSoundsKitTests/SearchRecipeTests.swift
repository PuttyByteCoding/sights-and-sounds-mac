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

    /// A copy is a new format — its own id, and its own ids on every
    /// part and rule, so editing the copy never edits the original —
    /// with the same parts and rules and the name it was given.
    @Test func aDuplicateIsANewFormatWithTheSameContent() {
        let band = UUID()
        let original = SearchRecipe(
            name: "Web",
            parts: [SearchPart(kind: .tags(categoryID: band, joiner: " "), format: SearchFormat(quoting: .always))],
            rules: [SearchRule(kind: .replace(from: "-", to: " ")), SearchRule(kind: .split(separator: "_", titleCaseWords: true, keep: .first))])
        let copy = original.duplicate(named: "Web copy")
        #expect(copy.name == "Web copy")
        #expect(copy.id != original.id)
        #expect(copy.parts.map(\.kind) == original.parts.map(\.kind))
        #expect(copy.parts.map(\.format) == original.parts.map(\.format))
        #expect(copy.rules.map(\.kind) == original.rules.map(\.kind))
        #expect(Set(copy.parts.map(\.id)).isDisjoint(with: original.parts.map(\.id)))
        #expect(Set(copy.rules.map(\.id)).isDisjoint(with: original.rules.map(\.id)))
    }

    /// One line per part and per rule, for the overview that shows
    /// every format's configuration at once.
    @Test func partsAndRulesDescribeThemselvesInOneLine() {
        let categories = [UUID(): "Band"]
        let band = categories.keys.first!
        #expect(SearchPart(kind: .literal("at the venue")).summary(categoryNames: categories) == "Text “at the venue”")
        #expect(SearchPart(kind: .fileName(includesExtension: false, splitsPieces: true), format: SearchFormat(letterCase: .lowercase, quoting: .multiWord))
            .summary(categoryNames: categories) == "File name · no extension · split at _ · lowercase · quote multi-word")
        #expect(SearchPart(kind: .fileName(includesExtension: true, splitsPieces: false)).summary(categoryNames: categories)
            == "File name · with extension")
        #expect(SearchPart(kind: .tags(categoryID: band, joiner: ", "), format: SearchFormat(quoting: .always)).summary(categoryNames: categories)
            == "Tags · Band · joined by “, ” · quote always")
        #expect(SearchPart(kind: .tags(categoryID: nil, joiner: " ")).summary(categoryNames: categories) == "Tags · all categories")
        #expect(SearchPart(kind: .tags(categoryID: UUID(), joiner: " ")).summary(categoryNames: categories) == "Tags · (missing category)")

        #expect(SearchRule(kind: .exclude("sdg")).summary == "Exclude “sdg”")
        #expect(SearchRule(kind: .exclude(#"\d{4}"#, keep: .last, regex: true)).summary == #"Exclude /\d{4}/ · keep last"#)
        #expect(SearchRule(kind: .replace(from: "-", to: " ")).summary == "Replace “-” with “ ”")
        #expect(SearchRule(kind: .replace(from: "x", to: "")).summary == "Remove “x”")
        #expect(SearchRule(kind: .replace(from: "(a)", to: "$1", regex: true)).summary == "Replace /(a)/ with “$1”")
        #expect(SearchRule(kind: .split(separator: "_", titleCaseWords: true, keep: .all)).summary == "Split at “_” · and at capitals")
        #expect(SearchRule(kind: .split(separator: " ", titleCaseWords: false, keep: .first)).summary == "Split at “ ” · keep first")
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

    /// Reading an unreadable value as empty is fine. Saving over it is
    /// not: every format the library had would be gone, silently.
    @Test func savingNeverReplacesFormatsThisBuildCannotRead() throws {
        let library = try makeLibrary()
        try library.writer.write { db in
            try db.execute(sql: "UPDATE libraryInfo SET searchRecipe = '{\"formats\": \"from a newer build\"}'")
        }
        #expect(try library.storedSearchFormatsAreUnreadable())

        let mine = SearchFormats(formats: [SearchRecipe(name: "Mine")], defaultID: nil)
        #expect(throws: SearchFormatsError.storedFormatsUnreadable) {
            try library.setSearchFormats(mine)
        }
        let stored = try library.writer.read { try String.fetchOne($0, sql: "SELECT searchRecipe FROM libraryInfo") }
        #expect(stored == "{\"formats\": \"from a newer build\"}")

        // Replacing them is a decision someone makes, not a side effect.
        try library.setSearchFormats(mine, replacingUnreadable: true)
        #expect(try library.searchFormats() == mine)
        #expect(try !library.storedSearchFormatsAreUnreadable())
    }
}
