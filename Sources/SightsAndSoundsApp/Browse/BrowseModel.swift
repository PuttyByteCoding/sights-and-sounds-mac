import Foundation
import GRDB
import SwiftUI
import SightsAndSoundsKit

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
    var hideOfflineItems = false { didSet { relist(); pruneSelection() } }

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

    /// The request that opens an auxiliary window from this listing. The
    /// windows that act on "the filtered items" carry them along.
    func auxRequest(_ kind: AuxWindowRequest.Kind) -> AuxWindowRequest {
        var request = AuxWindowRequest(libraryID: libraryID, kind: kind)
        // Organise plans over its own listing when it has no list, and
        // unfiltered, video-only and hiding nothing, that listing IS the
        // grid's — so it is sent a list only when something narrows the
        // grid (the list is the window's identity and saved state, and an
        // unfiltered library put every id into both). Maintenance's
        // write-back takes no list to mean every item of every kind, so it
        // always gets the grid's items.
        let narrowed = !filter.isEmpty || kinds != .video || hideOfflineItems
        if kind == .maintenance || (kind == .organise && narrowed) {
            request.scopeItemIDs = visibleItems.map(\.id)
        }
        return request
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

    private(set) var items: [MediaItem] = [] { didSet { relist() } }
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
    private(set) var onlineSourceIDs: Set<UUID> = [] { didSet { relist() } }
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

    /// What this window asks of its library. The reads and writes are
    /// moving onto it from `library` a group at a time; once they all
    /// have, a window can be given a library held by another Mac.
    let service: any LibraryService
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

    /// The thumbnail sweep's live progress for this library — non-nil
    /// only while a sweep is queued or running. Read by the footer bar
    /// under the grid; counts come from the job row and thumbnailState,
    /// the sweep's own progress bookkeeping, never re-derived from disk.
    typealias ThumbnailQueueStatus = SightsAndSoundsKit.ThumbnailQueueStatus
    private(set) var thumbnailQueue: ThumbnailQueueStatus?

    /// Poll while the browse UI is on screen — the view owns the task,
    /// so nothing runs while the player has the window or after close.
    /// Same one-second cadence as the tasks dashboard; two cheap reads.
    func watchThumbnailQueue() async {
        let service = service
        while !Task.isCancelled {
            // A read that fails shows no progress line, as it always has.
            thumbnailQueue = (try? await service.thumbnailQueueStatus()) ?? nil
            try? await Task.sleep(for: .seconds(1))
        }
    }

    init(
        libraryID: UUID, library: LibraryDatabase, runner: JobRunner,
        fileAccess: any FileAccess = LiveFileAccess(),
        service: (any LibraryService)? = nil,
        onWorkFinished: @escaping () -> Void = {}
    ) {
        self.libraryID = libraryID
        self.library = library
        self.libraryName = (try? library.info()?.name) ?? "Library"
        // Given one, the window asks that; given none, it asks the
        // library on this Mac.
        self.service = service
            ?? LocalLibraryService(library: library, runner: runner, fileAccess: fileAccess)
        self.onWorkFinished = onWorkFinished
        refreshAll()

        // Whoever writes — this model, another window, the player, a view
        // with the library in hand, a job — the library says what changed
        // and this window follows. It replaces a broadcast that meant "a
        // browse model refreshed", which the player and the jobs never
        // sent and a kind toggle sent for nothing.
        let changes = self.service.changes()
        changeWatch.task = Task { [weak self] in
            for await change in changes { self?.libraryChanged(change) }
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

    /// The task reading the service's change stream, cancelled with the
    /// model: held in a bag whose own deinit cancels it, like the mount
    /// observers, so nothing actor-isolated is touched in a deinit.
    private final class ChangeWatch: @unchecked Sendable {
        var task: Task<Void, Never>?
        deinit { task?.cancel() }
    }
    private let changeWatch = ChangeWatch()

    /// How many hub deliveries have touched each domain. The windows that
    /// keep reads of their own — Tag Manager, Review, Maintenance,
    /// Organise — reload when the domains they show change, which is how
    /// a write made anywhere else reaches them.
    private(set) var changeCounts: [LibraryChangeDomain: Int] = [:]

    func changeCount(_ domains: Set<LibraryChangeDomain>) -> Int {
        domains.reduce(0) { $0 &+ changeCounts[$1, default: 0] }
    }
    private var lastRefreshBegan = ContinuousClock.now

    /// Whoever wrote, reload what the change touches. A refresh that
    /// began after the change's last commit has already read it (the
    /// opening `refreshAll()` racing the first deliveries, say), so that
    /// delivery is skipped.
    private func libraryChanged(_ change: LibraryChange) {
        for domain in change.domains { changeCounts[domain, default: 0] &+= 1 }
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
        let service = service, kinds = kinds
        Task.detached(priority: .userInitiated) { [weak self] in
            // Each part loads on its own. They shared one `do`: a throw
            // in any of them (the saved filters, the duplicate count)
            // skipped applying ALL of them, left the listing unloaded and
            // put "Query Failed" in place of the grid for something that
            // was not the listing. Now a part that fails keeps what is on
            // screen and says so on the error line; the listing's own
            // failure is still the listing's.
            var loaded = Loaded()
            var failures: [String] = []
            if parts.contains(.sources) {
                do {
                    let states = try await service.sourceStates()
                    loaded.sources = states.map(\.source)
                    loaded.onlineIDs = Set(states.filter(\.isOnline).map(\.id))
                } catch { failures.append("sources: \(error)") }
            }
            if parts.contains(.vocabulary) {
                do {
                    let vocabulary = try await service.browseVocabulary()
                    loaded.vocabulary = vocabulary.categories
                    loaded.aliases = vocabulary.aliases
                } catch { failures.append("tags: \(error)") }
            }
            if parts.contains(.counts) {
                do {
                    // The trees and every sidebar number in one answer
                    // (#96) — the counts and the listing they label share
                    // one baseline, so they cannot disagree.
                    let sidebar = try await service.sidebarCounts(kinds: kinds)
                    loaded.trees = sidebar.trees
                    loaded.counts = sidebar.counts
                } catch { failures.append("counts: \(error)") }
            }
            if parts.contains(.duplicates) {
                do { loaded.pendingDuplicates = try await service.pendingDuplicateCount() }
                catch { failures.append("duplicates: \(error)") }
            }
            if parts.contains(.savedFilters) {
                do { loaded.savedFilters = try await service.savedFilters() }
                catch { failures.append("saved filters: \(error)") }
            }
            if parts.contains(.menuFacts), !parts.contains(.listing) {
                // With the listing these ride along in its payload.
                do {
                    let facts = try await service.tileMenuFacts(snapshotsPerItem: 10)
                    loaded.hideBlockItemIDs = facts.hideBlockItemIDs
                    loaded.snapshotRefs = facts.snapshotRefs
                } catch { failures.append("item details: \(error)") }
            }
            let result = loaded, failed = failures
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apply(result, parts: parts, generations: generations)
                if !failed.isEmpty {
                    self.errorMessage = "Part of the sidebar could not be loaded — "
                        + failed.joined(separator: "; ")
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
        let service = service
        let grid = GridDisplaySettings.shared.grid
        // The faceted counts and the tile menus' facts ride along with
        // the listing they describe, on the same generation — so the
        // numbers and the grid can never be from different filters.
        let request = ListingRequest(
            filter: filter, kinds: kinds, ordering: ordering,
            includesTagData: grid.needsTagData, includesDuplicateData: grid.needsDuplicateData,
            snapshotsPerItem: 10)
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<BrowseListingAnswer, Error>
            do {
                outcome = .success(try await service.listing(request))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                switch outcome {
                case .success(let answer):
                    self.items = answer.items
                    self.pruneSelection()
                    self.itemTags = answer.tags
                    self.itemMissingCategories = answer.missingCategories
                    self.duplicateFlaggedIDs = answer.duplicateIDs
                    self.filteredTagCounts = answer.filteredTagCounts
                    self.filteredMissingCounts = answer.filteredMissingCounts
                    self.hideBlockItemIDs = answer.menuFacts.hideBlockItemIDs
                    self.snapshotRefs = answer.menuFacts.snapshotRefs
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
    func renameSource(_ source: Source, to rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != source.name else { return }
        await write { try await $0.renameSource(source.id, to: name) }
    }

    // MARK: - Writes

    /// This window's writes, in the order they were asked for.
    private let writes = WriteQueue()

    /// Send one write to the service, after every write this window
    /// asked for before it. Returns what the write returned, or nil —
    /// with the reason on the error line — when it failed.
    @discardableResult
    private func write<T: Sendable>(
        orSay describe: (any Error) -> String = { "\($0)" },
        _ work: @escaping @Sendable (any LibraryService) async throws -> T
    ) async -> T? {
        let service = service
        switch await writes.run({ try await work(service) }) {
        case .success(let value):
            return value
        case .failure(let error):
            errorMessage = describe(error)
            return nil
        }
    }

    /// The library's saved filters, re-read after this window changed
    /// them, so the list is current when the call that changed it
    /// returns. A read that fails keeps the list on screen.
    private func reloadSavedFilters() async {
        savedFilters = (try? await service.savedFilters()) ?? savedFilters
    }

    // MARK: - Saved filters

    /// One count query per saved filter, off the main actor — a handful
    /// of indexed counts, recomputed whenever the vocabulary refresh
    /// runs so tagging keeps the numbers honest.
    func refreshSavedFilterCounts() {
        let service = service, kinds = kinds
        Task {
            let counts = await Task.detached(priority: .utility) {
                try? await service.savedFilterCounts(kinds: kinds)
            }.value
            // Counts that could not be read leave the ones on screen.
            if let counts { self.savedFilterCounts = counts }
        }
    }

    func saveCurrentFilter(named name: String) async {
        let filter = filter
        guard await write({ try await $0.saveFilter(named: name, filter) }) != nil else { return }
        await reloadSavedFilters()
    }

    /// Apply a saved filter — wholesale, replacing the current one. A
    /// merge would be quieter and also unpredictable; applying a named
    /// filter means "show me THAT".
    func applySavedFilter(_ saved: SavedFilter) {
        guard let decoded = saved.filter else {
            errorMessage = "This saved filter could not be read."
            return
        }
        // The field shows the saved filter's text, and a keystroke still
        // inside its pause must not land on top of it afterwards.
        searchDebounce?.cancel()
        searchDisplayText = decoded.searchText
        filter = decoded
    }

    /// Make a saved filter mean what is on screen now. Counts follow on
    /// the next refresh, so the sidebar's number changes with it.
    func updateSavedFilter(_ saved: SavedFilter) async {
        let filter = filter
        guard await write({ try await $0.updateSavedFilter(saved.id, to: filter) }) != nil else { return }
        await reloadSavedFilters()
    }

    func renameSavedFilter(_ saved: SavedFilter, to name: String) async {
        guard await write({ try await $0.renameSavedFilter(saved.id, to: name) }) != nil else { return }
        await reloadSavedFilters()
    }

    func deleteSavedFilter(_ saved: SavedFilter) async {
        guard await write({ try await $0.deleteSavedFilter(saved.id) }) != nil else { return }
        savedFilters.removeAll { $0.id == saved.id }
    }

    func setSourceEnabled(_ source: Source, _ enabled: Bool) async {
        await write { try await $0.setSourceEnabled(source.id, enabled) }
    }

    // MARK: - Sources & import

    @discardableResult
    /// Register a folder as a source; refused, with the reason shown, when
    /// it already is one or overlaps one.
    func addSource(at url: URL) async -> Source? {
        let name = url.lastPathComponent, path = url.path
        return await write(orSay: { "Could not add \(name): \($0)" }) {
            try await $0.addSource(named: name, rootPath: path)
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

    /// A click on a tile ticks it, and a second click unticks it: the
    /// grid selects like a photo picker, not like a list, because what a
    /// selection is for here is doing one thing to many. ⇧-click ticks
    /// the run from the last tick to this one. ⌘ is accepted and means
    /// the same as a plain click, for hands that reach for it. Double-
    /// click plays; Esc clears.
    ///
    /// It used to take ⌘ or ⇧ to start a selection, with plain clicks
    /// extending one already begun. Nobody found the way in.
    func click(_ itemID: UUID, extend: Bool, range: Bool) {
        let listing = visibleItems.map(\.id)
        if range, let anchor = selectionAnchor,
           let from = listing.firstIndex(of: anchor),
           let to = listing.firstIndex(of: itemID) {
            selection.formUnion(listing[min(from, to)...max(from, to)])
            return
        }
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

    /// ⌘A: everything the grid shows. Items hidden by the offline toggle
    /// are not shown, so they are not selected behind the user's back.
    func selectAll() {
        selection = Set(visibleItems.map(\.id))
        selectionAnchor = visibleItems.first?.id
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

    /// Put the keyboard's focus on one tile.
    func moveFocus(to itemID: UUID) {
        guard visibleItems.contains(where: { $0.id == itemID }) else { return }
        focusedItemID = itemID
    }

    /// Space: what Quick Look shows — the selection in listing order,
    /// opened at the focused tile when that is part of it; with nothing
    /// selected, the focused tile. Offline files cannot be shown and are
    /// left out. Nil when there is nothing to show.
    func quickLookTarget() -> (current: URL, all: [URL])? {
        let chosen = selectedItems.isEmpty
            ? visibleItems.filter { $0.id == focusedItemID }
            : selectedItems
        let shown = chosen.compactMap { item in fileURL(for: item).map { (item.id, $0) } }
        guard !shown.isEmpty else { return nil }
        let current = shown.first { $0.0 == focusedItemID }?.1 ?? shown[0].1
        return (current, shown.map(\.1))
    }

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
    ///
    /// Found through the index: the cost is the selection's size, not the
    /// listing's — a tile's context menu asks on every render.
    var selectedItems: [MediaItem] {
        selection.compactMap { visibleIndexByID[$0] }.sorted().map { visibleItems[$0] }
    }

    /// Mark the selection reviewed. The flag is what the Needs Review
    /// worklist reads, so clearing it here is the same act as clearing
    /// it one item at a time.
    func markSelectionReviewed() async {
        let ids = selectedItems.map(\.id)
        // Cleared once the write has landed, not before: a selection
        // cleared for an action that then failed would have to be made
        // again to retry it.
        guard await write({ try await $0.setNeedsReview(ids, false) }) != nil else { return }
        clearSelection()
    }

    /// Stage the selection for deletion. This MOVES each file into the
    /// staging folder, exactly as the single-item action does — nothing
    /// is deleted, and Review is where it is undone.
    func markSelectionForDeletion() { stageSelection(.toDelete, on: true) }

    /// Clear the mark and put each file back where it was.
    func unmarkSelectionForDeletion() { stageSelection(.toDelete, on: false) }

    /// Flag the selection as not playing and stage the files, as the
    /// player's W key does one at a time.
    func markSelectionWontPlay() { stageSelection(.playbackIssue, on: true) }

    func unmarkSelectionWontPlay() { stageSelection(.playbackIssue, on: false) }

    /// One routine for the four marks. Each item is a file move, so this
    /// cannot be one transaction. What it can be is honest: carry on past
    /// a failure, let the change hub refresh the grid to what did happen,
    /// and say what did not. And off the main actor: a selection of a
    /// few hundred on a networked drive is a few hundred file moves.
    /// Items already in the asked-for state are left alone, so marking a
    /// mixed selection marks the rest and moves nothing twice.
    private func stageSelection(_ folder: StagingFolder, on: Bool) {
        let items = selectedItems
        clearSelection()
        setStaging(folder, on: on, for: items)
    }

    /// Mark or clear, stage or unstage, any items — one tile's menu or a
    /// whole selection. Off the main actor, always: each item is a file
    /// move, and a tile's Restore used to run its move on the main
    /// thread, freezing the window over a slow volume.
    func setStaging(_ folder: StagingFolder, on: Bool, for chosen: [MediaItem]) {
        let items = chosen.filter { item in
            switch folder {
            case .toDelete: item.markedForDeletion != on
            case .playbackIssue: item.playbackIssue != on
            }
        }
        guard !items.isEmpty else { return }
        let service = service
        let verb = on ? "mark" : "restore"
        // The service says which items; this window knows what they were
        // called.
        let names = Dictionary(items.map { ($0.id, $0.fileName) }, uniquingKeysWith: { first, _ in first })
        Task {
            let failures: [String]
            do {
                failures = try await service.setStaging(folder, on: on, itemIDs: items.map(\.id))
                    .map { "\(names[$0.itemID] ?? "an item"): \($0.reason)" }
            } catch {
                errorMessage = "Could not \(verb) the selection: \(error)"
                return
            }
            if let first = failures.first {
                errorMessage = failures.count == 1
                    ? "Could not \(verb) \(first)"
                    : "\(failures.count) of \(items.count) could not be \(verb)d. First: \(first)"
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
    func applyTagToSelection(_ tagID: UUID) async {
        let ids = selectedItems.map(\.id)
        // One transaction in the kit: the bulk edit lands whole or not
        // at all.
        await write { try await $0.assignTag(tagID, to: ids) }
    }

    /// Favourite the selection, or unfavourite it: on when any selected
    /// item is not yet a favourite, off when they all are.
    func toggleSelectionFavorite() async {
        let items = selectedItems
        let on = items.contains { !$0.isFavorite }
        let ids = items.map(\.id)
        await write { try await $0.setFavorite(ids, on) }
    }

    /// Take one tag off everything selected that carries it.
    func removeTagFromSelection(_ tagID: UUID) async {
        let ids = selectedItems.map(\.id)
        await write { try await $0.removeTag(tagID, from: ids) }
    }

    /// The tags any selected item carries, in category order, for the
    /// bulk bar's Remove picker. Only what the grid already knows: when
    /// the tile view draws no tags this is empty, and the picker says so.
    var tagsOnSelection: [TagPill] {
        var seen: Set<UUID> = []
        var pills: [TagPill] = []
        for item in selectedItems {
            for pill in itemTags[item.id] ?? [] where seen.insert(pill.id).inserted {
                pills.append(pill)
            }
        }
        let order = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($1.category.id, $0) })
        return pills.sorted {
            let (a, b) = (order[$0.categoryID] ?? .max, order[$1.categoryID] ?? .max)
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
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
    ///
    /// Stored, like `offlineItems`, and redone only when the listing, the
    /// online sources or the toggle change. Every tile reads these on
    /// every render and a click re-renders every tile; filtering the
    /// whole listing per read made a click on a large grid lag.
    private(set) var visibleItems: [MediaItem] = []

    /// Items in the full listing whose source is offline. Counted against
    /// the listing BEFORE the toggle, so hiding them does not make the
    /// banner forget how many it hid.
    private(set) var offlineItems: [MediaItem] = []

    /// Where each visible item sits, so the selection is found without a
    /// pass over the listing.
    private var visibleIndexByID: [UUID: Int] = [:]

    /// Bumped when the visible ids change — what the grid animates on,
    /// rather than building and comparing every id on every render. A
    /// re-query that returns the same items leaves it alone, so it
    /// animates nothing.
    private(set) var listingGeneration = 0

    private func relist() {
        let online = onlineSourceIDs
        let previous = visibleItems
        offlineItems = items.filter { !online.contains($0.sourceID) }
        visibleItems = hideOfflineItems ? items.filter { online.contains($0.sourceID) } : items
        if !previous.elementsEqual(visibleItems, by: { $0.id == $1.id }) { listingGeneration &+= 1 }
        visibleIndexByID = Dictionary(
            visibleItems.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The offline sources represented in the listing, listed the way the
    /// banner names them.
    var offlineSourceNames: [String] {
        let ids = Set(offlineItems.map(\.sourceID))
        return sources.filter { ids.contains($0.id) }.map(\.name)
    }

    /// The file a tile drags out as: its own, reachable file. An
    /// embedded clip has none of its own, and an offline item's cannot
    /// be reached.
    func dragFileURL(for item: MediaItem) -> URL? {
        guard item.parentMediaItemID == nil else { return nil }
        return fileURL(for: item)
    }

    /// The item's file on this Mac (an embedded clip's is its parent's
    /// file), for the Finder, a drag and Quick Look. nil while the item's
    /// source is offline or disabled — and always for a library another
    /// Mac holds, whose paths are that Mac's.
    ///
    /// Worked out from what the window already holds: the source's folder
    /// and the item's path. It used to ask the database, and check the
    /// drive, every time.
    func fileURL(for item: MediaItem) -> URL? {
        guard service.filesAreOnThisMac, isOnline(item), let source = source(for: item) else { return nil }
        return source.fileURL(for: item)
    }

    /// Where the item can be read from, as something to be asked later
    /// and away from the main actor — what a thumbnail request takes, so
    /// a tile never pays for the lookup just to find its thumbnail was
    /// cached all along. It is where the item plays from: this Mac's file,
    /// or for a library held elsewhere whatever the service plays it
    /// through.
    func fileResolver(for item: MediaItem) -> @Sendable () async -> URL? {
        let service = service, itemID = item.id
        return { (try? await service.playable(itemID: itemID))?.url }
    }

    // MARK: - Operations

    /// Save segments as files of their own — what the delete list offers
    /// before it will purge the video they play from.
    func saveSegmentsAsFiles(_ segmentIDs: [UUID]) {
        start(segmentIDs.map { .exportClip(clipID: $0) })
    }

    func exportClip(_ item: MediaItem) {
        start(.exportClip(clipID: item.id))
    }

    func encode(_ item: MediaItem, preset: EncodeJob.Preset) {
        start(.encode(itemID: item.id, preset: preset))
    }

    func removeBlocks(_ item: MediaItem) {
        start(.removeBlocks(itemID: item.id))
    }

    /// Filled with each listing; see `BrowseListingAnswer.menuFacts`.
    private var hideBlockItemIDs: Set<UUID> = []
    private var snapshotRefs: [UUID: [SnapshotRef]] = [:]

    func hasHideBlocks(_ item: MediaItem) -> Bool {
        hideBlockItemIDs.contains(item.id)
    }

    func scanText(_ item: MediaItem) {
        start(.recogniseText(itemID: item.id))
    }

    /// The same OCR scan, with a completion — Tag Analysis reloads its
    /// evidence when the scan lands rather than waiting for a broadcast.
    func scanText(itemID: UUID, then finished: @escaping @MainActor @Sendable () -> Void) {
        let service = service
        Task {
            do {
                // Somebody is waiting on it: next after the job running,
                // not behind every sweep queued before it.
                try await service.run(.recogniseText(itemID: itemID), wait: .settled)
            } catch {
                errorMessage = "\(error)"
            }
            finished()
        }
    }

    func joinFolder(of item: MediaItem) {
        start(.joinFolder(sourceID: item.sourceID, folderPath: item.folderPath))
    }

    func writeTags(itemIDs: [UUID], scope: String) {
        start(.writeTags(itemIDs: itemIDs, scope: scope))
    }

    func restoreSnapshot(_ snapshotID: UUID) {
        start(.restoreSnapshot(snapshotID))
    }

    func snapshots(of itemID: UUID) -> [SnapshotRef] {
        snapshotRefs[itemID] ?? []
    }

    func runValidation() async {
        do {
            try await service.run(.validation, wait: .settled)
        } catch {
            errorMessage = "\(error)"
        }
    }

    func remux(_ item: MediaItem, mode: RemuxJob.Mode) {
        start(.remux(itemID: item.id, mode: mode))
    }

    /// Sweep embedded metadata into `embeddedMetadataPair` — the tag
    /// analysis queue's largest source, and the only one that needs a
    /// pass over the files rather than a query.
    ///
    /// With no items named it is a library sweep, which is a signal, not
    /// a command to run another one: a second row would re-probe every
    /// file the first is already probing. With items named it is a job
    /// of its own, and goes next after the job running — a pending
    /// library sweep must not swallow the small one the operator is
    /// waiting on, and behind every sweep queued before it left Tag
    /// Analysis loading.
    func sweepMetadata(
        itemIDs: [UUID]? = nil, then finished: @escaping @MainActor @Sendable () -> Void
    ) {
        let service = service
        Task {
            do {
                // Waits for its own sweep, never for jobs queued after it.
                try await service.run(.metadataSweep(itemIDs: itemIDs), wait: .settled)
            } catch {
                errorMessage = "\(error)"
            }
            finished()
        }
    }

    /// Examine the selection's files now: what they declare, how their
    /// frames are timed, what their picture and sound measure, and what
    /// that is evidence of. A scoped sweep, so it runs ahead of the
    /// library-wide one and steps aside for nothing but another sweep.
    /// Like every sweep it fills in what is missing: an item examined
    /// already is not decoded again.
    ///
    /// A segment is a range of its parent's file, so it is the parent
    /// that is examined; selecting three clips of one video costs one
    /// visit.
    func examineSelection() {
        let ids = Set(selectedItems.map { $0.parentMediaItemID ?? $0.id })
        guard !ids.isEmpty else { return }
        clearSelection()
        start(.examine(itemIDs: Array(ids)))
    }

    /// Queue a job and start the queue, without waiting for it.
    private func start(_ request: JobRequest) {
        start([request])
    }

    /// Several, queued in the order given.
    private func start(_ requests: [JobRequest]) {
        let service = service
        Task {
            do {
                for request in requests { try await service.run(request, wait: .none) }
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

/// Reload a window's own reads when the library changes in the domains
/// it shows — once things settle, not per delivery: an import commits up
/// to ten deliveries a second, and some windows' reloads open every
/// backup or stat every staged file. The count the window opened with is
/// not a change. But never more than `longestSettle` after a burst began:
/// each change put the settle back, and through an import Review,
/// Maintenance and Tag Manager did not reload until it stopped. (Organise's
/// planner caps its settle the same way.)
struct FollowsLibraryChanges: ViewModifier {
    let model: BrowseModel
    let domains: Set<LibraryChangeDomain>
    let reload: () -> Void
    @State private var seen: Int?
    /// When the unanswered changes began.
    @State private var burstStarted: ContinuousClock.Instant?
    static let settle: Duration = .milliseconds(400)
    static let longestSettle: Duration = .seconds(2)

    func body(content: Content) -> some View {
        // Read here, in the modifier's own body, not the window's: read in
        // the window, every hub delivery in ANY domain re-rendered the
        // whole window, ten times a second during an import.
        let count = model.changeCount(domains)
        return content
            .task(id: count) {
                // The first run is the window opening: the count it finds is
                // where it starts, not a change. (Seeded here rather than in
                // onAppear, whose order against this first run is not given.)
                guard let seen else {
                    seen = count
                    return
                }
                guard count != seen else { return }
                let now = ContinuousClock.now
                let started = burstStarted ?? now
                burstStarted = started
                let wait = min(Self.settle, Self.longestSettle - (now - started))
                if wait > .zero {
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled else { return }
                }
                self.seen = count
                burstStarted = nil
                reload()
            }
    }
}

extension View {
    func followsLibraryChanges(
        _ model: BrowseModel, _ domains: Set<LibraryChangeDomain>, reload: @escaping () -> Void
    ) -> some View {
        modifier(FollowsLibraryChanges(model: model, domains: domains, reload: reload))
    }
}

