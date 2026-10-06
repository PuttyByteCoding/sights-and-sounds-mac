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

    /// For tests: a payload over a stand-in volume.
    init(payload: Payload, fileAccess: any FileAccess) {
        self.payload = payload
        self.fileAccess = fileAccess
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
        guard let source = try await library.read({
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
        let info = try await library.read { try LibraryInfo.fetchOne($0) }
        let appSettings = AppSettingsStore.shared.current
        let videoSet = info?.effectiveVideoExtensions(appWide: appSettings.videoExtensions)
            ?? MediaProbe.videoExtensions
        let audioSet = info?.effectiveAudioExtensions(appWide: appSettings.audioExtensions)
            ?? MediaProbe.audioExtensions

        // What this run looks at. A named list — one folder of a drive
        // that may hold forty thousand files, one job per folder — is
        // checked file by file; it used to walk the whole source for each.
        // The same rules as the walk: a file under the archive, or with an
        // extension no list claims, is not importable and is left out. A
        // named file gone from disk is counted, not dropped without a word.
        let rootPath = root.standardizedFileURL.path
        var gone = 0
        let selected: [(relative: String, url: URL, kind: MediaKind)]
        if let names = payload.relativePaths {
            var found: [(relative: String, url: URL, kind: MediaKind)] = []
            var seen: Set<String> = []
            for name in names {
                let relative = MediaPath.normalize(name)
                guard seen.insert(relative.lowercased()).inserted else { continue }
                guard !MediaPath.isArchived(relative),
                      let kind = MediaProbe.kind(
                        forExtension: (relative as NSString).pathExtension, video: videoSet, audio: audioSet)
                else { continue }
                let url = root.appendingPathComponent(relative)
                // Nor is one reached through a link that leads out of
                // the source: the walk does not follow links, so it
                // would never have listed it.
                guard MediaPath.isReallyInside(root, file: url) else { continue }
                guard fileAccess.isReachable(url) else {
                    gone += 1
                    continue
                }
                found.append((relative, url, kind))
            }
            selected = found.sorted { $0.relative < $1.relative }
        } else {
            selected = try fileAccess.allFiles(under: root)
                .compactMap { url -> (relative: String, url: URL, kind: MediaKind)? in
                    guard let kind = MediaProbe.kind(
                        forExtension: url.pathExtension, video: videoSet, audio: audioSet)
                    else { return nil }
                    let full = url.standardizedFileURL.path
                    guard full.hasPrefix(rootPath + "/") else { return nil }
                    let relative = MediaPath.normalize(String(full.dropFirst(rootPath.count + 1)))
                    guard !MediaPath.isArchived(relative) else { return nil }
                    return (relative, url, kind)
                }
                .sorted { $0.relative < $1.relative }
        }

        // The library's own spellings, read once. Folded once too, and
        // looked up per file: scanning every known path for every
        // candidate made a full rescan quadratic — 40,000 items was over a
        // billion string comparisons.
        let exactKnown = try await library.read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT relativePath FROM mediaItem WHERE sourceID = ?", arguments: [source.id]))
        }
        var existing = Set(exactKnown.map { $0.lowercased() })

        var inserted = 0
        var skipped = 0
        // Paths this run inserted, folded: a second spelling of one is a
        // different file on a case-sensitive volume, not "already imported".
        var insertedFolded: Set<String> = []
        var caseTwins: [String] = []
        let resolved = try payload.staging?.resolve(in: library)
        var vanished: Set<UUID> = []
        // For a later scan of a case-sensitive folder: a candidate whose
        // folded path is known but whose exact spelling is not, while the
        // library's spelling is ALSO on disk, is the twin left out before
        // — still a twin, not "already in".
        let candidateSpellings = Set(selected.map(\.relative))
        let knownSpellingByFold = Dictionary(
            exactKnown.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        await context.reportProgress(current: 0, total: selected.count)

        /// The one-line outcome. The leading "N new, M already imported" is
        /// read by the import window; notes go after it.
        func summary(cancelledAfter reached: Int?) -> String {
            var summary = "\(inserted) new, \(skipped) already imported"
            if let reached {
                summary += " — cancelled, \(selected.count - reached) not reached"
            }
            if gone > 0 {
                summary += gone == 1 ? " — 1 no longer on disk" : " — \(gone) no longer on disk"
            }
            // Only when something was imported: with nothing new there was
            // nothing to apply a staged value to, so none went unapplied.
            let missingStaged = inserted > 0 ? (resolved.map { $0.missing.union(vanished).count } ?? 0) : 0
            if missingStaged > 0 {
                summary += missingStaged == 1
                    ? " — 1 staged tag or field no longer exists and was not applied"
                    : " — \(missingStaged) staged tags or fields no longer exist and were not applied"
            }
            if !caseTwins.isEmpty {
                // Library paths ignore case, so only one spelling can be in.
                summary += " — not imported, another spelling already came in (paths ignore case): "
                    + caseTwins.joined(separator: ", ")
            }
            return summary
        }

        for (index, candidate) in selected.enumerated() {
            do {
                try await context.checkCancellation()
            } catch is CancellationError {
                // Cancelled between files: what went in before is in, and
                // the summary says so — a cancelled job used to write none,
                // and the window counted it as nothing inserted.
                await context.setSummary(summary(cancelledAfter: index))
                throw CancellationError()
            }
            try await insert(candidate)
            // Awaited here, in order: reported from a task of its own, a
            // count could land after a later one, or after the job was done.
            await context.reportProgress(current: index + 1, total: selected.count)
        }

        func insert(_ candidate: (relative: String, url: URL, kind: MediaKind)) async throws {
            // NOCASE-unique paths: compare case-insensitively like the schema.
            let folded = candidate.relative.lowercased()
            if insertedFolded.contains(folded) {
                caseTwins.append(candidate.relative)
                return
            }
            if existing.contains(folded) {
                if !exactKnown.contains(candidate.relative),
                   let known = knownSpellingByFold[folded], candidateSpellings.contains(known) {
                    caseTwins.append(candidate.relative)
                } else {
                    skipped += 1
                }
                return
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
            try await library.writer.write { db in
                try item.insert(db)
                // Back in: a removal remembered for this path is over.
                try RemovedItem.forget(sourceID: source.id, relativePath: item.relativePath, in: db)
            }
            // A case-sensitive volume can hold `a.mp4` and `A.mp4`; the
            // library holds one path per spelling-ignoring-case, and the
            // second insert used to fail the whole run on the index.
            existing.insert(folded)
            insertedFolded.insert(folded)
            // Staging applies through the ordinary write paths, so a
            // single-select category still replaces rather than
            // accumulating — the rule cannot be skipped by importing.
            if let staging = payload.staging, let resolved {
                vanished.formUnion(try staging.apply(to: item.id, in: library, resolved: resolved))
            }
            inserted += 1
        }

        // Source seen successfully — stamp it.
        try await library.writer.write { db in
            try db.execute(
                sql: "UPDATE source SET lastSeenAt = ? WHERE id = ?",
                arguments: [Date(), source.id])
        }
        let finalSummary = summary(cancelledAfter: nil)
        if finalSummary.contains(" — ") { AppLog.shared.warning("import", finalSummary) }
        await context.setSummary(finalSummary)
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
