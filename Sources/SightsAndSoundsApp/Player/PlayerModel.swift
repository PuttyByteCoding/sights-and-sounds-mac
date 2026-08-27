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
    /// The filtered listing the item was opened from; ←/→ walk it.
    let playlist: [UUID]

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

    // MARK: - Tagging state

    var showTagPanel = false
    private(set) var itemTags: [CategoryTags] = []
    private(set) var panelVocabulary: [CategoryTags] = []
    private(set) var boundKeys: [String: TagKeyBinding] = [:]

    /// The category whose tags Alt+1…9 toggles: the first checkbox-mode
    /// category by sort order (old app rule — exactly one gets the keys).
    var checkboxCategory: CategoryTags? {
        panelVocabulary.first { $0.category.displayAsCheckboxes }
    }

    init(request: PlayerRequest, library: LibraryDatabase, appDatabase: AppDatabase?) {
        self.library = library
        self.libraryID = request.libraryID
        self.playlist = request.playlist
        _ = appDatabase  // legacy pref migrates into settings.json at launch
        skipSettings = AppSettingsStore.shared.current.skip
        load(itemID: request.itemID)
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

    // MARK: - Blocks

    private(set) var hideBlocks: [VideoBlock] = []
    var pendingBlockStart: Double?

    func refreshBlocks() {
        guard let item else { return }
        let targetID = item.parentMediaItemID ?? item.id
        hideBlocks = (try? library.blocks(of: targetID).filter { $0.kind == .hide }) ?? []
    }

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

    /// Save the pending range as an embedded clip on the current item
    /// (authoring on a clip targets its parent).
    func savePendingClip(named name: String) {
        guard let item, let start = pendingClipStart, let end = pendingClipEnd else { return }
        do {
            let parentID = item.parentMediaItemID ?? item.id
            _ = try library.createEmbeddedClip(
                parentID: parentID,
                name: name.isEmpty ? "clip" : name,
                startSeconds: start, endSeconds: end)
            cancelPendingClip()
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: - Playlist walking

    func goNext() { step(1) }
    func goPrevious() { step(-1) }

    private func step(_ delta: Int) {
        guard let item, let index = playlist.firstIndex(of: item.id) else { return }
        let next = index + delta
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
