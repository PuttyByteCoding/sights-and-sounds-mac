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

    /// Which media kinds this listing includes. Several at once is
    /// allowed and none is not — the guard lives in `MediaKinds` and in
    /// the query, not in whichever view last remembered to apply it.
    /// Changing it writes nothing, so it reloads only what depends on it:
    /// the counts, the trees and the listing — not the sources, their
    /// drives, or the vocabulary.
    var kinds: MediaKinds = .video { didSet { refresh([.counts, .savedFilterCounts, .listing]) } }
    var filter = MediaFilter() { didSet { refreshItems() } }
    /// The library's named filters, alphabetical — the sidebar's Saved
    /// Filters section.
    private(set) var savedFilters: [SavedFilter] = []
    /// What each saved filter would show, under the CURRENT media kinds —
    /// the number beside its sidebar row.
    private(set) var savedFilterCounts: [UUID: Int] = [:]
    /// The tree's selection, read from the filter it lives in — so an
    /// applied saved filter selects its folder, and nothing can drift.
    var selectedFolderPath: String? { filter.treeScope?.path }

    /// True for the row that was clicked: the same path under another
    /// source is a different folder. A filter from before folders knew
    /// their source matches the path wherever it appears, as it lists.
    func isSelectedFolder(_ path: String, in sourceID: UUID) -> Bool {
        guard let scope = filter.treeScope, scope.path == path else { return false }
        return scope.sourceID == nil || scope.sourceID == sourceID
    }

    /// The offline banner's toggle. It hides items from the LISTING;
    /// `items` stays the full listing so the banner can keep counting
    /// what it hid, which is what makes the state recoverable.
    var hideOfflineItems = false { didSet { pruneSelection() } }

    /// The listing's sort. One control orders both the grid and the play
    /// queue.
    ///
    /// Opens on the Settings default rather than a hard-coded path sort.
    /// `.random` mints a fresh seed here, so choosing it means every
    /// window opens on a different deal — which is the point of setting
    /// it: to be shown things you have not seen.
    var ordering: MediaOrdering = AppSettingsStore.shared.current.defaultOrdering.ordering() {
        didSet { refreshItems() }
    }

    /// Shuffle deals with a seed so the order is stable across refreshes;
    /// calling again is a new deal.
    func shuffle() {
        ordering = .random(seed: Int.random(in: 0..<1_000_000_000))
    }

    /// Non-nil while the embedded player has taken over this library's
    /// window; cleared (with a refresh — flags and tags may have changed)
    /// when playback closes.
    var playerRequest: PlayerRequest?

    /// Set by the browse entry points for Tag Analysis: the player is
    /// opened first, and the player view opens the companion as soon as
    /// its model exists, then clears this. The companion needs a player
    /// to follow; a grid has none.
    var pendingAnalysisOpen = false

    /// The item the embedded player is showing, for the Search menu
    /// (spec 17): a player up in this window makes its item the subject,
    /// whatever the grid has selected. Installed by the player.
    var playingItemID: UUID?

    /// The Search menu's subject: the playing item, else a single
    /// selection, else nothing — and the menu is disabled.
    var searchSubject: SearchSubjectRef? {
        let itemID = playingItemID ?? (selection.count == 1 ? selection.first : nil)
        return itemID.map { SearchSubjectRef(libraryID: libraryID, itemID: $0) }
    }

    /// A line the player footer shows for a few seconds — the search
    /// string just copied, or where a web search went.
    private(set) var searchNotice: String?
    private var searchNoticeGeneration = 0

    func showSearchNotice(_ text: String) {
        searchNotice = text
        searchNoticeGeneration += 1
        let generation = searchNoticeGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.searchNoticeGeneration == generation else { return }
            self.searchNotice = nil
        }
    }

    /// Open the player at `itemID` (or the first visible item) with the
    /// companion pending. Nothing to play means nothing to analyse, and
    /// the caller's control stays inert.
    func openPlayerForAnalysis(at itemID: UUID? = nil) {
        let online = visibleItems.filter(isOnline)
        guard let first = itemID.flatMap({ id in online.first { $0.id == id } }) ?? online.first
        else { return }
        pendingAnalysisOpen = true
        playerRequest = PlayerRequest(
            libraryID: libraryID, itemID: first.id,
            definition: .listing(filter: filter, kinds: kinds, ordering: ordering),
            playlist: visibleItems.map(\.id))
    }

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
    /// Every sidebar count — per tag, per source, per empty category, per
    /// status flag — under the listing baseline (kinds, enabled sources,
    /// spent clips) but not under the active filter. One batch in
    /// refreshAll, never a query per row (#96).
    private(set) var counts = BrowseCounts()
    private(set) var onlineSourceIDs: Set<UUID> = []
    /// Something the user asked for did not happen. Shown as a banner over
    /// the grid until dismissed or replaced — never in place of the grid,
    /// and never cleared by a refresh. It used to share one property with
    /// the listing's own failure: the grid was replaced by "Query Failed"
    /// for things that were not queries, and the message vanished on the
    /// next successful listing, a fraction of a second after every write.
    var errorMessage: String? {
        didSet {
            if let errorMessage { AppLog.shared.error("browse", errorMessage) }
        }
    }

    /// The listing (or the sidebar's data) could not be loaded. This one
    /// does replace the grid, and clears itself when a load succeeds.
    private(set) var listingError: String? {
        didSet {
            if let listingError { AppLog.shared.error("browse", listingError) }
        }
    }

    /// Run a write the user asked for from a view. A failure is said on
    /// the error line and stays there; it is never swallowed.
    @discardableResult
    func attempt(_ what: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            errorMessage = "Could not \(what): \(error)"
            return false
        }
    }

    private let fileAccess: any FileAccess
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
    // library. They all follow the library's change hub; see
    // `libraryChanged`.

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
        fileAccess: any FileAccess = LiveFileAccess(),
        onWorkFinished: @escaping () -> Void = {}
    ) {
        self.fileAccess = fileAccess
        self.libraryID = libraryID
        self.library = library
        self.libraryName = (try? library.info()?.name) ?? "Library"
        self.jobRunner = runner
        self.onWorkFinished = onWorkFinished
        refreshAll()

        // Whoever writes — this model, another window, the player, a view
        // with the library in hand, a job — the library says what changed
        // and this window follows. It replaces a broadcast that meant "a
        // browse model refreshed", which the player and the jobs never
        // sent and a kind toggle sent for nothing.
        changeSubscription = library.changes.subscribe { [weak self] change in
            Task { @MainActor in self?.libraryChanged(change) }
        }

        // Mount/unmount drives online-state transitions and wakes the
        // workers — the reachability check stays the fallback truth.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            mountObservers.tokens.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    // A drive appearing or leaving is not a database
                    // change, so the hub says nothing: ask directly, and
                    // only for what a drive can affect.
                    self?.refresh([.sources, .counts, .listing])
                    self?.onWorkFinished()
                }
            })
        }
    }



    /// Everything here runs off the main actor — the source reachability
    /// checks touch the FILESYSTEM, and an offline network volume used to
    /// block the UI for the length of its timeout. Each part has its own
    /// generation, so the last request for that part wins and a slow
    /// sources check cannot overwrite newer counts.
    private var refreshGenerations: [Int: Int] = [:]

    private var changeSubscription: LibraryChangeHub.Subscription?
    private var lastRefreshBegan = ContinuousClock.now

    /// Whoever wrote, reload what the change touches. A refresh that
    /// began after the change's last commit has already read it (the
    /// opening `refreshAll()` racing the first deliveries, say), so that
    /// delivery is skipped.
    private func libraryChanged(_ change: LibraryChange) {
        guard lastRefreshBegan < change.lastCommitAt else { return }
        refresh(BrowseRefresh.parts(for: change.domains))
    }

    /// Everything. For opening a window, and for callers that have not
    /// yet been narrowed.
    func refreshAll() {
        lastRefreshBegan = .now
        refresh(.everything)
    }

    /// Reload just these parts of what the window shows.
    func refresh(_ parts: BrowseRefresh) {
        guard !parts.isEmpty else { return }
        var generations: [Int: Int] = [:]
        for bit in parts.bits {
            refreshGenerations[bit, default: 0] += 1
            generations[bit] = refreshGenerations[bit]
        }
        let library = library, kinds = kinds, fileAccess = fileAccess
        // The trees hang off the enabled sources; when the sources are not
        // being reloaded, the ones already on screen are the ones to use.
        let knownSources = sources
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var loaded = Loaded()
                if parts.contains(.sources) {
                    let sources = try library.sources()
                    loaded.sources = sources
                    loaded.onlineIDs = Set(
                        sources.filter { $0.enabled && $0.isOnline(using: fileAccess) }.map(\.id))
                }
                if parts.contains(.vocabulary) {
                    loaded.vocabulary = try library.vocabulary()
                        .filter { !$0.category.hiddenFromBrowse }
                        .map { CategoryTags(category: $0.category, tags: $0.tags) }
                    loaded.aliases = Dictionary(
                        grouping: try await library.writer.read { try TagAlias.fetchAll($0) },
                        by: \.tagID
                    ).mapValues { $0.map(\.alias) }
                }
                if parts.contains(.counts) {
                    var trees: [UUID: [FolderNode]] = [:]
                    for source in loaded.sources ?? knownSources where source.enabled {
                        trees[source.id] = FolderTreeBuilder.build(
                            from: try library.folderCounts(kinds: kinds, sourceID: source.id))
                    }
                    loaded.trees = trees
                    // Every sidebar number in one batch (#96) — the counts
                    // and the listing they label share one baseline, so
                    // they cannot disagree.
                    loaded.counts = try library.browseCounts(kinds: kinds)
                }
                if parts.contains(.duplicates) {
                    loaded.pendingDuplicates = try library.pendingCandidates().count
                }
                if parts.contains(.savedFilters) {
                    loaded.savedFilters = try library.savedFilters()
                }
                if parts.contains(.menuFacts), !parts.contains(.listing) {
                    // With the listing these ride along in its payload.
                    loaded.hideBlockItemIDs = try library.itemIDsWithHideBlocks()
                    loaded.snapshotRefs = try library.recentSnapshotRefs(perItem: 10)
                }
                let result = loaded
                await MainActor.run { [weak self] in
                    self?.apply(result, parts: parts, generations: generations)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.listingError = "\(error)"
                }
            }
        }
    }

    private struct Loaded: Sendable {
        var sources: [Source]?
        var onlineIDs: Set<UUID>?
        var vocabulary: [CategoryTags]?
        var aliases: [UUID: [String]]?
        var trees: [UUID: [FolderNode]]?
        var counts: BrowseCounts?
        var pendingDuplicates: Int?
        var savedFilters: [SavedFilter]?
        var hideBlockItemIDs: Set<UUID>?
        var snapshotRefs: [UUID: [SnapshotRef]]?
    }

    private func apply(_ loaded: Loaded, parts: BrowseRefresh, generations: [Int: Int]) {
        func current(_ part: BrowseRefresh) -> Bool {
            part.bits.allSatisfy { generations[$0] == refreshGenerations[$0] }
        }
        if current(.sources), let sources = loaded.sources, let onlineIDs = loaded.onlineIDs {
            self.sources = sources
            self.onlineSourceIDs = onlineIDs
        }
        if current(.vocabulary), let vocabulary = loaded.vocabulary, let aliases = loaded.aliases {
            self.vocabulary = vocabulary
            self.tagAliases = aliases
        }
        if current(.counts), let counts = loaded.counts, let trees = loaded.trees {
            self.counts = counts
            self.folderTrees = trees
        }
        if current(.duplicates), let pending = loaded.pendingDuplicates {
            self.pendingDuplicateCount = pending
        }
        if current(.savedFilters), let savedFilters = loaded.savedFilters {
            self.savedFilters = savedFilters
        }
        if current(.menuFacts), let blocks = loaded.hideBlockItemIDs, let snapshots = loaded.snapshotRefs {
            self.hideBlockItemIDs = blocks
            self.snapshotRefs = snapshots
        }
        // After the saved filters themselves, so new ones are counted.
        if parts.contains(.savedFilterCounts) { refreshSavedFilterCounts() }
        if parts.contains(.listing) { refreshItems() }
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
    private(set) var itemTags: [UUID: [TagPill]] = [:]
    private(set) var itemMissingCategories: [UUID: [String]] = [:]
    private(set) var duplicateFlaggedIDs: Set<UUID> = []

    /// Per-tag counts under the ACTIVE filter — "if I added this, how
    /// many would survive". Empty while nothing is filtered, in which
    /// case the sidebar falls back to `counts.byTag`, which answers the
    /// other question: what is behind this tag in the library.
    private(set) var filteredTagCounts: [UUID: Int] = [:]

    /// The `Missing — no <Category> tag` rows under the active filter,
    /// so they narrow with the tags they sit beside instead of staying
    /// on library-wide numbers.
    private(set) var filteredMissingCounts: [UUID: Int] = [:]

    private struct ListingPayload: Sendable {
        var items: [MediaItem]
        var tags: [UUID: [TagPill]]
        var missingCategories: [UUID: [String]]
        var duplicateIDs: Set<UUID>
        var filteredTagCounts: [UUID: Int]
        var filteredMissingCounts: [UUID: Int]
        var hideBlockItemIDs: Set<UUID>
        var snapshotRefs: [UUID: [SnapshotRef]]
    }

    /// Everything a tile needs about one item that is not on its row.
    func tileContext(for item: MediaItem) -> TileContext {
        TileContext(
            isOnline: isOnline(item),
            sourceName: source(for: item)?.name,
            tags: itemTags[item.id] ?? [],
            missingCategories: itemMissingCategories[item.id] ?? [],
            isDuplicate: duplicateFlaggedIDs.contains(item.id))
    }

    func refreshItems() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let library = library, filter = filter, kinds = kinds, ordering = ordering
        let grid = GridDisplaySettings.shared.grid
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<ListingPayload, Error>
            // Timed because how the grid should react to a filter change
            // depends on how long the query actually takes, and that is a
            // fact about a real library rather than a guess. Debug level:
            // it is diagnostic, and the Log window can filter to it.
            let started = ContinuousClock.now
            do {
                let rows = try library.mediaItems(
                    matching: filter, kinds: kinds, orderedBy: ordering)
                // Both components: `attoseconds` carries only the
                // sub-second remainder, so seconds must be added or a
                // 1.5s query reports as 500ms — the exact case worth
                // knowing about.
                let took = started.duration(to: .now).components
                let elapsed = Double(took.seconds) * 1000
                    + Double(took.attoseconds) / 1e15
                AppLog.shared.debug(
                    "browse",
                    "listing query \(String(format: "%.1f", elapsed))ms — \(rows.count) items")
                var payload = ListingPayload(
                    items: rows, tags: [:], missingCategories: [:], duplicateIDs: [],
                    // Faceted counts ride along with the listing they
                    // describe, on the same generation — so the numbers
                    // and the grid can never be from different filters.
                    filteredTagCounts: try library.filteredTagCounts(
                        kinds: kinds, filter: filter),
                    filteredMissingCounts: try library.filteredMissingCategoryCounts(
                        kinds: kinds, filter: filter),
                    // What the tiles' context menus ask about, fetched
                    // here once: a menu's items are built every time a
                    // tile's body runs, so asking there is a read per
                    // tile per render, on the main thread.
                    hideBlockItemIDs: try library.itemIDsWithHideBlocks(),
                    snapshotRefs: try library.recentSnapshotRefs(perItem: 10))
                if grid.needsTagData {
                    let vocabulary = try library.vocabulary()
                        .filter { !$0.category.hiddenFromBrowse }
                    // Category order decides pill order, so a tile reads
                    // Band · Venue · Year the way the sidebar lists them.
                    var categoryRank: [UUID: Int] = [:]
                    var tagInfo: [UUID: TagPill] = [:]
                    for (rank, entry) in vocabulary.enumerated() {
                        categoryRank[entry.category.id] = rank
                        for tag in entry.tags {
                            tagInfo[tag.id] = TagPill(
                                id: tag.id, name: tag.name, categoryID: entry.category.id,
                                categoryName: entry.category.name,
                                colorIndex: entry.category.colorIndex)
                        }
                    }
                    // The ids leave the closure, never the rows: `Row` is
                    // not Sendable, and Swift 6.4 resolves a read inside an
                    // async context to the async overload. The explicit
                    // closure type keeps the older CI toolchain's inference
                    // unambiguous.
                    let links = try await library.writer.read { db -> [(item: UUID, tag: UUID)] in
                        try Row.fetchAll(db, sql: "SELECT mediaItemID, tagID FROM mediaItemTag")
                            .map { (item: $0["mediaItemID"], tag: $0["tagID"]) }
                    }
                    var tagsByItem: [UUID: [UUID]] = [:]
                    for link in links {
                        tagsByItem[link.item, default: []].append(link.tag)
                    }
                    for item in rows {
                        let tagIDs = tagsByItem[item.id] ?? []
                        payload.tags[item.id] = tagIDs
                            .compactMap { tagInfo[$0] }
                            .sorted {
                                (categoryRank[$0.categoryID] ?? 0, $0.name)
                                    < (categoryRank[$1.categoryID] ?? 0, $1.name)
                            }
                        let covered = Set(tagIDs.compactMap { tagInfo[$0]?.categoryID })
                        payload.missingCategories[item.id] = vocabulary
                            .filter { !covered.contains($0.category.id) }
                            .map(\.category.name)
                    }
                }
                if grid.needsDuplicateData {
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
                    self.pruneSelection()
                    self.itemTags = payload.tags
                    self.itemMissingCategories = payload.missingCategories
                    self.duplicateFlaggedIDs = payload.duplicateIDs
                    self.filteredTagCounts = payload.filteredTagCounts
                    self.filteredMissingCounts = payload.filteredMissingCounts
                    self.hideBlockItemIDs = payload.hideBlockItemIDs
                    self.snapshotRefs = payload.snapshotRefs
                    self.listingError = nil
                case .failure(let error):
                    self.listingError = "\(error)"
                }
            }
        }
    }

    // MARK: - Sidebar actions

    func selectFolder(_ path: String?, in sourceID: UUID? = nil) {
        filter.selectSubtree(path, sourceID: sourceID)
    }

    func clearFilter() {
        searchDebounce?.cancel()
        searchDisplayText = ""
        filter = MediaFilter()
    }

    /// Turn a media kind on or off. Returns false when the click was
    /// refused because it was the last kind selected — the sidebar says
    /// so rather than appearing to have ignored it.
    @discardableResult
    func toggleKind(_ kind: MediaKind) -> Bool {
        var updated = kinds
        guard updated.toggle(kind) else { return false }
        kinds = updated
        return true
    }

    /// Rename a source. The name is a label only — the library keys off
    /// `id` and finds files by `rootPath` — so this touches nothing but
    /// what the sidebar draws.
    ///
    /// Trimmed, and an empty name is refused rather than written: a
    /// source with no name is a row you cannot tell from its neighbour,
    /// and `rootPath` is a tooltip rather than something you can read at
    /// a glance. Duplicates ARE allowed: the schema does not make the
    /// name unique, two folders can honestly have the same name, and the
    /// path in the tooltip is what tells them apart.
    func renameSource(_ source: Source, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != source.name else { return }
        do {
            try library.writer.write { db in
                var updated = source
                updated.name = name
                try updated.update(db)
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Saved filters

    /// One count query per saved filter, off the main actor — a handful
    /// of indexed counts, recomputed whenever the vocabulary refresh
    /// runs so tagging keeps the numbers honest.
    func refreshSavedFilterCounts() {
        let library = library, kinds = kinds, filters = savedFilters
        Task {
            let counts = await Task.detached(priority: .utility) { () -> [UUID: Int] in
                var counts: [UUID: Int] = [:]
                for saved in filters {
                    guard let filter = saved.filter else { continue }
                    counts[saved.id] = (try? library.mediaItemCount(
                        matching: filter, kinds: kinds)) ?? 0
                }
                return counts
            }.value
            self.savedFilterCounts = counts
        }
    }

    func saveCurrentFilter(named name: String) {
        do {
            _ = try library.saveFilter(named: name, filter)
            savedFilters = (try? library.savedFilters()) ?? savedFilters
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Apply a saved filter — wholesale, replacing the current one. A
    /// merge would be quieter and also unpredictable; applying a named
    /// filter means "show me THAT".
    func applySavedFilter(_ saved: SavedFilter) {
        guard let decoded = saved.filter else {
            errorMessage = "This saved filter could not be read."
            return
        }
        filter = decoded
    }

    /// Make a saved filter mean what is on screen now. Counts follow on
    /// the next refresh, so the sidebar's number changes with it.
    func updateSavedFilter(_ saved: SavedFilter) {
        do {
            try library.updateSavedFilter(saved.id, to: filter)
            savedFilters = (try? library.savedFilters()) ?? savedFilters
        } catch {
            errorMessage = "\(error)"
        }
    }

    func renameSavedFilter(_ saved: SavedFilter, to name: String) {
        do {
            try library.renameSavedFilter(saved.id, to: name)
            savedFilters = (try? library.savedFilters()) ?? savedFilters
        } catch {
            errorMessage = "\(error)"
        }
    }

    func deleteSavedFilter(_ saved: SavedFilter) {
        do {
            try library.deleteSavedFilter(saved.id)
            savedFilters.removeAll { $0.id == saved.id }
        } catch {
            errorMessage = "\(error)"
        }
    }

    func setSourceEnabled(_ source: Source, _ enabled: Bool) {
        do {
            try library.writer.write { db in
                var updated = source
                updated.enabled = enabled
                try updated.update(db)
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Sources & import

    @discardableResult
    func addSource(at url: URL) -> Source? {
        do {
            let source = Source(name: url.lastPathComponent, rootPath: url.path)
            try library.writer.write { try source.insert($0) }
            return source
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    /// Scan a source and import everything new under it, unreviewed.
    ///
    /// This is the whole-source path — "Scan" from a source row, or a
    /// mount waking up. Reviewing a list before anything enters the
    /// library is the Import window's job; this one is for when you
    /// already know what is on the drive.
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

    // MARK: - Selection

    /// The tiles picked out for a bulk action. Held here rather than in
    /// the grid view so the bulk bar, the queue and the context menu all
    /// read one answer.
    private(set) var selection: Set<UUID> = []
    /// Where a shift-click measures from.
    private var selectionAnchor: UUID?

    /// A click on a tile. ⌘ or ⇧ starts a selection; once one exists,
    /// plain clicks extend it — the modifier is for getting in, not for
    /// staying in.
    func click(_ itemID: UUID, extend: Bool, range: Bool) {
        let listing = visibleItems.map(\.id)
        if range, let anchor = selectionAnchor,
           let from = listing.firstIndex(of: anchor),
           let to = listing.firstIndex(of: itemID) {
            selection.formUnion(listing[min(from, to)...max(from, to)])
            return
        }
        guard extend || !selection.isEmpty else { return }
        if selection.contains(itemID) {
            selection.remove(itemID)
        } else {
            selection.insert(itemID)
            selectionAnchor = itemID
        }
    }

    func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

    /// The selection is what is ticked AND on screen. Called whenever the
    /// listing changes, so "N selected" and every bulk action agree: a
    /// selection that outlived its listing had the bar counting items the
    /// grid no longer showed, Delete acting on the visible few, and Add
    /// Tag acting on all of them.
    private func pruneSelection() {
        if let focused = focusedItemID, !visibleItems.contains(where: { $0.id == focused }) {
            focusedItemID = nil
        }
        guard !selection.isEmpty else { return }
        selection.formIntersection(visibleItems.map(\.id))
        if let anchor = selectionAnchor, !selection.contains(anchor) { selectionAnchor = nil }
    }

    // MARK: - Keyboard focus

    /// The tile the keyboard is on. Separate from the selection: moving
    /// through the grid must not tick everything it passes.
    private(set) var focusedItemID: UUID?

    func moveFocus(_ move: GridFocusMove, columns: Int) {
        let ids = visibleItems.map(\.id)
        let current = focusedItemID.flatMap { ids.firstIndex(of: $0) }
        guard let next = GridFocus.index(after: move, from: current, count: ids.count, columns: columns)
        else { return }
        focusedItemID = ids[next]
    }

    func toggleSelectionOfFocusedItem() {
        guard let id = focusedItemID else { return }
        click(id, extend: true, range: false)
    }

    /// Play from this item, with the listing as the queue.
    func play(_ item: MediaItem) {
        guard isOnline(item) else { return }
        playerRequest = PlayerRequest(
            libraryID: libraryID, itemID: item.id,
            definition: .listing(filter: filter, kinds: kinds, ordering: ordering),
            playlist: visibleItems.map(\.id))
    }

    func playFocusedItem() {
        guard let id = focusedItemID, let item = visibleItems.first(where: { $0.id == id }) else { return }
        play(item)
    }

    /// The selected items in listing order — the order a queue plays
    /// them in, and the order any bulk action reports.
    var selectedItems: [MediaItem] {
        visibleItems.filter { selection.contains($0.id) }
    }

    /// Mark the selection reviewed. The flag is what the Needs Review
    /// worklist reads, so clearing it here is the same act as clearing
    /// it one item at a time.
    func markSelectionReviewed() {
        let ids = selectedItems.map(\.id)
        do {
            try library.setNeedsReview(ids, false)
            clearSelection()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Stage the selection for deletion. This MOVES each file into the
    /// staging folder, exactly as the single-item action does — nothing
    /// is deleted, and Review is where it is undone.
    func markSelectionForDeletion() {
        let items = selectedItems
        // Each item is a file move, so this cannot be one transaction.
        // What it can be is honest: carry on past a failure, always
        // refresh so the grid shows what did happen, and say what did not.
        // And off the main actor: a selection of a few hundred on a
        // networked drive is a few hundred file moves.
        let library = library
        clearSelection()
        Task {
            let failures = await Task.detached(priority: .userInitiated) { () -> [String] in
                var failures: [String] = []
                for item in items {
                    do {
                        try library.stage(.toDelete, itemID: item.id)
                    } catch {
                        failures.append("\(item.fileName): \(error)")
                    }
                }
                return failures
            }.value
            if let first = failures.first {
                errorMessage = failures.count == 1
                    ? "Could not mark \(first)"
                    : "\(failures.count) of \(items.count) could not be marked. First: \(first)"
            }
        }
    }

    /// Play the selection, in listing order.
    func queueSelection() {
        let items = selectedItems.filter(isOnline)
        guard let first = items.first else {
            errorMessage = "Every selected item is on an offline source."
            return
        }
        playerRequest = PlayerRequest(
            libraryID: libraryID, itemID: first.id, playlist: items.map(\.id), name: "Selection")
        clearSelection()
    }

    /// Apply one tag to everything selected. Goes through `assignTag`,
    /// so a single-select category replaces rather than accumulates —
    /// the rule cannot be skipped by tagging in bulk.
    func applyTagToSelection(_ tagID: UUID) {
        do {
            // One transaction in the kit: the bulk edit lands whole or
            // not at all.
            try library.assignTag(tagID, to: selectedItems.map(\.id))
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Command palette

    /// The commands last run here, most recent first. Empty means the
    /// palette lists everything; a palette that rewards the SECOND use
    /// of a command is the point of remembering.
    private(set) var paletteRecents: [String] = []

    func rememberPaletteCommand(_ id: String) {
        paletteRecents.removeAll { $0 == id }
        paletteRecents.insert(id, at: 0)
        if paletteRecents.count > 8 { paletteRecents.removeLast() }
    }

    /// How a filter term reads on a chip: the group it came from, and
    /// the value. Two halves because a tag name alone is ambiguous —
    /// "1995" could be a Year or a Venue — and the chip bar is read at a
    /// glance, away from the sidebar row that set it.
    func chipLabel(for term: FilterTerm) -> (group: String, value: String)? {
        switch term {
        case .tag(let id):
            for entry in vocabulary {
                if let tag = entry.tags.first(where: { $0.id == id }) {
                    return (entry.category.name, tag.name)
                }
            }
            return nil
        case .missingCategory(let id):
            guard let entry = vocabulary.first(where: { $0.category.id == id })
            else { return nil }
            return (entry.category.name, "Missing")
        case .status(let flag):
            return ("Status", flag.displayName)
        case .folder, .subtree, .source:
            return nil
        }
    }

    // MARK: - Offline items

    /// The listing the grid draws: `items`, minus the offline ones while
    /// the banner's toggle is on. Playback queues follow this, not
    /// `items` — the queue is what you can see.
    var visibleItems: [MediaItem] {
        hideOfflineItems ? items.filter(isOnline) : items
    }

    /// Items in the full listing whose source is offline. Counted against
    /// the listing BEFORE the toggle, so hiding them does not make the
    /// banner forget how many it hid.
    var offlineItems: [MediaItem] {
        items.filter { !isOnline($0) }
    }

    /// The offline sources represented in the listing, listed the way the
    /// banner names them.
    var offlineSourceNames: [String] {
        let ids = Set(offlineItems.map(\.sourceID))
        return sources.filter { ids.contains($0.id) }.map(\.name)
    }

    /// Absolute file URL (an embedded clip resolves to its parent's
    /// file), or nil while the item's source is offline.
    func fileURL(for item: MediaItem) -> URL? {
        (try? library.resolvedFileURL(for: item, fileAccess: fileAccess)) ?? nil
    }

    /// The same lookup as something that can be handed off and run
    /// later, away from the main actor — what a thumbnail request takes,
    /// so a tile never pays for database reads and a reachability check
    /// just to find its thumbnail was cached all along.
    func fileResolver(for item: MediaItem) -> @Sendable () -> URL? {
        let library = library, fileAccess = fileAccess
        return { (try? library.resolvedFileURL(for: item, fileAccess: fileAccess)) ?? nil }
    }

    // MARK: - Operations

    /// Save segments as files of their own — what the delete list offers
    /// before it will purge the video they play from.
    func saveSegmentsAsFiles(_ segmentIDs: [UUID]) {
        runOperation { runner in
            for id in segmentIDs { _ = try await ClipExportJob.enqueue(on: runner, clipID: id) }
        }
    }

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

    /// Filled with each listing; see `ListingPayload`.
    private var hideBlockItemIDs: Set<UUID> = []
    private var snapshotRefs: [UUID: [SnapshotRef]] = [:]

    func hasHideBlocks(_ item: MediaItem) -> Bool {
        hideBlockItemIDs.contains(item.id)
    }

    func scanText(_ item: MediaItem) {
        runOperation { runner in
            _ = try await OcrJob.enqueue(on: runner, itemID: item.id)
        }
    }

    /// The same OCR scan, with a completion — Tag Analysis reloads its
    /// evidence when the scan lands rather than waiting for a broadcast.
    func scanText(itemID: UUID, then finished: @escaping @MainActor @Sendable () -> Void) {
        let runner = jobRunner
        Task {
            do {
                _ = try await OcrJob.enqueue(on: runner, itemID: itemID)
                try await runner.runPending()
            } catch {
                errorMessage = "\(error)"
            }
            finished()
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

    func snapshots(of itemID: UUID) -> [SnapshotRef] {
        snapshotRefs[itemID] ?? []
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

    /// Sweep embedded metadata into `embeddedMetadataPair` — the tag
    /// analysis queue's largest source, and the only one that needs a
    /// pass over the files rather than a query.
    ///
    /// `enqueueUnlessPending` rather than `enqueue`: the button is a
    /// signal, not a command to run another sweep, and a second row would
    /// re-probe every file the first is already probing.
    func sweepMetadata(
        itemIDs: [UUID]? = nil, then finished: @escaping @MainActor @Sendable () -> Void
    ) {
        let runner = jobRunner
        Task {
            do {
                if let itemIDs {
                    // Scoped: plain enqueue — dedupe is by kind, and a
                    // pending library sweep must not swallow the small
                    // one the operator is waiting on.
                    _ = try await MetadataSweepJob.enqueue(on: runner, itemIDs: itemIDs)
                } else {
                    _ = try await runner.enqueueUnlessPending(MetadataSweepJob.self)
                }
                try await runner.runPending()
            } catch {
                errorMessage = "\(error)"
            }
            finished()
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
        }
    }
}

/// The parts of a browse window that can be reloaded on their own.
struct BrowseRefresh: OptionSet, Sendable, Hashable {
    let rawValue: Int

    /// Sources and whether each one's drive is there (a filesystem check).
    static let sources = BrowseRefresh(rawValue: 1 << 0)
    /// Categories, tags and aliases.
    static let vocabulary = BrowseRefresh(rawValue: 1 << 1)
    /// Every sidebar number, and the folder trees.
    static let counts = BrowseRefresh(rawValue: 1 << 2)
    static let savedFilters = BrowseRefresh(rawValue: 1 << 3)
    static let savedFilterCounts = BrowseRefresh(rawValue: 1 << 4)
    /// The pending-duplicates badge.
    static let duplicates = BrowseRefresh(rawValue: 1 << 5)
    /// The grid: items, their pills, faceted counts, duplicate flags.
    static let listing = BrowseRefresh(rawValue: 1 << 6)
    /// What the tile menus ask about: hide blocks and tag snapshots.
    static let menuFacts = BrowseRefresh(rawValue: 1 << 7)

    static let everything: BrowseRefresh = [
        .sources, .vocabulary, .counts, .savedFilters, .savedFilterCounts, .duplicates, .listing, .menuFacts,
    ]

    var bits: [Int] { (0..<8).filter { rawValue & (1 << $0) != 0 } }

    /// What a change in the library can affect on screen. Erring wide is
    /// a wasted query; erring narrow is a stale window — so where a
    /// domain could plausibly matter, it is included.
    static func parts(for domains: Set<LibraryChangeDomain>) -> BrowseRefresh {
        var parts: BrowseRefresh = []
        for domain in domains {
            switch domain {
            case .items, .tagging:
                parts.formUnion([.counts, .savedFilterCounts, .listing])
            case .vocabulary:
                // A rename, a hidden-by-default flag, a new category:
                // names, counts and which items are listed.
                parts.formUnion([.vocabulary, .counts, .listing])
            case .sources:
                // Enabling or disabling a source changes every listing.
                parts.formUnion([.sources, .counts, .savedFilterCounts, .listing])
            case .savedFilters:
                parts.formUnion([.savedFilters, .savedFilterCounts])
            case .duplicates:
                parts.formUnion([.duplicates, .listing])
            case .itemDetails:
                parts.formUnion(.menuFacts)
            }
        }
        return parts
    }
}

enum GridFocusMove: Sendable { case left, right, up, down }

/// Where an arrow key takes the grid's focus. Pure, so the rule can be
/// tested without a window.
enum GridFocus {
    /// nil focus, or one that is no longer in the listing, starts at the
    /// first tile. Left and right walk the listing and stop at its ends;
    /// up and down keep the column, and going down into a ragged last row
    /// that has no tile in this column takes the last tile instead.
    static func index(after move: GridFocusMove, from current: Int?, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0, current < count else { return 0 }
        let columns = max(1, columns)
        switch move {
        case .left: return max(0, current - 1)
        case .right: return min(count - 1, current + 1)
        case .up: return current - columns >= 0 ? current - columns : current
        case .down:
            if current + columns < count { return current + columns }
            let lastRowStart = ((count - 1) / columns) * columns
            return current < lastRowStart ? count - 1 : current
        }
    }

    /// How many columns the adaptive grid lays out at this width: the
    /// same arithmetic as `LazyVGrid`'s — 16 pt of padding each side,
    /// 16 pt between tiles, tiles no narrower than the chosen size.
    static func columns(width: CGFloat, tileMinimum: CGFloat) -> Int {
        let padding: CGFloat = 16, spacing: CGFloat = 16
        let available = width - padding * 2
        guard tileMinimum > 0, available > 0 else { return 1 }
        return max(1, Int((available + spacing) / (tileMinimum + spacing)))
    }
}

