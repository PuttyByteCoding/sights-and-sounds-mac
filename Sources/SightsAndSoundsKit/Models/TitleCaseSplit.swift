import Foundation

extension String {
    /// Title case with the spaces missing, given them back: "ThisExampleHere"
    /// → "This Example Here", "BenFolds" → "Ben Folds", "DMBLive" →
    /// "DMB Live". A word starts at an upper-case letter that follows a
    /// lower-case letter, or at the last capital of a run of capitals
    /// when a lower-case letter follows it, so an acronym stays whole.
    /// Only a run that LOOKS like title case is touched: it starts with
    /// a capital, has a lower-case letter and at least two capitals, and
    /// carries no space of its own. "Phish", "ACDC", "iPhone" and
    /// "Ben Folds" come back unchanged. Applied per whitespace-separated
    /// word, so "BenFolds live" becomes "Ben Folds live".
    public var splittingTitleCaseWords: String {
        split(separator: " ", omittingEmptySubsequences: false)
            .map { Self.splitOneRun(String($0)) }
            .joined(separator: " ")
    }

    private static func splitOneRun(_ run: String) -> String {
        let chars = Array(run)
        guard let first = chars.first, first.isUppercase,
              chars.contains(where: { $0.isLowercase }),
              chars.filter({ $0.isUppercase }).count >= 2
        else { return run }
        var out = ""
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase {
                let previous = chars[i - 1]
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let afterLower = previous.isLowercase || previous.isNumber
                let endsAnAcronym = previous.isUppercase && (next?.isLowercase ?? false)
                if afterLower || endsAnAcronym { out.append(" ") }
            }
            out.append(c)
        }
        return out
    }
}
