import Foundation
import GRDB

/// Per-feature state tables. Each holds state exactly one feature reads,
/// keyed by media item — the answer to the old app's 48-column core
/// entity. A missing row is the normal case ("nothing to report"), which
/// also means disk-state self-healing (Phase 5 workers) never fights a
/// stale flag.

/// Content hashing failed for this item; stops the worker retrying every
/// scan. Cleared (row deleted) on manual retry.
public struct ContentHashFailure: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "contentHashFailure"

    public var mediaItemID: UUID
    /// Exception message, "timed out", or "skipped by user".
    public var message: String
    public var occurredAt: Date

    public init(mediaItemID: UUID, message: String, occurredAt: Date = Date()) {
        self.mediaItemID = mediaItemID
        self.message = message
        self.occurredAt = occurredAt
    }
}

/// Thumbnail generation outcome for this item. Disk remains the source of
/// truth for *whether* thumbnails exist; this row lets progress surfaces
/// avoid per-row disk checks and carries the failure message.
public struct ThumbnailState: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "thumbnailState"

    public var mediaItemID: UUID
    public var generated: Bool
    public var failureMessage: String?
    public var updatedAt: Date

    public init(mediaItemID: UUID, generated: Bool, failureMessage: String? = nil, updatedAt: Date = Date()) {
        self.mediaItemID = mediaItemID
        self.generated = generated
        self.failureMessage = failureMessage
        self.updatedAt = updatedAt
    }
}

/// How far a resumable full-item OCR scan has reached. Tracked separately
/// from recognized text because frames with no text leave no other trace,
/// yet the scan still advanced past them.
public struct OcrProgress: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ocrProgress"

    public var mediaItemID: UUID
    public var scannedThroughSeconds: Double

    public init(mediaItemID: UUID, scannedThroughSeconds: Double) {
        self.mediaItemID = mediaItemID
        self.scannedThroughSeconds = scannedThroughSeconds
    }
}
