import Foundation
import GRDB

extension LibraryDatabase {

    /// The candidate queue: every string appearing in items that has no
    /// tag behind it, grouped with the number of items it appears in.
    ///
    /// **Derived, never stored.** A decision changes the underlying data,
    /// so the queue recomputes rather than being maintained — which is
    /// also why a decision is keyed by (source, key, value) instead of by
    /// a row id that will not exist next time.
    ///
    /// Three sources reach it by two routes, and the split is not
    /// arbitrary. Metadata pairs and on-screen lines group in SQL, where
    /// the counting belongs. **Path fragments cannot**: splitting a path
    /// is parsing, and the rules for it — separators, schemes, escapes,
    /// the media root, hidden roots — live in `PathSubParser`. So paths
    /// are segmented in Swift over the DISTINCT folder paths rather than
    /// per item, of which there are orders of magnitude fewer.
    ///
    /// Excluded: anything that already names a tag or one of its aliases,
    /// and anything already decided. A string a RULE would drop is **not**
    /// excluded — it comes back marked, because a mis-authored ignore rule
    /// has to be diagnosable rather than invisible.
    /// `within` narrows the queue to strings found in those items, with
    /// counts counted inside the scope — "what is in THIS video", or in
    /// the current play queue, rather than in the library. Nil is the
    /// whole library, and an empty set is nobody's question, so it means
    /// the whole library too.
    public func tagCandidates(
        sources: Set<TagCandidateSource> = Set(TagCandidateSource.allCases),
        rules: [RuleEngine.Rule] = [],
        limit: Int = 2000,
        pathSegmenter: PathSubParser? = nil,
        within scope: Set<UUID>? = nil
    ) throws -> [TagCandidate] {
        let scopeJSON = Self.scopeJSON(scope)
        let known = try knownTagText()
        let decided = try decidedCandidateKeys()

        var rows: [(source: TagCandidateSource, key: String?, value: String, count: Int)] = []

        if sources.contains(.metadata) {
            rows += try writer.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT key, value, COUNT(DISTINCT mediaItemID) AS n \
                    FROM embeddedMetadataPair \
                    \(Self.scopeClause("mediaItemID", scopeJSON, prefix: "WHERE")) \
                    GROUP BY key, value
                    """,
                    arguments: scopeJSON.map { [$0] } ?? []
                ).map { (.metadata, $0["key"] as String, $0["value"] as String, $0["n"] as Int) }
            }
        }

        if sources.contains(.onScreen) {
            rows += try writer.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT text, COUNT(DISTINCT mediaItemID) AS n \
                    FROM ocrTextLine \
                    \(Self.scopeClause("mediaItemID", scopeJSON, prefix: "WHERE")) \
                    GROUP BY text
                    """,
                    arguments: scopeJSON.map { [$0] } ?? []
                ).map { (.onScreen, nil, $0["text"] as String, $0["n"] as Int) }
            }
        }

        if sources.contains(.path) {
            rows += try pathCandidates(
                segmenter: pathSegmenter ?? PathSubParser(mediaRoot: nil, rules: rules),
                scopeJSON: scopeJSON)
        }

        var candidates: [TagCandidate] = []
        for row in rows {
            let trimmed = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Already a tag, or already one of a tag's aliases — an alias
            // IS a name, so a candidate matching one is not news.
            guard !known.contains(trimmed.lowercased()) else { continue }
            guard !decided.contains(Self.decisionKey(row.source, row.key, trimmed)) else { continue }

            let outcome = RuleEngine.apply(
                RuleInput(key: row.key, value: trimmed), rules: rules)
            let matched = rules.first { $0.id == outcome.matchedRuleID }
            candidates.append(
                TagCandidate(
                    source: row.source, key: row.key, value: trimmed, itemCount: row.count,
                    suggestedCategory: outcome.category,
                    suppressedByRule: outcome.kind == .ignored ? matched?.matcher.explanation : nil,
                    coveredByRuleID: coveringRule(row.key, trimmed, rules)?.id))
        }

        // Commonest first: a string in 40 items is worth deciding before
        // one in 2, and the bulk bar's whole value is that the obvious
        // ones cluster at the top.
        return Array(
            candidates.sorted {
                $0.itemCount == $1.itemCount
                    ? $0.value.localizedStandardCompare($1.value) == .orderedAscending
                    : $0.itemCount > $1.itemCount
            }.prefix(limit))
    }

    /// Path fragments, segmented over DISTINCT folder paths rather than
    /// per item — there are orders of magnitude fewer folders than files,
    /// and each folder's segment set is the same for every item under it.
    private func pathCandidates(
        segmenter: PathSubParser, scopeJSON: String?
    ) throws -> [(source: TagCandidateSource, key: String?, value: String, count: Int)] {
        let folders = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT folderPath, COUNT(*) AS n FROM mediaItem \
                WHERE folderPath <> '' \(Self.scopeClause("id", scopeJSON, prefix: "AND")) \
                GROUP BY folderPath
                """,
                arguments: scopeJSON.map { [$0] } ?? []
            ).map { ($0["folderPath"] as String, $0["n"] as Int) }
        }

        var counts: [String: Int] = [:]
        for (path, itemCount) in folders {
            // A segment appearing twice in one path counts that path once:
            // the number is "items this string appears in", not
            // occurrences.
            for segment in Set(segmenter.segments(of: path)) {
                counts[segment, default: 0] += itemCount
            }
        }
        return counts.map { (.path, nil, $0.key, $0.value) }
    }

    /// Every tag name and alias, folded to lowercase — the set a candidate
    /// must not already be in.
    private func knownTagText() throws -> Set<String> {
        try writer.read { db in
            var known = Set<String>()
            for name in try String.fetchAll(db, sql: "SELECT name FROM tag") {
                known.insert(name.lowercased())
            }
            for alias in try String.fetchAll(db, sql: "SELECT alias FROM tagAlias") {
                known.insert(alias.lowercased())
            }
            return known
        }
    }

    private func decidedCandidateKeys() throws -> Set<String> {
        try writer.read { db in
            Set(
                try TagCandidateDecision.fetchAll(db).map {
                    Self.decisionKey($0.source, $0.key, $0.value)
                })
        }
    }

    static func decisionKey(_ source: TagCandidateSource, _ key: String?, _ value: String) -> String {
        "\(source.rawValue)|\(KeyNormalizer.normalize(key ?? ""))|\(value.lowercased())"
    }

    /// The first rule whose matcher already fires on this string — spec 14
    /// §4: "make a rule from this" must open that rule rather than adding
    /// a rival, and the row says so before you click.
    private func coveringRule(
        _ key: String?, _ value: String, _ rules: [RuleEngine.Rule]
    ) -> RuleEngine.Rule? {
        rules.first { RuleEngine.matches($0.matcher, key: key, value: value) }
    }

    // MARK: - Scope plumbing

    /// The scope as one SQL argument: a JSON array of dash-less uppercase
    /// UUID hex, matched with `hex(column) IN (SELECT value FROM
    /// json_each(?))`.
    ///
    /// One bound argument regardless of size — a plain IN list runs into
    /// SQLite's bound-variable ceiling exactly when the scope is a real
    /// play queue. `hex()` of the stored 16-byte blob IS the dash-less
    /// uuidString, which is what makes the comparison exact. The scan
    /// this defeats an index for is a GROUP BY over the whole table
    /// anyway.
    static func scopeJSON(_ scope: Set<UUID>?) -> String? {
        guard let scope, !scope.isEmpty else { return nil }
        let hex = scope.map { $0.uuidString.replacingOccurrences(of: "-", with: "") }
        return "[" + hex.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// `prefix` is WHERE or AND, depending on what the query already has.
    static func scopeClause(_ column: String, _ scopeJSON: String?, prefix: String) -> String {
        scopeJSON == nil
            ? "" : "\(prefix) hex(\(column)) IN (SELECT value FROM json_each(?))"
    }

    // MARK: - Deciding

    /// Record a decision so the queue stops offering the candidate.
    public func decide(
        _ candidate: TagCandidate, as decision: TagCandidateDecision.Decision
    ) throws {
        try writer.write { db in
            try TagCandidateDecision(
                source: candidate.source, key: candidate.key, value: candidate.value,
                decision: decision
            ).insert(db)
        }
    }

    /// Undo a decision — the candidate returns to the queue on the next
    /// recomputation.
    public func clearDecision(for candidate: TagCandidate) throws {
        _ = try writer.write { db in
            try TagCandidateDecision
                .filter(sql: "source = ? AND value = ? AND (key IS ? OR key = ?)",
                        arguments: [
                            candidate.source.rawValue, candidate.value,
                            candidate.key, candidate.key,
                        ])
                .deleteAll(db)
        }
    }

    // MARK: - Metadata pairs

    /// Replace one item's pairs and mark it swept.
    ///
    /// The marker is separate from the pairs because an item whose file
    /// carries no metadata leaves none behind, and without it such an item
    /// is re-probed on every run forever.
    public func recordMetadataPairs(
        itemID: UUID, pairs: [(name: String, value: String)], failure: String? = nil
    ) throws {
        try writer.write { db in
            try EmbeddedMetadataPair
                .filter(sql: "mediaItemID = ?", arguments: [itemID])
                .deleteAll(db)
            for pair in pairs {
                let trimmed = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                try EmbeddedMetadataPair(
                    mediaItemID: itemID, key: pair.name, value: trimmed
                ).insert(db)
            }
            try MetadataSweepState(mediaItemID: itemID, failureMessage: failure).upsert(db)
        }
    }

    /// Items the sweep has not visited, oldest first. A missing marker is
    /// the only thing that makes an item eligible, so a retry is a row
    /// deletion.
    public func itemsNeedingMetadataSweep(limit: Int = 500) throws -> [MediaItem] {
        try writer.read { db in
            try MediaItem.fetchAll(
                db,
                sql: """
                SELECT mediaItem.* FROM mediaItem \
                LEFT JOIN metadataSweepState ON metadataSweepState.mediaItemID = mediaItem.id \
                WHERE metadataSweepState.mediaItemID IS NULL \
                AND mediaItem.parentMediaItemID IS NULL \
                ORDER BY mediaItem.relativePath LIMIT ?
                """,
                arguments: [limit])
        }
    }
}

extension LibraryDatabase {
    /// How many of these items the metadata sweep has not visited — the
    /// cheap check before auto-enqueueing a scoped sweep, so opening a
    /// scoped window on already-swept items queues nothing.
    public func unsweptCount(in scope: Set<UUID>) throws -> Int {
        guard !scope.isEmpty else { return 0 }
        let json = Self.scopeJSON(scope)
        return try writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM mediaItem \
                LEFT JOIN metadataSweepState ON metadataSweepState.mediaItemID = mediaItem.id \
                WHERE metadataSweepState.mediaItemID IS NULL \
                AND mediaItem.parentMediaItemID IS NULL \
                \(Self.scopeClause("mediaItem.id", json, prefix: "AND"))
                """,
                arguments: json.map { [$0] } ?? []) ?? 0
        }
    }
}
