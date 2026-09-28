import AppKit
import MediaPlayer
import SightsAndSoundsKit

/// The system's Now Playing: Control Center's Now Playing, the
/// keyboard's media keys, headphone buttons. The player neither told the
/// system what was playing nor answered those keys, so play/pause went
/// to whatever else had last played.
///
/// Several players can be open at once; the one that last started
/// playing owns Now Playing, and gives it up when it closes. The system
/// extrapolates the playhead from the rate, so this is updated on play,
/// pause, seek, load and rate — never per tick.
@MainActor
final class NowPlaying {
    /// The app's. Inert in a test run: Now Playing is system-wide, and
    /// players in parallel tests would take it from each other — a test
    /// that means to exercise it passes a live one of its own.
    static let shared = NowPlaying(live: !AppSettingsStore.isUnderTest)

    private let live: Bool

    init(live: Bool) {
        self.live = live
    }

    enum Command { case play, pause, togglePlayPause, next, previous }

    private weak var owner: PlayerModel?
    private var commandsInstalled = false
    private var center: MPNowPlayingInfoCenter { .default() }

    /// A player started playing: it is now what is playing.
    func claim(_ player: PlayerModel) {
        guard live else { return }
        owner = player
        installCommands()
        update(player)
    }

    /// The owner closed: nothing of ours is playing.
    func release(_ player: PlayerModel) {
        guard owner === player else { return }
        owner = nil
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    /// The owner's state changed. Other players' changes are ignored.
    func update(_ player: PlayerModel) {
        guard owner === player else { return }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: player.item?.fileName ?? player.title,
            MPMediaItemPropertyPlaybackDuration: player.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.playbackRate) : 0,
            MPNowPlayingInfoPropertyMediaType: (player.isAudio
                ? MPNowPlayingInfoMediaType.audio : MPNowPlayingInfoMediaType.video).rawValue,
        ]
        center.playbackState = player.isPlaying ? .playing : .paused
    }

    /// What a media key or a Now Playing control asks of the owner.
    func perform(_ command: Command) {
        guard let owner else { return }
        switch command {
        case .play: owner.play()
        case .pause: owner.pause()
        case .togglePlayPause: owner.togglePlayPause()
        case .next: owner.goNext()
        case .previous: owner.goPrevious()
        }
    }

    private func installCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let commands = MPRemoteCommandCenter.shared()
        let pairs: [(MPRemoteCommand, Command)] = [
            (commands.playCommand, .play),
            (commands.pauseCommand, .pause),
            (commands.togglePlayPauseCommand, .togglePlayPause),
            (commands.nextTrackCommand, .next),
            (commands.previousTrackCommand, .previous),
        ]
        for (remote, command) in pairs {
            remote.isEnabled = true
            remote.addTarget { [weak self] _ in
                Task { @MainActor in self?.perform(command) }
                return .success
            }
        }
        commands.changePlaybackPositionCommand.isEnabled = true
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.owner?.seek(to: seconds) }
            return .success
        }
    }
}
