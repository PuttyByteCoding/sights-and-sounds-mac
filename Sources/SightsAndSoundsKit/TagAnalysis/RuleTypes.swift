import Foundation

/// What the analysis decided a string is.
///
/// `tag` is the default and `ignored` is what a drop looks like. Ported
/// from the old engine's `FindingKind`; the stored form stays a free
/// string on the rule so a new kind needs no migration, and an
/// unrecognised one is inert rather than fatal.
public enum FindingKind: String, Sendable, CaseIterable {
    case tag, title, path, filename, md5, flag, ignored

    /// Lenient, case-insensitive. Nil for a kind this build does not know.
    public static func parse(_ raw: String) -> FindingKind? {
        FindingKind(rawValue: raw.lowercased())
    }
}

/// One string offered to the engine, with the raw key it was found under.
///
/// The key is the **leaf** key, not a dot-joined path — so a rule for
/// `OriginalMD5` fires however deeply that key is nested. Nil when the
/// value has no enclosing key at all: a path segment, a bare string, a
/// reader's top-level value.
public struct RuleInput: Hashable, Sendable {
    public let key: String?
    public let value: String

    public init(key: String?, value: String) {
        self.key = key
        self.value = value
    }
}

/// What the fold produced.
///
/// `matchedRuleID` names the rule whose action actually set the kind to
/// `.ignored` — an explicit ignore, or `onlyIfTrue` on a non-true value.
/// Nil for every other outcome: explaining a drop means naming the rule
/// that caused it, not merely knowing that some rule ran.
public struct RuleOutcome: Equatable, Sendable {
    public let kind: FindingKind
    public let value: String
    public let category: String?
    public let matchedRuleID: UUID?

    public init(kind: FindingKind, value: String, category: String?, matchedRuleID: UUID?) {
        self.kind = kind
        self.value = value
        self.category = category
        self.matchedRuleID = matchedRuleID
    }
}

/// The wire vocabulary's matchers. Raw values are the stored `type`
/// discriminators and are not a naming opportunity — the migrator writes
/// them and the old engine read them.
public enum RuleMatcher: Equatable, Sendable {
    case keyEquals(key: String)
    case valueStartsWith(prefix: String)
    case numericRange(min: Decimal, max: Decimal)
    case pathRootStartsWith(root: String)
    /// A matcher this build does not recognise. Kept so a rule authored
    /// against a newer build round-trips instead of being destroyed by
    /// being read — and never matches, so it degrades to inert.
    case unknown(type: String)

    public var typeName: String {
        switch self {
        case .keyEquals: "keyEquals"
        case .valueStartsWith: "valueStartsWith"
        case .numericRange: "numericRange"
        case .pathRootStartsWith: "pathRootStartsWith"
        case .unknown(let type): type
        }
    }

    /// Names what the matcher FIRES ON, not what it does — a caller
    /// explaining a drop already knows one happened.
    public var explanation: String {
        switch self {
        case .keyEquals(let key): "key \"\(key)\""
        case .valueStartsWith(let prefix): "value starts with \"\(prefix)\""
        case .numericRange(let min, let max): "value between \(min) and \(max)"
        case .pathRootStartsWith(let root): "path root \"\(root)\""
        case .unknown: "a rule"
        }
    }
}

/// The wire vocabulary's actions, folded in list order.
public enum RuleAction: Equatable, Sendable {
    case ignore
    case setKind(kind: String)
    case stripPrefix(prefix: String)
    case onlyIfTrue
    /// Stored as `assignGroup` by the old app; the migrator translates on
    /// the way in, never at read time.
    case assignCategory(category: String)
    /// Consumed by PATH PARSING, not by the fold: strip the media root,
    /// then any `hidePrefix` match, then split into segments. It exists so
    /// a hidden root is an ordinary rule row rather than a separate synced
    /// setting. The fold ignoring it is correct, not a gap.
    case hidePrefix
    case unknown(type: String)

    public var typeName: String {
        switch self {
        case .ignore: "ignore"
        case .setKind: "setKind"
        case .stripPrefix: "stripPrefix"
        case .onlyIfTrue: "onlyIfTrue"
        case .assignCategory: "assignCategory"
        case .hidePrefix: "hidePrefix"
        case .unknown(let type): type
        }
    }
}

/// The one key fold in the pipeline.
///
/// Two callers must never disagree about it: the `keyEquals` matcher and
/// the candidate seen-set. A seen-set folding differently from the matcher
/// it protects either under-collapses — two occurrences of the same text
/// under different keys silently becoming one, losing a category
/// assignment — or over-collapses. Both were real defects on two
/// successive rewrites of this pipeline, which is why it lives in one
/// place and says so.
public enum KeyNormalizer {
    public static func normalize(_ key: String) -> String {
        var stripped = key.replacingOccurrences(
            of: "\\[\\d+\\]", with: "", options: .regularExpression)
        if stripped.hasPrefix(".") { stripped.removeFirst() }
        return stripped.lowercased().replacingOccurrences(
            of: "[^a-z0-9]", with: "", options: .regularExpression)
    }
}
