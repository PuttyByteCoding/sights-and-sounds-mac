import Foundation

/// Finding the spellings of one thing.
///
/// A migrated library's vocabulary drifts: `Ash & Ember` and `Ash and
/// Ember`, `Broadside` and `The Broadside`, `Encore` and `Encores`. They
/// are not typos — every one was typed deliberately — so nothing catches
/// them except looking. This is the looking.
public enum TagSimilarity {
    /// The key two spellings of the same name share.
    ///
    /// Each step exists because a real pair needed it: `and` → `&` for
    /// "Ash and Ember", the leading article for "The Broadside", the
    /// trailing `s` for "Encores", and stripping punctuation for
    /// everything else.
    public static func key(_ name: String) -> String {
        var text = name.lowercased()
        text = text.replacingOccurrences(of: " and ", with: " & ")
        for article in ["the ", "a ", "an "] where text.hasPrefix(article) {
            text = String(text.dropFirst(article.count))
            break
        }
        var stripped = text.filter { $0.isLetter || $0.isNumber }
        if stripped.count > 3, stripped.hasSuffix("s") { stripped.removeLast() }
        return stripped
    }

    /// Clusters of two or more names sharing a key, most-used first.
    /// A cluster of one is just a tag, so it is not a finding.
    public static func clusters<T>(
        _ items: [T], name: (T) -> String, uses: (T) -> Int
    ) -> [[T]] {
        Dictionary(grouping: items, by: { key(name($0)) })
            .values
            .filter { $0.count > 1 }
            .map { cluster in cluster.sorted { uses($0) > uses($1) } }
            .sorted { left, right in
                let leftUses = left.reduce(0) { $0 + uses($1) }
                let rightUses = right.reduce(0) { $0 + uses($1) }
                if leftUses != rightUses { return leftUses > rightUses }
                return name(left[0]).localizedCaseInsensitiveCompare(name(right[0])) == .orderedAscending
            }
    }
}
