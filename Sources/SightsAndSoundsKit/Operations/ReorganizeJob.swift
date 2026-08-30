import Foundation
import GRDB

/// One item's reorganization plan — for the preview table.
public struct ReorganizePlanEntry: Sendable, Equatable {
    public let itemID: UUID
    public let fileName: String
    public let fromFolder: String
    /// nil = skipped; `reason` says why.
    public let toFolder: String?
    public let reason: String?
}

extension Array where Element == ReorganizePlanEntry {
    /// The shape of the result: which folders the plan creates, and how
    /// many items land in each.
    ///
    /// The row list answers "what happens to this file"; this answers
    /// "what will my drive look like", which is the question a template
    /// is being written to answer. Same plan, grouped — derived once,
    /// not recomputed per render.
    public var foldersCreated: [(folder: String, count: Int)] {
        Dictionary(grouping: compactMap(\.toFolder), by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
    }

    /// Skip reasons with their counts, so a template's weakness reads at
    /// a glance while the row list still shows every item.
    public var skipReasons: [(reason: String, count: Int)] {
        Dictionary(grouping: filter { $0.toFolder == nil }.map { $0.reason ?? "skipped" }, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    public var movableCount: Int { count { $0.toFolder != nil } }
}

extension LibraryDatabase {
    /// Dry-run: what a template would do to the given items. Pure — no
    /// file I/O — so the preview is free.
    public func previewReorganize(template: String, itemIDs: [UUID]) throws -> [ReorganizePlanEntry] {
        try writer.read { db in
            var entries: [ReorganizePlanEntry] = []
            for itemID in itemIDs {
                guard let item = try MediaItem.fetchOne(db, key: itemID),
                      item.parentMediaItemID == nil
                else { continue }
                let tags = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT tagCategory.name AS category, tag.name AS tag FROM tag \
                    JOIN tagCategory ON tagCategory.id = tag.tagCategoryID \
                    JOIN mediaItemTag ON mediaItemTag.tagID = tag.id \
                    WHERE mediaItemTag.mediaItemID = ?
                    """,
                    arguments: [itemID])
                var byCategory: [String: [String]] = [:]
                for row in tags {
                    byCategory[row["category"] as String, default: []].append(row["tag"] as String)
                }
                let resolved = OrganizeTemplate.resolve(template, tagsByCategory: byCategory)
                if let folder = resolved.relativeFolder {
                    if folder == item.folderPath {
                        entries.append(ReorganizePlanEntry(
                            itemID: itemID, fileName: item.fileName,
                            fromFolder: item.folderPath, toFolder: nil,
                            reason: "already in place"))
                    } else {
                        entries.append(ReorganizePlanEntry(
                            itemID: itemID, fileName: item.fileName,
                            fromFolder: item.folderPath, toFolder: folder,
                            reason: resolved.notes.isEmpty ? nil : resolved.notes.joined(separator: "; ")))
                    }
                } else {
                    entries.append(ReorganizePlanEntry(
                        itemID: itemID, fileName: item.fileName,
                        fromFolder: item.folderPath, toFolder: nil,
                        reason: "missing %\(resolved.missingToken ?? "?")"))
                }
            }
            return entries
        }
    }
}

/// Apply a reviewed reorganization: every move goes through the logged,
/// revertible move path — a botched template is one Move History session
/// to undo, not a lost library layout.
public struct ReorganizeJob: Job {
    public static let kind = "operations.reorganize"

    public struct Payload: Codable, Sendable {
        public var template: String
        public var itemIDs: [UUID]
        public init(template: String, itemIDs: [UUID]) {
            self.template = template
            self.itemIDs = itemIDs
        }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "operations.reorganize: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    public static func enqueue(
        on runner: JobRunner, template: String, itemIDs: [UUID]
    ) async throws -> JobRecord {
        try await runner.enqueue(
            ReorganizeJob.self,
            payload: JSONEncoder().encode(Payload(template: template, itemIDs: itemIDs)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library
        let plan = try library.previewReorganize(
            template: payload.template, itemIDs: payload.itemIDs)

        var moved = 0
        var skipped = 0
        var failed = 0
        // Every move in this run shares one session id: the run is the
        // unit anyone puts back.
        let sessionID = UUID()
        await context.reportProgress(current: 0, total: plan.count)

        for (index, entry) in plan.enumerated() {
            try await context.checkCancellation()
            defer {
                Task { await context.reportProgress(current: index + 1, total: plan.count) }
            }
            guard let toFolder = entry.toFolder else {
                skipped += 1
                continue
            }
            do {
                _ = try library.moveFile(
                    itemID: entry.itemID,
                    to: "\(toFolder)/\(entry.fileName)",
                    sessionID: sessionID,
                    fileAccess: fileAccess)
                moved += 1
            } catch {
                failed += 1
            }
        }
        var summary = "\(moved) moved, \(skipped) skipped"
        if failed > 0 { summary += ", \(failed) failed" }
        await context.setSummary(summary)
    }
}
