import Foundation

/// The Browse grid's listing.
public protocol BrowseListing: Sendable {
    /// The items a filter lists, and what describes them at that same
    /// moment: one answer, so the grid and the numbers beside it can
    /// never be from different filters.
    func listing(_ request: ListingRequest) async throws -> BrowseListingAnswer
}

public struct ListingRequest: Codable, Equatable, Sendable {
    public var filter: MediaFilter
    public var kinds: MediaKinds
    public var ordering: MediaOrdering
    /// Each item's tag pills and the categories it has no tag from: read
    /// only when the tiles show them, since it reads every tag link.
    public var includesTagData: Bool
    /// Which items are in a pending duplicate pair: read only when the
    /// tiles badge it.
    public var includesDuplicateData: Bool
    /// How many recent snapshots per item the tile menus offer.
    public var snapshotsPerItem: Int

    public init(
        filter: MediaFilter, kinds: MediaKinds, ordering: MediaOrdering,
        includesTagData: Bool, includesDuplicateData: Bool, snapshotsPerItem: Int
    ) {
        self.filter = filter
        self.kinds = kinds
        self.ordering = ordering
        self.includesTagData = includesTagData
        self.includesDuplicateData = includesDuplicateData
        self.snapshotsPerItem = snapshotsPerItem
    }
}

public struct BrowseListingAnswer: Codable, Equatable, Sendable {
    /// Every item the filter lists, in the order asked for.
    public var items: [MediaItem]
    /// By item, in category order then by name. Empty unless asked for.
    public var tags: [UUID: [TagPill]]
    /// By item: the names of the browse categories it carries no tag
    /// from. Empty unless tag data was asked for.
    public var missingCategories: [UUID: [String]]
    /// Empty unless asked for.
    public var duplicateIDs: Set<UUID>
    /// Per tag, under the filter: "if I added this, how many would
    /// survive".
    public var filteredTagCounts: [UUID: Int]
    /// Per category, under the filter: items with no tag from it.
    public var filteredMissingCounts: [UUID: Int]
    /// What the tiles' context menus ask about, fetched here once: a
    /// menu's items are built every time a tile's body runs.
    public var menuFacts: TileMenuFacts

    public init(
        items: [MediaItem], tags: [UUID: [TagPill]] = [:], missingCategories: [UUID: [String]] = [:],
        duplicateIDs: Set<UUID> = [], filteredTagCounts: [UUID: Int], filteredMissingCounts: [UUID: Int],
        menuFacts: TileMenuFacts
    ) {
        self.items = items
        self.tags = tags
        self.missingCategories = missingCategories
        self.duplicateIDs = duplicateIDs
        self.filteredTagCounts = filteredTagCounts
        self.filteredMissingCounts = filteredMissingCounts
        self.menuFacts = menuFacts
    }
}

/// A tag as a tile draws it. Batched with the listing (never a query per
/// cell) and carrying the category's stored hue, so a pill is the same
/// colour here, in the sidebar and in the player.
public struct TagPill: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var categoryID: UUID
    public var categoryName: String
    public var colorIndex: Int

    public init(id: UUID, name: String, categoryID: UUID, categoryName: String, colorIndex: Int) {
        self.id = id
        self.name = name
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.colorIndex = colorIndex
    }
}
