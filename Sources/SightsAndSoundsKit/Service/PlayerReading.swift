import Foundation

/// What the player reads.
public protocol PlayerReading: Sendable {
    /// An item and where its file can be played from, at one moment. The
    /// item is nil when it no longer exists; the URL is nil while its
    /// source is out of reach. A segment plays from its parent's file.
    func playable(itemID: UUID) async throws -> Playable

    /// These items, in the order given, minus any that no longer exist.
    func items(ids: [UUID]) async throws -> [MediaItem]

    /// What a queue definition lists now.
    func queueItems(_ definition: QueueDefinition) async throws -> [MediaItem]

    /// By item, the tags it wears.
    func tagMembership(itemIDs: [UUID]) async throws -> [UUID: Set<UUID>]

    /// The text scan queued or running for an item, if there is one.
    func pendingTextScan(itemID: UUID) async throws -> UUID?

    /// The text read from an item's video, in time order.
    func textLines(itemID: UUID) async throws -> [OcrTextLine]
}

public struct Playable: Codable, Equatable, Sendable {
    public var item: MediaItem?
    /// What a player opens. For a library on this Mac, the file.
    public var url: URL?

    public init(item: MediaItem?, url: URL?) {
        self.item = item
        self.url = url
    }
}
