import Foundation
import GRDB

/// Directory scan + import for one source: find media files under the
/// source root, probe the new ones, insert rows. The first real `Job`
/// conformance — persistence, progress, cancellation and the serialized
/// queue all come from the runner.
///
/// Standing rules honored here:
///   - **Serialized queue**: the runner executes jobs one at a time, so
///     two imports can never interleave inserts (the old
///     DirectoryImportService guarantee).
///   - **Idempotent**: `(sourceID, relativePath)` is unique; existing rows
///     are skipped, so re-running an import discovers only what's new.
///   - **Offline-aware**: an unreachable or disabled source fails the job
///     with a clear message instead of importing nothing silently.
///   - **Nothing destroyed**: files missing from disk are left alone —
///     reconciling deletions is validation's business (Phase 8). Sidecar
///     metadata files (JSON/text) are not consumed; the metadata pipeline
///     reads them in its own phase.
public struct ImportJob: Job {
    public static let kind = "import.scan"

    public struct Payload: Codable, Sendable {
        public var sourceID: UUID
        /// The files to import. `nil` imports everything the scan finds,
        /// which is what a plain "scan this source" still means; a list
        /// is what the review window sends once someone has looked at it.
        public var relativePaths: [String]?
        /// What to apply to every row this payload inserts. Per-folder
        /// staging is several payloads, one per folder — not a second
        /// code path.
        public var staging: ImportStaging?

        public init(
            sourceID: UUID, relativePaths: [String]? = nil, staging: ImportStaging? = nil
        ) {
            self.sourceID = sourceID
            self.relativePaths = relativePaths
            self.staging = staging
        }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "import.scan: missing payload") }
        self.payload = decoded
        self.fileAccess = LiveFileAccess()
    }

    /// Enqueue an import for a source. With no list, it imports
    /// everything it finds — the pre-review behaviour, kept for "scan
    /// all sources".
    @discardableResult
    public static func enqueue(
        on runner: JobRunner, sourceID: UUID,
        relativePaths: [String]? = nil, staging: ImportStaging? = nil
    ) async throws -> JobRecord {
        try await runner.enqueue(
            ImportJob.self,
            payload: JSONEncoder().encode(
                Payload(sourceID: sourceID, relativePaths: relativePaths, staging: staging)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library
        guard let source = try await library.writer.read({
            try Source.fetchOne($0, key: payload.sourceID)
        }) else {
            throw ImportError.sourceMissing
        }
        guard source.enabled else { throw ImportError.sourceDisabled(source.name) }
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        guard source.isOnline(using: fileAccess) else {
            throw ImportError.sourceOffline(source.name)
        }

        // Effective extension sets: the library's override replaces the
        // app-wide lists; absent, it inherits them. Resolved once per run.
        let info = try await library.writer.read { try LibraryInfo.fetchOne($0) }
        let appSettings = AppSettingsStore.shared.current
        let videoSet = info?.effectiveVideoExtensions(appWide: appSettings.videoExtensions)
            ?? MediaProbe.videoExtensions
        let audioSet = info?.effectiveAudioExtensions(appWide: appSettings.audioExtensions)
            ?? MediaProbe.audioExtensions

        // Discover media files, source-relative, stable order.
        let rootPath = root.standardizedFileURL.path
        let candidates = try fileAccess.allFiles(under: root)
            .compactMap { url -> (relative: String, url: URL, kind: MediaKind)? in
                guard let kind = MediaProbe.kind(
                    forExtension: url.pathExtension, video: videoSet, audio: audioSet)
                else { return nil }
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(rootPath + "/") else { return nil }
                let relative = MediaPath.normalize(String(full.dropFirst(rootPath.count + 1)))
                return (relative, url, kind)
            }
            .sorted { $0.relative < $1.relative }

        // A named list narrows what this run inserts. The comparison is
        // NOCASE like the schema's unique index, so a list written from
        // one case can't miss the file it named.
        let requested = payload.relativePaths.map { Set($0.map { $0.lowercased() }) }
        let selected = requested.map { wanted in
            candidates.filter { wanted.contains($0.relative.lowercased()) }
        } ?? candidates

        let existing = try await library.writer.read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT relativePath FROM mediaItem WHERE sourceID = ?",
                arguments: [source.id]))
        }

        var inserted = 0
        var skipped = 0
        await context.reportProgress(current: 0, total: selected.count)

        for (index, candidate) in selected.enumerated() {
            try await context.checkCancellation()
            defer { Task { await context.reportProgress(current: index + 1, total: selected.count) } }

            // NOCASE-unique paths: compare case-insensitively like the schema.
            if existing.contains(where: { $0.caseInsensitiveCompare(candidate.relative) == .orderedSame }) {
                skipped += 1
                continue
            }

            let size = (try? fileAccess.fileSize(at: candidate.url)) ?? 0
            let probe = await MediaProbe.probe(url: candidate.url)
            let item = MediaItem(
                sourceID: source.id,
                kind: candidate.kind,
                relativePath: candidate.relative,
                fileSize: size,
                durationSeconds: probe.durationSeconds,
                width: probe.width,
                height: probe.height,
                videoCodec: probe.videoCodec,
                audioCodec: probe.audioCodec,
                frameRate: probe.frameRate,
                bitrate: probe.bitrate,
                videoStreamCount: probe.videoStreamCount,
                audioStreamCount: probe.audioStreamCount,
                sampleRate: probe.sampleRate,
                audioChannels: probe.audioChannels,
                contentCreatedAt: probe.contentCreatedAt,
                ingestDate: Date(),
                needsReview: true)  // auto-set on import; the user clears it
            try await library.writer.write { try item.insert($0) }
            // Staging applies through the ordinary write paths, so a
            // single-select category still replaces rather than
            // accumulating — the rule cannot be skipped by importing.
            if let staging = payload.staging {
                try staging.apply(to: item.id, in: library)
            }
            inserted += 1
        }

        // Source seen successfully — stamp it.
        try await library.writer.write { db in
            try db.execute(
                sql: "UPDATE source SET lastSeenAt = ? WHERE id = ?",
                arguments: [Date(), source.id])
        }
        await context.setSummary("\(inserted) new, \(skipped) already imported")
    }
}

public enum ImportError: Error, CustomStringConvertible {
    case sourceMissing
    case sourceDisabled(String)
    case sourceOffline(String)

    public var description: String {
        switch self {
        case .sourceMissing: "the source no longer exists"
        case .sourceDisabled(let name): "source '\(name)' is disabled"
        case .sourceOffline(let name): "source '\(name)' is offline — import will pick it up when it returns"
        }
    }
}
