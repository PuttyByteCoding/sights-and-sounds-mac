import AVFoundation
import Foundation
import GRDB

/// Rewrite an item's container in place — stream copy, never re-encode.
///
///   - `optimize`: faststart remux (moov atom up front) for instant
///     playback start — the operation AVFoundation wins outright.
///   - `repair`: a plain remux into a fresh MP4, the first-line fix for
///     glitchy containers.
///
/// Archive-before-write, ported discipline: the new file is written to a
/// temp path and verified BEFORE the original moves to `_Replaced/<path>`
/// — the original is never the thing at risk, and it stays on disk for a
/// manual restore (the summary names it).
public struct RemuxJob: Job {
    public static let kind = "operations.remux"

    public enum Mode: String, Codable, Sendable {
        case optimize
        case repair
    }

    public struct Payload: Codable, Sendable {
        public var itemID: UUID
        public var mode: Mode
        public init(itemID: UUID, mode: Mode) {
            self.itemID = itemID
            self.mode = mode
        }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "operations.remux: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    public static func enqueue(on runner: JobRunner, itemID: UUID, mode: Mode) async throws -> JobRecord {
        try await runner.enqueue(
            RemuxJob.self, payload: JSONEncoder().encode(Payload(itemID: itemID, mode: mode)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library
        guard let item = try await library.writer.read({ try MediaItem.fetchOne($0, key: payload.itemID) })
        else { throw ClipError.itemNotFound }
        guard item.parentMediaItemID == nil else { throw ClipError.notAClip }
        guard let fileURL = try library.resolvedFileURL(for: item, fileAccess: fileAccess),
              fileAccess.isReachable(fileURL)
        else { throw MoveError.sourceUnavailable }

        await context.reportProgress(current: 0, total: 3)

        // 1. Write and verify the replacement beside nothing the library
        //    lists, on the item's own volume.
        let tempURL = try LibraryDatabase.workingURL(toReplace: fileURL, fileExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
        try await AVExport.passthrough(
            assetURL: fileURL, to: tempURL,
            optimizeForNetworkUse: payload.mode == .optimize)

        // A result that cannot be probed is not verified, and an
        // unverified result never replaces a file that at least exists.
        let probe = await MediaProbe.probe(url: tempURL)
        guard let remuxed = probe.durationSeconds, remuxed > 0 else {
            throw AVExport.ExportFailure(
                message: "the remuxed file could not be read back — original left untouched")
        }
        if let original = item.durationSeconds, abs(original - remuxed) > 2.0 {
            throw AVExport.ExportFailure(
                message: String(
                    format: "remux duration drifted (%.1fs → %.1fs) — original left untouched",
                    original, remuxed))
        }
        await context.reportProgress(current: 1, total: 3)

        // 2. Archive the original and land the result — only now that the
        //    replacement is verified. A remux always lands as .mp4; the
        //    path follows so the row stays honest.
        guard let source = try await library.writer.read({
            try Source.fetchOne($0, key: item.sourceID)
        }) else { throw MoveError.sourceUnavailable }
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        var newRelative = item.relativePath
        if (newRelative as NSString).pathExtension.lowercased() != "mp4" {
            newRelative = ((newRelative as NSString).deletingPathExtension) + ".mp4"
        }
        let archiveRelative = try LibraryDatabase.replaceFile(
            under: root, currentRelative: item.relativePath, newRelative: newRelative,
            with: tempURL, fileAccess: fileAccess)
        await context.reportProgress(current: 2, total: 3)

        let newSize = (try? fileAccess.fileSize(at: root.appendingPathComponent(newRelative))) ?? 0
        let finalRelative = newRelative
        let finalBitrate = probe.bitrate
        try await library.writer.write { db in
            guard var updated = try MediaItem.fetchOne(db, key: item.id) else { return }
            updated.setRelativePath(finalRelative)
            updated.fileSize = newSize
            updated.bitrate = finalBitrate ?? updated.bitrate
            try updated.updateWithSegmentPaths(db)
        }
        await context.reportProgress(current: 3, total: 3)
        await context.setSummary(
            "\(payload.mode == .optimize ? "optimized" : "repaired") — original archived at \(archiveRelative)")
    }
}
