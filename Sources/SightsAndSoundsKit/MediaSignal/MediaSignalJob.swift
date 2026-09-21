import Foundation
import GRDB

/// Runs every signal stage an item still lacks: what the file declares,
/// how its frames are timed, and (as later stages arrive) what its picture
/// and sound measure.
///
/// Like every sweep it fills in what is missing and nothing else. Each
/// stage is recorded as it finishes, so stopping the job loses the stage
/// in flight and no more; a stage that fails leaves a marker carrying the
/// reason, so a file that cannot be read is reported once rather than
/// re-read on every run.
public struct MediaSignalJob: Job {
    public static let kind = "mediaSignal.sweep"

    /// A scoped run, for a window looking at particular items now.
    public struct Payload: Codable, Sendable {
        public var itemIDs: [UUID]
        public init(itemIDs: [UUID]) { self.itemIDs = itemIDs }
    }

    let fileAccess: any FileAccess
    let stages: [any SignalStage]
    let scope: Set<UUID>?

    public init(payload: Data?) throws {
        fileAccess = LiveFileAccess()
        stages = SignalStages.all
        scope = payload.flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
            .map { Set($0.itemIDs) }
    }

    init(stages: [any SignalStage], scope: Set<UUID>? = nil, fileAccess: any FileAccess = LiveFileAccess()) {
        self.fileAccess = fileAccess
        self.stages = stages
        self.scope = scope
    }

    @discardableResult
    public static func enqueue(on runner: JobRunner, itemIDs: [UUID]) async throws -> JobRecord {
        try await runner.enqueue(
            MediaSignalJob.self, payload: try JSONEncoder().encode(Payload(itemIDs: itemIDs)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library

        // Only sources reachable right now. An offline drive must leave no
        // marker: a marker means "looked, and this is what was there".
        let sources = try await library.writer.read { db in
            Dictionary(uniqueKeysWithValues: try Source.fetchAll(db).map { ($0.id, $0) })
        }
        let online = Set(
            sources.values.filter { $0.enabled && $0.isOnline(using: fileAccess) }.map(\.id))

        let work = try library.itemsNeedingSignalStages(stages)
            .filter { online.contains($0.item.sourceID) }
            .filter { scope?.contains($0.item.id) ?? true }
        let byName = Dictionary(uniqueKeysWithValues: stages.map { ($0.name, $0) })

        var examined = 0
        var failedItems = 0
        await context.reportProgress(current: 0, total: work.count)

        for (index, entry) in work.enumerated() {
            try await context.checkCancellation()
            guard let source = sources[entry.item.sourceID] else { continue }
            let url = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                .appendingPathComponent(entry.item.relativePath)
            let input = SignalStageInput(url: url, kind: entry.item.kind) {
                await context.isCancelled
            }

            var failed = false
            for stageName in entry.stages {
                guard let stage = byName[stageName] else { continue }
                do {
                    let findings = try await stage.examine(input)
                    try library.recordSignalStage(
                        itemID: entry.item.id, stage: stage.name, version: stage.version,
                        findings: findings)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try library.recordSignalStage(
                        itemID: entry.item.id, stage: stage.name, version: stage.version,
                        findings: SignalFindings(), failure: "\(error)")
                    failed = true
                }
                try await context.checkCancellation()
            }
            examined += 1
            if failed { failedItems += 1 }
            await context.reportProgress(current: index + 1, total: work.count)
        }

        await context.setSummary(
            failedItems == 0
                ? "\(examined) items examined"
                : "\(examined) items examined, \(failedItems) with a stage that failed")
    }
}
