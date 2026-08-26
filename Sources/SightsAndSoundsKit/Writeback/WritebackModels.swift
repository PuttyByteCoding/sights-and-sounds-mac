import Foundation
import GRDB

public enum SnapshotSource: String, Codable, Sendable, CaseIterable {
    case preWrite
    case preRestore
    case importScan = "import"
}

/// Point-in-time capture of a file's embedded tags (ffprobe tag
/// dictionaries as JSON), taken before any write or restore — the user's
/// recovery path after wipe-and-rewrite.
public struct EmbeddedTagSnapshot: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "embeddedTagSnapshot"

    public var id: UUID
    public var mediaItemID: UUID
    public var capturedAt: Date
    public var source: SnapshotSource
    public var tagsJSON: String

    public init(
        id: UUID = UUID(), mediaItemID: UUID, capturedAt: Date = Date(),
        source: SnapshotSource, tagsJSON: String
    ) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.capturedAt = capturedAt
        self.source = source
        self.tagsJSON = tagsJSON
    }
}

public enum WriteRunFileStatus: String, Codable, Sendable, CaseIterable {
    case written
    case failed
    case skipped
}

/// One write-back run — the audit unit for operations that touched real
/// files.
public struct TagWriteRun: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tagWriteRun"

    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var scopeDescription: String
    public var totalFiles: Int
    public var writtenCount: Int
    public var failedCount: Int

    public init(
        id: UUID = UUID(), startedAt: Date = Date(), finishedAt: Date? = nil,
        scopeDescription: String, totalFiles: Int = 0, writtenCount: Int = 0, failedCount: Int = 0
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.scopeDescription = scopeDescription
        self.totalFiles = totalFiles
        self.writtenCount = writtenCount
        self.failedCount = failedCount
    }
}

/// Per-file outcome within a run. `mediaItemID` has no FK and the path is
/// denormalized — history survives moves and deletes (ported).
public struct TagWriteRunFile: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tagWriteRunFile"

    public var id: UUID
    public var tagWriteRunID: UUID
    public var mediaItemID: UUID
    public var filePath: String
    public var status: WriteRunFileStatus
    public var error: String?
    public var usedRemuxFallback: Bool

    public init(
        id: UUID = UUID(), tagWriteRunID: UUID, mediaItemID: UUID, filePath: String,
        status: WriteRunFileStatus, error: String? = nil, usedRemuxFallback: Bool = false
    ) {
        self.id = id
        self.tagWriteRunID = tagWriteRunID
        self.mediaItemID = mediaItemID
        self.filePath = filePath
        self.status = status
        self.error = error
        self.usedRemuxFallback = usedRemuxFallback
    }
}
