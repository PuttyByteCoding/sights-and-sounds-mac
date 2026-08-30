import AVFoundation
import Foundation
import SwiftUI
import SightsAndSoundsKit

/// One player window's state. Owns playback and nothing else — tagging,
/// OCR and clip authoring stay separate features (the 4,382-line lesson).
@Observable @MainActor
final class PlayerModel {
    let library: LibraryDatabase
    let libraryID: UUID
    /// The filtered listing the item was opened from; ←/→ walk it. It
    /// FOLLOWS the browse filter — see `updatePlaylist` — rather than
    /// being the snapshot the player opened with.
    private(set) var playlist: [UUID]

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
        didSet { if isPlaying { player.rate = playbackRate } }
    }

    private var skipSettings = SkipSettings()
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var completionRecorded = false
    private let fileAccess: any FileAccess = LiveFileAccess()

    var title: String { item?.fileName ?? "Player" }
    var isAudio: Bool { item?.kind == .audio }

    /// Which map the keys answer to. Read per use, so changing it in
    /// Settings applies without reopening the player.
    var keyMap: KeyMapStyle { AppSettingsStore.shared.current.keyMap }

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
    }

    var showsRail: Bool { panels.tags || panels.segments }

    /// The zones actually on screen, in Tab order. A collapsed panel is
    /// not a place focus can go.
    var availableZones: [PlayerZone] {
        var zones: [PlayerZone] = [.video]
        if panels.tags { zones.append(.tags) }
        if panels.segments { zones.append(.segments) }
        if panels.queue, !playlist.isEmpty { zones.append(.queue) }
        return zones
    }

    // MARK: - Tagging state

    /// Kept for the `T` key's older name; the panel itself is `panels.tags`.
    var showTagPanel: Bool {
        get { panels.tags }
        set { panels.tags = newValue }
    }
    private(set) var itemTags: [CategoryTags] = []
    private(set) var panelVocabulary: [CategoryTags] = []
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

    init(request: PlayerRequest, library: LibraryDatabase, appDatabase: AppDatabase?) {
        self.library = library
        self.libraryID = request.libraryID
        self.playlist = request.playlist
        _ = appDatabase  // legacy pref migrates into settings.json at launch
        skipSettings = AppSettingsStore.shared.current.skip
        load(itemID: request.itemID)
        loadQueueItems()
    }

    // MARK: - Play queue

    /// The playlist's rows, in playlist order — the queue strip's data.
    /// Re-fetched whenever the browse filter reshapes the listing, off
    /// the main actor.
    private(set) var queueItems: [MediaItem] = []

    /// Where the playing item sat when the filter dropped it out of the
    /// playlist, so ← and → still move from a sensible place. Nil while
    /// the item is in the playlist.
    private var orphanIndex: Int?

    /// The browse listing changed under us. The playlist follows it, but
    /// **playback does not stop**: an item that no longer matches keeps
    /// playing to its end and simply is not in the queue any more. A
    /// filter click killing what you are three minutes into would be a
    /// worse surprise than a queue that no longer contains it.
    func updatePlaylist(_ ids: [UUID]) {
        guard ids != playlist else { return }
        if let current = item?.id, !ids.contains(current) {
            // Its natural position in the new list: however many of the
            // items ahead of it survived the filter.
            orphanIndex = playlist.prefix { $0 != current }.filter(ids.contains).count
        } else {
            orphanIndex = nil
        }
        playlist = ids
        loadQueueItems()
    }

    private func loadQueueItems() {
        guard !playlist.isEmpty else {
            queueItems = []
            return
        }
        let library = library, playlist = playlist
        Task.detached(priority: .userInitiated) { [weak self] in
            // Explicit return type — the async `read` overload's
            // inference is ambiguous to the CI toolchain (Xcode 16).
            let rows: [MediaItem] = (try? await library.writer.read { db -> [MediaItem] in
                try MediaItem.fetchAll(db, keys: playlist)
            }) ?? []
            let position = Dictionary(
                uniqueKeysWithValues: playlist.enumerated().map { ($1, $0) })
            let ordered = rows.sorted { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }
            await MainActor.run { [weak self] in self?.queueItems = ordered }
        }
    }

    /// Resolved file URL for a QUEUE row (nil while its source is
    /// offline) — cached thumbnails render regardless.
    func queueFileURL(for item: MediaItem) -> URL? {
        (try? library.resolvedFileURL(for: item, fileAccess: fileAccess)) ?? nil
    }

    // MARK: - Loading

    /// Loads race under fast ←/→ — the counter lets only the newest
    /// apply, and the fetch + file resolution run off the main actor
    /// (resolvedFileURL touches the filesystem; a slow volume used to
    /// hitch the UI on every item switch).
    private var loadGeneration = 0

    func load(itemID: UUID) {
        persistProgress()
        removeObserver()
        completionRecorded = false
        loadError = nil
        loadGeneration += 1
        let generation = loadGeneration
        let library = library, fileAccess = fileAccess

        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<(MediaItem?, URL?), Error>
            do {
                let loaded = try await library.writer.read { try MediaItem.fetchOne($0, key: itemID) }
                // Embedded clips resolve to the PARENT's file.
                let url = try loaded.flatMap {
                    try library.resolvedFileURL(for: $0, fileAccess: fileAccess)
                }
                outcome = .success((loaded, url))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                switch outcome {
                case .success(let (loaded, url)): self.apply(loaded: loaded, url: url)
                case .failure(let error): self.loadError = "\(error)"
                }
            }
        }
    }

    private func apply(loaded: MediaItem?, url: URL?) {
        guard let loaded else {
            loadError = "The item no longer exists."
            return
        }
        guard let url else {
            item = loaded
            loadError = "The item's source is offline."
            return
        }
        item = loaded
        fileURL = url
        durationSeconds = loaded.durationSeconds ?? 0

        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        // Each item is a fresh start: videos follow the setting,
        // audio never begins muted (it would just be silence).
        isMuted = loaded.kind == .video && AppSettingsStore.shared.current.startVideosMuted
        player.isMuted = isMuted
        isLooping = AppSettingsStore.shared.current.loopVideos
        installObserver()
        refreshTagging()
        refreshBlocks()

        // Clips start at their in-point; everything else resumes.
        if let start = loaded.clipStartSeconds {
            seek(to: start)
        } else if let resume = loaded.resumePositionSeconds {
            seek(to: resume)
        }
        play()
    }

    private(set) var fileURL: URL?

    // MARK: - Transport

    func play() {
        player.play()
        player.rate = playbackRate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        persistProgress()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    /// Session-scoped: flipping it never outlives the current item —
    /// the next load re-applies the start-muted setting.
    private(set) var isMuted = false

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
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
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, durationSeconds > 0 ? min(seconds, durationSeconds) : seconds)
        currentSeconds = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(by delta: Double) { seek(to: currentSeconds + delta) }

    // MARK: - Keyboard dispatch

    /// Returns true when the key was consumed.
    func handle(character: Character, shift: Bool, numpad: Bool) -> Bool {
        guard let action = PlayerKeyMap.action(
            character: character, shift: shift, numpad: numpad, settings: skipSettings)
        else { return false }
        perform(action)
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
        }
    }

    private func toggle(_ flag: PlayerToggleFlag) {
        guard let item else { return }
        do {
            // Deletion and playback-issue marks stage the file physically
            // (and unstage on the way back); the other flags are plain.
            switch flag {
            case .markedForDeletion:
                item.markedForDeletion
                    ? try library.unstage(.toDelete, itemID: item.id)
                    : try library.stage(.toDelete, itemID: item.id)
            case .playbackIssue:
                item.playbackIssue
                    ? try library.unstage(.playbackIssue, itemID: item.id)
                    : try library.stage(.playbackIssue, itemID: item.id)
            case .favorite, .needsReview:
                _ = try library.toggleFlag(flag, itemID: item.id)
            }
            self.item = try library.writer.read { try MediaItem.fetchOne($0, key: item.id) }
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: - Tagging

    func refreshTagging() {
        guard let item else { return }
        do {
            itemTags = try library.tags(of: item.id).map { CategoryTags(category: $0.category, tags: $0.tags) }
            panelVocabulary = try library.vocabulary().map { CategoryTags(category: $0.category, tags: $0.tags) }
            boundKeys = Dictionary(
                uniqueKeysWithValues: try library.keyBindings().map { ($0.key, $0) })
        } catch {
            loadError = "\(error)"
        }
    }

    func hasTag(_ tagID: UUID) -> Bool {
        itemTags.contains { $0.tags.contains { $0.id == tagID } }
    }

    func toggleTag(_ tagID: UUID) {
        guard let item else { return }
        do {
            _ = try library.toggleTag(tagID, on: item.id)
            refreshTagging()
        } catch {
            loadError = "\(error)"
        }
    }

    /// Rename through the kit's single write path (normalization,
    /// per-category uniqueness) — the info bar's pill menu calls this.
    func renameTag(_ tagID: UUID, to name: String) {
        do {
            try library.renameTag(tagID, to: name)
            refreshTagging()
        } catch {
            loadError = "\(error)"
        }
    }

    /// Autocomplete-create: normalize, find-or-create, assign.
    func addTag(named raw: String, categoryID: UUID) {
        guard let item else { return }
        do {
            let tag = try library.ensureTag(named: raw, inCategory: categoryID)
            try library.assignTag(tag.id, to: item.id)
            refreshTagging()
        } catch {
            loadError = "\(error)"
        }
    }

    /// A recognized on-screen line, kept as another name for a tag.
    /// Aliases are how a future import or search resolves the spelling
    /// that was burned into the video.
    func addAlias(_ alias: String, to tagID: UUID) {
        do {
            try library.addAlias(alias, toTag: tagID)
            refreshTagging()
        } catch {
            loadError = "\(error)"
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
        guard let binding = boundKeys[canonical], let item else { return false }
        do {
            let applied = try library.toggleTag(binding.tagID, on: item.id)
            refreshTagging()
            if binding.advance && applied { goNext() }
        } catch {
            loadError = "\(error)"
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
        let parentID = item.parentMediaItemID ?? item.id
        let children = (try? library.clips(of: parentID)) ?? []
        let blocks = (try? library.blocks(of: parentID).filter { $0.kind == .hide }) ?? []
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

    // MARK: - Clip authoring

    var pendingClipStart: Double?
    var pendingClipEnd: Double?

    func setClipIn() { pendingClipStart = currentSeconds }
    func setClipOut() { pendingClipEnd = currentSeconds }
    func cancelPendingClip() {
        pendingClipStart = nil
        pendingClipEnd = nil
    }

    var pendingClipReady: Bool {
        if let start = pendingClipStart, let end = pendingClipEnd { return end > start }
        return false
    }

    /// Save the pending range as a segment on the current item
    /// (authoring on a clip targets its parent).
    func savePendingClip(named name: String, role: SegmentRole = .clip) {
        guard let item, let start = pendingClipStart, let end = pendingClipEnd else { return }
        do {
            let parentID = item.parentMediaItemID ?? item.id
            _ = try library.createEmbeddedClip(
                parentID: parentID, name: name,
                startSeconds: start, endSeconds: end, role: role)
            cancelPendingClip()
            refreshSegments()
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: - Playlist walking

    func goNext() { step(1) }
    func goPrevious() { step(-1) }

    private func step(_ delta: Int) {
        guard let item else { return }
        let base: Int
        if let index = playlist.firstIndex(of: item.id) {
            base = index
        } else if let orphan = orphanIndex {
            // The filter dropped what is playing. It keeps playing, but
            // the arrows have to move from somewhere — so they move from
            // the gap it left: forward onto the survivor that took its
            // place, back onto the one before it. Without this, ← and →
            // would silently stop working the moment a filter changed.
            base = delta > 0 ? orphan - 1 : orphan
        } else {
            return
        }
        let next = base + delta
        guard playlist.indices.contains(next) else { return }
        load(itemID: playlist[next])
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
                self.currentSeconds = time.seconds
                if self.durationSeconds == 0,
                   let duration = self.player.currentItem?.duration.seconds,
                   duration.isFinite, duration > 0 {
                    self.durationSeconds = duration
                }
                // Clip loop-back at the out-point.
                if let end = self.item?.clipEndSeconds, time.seconds >= end {
                    self.seek(to: self.item?.clipStartSeconds ?? 0)
                }
                // Hide blocks skip live — the same math the removal edit
                // uses, so what you hear is what the edit keeps. (An open
                // half-authored block doesn't skip.)
                if self.isPlaying, self.pendingBlockStart == nil,
                   let target = SegmentMath.skipTarget(
                       at: time.seconds,
                       hidden: self.hideBlocks.map { ($0.startSeconds, $0.endSeconds) },
                       duration: self.durationSeconds) {
                    self.seek(to: target)
                }
                // One completion tally per session, on first crossing 90%.
                if !self.completionRecorded, self.durationSeconds > 0,
                   time.seconds > self.durationSeconds * 0.9 {
                    self.completionRecorded = true
                    if let id = self.item?.id {
                        try? self.library.recordPlaybackCompletion(itemID: id)
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
    }

    /// Write resume position + last-watched. Called on pause, item switch
    /// and window close; clips never record resume state.
    func persistProgress() {
        guard let item, item.clipStartSeconds == nil, currentSeconds > 0 else { return }
        try? library.recordPlaybackStop(
            itemID: item.id, positionSeconds: currentSeconds,
            durationSeconds: durationSeconds > 0 ? durationSeconds : nil)
    }

    func shutdown() {
        pause()
        removeObserver()
        if let item {
            Task { await ScrubPreviewProvider.shared.releaseGenerator(for: item.id) }
        }
    }
}

/// The four places the keyboard can be pointed, in Tab order.
enum PlayerZone: String, CaseIterable, Sendable {
    case video, tags, segments, queue

    var displayName: String {
        switch self {
        case .video: "Video"
        case .tags: "Tags"
        case .segments: "Segments"
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
        case .queue: .queue
        }
    }
}

/// One of the player's four collapsible panels.
enum PlayerPanel: String, CaseIterable, Sendable {
    case tags, segments, queue, text
}

extension PlayerPanels {
    subscript(panel: PlayerPanel) -> Bool {
        get {
            switch panel {
            case .tags: tags
            case .segments: segments
            case .queue: queue
            case .text: text
            }
        }
        set {
            switch panel {
            case .tags: tags = newValue
            case .segments: segments = newValue
            case .queue: queue = newValue
            case .text: text = newValue
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
