import AVFoundation
import Foundation
import SwiftUI
import SightsAndSoundsKit

/// The app-wide mute for this RUN of the app. Seeded from the
/// start-muted setting the first time a player exists, then owned by
/// the operator's own mute toggle until the app closes — the setting
/// is a default, not a leash.
@MainActor
final class SessionAudio {
    static let shared = SessionAudio()
    var isMuted: Bool = AppSettingsStore.shared.current.startVideosMuted
}

/// One player window's state. Owns playback and nothing else — tagging,
/// OCR and clip authoring stay separate features (the 4,382-line lesson).
@Observable @MainActor
final class PlayerModel {
    let library: LibraryDatabase
    /// What this player asks of its library. Its reads and writes are
    /// moving onto it from `library` a group at a time.
    let service: any LibraryService
    let libraryID: UUID
    /// This player's queue: a snapshot with a definition. Nothing outside
    /// the player replaces it; Refresh re-runs the definition.
    let queue: PlayQueue
    /// The queue's ids under its sort — what ←/→ walk.
    var playlist: [UUID] { queue.ids }
    /// The queue's rows under its sort — the strip's data.
    var queueItems: [MediaItem] { queue.visible }
    private(set) var isRefreshingQueue = false

    /// The companion's handshake, created the first time Tag Analysis
    /// is opened from this player and kept for the player's life. The
    /// player only ever writes what it is showing; see the session.
    private(set) var analysisSession: TagAnalysisSession?

    /// The session for this player, registered on first use so the
    /// companion's window can find it by id.
    func analysisSession(registeringIn app: AppModel) -> TagAnalysisSession {
        if let analysisSession { return analysisSession }
        let session = TagAnalysisSession(libraryID: libraryID, library: library)
        session.apply = { [weak self] tag in self?.applyTag(tag.id) }
        session.step = { [weak self] delta in
            delta < 0 ? self?.goPrevious() : self?.goNext()
        }
        app.registerAnalysisSession(session)
        analysisSession = session
        publishToSession()
        return session
    }

    /// What the companion follows: the shown item and its place in the
    /// playlist. Cheap and idempotent — called on every load and every
    /// playlist change.
    private func publishToSession() {
        itemShown(item?.id)
        guard let analysisSession else { return }
        let position: (index: Int, count: Int)? = {
            guard playlist.count > 1, let item, let index = playlist.firstIndex(of: item.id)
            else { return nil }
            return (index, playlist.count)
        }()
        analysisSession.playerDidShow(itemID: item?.id, position: position)
    }

    private(set) var item: MediaItem?
    private(set) var player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var currentSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    var loadError: String? {
        didSet {
            if let loadError { AppLog.shared.error("playback", loadError) }
        }
    }

