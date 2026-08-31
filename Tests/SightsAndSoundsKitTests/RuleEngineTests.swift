import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The ported rule engine.
///
/// Every expectation here comes from the old app's implementation rather
/// than from a reading of spec 14's vocabulary — the semantics are not
/// derivable from the names, which is why they are written down in
/// `docs/design/14-tag-analysis-build-plan.md` and pinned here.
@Suite struct RuleEngineTests {

    private func rule(
        _ matcher: RuleMatcher, _ actions: [RuleAction], id: UUID = UUID()
    ) -> RuleEngine.Rule {
        RuleEngine.Rule(id: id, matcher: matcher, actions: actions)
    }

    // MARK: - The fold's three non-obvious properties

    /// Matching re-checks the CURRENT value, so a rule that strips a
    /// prefix changes what later rules see. This is how rules compose.
    @Test func aLaterRuleSeesAnEarlierRulesTransformation() {
        let strip = rule(.valueStartsWith(prefix: "The "), [.stripPrefix(prefix: "The ")])
        let assign = rule(.valueStartsWith(prefix: "Band"), [.assignCategory(category: "Band")])

        let outcome = RuleEngine.apply(
            RuleInput(key: nil, value: "The Bandwagon"), rules: [strip, assign])

        #expect(outcome.value == "Bandwagon")
        // The second rule fired only because the first had already run.
        #expect(outcome.category == "Band")
    }

    /// Last action wins, so two overlapping rules do not conflict.
    @Test func theLastRuleDecidesTheCategory() {
        let first = rule(.keyEquals(key: "artist"), [.assignCategory(category: "Band")])
        let second = rule(.keyEquals(key: "artist"), [.assignCategory(category: "Performer")])

        let outcome = RuleEngine.apply(
            RuleInput(key: "artist", value: "Phish"), rules: [first, second])
        #expect(outcome.category == "Performer")
    }

    /// Every rule is considered — there is no first-match-wins exit.
    @Test func everyMatchingRuleRuns() {
        let kind = rule(.keyEquals(key: "x"), [.setKind(kind: "title")])
        let category = rule(.keyEquals(key: "x"), [.assignCategory(category: "Venue")])

        let outcome = RuleEngine.apply(
            RuleInput(key: "x", value: "Barn"), rules: [kind, category])
        #expect(outcome.kind == .title)
        #expect(outcome.category == "Venue")
    }

    // MARK: - Actions

    @Test func ignoreDropsTheValueAndNamesTheRuleThatDidIt() {
        let id = UUID()
        let outcome = RuleEngine.apply(
            RuleInput(key: "junk", value: "whatever"),
            rules: [rule(.keyEquals(key: "junk"), [.ignore], id: id)])
        #expect(outcome.kind == .ignored)
        #expect(outcome.matchedRuleID == id)
    }

    /// A kind this build does not know is INERT, not fatal — the stored
    /// value is a free string so a new kind needs no migration.
    @Test func anUnknownKindIsInert() {
        let outcome = RuleEngine.apply(
            RuleInput(key: "x", value: "v"),
            rules: [rule(.keyEquals(key: "x"), [.setKind(kind: "sasquatch")])])
        #expect(outcome.kind == .tag)
    }

    @Test func stripPrefixIsANoOpWhenThePrefixIsAbsent() {
        let outcome = RuleEngine.apply(
            RuleInput(key: nil, value: "Bandwagon"),
            rules: [rule(.valueStartsWith(prefix: "B"), [.stripPrefix(prefix: "The ")])])
        #expect(outcome.value == "Bandwagon")
    }

    /// Trimmed and case-insensitive against "true"; anything else drops.
    @Test func onlyIfTrueKeepsTrueAndDropsEverythingElse() {
        func kind(of value: String) -> FindingKind {
            RuleEngine.apply(
                RuleInput(key: "flag", value: value),
                rules: [rule(.keyEquals(key: "flag"), [.onlyIfTrue])]).kind
        }
        #expect(kind(of: "true") == .tag)
        #expect(kind(of: "  TRUE  ") == .tag)
        #expect(kind(of: "false") == .ignored)
        #expect(kind(of: "1") == .ignored)
    }

