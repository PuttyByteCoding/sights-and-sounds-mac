import Foundation

/// Reads and writes `AnalysisRule.matchJSON` / `actionsJSON`.
///
/// The stored form is the old app's wire format: one matcher object with a
/// `type` discriminator, and an ordered array of action objects. Both
/// orders are significant — rules by `sortOrder`, actions by array
/// position — and the engine folds actions in list order.
///
/// **An unrecognised type round-trips rather than being destroyed.** A
/// rule authored against a newer build, or one the migrator wrote from a
/// vocabulary this build predates, must survive being read and written
/// back. Decoding it to `.unknown` and re-encoding the original object is
/// what makes reading a rule safe.
public enum RuleCoding {

    public enum CodingError: Error, CustomStringConvertible {
        case notAnObject
        case missingType

        public var description: String {
            switch self {
            case .notAnObject: "a rule matcher must be a JSON object"
            case .missingType: "a rule matcher or action needs a \"type\""
            }
        }
    }

    // MARK: - Decoding

    public static func decodeMatcher(_ json: String) throws -> RuleMatcher {
        guard let object = try object(from: json) else { throw CodingError.notAnObject }
        guard let type = object["type"] as? String else { throw CodingError.missingType }
        switch type {
        case "keyEquals":
            return .keyEquals(key: object["key"] as? String ?? "")
        case "valueStartsWith":
            return .valueStartsWith(prefix: object["prefix"] as? String ?? "")
        case "numericRange":
            return .numericRange(
                min: decimal(object["min"]) ?? 0, max: decimal(object["max"]) ?? 0)
        case "pathRootStartsWith":
            return .pathRootStartsWith(root: object["root"] as? String ?? "")
        default:
            return .unknown(type: type)
        }
    }

    public static func decodeActions(_ json: String) throws -> [RuleAction] {
        guard let data = json.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { object in
            guard let type = object["type"] as? String else { return nil }
            switch type {
            case "ignore": return .ignore
            case "setKind": return .setKind(kind: object["kind"] as? String ?? "")
            case "stripPrefix": return .stripPrefix(prefix: object["prefix"] as? String ?? "")
            case "onlyIfTrue": return .onlyIfTrue
            // `assignGroup` is the old app's name. The migrator is meant to
            // translate it inbound; accepting it here as well means a rule
            // that slipped through untranslated still works rather than
            // silently doing nothing.
            case "assignCategory", "assignGroup":
                return .assignCategory(
                    category: (object["category"] ?? object["group"]) as? String ?? "")
            case "hidePrefix": return .hidePrefix
            default: return .unknown(type: type)
            }
        }
    }

    /// One decoded rule, or nil when the matcher is unreadable — a
    /// malformed row must not take down a whole analysis run.
    public static func decode(_ rule: AnalysisRule) -> RuleEngine.Rule? {
        guard let matcher = try? decodeMatcher(rule.matchJSON) else { return nil }
        return RuleEngine.Rule(
            id: rule.id, matcher: matcher,
            actions: (try? decodeActions(rule.actionsJSON)) ?? [])
    }

    /// Every readable rule, in `sortOrder` — the order the engine folds in.
    public static func decodeAll(_ rules: [AnalysisRule]) -> [RuleEngine.Rule] {
        rules.sorted { $0.sortOrder < $1.sortOrder }.compactMap(decode)
    }

    // MARK: - Encoding

    public static func encode(_ matcher: RuleMatcher) -> String {
        switch matcher {
        case .keyEquals(let key):
            return json(["type": "keyEquals", "key": key])
        case .valueStartsWith(let prefix):
            return json(["type": "valueStartsWith", "prefix": prefix])
        case .numericRange(let min, let max):
            return json([
                "type": "numericRange",
                "min": NSDecimalNumber(decimal: min),
                "max": NSDecimalNumber(decimal: max),
            ])
        case .pathRootStartsWith(let root):
            return json(["type": "pathRootStartsWith", "root": root])
        case .unknown(let type):
            return json(["type": type])
        }
    }

    public static func encode(_ actions: [RuleAction]) -> String {
        let objects: [[String: Any]] = actions.map { action in
            switch action {
            case .ignore: ["type": "ignore"]
            case .setKind(let kind): ["type": "setKind", "kind": kind]
            case .stripPrefix(let prefix): ["type": "stripPrefix", "prefix": prefix]
            case .onlyIfTrue: ["type": "onlyIfTrue"]
            case .assignCategory(let category):
                ["type": "assignCategory", "category": category]
            case .hidePrefix: ["type": "hidePrefix"]
            case .unknown(let type): ["type": type]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects),
              let string = String(data: data, encoding: .utf8)
        else { return "[]" }
        return string
    }

    // MARK: - Mechanics

    private static func object(from json: String) throws -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    /// Numbers arrive as either a JSON number or a string, depending on
    /// which writer produced the row.
    private static func decimal(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber { return number.decimalValue }
        if let string = value as? String { return Decimal(string: string, locale: nil) }
        return nil
    }
}

extension LibraryDatabase {

    /// Every stored rule, decoded, in the order the engine folds them.
    ///
    /// A row whose matcher cannot be read is dropped rather than throwing:
    /// one unreadable rule must not take down an analysis run over a whole
    /// library. That is the same "degrade, never throw" the matchers
    /// themselves follow — an unregistered matcher goes inert too.
    public func analysisRules() throws -> [RuleEngine.Rule] {
        try writer.read { db in
            RuleCoding.decodeAll(try AnalysisRule.fetchAll(db))
        }
    }
}
