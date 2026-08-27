import Foundation
import GRDB
import SwiftUI
import SightsAndSoundsKit

/// Per-category tags for the filter panel.
struct CategoryTags: Identifiable {
    var id: UUID { category.id }
    let category: TagCategory
    let tags: [Tag]
}

/// One library window's state: the active filter, its results, and the
/// sidebar data. All reads go through the library's own handle — nothing
/// here can see another library.
@Observable @MainActor
final class BrowseModel {
    let libraryID: UUID
    let library: LibraryDatabase
    let libraryName: String

    var kind: MediaKind = .video { didSet { refreshAll() } }
    var filter = MediaFilter() { didSet { refreshItems() } }
    var selectedFolderPath: String?

    /// The listing's sort. One control orders both the grid and the play
    /// queue — the playlist is a snapshot of `items`.
    var ordering: MediaOrdering = .relativePath { didSet { refreshItems() } }

    /// Shuffle deals with a seed so the order is stable across refreshes;
    /// calling again is a new deal.
    func shuffle() {
        ordering = .random(seed: Int.random(in: 0..<1_000_000_000))
    }

    /// Non-nil while the embedded player has taken over this library's
    /// window; cleared (with a refresh — flags and tags may have changed)
    /// when playback closes.
    var playerRequest: PlayerRequest?

    private(set) var items: [MediaItem] = []
    /// One folder tree per enabled source — the sidebar nests each under
    /// its source row.
    private(set) var folderTrees: [UUID: [FolderNode]] = [:]
    /// Alias strings per tag, for the sidebar's per-category tag filter
    /// (typing "SBD" should find "Soundboard").
    private(set) var tagAliases: [UUID: [String]] = [:]
    private(set) var vocabulary: [CategoryTags] = []
    private(set) var sources: [Source] = []
    private(set) var pendingDuplicateCount = 0
    private(set) var onlineSourceIDs: Set<UUID> = []
    var errorMessage: String? {
        didSet {
            if let errorMessage { AppLog.shared.error("browse", errorMessage) }
        }
    }

    private let fileAccess: any FileAccess = LiveFileAccess()
    private let jobRunner: JobRunner
    private let onWorkFinished: () -> Void
    // Observer tokens live in a bag whose own deinit removes them —
    // sidestepping actor-isolated-deinit rules entirely.
    private final class ObserverBag: @unchecked Sendable {
        var tokens: [any NSObjectProtocol] = []
        deinit {
            for token in tokens {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
            }
        }
    }
    private let mountObservers = ObserverBag()

    // Cross-WINDOW reconciliation: the auxiliary workspace windows (the
    // former sheets) each host their own BrowseModel over the same
    // library. Whichever model refreshes broadcasts; the others follow
    // quietly. The sender token breaks the loop.
    private final class DefaultCenterBag: @unchecked Sendable {
        var tokens: [any NSObjectProtocol] = []
        deinit {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }
    }
    private let changeObservers = DefaultCenterBag()
    private let changeToken = UUID()

    /// Sources with an import in flight, and their progress line.
    private(set) var importStatus: [UUID: String] = [:]

    /// The thumbnail sweep's live progress for this library — non-nil
    /// only while a sweep is queued or running. Read by the footer bar
    /// under the grid; counts come from the job row and thumbnailState,
    /// the sweep's own progress bookkeeping, never re-derived from disk.
    struct ThumbnailQueueStatus: Equatable {
        var current: Int
        var total: Int?
        var failed: Int
    }
    private(set) var thumbnailQueue: ThumbnailQueueStatus?

