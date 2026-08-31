import Foundation

/// Applies every rule whose matcher fires, in list order, folding each
/// rule's actions into a running outcome.
///
/// Three properties, none obvious and all load-bearing:
///
/// 1. Matching re-checks the **current** value, not the original — a rule
///    that strips a prefix changes what later rules see, which is how a
///    chain of rules composes into one decision.
/// 2. **Last action wins** for kind and category, so two overlapping rules
///    do not conflict: the later one decides.
/// 3. **Every rule is considered.** There is no first-match-wins short
///    circuit.
///
/// Ported from the old app's `RuleEngine.Apply`, itself a port of
/// `analyzeRules.ts`. The semantics are recorded in
/// `docs/design/14-tag-analysis-build-plan.md` because they are not
/// derivable from the vocabulary spec 14 mandates.
public enum RuleEngine {

    /// One rule, decoded. `id` is carried so an outcome can name the rule
    /// that dropped a value.
    public struct Rule: Equatable, Sendable {
        public let id: UUID
        public let matcher: RuleMatcher
        public let actions: [RuleAction]

        public init(id: UUID, matcher: RuleMatcher, actions: [RuleAction]) {
            self.id = id
            self.matcher = matcher
            self.actions = actions
        }
    }

    public static func apply(_ input: RuleInput, rules: [Rule]) -> RuleOutcome {
        var kind = FindingKind.tag
        var value = input.value
        var category: String?
        var matchedRuleID: UUID?

        for rule in rules {
            guard matches(rule.matcher, key: input.key, value: value) else { continue }
            for action in rule.actions {
                switch action {
                case .ignore:
                    kind = .ignored
                    matchedRuleID = rule.id

                case .setKind(let raw):
                    // Inert, not fatal: the kind is stored as a free string
                    // precisely so a new one needs no migration.
                    if let parsed = FindingKind.parse(raw) { kind = parsed }

                case .stripPrefix(let prefix):
                    if value.hasPrefix(prefix) { value.removeFirst(prefix.count) }

                case .onlyIfTrue:
                    if value.trimmingCharacters(in: .whitespaces).lowercased() != "true" {
                        kind = .ignored
                        matchedRuleID = rule.id
                    }

                case .assignCategory(let name):
                    category = name

                // Path parsing consumes this one; the fold does not.
                case .hidePrefix, .unknown:
                    break
                }
            }
        }

        return RuleOutcome(
            kind: kind, value: value, category: category, matchedRuleID: matchedRuleID)
    }

    /// An unrecognised matcher does not match and does not throw: a rule
    /// authored against a newer build must go inert rather than take down
    /// an analysis run over a whole library.
    public static func matches(_ matcher: RuleMatcher, key: String?, value: String) -> Bool {
        switch matcher {
        case .keyEquals(let wanted):
            // A key-scoped rule can never fire on something with no key —
            // a path segment or a reader's top-level string.
            guard let key else { return false }
            return KeyNormalizer.normalize(key) == KeyNormalizer.normalize(wanted)

        case .valueStartsWith(let prefix):
            // Ordinal and case-SENSITIVE: a prefix like "Title - " is
            // authored to match literally.
            return value.hasPrefix(prefix)

        case .numericRange(let min, let max):
            // The WHOLE trimmed value, in the invariant locale: "19 94"
            // and "1994a" are not numbers. Bounds inclusive.
            //
            // Scanner rather than Decimal(string:), which stops at the
            // first character it cannot use and reports success — so
            // "1994a" parsed as 1994 and a year rule matched a string
            // that is not a year. `isAtEnd` is what makes it whole-value.
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            let scanner = Scanner(string: trimmed)
            scanner.locale = nil
            scanner.charactersToBeSkipped = nil
            guard let parsed = scanner.scanDecimal(), scanner.isAtEnd else { return false }
            return parsed >= min && parsed <= max

        case .pathRootStartsWith(let root):
            return strippingRoot(value, root: root) != nil

        case .unknown:
            return false
        }
    }

    /// The remainder after `root`, or nil when the root is not a
    /// boundary-respecting prefix.
    ///
    /// Hiding `/mnt/media` must not also swallow `/mnt/mediaXYZ`. The
    /// matcher and the strip share this one function so they can never
    /// disagree about where a root ends — path parsing calls it directly
    /// to perform the `hidePrefix` strip.
    public static func strippingRoot(_ path: String, root: String) -> String? {
        var normalizedRoot = root.replacingOccurrences(of: "\\", with: "/")
        while normalizedRoot.hasSuffix("/") { normalizedRoot.removeLast() }
        guard !normalizedRoot.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        if normalizedPath == normalizedRoot { return "" }
        guard normalizedPath.hasPrefix(normalizedRoot + "/") else { return nil }
        return String(normalizedPath.dropFirst(normalizedRoot.count + 1))
    }
}
