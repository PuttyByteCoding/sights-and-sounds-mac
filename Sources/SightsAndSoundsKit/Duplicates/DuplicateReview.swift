import Foundation
import GRDB

/// What `decide` did — for the UI to report honestly.
public struct DecideOutcome: Sendable, Equatable {
    public let tagsMerged: Int
    /// Single-value-category tags that could NOT merge because the keeper's
    /// existing pick wins — one human-readable line each.
    public let skippedSingleValue: [String]
    /// Set when the decision committed but the physical staging move
    /// failed — the old ordering guarantee: a filesystem failure never
    /// costs the user their curated decision.
    public var stagingWarning: String?
}

public enum DecideError: Error, CustomStringConvertible, Equatable {
    case samePair
    case notFound
    case keeperMarkedForDeletion
    case candidateDoesNotLinkPair

    public var description: String {
        switch self {
        case .samePair: "keeper and loser must be different items"
        case .notFound: "one of the items no longer exists"
        case .keeperMarkedForDeletion:
            "the keeper is marked for deletion — restore it first, or keep the other side"
        case .candidateDoesNotLinkPair: "the candidate does not link these two items"
        }
    }
}

/// Duplicate review operations — ported decide semantics from the old
/// app's compare endpoint:
///
///   - The library, not the caller, decides which tags are mergeable: a
///     multi-value-category tag merges if the keeper lacks it; a
///     single-value-category tag merges only when the keeper holds NO tag
///     in that category (the keeper's existing pick always wins), and the
///     category is claimed the moment one loser tag is accepted so two
///     loser tags in one single-value category can't both slip through.
///   - A keeper already staged for deletion is refused outright.
///   - Everything commits in one transaction. (The old app's two-phase
///     ordering hazard — tags first, then the physical `_ToDelete` move —
///     returns when Phase 7 adds file staging; the loser is flag-marked
///     only until then.)
extension LibraryDatabase {
    /// Pending candidates, newest first.
    public func pendingCandidates() throws -> [DuplicateCandidate] {
        try writer.read { db in
            try DuplicateCandidate
                .filter(sql: "status = 'pending'")
                .order(sql: "createdAt DESC")
                .fetchAll(db)
        }
    }