    /// Poll while the browse UI is on screen — the view owns the task,
    /// so nothing runs while the player has the window or after close.
    /// Same one-second cadence as the tasks dashboard; two cheap reads.
    func watchThumbnailQueue() async {
        while !Task.isCancelled {
            thumbnailQueue = await Self.thumbnailQueueStatus(in: library)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func thumbnailQueueStatus(
        in library: LibraryDatabase
    ) async -> ThumbnailQueueStatus? {
        do {
            return try await library.writer.read { db in
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
        } catch {
            return nil
        }
    }

    init(
        libraryID: UUID, library: LibraryDatabase, runner: JobRunner,
        onWorkFinished: @escaping () -> Void = {}
    ) {
        self.libraryID = libraryID
        self.library = library
        self.libraryName = (try? library.info()?.name) ?? "Library"
        self.jobRunner = runner
        self.onWorkFinished = onWorkFinished
        refreshAll()

        changeObservers.tokens.append(NotificationCenter.default.addObserver(
            forName: .sasLibraryDataChanged, object: nil, queue: .main
        ) { [weak self] note in
            let libraryID = note.userInfo?["libraryID"] as? UUID
            let sender = note.userInfo?["sender"] as? UUID
            Task { @MainActor in
                guard let self, libraryID == self.libraryID, sender != self.changeToken
                else { return }
                self.refreshAll(broadcast: false)
            }
        })

        // Mount/unmount drives online-state transitions and wakes the
        // workers — the reachability check stays the fallback truth.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            mountObservers.tokens.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshAll()
                    self?.onWorkFinished()
                }
            })
        }
    }



    /// Everything here runs off the main actor — the source reachability
    /// checks touch the FILESYSTEM, and an offline network volume used to
    /// block the UI for the length of its timeout. Same generation-guard
    /// shape as refreshItems; the last refresh requested wins.
    private var refreshAllGeneration = 0

    func refreshAll(broadcast: Bool = true) {
        refreshAllGeneration += 1
        let generation = refreshAllGeneration
        let library = library, kind = kind, fileAccess = fileAccess
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let sources = try library.sources()
                let onlineIDs = Set(
                    sources.filter { $0.enabled && $0.isOnline(using: fileAccess) }.map(\.id))
                let vocabulary = try library.vocabulary()
                    .filter { !$0.category.hiddenFromBrowse }
                    .map { CategoryTags(category: $0.category, tags: $0.tags) }
                let aliases = Dictionary(
                    grouping: try await library.writer.read { try TagAlias.fetchAll($0) },
                    by: \.tagID
                ).mapValues { $0.map(\.alias) }
                var trees: [UUID: [FolderNode]] = [:]
                for source in sources where source.enabled {
                    trees[source.id] = FolderTreeBuilder.build(
                        from: try library.folderCounts(kind: kind, sourceID: source.id))
                }
                let pending = try library.pendingCandidates().count
                await MainActor.run { [weak self] in
                    guard let self, self.refreshAllGeneration == generation else { return }
                    self.sources = sources
                    self.onlineSourceIDs = onlineIDs
                    self.vocabulary = vocabulary
                    self.tagAliases = aliases
                    self.folderTrees = trees
                    self.pendingDuplicateCount = pending
                    self.refreshItems()
                    if broadcast {
                        NotificationCenter.default.post(
                            name: .sasLibraryDataChanged, object: nil,
                            userInfo: [
                                "libraryID": self.libraryID, "sender": self.changeToken,
                            ])
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.refreshAllGeneration == generation else { return }
                    self.errorMessage = "\(error)"
                }
            }
        }
    }

    /// The search field's live text — always in sync with keystrokes.
    /// Pushed into the filter (and thus the query) only after a pause,
    /// so typing never waits on a table scan.
    private(set) var searchDisplayText: String = ""
    private var searchDebounce: Task<Void, Never>?

    func setSearchText(_ text: String) {
        searchDisplayText = text
        searchDebounce?.cancel()
        // Clearing (the field's ✕, or deleting the last character) skips
        // the pause — restoring the full grid should feel instant.
        if text.isEmpty {
            if filter.searchText != "" { filter.searchText = "" }
            return
        }
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            if self.filter.searchText != text { self.filter.searchText = text }
        }
    }

    /// Queries run off the main actor; the generation counter drops any
    /// result a newer refresh has since superseded, so typing fast can
    /// never publish stale rows over fresh ones.
    private var refreshGeneration = 0

    /// Per-item display data for grid fields that need joins — batched
    /// alongside the item fetch, never per cell (per-cell queries are an
    /// N+1 disaster at library size). Populated only while a field that
    /// needs them is enabled.
    private(set) var itemTagNames: [UUID: [String]] = [:]
    private(set) var itemMissingCategories: [UUID: [String]] = [:]
    private(set) var duplicateFlaggedIDs: Set<UUID> = []

    private struct ListingPayload: Sendable {
        var items: [MediaItem]
        var tagNames: [UUID: [String]]
        var missingCategories: [UUID: [String]]
        var duplicateIDs: Set<UUID>
    }

    func refreshItems() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let library = library, filter = filter, kind = kind, ordering = ordering
        let grid = AppSettingsStore.shared.current.grid
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<ListingPayload, Error>
            do {
                let rows = try library.mediaItems(matching: filter, kind: kind, orderedBy: ordering)
                var payload = ListingPayload(
                    items: rows, tagNames: [:], missingCategories: [:], duplicateIDs: [])
                if grid.needsTagData {
                    let vocabulary = try library.vocabulary()
                        .filter { !$0.category.hiddenFromBrowse }
                    var tagInfo: [UUID: (name: String, categoryID: UUID)] = [:]
                    for entry in vocabulary {
                        for tag in entry.tags { tagInfo[tag.id] = (tag.name, entry.category.id) }
                    }
                    // Explicit return type — the async `read` overload's
                    // inference is ambiguous to the CI toolchain (Xcode 16).
                    let links: [Row] = try await library.writer.read { db -> [Row] in
                        try Row.fetchAll(db, sql: "SELECT mediaItemID, tagID FROM mediaItemTag")
                    }
                    var tagsByItem: [UUID: [UUID]] = [:]
                    for link in links {
                        tagsByItem[link["mediaItemID"] as UUID, default: []]
                            .append(link["tagID"] as UUID)
                    }
                    for item in rows {
                        let tagIDs = tagsByItem[item.id] ?? []
                        payload.tagNames[item.id] = tagIDs.compactMap { tagInfo[$0]?.name }.sorted()
                        let covered = Set(tagIDs.compactMap { tagInfo[$0]?.categoryID })
                        payload.missingCategories[item.id] = vocabulary
                            .filter { !covered.contains($0.category.id) }
                            .map(\.category.name)
                    }
                }
                if grid.showsDuplicate {
                    payload.duplicateIDs = Set(
                        try library.pendingCandidates().flatMap { [$0.itemAID, $0.itemBID] })
                }
                outcome = .success(payload)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                switch outcome {
                case .success(let payload):
                    self.items = payload.items
                    self.itemTagNames = payload.tagNames
                    self.itemMissingCategories = payload.missingCategories
                    self.duplicateFlaggedIDs = payload.duplicateIDs
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = "\(error)"
                }
            }
        }
    }

    // MARK: - Sidebar actions

    func selectFolder(_ path: String?) {
        selectedFolderPath = path
        filter.selectSubtree(path)
    }

    func clearFilter() {
        selectedFolderPath = nil
        searchDebounce?.cancel()
        searchDisplayText = ""
        filter = MediaFilter()
    }

    func setSourceEnabled(_ source: Source, _ enabled: Bool) {
        do {
            try library.writer.write { db in
                var updated = source
                updated.enabled = enabled
                try updated.update(db)
            }
            refreshAll()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Sources & import

    func addSource(at url: URL) {
        do {
            let source = Source(name: url.lastPathComponent, rootPath: url.path)
            try library.writer.write { try source.insert($0) }
            refreshAll()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Scan a source for new files. Serialized by the job runner; progress
    /// surfaces beside the source row; the grid refreshes when done.
    func importSource(_ source: Source) {
        guard importStatus[source.id] == nil else { return }
        importStatus[source.id] = "queued…"
        Task {
            do {
                await jobRunner.register(ImportJob.self)
                let record = try await ImportJob.enqueue(on: jobRunner, sourceID: source.id)
                let drain = Task { try await jobRunner.runPending() }

                // Poll the job row for progress until it settles.
                var settled = false
                while !settled {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let row = try await library.writer.read({
                        try JobRecord.fetchOne($0, key: record.id)
                    }) else { break }
                    switch row.state {
                    case .queued:
                        importStatus[source.id] = "queued…"
                    case .running:
                        if let total = row.progressTotal, total > 0 {
                            importStatus[source.id] = "\(row.progressCurrent)/\(total)"
                        } else {
                            importStatus[source.id] = "scanning…"
                        }
                    case .succeeded, .failed, .cancelled:
                        settled = true
                        if row.state == .failed, let error = row.error {
                            errorMessage = "Import failed: \(error)"
                        }
                    }
                }
                _ = try? await drain.value
            } catch {
                errorMessage = "\(error)"
            }
            importStatus[source.id] = nil
            refreshAll()
            // Import finishing is a worker signal: new rows want hashes
            // and thumbnails.
            onWorkFinished()
        }
    }

    // MARK: - Item helpers

    func source(for item: MediaItem) -> Source? {
        sources.first { $0.id == item.sourceID }
    }

    func isOnline(_ item: MediaItem) -> Bool {
        onlineSourceIDs.contains(item.sourceID)
    }

    /// Absolute file URL (an embedded clip resolves to its parent's
    /// file), or nil while the item's source is offline.
    func fileURL(for item: MediaItem) -> URL? {
        (try? library.resolvedFileURL(for: item, fileAccess: fileAccess)) ?? nil
    }

    // MARK: - Operations

    func exportClip(_ item: MediaItem) {
        runOperation { runner in
            _ = try await ClipExportJob.enqueue(on: runner, clipID: item.id)
        }
    }

    func encode(_ item: MediaItem, preset: EncodeJob.Preset) {
        runOperation { runner in
            _ = try await EncodeJob.enqueue(on: runner, itemID: item.id, preset: preset)
        }
    }

    func removeBlocks(_ item: MediaItem) {
        runOperation { runner in
            _ = try await BlockRemovalJob.enqueue(on: runner, itemID: item.id)
        }
    }

    func hasHideBlocks(_ item: MediaItem) -> Bool {
        ((try? library.blocks(of: item.id)) ?? []).contains { $0.kind == .hide }
    }

    func scanText(_ item: MediaItem) {
        runOperation { runner in
            _ = try await OcrJob.enqueue(on: runner, itemID: item.id)
        }
    }

    func joinFolder(of item: MediaItem) {
        runOperation { runner in
            _ = try await JoinJob.enqueue(
                on: runner, sourceID: item.sourceID, folderPath: item.folderPath)
        }
    }

    func reorganize(template: String, itemIDs: [UUID]) {
        runOperation { runner in
            _ = try await ReorganizeJob.enqueue(on: runner, template: template, itemIDs: itemIDs)
        }
    }

    func writeTags(itemIDs: [UUID], scope: String) {
        runOperation { runner in
            _ = try await WritebackJob.enqueue(on: runner, itemIDs: itemIDs, scopeDescription: scope)
        }
    }

    func restoreSnapshot(_ snapshotID: UUID) {
        runOperation { runner in
            _ = try await RestoreTagsJob.enqueue(on: runner, snapshotID: snapshotID)
        }
    }

    func snapshots(of itemID: UUID) -> [EmbeddedTagSnapshot] {
        (try? library.writer.read { db in
            try EmbeddedTagSnapshot
                .filter(sql: "mediaItemID = ?", arguments: [itemID])
                .order(sql: "capturedAt DESC").limit(10).fetchAll(db)
        }) ?? []
    }

    func runValidation() async {
        do {
            await jobRunner.register(ValidationJob.self)
            _ = try await jobRunner.enqueueUnlessPending(ValidationJob.self)
            try await jobRunner.runPending()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func remux(_ item: MediaItem, mode: RemuxJob.Mode) {
        runOperation { runner in
            _ = try await RemuxJob.enqueue(on: runner, itemID: item.id, mode: mode)
        }
    }

    private func runOperation(_ enqueue: @escaping @Sendable (JobRunner) async throws -> Void) {
        let runner = jobRunner
        Task {
            do {
                try await enqueue(runner)
                try await runner.runPending()
            } catch {
                errorMessage = "\(error)"
            }
            refreshAll()
        }
    }
}

extension Notification.Name {
    /// Posted (with libraryID + sender in userInfo) after a BrowseModel
    /// publishes a refresh — how windows over the same library stay in
    /// agreement without sharing a model.
    static let sasLibraryDataChanged = Notification.Name("sasLibraryDataChanged")
}
