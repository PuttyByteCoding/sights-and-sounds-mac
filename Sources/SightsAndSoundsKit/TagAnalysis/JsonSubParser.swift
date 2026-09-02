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

    /// Strict whole-string JSON, or JSON EMBEDDED in a longer string —
    /// a comment field's "Ripped by X {…} enjoy" counts. The embedded
    /// path was the reported miss: real comment fields bury their JSON
    /// in prose, and the starts-with check never saw it.
    public func detect(_ raw: String) -> Bool {
        JsonLeafExtractor.isStructuredJSON(raw)
            || !JsonLeafExtractor.embeddedSpans(in: raw).isEmpty
    }

    public func parse(_ raw: String, key: String?) -> [SubParserNextItem] {
        if JsonLeafExtractor.isStructuredJSON(raw) {
            return JsonLeafExtractor.extract(raw).map {
                SubParserNextItem(raw: $0.text, key: $0.rawKey)
            }
        }
        // Embedded: each span explodes into keyed leaves, and the prose
        // AROUND the spans survives as text under the ORIGINAL key — a
        // rule authored against the field still sees it.
        let spans = JsonLeafExtractor.embeddedSpans(in: raw)
        var items: [SubParserNextItem] = []
        var cursor = raw.startIndex
        for span in spans {
            let before = String(raw[cursor..<span.range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { items.append(SubParserNextItem(raw: before, key: key)) }
            items += JsonLeafExtractor.extract(span.json).map {
                SubParserNextItem(raw: $0.text, key: $0.rawKey)
            }
            cursor = span.range.upperBound
        }
        let after = String(raw[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !after.isEmpty { items.append(SubParserNextItem(raw: after, key: key)) }
        return items
    }
}

extension JsonLeafExtractor {

    /// A balanced, parseable JSON span found INSIDE a longer string —
    /// "Ripped by X {"taper": "Mike"} enjoy" carries one. The strict
    /// detector requires the whole string to be JSON; real comment
    /// fields bury their JSON in prose, and that was the reported miss.
    public struct EmbeddedSpan: Equatable, Sendable {
        public let json: String
        public let range: Range<String.Index>
    }

    /// Every embedded span, left to right, non-overlapping. A span must
    /// balance its brackets (string-aware, escape-aware) AND parse as an
    /// object or array — a stray brace in prose fails one or the other
    /// and contributes nothing.
    public static func embeddedSpans(in raw: String) -> [EmbeddedSpan] {
        var spans: [EmbeddedSpan] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let ch = raw[index]
            guard ch == "{" || ch == "[" else {
                index = raw.index(after: index)
                continue
            }
            guard let end = balancedEnd(in: raw, from: index) else {
                index = raw.index(after: index)
                continue
            }
            let candidate = String(raw[index...end])
            if isStructuredJSON(candidate) {
                spans.append(EmbeddedSpan(json: candidate, range: index..<raw.index(after: end)))
                index = raw.index(after: end)
            } else {
                index = raw.index(after: index)
            }
        }
        return spans
    }

    /// The index of the bracket closing the one at `start`, honouring
    /// strings and escapes. Nil when the text runs out first.
    private static func balancedEnd(in raw: String, from start: String.Index) -> String.Index? {
        let open = raw[start]
        let close: Character = open == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < raw.endIndex {
            let ch = raw[index]
            if escaped {
                escaped = false
            } else if inString {
                if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case open: depth += 1
                case close:
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index = raw.index(after: index)
        }
        return nil
    }
}
