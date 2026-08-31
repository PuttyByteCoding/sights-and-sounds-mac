import Foundation

/// A candidate the parser's rule step identified. Bare on purpose — turning
/// it into an applied/unapplied row against the tag inventory is a later
/// stage's job.
///
/// `suppressedByRule` is nil for an ordinary candidate, otherwise a
/// description of the matcher whose rule ignored it. A rule-ignored value
/// is **not dropped**: it survives as a suppressed candidate so a
/// mis-authored ignore rule can be seen and diagnosed, rather than the
/// value vanishing with no trace.
public struct ParsedCandidate: Equatable, Sendable {
    public let value: String
    public let category: String?
    public let suppressedByRule: String?
    /// The enclosing object key the value was found under, when there was
    /// one — "the key beside the value could indicate which value is the
    /// taper's name", so the display must be able to show it.
    public let key: String?

    public init(
        value: String, category: String? = nil, suppressedByRule: String? = nil,
        key: String? = nil
    ) {
        self.value = value
        self.category = category
        self.suppressedByRule = suppressedByRule
        self.key = key
    }
}

/// One step of the trail: this tool examined this raw string, at this
/// depth, under this key.
///
/// Returned as **data, never logged** — the window renders these as its
/// collapsed results table. `tool` is a sub-parser's id, `md5` for the
/// built-in detector, `textParser` for the rule fallback, `alreadySeen`
/// when the cycle guard fired, or `timeout` when the run was cut short.
/// Deliberately a string rather than a closed set, so a new sub-parser
/// appears here without this file changing.
public struct ProvenanceStep: Equatable, Sendable {
    public let tool: String
    public let raw: String
    public let depth: Int
    public let key: String?

    public init(tool: String, raw: String, depth: Int, key: String?) {
        self.tool = tool
        self.raw = raw
        self.depth = depth
        self.key = key
    }
}

public struct TextParseResult: Equatable, Sendable {
    public let candidates: [ParsedCandidate]
    public let md5s: [String]
    public let provenance: [ProvenanceStep]
    /// The run was cut short. Must be surfaced **where the results are**,
    /// not only in the trail: an incomplete list that looks complete is
    /// worse than a visibly incomplete one.
    public let truncated: Bool
}

/// One item a sub-parser hands back as further work. `key` is the enclosing
/// object key when there was one, nil otherwise — a path segment or a
/// reader's top-level string has none.
public struct SubParserNextItem: Equatable, Sendable {
    public let raw: String
    public let key: String?

    public init(raw: String, key: String?) {
        self.raw = raw
        self.key = key
    }
}

/// The injection point sub-parsers register through.
///
/// `TextParser` depends only on this shape and never on a concrete parser —
/// it has no switch naming "json" or "path". **Registration order is
/// precedence**, and a PRECISE detector must come before a LOOSE one: the
/// path detector claims any slash anywhere, while the JSON detector
/// requires a `{`/`[` start *and* a successful parse. Registering the loose
/// one first starves the precise one and shreds every JSON payload
/// containing a path — learned the hard way on the previous cut.
///
/// `parse` cannot throw, which is stronger than the original's contract:
/// there, one bad sub-parser could unwind out of the whole run and discard
/// every candidate found so far, and it had to be defended against at
/// runtime. Here the type system makes that impossible.
public protocol SubParser: Sendable {
    var id: String { get }
    func detect(_ raw: String) -> Bool
    func parse(_ raw: String) -> [SubParserNextItem]
}

/// How long a parse may run.
///
/// A wall-clock bound is the **only** limit. The depth cap and node budget
/// an earlier cut carried are deliberately absent: recursion should not hit
/// a limit in normal operation, and a timeout guards the thing actually
/// worth guarding — the analysis not hanging — rather than standing in for
/// it via proxies that ordinary data can trip.
public struct ParseDeadline: Sendable {
    let expiry: ContinuousClock.Instant

    public var isExpired: Bool { ContinuousClock.now >= expiry }

    public static func seconds(_ seconds: Double) -> ParseDeadline {
        ParseDeadline(expiry: ContinuousClock.now.advanced(by: .seconds(seconds)))
    }

    /// Already spent — for proving the truncation path.
    public static var expired: ParseDeadline {
        ParseDeadline(expiry: ContinuousClock.now.advanced(by: .seconds(-1)))
    }
}

/// The hub of the recursive pipeline. Given a raw string it decides what
/// the string *is* and delegates rather than parsing everything itself:
///
/// - looks like JSON → the JSON sub-parser, stop parsing as text
/// - looks like a path → the path sub-parser, stop
/// - looks like an MD5 → emit that fact, stop
/// - otherwise → apply rules to identify a candidate
///
/// Sub-parsers feed what they extract **back in**, which is the
/// architecture's defining property and its hazard: a path inside a JSON
/// value inside a container comment resolves all the way down.
public struct TextParser: Sendable {
    private let subParsers: [any SubParser]

    /// Order is precedence. See `SubParser` — precise before loose.
    public init(subParsers: [any SubParser]) {
        self.subParsers = subParsers
    }

