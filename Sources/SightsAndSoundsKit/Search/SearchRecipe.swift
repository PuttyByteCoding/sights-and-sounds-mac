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
/// the order is the operator's, which is the point. Exclude drops a
/// value equal to the text (whole value, ignoring case — never a
/// substring, so "on" cannot eat "On Stage"). Replace changes every
/// occurrence of the text inside a value; an empty right-hand side
/// removes it. "-" to a space is the one this was asked for.
public struct SearchRule: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        case exclude(String)
        case replace(from: String, to: String)
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

/// The recipe: an ordered list of parts that gather values, then an
/// ordered list of rules that run over every value. One per library,
/// stored as JSON on the library's info row.
public struct SearchRecipe: Equatable, Sendable {
    public var parts: [SearchPart]
    public var rules: [SearchRule]

    public init(parts: [SearchPart] = [], rules: [SearchRule] = []) {
        self.parts = parts
        self.rules = rules
    }

    public static let empty = SearchRecipe()
}

extension SearchRecipe: Codable {
    private enum CodingKeys: String, CodingKey {
        case parts, rules
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
        try container.encode(parts, forKey: .parts)
        try container.encode(rules, forKey: .rules)
    }
}

extension LibraryDatabase {
    /// The library's recipe; the empty recipe when none is stored or the
    /// stored one cannot be read — the column is JSON and the shape may
    /// grow, and a recipe must never stop a library from opening.
    public func searchRecipe() throws -> SearchRecipe {
        guard let raw = try info()?.searchRecipe, let data = raw.data(using: .utf8) else {
            return .empty
        }
        return (try? JSONDecoder().decode(SearchRecipe.self, from: data)) ?? .empty
    }

    public func setSearchRecipe(_ recipe: SearchRecipe) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(data: try encoder.encode(recipe), encoding: .utf8)
        try writer.write { db in
            guard var info = try LibraryInfo.fetchOne(db) else { return }
            info.searchRecipe = encoded
            try info.update(db)
        }
    }
}
