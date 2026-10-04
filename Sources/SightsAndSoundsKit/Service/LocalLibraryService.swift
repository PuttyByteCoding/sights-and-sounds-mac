import Foundation
import GRDB

/// The service for a library this Mac holds: the database, its job
/// runner and the drives its sources are on. Every answer is today's
/// answer — the queries the windows used to run themselves live here now.
///
/// It is also what a host answers a remote client with: a request is
/// decoded, the same method is called, and the result encoded. Nothing
/// runs for a remote library that does not run for a local one.
public final class LocalLibraryService: LibraryService {
    let library: LibraryDatabase
    let runner: JobRunner
    let fileAccess: any FileAccess

    public init(
        library: LibraryDatabase, runner: JobRunner,
        fileAccess: any FileAccess = LiveFileAccess()
    ) {
        self.library = library
        self.runner = runner
        self.fileAccess = fileAccess
    }

    public func changes() -> AsyncStream<LibraryChange> {
        AsyncStream { continuation in
            let subscription = library.changes.subscribe { continuation.yield($0) }
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }
}

// MARK: - BrowseReading

extension LocalLibraryService {
    public func sourceStates() async throws -> [SourceState] {
        try library.sources().map { source in
            SourceState(source: source, isOnline: source.enabled && source.isOnline(using: fileAccess))
        }
    }

    public func browseVocabulary() async throws -> BrowseVocabulary {
        let categories = try library.vocabulary()
            .filter { !$0.category.hiddenFromBrowse }
            .map { CategoryTags(category: $0.category, tags: $0.tags) }
        let aliases = Dictionary(
            grouping: try await library.writer.read { try TagAlias.fetchAll($0) },
            by: \.tagID
        ).mapValues { $0.map(\.alias) }
        return BrowseVocabulary(categories: categories, aliases: aliases)
    }

    public func sidebarCounts(kinds: MediaKinds) async throws -> SidebarCounts {
        var trees: [UUID: [FolderNode]] = [:]
        for source in try library.sources() where source.enabled {
            trees[source.id] = FolderTreeBuilder.build(
                from: try library.folderCounts(kinds: kinds, sourceID: source.id))
        }
        // Every sidebar number in one batch (#96) — the counts and the
        // listing they label share one baseline, so they cannot disagree.
        return SidebarCounts(trees: trees, counts: try library.browseCounts(kinds: kinds))
    }

    public func pendingDuplicateCount() async throws -> Int {
        try library.pendingCandidates().count
    }

    public func savedFilters() async throws -> [SavedFilter] {
        try library.savedFilters()
    }

    public func savedFilterCounts(kinds: MediaKinds) async throws -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for saved in try library.savedFilters() {
            guard let filter = saved.filter else { continue }
            counts[saved.id] = (try? library.mediaItemCount(matching: filter, kinds: kinds)) ?? 0
        }
        return counts
    }

    public func tileMenuFacts(snapshotsPerItem: Int) async throws -> TileMenuFacts {
        TileMenuFacts(
            hideBlockItemIDs: try library.itemIDsWithHideBlocks(),
            snapshotRefs: try library.recentSnapshotRefs(perItem: snapshotsPerItem))
    }

    public func thumbnailQueueStatus() async throws -> ThumbnailQueueStatus? {
        try await library.writer.read { db -> ThumbnailQueueStatus? in
            guard
                let row = try JobRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM job WHERE kind = ? ORDER BY createdAt DESC LIMIT 1",
                    arguments: [ThumbnailBatchJob.kind]),
                row.state == .queued || row.state == .running
            else { return nil }
            let failed = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM thumbnailState WHERE failureMessage IS NOT NULL"
            ) ?? 0
            return ThumbnailQueueStatus(
                current: row.progressCurrent, total: row.progressTotal, failed: failed)
        }
    }
}
