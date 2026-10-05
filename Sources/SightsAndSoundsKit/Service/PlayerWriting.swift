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

    // The tag panel. Applying a tag to items is `BrowseWriting`'s.

    /// Put the tag on the item, or take it off. Returns whether the item
    /// wears it afterwards. In a single-select category, putting one on
    /// takes the others off.
    func toggleTag(_ tagID: UUID, on itemID: UUID) async throws -> Bool

    /// Refused when the category already has a tag of that name.
    func renameTag(_ tagID: UUID, to name: String) async throws

    /// The tag of that name in the category, made if it is not there.
    func ensureTag(named name: String, inCategory categoryID: UUID) async throws -> Tag

    /// Another name for a tag. An empty one is not added.
    func addAlias(_ alias: String, toTag tagID: UUID) async throws

    /// The order the categories are listed in, everywhere.
    func setCategoryOrder(_ categoryIDs: [UUID]) async throws

    /// Bind a key to a tag, replacing what the key was bound to.
    func setKeyBinding(_ key: String, tagID: UUID, advance: Bool) async throws
    func removeKeyBinding(_ key: String) async throws
}

public enum PlaybackEvent: Codable, Equatable, Sendable {
    /// An item was loaded. A load is a watch, even a brief one.
    case started(itemID: UUID, at: Date)
    /// Playback paused, moved to another item, or the window closed.
    case stopped(itemID: UUID, positionSeconds: Double, durationSeconds: Double?, at: Date)
    /// Playback first crossed most of the way through.
    case completed(itemID: UUID, at: Date)
}
