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
        /// An explicit part order. Nil keeps the folder default — name
        /// order, which is what a folder join answers; a selection
        /// carries the order it was dragged into, because that is a
        /// different question.
        public var itemIDs: [UUID]?

        public init(sourceID: UUID, folderPath: String, itemIDs: [UUID]? = nil) {
            self.sourceID = sourceID
            self.folderPath = folderPath
            self.itemIDs = itemIDs
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

    @discardableResult
    public static func enqueue(
        on runner: JobRunner, sourceID: UUID, folderPath: String, itemIDs: [UUID]? = nil
    ) async throws -> JobRecord {
        try await runner.enqueue(
            JoinJob.self,
            payload: JSONEncoder().encode(
                Payload(sourceID: sourceID, folderPath: folderPath, itemIDs: itemIDs)))
    }

    /// Why a join would be refused — checked BEFORE the job is queued,
    /// so the refusal is a panel and not a failed row in Background
    /// Tasks half an hour later.
    ///
    /// The concat demuxer needs identical codecs, dimensions and sample
    /// rates. This reads the probe columns the library already has, so
    /// it costs nothing; ffmpeg still gets the last word at run time,
    /// with its own error.
    public struct CompatibilityReport: Sendable, Equatable {
        public var mismatches: [String]
        public var isJoinable: Bool { mismatches.isEmpty }

        /// The named fix, because "refused" without a next step is just
        /// a wall.
        public static let remedy = """
            Concatenating without re-encoding requires identical codecs, dimensions and \
            sample rates. Transcode the odd one out first — Encode a Copy will do it — \
            then join the results.
            """
    }

    public static func compatibility(of parts: [MediaItem]) -> CompatibilityReport {
        guard parts.count > 1 else {
            return CompatibilityReport(mismatches: ["joining needs at least 2 items selected"])
        }
        var mismatches: [String] = []
        func distinct<T: Hashable>(_ values: [T?], _ label: String) {
            let present = Set(values.compactMap { $0 })
            if present.count > 1 {
                mismatches.append(
                    "\(label): \(present.map { "\($0)" }.sorted().joined(separator: " vs "))")
            }
        }
        distinct(parts.map(\.videoCodec), "video codec")
        distinct(parts.map(\.audioCodec), "audio codec")
        distinct(parts.map { $0.width.map { w in "\(w)" } }, "width")
        distinct(parts.map { $0.height.map { h in "\(h)" } }, "height")
        distinct(parts.map { $0.sampleRate.map { r in "\(r) Hz" } }, "sample rate")
        distinct(parts.map { $0.audioChannels.map { c in "\(c) ch" } }, "channels")
        return CompatibilityReport(mismatches: mismatches)
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
        let discovered = try await library.writer.read { db -> [MediaItem] in
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
        // An explicit order wins, and only over parts that are actually
        // in the folder — a stale selection cannot smuggle in a file
        // from somewhere else.
        var ordered = discovered
        if let itemIDs = payload.itemIDs {
            let byID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
            ordered = itemIDs.compactMap { byID[$0] }
        }
        let parts = ordered
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
