import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The recursive parser core.
///
/// The pathological cases here are ported from the old app and are the
/// reason termination is understood at all — mutual recursion, case-flip
/// repeats, wide fan-out, and the same text under two keys.
@Suite struct TextParserTests {

    /// The shipped registration order: PRECISE before LOOSE. The JSON
    /// detector requires a `{`/`[` start and a successful parse; the path
    /// detector claims any slash anywhere. The other order starves JSON.
    private func parser(mediaRoot: String? = nil, rules: [RuleEngine.Rule] = []) -> TextParser {
        TextParser(subParsers: [
            JsonSubParser(),
            PathSubParser(mediaRoot: mediaRoot, rules: rules),
        ])
    }

    private func parse(
        _ raw: String, rules: [RuleEngine.Rule] = [], mediaRoot: String? = nil,
        deadline: ParseDeadline = .seconds(5)
    ) -> TextParseResult {
        parser(mediaRoot: mediaRoot, rules: rules)
            .parse(raw, rules: rules, deadline: deadline)
    }

    // MARK: - The defining property

    /// A path inside a JSON value inside a container comment resolves all
    /// the way down. This is the whole architecture in one test.
    @Test func aPathInsideJsonIsParsedAllTheWayDown() {
        let json = #"{"comment":"/mnt/media/Phish/1995/show.mp4"}"#
        let result = parse(json, mediaRoot: "/mnt/media")

        let values = result.candidates.map(\.value)
        #expect(values.contains("Phish"))
        #expect(values.contains("1995"))
        // The whole path never becomes a candidate in its own right — it
        // was claimed by the path parser and replaced by its segments.
        #expect(!values.contains(where: { $0.contains("/") }))

        let tools = result.provenance.map(\.tool)
        #expect(tools.first == "jsonParser")
        #expect(tools.contains("pathParser"))
    }