    var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying { player.rate = playbackRate }
            nowPlaying.update(self)
        }
    }

    /// What the system's Now Playing and media keys talk to.
    private let nowPlaying: NowPlaying
    private var skipSettings = SkipSettings()
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var statusObserver: NSKeyValueObservation?
    private var completionRecorded = false
    private let fileAccess: any FileAccess

    var title: String { item?.fileName ?? "Player" }
    var isAudio: Bool { item?.kind == .audio }

    /// Which map the keys answer to. Read per use, so changing it in
    /// Settings applies without reopening the player.
    var keyMap: KeyMapStyle { AppSettingsStore.shared.current.keyMap }

    /// The top-row digits' mode: stamping their bound tags, or typing.
    /// Read from settings so every player agrees and the mode survives
    /// a relaunch; `settingsTick` makes the read observable.
    var digitsStampTags: Bool {
        _ = settingsTick
        return AppSettingsStore.shared.current.digitKeysStampTags
    }
    private var settingsTick = 0

    func toggleDigitStamping() {
        AppSettingsStore.shared.update { $0.digitKeysStampTags.toggle() }
        settingsTick += 1
    }

    /// The laptop numpad layer: the right-hand cluster as the keypad.
    var laptopNumpad: Bool {
        _ = settingsTick
        return AppSettingsStore.shared.current.laptopNumpad
    }

    func toggleLaptopNumpad() {
        AppSettingsStore.shared.update { $0.laptopNumpad.toggle() }
        settingsTick += 1
    }

    /// A key on the laptop numpad layer, wherever it was pressed: the
    /// keypad action it stands for while the layer is on, else nothing —
    /// the caller lets the letter be a letter.
    func handleLaptopNumpadKey(_ character: Character) -> Bool {
        guard laptopNumpad, let key = PlayerKeyMap.laptopNumpadKey(for: character) else { return false }
        return handle(character: key, shift: false, numpad: true)
    }

    /// Whether any digit is bound — the mode is worth showing only then.
    var hasDigitBindings: Bool {
        boundKeys.keys.contains { $0.count == 1 && $0.first!.isNumber }
    }

    /// A top-row digit, wherever it was pressed: its bound tag when the
    /// mode stamps, else nothing — the caller lets it type.
    func handleDigitKey(_ character: Character) -> Bool {
        guard character.isNumber, digitsStampTags else { return false }
        return handleBoundKey(String(character))
    }

    // MARK: - Focus

    /// Where the keyboard is pointed. The whole single-key map depends on
    /// this being knowable, so it is state rather than a guess made from
    /// whichever text field last took first responder.
    var zone: PlayerZone = .video

    /// Tab walks the zones that are actually on screen — a collapsed
    /// panel is not a place focus can go.
    func moveZone(reverse: Bool, available: [PlayerZone]) {
        guard !available.isEmpty else { return }
        let index = available.firstIndex(of: zone) ?? 0
        let next = (index + (reverse ? available.count - 1 : 1)) % available.count
        zone = available[next]
    }

    // MARK: - Panels

    /// Which panels are up. Persisted through the player's layout
    /// settings — whether you want the segments rail is a fact about how
    /// you work, not about this item.
    var panels: PlayerPanels = AppSettingsStore.shared.current.playerLayout.panels

    func togglePanel(_ panel: PlayerPanel) {
        panels[panel].toggle()
        // Focus cannot sit in a panel that just closed.
        if !panels[panel], zone.panel == panel { zone = .video }
        // The history is read when the panel opens: fresh then, and
        // not reordered under the arrows while it is up.
        if panel == .history, panels.history { refreshHistory() }
        // The formats may have changed in Settings while the panel was
        // closed: read them fresh when it opens.
        if panel == .search, panels.search { refreshSearch() }
    }

    var showsRail: Bool { panels.tags || panels.segments || panels.history || panels.search }

    // MARK: - Search panel

    /// Every search format the library has, and the shown item as the
    /// builder sees it — refreshed with the tags, so the panel's strings
    /// follow a tag change at once (spec 17, decision 9).
    private(set) var searchFormats: SearchFormats = .empty
    private(set) var searchSubject: SearchSubject?

    func refreshSearch() {
        guard let itemID = item?.id else { return }
        searchGeneration += 1
        let generation = searchGeneration, service = service
        panelLoadsInFlight += 1
        Task { [weak self] in
            let answer = await Self.answer { try await service.searchContext(itemID: itemID) }
            guard let self else { return }
            self.panelLoadsInFlight -= 1
            // Values that could not be read leave the ones on screen.
            guard case .success(let context) = answer,
                  self.item?.id == itemID, self.searchGeneration == generation
            else { return }
            self.searchFormats = context.formats
            self.searchSubject = context.subject
        }
    }
    private var searchGeneration = 0

    // MARK: - Panel reads

    /// Reads of the panels asked for and not yet answered. Zero means
    /// what the panels show is everything that was asked of them.
    ///
    /// The panels are read off the main actor and shown when the answer
    /// arrives — and only if it is still wanted: an answer about an item
    /// no longer on screen, or one overtaken by a later read of the same
    /// thing, is dropped. A read used to be finished by the next line; a
    /// library on another Mac answers in its own time, and in no
    /// promised order.
    private(set) var panelLoadsInFlight = 0

    /// One read, off the main actor, as a result.
    private nonisolated static func answer<T: Sendable>(
        _ read: @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        do {
            return .success(try await read())
        } catch {
            return .failure(error)
        }
    }

    /// The panel's editor: write one format back — in place when it
    /// exists, appended when it is new (and made the default when there
    /// was none).
    func saveSearchFormat(_ recipe: SearchRecipe) {
        var formats = searchFormats
        if let index = formats.formats.firstIndex(where: { $0.id == recipe.id }) {
            formats.formats[index] = recipe
        } else {
            formats.formats.append(recipe)
            if formats.defaultID == nil { formats.defaultID = recipe.id }
        }
        do {
            try library.setSearchFormats(formats)
            searchFormats = formats
        } catch {
            loadError = "\(error)"
        }
    }

    /// The panel's ⌘⇧C marker: make this format the default.
    func setDefaultSearchFormat(_ id: UUID) {
        var formats = searchFormats
        formats.defaultID = id
        do {
            try library.setSearchFormats(formats)
            searchFormats = formats
        } catch {
            loadError = "\(error)"
        }
    }

    /// The zones actually on screen, in Tab order. A collapsed panel is
    /// not a place focus can go.
    var availableZones: [PlayerZone] {
        var zones: [PlayerZone] = [.video]
        if panels.tags { zones.append(.tags) }
        if panels.segments { zones.append(.segments) }
        if panels.history { zones.append(.history) }
        if panels.queue, !playlist.isEmpty { zones.append(.queue) }
        return zones
    }

    // MARK: - History panel

    /// What has been watched, newest first, for the rail's History
    /// panel. Read when the panel opens and when ANOTHER player loads
    /// something; this player's own loads stamp the history too, but
    /// re-reading on them would move the row just walked to onto the
    /// top and put the next ↓ somewhere else — a walk needs the list
    /// to hold still.
    private(set) var historyRows: [MediaItem] = []
    var historySelectionID: UUID?

    func refreshHistory() {
        historyGeneration += 1
        let generation = historyGeneration, service = service
        panelLoadsInFlight += 1
        Task { [weak self] in
            let answer = await Self.answer { try await service.recentlyWatched(limit: 300) }
            guard let self else { return }
            self.panelLoadsInFlight -= 1
            guard case .success(let rows) = answer, self.historyGeneration == generation else { return }
            self.show(history: rows)
        }
    }
    private var historyGeneration = 0

    private func show(history rows: [MediaItem]) {
        historyRows = rows
        if let id = item?.id, historyRows.contains(where: { $0.id == id }) {
            historySelectionID = id
        }
    }

    /// ↑ ↓ in the History zone: the next row is selected AND loaded —
    /// the arrows walk what you watched, they do not pick and wait.
    func stepHistorySelection(_ delta: Int) {
        guard let next = HistoryNavigation.next(
            after: historySelectionID, in: historyRows.map(\.id), delta: delta)
        else { return }
        selectHistoryRow(next)
    }

    func selectHistoryRow(_ id: UUID) {
        historySelectionID = id
        zone = .history
        if item?.id != id { load(itemID: id) }
    }

    // MARK: - Tagging state

    /// Kept for the `T` key's older name; the panel itself is `panels.tags`.
    var showTagPanel: Bool {
        get { panels.tags }
        set { panels.tags = newValue }
    }
    private(set) var itemTags: [CategoryTags] = []
    private(set) var panelVocabulary: [CategoryTags] = []
    /// Alias strings per tag, so the tagging field can offer a tag by a
    /// name it also answers to.
    private(set) var panelAliases: [UUID: [String]] = [:]
    private(set) var boundKeys: [String: TagKeyBinding] = [:]

    /// The category whose tags Alt+1…9 toggles: the first checkbox-mode
    /// category by sort order (old app rule — exactly one gets the keys).
    var checkboxCategory: CategoryTags? {
        panelVocabulary.first { $0.category.displayAsCheckboxes }
    }

    /// Which category's field takes focus when the panel opens: the
    /// first visible one, by sort order. It used to be a flag a category
    /// carried, which two categories could hold at once and a write path
    /// had to police.
    var focusCategoryID: UUID? {
        panelVocabulary.first { !$0.category.hiddenFromBrowse }?.id
    }

    init(
        request: PlayerRequest, library: LibraryDatabase, appDatabase: AppDatabase?,
        fileAccess: any FileAccess = LiveFileAccess(),
        service: (any LibraryService)? = nil,
        nowPlaying: NowPlaying = .shared
    ) {
        self.nowPlaying = nowPlaying
        self.library = library
        self.fileAccess = fileAccess
        // The window's own service when it is given one. Otherwise one
        // that reads and writes this library but starts no jobs: a
        // player has no runner to hand, and must not make a second.
        self.service = service ?? LocalLibraryService(library: library, fileAccess: fileAccess)
        self.libraryID = request.libraryID
        self.queue = PlayQueue(definition: request.definition, items: [])
        _ = appDatabase  // legacy pref migrates into settings.json at launch
        skipSettings = AppSettingsStore.shared.current.skip
        // The rail is per window: on where there is no sidebar to narrow
        // with (Tag Pivot, History, a selection), off in the library
        // window whose sidebar sits in the same place.
        if case .listing = request.definition { panels.rail = false } else { panels.rail = true }
        load(itemID: request.itemID)
        loadSnapshot(request.playlist)
        // History is the one live queue: another player's load over this
        // library re-runs it. Its own loads are excluded by token, so
        // walking the history never reorders it under you.
        // The History panel follows the same broadcast, whatever the
        // queue is.
        let followsHistoryQueue: Bool
        if case .history = request.definition { followsHistoryQueue = true } else { followsHistoryQueue = false }
        loadObserver = NotificationCenter.default.addObserver(
            forName: .sasPlaybackDidLoad, object: nil, queue: .main
        ) { [weak self] note in
            let changed = note.userInfo?["libraryID"] as? UUID
            let sender = note.userInfo?["sender"] as? UUID
            Task { @MainActor in
                guard let self, changed == self.libraryID, sender != self.playerToken
                else { return }
                if followsHistoryQueue { self.refreshQueue() }
                if self.panels.history { self.refreshHistory() }
            }
        }
        if panels.history { refreshHistory() }
        // Edits made anywhere reach an open player: a rename in the Tag
        // Manager, a bulk tag in the grid, blocks from another window. It
        // used to hear only that a browse window had refreshed, and then
        // only recounted the queue — the tag panel kept the old names
        // until the next item.
        let changes = self.service.changes()
        changeWatch.task = Task { [weak self] in
            for await change in changes { self?.libraryChanged(change) }
        }
    }

    /// The task reading the service's change stream. Cancelled by
    /// `shutdown`, and by the bag's own deinit for a player let go of
    /// without one, so nothing actor-isolated is touched in a deinit.
    private final class ChangeWatch: @unchecked Sendable {
        var task: Task<Void, Never>?
        deinit { task?.cancel() }
    }
    private let changeWatch = ChangeWatch()
    /// When this player last re-read its tagging; its own edits do that
    /// at once, and the hub's echo of them is then skipped.
    private var lastTaggingRefreshBegan = ContinuousClock.now

    private func libraryChanged(_ change: LibraryChange) {
        if !change.domains.isDisjoint(with: [.vocabulary, .tagging]) {
            if lastTaggingRefreshBegan < change.lastCommitAt {
                // Tags on items moved: re-read this item's. The vocabulary
                // itself changed: everything.
                change.domains.contains(.vocabulary) ? refreshTagging() : refreshItemTags()
            }
            recountQueue()
        }
        if change.domains.contains(.itemDetails) { refreshBlocks() }
    }
    private var loadObserver: (any NSObjectProtocol)?
    /// This player's identity on the load broadcast, so a History queue
    /// can tell another player's load from its own.
    let playerToken = UUID()

    // MARK: - Play queue

    /// The opening snapshot's rows, in the given order, off the main
    /// actor — the request carries ids so the player starts at once.
    private func loadSnapshot(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let service = service
        Task.detached(priority: .userInitiated) { [weak self] in
            let ordered = (try? await service.items(ids: ids)) ?? []
            await MainActor.run { [weak self] in
                self?.queue.apply(ordered)
                self?.publishToSession()
                self?.recountQueue()
            }
        }
    }

    /// Which tags the snapshot's items wear, off the main actor — the
    /// rail's counts and the narrowing follow.
    func recountQueue() {
        let service = service, ids = queue.items.map(\.id)
        guard !ids.isEmpty else {
            queue.apply(membership: [:])
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let membership = (try? await service.tagMembership(itemIDs: ids)) ?? [:]
            await MainActor.run { [weak self] in self?.queue.apply(membership: membership) }
        }
    }

    /// The listing definition Refresh should use when this queue is a
    /// listing — installed by the view that knows the grid, so the
    /// library window's queue catches up with what the grid shows.
    var currentListing: () -> QueueDefinition? = { nil }

    /// The shown item, for whoever hosts the player — the browse model
    /// makes it the Search menu's subject. nil once the player is gone.
    var itemShown: (UUID?) -> Void = { _ in }

    /// Re-run the queue's definition. The shown item keeps playing
    /// whether or not it is still in the result — a Refresh is not a
    /// stop — and ←/→ then start from the ends of what is left.
    func refreshQueue() {
        guard !isRefreshingQueue else { return }
        if case .listing = queue.definition, let listing = currentListing() {
            queue.replaceDefinition(listing)
        }
        isRefreshingQueue = true
        let service = service, definition = queue.definition
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<[MediaItem], Error>
            do {
                result = .success(try await service.queueItems(definition))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let rows): self.queue.apply(rows)
                case .failure(let error): self.loadError = "Refresh failed: \(error)"
                }
                self.isRefreshingQueue = false
                self.publishToSession()
                self.recountQueue()
            }
        }
    }

    /// The same lookup, to be run later and off the main actor; see
    /// `BrowseModel.fileResolver(for:)`.
    func queueFileResolver(for item: MediaItem) -> @Sendable () -> URL? {
        let library = library, fileAccess = fileAccess
        return { (try? library.resolvedFileURL(for: item, fileAccess: fileAccess)) ?? nil }
    }

    // MARK: - Loading

    /// Loads race under fast ←/→ — the counter lets only the newest
    /// apply, and the fetch + file resolution run off the main actor
    /// (resolvedFileURL touches the filesystem; a slow volume used to
    /// hitch the UI on every item switch).
    private var loadGeneration = 0

    func load(itemID: UUID) {
        persistProgress()
        queuePositionID = itemID
        removeObserver()
        completionRecorded = false
        reachedEnd = false
        loadError = nil
        loadGeneration += 1
        let generation = loadGeneration
        let service = service
        let asked = ContinuousClock.now

        Task.detached(priority: .userInitiated) { [weak self] in
            // The item, where it plays from, and what its panel and rail
            // show: one answer, applied in one turn. The panel used to be
            // read after the item had been set, which was safe only while
            // a read was finished by the next line.
            let outcome: Result<OpenedItem, Error>
            do {
                outcome = .success(try await service.opened(itemID: itemID))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                switch outcome {
                case .success(let opened): self.apply(opened, asked: asked)
                case .failure(let error):
                    self.stopForFailedLoad()
                    self.letGoOfItem()
                    self.loadError = "\(error)"
                }
            }
        }
    }

    private func apply(_ opened: OpenedItem, asked: ContinuousClock.Instant) {
        let url = opened.playable.url
        guard let loaded = opened.playable.item else {
            stopForFailedLoad()
            letGoOfItem()
            loadError = "The item no longer exists."
            return
        }
        guard let url else {
            stopForFailedLoad()
            item = loaded
            // The panel and the rail answer for the item on screen, even
            // one that cannot play: they kept the last item's tags and
            // segments, so a click here edited the wrong file.
            show(panelOf: opened, asked: asked)
            publishToSession()
            loadError = "The item's source is offline."
            return
        }
        let changesItem = item?.id != loaded.id
        item = loaded
        fileURL = url
        // The search values are the last item's until re-read: gone, so
        // a search is never built from another item's name and tags.
        if changesItem { searchSubject = nil }
        // A segment plays inside its parent's file, so the timeline is the
        // FILE's; the row's duration is only the segment's length. Taken
        // as the file's, it clamped every seek: a song at 40:00 started
        // at its own length and looped there. Zero lets the first tick
        // read the file's duration from the player.
        durationSeconds = loaded.parentMediaItemID == nil ? (loaded.durationSeconds ?? 0) : 0
        // The playhead answers for THIS item from now on. It used to keep
        // the last item's position until the new file's first time tick
        // — seconds, on a big file over the network — and a "skip the
        // intro" pressed in that gap seeked from where the LAST video
        // was, which is how the next one came up well into its running
        // time. A clip's seek below moves it to the in-point.
        currentSeconds = 0

        // A load is a watch, even a brief one: the history stamps now,
        // and every History queue over this library hears about it —
        // except this player's own, which never reorders on its plays.
        if loaded.clipStartSeconds == nil {
            record(.started(itemID: loaded.id, at: Date()))
        }
        // Told once the stamp has landed: the queues that hear this
        // re-read the history, and must find this watch in it. Queued
        // behind the stamp, so it follows it whether or not there was one.
        let libraryID = libraryID, sender = playerToken
        writes.send({
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .sasPlaybackDidLoad, object: nil,
                    userInfo: ["libraryID": libraryID, "sender": sender])
            }
        })

        let playerItem = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: playerItem)
        // Mute is SESSION state, not per-item: the settings toggle seeds
        // it once at launch, and from then on the operator's own toggle
        // is the truth until the app restarts. Re-reading the setting on
        // every load was silently re-muting each next video after the
        // operator had turned sound on. Audio never begins muted (it
        // would just be silence) — playing audio reads past the session
        // state without changing it.
        isMuted = loaded.kind == .video && SessionAudio.shared.isMuted
        player.isMuted = isMuted
        isLooping = AppSettingsStore.shared.current.loopVideos
        pendingSeekTarget = nil
        isBuffering = false
        installObserver()
        observeStatus(of: playerItem)
        show(panelOf: opened, asked: asked)
        publishToSession()

        // Clips start at their in-point; everything else starts at the
        // beginning. The stored resume position is deliberately NOT
        // seeked to — reopening a video always plays from the top. The
        // position keeps being persisted, because History still
        // says where you stopped; it just no longer drives playback.
        if let start = loaded.clipStartSeconds {
            seek(to: start)
        }
        play()
    }

    private(set) var fileURL: URL?

    /// A load that cannot play leaves nothing playing. `load` has already
    /// taken the observers off, so without this the LAST item carried on
    /// under the new item's title — playhead frozen, `isPlaying` still
    /// true, and `fileURL` still answering for a file that is no longer
    /// the one on screen.
    /// Where the queue stands: the id last asked for, loaded or not.
    /// Separate from `item` so a failed load can let go of the item
    /// without losing its place for Next and Previous.
    private var queuePositionID: UUID?

    /// A load that found no item must not leave the LAST one behind:
    /// every key acts on `item`, so ⇧⌫ unmarked the previous file and
    /// tag keys wrote to it while the title said something else.
    private func letGoOfItem() {
        item = nil
        itemTags = []
        segments = []
        hideBlocks = []
        publishToSession()
    }

    private func stopForFailedLoad() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isBuffering = false
        pendingSeekTarget = nil
        fileURL = nil
        currentSeconds = 0
        durationSeconds = 0
    }

    // MARK: - Transport

    func play() {
        // From the natural end, Play means from the top (the in-point
        // for a clip), as in QuickTime. `player.play()` at the end of the
        // file moves nothing while the button says Pause.
        if reachedEnd { seek(to: item?.clipStartSeconds ?? 0) }
        player.play()
        player.rate = playbackRate
        isPlaying = true
        // Playing makes this player what the system's Now Playing and
        // media keys talk to.
        nowPlaying.claim(self)
    }

    func pause() {
        player.pause()
        isPlaying = false
        persistProgress()
        nowPlaying.update(self)
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    /// Session-scoped: flipping it never outlives the current item —
    /// the next load re-applies the start-muted setting.
    private(set) var isMuted = false

    /// Where the operator has ASKED to be, while the player catches up.
    /// Seeks stack from this, not from the player's reported time —
    /// which lags during buffering, so "skip 30s four times quickly"
    /// must mean two minutes, not four attempts at the same 30.
    private var pendingSeekTarget: Double?
    /// The seek has outrun the buffer — the stage shows a spinner.
    private(set) var isBuffering = false

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
        // The toggle IS the session's new truth — every later load, in
        // every window, follows it until the app restarts.
        SessionAudio.shared.isMuted = isMuted
    }

    /// Session-scoped like mute: each load re-reads the setting.
    private(set) var isLooping = false

    func toggleLoop() { isLooping.toggle() }

    /// Natural end of the file. Looping restarts (clips at their
    /// in-point); otherwise just reflect the stop — no progress write,
    /// so a finished item doesn't resume at its final frame.
    private func playbackDidEnd() {
        if isLooping {
            seek(to: item?.clipStartSeconds ?? 0)
            play()
        } else {
            isPlaying = false
            reachedEnd = true
        }
    }

    /// Stopped at the natural end — cleared by any seek or load.
    private var reachedEnd = false

    func seek(to seconds: Double) {
        let clamped = max(0, durationSeconds > 0 ? min(seconds, durationSeconds) : seconds)
        reachedEnd = false
        // The playhead moves NOW — the display answers to the operator's
        // intent, and the video catches up to it, never the reverse.
        currentSeconds = clamped
        pendingSeekTarget = clamped
        isBuffering = true
        nowPlaying.update(self)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                // A superseded seek completes with false — a newer target
                // owns the pending state; only the seek that LANDED may
                // clear it.
                guard finished, self.pendingSeekTarget == clamped else { return }
                self.pendingSeekTarget = nil
                self.isBuffering = false
            }
        }
    }

    func seek(by delta: Double) { seek(to: currentSeconds + delta) }

    // MARK: - Scrubbing

    /// Scrubbing, the chase way (Technical Q&A QA1820). A drag sends a
    /// position per mouse event; each used to start an exact seek that
    /// cancelled the one before, so the decoder thrashed and the picture
    /// lagged the thumb. Now: the playhead shows the thumb at once, one
    /// loose seek is in flight, and only the latest position waits for
    /// it; where the drag ends gets an exact seek.
    private var scrubTarget: Double?
    private var scrubSeekInFlight = false
    /// Whether playback was running when the drag began — it pauses for
    /// the drag and picks up again after.
    private var playingBeforeScrub: Bool?
    /// Loose seeks started for drags — what the tests watch.
    private(set) var scrubSeeksIssued = 0

    func scrub(to seconds: Double) {
        let clamped = max(0, durationSeconds > 0 ? min(seconds, durationSeconds) : seconds)
        if playingBeforeScrub == nil {
            playingBeforeScrub = isPlaying
            if isPlaying { player.pause() }
        }
        reachedEnd = false
        currentSeconds = clamped
        // Holds the time observer off the display while the player
        // catches up, as a keyboard seek does.
        pendingSeekTarget = clamped
        scrubTarget = clamped
        if !scrubSeekInFlight { chaseScrub() }
    }

    private func chaseScrub() {
        guard let target = scrubTarget else {
            scrubSeekInFlight = false
            return
        }
        scrubTarget = nil
        scrubSeekInFlight = true
        scrubSeeksIssued += 1
        let slack = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: slack, toleranceAfter: slack
        ) { [weak self] _ in
            Task { @MainActor in self?.chaseScrub() }
        }
    }

    func endScrub(at seconds: Double) {
        scrubTarget = nil
        seek(to: seconds)  // exact, where the drag let go
        if playingBeforeScrub == true {
            player.play()
            player.rate = playbackRate
        }
        playingBeforeScrub = nil
    }

    // MARK: - Keyboard dispatch

    /// Returns true when the key was consumed.
    func handle(character: Character, shift: Bool, numpad: Bool) -> Bool {
        guard let action = PlayerKeyMap.action(
            character: character, shift: shift, numpad: numpad, settings: skipSettings)
        else { return false }
        // The D key is the ordinary mark, which may move on.
        if action == .toggleMarkedForDeletion {
            markForDeletion()
        } else {
            perform(action)
        }
        return true
    }

    func perform(_ action: PlayerAction) {
        switch action {
        case .seek(let seconds): seek(by: seconds)
        case .playPause: togglePlayPause()
        case .seekToStart: seek(to: item?.clipStartSeconds ?? 0)
        case .seekToNearEnd:
            let end = item?.clipEndSeconds ?? durationSeconds
            if end > 5 { seek(to: end - 5) }
        case .toggleFavorite: toggle(.favorite)
        case .toggleNeedsReview: toggle(.needsReview)
        case .toggleMarkedForDeletion: toggle(.markedForDeletion)
        case .togglePlaybackIssue: toggle(.playbackIssue)
        case .focusUniversalField: focusUniversalField()
        case .readOnScreenText: readOnScreenText()
        }
    }

    /// Esc unwinds EXACTLY ONE layer: an open mark (segment or hide
    /// block), then the focus zone back to the video. Never two —
    /// clearing a mark and losing your place in one press is how you
    /// lose work you could see. The stack ENDS at the video: from there
    /// with nothing open, Esc does nothing at all. Leaving the player is
    /// the Back button's job, never a key you might press by reflex.
    /// Returns true when a layer was unwound.
    @discardableResult
    func unwindOneLayer() -> Bool {
        if pendingSegmentStart != nil || pendingBlockStart != nil {
            cancelSegmentMark()
            pendingBlockStart = nil
            return true
        }
        if zone != .video {
            zone = .video
            return true
        }
        return false
    }

    /// Numpad 2: the Universal field, and a read of the frame at the
    /// playhead into it — ⇧↓ without the reach. A count, not a flag, so
    /// two presses in a row both read.
    private(set) var screenReadRequests = 0

    func readOnScreenText() {
        focusUniversalField()
        screenReadRequests += 1
    }

    /// Numpad 8: open the tag panel if it is closed, point the zone at
    /// it, and hand the keyboard to the Universal field. The panel's
    /// focus mirrors `tagFieldCategoryID`, so setting it IS focusing.
    func focusUniversalField() {
        if !panels.tags { togglePanel(.tags) }
        zone = .tags
        tagFieldCategoryID = Self.universalFieldFocusID
    }

    /// This player's writes, in the order they were asked for: a quick
    /// mark-then-unmark stages and unstages in that order, and where the
    /// video stopped is recorded after the load it follows.
    private let writes = WriteQueue()

    /// One thing that happened here, for the library's history. Nobody
    /// waits on it, and it is not said when it fails: the history is a
    /// convenience, and a line on the player about it would be noise.
    private func record(_ event: PlaybackEvent) {
        let service = service
        writes.send({ try await service.recordPlayback(event) })
    }

    /// Presses whose write has not finished. A finished write shows the
    /// row only when it was the last one — an earlier write must not
    /// overwrite a later press already on screen.
    private var flagWritesInFlight = 0

    /// The mark shows at once; the write, and for the two staging marks
    /// the file move, follow off the main actor. The move (with retries
    /// on a busy or network volume) used to run here, on the main thread,
    /// so a triage key press could freeze the window for as long as the
    /// move took.
    private func toggle(_ flag: PlayerToggleFlag) {
        guard var shown = item else { return }
        let itemID = shown.id
        let on: Bool
        switch flag {
        case .markedForDeletion: on = !shown.markedForDeletion; shown.markedForDeletion = on
        case .playbackIssue: on = !shown.playbackIssue; shown.playbackIssue = on
        case .favorite: on = !shown.isFavorite; shown.isFavorite = on
        case .needsReview: on = !shown.needsReview; shown.needsReview = on
        }
        item = shown

        // Decided from the press, not from whatever the row says by the
        // time the write runs; and queued at the press, so two presses
        // are carried out in the order they were made.
        let service = service
        flagWritesInFlight += 1
        let write = writes.submit { try await service.setFlag(flag, on, itemID: itemID) }
        Task { [weak self] in
            let outcome = await write.value
            guard let self else { return }
            self.flagWritesInFlight -= 1
            switch outcome {
            case .success(let playable):
                let fresh = playable.item, url = playable.url
                // The row as it now is (a staged file has a new path) —
                // for the item still showing, once no later press waits.
                // `fileURL` follows it: Save a Copy, Live Text, the screen
                // read and scrub previews all read it, and it kept naming
                // the path the file had just left.
                if self.item?.id == itemID, self.flagWritesInFlight == 0 {
                    self.item = fresh
                    if let url, url != self.fileURL {
                        self.fileURL = url
                        await ScrubPreviewProvider.shared.releaseGenerator(for: itemID)
                    }
                }
            case .failure(let error):
                self.loadError = "\(error)"
                // The mark was shown before it was made; show the row as
                // it is. If that cannot be read either, the mark stays
                // and the line above says it did not take.
                if self.item?.id == itemID, let actual = try? await service.playable(itemID: itemID),
                   self.item?.id == itemID, self.flagWritesInFlight == 0 {
                    self.item = actual.item
                }
            }
        }
    }

    // MARK: - Tagging

    /// A tag field has a list open (history, analysis, a typed query).
    /// Esc then belongs to the field — it closes the list and leaves the
    /// field empty and focused — rather than to the player's zone
    /// unwinding. The fields keep it current.
    var tagFieldListOpen = false

    /// Which tag category's Add field holds the keyboard — mirrored from
    /// the panel's FocusState so the PLAYER's key handler can walk it.
    /// The handler is where Tab actually arrives: the field's own
    /// key-press modifier never sees Tab, because the outer handler runs
    /// first for every key the text-input guard does not exempt.
    var tagFieldCategoryID: UUID?

    /// Move the keyboard to the next (or previous) search category's
    /// field, wrapping. False when there is nothing to walk — no search
    /// categories — so the caller can fall back to the zone walk.
    /// The Universal field's slot in the focus walk — a fixed sentinel
    /// beside the category IDs, placed by its persisted position.
    static let universalFieldFocusID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111")!

    /// The Tag Analysis Results field's slot in the focus walk — the
    /// second fixed sentinel beside the category IDs.
    static let analysisResultsFieldFocusID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222")!

    /// The panel's Tab order: the search categories in panel order with
    /// the pseudo-fields inserted at their positions. Positions are
    /// indexes into the category list; past the end means last. Fields
    /// sorted by position (ties in declared order: Universal, Results)
    /// and inserted in that order, each shifted by how many went in
    /// before it — so every field lands where its position says
    /// relative to the categories, whatever the other chose. Kept as
    /// the seed for the panel's row order on first run.
    static func tagFieldOrder(
        searchCategoryIDs: [UUID], universalPosition: Int, resultsPosition: Int
    ) -> [UUID] {
        var fields = searchCategoryIDs
        let count = fields.count
        let pseudo: [(id: UUID, position: Int)] = [
            (universalFieldFocusID, min(max(0, universalPosition), count)),
            (analysisResultsFieldFocusID, min(max(0, resultsPosition), count)),
        ]
        let ordered = pseudo.enumerated().sorted {
            ($0.element.position, $0.offset) < ($1.element.position, $1.offset)
        }
        for (inserted, entry) in ordered.enumerated() {
            fields.insert(entry.element.id, at: entry.element.position + inserted)
        }
        return fields
    }

    /// The pre-folded search rows — see `TagSearchEntry`. Rebuilt with
    /// the vocabulary in `refreshTagging`.
    private(set) var tagSearchIndex: [TagSearchEntry] = []

    /// The one fold every comparison goes through — names, aliases and
    /// typed terms alike. Lives on the shared entry type now; kept here
    /// for the per-category fields that call it by this name.
    static func searchFold(_ text: String) -> String { TagSearchEntry.fold(text) }

    /// The panel's rows in order — every category and the three fields —
    /// reconciled against the vocabulary on each refresh. One list, so a
    /// drop means exactly "before that row" and the Tab walk agrees.
    private(set) var panelRows: [PanelRow] = []

    private func refreshPanelRows() {
        let settings = AppSettingsStore.shared.current
        panelRows = TagPanelOrder.rows(
            vocabulary: panelVocabulary.map(\.category.id),
            stored: settings.tagPanelRowOrder,
            seed: (
                universal: settings.universalTagFieldPosition,
                results: settings.analysisResultsFieldPosition))
    }

    /// The panel's drag: move a row before another (nil = to the end).
    /// The list is written to settings, and the categories' order in
    /// the library follows it, so the Categories window and every other
    /// window agree.
    func movePanelRow(_ row: PanelRow, before target: PanelRow?) {
        let rows = TagPanelOrder.moved(panelRows, row, before: target)
        guard rows != panelRows else { return }
        AppSettingsStore.shared.update { $0.tagPanelRowOrder = rows.map(\.key) }
        // The rows follow the setting at once, where the drop was made;
        // the library's own category order follows when the write lands.
        refreshPanelRows()
        let order = rows.compactMap(\.categoryID)
        editTags({ try await $0.setCategoryOrder(order) }) { [weak self] _ in
            self?.refreshTagging()
            self?.recountQueue()
        }
    }

    // MARK: - Tag writes

    /// Tag writes asked for whose result has not been shown yet.
    private(set) var writesInFlight = 0

    /// Nothing asked of the library is still on its way: every write
    /// made here has landed and every panel read has been shown.
    var isSettled: Bool { writesInFlight == 0 && panelLoadsInFlight == 0 }

    /// Queue one change to the library's tags, in the order it was asked
    /// for, and show its result when it lands. The write is queued at
    /// the call, so a run of key presses is carried out in the order
    /// pressed; whatever it names (the item, the tag) was read at the
    /// press, so stepping on meanwhile does not move it to another item.
    /// A write that fails says so on the error line.
    private func editTags<T: Sendable>(
        _ work: @escaping @Sendable (any LibraryService) async throws -> T,
        then show: @escaping @MainActor (T) -> Void
    ) {
        let service = service
        writesInFlight += 1
        let write = writes.submit { try await work(service) }
        Task { [weak self] in
            let outcome = await write.value
            guard let self else { return }
            // After `show`, which starts the panel's re-read: there is no
            // moment between the two when the player looks settled.
            defer { self.writesInFlight -= 1 }
            switch outcome {
            case .success(let value): show(value)
            case .failure(let error): self.loadError = "\(error)"
            }
        }
    }

    /// A tag put on the item joins the tags recently applied. Only
    /// APPLYING records history — removing a tag is not something you
    /// want offered back.
    private func noteApplied(_ tagID: UUID) {
        recentlyAppliedTagIDs.removeAll { $0 == tagID }
        recentlyAppliedTagIDs.insert(tagID, at: 0)
        if recentlyAppliedTagIDs.count > 30 {
            recentlyAppliedTagIDs.removeLast()
        }
    }

    /// Bind a key to a tag. Returns what went wrong, or nil; the
    /// bindings on this model are current when it returns, which the
    /// editor relies on to step to the next free key.
    func setKeyBinding(_ key: String, tagID: UUID, advance: Bool) async -> String? {
        await editKeyBindings { try await $0.setKeyBinding(key, tagID: tagID, advance: advance) }
    }

    func removeKeyBinding(_ key: String) async -> String? {
        await editKeyBindings { try await $0.removeKeyBinding(key) }
    }

    private func editKeyBindings(
        _ work: @escaping @Sendable (any LibraryService) async throws -> Void
    ) async -> String? {
        let service = service
        writesInFlight += 1
        defer { writesInFlight -= 1 }
        if case .failure(let error) = await writes.run({ try await work(service) }) { return "\(error)" }
        await startTaggingRead()?.value
        return nil
    }

    @discardableResult
    func advanceTagField(reverse: Bool) -> Bool {
        // The walk is the panel's order, minus the checkbox categories
        // (they have no field to type in).
        let typable = Set(panelVocabulary.filter { $0.category.displayStyle == .search }.map(\.id))
        let fields = panelRows.compactMap { row -> UUID? in
            if let id = row.categoryID { return typable.contains(id) ? id : nil }
            return row.focusID
        }
        guard !fields.isEmpty else { return false }
        guard let current = tagFieldCategoryID, let index = fields.firstIndex(of: current)
        else {
            tagFieldCategoryID = fields.first
            return true
        }
        let next = (index + (reverse ? fields.count - 1 : 1)) % fields.count
        tagFieldCategoryID = fields[next]
        return true
    }

    /// Only this item's tags: what a tag key, a toggle or an apply of an
    /// existing tag changes. Re-reading the whole vocabulary, every alias
    /// and the key bindings, and rebuilding the search index, on every
    /// press made tagging slow with the size of the library's vocabulary.
    func refreshItemTags() {
        lastTaggingRefreshBegan = .now
        guard let itemID = item?.id else { return }
        itemTagsGeneration += 1
        let generation = itemTagsGeneration, service = service
        panelLoadsInFlight += 1
        Task { [weak self] in
            let answer = await Self.answer { try await service.itemTags(itemID: itemID) }
            guard let self else { return }
            self.panelLoadsInFlight -= 1
            guard self.item?.id == itemID, self.itemTagsGeneration == generation else { return }
            switch answer {
            case .success(let tags): self.itemTags = tags
            case .failure(let error): self.loadError = "\(error)"
            }
        }
        if panels.search { refreshSearch() }
    }
    /// The item's tags and the vocabulary are read together and apart;
    /// each is shown only by the latest read of it.
    private var itemTagsGeneration = 0
    private var vocabularyGeneration = 0

    /// Everything the panel shows: the item's tags, the vocabulary, the
    /// aliases, the key bindings and the search index. For a load, and
    /// for a change to the vocabulary itself.
    func refreshTagging() {
        startTaggingRead()
    }

    /// The read `refreshTagging` starts, for a caller that waits for the
    /// panel to be current. nil with no item on screen.
    @discardableResult
    private func startTaggingRead() -> Task<Void, Never>? {
        lastTaggingRefreshBegan = .now
        guard let itemID = item?.id else { return nil }
        itemTagsGeneration += 1
        vocabularyGeneration += 1
        let tagsGeneration = itemTagsGeneration, wordsGeneration = vocabularyGeneration
        let service = service
        panelLoadsInFlight += 1
        if panels.search { refreshSearch() }
        return Task { [weak self] in
            let answer = await Self.answer { try await service.tagging(itemID: itemID) }
            guard let self else { return }
            self.panelLoadsInFlight -= 1
            switch answer {
            case .success(let tagging):
                // The vocabulary is the library's, whichever item shows.
                if self.vocabularyGeneration == wordsGeneration { self.show(vocabularyOf: tagging) }
                if self.item?.id == itemID, self.itemTagsGeneration == tagsGeneration {
                    self.itemTags = tagging.itemTags
                }
            case .failure(let error):
                if self.item?.id == itemID { self.loadError = "\(error)" }
            }
        }
    }

    /// The vocabulary, the aliases, the key bindings and the search
    /// index built from them.
    private func show(vocabularyOf tagging: PlayerTagging) {
        panelVocabulary = tagging.vocabulary
        refreshPanelRows()
        // An alias IS a name, so typing "SBD" must offer "Soundboard"
        // — the browse sidebar has always matched them and the
        // tagging field, where you are actually typing, did not.
        panelAliases = tagging.aliases
        boundKeys = Dictionary(tagging.keyBindings.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        tagSearchIndex = TagSearchEntry.index(
            vocabulary: panelVocabulary.map { ($0.category, $0.tags) },
            aliases: panelAliases)
    }

    /// What arrived with the item: its panel and its rail, shown in the
    /// turn the item is. Any read still on its way was asked before this
    /// one was answered, and is dropped.
    private func show(panelOf opened: OpenedItem, asked: ContinuousClock.Instant) {
        // When the read was ASKED: a change committed since then is not
        // in it, and the hub's word of that change must not be skipped.
        lastTaggingRefreshBegan = asked
        itemTagsGeneration += 1
        vocabularyGeneration += 1
        segmentsGeneration += 1
        itemTags = opened.tagging?.itemTags ?? []
        if let tagging = opened.tagging { show(vocabularyOf: tagging) }
        show(opened.segments ?? PlayerSegments(clips: [], hideBlocks: []))
        if panels.search { refreshSearch() }
    }

    func hasTag(_ tagID: UUID) -> Bool {
        itemTags.contains { $0.tags.contains { $0.id == tagID } }
    }

    /// The tags applied this session, newest first — the ↑-history every
    /// tag field offers on an empty query. Session-scoped on purpose:
    /// "the tags I've been adding" is a working set, not an archive, and
    /// it resets with the app like the rest of the working state.
    private(set) var recentlyAppliedTagIDs: [UUID] = []

    func toggleTag(_ tagID: UUID) {
        guard let itemID = item?.id else { return }
        editTags({ try await $0.toggleTag(tagID, on: itemID) }) { [weak self] applied in
            if applied { self?.noteApplied(tagID) }
            self?.refreshItemTags()
            self?.recountQueue()
        }
    }

    /// Apply (never remove) one tag — the companion's path in, and the
    /// results field's. Records the session history like a toggle-on
    /// does, and refreshes the panel, so a tag applied from the other
    /// window appears here at once without a broadcast.
    func applyTag(_ tagID: UUID) {
        guard let itemID = item?.id else { return }
        editTags({ try await $0.assignTag(tagID, to: [itemID]) }) { [weak self] _ in
            self?.noteApplied(tagID)
            self?.refreshItemTags()
            self?.recountQueue()
        }
    }

    /// Rename through the kit's single write path (normalization,
    /// per-category uniqueness) — the info bar's pill menu calls this.
    func renameTag(_ tagID: UUID, to name: String) {
        editTags({ try await $0.renameTag(tagID, to: name) }) { [weak self] _ in
            self?.refreshTagging()
            self?.recountQueue()
        }
    }

    /// Autocomplete-create: normalize, find-or-create, assign.
    func addTag(named raw: String, categoryID: UUID) {
        guard let itemID = item?.id else { return }
        editTags({ service in
            let tag = try await service.ensureTag(named: raw, inCategory: categoryID)
            try await service.assignTag(tag.id, to: [itemID])
        }) { [weak self] _ in
            self?.refreshTagging()
            self?.recountQueue()
        }
    }

    /// A recognized on-screen line, kept as another name for a tag.
    /// Aliases are how a future import or search resolves the spelling
    /// that was burned into the video.
    func addAlias(_ alias: String, to tagID: UUID) {
        editTags({ try await $0.addAlias(alias, toTag: tagID) }) { [weak self] _ in
            self?.refreshTagging()
            self?.recountQueue()
        }
    }

    /// Alt+digit: toggle the Nth (1-based) tag of the checkbox category.
    func toggleCheckboxTag(at digit: Int) -> Bool {
        guard let entry = checkboxCategory, digit >= 1, digit <= entry.tags.count else { return false }
        toggleTag(entry.tags[digit - 1].id)
        return true
    }

    /// A user key binding: toggle the bound tag; when the binding says
    /// advance and the tag was APPLIED (not removed), step to the next item.
    func handleBoundKey(_ key: String) -> Bool {
        let canonical = key.count == 1 ? key.lowercased() : key
        guard let binding = boundKeys[canonical], let itemID = item?.id else { return false }
        let tagID = binding.tagID, advances = binding.advance
        editTags({ try await $0.toggleTag(tagID, on: itemID) }) { [weak self] applied in
            guard let self else { return }
            self.refreshItemTags()
            // Still on the item the key was pressed on: a step taken
            // meanwhile is not taken again.
            if advances, applied, self.item?.id == itemID { self.goNext() }
        }
        return true
    }

    // MARK: - Segments

    /// Songs and clips (child rows) and hide blocks (edit instructions),
    /// in one list because they are one thing on screen: a named range.
    /// They stay two records — a song can be tagged and browsed, a hide
    /// block must never reach the grid.
    private(set) var segments: [SegmentRow] = []
    var selectedSegmentID: UUID?

    /// A mark opened and not yet closed. Separate from the hide-block
    /// pending mark: `{`/`}` author a block, the map's segment keys
    /// author a song or a clip, and having one variable for both would
    /// make an overshoot silently change what you were making.
    var pendingSegmentStart: Double?

    func refreshSegments() {
        guard let item else { return }
        let itemID = item.id, parentID = item.parentMediaItemID ?? item.id
        segmentsGeneration += 1
        let generation = segmentsGeneration, service = service
        panelLoadsInFlight += 1
        Task { [weak self] in
            let answer = await Self.answer { try await service.segments(parentID: parentID) }
            guard let self else { return }
            self.panelLoadsInFlight -= 1
            // A rail that could not be read keeps what it shows.
            guard case .success(let found) = answer,
                  self.item?.id == itemID, self.segmentsGeneration == generation
            else { return }
            self.show(found)
        }
    }
    private var segmentsGeneration = 0

    private func show(_ found: PlayerSegments) {
        let children = found.clips, blocks = found.hideBlocks
        segments = (children.map { child in
            SegmentRow(
                id: child.id,
                kind: (child.segmentRole ?? .clip) == .song ? .song : .clip,
                name: child.notes.isEmpty ? (child.segmentRole ?? .clip).defaultName : child.notes,
                start: child.clipStartSeconds ?? 0,
                end: child.clipEndSeconds ?? (child.clipStartSeconds ?? 0))
        } + blocks.map { block in
            SegmentRow(
                id: block.id, kind: .hide, name: "Hide block",
                start: block.startSeconds, end: block.endSeconds)
        }).sorted { $0.start < $1.start }
        hideBlocks = blocks
    }

    var songCount: Int { segments.count { $0.kind == .song } }
    var clipCount: Int { segments.count { $0.kind == .clip } }

    /// Open a mark at the playhead.
    func openSegmentMark() { pendingSegmentStart = currentSeconds }

    /// Close the open mark as a song or a clip. The name comes later —
    /// the rail renames in place, and blocking the close on a text field
    /// is how you lose the range you just marked.
    func closeSegmentMark(as role: SegmentRole) {
        guard let item, let start = pendingSegmentStart, currentSeconds > start else { return }
        do {
            let created = try library.createEmbeddedClip(
                parentID: item.parentMediaItemID ?? item.id,
                startSeconds: start, endSeconds: currentSeconds, role: role)
            pendingSegmentStart = nil
            refreshSegments()
            selectedSegmentID = created.id
        } catch {
            loadError = "\(error)"
        }
    }

    func cancelSegmentMark() { pendingSegmentStart = nil }

    func renameSegment(_ id: UUID, to name: String) {
        do {
            try library.renameSegment(id, to: name)
            refreshSegments()
        } catch {
            loadError = "\(error)"
        }
    }

    /// Remove a rail row, whichever record it is. Nothing is destroyed
    /// either way: a segment is a name over a range, and a hide block is
    /// an instruction the export reads.
    func removeSegment(_ row: SegmentRow) {
        do {
            switch row.kind {
            case .song, .clip: try library.deleteSegment(row.id)
            case .hide: try library.deleteBlock(row.id)
            }
            if selectedSegmentID == row.id { selectedSegmentID = nil }
            refreshSegments()
        } catch {
            loadError = "\(error)"
        }
    }

    /// Play from a segment's start. Selecting a row highlights its bar on
    /// the scrubber; playing it moves the playhead there.
    var selectedSegment: SegmentRow? {
        segments.first { $0.id == selectedSegmentID }
    }

    /// ↑/↓ in the segments zone. Nothing selected yet starts at the end
    /// the arrow came from, so the first press always lands somewhere.
    func stepSegmentSelection(_ delta: Int) {
        guard !segments.isEmpty else { return }
        guard let current = segments.firstIndex(where: { $0.id == selectedSegmentID }) else {
            selectedSegmentID = delta > 0 ? segments.first?.id : segments.last?.id
            return
        }
        let next = (current + delta + segments.count) % segments.count
        selectedSegmentID = segments[next].id
    }

    func playSegment(_ row: SegmentRow) {
        selectedSegmentID = row.id
        seek(to: row.start)
        play()
    }

    // MARK: - Triage

    /// Triage mode exists for one reason: to make the FIXED flag keys
    /// advance without changing what they mean everywhere else. Outside
    /// it, R/W/D toggle and stay put.
    var triageMode = false {
        didSet { if triageMode != oldValue { triageCount = 0 } }
    }
    private(set) var triageCount = 0

    /// Mark and move on. Returns false when there was nothing to mark.
    @discardableResult
    func triageMark(_ action: PlayerAction) -> Bool {
        guard item != nil else { return false }
        perform(action)
        triageCount += 1
        goNext()
        return true
    }

    /// ⇧⌫: toggle the deletion mark and move on — from ANYWHERE in the
    /// window: any zone, either map, inside a tag field, in or out of
    /// Triage mode. Marking advances; unmarking stays put (the bound-key
    /// rule), so what you just restored is still in front of you. Inside
    /// the mode a mark counts as one decision of the pass. Nothing moves
    /// unless the mark actually landed.
    func toggleDeletionAndAdvance() {
        guard let item else { return }
        let marking = !item.markedForDeletion
        perform(.toggleMarkedForDeletion)
        guard marking, self.item?.markedForDeletion == true else { return }
        if triageMode { triageCount += 1 }
        goNext()
    }

    /// D, the ⌫ key and the toolbar button: the ordinary toggle, which
    /// moves on after a mark when the setting says so, and otherwise
    /// stays put.
    func markForDeletion() {
        if AppSettingsStore.shared.current.deletionMarkAdvances {
            toggleDeletionAndAdvance()
        } else {
            perform(.toggleMarkedForDeletion)
        }
    }

    // MARK: - Blocks

    fileprivate(set) var hideBlocks: [VideoBlock] = []
    var pendingBlockStart: Double?

    func refreshBlocks() { refreshSegments() }

    /// The old map's `{`/`}` block taps: first tap opens a block at the
    /// playhead, second closes and saves it.
    func blockTap(open: Bool) {
        guard let item else { return }
        if open {
            pendingBlockStart = currentSeconds
            return
        }
        guard let start = pendingBlockStart, currentSeconds > start else { return }
        let targetID = item.parentMediaItemID ?? item.id
        do {
            _ = try library.addBlock(
                to: targetID, startSeconds: start, endSeconds: currentSeconds, kind: .hide)
            pendingBlockStart = nil
            refreshBlocks()
        } catch {
            loadError = "\(error)"
        }
    }

    func deleteBlock(_ blockID: UUID) {
        try? library.deleteBlock(blockID)
        refreshBlocks()
    }

    // MARK: - Playlist walking

    func goNext() { step(1) }
    func goPrevious() { step(-1) }

    private func step(_ delta: Int) {
        guard let current = queuePositionID ?? item?.id else { return }
        if let index = playlist.firstIndex(of: current) {
            let next = index + delta
            guard playlist.indices.contains(next) else { return }
            load(itemID: playlist[next])
        } else if let edge = delta > 0 ? playlist.first : playlist.last {
            // A refresh dropped the shown item: walk in from the end.
            load(itemID: edge)
        }
    }

    // MARK: - Progress

    private func installObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.playbackDidEnd() }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                // While a seek is in flight the playhead already shows
                // the TARGET; the player's stale time must not drag it
                // back.
                if self.pendingSeekTarget == nil {
                    self.currentSeconds = time.seconds
                }
                if self.durationSeconds == 0,
                   let duration = self.player.currentItem?.duration.seconds,
                   duration.isFinite, duration > 0 {
                    self.durationSeconds = duration
                }
                // Clip loop-back at the out-point, and hide blocks skipped
                // live — the same math the removal edit uses, so what you
                // hear is what the edit keeps. (An open half-authored block
                // doesn't skip.) Never while a seek is still in flight:
                // see `tickSeek`.
                var clip: (start: Double, end: Double)?
                if let end = self.item?.clipEndSeconds {
                    clip = (start: self.item?.clipStartSeconds ?? 0, end: end)
                }
                if let target = SegmentMath.tickSeek(
                    at: time.seconds,
                    seekInFlight: self.pendingSeekTarget != nil,
                    clip: clip,
                    hidden: self.hideBlocks.map { ($0.startSeconds, $0.endSeconds) },
                    skipsHidden: self.isPlaying && self.pendingBlockStart == nil,
                    duration: self.durationSeconds) {
                    self.seek(to: target)
                }
                // One completion tally per session, on first crossing 90%.
                // Segments record no watch history, as at load and on stop.
                if !self.completionRecorded, self.item?.clipStartSeconds == nil,
                   self.durationSeconds > 0,
                   time.seconds > self.durationSeconds * 0.9 {
                    self.completionRecorded = true
                    if let id = self.item?.id {
                        self.record(.completed(itemID: id, at: Date()))
                    }
                }
            }
        }
    }

    private func removeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
    }

    /// A file the player cannot open says so. Nothing used to watch the
    /// item's status, so a damaged or unsupported file was a black frame
    /// that claimed to be playing.
    private func observeStatus(of playerItem: AVPlayerItem) {
        statusObserver = playerItem.observe(\.status) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            let reason = observed.error?.localizedDescription ?? "unknown error"
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === observed else { return }
                self.stopForFailedLoad()
                self.loadError = "This file could not be played: \(reason)"
            }
        }
    }

    /// Write resume position + last-watched. Called on pause, item switch
    /// and window close; clips never record resume state.
    func persistProgress() {
        guard let item, item.clipStartSeconds == nil, currentSeconds > 0 else { return }
        // Stamped now: it is on its way when this returns, and may land
        // after the window has gone.
        record(.stopped(
            itemID: item.id, positionSeconds: currentSeconds,
            durationSeconds: durationSeconds > 0 ? durationSeconds : nil, at: Date()))
    }

    func shutdown() {
        itemShown(nil)
        changeWatch.task?.cancel()
        changeWatch.task = nil
        if let loadObserver { NotificationCenter.default.removeObserver(loadObserver) }
        loadObserver = nil
        analysisSession?.playerDidClose()
        pause()
        nowPlaying.release(self)
        removeObserver()
        if let item {
            Task { await ScrubPreviewProvider.shared.releaseGenerator(for: item.id) }
        }
    }
}

