import Foundation
import GRDB

/// What a rule would do, counted but not done.
///
/// Spec 14 §6: a rule reports before it writes. Both numbers are here
/// because they answer different questions — how many strings the matcher
/// fires on, and how much of the library that reaches.
public struct RuleDryRun: Equatable, Sendable {
    /// Candidate rows the matcher fires on.
    public let matchedCandidates: Int
    /// Distinct items behind those rows. Counted, not summed: two
    /// candidates can share an item, so adding their counts overstates it.
    public let affectedItems: Int
    /// How many of the matched rows came from embedded metadata. The
    /// spec's dry-run sentence names metadata pairs specifically, and it
    /// is only the whole truth when this equals `matchedCandidates`.
    public let metadataMatches: Int
    public let actionCount: Int

    public var isEmpty: Bool { matchedCandidates == 0 }
}

extension LibraryDatabase {

    // MARK: - Reading

    /// The stored rows, in fold order. The decoded form is
    /// `analysisRules()`; this is for the editor, which needs the row to
    /// write back to.
    public func analysisRuleRecords() throws -> [AnalysisRule] {
        try writer.read { db in
            try AnalysisRule.order(sql: "sortOrder, id").fetchAll(db)
        }
    }

    // MARK: - Writing

    /// Insert or update one rule. The matcher and actions are encoded
    /// through `RuleCoding`, so the wire vocabulary is written in exactly
    /// one place and an unknown type authored against a newer build
    /// round-trips rather than being destroyed by being saved.
    public func saveAnalysisRule(_ rule: RuleEngine.Rule, sortOrder: Int? = nil) throws {
        try writer.write { db in
            let order = try sortOrder ?? AnalysisRule.fetchOne(db, key: rule.id)?.sortOrder
                ?? ((try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM analysisRule") ?? -1) + 1)
            try AnalysisRule(
                id: rule.id, sortOrder: order,
                matchJSON: RuleCoding.encode(rule.matcher),
                actionsJSON: RuleCoding.encode(rule.actions)
            ).upsert(db)
        }
    }

    public func deleteAnalysisRule(_ id: UUID) throws {
        _ = try writer.write { db in
            try AnalysisRule.deleteOne(db, key: id)
        }
    }

    /// Rewrite the fold order. Order is the engine (spec 14 §5), so it is
    /// stored densely from zero rather than left with the gaps a swap
    /// leaves behind — a gap is invisible on screen and survives into
    /// every later insert.
    public func setAnalysisRuleOrder(_ ids: [UUID]) throws {
        try writer.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE analysisRule SET sortOrder = ? WHERE id = ?",
                    arguments: [index, id])
            }
        }
    }

    /// Move one rule one place up or down, and persist the whole order.
    /// A no-op at either end rather than an error: the buttons are always
    /// present, and disabling them is the view's business.
    public func moveAnalysisRule(_ id: UUID, up: Bool) throws {
        var ids = try analysisRuleRecords().map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let target = up ? index - 1 : index + 1
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        try setAnalysisRuleOrder(ids)
    }

    // MARK: - Dry run

    /// What this rule would match, without writing anything.
    ///
    /// Run against the **candidate queue**, not the raw tables: the queue
    /// is what the rule is authored against, so a dry run counting rows
    /// the queue excludes would promise matches the operator will never
    /// see. `rule` is evaluated alone — the number answers "what does THIS
    /// rule fire on", not "what survives the whole fold".
    public func dryRun(_ rule: RuleEngine.Rule) throws -> RuleDryRun {
        let candidates = try tagCandidates(rules: [])
        let matched = candidates.filter {
            RuleEngine.matches(rule.matcher, key: $0.key, value: $0.value)
        }
        return RuleDryRun(
            matchedCandidates: matched.count,
            affectedItems: try itemsAffected(by: matched),
            metadataMatches: matched.count { $0.source == .metadata },
            actionCount: rule.actions.count)
    }

    /// Every rule's dry run in one pass — the per-card "412 pairs · 380
    /// items" lines. The queue is computed ONCE and each rule filters it;
    /// running dryRun(_:) per card would recompute the whole queue per
    /// rule.
    public func dryRuns(for rules: [RuleEngine.Rule]) throws -> [UUID: RuleDryRun] {
        let candidates = try tagCandidates(rules: [])
        var results: [UUID: RuleDryRun] = [:]
        for rule in rules {
            let matched = candidates.filter {
                RuleEngine.matches(rule.matcher, key: $0.key, value: $0.value)
            }
            results[rule.id] = RuleDryRun(
                matchedCandidates: matched.count,
                affectedItems: try itemsAffected(by: matched),
                metadataMatches: matched.count { $0.source == .metadata },
                actionCount: rule.actions.count)
        }
        return results
    }

    /// The rule a "make a rule from this" should OPEN rather than rival —
    /// spec 14 §4. Nil when nothing covers the candidate yet.
    public func ruleCovering(_ candidate: TagCandidate) throws -> RuleEngine.Rule? {
        try ruleCovering(key: candidate.key, value: candidate.value)
    }

    public func ruleCovering(key: String?, value: String) throws -> RuleEngine.Rule? {
        try analysisRules().first {
            RuleEngine.matches($0.matcher, key: key, value: value)
        }
    }

    /// The matcher a new rule from this candidate starts with.
    ///
    /// A keyed candidate becomes `keyEquals`, which is the precise claim
    /// and the one the operator almost always wants: every value under
    /// this metadata key. An unkeyed one — a path segment or an on-screen
    /// line — has no key to match, so it falls back to the value itself.
    public static func matcher(forNewRuleFrom candidate: TagCandidate) -> RuleMatcher {
        matcher(forKey: candidate.key, value: candidate.value)
    }

    /// The same choice, from a bare (key, value) — the per-video analysis
    /// hands strings over without a TagCandidate around them.
    public static func matcher(forKey key: String?, value: String) -> RuleMatcher {
        if let key, !key.isEmpty { return .keyEquals(key: key) }
        return .valueStartsWith(prefix: value)
    }
}

