import AVFoundation
import Foundation
import GRDB

/// Where grid thumbnails live on disk — shared by the on-demand provider
/// (app side) and the pregeneration sweep below, so both agree on what
/// "already generated" means. Disk state is the source of truth.
public enum ThumbnailStore {
    public static var root: URL {
        if let custom = AppSettingsStore.shared.current.thumbnailDirectory {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        // A test run writes thumbnails too; not into the real cache.
        if AppSettingsStore.isUnderTest {
            return AppSettingsStore.testScratch.appendingPathComponent("Thumbnails", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SightsAndSounds/Thumbnails", isDirectory: true)
    }

    public static func url(libraryID: UUID, itemID: UUID) -> URL {
        root.appendingPathComponent(libraryID.uuidString, isDirectory: true)
            .appendingPathComponent(itemID.uuidString + ".jpg")
    }

    /// A cached thumbnail counts as made only when it is a whole JPEG —
    /// non-empty and ending in the end-of-image marker. A file cut off
    /// by a crash mid-write used to count as done forever. Two bytes
    /// read, not a decode.
    static func isWhole(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end >= 4 else { return false }
        try? handle.seek(toOffset: end - 2)
        return (try? handle.read(upToCount: 2)) == Data([0xFF, 0xD9])
    }
}

/// Pregenerates missing grid thumbnails for video items. Work is decided
/// from DISK state — a thumbnail exists or it doesn't — never a DB flag,
/// which is why deleted cache files self-heal on the next sweep. The
/// `thumbnailState` row is bookkeeping for progress surfaces and failure
/// messages, not the decision input.
public struct ThumbnailBatchJob: Job {
    public static let kind = "thumbnails.sweep"

    public struct Payload: Codable, Sendable {
        public var libraryID: UUID
        public init(libraryID: UUID) { self.libraryID = libraryID }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "thumbnails.sweep: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    /// The one way to queue a sweep. The payload names the library whose
    /// cache folder is being filled; a row without it fails on
    /// construction, so no caller builds the payload by hand.
    @discardableResult
    public static func enqueueUnlessPending(on runner: JobRunner, libraryID: UUID) async throws -> JobRecord? {
        try await runner.enqueueUnlessPending(
            ThumbnailBatchJob.self, payload: JSONEncoder().encode(Payload(libraryID: libraryID)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library
        let sources = try await library.writer.read { db in
            Dictionary(uniqueKeysWithValues: try Source.fetchAll(db).map { ($0.id, $0) })
        }
        let onlineSources = Set(
            sources.values
                .filter { $0.enabled && $0.isOnline(using: fileAccess) }
                .map(\.id))

        // Audio has no frames to thumbnail; failures recorded earlier are
        // skipped until retried.
        let candidates = try await library.writer.read { db in
            try MediaItem.fetchAll(
                db,
                sql: """
                SELECT mediaItem.* FROM mediaItem \
                WHERE mediaItem.kind = 0 \
                AND NOT EXISTS (SELECT 1 FROM thumbnailState \
                                WHERE thumbnailState.mediaItemID = mediaItem.id \
                                AND thumbnailState.failureMessage IS NOT NULL) \
                ORDER BY mediaItem.relativePath
                """)
        }.filter { item in
            onlineSources.contains(item.sourceID)
                && !ThumbnailStore.isWhole(
                    at: ThumbnailStore.url(libraryID: payload.libraryID, itemID: item.id))
        }

        var generated = 0
        var failed = 0
        var lostSources: Set<UUID> = []
        await context.reportProgress(current: 0, total: candidates.count)

        for (index, item) in candidates.enumerated() {
            try await context.checkCancellation()
            guard let source = sources[item.sourceID], !lostSources.contains(source.id) else { continue }
            let fileURL = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                .appendingPathComponent(item.relativePath)
            let thumbURL = ThumbnailStore.url(libraryID: payload.libraryID, itemID: item.id)

            if let jpeg = await Self.generate(fileURL: fileURL, durationSeconds: item.durationSeconds) {
                do {
                    try FileManager.default.createDirectory(
                        at: thumbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Whole or not at all: a crash mid-write must not
                    // leave a cut-off file in the cache.
                    try jpeg.write(to: thumbURL, options: .atomic)
                    try await library.writer.write { db in
                        try ThumbnailState(mediaItemID: item.id, generated: true).upsert(db)
                    }
                    generated += 1
                } catch {
                    try await recordFailure(library, item.id, "\(error)")
                    failed += 1
                }
            } else {
                switch try await library.sweepMiss(for: item, source: source, fileAccess: fileAccess) {
                case .sourceGone: lostSources.insert(source.id); continue
                case .fileMoved: continue
                case .fileFailed: break
                }
                try await recordFailure(library, item.id, "no frame could be decoded")
                failed += 1
            }
            await context.reportProgress(current: index + 1, total: candidates.count)
        }
        await context.setSummary(
            failed == 0 ? "\(generated) generated" : "\(generated) generated, \(failed) failed")
    }

    private func recordFailure(_ library: LibraryDatabase, _ itemID: UUID, _ message: String) async throws {
        try await library.writer.write { db in
            try ThumbnailState(mediaItemID: itemID, generated: false, failureMessage: message).upsert(db)
        }
    }

    /// Same representative-frame rule as the on-demand provider: a quarter
    /// in, capped at one minute. Callback API bridged by a continuation so
    /// the generator stays in this isolation region.
    static func generate(fileURL: URL, durationSeconds: Double?) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let seconds = min((durationSeconds ?? 8) * 0.25, 60)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, cgImage, _, result, _ in
                guard result == .succeeded, let cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: JPEG.data(from: cgImage, quality: 0.8))
            }
        }
    }
}
