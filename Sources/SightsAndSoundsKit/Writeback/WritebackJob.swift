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

    /// What one file's write came to; the run's file row says the same.
    public enum FileOutcome: Equatable, Sendable {
        case written
        case failed(String?)
        /// Nothing to write, or nowhere to write it.
        case skipped(String)
    }

    /// The library's write-back mappings, read once per run.
    public static func mappings(in library: LibraryDatabase) throws -> [CategoryMapping] {
        try library.writer.read { db in
            try TagCategory.order(sql: "sortOrder, name").fetchAll(db).map {
                CategoryMapping(
                    categoryName: $0.name, enabled: $0.writebackEnabled,
                    writebackField: $0.writebackField)
            }
        }
    }

    /// Write one item's tags into its file, recording a file row on `runID`:
    /// snapshot first, then the wipe-and-rewrite, then forget what the
    /// library read off the old bytes. Shared with removing an item from
    /// the library, which offers to write the tags out before the row goes.
    public static func writeTags(
        of item: MediaItem, mappings: [CategoryMapping], runID: UUID,
        library: LibraryDatabase, fileAccess: any FileAccess
    ) async throws -> FileOutcome {
        let itemID = item.id
        func record(_ status: WriteRunFileStatus, error: String? = nil, fallback: Bool = false) async throws {
            let file = TagWriteRunFile(
                tagWriteRunID: runID, mediaItemID: itemID, filePath: item.relativePath,
                status: status, error: error, usedRemuxFallback: fallback)
            try await library.writer.write { try file.insert($0) }
        }

        guard let url = try library.resolvedFileURL(for: item, fileAccess: fileAccess),
              fileAccess.isReachable(url)
        else {
            try await record(.skipped, error: "source offline or file missing")
            return .skipped("source offline or file missing")
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
            try await record(.skipped, error: "no write-back-enabled tags")
            return .skipped("no write-back-enabled tags")
        }

        // Snapshot BEFORE the wipe-and-rewrite — non-negotiable.
        do {
            let json = try await Blocking.run { try TagWriters.readTagsJSON(url: url) }
            try await library.writer.write { db in
                try EmbeddedTagSnapshot(
                    mediaItemID: itemID, source: .preWrite, tagsJSON: json).insert(db)
            }
        } catch {
            let reason = "snapshot failed: \(error) — write refused"
            try await record(.failed, error: reason)
            return .failed(reason)
        }

        let result = try await Blocking.run { TagWriters.write(fields: fields, to: url) }
        guard result.success else {
            try await record(.failed, error: result.error, fallback: result.usedRemuxFallback)
            return .failed(result.error)
        }
        let outcome: FileOutcome
        if result.keptNothing(of: fields.count) {
            // The old tags were replaced by nothing: not a write. The
            // pre-write snapshot can put them back.
            try await record(.failed, error: result.writtenNote, fallback: result.usedRemuxFallback)
            outcome = .failed(result.writtenNote)
        } else {
            // A write that took the slow path keeps the reason with it.
            try await record(.written, error: result.writtenNote, fallback: result.usedRemuxFallback)
            outcome = .written
        }
        // Bytes changed, whichever tool wrote them: the hash is of the
        // whole file, so an in-place tag rewrite stales it as surely as a
        // remux does, and the size may differ.
        let newSize = (try? fileAccess.fileSize(at: url)) ?? item.fileSize
        try await library.writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET fileSize = ? WHERE id = ?",
                arguments: [newSize, itemID])
            try LibraryDatabase.forgetReadingsOfChangedFile(itemID, .sameStreams, in: db)
        }
        return outcome
    }

    public func run(_ context: JobContext) async throws {
        guard TagWriters.ffprobePath() != nil, FfmpegTool.path() != nil else {
            await context.setSummary(FfmpegTool.installHint)
            return
        }
        let library = context.library
        let mappings = try Self.mappings(in: library)

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
            guard let item = try await library.writer.read({ try MediaItem.fetchOne($0, key: itemID) }),
                  item.parentMediaItemID == nil
            else {
                skipped += 1
                await context.reportProgress(current: index + 1, total: payload.itemIDs.count)
                continue
            }
            switch try await Self.writeTags(
                of: item, mappings: mappings, runID: run.id, library: library, fileAccess: fileAccess
            ) {
            case .written: written += 1
            case .failed: failed += 1
            case .skipped: skipped += 1
            }
            await context.reportProgress(current: index + 1, total: payload.itemIDs.count)
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
        let currentJSON = try await Blocking.run { try TagWriters.readTagsJSON(url: url) }
        try await library.writer.write { db in
            try EmbeddedTagSnapshot(
                mediaItemID: item.id, source: .preRestore, tagsJSON: currentJSON).insert(db)
        }

        let fields = SnapshotRestore.fields(fromSnapshotJSON: snapshot.tagsJSON)

        let result = try await Blocking.run { TagWriters.write(fields: fields, to: url, restoring: true) }
        guard result.success else {
            throw FfmpegTool.FfmpegError(exitCode: -1, stderrTail: result.error ?? "write failed")
        }
        // A restore rewrites the file's bytes too, native tool or remux.
        let newSize = (try? fileAccess.fileSize(at: url)) ?? item.fileSize
        try await library.writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET fileSize = ? WHERE id = ?",
                arguments: [newSize, item.id])
            try LibraryDatabase.forgetReadingsOfChangedFile(item.id, .sameStreams, in: db)
        }
        // A restore that could hold none of the fields still succeeded: the
        // file is as near the snapshot as its format allows (see
        // `TagWriters.write(restoring:)`), and the note names what it could
        // not hold. Its pre-restore snapshot can undo it.
        // What the writer could not hold is said, not counted as restored.
        let restored = fields.count - result.notWritten.count
        let note = result.writtenNote.map { " — \($0)" } ?? ""
        await context.setSummary(
            "restored \(restored) of \(fields.count) fields from "
                + snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened) + note)
    }
}
