import Foundation

/// A pasted list of aliases, as the tag sheet accepts it.
///
/// One alias per line is the natural shape, but a list copied out of
/// prose or a spreadsheet arrives comma-, semicolon- or tab-separated,
/// so all four split. Every entry is trimmed — sloppy copies carry
/// leading and trailing spaces, tabs and non-breaking spaces — blanks
/// are dropped, and a spelling that repeats (case-insensitively) is
/// kept once, in the form first seen. `excluding` is what the tag
/// already answers to: its name and its current aliases.
public enum AliasList {
    public static func parse(_ text: String, excluding existing: [String] = []) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var result: [String] = []
        for piece in text.split(whereSeparator: { "\n\r,;\t".contains($0) }) {
            let alias = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !alias.isEmpty, seen.insert(alias.lowercased()).inserted else { continue }
            result.append(alias)
        }
        return result
    }
}
