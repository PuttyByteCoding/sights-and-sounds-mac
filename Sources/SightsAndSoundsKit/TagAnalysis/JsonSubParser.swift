import Foundation

/// One non-empty scalar found in a JSON payload.
///
/// `rawKey` is the walk's own untouched object key — **never re-derived by
/// splitting `keyPath`**, which breaks on a key containing a literal dot.
/// Nil for a scalar with no enclosing object key at all, such as a root
/// array's items.
///
/// `keyPath` keeps `[N]` index segments so array entries stay
/// distinguishable for display; `rawKey` never carries one, so an
/// array-rooted payload's leaves match a `keyEquals` rule identically to an
/// object-rooted one's. **keyPath is for display, rawKey is for lookup.
/// Never swap them.**
public struct JsonLeaf: Equatable, Sendable {
    public let text: String
    public let rawKey: String?
    public let keyPath: String
}

public enum JsonLeafExtractor {

    /// Only an object or an array counts as structured. A bare scalar does
    /// not: routing it here would strip the key it arrived under for no
    /// gain.
    public static func isStructuredJSON(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first,
              first == "{" || first == "["
        else { return false }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else { return false }
        return object is [String: Any] || object is [Any]
    }

    public static func extract(_ raw: String) -> [JsonLeaf] {
        guard isStructuredJSON(raw),
              let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        var leaves: [JsonLeaf] = []
        walk(root, rawKey: nil, keyPath: "", into: &leaves)
        return leaves
    }

    private static func walk(
        _ value: Any, rawKey: String?, keyPath: String, into leaves: inout [JsonLeaf]
    ) {
        switch value {
        case let object as [String: Any]:
            // The object key passes straight through, untouched by array
            // nesting.
            for (name, child) in object.sorted(by: { $0.key < $1.key }) {
                walk(child, rawKey: name, keyPath: join(keyPath, name), into: &leaves)
            }

        case let array as [Any]:
            // The index goes into the DISPLAY path only. rawKey is
            // inherited unchanged, so it never becomes index-bearing.
            for (index, item) in array.enumerated() {
                walk(item, rawKey: rawKey, keyPath: "\(keyPath)[\(index)]", into: &leaves)
            }

        case is NSNull:
            break  // empty leaves contribute nothing

        default:
            let text = stringify(value)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                leaves.append(JsonLeaf(text: text, rawKey: rawKey, keyPath: keyPath))
            }
        }
    }

    private static func join(_ keyPath: String, _ name: String) -> String {
        keyPath.isEmpty ? name : "\(keyPath).\(name)"
    }

    /// Booleans and numbers arrive stringified because `onlyIfTrue`
    /// compares against the literal string "true".
    private static func stringify(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            // CFBoolean is an NSNumber; distinguishing it is what keeps a
            // JSON `true` from stringifying as "1" and silently failing
            // every onlyIfTrue rule.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return "\(value)"
    }
}

/// The JSON half of the parser loop.
///
/// Each leaf is handed back **with its own raw object key** so the hub's
/// rule fallback — the one place a raw string becomes a candidate — can run
/// a key-aware match against it. Keeping rule application in exactly one
/// place is what stops a JSON leaf and a plain metadata value from ever
/// being evaluated differently.
public struct JsonSubParser: SubParser {
    public let id = "jsonParser"

    public init() {}

    public func detect(_ raw: String) -> Bool { JsonLeafExtractor.isStructuredJSON(raw) }

    public func parse(_ raw: String) -> [SubParserNextItem] {
        JsonLeafExtractor.extract(raw).map {
            SubParserNextItem(raw: $0.text, key: $0.rawKey)
        }
    }
}
