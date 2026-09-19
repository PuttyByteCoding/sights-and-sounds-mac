import Foundation

/// How one part's values are cased before they join the string.
public enum SearchLetterCase: String, Codable, Sendable, CaseIterable {
    case asIs, lowercase, uppercase, titleCase

    public var displayName: String {
        switch self {
        case .asIs: "As is"
        case .lowercase: "lowercase"
        case .uppercase: "UPPERCASE"
        case .titleCase: "Title Case"
        }
    }
}

/// Whether a value is wrapped in double quotes — the search-engine
/// gesture for "these words together".
public enum SearchQuoting: String, Codable, Sendable, CaseIterable {
    case never, multiWord, always

    public var displayName: String {
        switch self {
        case .never: "Never"
        case .multiWord: "Multi-word only"
        case .always: "Always"
        }
    }
}

public struct SearchFormat: Codable, Equatable, Sendable {
    public var letterCase: SearchLetterCase
    public var quoting: SearchQuoting

    public init(letterCase: SearchLetterCase = .asIs, quoting: SearchQuoting = .never) {
        self.letterCase = letterCase
        self.quoting = quoting
    }
}

/// One rule, run over every value the parts gathered, in list order —
/// the order is the operator's, which is the point. Exclude removes
/// the text wherever it appears in a value, ignoring case; a value
/// left empty is dropped. Replace changes every occurrence of the
/// text inside a value, case-sensitively; an empty right-hand side
/// removes it. "-" to a space is the one this was asked for. Split
/// breaks each value at a separator into pieces — and, when asked, at
/// the capitals inside a run, so "OnStage" is "On Stage" — and every
/// rule below it works on the pieces; empty pieces vanish.
public struct SearchRule: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        case exclude(String)
        case replace(from: String, to: String)
        case split(separator: String, titleCaseWords: Bool)
    }

    public var id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// One part of the search string, in order. A literal is prose for the
/// search engine; the other two kinds draw values from the item.
public struct SearchPart: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        case literal(String)
        /// The item's file name, with or without its extension, either
        /// whole or split at underscores into the pieces the namer
        /// meant separately.
        case fileName(includesExtension: Bool, splitsPieces: Bool)
        /// Every tag the item wears from one category, or from all of
        /// them when the id is nil, joined with `joiner`.
        case tags(categoryID: UUID?, joiner: String)
    }

    public var id: UUID
    public var kind: Kind
    public var format: SearchFormat

    public init(id: UUID = UUID(), kind: Kind, format: SearchFormat = SearchFormat()) {
        self.id = id
        self.kind = kind
        self.format = format
    }

    public var isLiteral: Bool {
        if case .literal = kind { return true }
        return false
    }
}

/// One format: an ordered list of parts that gather values, then an
/// ordered list of rules that run over every value, under a name. A
/// library keeps several (`SearchFormats`), stored as JSON on its info
/// row.
public struct SearchRecipe: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var parts: [SearchPart]
    public var rules: [SearchRule]

    public init(id: UUID = UUID(), name: String = "Default", parts: [SearchPart] = [], rules: [SearchRule] = []) {
        self.id = id
        self.name = name
        self.parts = parts
        self.rules = rules
    }

    /// No format at all — what a library without any answers with.
    public static let empty = SearchRecipe(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "")
}

extension SearchRecipe: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, parts, rules
        // Before the rules were one ordered list: replacements, then
        // exclusions, in that fixed order.
        case exclusions, replacements
    }

    private struct LegacyReplacement: Decodable {
        var id: UUID?
        var from: String
        var to: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Default"
        parts = try container.decodeIfPresent([SearchPart].self, forKey: .parts) ?? []
        if let rules = try container.decodeIfPresent([SearchRule].self, forKey: .rules) {
            self.rules = rules
        } else {
            let replacements = try container.decodeIfPresent([LegacyReplacement].self, forKey: .replacements) ?? []
            let exclusions = try container.decodeIfPresent([String].self, forKey: .exclusions) ?? []
            rules = replacements.map { SearchRule(id: $0.id ?? UUID(), kind: .replace(from: $0.from, to: $0.to)) }
                + exclusions.map { SearchRule(kind: .exclude($0)) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(parts, forKey: .parts)
        try container.encode(rules, forKey: .rules)
    }
}

/// Every format a library has, and which one ⌘⇧C uses. The default is
/// by id; a missing or stale id falls back to the first format, so
/// there is always one to use while any exists.
public struct SearchFormats: Equatable, Sendable {
    public var formats: [SearchRecipe]
    public var defaultID: UUID?

    public init(formats: [SearchRecipe] = [], defaultID: UUID? = nil) {
        self.formats = formats
        self.defaultID = defaultID
    }

    public static let empty = SearchFormats()

    public var defaultFormat: SearchRecipe? {
        formats.first { $0.id == defaultID } ?? formats.first
    }
}

extension SearchFormats: Codable {
    private enum CodingKeys: String, CodingKey { case formats, defaultID }

    /// A library that stored ONE recipe before formats existed has its
    /// parts at the top level: it reads as one format, the default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.formats) {
            formats = try container.decode([SearchRecipe].self, forKey: .formats)
            defaultID = try container.decodeIfPresent(UUID.self, forKey: .defaultID)
        } else {
            let single = try SearchRecipe(from: decoder)
            formats = [single]
            defaultID = single.id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formats, forKey: .formats)
        try container.encodeIfPresent(defaultID, forKey: .defaultID)
    }
}

extension LibraryDatabase {
    /// The library's formats; the empty set when none is stored or the
    /// stored JSON cannot be read — the shape may grow, and a recipe
    /// must never stop a library from opening.
    public func searchFormats() throws -> SearchFormats {
        guard let raw = try info()?.searchRecipe, let data = raw.data(using: .utf8) else {
            return .empty
        }
        return (try? JSONDecoder().decode(SearchFormats.self, from: data)) ?? .empty
    }

    public func setSearchFormats(_ formats: SearchFormats) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(data: try encoder.encode(formats), encoding: .utf8)
        try writer.write { db in
            guard var info = try LibraryInfo.fetchOne(db) else { return }
            info.searchRecipe = encoded
            try info.update(db)
        }
    }

    /// The recipe ⌘⇧C and the other commands use: the default format,
    /// else the first, else nothing.
    public func searchRecipe() throws -> SearchRecipe {
        try searchFormats().defaultFormat ?? .empty
    }
}
