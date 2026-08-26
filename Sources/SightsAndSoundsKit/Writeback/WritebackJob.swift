import Foundation
import GRDB

/// Write each item's tags into its file — wipe-and-rewrite of the tag
/// set, which is exactly why every file gets a pre-write snapshot first.
/// The run and each file's outcome are history rows; a fallback remux
/// changes the file's bytes, so the content hash is cleared for the next
/// sweep to recompute.
public struct WritebackJob: Job {
    public static let kind = "writeback.run"

    public struct Payload: Codable, Sendable {
        public var itemIDs: [UUID]
        public var scopeDescription: String
        public init(itemIDs: [UUID], scopeDescription: String) {
            self.itemIDs = itemIDs
            self.scopeDescription = scopeDescription
        }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "writeback.run: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    public static func enqueue(
        on runner: JobRunner, itemIDs: [UUID], scopeDescription: String
    ) async throws -> JobRecord {
        try await runner.enqueue(
            WritebackJob.self,
            payload: JSONEncoder().encode(Payload(itemIDs: itemIDs, scopeDescription: scopeDescription)))
    }

    public func run(_ context: JobContext) async throws {
        guard TagWriters.ffprobePath() != nil, FfmpegTool.path() != nil else {
            await context.setSummary(FfmpegTool.installHint)
            return
        }
        let library = context.library

        let mappings = try await library.writer.read { db -> [CategoryMapping] in
            try TagCategory.order(sql: "sortOrder, name").fetchAll(db).map {
                CategoryMapping(
                    categoryName: $0.name, enabled: $0.writebackEnabled,
                    writebackField: $0.writebackField)
            }
        }

        var run = TagWriteRun(
            scopeDescription: payload.scopeDescription, totalFiles: payload.itemIDs.count)
        let initialRun = run
        try await library.writer.write { try initialRun.insert($0) }

        var written = 0
        var failed = 0
        var skipped = 0
        await context.reportProgress(current: 0, total: payload.itemIDs.count)

        for (index, itemID) in payload.itemIDs.enumerated() {
            try await context.checkCancellation()
            defer {
                Task { await context.reportProgress(current: index + 1, total: payload.itemIDs.count) }
            }
            guard let item = try await library.writer.read({ try MediaItem.fetchOne($0, key: itemID) }),
                  item.parentMediaItemID == nil
            else {
                skipped += 1
                continue
            }
            let runID = run.id

            func record(_ status: WriteRunFileStatus, error: String? = nil, fallback: Bool = false) async throws {
                let file = TagWriteRunFile(
                    tagWriteRunID: runID, mediaItemID: itemID, filePath: item.relativePath,
                    status: status, error: error, usedRemuxFallback: fallback)
                try await library.writer.write { try file.insert($0) }
            }

            guard let url = try library.resolvedFileURL(for: item, fileAccess: fileAccess),
                  fileAccess.isReachable(url)
            else {
                skipped += 1
                try await record(.skipped, error: "source offline or file missing")
                continue
            }

            // Resolve this item's fields.
            let tags = try await library.writer.read { db -> [String: [String]] in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT tagCategory.name AS category, tag.name AS tag FROM tag \
                    JOIN tagCategory ON tagCategory.id = tag.tagCategoryID \
                    JOIN mediaItemTag ON mediaItemTag.tagID = tag.id \
                    WHERE mediaItemTag.mediaItemID = ? ORDER BY tag.name
                    """,
                    arguments: [itemID])
                var byCategory: [String: [String]] = [:]
                for row in rows {
                    byCategory[row["category"] as String, default: []].append(row["tag"] as String)
                }
                return byCategory
            }
            let fields = WritebackMapping.resolve(mappings: mappings, tagsByCategory: tags)
            guard !fields.isEmpty else {
                skipped += 1
                try await record(.skipped, error: "no write-back-enabled tags")
                continue
            }

            // Snapshot BEFORE the wipe-and-rewrite — non-negotiable.
            do {
                let json = try TagWriters.readTagsJSON(url: url)
                try await library.writer.write { db in
                    try EmbeddedTagSnapshot(
                        mediaItemID: itemID, source: .preWrite, tagsJSON: json).insert(db)
                }
            } catch {
                failed += 1
                try await record(.failed, error: "snapshot failed: \(error) — write refused")
                continue
            }

            let result = TagWriters.write(fields: fields, to: url)
            if result.success {
                written += 1
                try await record(.written, fallback: result.usedRemuxFallback)
                if result.usedRemuxFallback {
                    // Bytes changed: hash is stale, size may differ.
                    let newSize = (try? fileAccess.fileSize(at: url)) ?? item.fileSize
                    try await library.writer.write { db in
                        try db.execute(
                            sql: """
                            UPDATE mediaItem SET contentHash = NULL, fileSize = ? WHERE id = ?
                            """,
                            arguments: [newSize, itemID])
                        try db.execute(
                            sql: "DELETE FROM contentHashFailure WHERE mediaItemID = ?",
                            arguments: [itemID])
                    }
                }
            } else {
                failed += 1
                try await record(.failed, error: result.error, fallback: result.usedRemuxFallback)
            }
        }

        run.finishedAt = Date()
        run.writtenCount = written
        run.failedCount = failed
        let finalRun = run
        try await library.writer.write { try finalRun.update($0) }
        var summary = "\(written) written, \(skipped) skipped"
        if failed > 0 { summary += ", \(failed) failed" }
        await context.setSummary(summary)
    }
}

/// Restore a snapshot's tags into the file — after taking a pre-restore
/// snapshot of what's there now, so restore itself is undoable (ported).
public struct RestoreTagsJob: Job {
    public static let kind = "writeback.restore"

    public struct Payload: Codable, Sendable {
        public var snapshotID: UUID
        public init(snapshotID: UUID) { self.snapshotID = snapshotID }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "writeback.restore: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    public static func enqueue(on runner: JobRunner, snapshotID: UUID) async throws -> JobRecord {
        try await runner.enqueue(
            RestoreTagsJob.self, payload: JSONEncoder().encode(Payload(snapshotID: snapshotID)))
    }

    struct SnapshotMissing: Error, CustomStringConvertible {
        var description: String { "the snapshot no longer exists" }
    }

    public func run(_ context: JobContext) async throws {
        guard TagWriters.ffprobePath() != nil, FfmpegTool.path() != nil else {
            await context.setSummary(FfmpegTool.installHint)
            return
        }
        let library = context.library
        guard let snapshot = try await library.writer.read({
            try EmbeddedTagSnapshot.fetchOne($0, key: payload.snapshotID)
        }) else { throw SnapshotMissing() }
        guard let item = try await library.writer.read({
            try MediaItem.fetchOne($0, key: snapshot.mediaItemID)
        }), let url = try library.resolvedFileURL(for: item, fileAccess: fileAccess),
            fileAccess.isReachable(url)
        else { throw MoveError.sourceUnavailable }

        // Pre-restore snapshot: restoring is itself undoable.
        let currentJSON = try TagWriters.readTagsJSON(url: url)
        try await library.writer.write { db in
            try EmbeddedTagSnapshot(
                mediaItemID: item.id, source: .preRestore, tagsJSON: currentJSON).insert(db)
        }

        let fields = TagWriters.tagPairs(fromSnapshotJSON: snapshot.tagsJSON).map { pair in
            if let standard = StandardFields.all.first(where: {
                $0.vorbisName.caseInsensitiveCompare(pair.name) == .orderedSame
            }) {
                return FieldWrite(
                    vorbisName: standard.vorbisName, mp4Atom: standard.mp4Atom,
                    mp4Freeform: standard.mp4Freeform, values: [pair.value])
            }
            return FieldWrite(
                vorbisName: pair.name.uppercased(), mp4Atom: pair.name.uppercased(),
                mp4Freeform: true, values: [pair.value])
        }

        let result = TagWriters.write(fields: fields, to: url)
        guard result.success else {
            throw FfmpegTool.FfmpegError(exitCode: -1, stderrTail: result.error ?? "write failed")
        }
        if result.usedRemuxFallback {
            let newSize = (try? fileAccess.fileSize(at: url)) ?? item.fileSize
            try await library.writer.write { db in
                try db.execute(
                    sql: "UPDATE mediaItem SET contentHash = NULL, fileSize = ? WHERE id = ?",
                    arguments: [newSize, item.id])
                try db.execute(
                    sql: "DELETE FROM contentHashFailure WHERE mediaItemID = ?",
                    arguments: [item.id])
            }
        }
        await context.setSummary(
            "restored \(fields.count) fields from \(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened))")
    }
}
