import AVFoundation
import Foundation
import GRDB

/// Export an embedded clip to its own standalone file — stream-copied,
/// never re-encoded. The source clip row is NOT deleted: it's marked
/// exported (hiding it from listings) and keeps a soft reference to the
/// new item, so the parent's timeline can show "a clip was exported from
/// here" — ported breadcrumb semantics.
public struct ClipExportJob: Job {
    public static let kind = "operations.clipExport"

    public struct Payload: Codable, Sendable {
        public var clipID: UUID
        public init(clipID: UUID) { self.clipID = clipID }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "operations.clipExport: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    public static func enqueue(on runner: JobRunner, clipID: UUID) async throws -> JobRecord {
        try await runner.enqueue(
            ClipExportJob.self, payload: JSONEncoder().encode(Payload(clipID: clipID)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library
        guard let clip = try await library.writer.read({ try MediaItem.fetchOne($0, key: payload.clipID) })
        else { throw ClipError.itemNotFound }
        guard clip.parentMediaItemID != nil,
              let start = clip.clipStartSeconds, let end = clip.clipEndSeconds
        else { throw ClipError.notAClip }
        guard let parentFile = try library.resolvedFileURL(for: clip, fileAccess: fileAccess),
              let parent = try await library.writer.read({
                  try MediaItem.fetchOne($0, key: clip.parentMediaItemID!)
              })
        else { throw MoveError.sourceUnavailable }

        // Output beside the parent, named by the clip's label.
        let label = clip.notes.isEmpty ? "clip" : clip.notes
        let stem = (parent.fileName as NSString).deletingPathExtension
        var outputRelative = MediaPath.normalize(
            "\(parent.folderPath)/\(stem) - \(label).mp4")
        guard let source = try await library.writer.read({
            try Source.fetchOne($0, key: parent.sourceID)
        }) else { throw MoveError.sourceUnavailable }
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        if fileAccess.isReachable(root.appendingPathComponent(outputRelative)) {
            let ext = (outputRelative as NSString).pathExtension
            let base = (outputRelative as NSString).deletingPathExtension
            outputRelative = "\(base)-\(LibraryDatabase.collisionStamp()).\(ext)"
        }
        let outputURL = root.appendingPathComponent(outputRelative)

        await context.reportProgress(current: 0, total: 1)
        try await AVExport.passthrough(
            assetURL: parentFile, to: outputURL,
            timeRange: CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600)))

        let probe = await MediaProbe.probe(url: outputURL)
        let size = (try? fileAccess.fileSize(at: outputURL)) ?? 0
        let exported = MediaItem(
            sourceID: parent.sourceID,
            kind: parent.kind,
            relativePath: outputRelative,
            fileSize: size,
            durationSeconds: probe.durationSeconds,
            width: probe.width, height: probe.height,
            videoCodec: probe.videoCodec, audioCodec: probe.audioCodec,
            frameRate: probe.frameRate, bitrate: probe.bitrate,
            videoStreamCount: probe.videoStreamCount, audioStreamCount: probe.audioStreamCount,
            sampleRate: probe.sampleRate, audioChannels: probe.audioChannels,
            ingestDate: Date(),
            needsReview: false,
            isExportedClip: true)

        try await library.writer.write { db in
            try exported.insert(db)
            try db.execute(
                sql: """
                UPDATE mediaItem SET clipExported = 1, exportedToMediaItemID = ? WHERE id = ?
                """,
                arguments: [exported.id, clip.id])
        }
        await context.reportProgress(current: 1, total: 1)
        await context.setSummary("exported \(exported.fileName)")
    }
}
