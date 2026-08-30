import Foundation

/// Template-driven path building for reorganization — ported from the old
/// app's `OrganizeTemplate`, category-token half. (Standard-field tokens —
/// %ARTIST resolving through write-back mappings — arrive with Phase 8's
/// write-back port; today a token names an existing category,
/// underscores standing in for spaces.)
///
/// Ported rules:
///   - tokens are `%[A-Za-z0-9_]+`; `/` separates folders; all else literal
///   - unknown tokens and empty path segments fail validation up front
///   - multi-value: first ORDINALLY (locale-independent on purpose — the
///     same tags must build the same path on every machine), with a note
///   - missing value → the file is skipped, with the token named
///   - per-segment sanitization: `/ \ : * ? " < > |` and control chars →
///     `_`; leading/trailing dots+spaces trimmed; empty-after-sanitizing =
///     missing; 200-char cap
///   - the extension is NOT the template's business; the caller appends
public enum OrganizeTemplate {
    public struct ValidationError: Equatable, Sendable {
        public let message: String
    }

    public struct ResolveResult: Equatable, Sendable {
        /// nil when a token had no value for this item.
        public let relativeFolder: String?
        /// Set when `relativeFolder` is nil: what was missing.
        public let missingToken: String?
        public let notes: [String]
    }

    // A computed property: Regex isn't Sendable, so a stored static would
    // be shared mutable state under strict concurrency.
    static var tokenPattern: Regex<Substring> { /%[A-Za-z0-9_]+/ }

    public static func validate(_ template: String, categoryNames: [String]) -> [ValidationError] {
        var errors: [ValidationError] = []
        guard !template.trimmingCharacters(in: .whitespaces).isEmpty else {
            return [ValidationError(message: "Template is empty.")]
        }
        if template.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            errors.append(ValidationError(message: "Template has an empty path segment."))
        }
        let tokens = template.matches(of: tokenPattern).map { String($0.output.dropFirst()) }
        if tokens.isEmpty {
            errors.append(ValidationError(message: "Template has no tokens."))
            return errors
        }
        let known = Set(categoryNames.map { $0.lowercased() })
        var seen = Set<String>()
        for token in tokens where seen.insert(token.lowercased()).inserted {
            let folded = token.replacingOccurrences(of: "_", with: " ").lowercased()
            if !known.contains(folded) {
                // Name the category and point somewhere useful: an
                // unknown token is almost always a spelling, and the
                // remedy is one window away.
                let name = token.replacingOccurrences(of: "_", with: " ")
                errors.append(ValidationError(
                    message: """
                        No category called "\(name)" — check the spelling, or create it in \
                        Categories & Fields.
                        """))
            }
        }
        return errors
    }

    /// Resolve one item's target folder from its tags (category name →
    /// that category's tag names on the item).
    public static func resolve(
        _ template: String, tagsByCategory: [String: [String]]
    ) -> ResolveResult {
        // Case-insensitive category lookup.
        let lookup = Dictionary(
            tagsByCategory.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { a, _ in a })

        var notes: [String] = []
        var segments: [String] = []

        for rawSegment in template.split(separator: "/", omittingEmptySubsequences: true) {
            var built = ""
            var missing: String?
            var index = rawSegment.startIndex
            let matches = rawSegment.matches(of: tokenPattern)
            for match in matches {
                built += rawSegment[index..<match.range.lowerBound]
                let token = String(match.output.dropFirst())
                let folded = token.replacingOccurrences(of: "_", with: " ").lowercased()
                let values = lookup[folded] ?? []
                guard !values.isEmpty else {
                    missing = token
                    break
                }
                // Ordinal, deliberately: locale-independent determinism.
                let chosen = values.min { $0.compare($1) == .orderedAscending } ?? values[0]
                if values.count > 1 {
                    notes.append("\(token) had \(values.count) values; used '\(chosen)'")
                }
                built += chosen
                index = match.range.upperBound
            }
            if let missing {
                return ResolveResult(relativeFolder: nil, missingToken: missing, notes: notes)
            }
            built += rawSegment[index...]

            let sanitized = sanitize(built)
            guard !sanitized.isEmpty else {
                let tokenName = matches.first.map { String($0.output.dropFirst()) }
                return ResolveResult(
                    relativeFolder: nil,
                    missingToken: tokenName ?? String(rawSegment), notes: notes)
            }
            segments.append(sanitized)
        }
        return ResolveResult(
            relativeFolder: segments.joined(separator: "/"), missingToken: nil, notes: notes)
    }

    static func sanitize(_ segment: String) -> String {
        let forbidden = Set("/\\:*?\"<>|")
        var cleaned = String(segment.map { ch in
            forbidden.contains(ch) || ch.asciiValue.map { $0 < 32 } == true ? "_" : ch
        })
        while let first = cleaned.first, first == "." || first == " " { cleaned.removeFirst() }
        while let last = cleaned.last, last == "." || last == " " { cleaned.removeLast() }
        return String(cleaned.prefix(200))
    }
}
