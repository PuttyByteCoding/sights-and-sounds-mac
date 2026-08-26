import Foundation
import GRDB

/// Join every video file in one folder into a single file, name order —
/// the multi-part-show case. Stream copy via ffmpeg's concat demuxer:
/// exact, fast, and it refuses (with ffmpeg's own error) when the parts'
/// codecs don't actually match. Additive: parts stay untouched.
public struct JoinJob: Job {
    public static let kind = "operations.join"

    public struct Payload: Codable, Sendable {
        public var sourceID: UUID
        public var folderPath: String
        public init(sourceID: UUID, folderPath: String) {
            self.sourceID = sourceID
            self.folderPath = folderPath
        }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "operations.join: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    public static func enqueue(on runner: JobRunner, sourceID: UUID, folderPath: String) async throws -> JobRecord {
        try await runner.enqueue(
            JoinJob.self,
            payload: JSONEncoder().encode(Payload(sourceID: sourceID, folderPath: folderPath)))
    }

    struct NotEnoughParts: Error, CustomStringConvertible {
        var description: String { "joining needs at least two video files in the folder" }
    }

    public func run(_ context: JobContext) async throws {
        guard let tool = FfmpegTool.path() else {
            await context.setSummary(FfmpegTool.installHint)
            return
        }
        let library = context.library
        let folder = MediaPath.normalize(payload.folderPath)
        let sourceIDValue = payload.sourceID
        let parts = try await library.writer.read { db -> [MediaItem] in
            try MediaItem.fetchAll(
                db,
                sql: """
                SELECT * FROM mediaItem WHERE sourceID = ? AND folderPath = ? \
                AND kind = 0 AND parentMediaItemID IS NULL AND isEdited = 0 \
                AND fileName NOT LIKE '%(joined)%' \
                ORDER BY fileName
                """,
                arguments: [sourceIDValue, folder])
        }
        guard parts.count >= 2 else { throw NotEnoughParts() }
        guard let source = try await library.writer.read({
            try Source.fetchOne($0, key: sourceIDValue)
        }), source.enabled, source.isOnline(using: fileAccess)
        else { throw MoveError.sourceUnavailable }

        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        // concat demuxer list file — single-quoted paths, quote-escaped.
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-join-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: listURL) }
        let listing: String = parts.map { part -> String in
            let path = root.appendingPathComponent(part.relativePath).path
                .replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(path)'"
        }.joined(separator: "\n")
        try listing.write(to: listURL, atomically: true, encoding: .utf8)

        let folderName = (folder as NSString).lastPathComponent
        var outputRelative = MediaPath.normalize(
            "\(folder)/\(folderName.isEmpty ? "joined" : folderName) (joined).mp4")
        if fileAccess.isReachable(root.appendingPathComponent(outputRelative)) {
            outputRelative = MediaPath.normalize(
                "\(folder)/\(folderName) (joined)-\(LibraryDatabase.collisionStamp()).mp4")
        }
        let outputURL = root.appendingPathComponent(outputRelative)

        await context.reportProgress(current: 0, total: 1)
        try FfmpegTool.run(
            ["-f", "concat", "-safe", "0", "-i", listURL.path, "-c", "copy",
             "-movflags", "+faststart", outputURL.path],
            tool: tool)

        let probe = await MediaProbe.probe(url: outputURL)
        let size = (try? fileAccess.fileSize(at: outputURL)) ?? 0
        let joined = MediaItem(
            sourceID: sourceIDValue, kind: .video, relativePath: outputRelative,
            fileSize: size, durationSeconds: probe.durationSeconds,
            width: probe.width, height: probe.height,
            videoCodec: probe.videoCodec, audioCodec: probe.audioCodec,
            frameRate: probe.frameRate, bitrate: probe.bitrate,
            videoStreamCount: probe.videoStreamCount, audioStreamCount: probe.audioStreamCount,
            sampleRate: probe.sampleRate, audioChannels: probe.audioChannels,
            ingestDate: Date(), needsReview: false)
        try await library.writer.write { try joined.insert($0) }

        await context.reportProgress(current: 1, total: 1)
        await context.setSummary("joined \(parts.count) parts → \(joined.fileName)")
    }
}