/// What applying a rule actually did.
public struct RuleApplication: Equatable, Sendable {
    public let itemsUpdated: Int
    public let candidatesIgnored: Int
    /// Categories the rule named that this library does not have. The
    /// rule is not rewritten and nothing is invented: a category is a
    /// deliberate object with an order and a colour, so a rule naming one
    /// that does not exist is reported rather than silently creating it.
    public let unknownCategories: [String]
}

extension LibraryDatabase {

    /// Fold one rule over the queue and carry out what it decides.
    ///
    /// The tag takes the **folded value, not the candidate's** — a rule
    /// pairing `stripPrefix("The ")` with `assignCategory("Band")` exists
    /// precisely so "The Beatles" files under "Beatles". Using the raw
    /// string here would make every prefix rule a no-op that still
    /// reported success.
    @discardableResult
    public func applyAnalysisRule(_ rule: RuleEngine.Rule) throws -> RuleApplication {
        let categoriesByName = Dictionary(
            try writer.read { db in try TagCategory.fetchAll(db) }
                .map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })

        // Distinct items, not assignments: two candidates under one rule
        // routinely share an item, and reporting the assignment count
        // would tell the operator the rule touched more of the library
        // than it did.
        var updatedItems = Set<UUID>()
        var ignored = 0
        var unknown = Set<String>()

        for candidate in try tagCandidates(rules: []) {
            guard RuleEngine.matches(rule.matcher, key: candidate.key, value: candidate.value)
            else { continue }
            let outcome = RuleEngine.apply(
                RuleInput(key: candidate.key, value: candidate.value), rules: [rule])

            if outcome.kind == .ignored {
                try decide(candidate, as: .ignored)
                ignored += 1
                continue
            }

            guard let categoryName = outcome.category else { continue }
            guard let category = categoriesByName[categoryName.lowercased()] else {
                unknown.insert(categoryName)
                continue
            }

            let name = outcome.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let tag = try ensureTag(named: name, inCategory: category.id)
            for evidence in try candidateEvidence(for: candidate, limit: Int.max) {
                try assignTag(tag.id, to: evidence.item.id)
                updatedItems.insert(evidence.item.id)
            }
            try decide(candidate, as: .accepted)
        }

        return RuleApplication(
            itemsUpdated: updatedItems.count, candidatesIgnored: ignored,
            unknownCategories: unknown.sorted())
    }
}
