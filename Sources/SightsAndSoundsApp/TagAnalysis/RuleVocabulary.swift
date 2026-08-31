import Foundation
import SightsAndSoundsKit

/// The matcher vocabulary as the editor needs it: a closed list of kinds,
/// each with the spec's one-line explanation and a placeholder for its
/// argument.
///
/// The wire names are spelled exactly as `AnalysisRule`'s header lists
/// them — they are the ported vocabulary, not a naming opportunity — and
/// they are the `rawValue`s so the screen and the JSON can never drift.
///
/// `unknown` is deliberately absent: a matcher this build does not
/// recognise has no kind to offer in a radio list, and the editor says so
/// instead of pretending it can be edited.
enum MatcherKind: String, CaseIterable, Hashable {
    case keyEquals
    case valueStartsWith
    case numericRange
    case pathRootStartsWith

    init?(_ matcher: RuleMatcher) {
        switch matcher {
        case .keyEquals: self = .keyEquals
        case .valueStartsWith: self = .valueStartsWith
        case .numericRange: self = .numericRange
        case .pathRootStartsWith: self = .pathRootStartsWith
        case .unknown: return nil
        }
    }

    /// Spec 14's copy, verbatim.
    var explanation: String {
        switch self {
        case .keyEquals: "the metadata key is exactly this"
        case .valueStartsWith: "the value begins with this string"
        case .numericRange: "the value falls in this numeric range"
        case .pathRootStartsWith: "the item's path starts with this folder"
        }
    }

    var placeholder: String {
        switch self {
        case .keyEquals: "band"
        case .valueStartsWith: "Title - "
        case .numericRange: "1900-2100"
        case .pathRootStartsWith: "/Volumes/Media"
        }
    }

    /// Build this kind of matcher from the argument field's text.
    ///
    /// A range is two numbers in one field, written `min-max`. One field
    /// because switching matcher kind keeps the text — the argument
    /// carries across so a mis-click does not erase what was typed — and
    /// two fields would have nothing to carry to. Text that is not a
    /// range yields `0-0`, which matches nothing: an inert rule, never a
    /// crash.
    func matcher(argument: String) -> RuleMatcher {
        switch self {
        case .keyEquals: .keyEquals(key: argument)
        case .valueStartsWith: .valueStartsWith(prefix: argument)
        case .pathRootStartsWith: .pathRootStartsWith(root: argument)
        case .numericRange:
            {
                let parts = argument.split(separator: "-", maxSplits: 1).map {
                    Decimal(string: $0.trimmingCharacters(in: .whitespaces)) ?? 0
                }
                return .numericRange(
                    min: parts.first ?? 0, max: parts.count > 1 ? parts[1] : (parts.first ?? 0))
            }()
        }
    }
}

extension RuleMatcher {
    /// The matcher's argument as one editable string. The inverse of
    /// `MatcherKind.matcher(argument:)`, and it must stay the inverse:
    /// they are the two halves of the same field.
    var argument: String {
        switch self {
        case .keyEquals(let key): key
        case .valueStartsWith(let prefix): prefix
        case .pathRootStartsWith(let root): root
        case .numericRange(let min, let max): "\(min)-\(max)"
        case .unknown: ""
        }
    }
}

/// The action vocabulary, same rules: closed, wire-spelled, `unknown`
/// absent because it cannot be authored.
enum ActionKind: String, CaseIterable, Hashable {
    case ignore
    case setKind
    case stripPrefix
    case onlyIfTrue
    case assignCategory
    case hidePrefix

    init?(_ action: RuleAction) {
        switch action {
        case .ignore: self = .ignore
        case .setKind: self = .setKind
        case .stripPrefix: self = .stripPrefix
        case .onlyIfTrue: self = .onlyIfTrue
        case .assignCategory: self = .assignCategory
        case .hidePrefix: self = .hidePrefix
        case .unknown: return nil
        }
    }

    /// A newly added action, with an empty argument where it takes one.
    var blank: RuleAction {
        switch self {
        case .ignore: .ignore
        case .onlyIfTrue: .onlyIfTrue
        case .hidePrefix: .hidePrefix
        case .setKind: .setKind(kind: "")
        case .stripPrefix: .stripPrefix(prefix: "")
        case .assignCategory: .assignCategory(category: "")
        }
    }

    /// Nil for the three actions that take no argument — the editor draws
    /// no field for them rather than an empty one that does nothing.
    func argument(of action: RuleAction) -> String? {
        switch action {
        case .setKind(let kind): kind
        case .stripPrefix(let prefix): prefix
        case .assignCategory(let category): category
        case .ignore, .onlyIfTrue, .hidePrefix, .unknown: nil
        }
    }

    func withArgument(_ text: String) -> RuleAction {
        switch self {
        case .setKind: .setKind(kind: text)
        case .stripPrefix: .stripPrefix(prefix: text)
        case .assignCategory: .assignCategory(category: text)
        case .ignore: .ignore
        case .onlyIfTrue: .onlyIfTrue
        case .hidePrefix: .hidePrefix
        }
    }

    var placeholder: String {
        switch self {
        // Spec §7: setKind takes a KIND, never a metadata key. Free text
        // there is how `OriginalMD5` ends up as a kind name.
        case .setKind: "filename · md5 · title · flag"
        case .stripPrefix: "The "
        case .assignCategory: "Band"
        case .ignore, .onlyIfTrue, .hidePrefix: ""
        }
    }
}

extension RuleEngine.Rule {
    /// A copy with a different action list. `Rule` keeps its stored
    /// properties immutable — a fold's inputs should not be mutable
    /// mid-fold — so the editor rebuilds rather than the Kit loosening.
    func with(actions: [RuleAction]) -> RuleEngine.Rule {
        RuleEngine.Rule(id: id, matcher: matcher, actions: actions)
    }
}
