import Foundation
import GRDB

/// Produce an edited copy with the hide blocks cut out. Frame-accurate:
/// the kept segments are trimmed and concatenated with a re-encode (the
/// ported x264 line), because stream-copy cuts land only on keyframes.
/// Additive — the original and its blocks stay untouched; the edited
/// copy is a new item flagged `isEdited`.
public struct BlockRemovalJob: Job {
    public static let kind = "operations.blockRemoval"

    public struct Payload: Codable, Sendable {
        public var itemID: UUID
        public init(itemID: UUID) { self.itemID = itemID }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "operations.blockRemoval: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    public static func enqueue(on runner: JobRunner, itemID: UUID) async throws -> JobRecord {
        try await runner.enqueue(
            BlockRemovalJob.self, payload: JSONEncoder().encode(Payload(itemID: itemID)))
    }

    struct NoHiddenBlocks: Error, CustomStringConvertible {
        var description: String { "the item has no hide blocks" }
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
        guard let duration = item.durationSeconds, duration > 0 else {
            throw AVExport.ExportFailure(message: "unknown duration — probe the item first")
        }
        let hidden = try library.blocks(of: item.id)
            .filter { $0.kind == .hide }
            .map { ($0.startSeconds, $0.endSeconds) }
        guard !hidden.isEmpty else { throw NoHiddenBlocks() }
        let keep = SegmentMath.keepSegments(duration: duration, hidden: hidden)
        guard !keep.isEmpty else {
            throw AVExport.ExportFailure(message: "the hide blocks cover the whole item")
        }
        guard let fileURL = try library.resolvedFileURL(for: item, fileAccess: fileAccess),
              fileAccess.isReachable(fileURL),
              let source = try await library.writer.read({ try Source.fetchOne($0, key: item.sourceID) })
        else { throw MoveError.sourceUnavailable }

        let hasAudio = (item.audioStreamCount ?? 1) > 0
        let filter = Self.filterGraph(keep: keep, hasAudio: hasAudio)

        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        let stem = (item.fileName as NSString).deletingPathExtension
        var outputRelative = MediaPath.normalize("\(item.folderPath)/\(stem) (edited).mp4")
        if fileAccess.isReachable(root.appendingPathComponent(outputRelative)) {
            outputRelative = MediaPath.normalize(
                "\(item.folderPath)/\(stem) (edited)-\(LibraryDatabase.collisionStamp()).mp4")
        }
        let outputURL = root.appendingPathComponent(outputRelative)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        await context.reportProgress(current: 0, total: 1)
        var arguments = ["-i", fileURL.path, "-filter_complex", filter, "-map", "[v]"]
        if hasAudio { arguments += ["-map", "[a]"] }
        arguments += ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
        if hasAudio { arguments += ["-c:a", "aac", "-b:a", "192k"] }
        arguments += ["-movflags", "+faststart", outputURL.path]
        try FfmpegTool.run(arguments, tool: tool)

        let probe = await MediaProbe.probe(url: outputURL)
        let size = (try? fileAccess.fileSize(at: outputURL)) ?? 0
        let edited = MediaItem(
            sourceID: item.sourceID, kind: item.kind, relativePath: outputRelative,
            fileSize: size, durationSeconds: probe.durationSeconds,
            width: probe.width, height: probe.height,
            videoCodec: probe.videoCodec, audioCodec: probe.audioCodec,
            frameRate: probe.frameRate, bitrate: probe.bitrate,
            videoStreamCount: probe.videoStreamCount, audioStreamCount: probe.audioStreamCount,
            sampleRate: probe.sampleRate, audioChannels: probe.audioChannels,
            ingestDate: Date(), needsReview: false, isEdited: true)
        try await library.writer.write { try edited.insert($0) }

        await context.reportProgress(current: 1, total: 1)
        let removed = duration - keep.reduce(0) { $0 + ($1.end - $1.start) }
        await context.setSummary(String(
            format: "edited copy: %@ (%.0fs removed)", edited.fileName, removed))
    }

    /// trim/atrim + concat over the kept segments.
    static func filterGraph(keep: [(start: Double, end: Double)], hasAudio: Bool) -> String {
        var parts: [String] = []
        for (index, segment) in keep.enumerated() {
            parts.append(String(
                format: "[0:v]trim=start=%.3f:end=%.3f,setpts=PTS-STARTPTS[v%d]",
                segment.start, segment.end, index))
            if hasAudio {
                parts.append(String(
                    format: "[0:a]atrim=start=%.3f:end=%.3f,asetpts=PTS-STARTPTS[a%d]",
                    segment.start, segment.end, index))
            }
        }
        let pads = (0..<keep.count)
            .map { hasAudio ? "[v\($0)][a\($0)]" : "[v\($0)]" }
            .joined()
        let concat = hasAudio
            ? "\(pads)concat=n=\(keep.count):v=1:a=1[v][a]"
            : "\(pads)concat=n=\(keep.count):v=1:a=0[v]"
        return (parts + [concat]).joined(separator: ";")
    }
}
