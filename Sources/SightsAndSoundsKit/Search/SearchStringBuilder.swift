import Foundation

/// One tag the subject wears, with the category it came from.
public struct SearchSubjectTag: Equatable, Sendable {
    public let categoryID: UUID
    public let name: String

    public init(categoryID: UUID, name: String) {
        self.categoryID = categoryID
        self.name = name
    }
}

/// What a recipe is built from: the item's file name and its tags.
public struct SearchSubject: Equatable, Sendable {
    public let fileName: String
    public let tags: [SearchSubjectTag]

    public init(fileName: String, tags: [SearchSubjectTag]) {
        self.fileName = fileName
        self.tags = tags
    }
}

/// A recipe and an item in, one string out (spec 17, decision 2). For
/// every value a part yields: the rules, in their order — a replace
/// changes the value, an exclude removes its text wherever it appears,
/// case-insensitively, and a value left empty is dropped — then the
/// part's case and quoting. Literals are
/// prose for the search engine: used verbatim, and left out of the
/// bookmark terms.
public enum SearchStringBuilder {
    /// The part's values after the rules, before any formatting: what
    /// the bookmark search matches on.
    public static func values(
        for part: SearchPart, subject: SearchSubject, recipe: SearchRecipe
    ) -> [String] {
        // A rule maps one value to one or more — split is the one that
        // multiplies — and the next rule sees whatever the last left.
        var values = rawValues(for: part, subject: subject)
        for rule in recipe.rules {
            values = values.flatMap { apply(rule, to: $0) }
            // A Split's keep first / keep last chooses across EVERYTHING
            // the part has at this point — not inside each value on its
            // own, or a name the part had already cut into pieces would
            // keep every piece. First and last mean the first and last
            // with something in it, so a doubled separator cannot choose
            // an empty one.
            if case .split(_, _, let keep) = rule.kind, keep != .all {
                let filled = values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                values = (keep == .first ? filled.first : filled.last).map { [$0] } ?? []
            }
        }
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func apply(_ rule: SearchRule, to value: String) -> [String] {
        switch rule.kind {
        case .replace(let from, let to, let regex):
            guard !from.isEmpty else { return [value] }
            if regex {
                // A pattern that does not compile does nothing — the
                // row says so — rather than guessing at what was meant.
                guard let expression = try? NSRegularExpression(pattern: from) else { return [value] }
                return [expression.stringByReplacingMatches(
                    in: value, range: NSRange(value.startIndex..., in: value), withTemplate: to)]
            }
            return [value.replacingOccurrences(of: from, with: to)]
        case .exclude(let text, let keep, let regex):
            // Wherever it appears, ignoring case — a whole value equal
            // to it is left empty and dropped by the caller. Keeping the
            // first or last occurrence removes all the others. As a
            // pattern, the matches are the occurrences.
            let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return [value] }
            var ranges: [Range<String.Index>] = []
            if regex {
                guard let expression = try? NSRegularExpression(pattern: needle, options: [.caseInsensitive])
                else { return [value] }
                ranges = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
                    .compactMap { Range($0.range, in: value) }
                    .filter { !$0.isEmpty }
            } else {
                var from = value.startIndex
                while let found = value.range(of: needle, options: [.caseInsensitive], range: from..<value.endIndex) {
                    ranges.append(found)
                    from = found.upperBound
                }
            }
            let kept: Int?
            switch keep {
            case .none: kept = nil
            case .first: kept = ranges.indices.first
            case .last: kept = ranges.indices.last
            }
            var result = value
            for (index, range) in ranges.enumerated().reversed() where index != kept {
                result.removeSubrange(range)
            }
            return [result]
        case .split(let separator, let titleCaseWords, _):
            // Keep is applied by the caller, across the whole part.
            let pieces = separator.isEmpty ? [value] : value.components(separatedBy: separator)
            return titleCaseWords ? pieces.map(\.splittingTitleCaseWords) : pieces
        }
    }

