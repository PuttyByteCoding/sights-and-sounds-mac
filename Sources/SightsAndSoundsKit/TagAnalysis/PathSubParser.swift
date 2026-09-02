import Foundation

/// The path half of the parser loop.
///
/// A path is an **ordered list of strings and nothing more**. Every scrap
/// of path knowledge lives here — separators, `file://` schemes,
/// percent-encoding, the media root, hidden roots — so the view receives a
/// list and its only path-specific behaviour is drawing it indented.
/// Splitting a path *is* parsing, however presentational it looks.
///
/// The segments loop **back into** the hub, so a directory name is parsed
/// as text in its own right — that is what makes a path inside a JSON value
/// inside a comment resolve all the way down. Segments are handed back
/// **unkeyed**: a directory name has no enclosing object key, so it must
/// never satisfy a `keyEquals` rule.
public struct PathSubParser: SubParser {
    public let id = "pathParser"

    private let mediaRoot: String?
    private let hiddenRoots: [String]

    /// `rules` supplies the hidden roots: every rule pairing a
    /// `pathRootStartsWith` matcher with a `hidePrefix` action. That is
    /// what `hidePrefix` is for — a hidden root is an ordinary rule row
    /// rather than a separate synced setting, so it gets one editor, one
    /// storage and one backup path.
    public init(mediaRoot: String?, rules: [RuleEngine.Rule]) {
        self.mediaRoot = mediaRoot
        self.hiddenRoots = rules.compactMap { rule in
            guard rule.actions.contains(.hidePrefix),
                  case .pathRootStartsWith(let root) = rule.matcher,
                  !root.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return root
        }
    }

    /// A cheap syntactic claim: a separator anywhere. Deliberately
    /// imprecise — `16/9` matching too is accepted, since the resulting
    /// "16" and "9" candidates harm nothing and a rule can suppress them.
    public func detect(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("/") || trimmed.contains("\\")
    }

    public func parse(_ raw: String, key: String?) -> [SubParserNextItem] {
        // Deliberately ignores the enclosing key: a directory name has
        // no key, and must never satisfy a keyEquals rule.
        segments(of: raw).map { SubParserNextItem(raw: $0, key: nil) }
    }

    public func segments(of raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        var working = normalize(raw)

        // The media root strips FIRST, and hidden roots match whatever is
        // left AFTER that strip — not the original path. Hidden roots are
        // additional roots alongside the media root, not sub-paths in
        // absolute terms: one living under the media root must be written
        // relative to it, because its absolute form will never again be a
        // prefix once the media root is gone.
        if let mediaRoot, !mediaRoot.trimmingCharacters(in: .whitespaces).isEmpty {
            working = RuleEngine.strippingRoot(working, root: mediaRoot) ?? working
        }

        // Longest first, so the more specific root wins regardless of the
        // user's rule ordering — and exactly ONE strip: these are prefixes
        // to peel off the front, not a chain to run repeatedly. Double
        // emission shipped twice from that instinct on the old app.
        for root in hiddenRoots.sorted(by: { $0.count > $1.count }) {
            if let stripped = RuleEngine.strippingRoot(working, root: root) {
                working = stripped
                break
            }
        }

        return working.split(separator: "/").map(String.init)
    }

    private func normalize(_ raw: String) -> String {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        if working.lowercased().hasPrefix("file://") {
            working = String(working.dropFirst("file://".count))
        }

        // Best effort: a malformed escape must not blank the whole path.
        working = working.removingPercentEncoding ?? working

        // Resolve `.`/`..` and redundant separators for absolute paths
        // only, matching the original's guard. Never throws, so a path it
        // cannot make sense of is used as-is rather than lost.
        if working.hasPrefix("/") {
            working = (working as NSString).standardizingPath
        }

        return working
    }
}
