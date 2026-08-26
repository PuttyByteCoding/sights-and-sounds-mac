import Foundation
import GRDB

/// Re-encode an item into a fresh file beside the original — additive,
/// never in place: the original is simply not touched.
public struct EncodeJob: Job {
    public static let kind = "operations.encode"

    public enum Preset: String, Codable, Sendable, CaseIterable {
        /// The old app's default encode line, verbatim.
        case h264
        case hevc

        public var displayName: String {
            switch self {
            case .h264: "H.264 (compatible)"
            case .hevc: "HEVC (smaller)"
            }
        }

        var videoArguments: [String] {
            switch self {
            case .h264:
                ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
            case .hevc:
                ["-c:v", "libx265", "-preset", "medium", "-crf", "22", "-tag:v", "hvc1"]
            }
        }
    }

    public struct Payload: Codable, Sendable {
        public var itemID: UUID
        public var preset: Preset
        public init(itemID: UUID, preset: Preset) {
            self.itemID = itemID
            self.preset = preset
        }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "operations.encode: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    public static func enqueue(on runner: JobRunner, itemID: UUID, preset: Preset) async throws -> JobRecord {
        try await runner.enqueue(
            EncodeJob.self, payload: JSONEncoder().encode(Payload(itemID: itemID, preset: preset)))
    }

    public func run(_ context: JobContext) async throws {
        guard let tool = FfmpegTool.path() else {
            await context.setSummary(FfmpegTool.installHint)
            return
        }
        let library = context.library
        guard let item = try await library.writer.read({ try MediaItem.fetchOne($0, key: payload.itemID) })
        else { throw ClipError.itemNotFound }
        guard item.parentMediaItemID == nil else { throw ClipError.notAClip }
        guard let fileURL = try library.resolvedFileURL(for: item, fileAccess: fileAccess),
              fileAccess.isReachable(fileURL),
              let source = try await library.writer.read({ try Source.fetchOne($0, key: item.sourceID) })
        else { throw MoveError.sourceUnavailable }

        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        let stem = (item.fileName as NSString).deletingPathExtension
        var outputRelative = MediaPath.normalize(
            "\(item.folderPath)/\(stem) (\(payload.preset.rawValue)).mp4")
        if fileAccess.isReachable(root.appendingPathComponent(outputRelative)) {
            outputRelative = MediaPath.normalize(
                "\(item.folderPath)/\(stem) (\(payload.preset.rawValue))-\(LibraryDatabase.collisionStamp()).mp4")
        }
        let outputURL = root.appendingPathComponent(outputRelative)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        await context.reportProgress(current: 0, total: 1)
        // Ported audio/container line: aac 192k, faststart.
        try FfmpegTool.run(
            ["-i", fileURL.path]
                + payload.preset.videoArguments
                + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", outputURL.path],
            tool: tool)

        let probe = await MediaProbe.probe(url: outputURL)
        let size = (try? fileAccess.fileSize(at: outputURL)) ?? 0
        let encoded = MediaItem(
            sourceID: item.sourceID, kind: item.kind, relativePath: outputRelative,
            fileSize: size, durationSeconds: probe.durationSeconds,
            width: probe.width, height: probe.height,
            videoCodec: probe.videoCodec, audioCodec: probe.audioCodec,
            frameRate: probe.frameRate, bitrate: probe.bitrate,
            videoStreamCount: probe.videoStreamCount, audioStreamCount: probe.audioStreamCount,
            sampleRate: probe.sampleRate, audioChannels: probe.audioChannels,
            ingestDate: Date(), needsReview: false)
        try await library.writer.write { try encoded.insert($0) }

        await context.reportProgress(current: 1, total: 1)
        await context.setSummary("encoded \(encoded.fileName)")
    }
}
