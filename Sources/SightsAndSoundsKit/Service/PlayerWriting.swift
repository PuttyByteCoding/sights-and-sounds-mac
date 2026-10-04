import Foundation

/// What the player changes as it plays.
public protocol PlayerWriting: Sendable {
    /// One thing that happened in a player. The time is the player's,
    /// taken when it happened and not when the request arrived.
    func recordPlayback(_ event: PlaybackEvent) async throws

    /// Set or clear one flag on an item. Marking for deletion and
    /// marking a playback issue stage the file, and clearing them moves
    /// it back. Returns the row and where it plays from as they are
    /// afterwards: a staged file has a new path.
    func setFlag(_ flag: PlayerToggleFlag, _ on: Bool, itemID: UUID) async throws -> Playable
}

public enum PlaybackEvent: Codable, Equatable, Sendable {
    /// An item was loaded. A load is a watch, even a brief one.
    case started(itemID: UUID, at: Date)
    /// Playback paused, moved to another item, or the window closed.
    case stopped(itemID: UUID, positionSeconds: Double, durationSeconds: Double?, at: Date)
    /// Playback first crossed most of the way through.
    case completed(itemID: UUID, at: Date)
}
