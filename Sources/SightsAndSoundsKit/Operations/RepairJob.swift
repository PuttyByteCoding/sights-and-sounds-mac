import Foundation
import GRDB

/// Run one repair recipe against one file.
///
/// The discipline is `RemuxJob`'s, and every recipe inherits it: write
/// the result to a temporary file, **re-probe it**, and only then move
/// the original aside to `_Replaced/<path>`. That is what lets a fix be
/// offered without a confirmation dialog in front of it — the original is
/// never the thing at risk, and it stays on disk for a manual restore
/// (the summary names where).
///
/// The recipe itself is data, so this job is the only code the fixes
/// share: adding one is a row, not a release.
public struct RepairJob: Job {
    public static let kind = "operations.repair"

    public struct Payload: Codable, Sendable {
        public var itemID: UUID
        public var recipe: RepairRecipe
        public init(itemID: UUID, recipe: RepairRecipe) {
            self.itemID = itemID
            self.recipe = recipe
        }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "operations.repair: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    @discardableResult
    public static func enqueue(
        on runner: JobRunner, itemID: UUID, recipe: RepairRecipe
    ) async throws -> JobRecord {
        try await runner.enqueue(
            RepairJob.self,
            payload: JSONEncoder().encode(Payload(itemID: itemID, recipe: recipe)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library
        guard let item = try await library.writer.read({
            try MediaItem.fetchOne($0, key: payload.itemID)
        }) else { throw ClipError.itemNotFound }
        guard item.parentMediaItemID == nil else { throw ClipError.notAClip }
        guard let fileURL = try library.resolvedFileURL(for: item, fileAccess: fileAccess),
              fileAccess.isReachable(fileURL)
        else { throw MoveError.sourceUnavailable }
        guard let tool = TagWriters.toolPath(payload.recipe.tool) else {
            throw RepairError.toolMissing(payload.recipe.tool)
        }

        await context.reportProgress(current: 0, total: 3)

        // 1. Run the recipe into a temp file.
        let ext = (item.relativePath as NSString).pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-repair-\(item.id.uuidString).\(ext.isEmpty ? "mp4" : ext)")
        try? FileManager.default.removeItem(at: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try FfmpegTool.run(
            payload.recipe.resolvedArguments(input: fileURL.path, output: tempURL.path),
            tool: tool)

        // 2. Re-probe the RESULT. A repair that produced an unplayable
        //    file must not replace a file that at least still exists.
        let probe = await MediaProbe.probe(url: tempURL)
        guard let duration = probe.durationSeconds, duration > 0 else {
            throw RepairError.resultUnplayable
        }
        await context.reportProgress(current: 1, total: 3)

        // 3. Archive the original, only now that the result is verified.
        guard let source = try await library.writer.read({
            try Source.fetchOne($0, key: item.sourceID)
        }) else { throw MoveError.sourceUnavailable }
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        var archiveRelative = "_Replaced/\(item.relativePath)"
        if fileAccess.isReachable(root.appendingPathComponent(archiveRelative)) {
            let archiveExt = (archiveRelative as NSString).pathExtension
            let base = (archiveRelative as NSString).deletingPathExtension
            archiveRelative = archiveExt.isEmpty
                ? "\(base)-\(LibraryDatabase.collisionStamp())"
                : "\(base)-\(LibraryDatabase.collisionStamp()).\(archiveExt)"
        }
        try LibraryDatabase.moveWithRetries(
            fileAccess: fileAccess, from: fileURL,
            to: root.appendingPathComponent(archiveRelative))
        try LibraryDatabase.moveWithRetries(
            fileAccess: fileAccess, from: tempURL,
            to: root.appendingPathComponent(item.relativePath))
        await context.reportProgress(current: 2, total: 3)

        // The file plays: clear the flag and the staging that came with
        // it, and record what the repair produced.
        let newSize = (try? fileAccess.fileSize(
            at: root.appendingPathComponent(item.relativePath))) ?? item.fileSize
        try library.unstage(.playbackIssue, itemID: item.id, fileAccess: fileAccess)
        try await library.writer.write { db in
            guard var updated = try MediaItem.fetchOne(db, key: item.id) else { return }
            updated.fileSize = newSize
            updated.durationSeconds = probe.durationSeconds ?? updated.durationSeconds
            updated.bitrate = probe.bitrate ?? updated.bitrate
            try updated.update(db)
            try db.execute(
                sql: "DELETE FROM playbackIssueEvidence WHERE mediaItemID = ?",
                arguments: [item.id])
        }
        await context.reportProgress(current: 3, total: 3)
        await context.setSummary(
            "repaired with \(payload.recipe.name) — original archived at \(archiveRelative)")
    }
}

public enum RepairError: Error, CustomStringConvertible {
    case toolMissing(String)
    case resultUnplayable

    public var description: String {
        switch self {
        case .toolMissing(let tool):
            "\(tool) not found — install it and try again; the original is untouched"
        case .resultUnplayable:
            "the repaired file did not probe as playable — the original is untouched"
        }
    }
}