    /// hidePrefix belongs to PATH PARSING, not to the fold. Ignoring it
    /// here is correct — the fold must not treat it as unknown noise nor
    /// invent a meaning for it.
    @Test func hidePrefixDoesNothingInTheFold() {
        let outcome = RuleEngine.apply(
            RuleInput(key: nil, value: "/mnt/media/shows/a.mp4"),
            rules: [rule(.pathRootStartsWith(root: "/mnt/media"), [.hidePrefix])])
        #expect(outcome.value == "/mnt/media/shows/a.mp4")
        #expect(outcome.kind == .tag)
    }

    // MARK: - Matchers

    /// A key-scoped rule can never fire on something with no key.
    @Test func keyEqualsNeverMatchesANilKey() {
        #expect(!RuleEngine.matches(.keyEquals(key: "band"), key: nil, value: "Phish"))
    }

    /// Both sides fold: lowercased, punctuation dropped. The key arriving
    /// here is the LEAF key, never a dot-joined path — which is what lets
    /// a rule for `OriginalMD5` fire however deeply that key was nested.
    @Test func keyEqualsFoldsBothSides() {
        #expect(RuleEngine.matches(
            .keyEquals(key: "Original_MD5"), key: "originalMd5", value: "x"))
        #expect(RuleEngine.matches(
            .keyEquals(key: "band"), key: "BAND", value: "x"))
        #expect(!RuleEngine.matches(
            .keyEquals(key: "band"), key: "bandwagon", value: "x"))
    }

    /// The fold itself, including the array indices a JSON walker leaves
    /// on a key. Pinned separately because the candidate seen-set must
    /// use this exact function — a seen-set folding differently from the
    /// matcher it protects was a real defect on two successive rewrites.
    @Test func theKeyFoldStripsIndicesPunctuationAndCase() {
        #expect(KeyNormalizer.normalize("tags[12].Original-MD5") == "tagsoriginalmd5")
        #expect(KeyNormalizer.normalize(".leading") == "leading")
        #expect(KeyNormalizer.normalize("a[0][1]b") == "ab")
    }

    /// Case-SENSITIVE: a prefix is authored to match literally.
    @Test func valueStartsWithIsCaseSensitive() {
        #expect(RuleEngine.matches(.valueStartsWith(prefix: "Title - "), key: nil, value: "Title - X"))
        #expect(!RuleEngine.matches(.valueStartsWith(prefix: "Title - "), key: nil, value: "title - X"))
    }

    /// The whole trimmed value, and bounds are inclusive.
    @Test func numericRangeTakesWholeNumbersOnlyAndIncludesItsBounds() {
        let year = RuleMatcher.numericRange(min: 1960, max: 2030)
        #expect(RuleEngine.matches(year, key: nil, value: "1994"))
        #expect(RuleEngine.matches(year, key: nil, value: " 1960 "))
        #expect(RuleEngine.matches(year, key: nil, value: "2030"))
        #expect(!RuleEngine.matches(year, key: nil, value: "1959"))
        // Not numbers.
        #expect(!RuleEngine.matches(year, key: nil, value: "1994a"))
        #expect(!RuleEngine.matches(year, key: nil, value: "19 94"))
    }

    /// The boundary hazard this matcher exists to avoid: hiding
    /// /mnt/media must not swallow /mnt/mediaXYZ.
    @Test func pathRootRespectsTheBoundary() {
        let root = RuleMatcher.pathRootStartsWith(root: "/mnt/media")
        #expect(RuleEngine.matches(root, key: nil, value: "/mnt/media/shows/a.mp4"))
        #expect(!RuleEngine.matches(root, key: nil, value: "/mnt/mediaXYZ/a.mp4"))
        // An exact equal is a match with an empty remainder.
        #expect(RuleEngine.strippingRoot("/mnt/media", root: "/mnt/media") == "")
        #expect(RuleEngine.strippingRoot("/mnt/media/shows", root: "/mnt/media/") == "shows")
        #expect(RuleEngine.strippingRoot("\\mnt\\media\\shows", root: "/mnt/media") == "shows")
    }

    /// Degrade to inert, never throw: a rule authored against a newer
    /// build must not take down an analysis run over a whole library.
    @Test func anUnknownMatcherNeverMatchesAndNeverThrows() {
        #expect(!RuleEngine.matches(.unknown(type: "fromTheFuture"), key: "k", value: "v"))
        let outcome = RuleEngine.apply(
            RuleInput(key: "k", value: "v"),
            rules: [rule(.unknown(type: "fromTheFuture"), [.ignore])])
        #expect(outcome.kind == .tag)
    }
}

