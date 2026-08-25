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
    var loadError: String?

    var playbackRate: Float = 1.0 {
        didSet { if isPlaying { player.rate = playbackRate } }
    }

    private var skipSettings = SkipSettings()
    private var timeObserver: Any?
    private var completionRecorded = false
    private let fileAccess: any FileAccess = LiveFileAccess()

    var title: String { item?.fileName ?? "Player" }
    var isAudio: Bool { item?.kind == .audio }

    init(request: PlayerRequest, library: LibraryDatabase, appDatabase: AppDatabase?) {
        self.library = library
        self.libraryID = request.libraryID
        self.playlist = request.playlist
        if let appDatabase,
           let raw = try? appDatabase.preference("playbackSkips"),
           let decoded = try? JSONDecoder().decode(SkipSettings.self, from: Data(raw.utf8)) {
            skipSettings = decoded
        }
        load(itemID: request.itemID)
    }

    // MARK: - Loading

    func load(itemID: UUID) {
        persistProgress()
        removeObserver()
        completionRecorded = false
        loadError = nil

        do {
            guard let loaded = try library.writer.read({ try MediaItem.fetchOne($0, key: itemID) })
            else {
                loadError = "The item no longer exists."
                return
            }
            guard let source = try library.sources().first(where: { $0.id == loaded.sourceID }),
                  source.enabled, source.isOnline(using: fileAccess)
            else {
                item = loaded
                loadError = "The item's source is offline."
                return
            }
            item = loaded
            let url = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                .appendingPathComponent(loaded.relativePath)
            fileURL = url
            durationSeconds = loaded.durationSeconds ?? 0

            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            installObserver()

            // Clips start at their in-point; everything else resumes.
            if let start = loaded.clipStartSeconds {
                seek(to: start)
            } else if let resume = loaded.resumePositionSeconds {
                seek(to: resume)
            }
            play()
        } catch {
            loadError = "\(error)"
        }
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
            _ = try library.toggleFlag(flag, itemID: item.id)
            self.item = try library.writer.read { try MediaItem.fetchOne($0, key: item.id) }
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
