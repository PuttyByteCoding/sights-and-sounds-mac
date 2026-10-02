import Foundation
import GRDB

/// Take items out of the library and leave their files where they are.
///
/// There is no un-import; this is the way out. The rows go — the item,
/// its segments (they describe a file the library no longer knows), and
/// by cascade its tags, field values, snapshots, readings and pairs — and
/// the file is not touched. Deletion staging is the other thing, for
/// files that should go too.
public struct RemovalOutcome: Equatable, Sendable {
    public var itemsRemoved = 0
    public var segmentsRemoved = 0
    public var failures: [String] = []
    public init() {}
}

/// A file taken out of the library on purpose. The file is still under
/// its source, so the next scan would list it as new; this row makes it
/// "removed" instead — shown, not ticked, and importable again, which
/// forgets the row.
public struct RemovedItem: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "removedItem"

    public var id: UUID
    public var sourceID: UUID
    public var relativePath: String
    public var fileName: String
    public var removedAt: Date

    public init(id: UUID = UUID(), sourceID: UUID, relativePath: String, fileName: String, removedAt: Date = Date()) {
        self.id = id
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.fileName = fileName
        self.removedAt = removedAt
    }

    /// Remember this item's path as removed — once per path, however the
    /// path is spelled.
    static func remember(_ item: MediaItem, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM removedItem WHERE sourceID = ? AND relativePath = ?",
            arguments: [item.sourceID, item.relativePath])
        try RemovedItem(sourceID: item.sourceID, relativePath: item.relativePath, fileName: item.fileName).insert(db)
    }

    /// The path is back in the library: nothing to remember.
    static func forget(sourceID: UUID, relativePath: String, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM removedItem WHERE sourceID = ? AND relativePath = ?",
            arguments: [sourceID, relativePath])
    }
}

extension LibraryDatabase {
    /// The removed paths of a source, folded for the NOCASE comparison the
    /// scan and the import make.
    public func removedPaths(in sourceID: UUID) throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT relativePath FROM removedItem WHERE sourceID = ?", arguments: [sourceID]
            ).map { $0.lowercased() })
        }
    }

    public func removedItems() throws -> [RemovedItem] {
        try writer.read { try RemovedItem.order(sql: "removedAt DESC").fetchAll($0) }
    }
}

