import Foundation
import GRDB

/// One step of looking at a file: what it declares, how its frames are
/// timed, what its picture measures, what its sound measures.
///
/// A stage reads one file and returns findings. It never touches the
/// library, so it can be run on a loose file in a test, and the job is the
/// only thing that knows about items, markers and failure rows.
public protocol SignalStage: Sendable {
    /// Stable name stored in `mediaSignalStage.stage`. Never rename a
    /// shipped stage: its rows outlive the code.
    var name: String { get }

    /// Raise this when the stage would now say something different about
    /// the same file. Items marked at an older version become missing
    /// again and the next sweep re-reads them.
    var version: Int { get }

    /// The kinds of item the stage has anything to say about.
    var kinds: Set<MediaKind> { get }

    func examine(_ file: SignalStageInput) async throws -> SignalFindings
}

public struct SignalStageInput: Sendable {
    public let url: URL
    public let kind: MediaKind
    /// Long stages ask this between frames and throw `CancellationError`.
    public let isCancelled: @Sendable () async -> Bool

    public init(
        url: URL, kind: MediaKind, isCancelled: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.url = url
        self.kind = kind
        self.isCancelled = isCancelled
    }

    public func checkCancellation() async throws {
        if await isCancelled() { throw CancellationError() }
    }
}

/// A stage could not say anything about this file, and why.
public struct SignalStageError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum SignalStages {
    /// Every shipped stage, in the order they run. Cheap ones first, so a
    /// stopped sweep has filled in the most items it could.
    public static let all: [any SignalStage] = [
        DeclaredStage(),
        FrameTimingStage(),
        ProbeToolsStage(),
        PictureStillsStage(),
    ]
}

/// One item and the stages it still needs.
public struct SignalWork: Equatable, Sendable {
    public var item: MediaItem
    public var stages: [String]
}

extension LibraryDatabase {
    /// Items with at least one stage missing at its current version, in
    /// path order, each with the stages it lacks. A failure row is a
    /// marker like any other: a broken file is not re-read until someone
    /// asks for a retry.
    ///
    /// Segments are ranges inside their parent's file, so the parent's
    /// findings are theirs and they are never examined separately.
    public func itemsNeedingSignalStages(
        _ stages: [any SignalStage] = SignalStages.all
    ) throws -> [SignalWork] {
        try writer.read { db in
            var lacking: [UUID: [String]] = [:]
            for stage in stages {
                let kinds = stage.kinds.map(\.rawValue)
                guard !kinds.isEmpty else { continue }
                let marks = Array(repeating: "?", count: kinds.count).joined(separator: ",")
                let ids = try UUID.fetchAll(
                    db,
                    sql: """
                    SELECT mediaItem.id FROM mediaItem \
                    WHERE mediaItem.parentMediaItemID IS NULL \
                    AND mediaItem.kind IN (\(marks)) \
                    AND NOT EXISTS (SELECT 1 FROM mediaSignalStage \
                                    WHERE mediaSignalStage.mediaItemID = mediaItem.id \
                                    AND mediaSignalStage.stage = ? \
                                    AND mediaSignalStage.version >= ?)
                    """,
                    arguments: StatementArguments(kinds) + [stage.name, stage.version])
                for id in ids { lacking[id, default: []].append(stage.name) }
            }
            guard !lacking.isEmpty else { return [] }
            let items = try MediaItem
                .filter(sql: "parentMediaItemID IS NULL")
                .order(sql: "relativePath")
                .fetchAll(db)
            return items.compactMap { item in
                lacking[item.id].map { SignalWork(item: item, stages: $0) }
            }
        }
    }

    // MARK: - The sweeps panel

    public func signalStatus(_ stages: [any SignalStage] = SignalStages.all) throws -> SweepStatus {
        let missing = try itemsNeedingSignalStages(stages).count
        let failed = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(DISTINCT mediaItemID) FROM mediaSignalStage \
                WHERE failureMessage IS NOT NULL
                """) ?? 0
        }
        return SweepStatus(missing: missing, failed: failed)
    }

    public func retrySignalFailures() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM mediaSignalStage WHERE failureMessage IS NOT NULL")
        }
    }

    /// Forget every finding. Evidence and inferences go with them: they
    /// are computed from these rows and mean nothing without them.
    public func resetSignalFindings() throws {
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM mediaSignalInference;
                DELETE FROM mediaSignalEvidence;
                DELETE FROM mediaSignalMeasurement;
                DELETE FROM mediaSignalDeclared;
                DELETE FROM mediaSignalStage;
                """)
        }
    }
}
