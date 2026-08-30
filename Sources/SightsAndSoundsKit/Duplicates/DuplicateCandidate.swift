import Foundation
import GRDB

public enum DuplicateStatus: String, Codable, Sendable, CaseIterable {
    /// Awaiting human review.
    case pending
    /// Reviewed and confirmed the same content.
    case confirmed
    /// Reviewed and judged NOT duplicates. Kept — never deleted — so the
    /// pair can't be re-flagged and re-reviewed later.
    case rejected
    /// Reviewed, agreed to be the same content, and **both copies are
    /// wanted**. A pro-shot and an audience capture of the same set match
    /// at 94% and are both worth having; the matcher does not know that.
    /// Distinct from `rejected`, which says the match was wrong.
    case keptBoth
}

/// How a pair got flagged.
public enum CandidateSource: String, Codable, Sendable, CaseIterable {
    case manual
    case fingerprint
    /// Identical content hashes — byte-for-byte the same file.
    case contentHash
}

public enum CandidateMatchKind: String, Codable, Sendable, CaseIterable {
    /// Near-full-length match of both files.
    case sameRecording
    /// The shorter file's audio appears inside the longer one.
    case containment
}

/// A "these two items might be the same content" pair. Scoped within one
/// library by construction; review is human, absolutely — nothing ever
/// auto-merges from a candidate.
///
/// The pair is stored in normalized order (A's id sorts before B's) so
/// the same pair can't exist twice in opposite orders — the unique index
/// then enforces one row per pair, and a rejected row permanently blocks
/// re-flagging.
public struct DuplicateCandidate: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "duplicateCandidate"

    public var id: UUID
    public private(set) var itemAID: UUID
    public private(set) var itemBID: UUID
    public var status: DuplicateStatus
    public var source: CandidateSource
    /// 0…1 similarity over the matched overlap (fingerprint pairs).
    public var confidence: Double?
    /// Where the shorter starts inside the longer (fingerprint pairs).
    public var offsetSeconds: Double?
    public var matchKind: CandidateMatchKind?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        itemA: UUID, itemB: UUID,
        source: CandidateSource,
        confidence: Double? = nil,
        offsetSeconds: Double? = nil,
        matchKind: CandidateMatchKind? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        // Normalized order, always.
        if itemA.uuidString <= itemB.uuidString {
            self.itemAID = itemA
            self.itemBID = itemB
        } else {
            self.itemAID = itemB
            self.itemBID = itemA
        }
        self.status = .pending
        self.source = source
        self.confidence = confidence
        self.offsetSeconds = offsetSeconds
        self.matchKind = matchKind
        self.createdAt = createdAt
    }
}

/// A cached audio fingerprint: one row per item, success only — failures
/// live in `fingerprintFailure` per the side-table convention.
public struct AudioFingerprintRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "audioFingerprint"

    public var mediaItemID: UUID
    /// Seconds of audio actually fingerprinted.
    public var durationSeconds: Double
    /// Packed little-endian Int32 sub-fingerprints.
    public var fingerprint: Data
    /// e.g. "fpcalc:1.5.1" — a tool change invalidates comparability.
    public var toolVersion: String
    public var computedAt: Date

    public init(
        mediaItemID: UUID, durationSeconds: Double, fingerprint: Data,
        toolVersion: String, computedAt: Date = Date()
    ) {
        self.mediaItemID = mediaItemID
        self.durationSeconds = durationSeconds
        self.fingerprint = fingerprint
        self.toolVersion = toolVersion
        self.computedAt = computedAt
    }

    public var unpacked: [Int32] {
        fingerprint.withUnsafeBytes { raw in
            raw.bindMemory(to: Int32.self).map { Int32(littleEndian: $0) }
        }
    }

    public static func pack(_ values: [Int32]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// Fingerprinting failed for this item; stops the sweep retrying every
/// signal. Cleared on manual retry.
public struct FingerprintFailure: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "fingerprintFailure"

    public var mediaItemID: UUID
    public var message: String
    public var occurredAt: Date

    public init(mediaItemID: UUID, message: String, occurredAt: Date = Date()) {
        self.mediaItemID = mediaItemID
        self.message = message
        self.occurredAt = occurredAt
    }
}