    /// Bare 32-hex string. The only built-in detector alongside the rule
    /// fallback. MD5 gets no sub-parser because it never recurses — there
    /// is nothing to hand back, so the contract does not fit it.
    private static let md5Pattern = try! NSRegularExpression(
        pattern: "^[a-f0-9]{32}$", options: [.caseInsensitive])

    private struct State {
        var seen: Set<String> = []
        var candidates: [ParsedCandidate] = []
        var md5s: [String] = []
        var provenance: [ProvenanceStep] = []
        var truncated = false
    }

    /// Everything starts fresh per call: two readers legally reporting the
    /// same literal string must each get a full pass, not have the second
    /// suppressed as a false repeat.
    ///
    /// Driven by an explicit worklist rather than the call stack. The
    /// timeout is the only limit on how far this walks, and letting an
    /// unbounded walk grow the *call* stack risks a crash that takes the
    /// process with it — no partial results, no truncation flag. A
    /// heap-allocated stack walks exactly as far, safely.
    public func parse(
        _ raw: String, rules: [RuleEngine.Rule], deadline: ParseDeadline
    ) -> TextParseResult {
        parse(raw, key: nil, rules: rules, deadline: deadline)
    }

    /// As above, with the top-level string already under a key — an
    /// embedded metadata value arrives under its field name, and the rule
    /// fold must see that key exactly ONCE, here, rather than being
    /// re-applied by the caller to an already-folded value (which runs
    /// every stripPrefix twice).
    public func parse(
        _ raw: String, key: String?, rules: [RuleEngine.Rule], deadline: ParseDeadline
    ) -> TextParseResult {
        var state = State()
        var work: [(raw: String, key: String?, depth: Int)] = [(raw, key, 0)]

        while let node = work.popLast() {
            // Truncation stops the drain entirely. Everything still queued
            // would only hit the same check and do nothing — and stopping
            // is what keeps the timeout row to exactly one.
            guard process(node, rules: rules, state: &state, work: &work, deadline: deadline)
            else { break }
        }

        return TextParseResult(
            candidates: state.candidates, md5s: state.md5s,
            provenance: state.provenance, truncated: state.truncated)
    }

    /// One node. Returns false the instant truncation is discovered.
    private func process(
        _ node: (raw: String, key: String?, depth: Int),
        rules: [RuleEngine.Rule], state: inout State,
        work: inout [(raw: String, key: String?, depth: Int)], deadline: ParseDeadline
    ) -> Bool {
        let (raw, key, depth) = node

        if deadline.isExpired {
            state.truncated = true
            state.provenance.append(ProvenanceStep(tool: "timeout", raw: raw, depth: depth, key: key))
            return false
        }

        // Nothing to parse, and not a limit hit — so no provenance, which
        // keeps blank sub-parser output from becoming junk rows.
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }

        let seenKey = Self.seenKey(key: key, raw: raw)
        guard state.seen.insert(seenKey).inserted else {
            state.provenance.append(
                ProvenanceStep(tool: "alreadySeen", raw: raw, depth: depth, key: key))
            return true
        }

        for sub in subParsers where sub.detect(raw) {
            state.provenance.append(
                ProvenanceStep(tool: sub.id, raw: raw, depth: depth, key: key))
            // Pushed in reverse so popping reproduces left-to-right,
            // depth-first order — provenance and candidate ordering are
            // pinned to it.
            for item in sub.parse(raw).reversed() {
                work.append((item.raw, item.key, depth + 1))
            }
            return true  // first matching sub-parser wins
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isMD5(trimmed) {
            // The seen-set is KEY-scoped, so the same hash under two
            // different keys reaches here twice. Each occurrence earns its
            // own provenance row — both are real and worth showing — but
            // the md5s list is a set of DISTINCT hashes, not an occurrence
            // log: a caller doing something once per hash must not see it
            // twice.
            let hash = trimmed.lowercased()
            if !state.md5s.contains(hash) { state.md5s.append(hash) }
            state.provenance.append(ProvenanceStep(tool: "md5", raw: raw, depth: depth, key: key))
            return true
        }

        state.provenance.append(
            ProvenanceStep(tool: "textParser", raw: raw, depth: depth, key: key))
        let outcome = RuleEngine.apply(RuleInput(key: key, value: raw), rules: rules)
        let suppressedBy = outcome.kind == .ignored
            ? rules.first { $0.id == outcome.matchedRuleID }?.matcher.explanation
            : nil
        state.candidates.append(
            ParsedCandidate(
                value: outcome.value, category: outcome.category,
                suppressedByRule: suppressedBy, key: key))
        return true
    }

    /// Key-scoped, and folded through the **same** normaliser the
    /// `keyEquals` matcher uses. Both halves were review defects: text-only
    /// scoping silently drops a second occurrence's key-scoped rule match,
    /// and a raw-key comparison lets two occurrences the engine considers
    /// identical each get their own pass.
    ///
    /// The fold's output is always `[a-z0-9]`, so it can never contain the
    /// separator — the join is unambiguous by construction rather than by
    /// an assumption about realistic input.
    static func seenKey(key: String?, raw: String) -> String {
        KeyNormalizer.normalize(key ?? "") + " "
            + raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isMD5(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return md5Pattern.firstMatch(in: value, range: range) != nil
    }
}