/// The stored JSON, which is the migrator's output and the old app's wire
/// format — so reading it wrong is a data-compatibility bug, not a bug in
/// this app alone.
@Suite struct RuleCodingTests {

    @Test func everyMatcherRoundTrips() throws {
        let matchers: [RuleMatcher] = [
            .keyEquals(key: "band"),
            .valueStartsWith(prefix: "Title - "),
            .numericRange(min: 1960, max: 2030),
            .pathRootStartsWith(root: "/mnt/media"),
        ]
        for matcher in matchers {
            let decoded = try RuleCoding.decodeMatcher(RuleCoding.encode(matcher))
            #expect(decoded == matcher)
        }
    }

    @Test func everyActionRoundTrips() throws {
        let actions: [RuleAction] = [
            .ignore, .setKind(kind: "md5"), .stripPrefix(prefix: "The "),
            .onlyIfTrue, .assignCategory(category: "Band"), .hidePrefix,
        ]
        #expect(try RuleCoding.decodeActions(RuleCoding.encode(actions)) == actions)
    }

    /// The old app wrote `assignGroup`. The migrator is meant to translate
    /// it, but a row that slipped through untranslated should still work
    /// rather than silently do nothing.
    @Test func assignGroupIsReadAsAssignCategory() throws {
        let json = #"[{"type":"assignGroup","group":"Band"}]"#
        #expect(try RuleCoding.decodeActions(json) == [.assignCategory(category: "Band")])
    }

    /// An unrecognised type survives being read and written back — being
    /// destroyed by a build that predates it would be the worse failure.
    @Test func anUnknownTypeRoundTripsRatherThanBeingLost() throws {
        let decoded = try RuleCoding.decodeMatcher(#"{"type":"fromTheFuture","x":1}"#)
        #expect(decoded == .unknown(type: "fromTheFuture"))
        let reencoded = try RuleCoding.decodeMatcher(RuleCoding.encode(decoded))
        #expect(reencoded == .unknown(type: "fromTheFuture"))
    }

    /// Numbers may arrive as JSON numbers or as strings depending on the
    /// writer; both have to parse.
    @Test func numericBoundsParseFromEitherForm() throws {
        let asNumbers = try RuleCoding.decodeMatcher(
            #"{"type":"numericRange","min":1960,"max":2030}"#)
        let asStrings = try RuleCoding.decodeMatcher(
            #"{"type":"numericRange","min":"1960","max":"2030"}"#)
        #expect(asNumbers == .numericRange(min: 1960, max: 2030))
        #expect(asStrings == asNumbers)
    }

    /// A malformed row must not take down a run: it decodes to nil and is
    /// skipped, and the readable rules around it still fold.
    @Test func aMalformedRuleIsSkippedNotFatal() {
        let good = AnalysisRule(
            sortOrder: 1, matchJSON: #"{"type":"keyEquals","key":"band"}"#,
            actionsJSON: #"[{"type":"ignore"}]"#)
        let bad = AnalysisRule(sortOrder: 0, matchJSON: "not json at all", actionsJSON: "[]")
        let decoded = RuleCoding.decodeAll([bad, good])
        #expect(decoded.count == 1)
        #expect(decoded.first?.matcher == .keyEquals(key: "band"))
    }

    /// sortOrder is the fold order, and the engine depends on it.
    @Test func rulesDecodeInSortOrder() {
        let second = AnalysisRule(
            sortOrder: 2, matchJSON: #"{"type":"keyEquals","key":"b"}"#, actionsJSON: "[]")
        let first = AnalysisRule(
            sortOrder: 1, matchJSON: #"{"type":"keyEquals","key":"a"}"#, actionsJSON: "[]")
        let decoded = RuleCoding.decodeAll([second, first])
        #expect(decoded.map(\.matcher) == [.keyEquals(key: "a"), .keyEquals(key: "b")])
    }
}
