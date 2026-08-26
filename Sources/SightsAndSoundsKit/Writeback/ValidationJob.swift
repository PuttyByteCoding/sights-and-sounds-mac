import Foundation
import GRDB

public enum ValidationFindingKind: String, Codable, Sendable, CaseIterable {
    /// A row whose file is gone from disk.
    case missingFile
    /// A media file on disk with no row.
    case orphanFile
    /// Row and disk disagree about the file's size.
    case sizeMismatch
}

/// One validation finding. The table holds the LATEST run only — findings
/// are observations, recomputed cheaply, not history.
public struct ValidationFinding: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "validationFinding"

    public var id: UUID
    public var kind: ValidationFindingKind
    public var mediaItemID: UUID?
    public var path: String
    public var detail: String

    public init(
        id: UUID = UUID(), kind: ValidationFindingKind,
        mediaItemID: UUID? = nil, path: String, detail: String
    ) {
        self.id = id
        self.kind = kind
        self.mediaItemID = mediaItemID
        self.path = path
        self.detail = detail
    }
}

/// Compare the database against the disk, per online source: rows whose
/// files vanished, files with no rows, size disagreements. Offline
/// sources are skipped whole — absence of a drive is not absence of
/// files. Findings replace the previous run's.
public struct ValidationJob: Job {
    public static let kind = "validation.sweep"

    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        fileAccess = LiveFileAccess()
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library
        let sources = try await library.writer.read { db -> [Source] in
            try Source.fetchAll(db)
        }
        let online = sources.filter { $0.enabled && $0.isOnline(using: fileAccess) }

        try await library.writer.write { db in
            try db.execute(sql: "DELETE FROM validationFinding")
        }

        var findings: [ValidationFinding] = []
        var checkedItems = 0

        for source in online {
            try await context.checkCancellation()
            let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
            let sourceIDValue = source.id

            let items = try await library.writer.read { db -> [MediaItem] in
                try MediaItem.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM mediaItem WHERE sourceID = ? AND parentMediaItemID IS NULL
                    """,
                    arguments: [sourceIDValue])
            }
            checkedItems += items.count

            // Rows → disk.
            var knownPaths = Set<String>()
            for item in items {
                knownPaths.insert(item.relativePath.lowercased())
                let url = root.appendingPathComponent(item.relativePath)
                guard fileAccess.isReachable(url) else {
                    findings.append(ValidationFinding(
                        kind: .missingFile, mediaItemID: item.id,
                        path: item.relativePath,
                        detail: "the row exists but the file is gone (source '\(source.name)')"))
                    continue
                }
                let diskSize = (try? fileAccess.fileSize(at: url)) ?? -1
                if diskSize >= 0, item.fileSize > 0, diskSize != item.fileSize {
                    findings.append(ValidationFinding(
                        kind: .sizeMismatch, mediaItemID: item.id,
                        path: item.relativePath,
                        detail: "row says \(item.fileSize) bytes, disk says \(diskSize)"))
                }
            }

            // Disk → rows (media extensions only).
            let rootPath = root.standardizedFileURL.path
            for url in (try? fileAccess.allFiles(under: root)) ?? [] {
                guard MediaProbe.kind(forExtension: url.pathExtension) != nil else { continue }
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(rootPath + "/") else { continue }
                let relative = MediaPath.normalize(String(full.dropFirst(rootPath.count + 1)))
                if !knownPaths.contains(relative.lowercased()) {
                    findings.append(ValidationFinding(
                        kind: .orphanFile,
                        path: relative,
                        detail: "on disk in '\(source.name)' but not in the library — import picks it up"))
                }
            }
        }

        let toInsert = findings
        try await library.writer.write { db in
            for finding in toInsert { try finding.insert(db) }
        }

        let skippedSources = sources.count - online.count
        var summary = findings.isEmpty
            ? "clean — \(checkedItems) items verified"
            : "\(findings.count) findings across \(checkedItems) items"
        if skippedSources > 0 { summary += " (\(skippedSources) offline sources skipped)" }
        await context.setSummary(summary)
    }
}

extension LibraryDatabase {
    public func validationFindings() throws -> [ValidationFinding] {
        try writer.read { db in
            try ValidationFinding.order(sql: "kind, path").fetchAll(db)
        }
    }

    /// Fix a size mismatch: trust the disk — refresh the size, clear the
    /// stale hash so the sweep recomputes.
    public func acceptDiskSize(for itemID: UUID, fileAccess: any FileAccess = LiveFileAccess()) throws {
        guard let item = try writer.read({ try MediaItem.fetchOne($0, key: itemID) }),
              let url = try resolvedFileURL(for: item, fileAccess: fileAccess)
        else { throw MoveError.itemNotFound }
        let diskSize = try fileAccess.fileSize(at: url)
        try writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET fileSize = ?, contentHash = NULL WHERE id = ?",
                arguments: [diskSize, itemID])
            try db.execute(
                sql: "DELETE FROM contentHashFailure WHERE mediaItemID = ?", arguments: [itemID])
            try db.execute(
                sql: "DELETE FROM validationFinding WHERE mediaItemID = ? AND kind = 'sizeMismatch'",
                arguments: [itemID])
        }
    }
}