extension LibraryDatabase {
    /// The segments of these items that are not saved as files of their
    /// own — what leaving the library would take with it. Unlike the
    /// delete list's question, the items need not be flagged.
    public func unsavedSegments(of itemIDs: [UUID]) throws -> [UnsavedSegments] {
        guard !itemIDs.isEmpty else { return [] }
        return try writer.read { db in
            let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT segment.id AS segmentID, parent.id AS parentID, parent.fileName AS fileName \
                FROM mediaItem segment \
                JOIN mediaItem parent ON parent.id = segment.parentMediaItemID \
                WHERE segment.clipExported = 0 AND parent.id IN (\(placeholders)) \
                ORDER BY parent.relativePath, segment.clipStartSeconds
                """,
                arguments: StatementArguments(itemIDs))
            var order: [UUID] = []
            var grouped: [UUID: (name: String, segments: [UUID])] = [:]
            for row in rows {
                let parentID: UUID = row["parentID"]
                if grouped[parentID] == nil {
                    order.append(parentID)
                    grouped[parentID] = (row["fileName"], [])
                }
                grouped[parentID]?.segments.append(row["segmentID"])
            }
            return order.map {
                UnsavedSegments(parentID: $0, parentFileName: grouped[$0]!.name, segmentIDs: grouped[$0]!.segments)
            }
        }
    }

    /// Remove these items' rows. Files are not touched. A segment passed
    /// on its own leaves alone; a show takes its segment rows with it (an
    /// exported segment's file is its own item and stays). One item's
    /// failure does not strand the rest.
    @discardableResult
    public func removeFromLibrary(itemIDs: [UUID]) throws -> RemovalOutcome {
        var outcome = RemovalOutcome()
        for itemID in itemIDs {
            do {
                let removed = try writer.write { db -> (item: Bool, segments: Int)? in
                    guard let item = try MediaItem.fetchOne(db, key: itemID) else { return nil }
                    var segments = 0
                    if item.parentMediaItemID == nil {
                        try db.execute(
                            sql: "DELETE FROM mediaItem WHERE parentMediaItemID = ?", arguments: [itemID])
                        segments = db.changesCount
                        // Its file stays under the source: remembered, so
                        // the next scan shows it as removed, not new.
                        try RemovedItem.remember(item, in: db)
                    }
                    return (try MediaItem.deleteOne(db, key: itemID), segments)
                }
                if let removed {
                    if removed.item { outcome.itemsRemoved += 1 }
                    outcome.segmentsRemoved += removed.segments
                }
            } catch {
                outcome.failures.append("\(itemID): \(error)")
            }
        }
        return outcome
    }
}

/// Remove items from the library, writing their tags into the files
/// first if asked — so what the library knew travels with the file it is
/// about to forget. An item whose tags could not be written (file
/// offline, tools missing, the write failed) is kept: removing it would
/// lose the tags for good, which is the one thing the question was for.
public struct RemoveFromLibraryJob: Job {
    public static let kind = "library.remove"

    public struct Payload: Codable, Sendable {
        public var itemIDs: [UUID]
        public var writeTagsFirst: Bool
        public init(itemIDs: [UUID], writeTagsFirst: Bool) {
            self.itemIDs = itemIDs
            self.writeTagsFirst = writeTagsFirst
        }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "library.remove: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    init(payload: Payload, fileAccess: any FileAccess) {
        self.payload = payload
        self.fileAccess = fileAccess
    }

    @discardableResult
    public static func enqueue(
        on runner: JobRunner, itemIDs: [UUID], writeTagsFirst: Bool
    ) async throws -> JobRecord {
        try await runner.enqueue(
            RemoveFromLibraryJob.self,
            payload: JSONEncoder().encode(Payload(itemIDs: itemIDs, writeTagsFirst: writeTagsFirst)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library
        var toRemove: [UUID] = []
        var kept: [String] = []
        var written = 0
        await context.reportProgress(current: 0, total: payload.itemIDs.count)

        if payload.writeTagsFirst {
            let toolsPresent = TagWriters.ffprobePath() != nil && FfmpegTool.path() != nil
            let mappings = try WritebackJob.mappings(in: library)
            var run = TagWriteRun(scopeDescription: "before removing from the library", totalFiles: payload.itemIDs.count)
            let initialRun = run
            try await library.writer.write { try initialRun.insert($0) }
            var failed = 0
            for (index, itemID) in payload.itemIDs.enumerated() {
                try await context.checkCancellation()
                guard let item = try await library.writer.read({ try MediaItem.fetchOne($0, key: itemID) })
                else { continue }
                // A segment has no tags of its own in the file; a show
                // does. Nothing to write means nothing to lose.
                if item.parentMediaItemID != nil {
                    toRemove.append(itemID)
                } else if !toolsPresent {
                    kept.append("\(item.fileName): \(FfmpegTool.installHint)")
                } else {
                    switch try await WritebackJob.writeTags(
                        of: item, mappings: mappings, runID: run.id, library: library, fileAccess: fileAccess
                    ) {
                    case .written:
                        written += 1
                        toRemove.append(itemID)
                    case .skipped("no write-back-enabled tags"):
                        toRemove.append(itemID)
                    case .skipped(let reason):
                        kept.append("\(item.fileName): \(reason), tags not written")
                    case .failed(let reason):
                        failed += 1
                        kept.append("\(item.fileName): \(reason ?? "write failed"), tags not written")
                    }
                }
                await context.reportProgress(current: index + 1, total: payload.itemIDs.count)
            }
            run.finishedAt = Date()
            run.writtenCount = written
            run.failedCount = failed
            let finalRun = run
            try await library.writer.write { try finalRun.update($0) }
        } else {
            toRemove = payload.itemIDs
        }

        try await context.checkCancellation()
        let outcome = try library.removeFromLibrary(itemIDs: toRemove)
        await context.reportProgress(current: payload.itemIDs.count, total: payload.itemIDs.count)

        var summary = "\(outcome.itemsRemoved) removed from the library, files kept"
        if outcome.segmentsRemoved > 0 { summary += " (\(outcome.segmentsRemoved) segments with them)" }
        if payload.writeTagsFirst { summary += " — tags written to \(written)" }
        if !kept.isEmpty {
            summary += " — \(kept.count) kept in the library: " + kept.joined(separator: "; ")
        }
        if !outcome.failures.isEmpty {
            summary += " — could not remove: " + outcome.failures.joined(separator: "; ")
        }
        await context.setSummary(summary)
    }
}