    /// Precedence in the other direction: a JSON payload that happens to
    /// contain a slash must still be claimed by the JSON parser.
    @Test func jsonWinsOverPathWhenBothCouldClaimIt() {
        let result = parse(#"{"a":"x/y"}"#)
        #expect(result.provenance.first?.tool == "jsonParser")
    }

    // MARK: - Pathological cases

    /// Mutual recursion: a path segment that itself looks like a path.
    /// Terminates because the segments shrink, and the seen-set catches
    /// any that do not.
    @Test func mutualRecursionTerminates() {
        let result = parse("/a/b/c/d/e/f")
        #expect(!result.truncated)
        #expect(Set(result.candidates.map(\.value)) == ["a", "b", "c", "d", "e", "f"])
    }

    /// Case-flip repeats collapse: the seen-set folds the value to
    /// lowercase, so Live / live / LIVE under the same key is one pass.
    @Test func caseFlipRepeatsAreSeenOnce() {
        let result = parse(#"{"k":["Live","live","LIVE"]}"#)
        #expect(result.candidates.count == 1)
        #expect(result.provenance.filter { $0.tool == "alreadySeen" }.count == 2)
    }

    /// The seen-set is KEY-SCOPED: the same text under two different keys
    /// is parsed twice. Collapsing them silently drops the second
    /// occurrence's key-scoped rule match — a real defect, twice.
    @Test func theSameTextUnderTwoKeysIsParsedTwice() {
        let result = parse(#"{"band":"Live","venue":"Live"}"#)
        #expect(result.candidates.count == 2)
        #expect(result.provenance.filter { $0.tool == "alreadySeen" }.isEmpty)
    }

    /// Wide fan-out: a payload with many leaves completes rather than
    /// tripping some proxy for a limit.
    @Test func wideFanOutCompletes() {
        let leaves = (0..<400).map { "\"k\($0)\":\"v\($0)\"" }.joined(separator: ",")
        let result = parse("{\(leaves)}")
        #expect(!result.truncated)
        #expect(result.candidates.count == 400)
    }

    // MARK: - Termination

    /// The deadline is the only limit, and it produces exactly ONE timeout
    /// row: once truncation is discovered the drain stops entirely, so no
    /// sibling or cousin gets a chance to add its own.
    @Test func anExpiredDeadlineTruncatesWithExactlyOneRow() {
        let result = parse(#"{"a":"1","b":"2","c":"3"}"#, deadline: .expired)
        #expect(result.truncated)
        #expect(result.provenance.filter { $0.tool == "timeout" }.count == 1)
        #expect(result.candidates.isEmpty)
    }

    @Test func anUntruncatedRunSaysSo() {
        #expect(!parse("Phish").truncated)
    }

    // MARK: - MD5

    /// A bare 32-hex string is a fact, not a tag.
    @Test func anMD5IsDetectedAndNeverBecomesACandidate() {
        let hash = "d41d8cd98f00b204e9800998ecf8427e"
        let result = parse(hash)
        #expect(result.md5s == [hash])
        #expect(result.candidates.isEmpty)
        #expect(result.provenance.map(\.tool) == ["md5"])
    }

    /// The same hash under two keys earns two provenance rows — both
    /// occurrences are real — but the md5s list is a set of DISTINCT
    /// hashes, so a caller acting once per hash does not act twice.
    @Test func aRepeatedHashIsListedOnceButTrailedTwice() {
        let hash = "d41d8cd98f00b204e9800998ecf8427e"
        let result = parse(#"{"OriginalMD5":"\#(hash)","hash":"\#(hash)"}"#)
        #expect(result.md5s == [hash])
        #expect(result.provenance.filter { $0.tool == "md5" }.count == 2)
    }

    @Test func md5DetectionIsCaseInsensitiveAndAnchored() {
        #expect(TextParser.isMD5("D41D8CD98F00B204E9800998ECF8427E"))
        #expect(!TextParser.isMD5("d41d8cd98f00b204e9800998ecf8427"))    // 31
        #expect(!TextParser.isMD5("d41d8cd98f00b204e9800998ecf8427ez"))  // trailing
    }

    // MARK: - Rules reach the fallback

    /// The rule fallback is the ONE place a raw string becomes a
    /// candidate, so a JSON leaf and a plain value are evaluated
    /// identically — including key-aware matching.
    @Test func aJsonLeafIsRuleMatchedByItsOwnKey() {
        let rule = RuleEngine.Rule(
            id: UUID(), matcher: .keyEquals(key: "band"),
            actions: [.assignCategory(category: "Band")])
        let result = parse(#"{"band":"Phish","venue":"Barn"}"#, rules: [rule])

        // Asserted on the candidates rather than through a dictionary:
        // [String: String?] subscripting yields String??, so a present key
        // with a nil category reads as .some(nil) and never equals nil.
        #expect(result.candidates.first { $0.value == "Phish" }?.category == "Band")
        #expect(result.candidates.first { $0.value == "Barn" }?.category == nil)
    }

    /// A path segment is handed back UNKEYED, so it can never satisfy a
    /// key-scoped rule.
    @Test func pathSegmentsCannotSatisfyAKeyRule() {
        let rule = RuleEngine.Rule(
            id: UUID(), matcher: .keyEquals(key: "comment"),
            actions: [.assignCategory(category: "Wrong")])
        let result = parse(#"{"comment":"/a/b"}"#, rules: [rule])
        #expect(result.candidates.allSatisfy { $0.category == nil })
    }

    /// A rule-ignored value SURVIVES as a suppressed candidate naming the
    /// matcher that dropped it — so a mis-authored ignore rule can be
    /// diagnosed instead of the value vanishing without trace.
    @Test func aRuleIgnoredValueSurvivesAndNamesTheMatcher() {
        let rule = RuleEngine.Rule(
            id: UUID(), matcher: .keyEquals(key: "junk"), actions: [.ignore])
        let result = parse(#"{"junk":"noise"}"#, rules: [rule])

        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.suppressedByRule == "key \"junk\"")
    }
}

/// The JSON half.
@Suite struct JsonLeafExtractorTests {

    @Test func onlyObjectsAndArraysAreStructured() {
        #expect(JsonLeafExtractor.isStructuredJSON(#"{"a":1}"#))
        #expect(JsonLeafExtractor.isStructuredJSON("[1,2]"))
        // A bare scalar is not: routing it here would strip its key.
        #expect(!JsonLeafExtractor.isStructuredJSON(#""just a string""#))
        #expect(!JsonLeafExtractor.isStructuredJSON("42"))
        #expect(!JsonLeafExtractor.isStructuredJSON("not json"))
        #expect(!JsonLeafExtractor.isStructuredJSON("{"))
    }

    /// rawKey is the walk's own key and never index-bearing, so an
    /// array-rooted payload's leaves match a keyEquals rule identically to
    /// an object-rooted one's. keyPath keeps indices, for display.
    @Test func arrayIndicesLandInTheDisplayPathNotTheKey() {
        let leaves = JsonLeafExtractor.extract(#"{"tags":["a","b"]}"#)
        #expect(leaves.map(\.rawKey) == ["tags", "tags"])
        #expect(leaves.map(\.keyPath) == ["tags[0]", "tags[1]"])
    }

    /// A key containing a literal dot is why rawKey is carried rather than
    /// re-derived by splitting keyPath.
    @Test func aKeyWithADotSurvives() {
        let leaves = JsonLeafExtractor.extract(#"{"a.b":"v"}"#)
        #expect(leaves.first?.rawKey == "a.b")
    }

    /// Booleans stringify as "true"/"false" because onlyIfTrue compares
    /// against the literal string — an NSNumber-shaped `true` rendering as
    /// "1" would silently fail every such rule.
    @Test func booleansStringifyAsWords() {
        let leaves = JsonLeafExtractor.extract(#"{"a":true,"b":false,"c":7}"#)
        let byKey = Dictionary(uniqueKeysWithValues: leaves.map { ($0.rawKey ?? "", $0.text) })
        #expect(byKey["a"] == "true")
        #expect(byKey["b"] == "false")
        #expect(byKey["c"] == "7")
    }

    @Test func nullsAndBlanksContributeNothing() {
        let leaves = JsonLeafExtractor.extract(#"{"a":null,"b":"","c":"  "}"#)
        #expect(leaves.isEmpty)
    }

    @Test func aRootArraysItemsHaveNoKey() {
        let leaves = JsonLeafExtractor.extract(#"["x","y"]"#)
        #expect(leaves.allSatisfy { $0.rawKey == nil })
    }
}

/// The path half.
@Suite struct PathSubParserTests {

    private func subParser(
        mediaRoot: String? = nil, hidden: [String] = []
    ) -> PathSubParser {
        let rules = hidden.map {
            RuleEngine.Rule(
                id: UUID(), matcher: .pathRootStartsWith(root: $0), actions: [.hidePrefix])
        }
        return PathSubParser(mediaRoot: mediaRoot, rules: rules)
    }

    @Test func detectionIsDeliberatelyLoose() {
        // "16/9" matching too is accepted: the segments harm nothing and a
        // rule can suppress them.
        #expect(subParser().detect("16/9"))
        #expect(subParser().detect("C:\\media\\x"))
        #expect(!subParser().detect("Phish"))
    }

    @Test func theMediaRootStripsFirst() {
        let segments = subParser(mediaRoot: "/mnt/media")
            .segments(of: "/mnt/media/Phish/1995/show.mp4")
        #expect(segments == ["Phish", "1995", "show.mp4"])
    }

    /// A hidden root under the media root is written RELATIVE to it,
    /// because the absolute form is no longer a prefix once the media root
    /// has gone.
    @Test func hiddenRootsMatchWhatIsLeftAfterTheMediaRoot() {
        let segments = subParser(mediaRoot: "/mnt/media", hidden: ["private"])
            .segments(of: "/mnt/media/private/Phish/x.mp4")
        #expect(segments == ["Phish", "x.mp4"])
    }

    /// Longest first, so the more specific root wins whatever order the
    /// rules were authored in — and exactly ONE strip, never a chain.
    @Test func theLongestHiddenRootWinsAndOnlyOneStripHappens() {
        let segments = subParser(hidden: ["/a", "/a/b"]).segments(of: "/a/b/c")
        #expect(segments == ["c"])
    }

    @Test func schemesAndEscapesAreHandled() {
        #expect(subParser().segments(of: "file:///mnt/My%20Shows/x.mp4")
            == ["mnt", "My Shows", "x.mp4"])
        // A malformed escape must not blank the path.
        #expect(subParser().segments(of: "/a/100%/b") == ["a", "100%", "b"])
    }

    @Test func backslashesAndEmptySegmentsNormalise() {
        #expect(subParser().segments(of: "\\a\\\\b\\") == ["a", "b"])
    }
}
