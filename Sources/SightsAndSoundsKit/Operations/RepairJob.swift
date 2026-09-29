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
        guard item.parentMediaItemID == nil else { throw RepairError.cannotRepairClip }
        guard let fileURL = try library.resolvedFileURL(for: item, fileAccess: fileAccess),
              fileAccess.isReachable(fileURL)
        else { throw MoveError.sourceUnavailable }
        guard let tool = TagWriters.toolPath(payload.recipe.tool) else {
            throw RepairError.toolMissing(payload.recipe.tool)
        }

        await context.reportProgress(current: 0, total: 3)

        // 1. Run the recipe into a working file on the item's own volume.
        let ext = (item.relativePath as NSString).pathExtension
        let tempURL = try LibraryDatabase.workingURL(
            toReplace: fileURL, fileExtension: ext.isEmpty ? "mp4" : ext)
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
        try await FfmpegTool.run(
            payload.recipe.resolvedArguments(input: fileURL.path, output: tempURL.path),
            tool: tool, isCancelled: { await context.isCancelled })

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
        let swap = try library.journaledReplace(
            item: item, under: root, newRelative: item.relativePath, with: tempURL,
            fileAccess: fileAccess)
        let archiveRelative = swap.archiveRelative
        let newSize = (try? fileAccess.fileSize(
            at: root.appendingPathComponent(item.relativePath))) ?? item.fileSize
        // The row describes the NEW file in the same transaction that
        // closes the swap: from here nothing can leave the repaired bytes
        // described by the old file's hash, size and evidence. It used to
        // be written after the unstage below, so an unstage that threw
        // (or a quit) left the old hash, and the duplicate sweep paired
        // the repaired file with its old twin as byte-identical.
        try await library.writer.write { db in
            try swap.clear(db)
            guard var updated = try MediaItem.fetchOne(db, key: item.id) else { return }
            updated.fileSize = newSize
            updated.durationSeconds = probe.durationSeconds ?? updated.durationSeconds
            updated.bitrate = probe.bitrate ?? updated.bitrate
            // New bytes: the next sweep hashes it afresh.
            updated.contentHash = nil
            try updated.update(db)
            try ContentHashFailure.filter(sql: "mediaItemID = ?", arguments: [item.id]).deleteAll(db)
            try PlaybackIssueEvidence
                .filter(sql: "mediaItemID = ?", arguments: [item.id])
                .deleteAll(db)
        }
        await context.reportProgress(current: 2, total: 3)

        // The file plays: clear the flag and put it back out of the
        // playback-issues folder — last, because it is a move of its own
        // and can fail without the repair being undone. When it does, the
        // repair still stands and says where the file was left: a failed
        // job invited a retry that would repair the repaired file again.
        var putBack = ""
        do {
            try library.unstage(.playbackIssue, itemID: item.id, fileAccess: fileAccess)
        } catch {
            let whereLeft = (try? await library.writer.read { try MediaItem.fetchOne($0, key: item.id) })??
                .relativePath ?? item.relativePath
            putBack = "; it could not be moved back out of the playback-issues folder and is at \(whereLeft): \(error)"
            AppLog.shared.warning("repair", "\(item.fileName): repaired, but \(putBack.dropFirst(2))")
        }
        await context.reportProgress(current: 3, total: 3)
        await context.setSummary(
            "repaired with \(payload.recipe.name) — original archived at \(archiveRelative)\(putBack)")
    }
}

public enum RepairError: Error, CustomStringConvertible {
    case toolMissing(String)
    case resultUnplayable
    case cannotRepairClip

    public var description: String {
        switch self {
        case .toolMissing(let tool):
            "\(tool) not found — install it and try again; the original is untouched"
        case .resultUnplayable:
            "the repaired file did not probe as playable — the original is untouched"
        case .cannotRepairClip:
            "a clip has no file of its own — repair the item it was cut from"
        }
    }
}
