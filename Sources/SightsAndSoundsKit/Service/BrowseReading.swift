import Foundation

/// What the Browse window's sidebar and footer read.
public protocol BrowseReading: Sendable {
    /// Every source, in sidebar order, with whether its files can be
    /// reached right now.
    func sourceStates() async throws -> [SourceState]

    /// The categories Browse shows, each with its tags, and every tag's
    /// aliases. Categories hidden from Browse are left out.
    func browseVocabulary() async throws -> BrowseVocabulary

    /// The folder tree of each enabled source and every sidebar number,
    /// under the kinds shown. One answer, so the trees and the counts
    /// cannot be from different moments.
    func sidebarCounts(kinds: MediaKinds) async throws -> SidebarCounts

    /// Duplicate candidates still waiting for a decision.
    func pendingDuplicateCount() async throws -> Int

    func savedFilters() async throws -> [SavedFilter]

    /// How many items each saved filter lists under the kinds shown. A
    /// saved filter that can no longer be read has no count.
    func savedFilterCounts(kinds: MediaKinds) async throws -> [UUID: Int]

    /// What a tile's context menu needs to know about the items it may
    /// be opened on, asked once for the whole library.
    func tileMenuFacts(snapshotsPerItem: Int) async throws -> TileMenuFacts

    /// The thumbnail sweep's progress, or nil when none is queued or
    /// running.
    func thumbnailQueueStatus() async throws -> ThumbnailQueueStatus?

    /// The thumbnail the library's own Mac has already made for an item,
    /// as JPEG bytes; nil when it has made none. For a window on another
    /// Mac, which cannot make one without fetching the video to do it. A
    /// window on the library's Mac reads the same file for itself.
    func storedThumbnail(itemID: UUID) async throws -> Data?
}

/// A source, and whether its files are within reach.
public struct SourceState: Codable, Equatable, Sendable, Identifiable {
    public var source: Source
    /// Enabled, and its folder reachable — as seen from the machine that
    /// holds the files, which is the only one that can say.
    public var isOnline: Bool

    public var id: UUID { source.id }

    public init(source: Source, isOnline: Bool) {
        self.source = source
        self.isOnline = isOnline
    }
}

/// Per-category tags for the filter panel.
public struct CategoryTags: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { category.id }
    public let category: TagCategory
    public let tags: [Tag]

    public init(category: TagCategory, tags: [Tag]) {
        self.category = category
        self.tags = tags
    }
}

public struct BrowseVocabulary: Codable, Equatable, Sendable {
    /// In sidebar order.
    public var categories: [CategoryTags]
    /// By tag.
    public var aliases: [UUID: [String]]

    public init(categories: [CategoryTags], aliases: [UUID: [String]]) {
        self.categories = categories
        self.aliases = aliases
    }
}

public struct SidebarCounts: Codable, Equatable, Sendable {
    /// By source; enabled sources only.
    public var trees: [UUID: [FolderNode]]
    public var counts: BrowseCounts

    public init(trees: [UUID: [FolderNode]], counts: BrowseCounts) {
        self.trees = trees
        self.counts = counts
    }
}

public struct TileMenuFacts: Codable, Equatable, Sendable {
    /// Items with at least one hide block.
    public var hideBlockItemIDs: Set<UUID>
    /// Each item's most recent snapshots, newest first.
    public var snapshotRefs: [UUID: [SnapshotRef]]

    public init(hideBlockItemIDs: Set<UUID>, snapshotRefs: [UUID: [SnapshotRef]]) {
        self.hideBlockItemIDs = hideBlockItemIDs
        self.snapshotRefs = snapshotRefs
    }
}

/// The thumbnail sweep's live progress. Counts come from the job row and
/// `thumbnailState`, the sweep's own bookkeeping, never re-derived from
/// disk.
public struct ThumbnailQueueStatus: Codable, Equatable, Sendable {
    public var current: Int
    public var total: Int?
    public var failed: Int

    public init(current: Int, total: Int?, failed: Int) {
        self.current = current
        self.total = total
        self.failed = failed
    }
}