    /// Both copies are wanted. The pair leaves the queue without either
    /// file being staged, and — like `rejected` — the row survives so
    /// the sweeps cannot re-flag it.
    public func keepBothCandidate(_ candidateID: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE duplicateCandidate SET status = 'keptBoth' WHERE id = ?",
                arguments: [candidateID])
        }
    }

    public func rejectCandidate(_ candidateID: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE duplicateCandidate SET status = 'rejected' WHERE id = ?",
                arguments: [candidateID])
        }
    }

    /// The loser's tags that WOULD merge onto the keeper — for the UI to
    /// preview. Pure query; `decide` recomputes on its own snapshot.
    public func mergeableTags(keeper keeperID: UUID, loser loserID: UUID) throws -> [Tag] {
        try writer.read { db in
            try Self.computeMergeable(db, keeperID: keeperID, loserID: loserID).map(\.tag)
        }
    }

    /// Resolve a pair: merge the mergeable subset of `mergeTagIDs`, confirm
    /// the candidate, mark the loser for deletion (flag only until Phase 7
    /// stages files) and clear its review state.
    @discardableResult
    public func decide(
        keeper keeperID: UUID, loser loserID: UUID,
        candidateID: UUID?, mergeTagIDs: Set<UUID>,
        fileAccess: any FileAccess = LiveFileAccess()
    ) throws -> DecideOutcome {
        guard keeperID != loserID else { throw DecideError.samePair }
        var outcome = try writer.write { db in
            guard let keeper = try MediaItem.fetchOne(db, key: keeperID),
                  try MediaItem.fetchOne(db, key: loserID) != nil
            else { throw DecideError.notFound }
            guard !keeper.markedForDeletion else { throw DecideError.keeperMarkedForDeletion }

            if let candidateID {
                guard let candidate = try DuplicateCandidate.fetchOne(db, key: candidateID),
                      Set([candidate.itemAID, candidate.itemBID]) == Set([keeperID, loserID])
                else { throw DecideError.candidateDoesNotLinkPair }
            }

            // Recompute mergeability here — never trust the caller's list.
            let mergeable = try Self.computeMergeable(db, keeperID: keeperID, loserID: loserID)
            var merged = 0
            var skipped: [String] = []
            for entry in mergeable {
                guard mergeTagIDs.contains(entry.tag.id) else { continue }
                try MediaItemTag(mediaItemID: keeperID, tagID: entry.tag.id).insert(db, onConflict: .ignore)
                merged += 1
            }
            // Requested-but-unmergeable single-value tags get their honest
            // explanation.
            let mergeableIDs = Set(mergeable.map(\.tag.id))
            if !mergeTagIDs.subtracting(mergeableIDs).isEmpty {
                let unmergeable = try Tag.fetchAll(
                    db, keys: Array(mergeTagIDs.subtracting(mergeableIDs)))
                for tag in unmergeable {
                    let category = try TagCategory.fetchOne(db, key: tag.tagCategoryID)
                    skipped.append(
                        "\(category?.name ?? "?"): keeper already has a tag in this single-value category — '\(tag.name)' was not merged.")
                }
            }

            if let candidateID {
                try db.execute(
                    sql: "UPDATE duplicateCandidate SET status = 'confirmed' WHERE id = ?",
                    arguments: [candidateID])
            }

            // Flag the loser; the physical staging move is Phase 7's.
            try db.execute(
                sql: "UPDATE mediaItem SET markedForDeletion = 1, needsReview = 0 WHERE id = ?",
                arguments: [loserID])

            return DecideOutcome(tagsMerged: merged, skippedSingleValue: skipped)
        }
        // Two-phase on purpose (ported ordering): the decision above is
        // committed; the physical _ToDelete staging happens after, and a
        // move failure surfaces as a warning on the intact outcome.
        do {
            try stage(.toDelete, itemID: loserID, fileAccess: fileAccess)
        } catch {
            outcome.stagingWarning =
                "Decision saved, but the file could not be staged: \(error). It remains where it was."
        }
        return outcome
    }

    /// The mergeable set: loser tags the keeper can take, honoring
    /// multi/single-value category rules with in-loop category claiming.
    private static func computeMergeable(
        _ db: Database, keeperID: UUID, loserID: UUID
    ) throws -> [(tag: Tag, category: TagCategory)] {
        let keeperTagIDs = Set(try UUID.fetchAll(
            db, sql: "SELECT tagID FROM mediaItemTag WHERE mediaItemID = ?", arguments: [keeperID]))
        var keeperCategoryIDs = Set(try UUID.fetchAll(
            db,
            sql: """
            SELECT tag.tagCategoryID FROM tag \
            JOIN mediaItemTag ON mediaItemTag.tagID = tag.id \
            WHERE mediaItemTag.mediaItemID = ?
            """,
            arguments: [keeperID]))

        let loserTags = try Tag.fetchAll(
            db,
            sql: """
            SELECT tag.* FROM tag \
            JOIN mediaItemTag ON mediaItemTag.tagID = tag.id \
            WHERE mediaItemTag.mediaItemID = ? \
            ORDER BY tag.sortOrder, tag.name
            """,
            arguments: [loserID])

        var result: [(Tag, TagCategory)] = []
        for tag in loserTags {
            guard !keeperTagIDs.contains(tag.id) else { continue }
            guard let category = try TagCategory.fetchOne(db, key: tag.tagCategoryID) else { continue }
            if !category.allowMultiple {
                // Keeper's existing pick wins; claim immediately so a second
                // loser tag in this category can't also pass.
                guard !keeperCategoryIDs.contains(category.id) else { continue }
                keeperCategoryIDs.insert(category.id)
            }
            result.append((tag, category))
        }
        return result
    }
}
