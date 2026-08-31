import Foundation
import GRDB

/// Reads every item's embedded metadata into `embeddedMetadataPair`, the
/// candidate queue's largest source.
///
/// Nothing persisted these before. The tag writers already flatten
/// ffprobe's dictionaries — `TagWriters.readTagsJSON` then `tagPairs` —
/// but only ever for a snapshot about to be overwritten, so the pairs were
/// read and discarded on every write. This job reuses exactly that pair of
/// calls: one flattening, so a candidate mined here and a snapshot written
/// upstream can never disagree about what a file's tags are.
///
/// Sweep state is a separate table from the pairs because **an item whose
/// file carries no metadata leaves no pairs behind**, and without a marker
/// such an item is re-probed on every run forever. The marker also carries
/// the failure message, so a broken file reports rather than silently
/// vanishing — and a retry is a row deletion, matching `contentHashFailure`.
public struct MetadataSweepJob: Job {
    public static let kind = "tagAnalysis.metadataSweep"

    /// A scoped run: only these items, for a Tag Analysis window opened
    /// on one video or on the current queue — the operator is looking at
    /// those items NOW, and a library-wide sweep gets to them when it
    /// gets to them. Nil is the ordinary whole-library sweep.
    public struct Payload: Codable, Sendable {
        public var itemIDs: [UUID]
        public init(itemIDs: [UUID]) { self.itemIDs = itemIDs }
    }

    let fileAccess: any FileAccess
    let scope: Set<UUID>?

    public init(payload: Data?) throws {
        fileAccess = LiveFileAccess()
        scope = payload.flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
            .map { Set($0.itemIDs) }
    }

    /// Enqueue a scoped sweep. Plain `enqueue`, not `enqueueUnlessPending`
    /// — dedupe is by kind, and a pending LIBRARY sweep must not swallow
    /// a scoped one the operator is waiting on.
    @discardableResult
    public static func enqueue(on runner: JobRunner, itemIDs: [UUID]) async throws -> JobRecord {
        try await runner.enqueue(
            MetadataSweepJob.self,
            payload: try JSONEncoder().encode(Payload(itemIDs: itemIDs)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library

        // Work is decided per run, matching ContentHashJob: unswept items
        // on enabled sources that are reachable right now. An offline
        // source must leave no marker at all — a marker would mean "swept,
        // nothing found" and the item would never be revisited once the
        // drive came back.
        let sources = try await library.writer.read { db in
            Dictionary(uniqueKeysWithValues: try Source.fetchAll(db).map { ($0.id, $0) })
        }
        let onlineSources = Set(
            sources.values
                .filter { $0.enabled && $0.isOnline(using: fileAccess) }
                .map(\.id))

        let pending = try library.itemsNeedingMetadataSweep(limit: Int.max)
            .filter { onlineSources.contains($0.sourceID) }
            .filter { scope?.contains($0.id) ?? true }

        var swept = 0
        var failed = 0
        var pairsFound = 0
        await context.reportProgress(current: 0, total: pending.count)

        for (index, item) in pending.enumerated() {
            try await context.checkCancellation()
            guard let source = sources[item.sourceID] else { continue }
            let url = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                .appendingPathComponent(item.relativePath)

            do {
                let json = try TagWriters.readTagsJSON(url: url)
                let pairs = TagWriters.tagPairs(fromSnapshotJSON: json)
                try library.recordMetadataPairs(itemID: item.id, pairs: pairs)
                pairsFound += pairs.count
                swept += 1
            } catch {
                // The marker still goes down, carrying the reason: a file
                // ffprobe cannot read must not be retried every run.
                try library.recordMetadataPairs(
                    itemID: item.id, pairs: [], failure: "\(error)")
                failed += 1
            }
            await context.reportProgress(current: index + 1, total: pending.count)
        }

        await context.setSummary(
            failed == 0
                ? "\(swept) items, \(pairsFound) pairs"
                : "\(swept) items, \(pairsFound) pairs, \(failed) failed")
    }
}
