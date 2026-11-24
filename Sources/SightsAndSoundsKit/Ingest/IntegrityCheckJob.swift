import Foundation
import GRDB

/// The last integrity check of one item: its file hashed again and
/// compared with the hash stored when it was first hashed. One row per
/// item. A row that matched is "verified"; one that did not, or whose file
/// could not be read, is a failure, and stays one until checked again.
public struct IntegrityCheck: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "integrityCheck"

    public var mediaItemID: UUID
    public var checkedAt: Date
    public var matched: Bool
    /// What the file hashes to now, when it was read and differs.
    public var actualHash: String?
    /// Why it failed, in words.
    public var message: String?

    public init(
        mediaItemID: UUID, checkedAt: Date = Date(), matched: Bool,
        actualHash: String? = nil, message: String? = nil
    ) {
        self.mediaItemID = mediaItemID
        self.checkedAt = checkedAt
        self.matched = matched
        self.actualHash = actualHash
        self.message = message
    }
}

/// Verify Integrity: every file with a stored content hash and no check
/// yet is read end to end and hashed again. Same hash, it is verified;
/// a different one means its bytes changed since they were hashed —
/// bit rot, a bad copy, an edit made outside the app — and it is reported,
/// never fixed. The stored hash is left as it was: it is the reference.
///
/// Like every sweep it fills what is missing: Verify checks the files
/// never checked, Retry Failed checks the failures again, and Recalculate
/// All forgets every check so the whole library is read again — the run
/// to make after a drive is copied or restored.
///
/// A file this app rewrote (a repair, a tag write) has its hash and its
/// check forgotten with it (`forgetReadingsOfChangedFile`), so a change
/// the app made is never reported as damage.
public struct IntegrityCheckJob: Job {
    public static let kind = "contentHash.verify"

    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        fileAccess = LiveFileAccess()
    }

    init(fileAccess: any FileAccess) {
        self.fileAccess = fileAccess
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library
        let sources = try await library.read { db in
            Dictionary(uniqueKeysWithValues: try Source.fetchAll(db).map { ($0.id, $0) })
        }
        let onlineSources = Set(
            sources.values
                .filter { $0.enabled && $0.isOnline(using: fileAccess) }
                .map(\.id))

        // Files only: a segment's hash, if it ever had one, is its parent's.
        let pending = try await library.read { db in
            try MediaItem.fetchAll(
                db,
                sql: """
                SELECT mediaItem.* FROM mediaItem \
                WHERE mediaItem.contentHash IS NOT NULL \
                AND mediaItem.parentMediaItemID IS NULL \
                AND NOT EXISTS (SELECT 1 FROM integrityCheck \
                                WHERE integrityCheck.mediaItemID = mediaItem.id) \
                ORDER BY mediaItem.relativePath
                """)
        }.filter { onlineSources.contains($0.sourceID) }

        var verified = 0
        var changed: [String] = []
        var unreadable = 0
        var lostSources: Set<UUID> = []
        await context.reportProgress(current: 0, total: pending.count)

        for (index, item) in pending.enumerated() {
            try await context.checkCancellation()
            try await context.stepAsideIfAnImportIsWaiting()
            guard let expected = item.contentHash,
                  let source = sources[item.sourceID], !lostSources.contains(source.id)
            else { continue }
            let url = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                .appendingPathComponent(item.relativePath)

            let check: IntegrityCheck
            do {
                let actual = try await ContentHashJob.md5(of: url, fileAccess: fileAccess)
                if actual == expected {
                    check = IntegrityCheck(mediaItemID: item.id, matched: true)
                    verified += 1
                } else {
                    check = IntegrityCheck(
                        mediaItemID: item.id, matched: false, actualHash: actual,
                        message: "contents changed since the file was hashed")
                    changed.append(item.relativePath)
                    AppLog.shared.warning(
                        "integrity",
                        "\(source.name)/\(item.relativePath): hash \(actual) differs from stored \(expected)")
                }
            } catch {
                // A drive gone or a file moved is not damage: try again
                // next run. A file that is there and cannot be read is.
                switch try await library.sweepMiss(for: item, source: source, fileAccess: fileAccess) {
                case .sourceGone: lostSources.insert(source.id); continue
                case .fileMoved: continue
                case .fileFailed: break
                }
                check = IntegrityCheck(mediaItemID: item.id, matched: false, message: "\(error)")
                unreadable += 1
                AppLog.shared.warning("integrity", "\(source.name)/\(item.relativePath): could not be read — \(error)")
            }
            try await library.writer.write { db in try check.save(db) }
            await context.reportProgress(current: index + 1, total: pending.count)
        }

        var parts = ["\(verified) verified"]
        if !changed.isEmpty {
            let named = changed.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            parts.append("\(changed.count) changed (\(named)\(changed.count > 3 ? ", …" : ""))")
        }
        if unreadable > 0 { parts.append("\(unreadable) unreadable") }
        await context.setSummary(parts.joined(separator: ", "))
    }
}

extension LibraryDatabase {
    /// Missing: files with a stored hash never checked. Failed: checks
    /// that did not match, or could not read the file.
    public func integrityStatus() throws -> SweepStatus {
        try writer.read { db in
            SweepStatus(
                missing: try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM mediaItem \
                    WHERE contentHash IS NOT NULL AND parentMediaItemID IS NULL \
                    AND NOT EXISTS (SELECT 1 FROM integrityCheck \
                                    WHERE integrityCheck.mediaItemID = mediaItem.id)
                    """) ?? 0,
                failed: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM integrityCheck WHERE matched = 0") ?? 0)
        }
    }

    /// Check the failures again.
    public func retryIntegrityFailures() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM integrityCheck WHERE matched = 0")
        }
    }

    /// Forget every check, so the next run reads every hashed file.
    public func resetIntegrityChecks() throws {
        _ = try writer.write { db in
            try IntegrityCheck.deleteAll(db)
        }
    }

    /// The items whose last check failed, by path: what changed, and what
    /// could not be read.
    public func integrityFailures() throws -> [(item: MediaItem, check: IntegrityCheck)] {
        try writer.read { db in
            let checks = try IntegrityCheck.filter(sql: "matched = 0").fetchAll(db)
            let items = Dictionary(
                uniqueKeysWithValues: try MediaItem.fetchAll(db, keys: checks.map(\.mediaItemID)).map { ($0.id, $0) })
            return checks.compactMap { check in items[check.mediaItemID].map { ($0, check) } }
                .sorted { $0.item.relativePath < $1.item.relativePath }
        }
    }
}
