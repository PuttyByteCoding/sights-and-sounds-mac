import CryptoKit
import Foundation
import GRDB

/// Hashes every item that doesn't have a content hash yet. One job sweeps
/// the whole library: per-item failures are recorded beside the feature
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

    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        fileAccess = LiveFileAccess()
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library

        // Work is decided per run: unhashed items, no prior failure row,
        // on enabled sources that are reachable right now.
        let sources = try await library.writer.read { db in
            Dictionary(uniqueKeysWithValues: try Source.fetchAll(db).map { ($0.id, $0) })
        }
        let onlineSources = Set(
            sources.values
                .filter { $0.enabled && $0.isOnline(using: fileAccess) }
                .map(\.id))

        let pending = try await library.writer.read { db in
            try MediaItem.fetchAll(
                db,
                sql: """
                SELECT mediaItem.* FROM mediaItem \
                WHERE mediaItem.contentHash IS NULL \
                AND NOT EXISTS (SELECT 1 FROM contentHashFailure \
                                WHERE contentHashFailure.mediaItemID = mediaItem.id) \
                ORDER BY mediaItem.relativePath
                """)
        }.filter { onlineSources.contains($0.sourceID) }

        var hashed = 0
        var failed = 0
        await context.reportProgress(current: 0, total: pending.count)

        for (index, item) in pending.enumerated() {
            try await context.checkCancellation()
            guard let source = sources[item.sourceID] else { continue }
            let url = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                .appendingPathComponent(item.relativePath)

            do {
                var hasher = Insecure.MD5()
                try fileAccess.readFile(at: url) { chunk in
                    hasher.update(data: chunk)
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                try await library.writer.write { db in
                    try db.execute(
                        sql: "UPDATE mediaItem SET contentHash = ? WHERE id = ?",
                        arguments: [digest, item.id])
                }
                hashed += 1
            } catch {
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