    /// The whole string: every part's formatted values, parts joined by
    /// single spaces, a part with nothing to say leaving no gap.
    public static func string(recipe: SearchRecipe, subject: SearchSubject) -> String {
        recipe.parts.compactMap { part -> String? in
            switch part.kind {
            case .literal(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case .fileName, .tags:
                let formatted = values(for: part, subject: subject, recipe: recipe)
                    .map { quote(cased($0, part.format.letterCase), part.format.quoting) }
                guard !formatted.isEmpty else { return nil }
                let joiner: String
                if case .tags(_, let tagJoiner) = part.kind { joiner = tagJoiner } else { joiner = " " }
                return formatted.joined(separator: joiner)
            }
        }
        .joined(separator: " ")
    }

    /// Why a rule's text does not work as a pattern, or nil when it
    /// does — for the row to show beside its regex switch.
    public static func regexProblem(in pattern: String) -> String? {
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return "Not a valid pattern"
        }
    }

    /// The string the rules start from: the parts applied and no rule
    /// yet — what the first rule sees.
    public static func stringBeforeRules(recipe: SearchRecipe, subject: SearchSubject) -> String {
        var cut = recipe
        cut.rules = []
        return string(recipe: cut, subject: subject)
    }

    /// The string as it stands after each rule — the recipe cut off
    /// after rule N, for every N, in rule order — so an editor can show
    /// what each rule did. One entry per rule; the last is the whole
    /// recipe's string.
    public static func stringsAfterEachRule(recipe: SearchRecipe, subject: SearchSubject) -> [String] {
        recipe.rules.indices.map { index in
            var cut = recipe
            cut.rules = Array(recipe.rules.prefix(index + 1))
            return string(recipe: cut, subject: subject)
        }
    }

    /// The values a bookmark must contain, every one: the non-literal
    /// parts' values with the part's case applied and no quoting.
    public static func bookmarkTerms(recipe: SearchRecipe, subject: SearchSubject) -> [String] {
        recipe.parts.filter { !$0.isLiteral }.flatMap { part in
            values(for: part, subject: subject, recipe: recipe).map { cased($0, part.format.letterCase) }
        }
    }

    /// Tag parts naming a category the library no longer has, in recipe
    /// order, once each — skipped by the builder, flagged by the page.
    public static func missingCategoryIDs(in recipe: SearchRecipe, known: Set<UUID>) -> [UUID] {
        var seen = Set<UUID>()
        return recipe.parts.compactMap { part in
            guard case .tags(let id?, _) = part.kind, !known.contains(id), seen.insert(id).inserted
            else { return nil }
            return id
        }
    }

    // MARK: - Pieces

    private static func rawValues(for part: SearchPart, subject: SearchSubject) -> [String] {
        switch part.kind {
        case .literal(let text):
            return [text]
        case .fileName(let includesExtension, let splitsPieces):
            let stem = (subject.fileName as NSString).deletingPathExtension
            if splitsPieces {
                let pieces = FileNameSegments.pieces(of: subject.fileName)
                return pieces.isEmpty ? [stem] : pieces
            }
            return [includesExtension ? subject.fileName : stem]
        case .tags(let categoryID, _):
            return subject.tags
                .filter { categoryID == nil || $0.categoryID == categoryID }
                .map(\.name)
        }
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func cased(_ value: String, _ letterCase: SearchLetterCase) -> String {
        switch letterCase {
        case .asIs: value
        case .lowercase: value.lowercased()
        case .uppercase: value.uppercased()
        case .titleCase: TagNameFormatter.format(value, textFormat: .titleCase)
        }
    }

    private static func quote(_ value: String, _ quoting: SearchQuoting) -> String {
        switch quoting {
        case .never: value
        case .multiWord: value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
        case .always: "\"\(value)\""
        }
    }
}

extension LibraryDatabase {
    /// The item as the builder sees it: file name and tags with their
    /// categories, in browse-panel order. nil when the item is gone.
    public func searchSubject(for itemID: UUID) throws -> SearchSubject? {
        guard let item = try writer.read({ try MediaItem.fetchOne($0, key: itemID) }) else { return nil }
        let tags = try tags(of: itemID).flatMap { entry in
            entry.tags.map { SearchSubjectTag(categoryID: entry.category.id, name: $0.name) }
        }
        return SearchSubject(fileName: item.fileName, tags: tags)
    }
}
