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
    var kinds: MediaKinds = .video { didSet { refreshAll() } }
    var filter = MediaFilter() { didSet { refreshItems() } }
    /// The library's named filters, alphabetical — the sidebar's Saved
    /// Filters section.
    private(set) var savedFilters: [SavedFilter] = []
    /// What each saved filter would show, under the CURRENT media kinds —
    /// the number beside its sidebar row.
    private(set) var savedFilterCounts: [UUID: Int] = [:]
    var selectedFolderPath: String?

    /// The offline banner's toggle. It hides items from the LISTING;
    /// `items` stays the full listing so the banner can keep counting
    /// what it hid, which is what makes the state recoverable.
    var hideOfflineItems = false

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
        let library = library, kinds = kinds, fileAccess = fileAccess
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
                        from: try library.folderCounts(kinds: kinds, sourceID: source.id))
                }
                let pending = try library.pendingCandidates().count
                // Every sidebar number in one batch (#96) — the counts
                // and the listing they label share one baseline, so they
                // cannot disagree.
                let counts = try library.browseCounts(kinds: kinds)
                await MainActor.run { [weak self] in
                    guard let self, self.refreshAllGeneration == generation else { return }
                    self.sources = sources
                    self.onlineSourceIDs = onlineIDs
                    self.vocabulary = vocabulary
                    self.savedFilters = (try? library.savedFilters()) ?? []
                    self.refreshSavedFilterCounts()
                    self.tagAliases = aliases
                    self.folderTrees = trees
                    self.counts = counts
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
                        kinds: kinds, filter: filter))
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
                    // Deliberately the SYNCHRONOUS read: we're already on
                    // a detached task (like the item fetch above), and the
                    // explicit closure type sidesteps the async overload's
                    // inference ambiguity on the CI toolchain (Xcode 16).
                    let links: [Row] = try library.writer.read { db -> [Row] in
                        try Row.fetchAll(db, sql: "SELECT mediaItemID, tagID FROM mediaItemTag")
                    }
                    var tagsByItem: [UUID: [UUID]] = [:]
                    for link in links {
                        tagsByItem[link["mediaItemID"] as UUID, default: []]
                            .append(link["tagID"] as UUID)
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
                    self.itemTags = payload.tags
                    self.itemMissingCategories = payload.missingCategories
                    self.duplicateFlaggedIDs = payload.duplicateIDs
                    self.filteredTagCounts = payload.filteredTagCounts
                    self.filteredMissingCounts = payload.filteredMissingCounts
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
            refreshAll()
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
            refreshAll()
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
            refreshAll()
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

    /// The selected items in listing order — the order a queue plays
    /// them in, and the order any bulk action reports.
    var selectedItems: [MediaItem] {
        visibleItems.filter { selection.contains($0.id) }
    }

    /// Mark the selection reviewed. The flag is what the Needs Review
    /// worklist reads, so clearing it here is the same act as clearing
    /// it one item at a time.
    func markSelectionReviewed() {
        let ids = Array(selection)
        do {
            try library.setNeedsReview(ids, false)
            clearSelection()
            refreshAll()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Stage the selection for deletion. This MOVES each file into the
    /// staging folder, exactly as the single-item action does — nothing
    /// is deleted, and Review is where it is undone.
    func markSelectionForDeletion() {
        let items = selectedItems
        do {
            for item in items {
                try library.stage(.toDelete, itemID: item.id)
            }
            clearSelection()
            refreshAll()
        } catch {
            errorMessage = "\(error)"
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
            libraryID: libraryID, itemID: first.id, playlist: items.map(\.id))
        clearSelection()
    }

    /// Apply one tag to everything selected. Goes through `assignTag`,
    /// so a single-select category replaces rather than accumulates —
    /// the rule cannot be skipped by tagging in bulk.
    func applyTagToSelection(_ tagID: UUID) {
        do {
            for id in selection { try library.assignTag(tagID, to: id) }
            refreshAll()
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
        case .folder, .subtree:
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
