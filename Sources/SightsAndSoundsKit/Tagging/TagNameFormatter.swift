import Foundation

/// Applies a category's `TextFormat` to a tag name on save. Pure, so every
/// creation path — single create, bulk paste, rename, autocomplete-create —
/// normalizes identically. Ported verbatim from the web app's
/// `TagNameFormatter` (#207, #396).
public enum TagNameFormatter {
    /// `separatorsToSpaces` runs BEFORE the case pass — converting `-`,
    /// `.`, `_` to spaces, collapsing runs, trimming — so
    /// "dave--matthews_.band" + titleCase → "Dave Matthews Band".
    public static func format(
        _ name: String, textFormat: TextFormat, separatorsToSpaces: Bool = false
    ) -> String {
        guard !name.isEmpty else { return name }
        let working = separatorsToSpaces ? convertSeparatorsToSpaces(name) : name
        switch textFormat {
        case .allLowercase: return working.lowercased()
        case .allUppercase: return working.uppercased()
        case .titleCase: return titleCase(working)
        case .noFormatting: return working
        }
    }

    /// Convenience: normalize for a category's configuration.
    public static func format(_ name: String, for category: TagCategory) -> String {
        format(name, textFormat: category.textFormat, separatorsToSpaces: category.separatorsToSpaces)
    }

    private static let separators: Set<Character> = ["-", ".", "_"]

    private static func convertSeparatorsToSpaces(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s {
            let isSpace = separators.contains(ch) || ch.isWhitespace
            if isSpace {
                if !lastWasSpace && !result.isEmpty { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(ch)
                lastWasSpace = false
            }
        }
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// First letter of each whitespace-separated word uppercased, the rest
    /// lowercased — unlike locale title-casing, ALL-CAPS words normalize
    /// too ("LIVE SHOW" → "Live Show") so the result is predictable.
    private static func titleCase(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var newWord = true
        for ch in s {
            if ch.isWhitespace {
                newWord = true
                result.append(ch)
            } else {
                result.append(contentsOf: newWord ? ch.uppercased() : ch.lowercased())
                newWord = false
            }
        }
        return result
    }
}