/// The four places the keyboard can be pointed, in Tab order.
enum PlayerZone: String, CaseIterable, Sendable {
    case video, tags, segments, history, queue

    var displayName: String {
        switch self {
        case .video: "Video"
        case .tags: "Tags"
        case .segments: "Segments"
        case .history: "History"
        case .queue: "Queue"
        }
    }

    /// The panel this zone lives in, if any — closing a panel has to be
    /// able to evict the focus sitting in it.
    var panel: PlayerPanel? {
        switch self {
        case .video: nil
        case .tags: .tags
        case .segments: .segments
        case .history: .history
        case .queue: .queue
        }
    }
}

/// One of the player's four collapsible panels.
enum PlayerPanel: String, CaseIterable, Sendable {
    case tags, segments, queue, text, rail, history, search
}

extension PlayerPanels {
    subscript(panel: PlayerPanel) -> Bool {
        get {
            switch panel {
            case .tags: tags
            case .segments: segments
            case .queue: queue
            case .text: text
            case .rail: rail
            case .history: history
            case .search: search
            }
        }
        set {
            switch panel {
            case .tags: tags = newValue
            case .segments: segments = newValue
            case .queue: queue = newValue
            case .text: text = newValue
            case .rail: rail = newValue
            case .history: history = newValue
            case .search: search = newValue
            }
        }
    }
}

/// One row of the segments rail: a song, a clip, or a hide block. Same
/// shape on screen; deliberately not the same record.
struct SegmentRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case song, clip, hide

        var badge: String {
            switch self {
            case .song: "SONG"
            case .clip: "CLIP"
            case .hide: "HIDE"
            }
        }
    }

    var id: UUID
    var kind: Kind
    var name: String
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
    /// Only songs and clips are renameable rows — a hide block has no
    /// name to give, because it is not a thing you can browse to.
    var isRenameable: Bool { kind != .hide }
}

extension Notification.Name {
    /// A player loaded an item. userInfo: `libraryID`, `sender` (the
    /// player's token). History queues over the library re-run on it.
    static let sasPlaybackDidLoad = Notification.Name("sasPlaybackDidLoad")
}
