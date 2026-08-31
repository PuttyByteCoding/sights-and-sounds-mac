import Foundation
import GRDB

/// One item a candidate was found in, and — for on-screen text — the
/// moment it was read.
///
/// `timeSeconds` is what makes the evidence strip worth showing at all:
/// spec 14 §8 wants the frame **at the moment the string was read**, not a
/// representative thumbnail. A still from elsewhere in the file answers
/// nothing, because the string is not on screen in it.
public struct CandidateEvidence: Equatable, Sendable, Identifiable {
    public let item: MediaItem
    /// Nil for metadata and path candidates — they are properties of the
    /// file, not of a moment in it.
    public let timeSeconds: Double?

    public var id: UUID { item.id }
}

/// What the operator decided to do with a candidate.
///
/// Spec 14 §3: a suggestion is a suggestion. The candidate carries a
/// proposed decision and the operator accepts, redirects or rejects it —
/// so this is the redirected outcome, not the suggestion.
public enum CandidateApplication: Equatable, Sendable {
    /// Make (or find) a tag with this name in the category and apply it to
    /// every matching item.
    case assignCategory(categoryID: UUID)
    /// The string is another name for a tag that already exists. No item
    /// is retagged: the alias makes future sweeps recognise it, which is
    /// why it also stops being a candidate.
    case alias(ofTag: UUID)
    /// Not a tag, and not worth being asked again.
    case ignore
}

extension LibraryDatabase {

    /// The items a candidate appears in, newest evidence first.
    ///
    /// Bounded by `limit` because the strip shows a handful and the count
    /// is already on the row — a candidate in 4,000 items must not load
    /// 4,000 records to draw six stills.
    public func candidateEvidence(
        for candidate: TagCandidate, limit: Int = 24, pathSegmenter: PathSubParser? = nil,
        within scope: Set<UUID>? = nil
    ) throws -> [CandidateEvidence] {
        let scopeJSON = Self.scopeJSON(scope)
        switch candidate.source {
        case .metadata:
            return try writer.read { db in
                try MediaItem.fetchAll(
                    db,
                    sql: """
                    SELECT mediaItem.* FROM mediaItem \
                    JOIN embeddedMetadataPair ON embeddedMetadataPair.mediaItemID = mediaItem.id \
                    WHERE embeddedMetadataPair.key = ? AND embeddedMetadataPair.value = ? \
                    \(Self.scopeClause("mediaItem.id", scopeJSON, prefix: "AND")) \
                    ORDER BY mediaItem.relativePath LIMIT ?
                    """,
                    arguments: [candidate.key, candidate.value]
                        + (scopeJSON.map { [$0] } ?? []) + [limit]
                ).map { CandidateEvidence(item: $0, timeSeconds: nil) }
            }

        case .onScreen:
            // The EARLIEST reading of the string in each item. Any single
            // moment would do; the first is reproducible, which matters
            // when the same still is generated again later.
            return try writer.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT mediaItemID, MIN(timeSeconds) AS t FROM ocrTextLine \
                    WHERE text = ? \(Self.scopeClause("mediaItemID", scopeJSON, prefix: "AND")) \
                    GROUP BY mediaItemID LIMIT ?
                    """,
                    arguments: [candidate.value] + (scopeJSON.map { [$0] } ?? []) + [limit])
                var evidence: [CandidateEvidence] = []
                for row in rows {
                    let itemID: UUID = row["mediaItemID"]
                    guard let item = try MediaItem.fetchOne(db, key: itemID) else { continue }
                    evidence.append(CandidateEvidence(item: item, timeSeconds: row["t"]))
                }
                return evidence.sorted { $0.item.relativePath < $1.item.relativePath }
            }

        case .path:
            // Segmenting is parsing, so it happens through the sub-parser
            // rather than by matching the string against the path — which
            // would make "live" match "Olive Grove".
            let segmenter = pathSegmenter ?? PathSubParser(mediaRoot: nil, rules: [])
            let folders = try writer.read { db in
                try String.fetchAll(
                    db, sql: "SELECT DISTINCT folderPath FROM mediaItem WHERE folderPath <> ''")
            }
            let matching = folders.filter { segmenter.segments(of: $0).contains(candidate.value) }
            guard !matching.isEmpty else { return [] }
            return try writer.read { db in
                try MediaItem.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM mediaItem WHERE folderPath IN (\(databaseQuestionMarks(count: matching.count))) \
                    \(Self.scopeClause("id", scopeJSON, prefix: "AND")) \
                    ORDER BY relativePath LIMIT ?
                    """,
                    arguments: StatementArguments(matching)
                        + (scopeJSON.map { [$0] } ?? []) + [limit]
                ).map { CandidateEvidence(item: $0, timeSeconds: nil) }
            }
        }
    }

    /// The number of items a candidate's decision would touch. The bulk
    /// bar's second number, and deliberately counted rather than summed
    /// from the rows: two candidates can share items, so adding their
    /// counts overstates the blast radius.
    public func itemsAffected(
        by candidates: [TagCandidate], pathSegmenter: PathSubParser? = nil,
        within scope: Set<UUID>? = nil
    ) throws -> Int {
        var ids = Set<UUID>()
        for candidate in candidates {
            // No limit here: this is a count, and an underestimate would
            // understate what Apply is about to do.
            for evidence in try candidateEvidence(
                for: candidate, limit: Int.max, pathSegmenter: pathSegmenter, within: scope)
            {
                ids.insert(evidence.item.id)
            }
        }
        return ids.count
    }

    /// Carry out a decision. Returns the number of items updated.
    ///
    /// Every path records the decision, so the candidate leaves the queue
    /// whichever way it was decided — that is the point of the decisions
    /// table. Category assignment is an ordinary database write, revertible
    /// like any other (spec 14 §9: do not invent a third audit trail).
    /// `within` limits what an accept touches. An **ignore stays global
    /// regardless of scope**: the decision table is keyed by (source, key,
    /// value) because "not a tag" is a fact about the string, not about
    /// whichever items you happened to be looking at.
    @discardableResult
    public func apply(
        _ candidate: TagCandidate, _ application: CandidateApplication,
        pathSegmenter: PathSubParser? = nil,
        within scope: Set<UUID>? = nil
    ) throws -> Int {
        switch application {
        case .ignore:
            try decide(candidate, as: .ignored)
            return 0

        case .alias(let tagID):
            try addAlias(candidate.value, toTag: tagID)
            // No decision row needed — an alias makes the string a known
            // tag name, so the queue excludes it on its own. Recording one
            // anyway would mean removing the alias never brings it back.
            return 0

        case .assignCategory(let categoryID):
            let tag = try ensureTag(named: candidate.value, inCategory: categoryID)
            let evidence = try candidateEvidence(
                for: candidate, limit: Int.max, pathSegmenter: pathSegmenter, within: scope)
            for one in evidence {
                try assignTag(tag.id, to: one.item.id)
            }
            // A SCOPED accept records no decision: the row would suppress
            // the string library-wide while only the scoped items were
            // tagged. The string now names a tag, so the queue excludes
            // it anyway — and the un-tagged rest stays reachable through
            // "Missing — no <Category> tag".
            if scope?.isEmpty ?? true {
                try decide(candidate, as: .accepted)
            }
            return evidence.count
        }
    }
}

/// `?, ?, ?` for an IN clause. GRDB has no public helper for a bare SQL
/// string, and building it inline invites an off-by-one.
private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
