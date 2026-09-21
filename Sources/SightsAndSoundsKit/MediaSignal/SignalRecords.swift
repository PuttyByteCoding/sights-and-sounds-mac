import Foundation
import GRDB

/// Something the container or the bitstream says about the file.
///
/// True as a statement about *this encode*, and nothing more: a file that
/// has been through a transcoder declares the transcoder's output. Values
/// are text because they are read, shown and compared, never computed on.
public struct SignalDeclared: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mediaSignalDeclared"

    public var mediaItemID: UUID
    public var key: String
    public var value: String
    /// The stage that read it, so a stage's re-run replaces only its own.
    public var stage: String

    public init(mediaItemID: UUID, key: String, value: String, stage: String) {
        self.mediaItemID = mediaItemID
        self.key = key
        self.value = value
        self.stage = stage
    }
}

/// Something decoding the media showed.
public struct SignalMeasurement: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mediaSignalMeasurement"

    /// What one number covers. A per-frame measurement depends on what was
    /// in front of the camera at that instant, so the frames are kept and
    /// the summaries are rows of their own.
    public enum Scope: String, Codable, Sendable {
        /// One value for the whole file.
        case file
        /// The middle of the sampled values: what the file usually does.
        case median
        /// The ninetieth percentile: the best (or worst) it can do.
        case high
        /// One sampled frame, at `positionSeconds`.
        case frame
        /// One decoded sequence, starting at `positionSeconds`.
        case window
    }

    public var id: Int64?
    public var mediaItemID: UUID
    public var stage: String
    public var key: String
    public var scope: Scope
    public var positionSeconds: Double?
    public var value: Double

    public init(
        mediaItemID: UUID, stage: String, key: String, scope: Scope = .file,
        positionSeconds: Double? = nil, value: Double
    ) {
        self.mediaItemID = mediaItemID
        self.stage = stage
        self.key = key
        self.scope = scope
        self.positionSeconds = positionSeconds
        self.value = value
    }
}

/// The sweep marker: this stage, at this version, has looked at this item.
public struct SignalStageState: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mediaSignalStage"

    public var mediaItemID: UUID
    public var stage: String
    public var version: Int
    public var completedAt: Date
    /// Kept so a broken file reports rather than being retried every run;
    /// a retry is a row deletion, as for every other sweep.
    public var failureMessage: String?

    public init(
        mediaItemID: UUID, stage: String, version: Int, completedAt: Date = Date(),
        failureMessage: String? = nil
    ) {
        self.mediaItemID = mediaItemID
        self.stage = stage
        self.version = version
        self.completedAt = completedAt
        self.failureMessage = failureMessage
    }
}

/// What one stage found in one file, before it has an item to belong to.
public struct SignalFindings: Equatable, Sendable {
    public struct Measured: Equatable, Sendable {
        public var key: String
        public var scope: SignalMeasurement.Scope
        public var positionSeconds: Double?
        public var value: Double

        public init(
            _ key: String, _ value: Double, scope: SignalMeasurement.Scope = .file,
            at positionSeconds: Double? = nil
        ) {
            self.key = key
            self.scope = scope
            self.positionSeconds = positionSeconds
            self.value = value
        }
    }

    public var declared: [String: String] = [:]
    public var measured: [Measured] = []

    public init() {}

    /// Record a declared value, skipping what the file does not say. An
    /// absent tag is itself a finding, and an empty string would hide it.
    public mutating func declare(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        declared[key] = value
    }

    public mutating func measure(_ key: String, _ value: Double?) {
        guard let value, value.isFinite else { return }
        measured.append(Measured(key, value))
    }

    /// The first value for `key` at `scope`.
    public func value(_ key: String, _ scope: SignalMeasurement.Scope = .file) -> Double? {
        measured.first { $0.key == key && $0.scope == scope }?.value
    }

    public mutating func merge(_ other: SignalFindings) {
        declared.merge(other.declared) { _, new in new }
        measured += other.measured
    }
}

extension LibraryDatabase {
    /// Replace everything `stage` previously recorded for the item and mark
    /// the stage done, in one transaction: a reader never sees half a
    /// stage, and a re-run leaves no rows behind from the run before.
    public func recordSignalStage(
        itemID: UUID, stage: String, version: Int, findings: SignalFindings,
        failure: String? = nil
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM mediaSignalDeclared WHERE mediaItemID = ? AND stage = ?",
                arguments: [itemID, stage])
            try db.execute(
                sql: "DELETE FROM mediaSignalMeasurement WHERE mediaItemID = ? AND stage = ?",
                arguments: [itemID, stage])
            for (key, value) in findings.declared {
                // Two stages may read the same fact from different tools.
                // The first to say it keeps it; the supplementary tools
                // use their own key prefix, so this only guards re-runs.
                try SignalDeclared(mediaItemID: itemID, key: key, value: value, stage: stage)
                    .upsert(db)
            }
            for measured in findings.measured {
                try SignalMeasurement(
                    mediaItemID: itemID, stage: stage, key: measured.key, scope: measured.scope,
                    positionSeconds: measured.positionSeconds, value: measured.value
                ).insert(db)
            }
            try SignalStageState(
                mediaItemID: itemID, stage: stage, version: version, failureMessage: failure
            ).upsert(db)
        }
    }

    /// Remove a stage's marker and rows, as if it had never looked.
    public func forgetSignalStage(itemID: UUID, stage: String) throws {
        try writer.write { db in
            for table in ["mediaSignalDeclared", "mediaSignalMeasurement", "mediaSignalStage"] {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE mediaItemID = ? AND stage = ?", arguments: [itemID, stage])
            }
        }
    }

    public func signalDeclared(itemID: UUID) throws -> [String: String] {
        try writer.read { db in
            let rows = try SignalDeclared
                .filter(sql: "mediaItemID = ?", arguments: [itemID]).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
        }
    }

    public func signalMeasurements(itemID: UUID) throws -> [SignalMeasurement] {
        try writer.read { db in
            try SignalMeasurement
                .filter(sql: "mediaItemID = ?", arguments: [itemID])
                .order(sql: "key, scope, positionSeconds")
                .fetchAll(db)
        }
    }

    public func signalStageStates(itemID: UUID) throws -> [SignalStageState] {
        try writer.read { db in
            try SignalStageState
                .filter(sql: "mediaItemID = ?", arguments: [itemID])
                .order(sql: "stage").fetchAll(db)
        }
    }
}
