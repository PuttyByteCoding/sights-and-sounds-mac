import Foundation
import GRDB

/// Lifecycle of a job row. Terminal states are `succeeded`, `failed`,
/// `cancelled`.
public enum JobState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

/// One long-running operation, persisted in the library it works on.
///
/// The web app implemented this concept thirteen times — import, encode,
/// join, repair, clip export, block removal, move, OCR, optimize,
/// write-back, hash, fingerprint, thumbnails — as near-identical ~56-line
/// classes. Here it exists once; every later phase lands its operation as
/// a `Job` conformance and gets persistence, progress, failure capture and
/// cancellation for free.
///
/// Job rows live in the library file (not the app store) so a library
/// carries its own history and the tables can reference its rows.
public struct JobRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "job"

    public var id: UUID
    /// Which `Job` conformance runs this row (`Job.kind`).
    public var kind: String
    public var state: JobState
    /// Job-specific parameters, JSON-encoded by the conformance.
    public var payload: Data?
    public var error: String?
    public var progressCurrent: Int
    public var progressTotal: Int?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: String,
        payload: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.state = .queued
        self.payload = payload
        self.error = nil
        self.progressCurrent = 0
        self.progressTotal = nil
        self.createdAt = createdAt
        self.startedAt = nil
        self.finishedAt = nil
    }
}
