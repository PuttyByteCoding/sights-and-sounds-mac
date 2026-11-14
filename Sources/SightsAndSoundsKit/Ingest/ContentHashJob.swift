import CryptoKit
import Foundation
import GRDB

/// Hashes every item that doesn't have a content hash yet — the whole
/// library, or only the items an import brought in, which each import
/// queues as a job of its own. Per-item failures are recorded beside the feature
/// (`contentHashFailure`) and the sweep continues — a broken file never
/// stalls the queue, and the failure row stops the worker from retrying
/// the same file every signal (cleared on manual retry).
///
/// The algorithm is MD5 — deliberately, for identity not security: the
/// migrated library carries the old app's hashes, and same-bytes must mean
/// same-hash across the migration boundary. The column stays named for the
/// role (`contentHash`) so changing algorithms later is a data migration,
/// not a rename.
public struct ContentHashJob: Job {
    public static let kind = "contentHash.sweep"

    struct Payload: Codable {
        var itemIDs: [UUID]
    }

    let fileAccess: any FileAccess
    /// Nil sweeps the whole library.
    let itemIDs: Set<UUID>?

    public init(payload: Data?) throws {
        fileAccess = LiveFileAccess()
        itemIDs = try payload.map { Set(try JSONDecoder().decode(Payload.self, from: $0).itemIDs) }
    }

    init(fileAccess: any FileAccess, itemIDs: Set<UUID>? = nil) {
        self.fileAccess = fileAccess
        self.itemIDs = itemIDs
    }

    /// A hash job for these items only: what an import brought in.
    static func enqueue(in context: JobContext, itemIDs: [UUID]) async throws {
        try await context.enqueue(
            ContentHashJob.self, payload: JSONEncoder().encode(Payload(itemIDs: itemIDs)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library

        // Work is decided per run: unhashed files (a segment has no bytes
        // of its own — hashing it would hash its parent again), no prior
        // failure row, on enabled sources that are reachable right now.
        let sources = try await library.read { db in
            Dictionary(uniqueKeysWithValues: try Source.fetchAll(db).map { ($0.id, $0) })
        }
        let onlineSources = Set(
            sources.values
                .filter { $0.enabled && $0.isOnline(using: fileAccess) }
                .map(\.id))

        let pending = try await library.read { db in
            try MediaItem.fetchAll(
                db,
                sql: """
                SELECT mediaItem.* FROM mediaItem \
                WHERE mediaItem.contentHash IS NULL \
                AND mediaItem.parentMediaItemID IS NULL \
                AND NOT EXISTS (SELECT 1 FROM contentHashFailure \
                                WHERE contentHashFailure.mediaItemID = mediaItem.id) \
                ORDER BY mediaItem.relativePath
                """)
        }.filter { onlineSources.contains($0.sourceID) && itemIDs?.contains($0.id) != false }

        var hashed = 0
        var failed = 0
        var lostSources: Set<UUID> = []
        await context.reportProgress(current: 0, total: pending.count)

        for (index, item) in pending.enumerated() {
            try await context.checkCancellation()
            try await context.stepAsideIfAnImportIsWaiting()
            guard let source = sources[item.sourceID], !lostSources.contains(source.id) else { continue }
            let url = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                .appendingPathComponent(item.relativePath)

            do {
                // A whole file, read on a thread of its own: see Blocking.
                let digest = try await Blocking.run { [fileAccess] in
                    var hasher = Insecure.MD5()
                    try fileAccess.readFile(at: url) { chunk in
                        hasher.update(data: chunk)
                    }
                    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
                }
                try await library.writer.write { db in
                    try db.execute(
                        sql: "UPDATE mediaItem SET contentHash = ? WHERE id = ?",
                        arguments: [digest, item.id])
                }
                hashed += 1
            } catch {
                switch try await library.sweepMiss(for: item, source: source, fileAccess: fileAccess) {
                case .sourceGone: lostSources.insert(source.id); continue
                case .fileMoved: continue
                case .fileFailed: break
                }
                try await library.writer.write { db in
                    try ContentHashFailure(
                        mediaItemID: item.id, message: "\(error)").insert(db)
                }
                failed += 1
            }
            await context.reportProgress(current: index + 1, total: pending.count)
        }
        await context.setSummary(
            failed == 0 ? "\(hashed) hashed" : "\(hashed) hashed, \(failed) failed")
    }
}
