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

        // 1. Write and verify the replacement in a temp location.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-remux-\(item.id.uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try? FileManager.default.removeItem(at: tempURL)
        try await AVExport.passthrough(
            assetURL: fileURL, to: tempURL,
            optimizeForNetworkUse: payload.mode == .optimize)

        let probe = await MediaProbe.probe(url: tempURL)
        if let original = item.durationSeconds, let remuxed = probe.durationSeconds,
           abs(original - remuxed) > 2.0 {
            throw AVExport.ExportFailure(
                message: String(
                    format: "remux duration drifted (%.1fs → %.1fs) — original left untouched",
                    original, remuxed))
        }
        await context.reportProgress(current: 1, total: 3)

        // 2. Archive the original under _Replaced, only now that the
        //    replacement is verified.
        guard let source = try await library.writer.read({
            try Source.fetchOne($0, key: item.sourceID)
        }) else { throw MoveError.sourceUnavailable }
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        var archiveRelative = "_Replaced/\(item.relativePath)"
        if fileAccess.isReachable(root.appendingPathComponent(archiveRelative)) {
            let ext = (archiveRelative as NSString).pathExtension
            let base = (archiveRelative as NSString).deletingPathExtension
            archiveRelative = ext.isEmpty
                ? "\(base)-\(LibraryDatabase.collisionStamp())"
                : "\(base)-\(LibraryDatabase.collisionStamp()).\(ext)"
        }
        try LibraryDatabase.moveWithRetries(
            fileAccess: fileAccess, from: fileURL,
            to: root.appendingPathComponent(archiveRelative))
        await context.reportProgress(current: 2, total: 3)

        // 3. The remuxed file takes the item's place. A remux always lands
        //    as .mp4; the path follows so the row stays honest.
        var newRelative = item.relativePath
        if (newRelative as NSString).pathExtension.lowercased() != "mp4" {
            newRelative = ((newRelative as NSString).deletingPathExtension) + ".mp4"
        }
        try LibraryDatabase.moveWithRetries(
            fileAccess: fileAccess, from: tempURL,
            to: root.appendingPathComponent(newRelative))

        let newSize = (try? fileAccess.fileSize(at: root.appendingPathComponent(newRelative))) ?? 0
        let finalRelative = newRelative
        let finalBitrate = probe.bitrate
        try await library.writer.write { db in
            guard var updated = try MediaItem.fetchOne(db, key: item.id) else { return }
            updated.setRelativePath(finalRelative)
            updated.fileSize = newSize
            updated.bitrate = finalBitrate ?? updated.bitrate
            try updated.update(db)
        }
        await context.reportProgress(current: 3, total: 3)
        await context.setSummary(
            "\(payload.mode == .optimize ? "optimized" : "repaired") — original archived at \(archiveRelative)")
    }
}
