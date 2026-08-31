import Foundation
import GRDB

/// One embedded-metadata pair read off a file.
///
/// The candidate queue's largest source, and nothing persisted these
/// before: the tag writers already flatten ffprobe's dictionaries, but
/// only ever for a snapshot about to be overwritten.
public struct EmbeddedMetadataPair: Codable, Equatable, Sendable, FetchableRecord,
    PersistableRecord
{
    public static let databaseTableName = "embeddedMetadataPair"

    public var id: Int64?
    public var mediaItemID: UUID
    public var key: String
    public var value: String

    public init(id: Int64? = nil, mediaItemID: UUID, key: String, value: String) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.key = key
        self.value = value
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Where a candidate string came from.
///
/// `TagCandidateSource` rather than the shorter name: duplicate detection
/// already owns that name for where a duplicate PAIR came from, and two
/// unrelated meanings under one name in one module is how a wrong import
/// compiles.
///
/// Three sources, one queue — spec 14
/// §1: they all arrive as the same shape, a string appearing in N items
/// with no tag behind it, so triaging them together means one surface and
/// one rule engine rather than three half-features.
public enum TagCandidateSource: String, Codable, Sendable, CaseIterable {
    case metadata, onScreen, path

    public var displayName: String {
        switch self {
        case .metadata: "Metadata"
        case .onScreen: "On-screen"
        case .path: "File path"
        }
    }
}

/// What was decided about a candidate, so the queue does not offer it
/// again.
///
/// Keyed by (source, key, value) rather than by a row id because **the
/// queue is derived** — recomputed from the underlying data every time —
/// so a decision has to survive the disappearance of the row that
/// prompted it.
public struct TagCandidateDecision: Codable, Equatable, Sendable, FetchableRecord,
    PersistableRecord
{
    public static let databaseTableName = "tagCandidateDecision"

    public enum Decision: String, Codable, Sendable {
        case ignored, accepted
    }

    public var id: Int64?
    public var source: TagCandidateSource
    public var key: String?
    public var value: String
    public var decision: Decision
    public var decidedAt: Date

    public init(
        id: Int64? = nil, source: TagCandidateSource, key: String?, value: String,
        decision: Decision, decidedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.key = key
        self.value = value
        self.decision = decision
        self.decidedAt = decidedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A string appearing in N items with no tag behind it, plus what the
/// rules propose doing with it.
public struct TagCandidate: Equatable, Sendable, Identifiable {
    public let source: TagCandidateSource
    public let key: String?
    public let value: String
    public let itemCount: Int
    /// The category a rule assigns, when one does.
    public let suggestedCategory: String?
    /// Non-nil when a rule would drop this. It is shown rather than
    /// removed: a mis-authored ignore rule must be diagnosable, not
    /// invisible.
    public let suppressedByRule: String?
    /// A rule already covers this string — spec 14 §4's "make a rule from
    /// this" opens that rule instead of adding a rival.
    public let coveredByRuleID: UUID?

    /// Stable across recomputation, because the queue is derived and a
    /// selection must survive a refresh.
    public var id: String { "\(source.rawValue)|\(key ?? "")|\(value)" }
}
