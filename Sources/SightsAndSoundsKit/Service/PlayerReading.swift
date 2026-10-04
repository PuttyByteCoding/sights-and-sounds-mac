import Foundation

/// What the player reads.
public protocol PlayerReading: Sendable {
    /// An item and where its file can be played from, at one moment. The
    /// item is nil when it no longer exists; the URL is nil while its
    /// source is out of reach. A segment plays from its parent's file.
    func playable(itemID: UUID) async throws -> Playable

    /// An item as the player opens it: what `playable` answers, and with
    /// it what its tag panel and segment rail show. One answer, so a
    /// newly opened item never stands over the last one's tags.
    func opened(itemID: UUID) async throws -> OpenedItem

    /// The tags one item wears, by category: what a toggle changes.
    func itemTags(itemID: UUID) async throws -> [CategoryTags]

    /// Everything the tag panel draws for one item: its tags, the whole
    /// vocabulary, the aliases and the key bindings.
    func tagging(itemID: UUID) async throws -> PlayerTagging

    /// A video's segments and its hide blocks.
    func segments(parentID: UUID) async throws -> PlayerSegments

    /// The library's search formats and what they are built from for
    /// one item.
    func searchContext(itemID: UUID) async throws -> SearchContext

    /// What has been watched, most recent first.
    func recentlyWatched(limit: Int) async throws -> [MediaItem]

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

public struct OpenedItem: Codable, Equatable, Sendable {
    public var playable: Playable
    /// nil when the item no longer exists.
    public var tagging: PlayerTagging?
    /// Of the video the item is, or is a segment of. nil when the item
    /// no longer exists.
    public var segments: PlayerSegments?

    public init(playable: Playable, tagging: PlayerTagging?, segments: PlayerSegments?) {
        self.playable = playable
        self.tagging = tagging
        self.segments = segments
    }
}

public struct PlayerTagging: Codable, Equatable, Sendable {
    /// What the item wears.
    public var itemTags: [CategoryTags]
    /// Every category in panel order, those hidden from Browse included:
    /// the panel is where they are set.
    public var vocabulary: [CategoryTags]
    /// By tag.
    public var aliases: [UUID: [String]]
    public var keyBindings: [TagKeyBinding]

    public init(
        itemTags: [CategoryTags], vocabulary: [CategoryTags],
        aliases: [UUID: [String]], keyBindings: [TagKeyBinding]
    ) {
        self.itemTags = itemTags
        self.vocabulary = vocabulary
        self.aliases = aliases
        self.keyBindings = keyBindings
    }
}

public struct PlayerSegments: Codable, Equatable, Sendable {
    /// The video's songs and clips.
    public var clips: [MediaItem]
    public var hideBlocks: [VideoBlock]

    public init(clips: [MediaItem], hideBlocks: [VideoBlock]) {
        self.clips = clips
        self.hideBlocks = hideBlocks
    }
}

public struct SearchContext: Codable, Equatable, Sendable {
    public var formats: SearchFormats
    /// nil when the item no longer exists.
    public var subject: SearchSubject?

    public init(formats: SearchFormats, subject: SearchSubject?) {
        self.formats = formats
        self.subject = subject
    }
}
