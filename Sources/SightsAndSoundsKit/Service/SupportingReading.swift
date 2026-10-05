import Foundation

/// The smaller reads around the grid and the player: the History
/// window, an item's Media Signal summary, and what would be lost with
/// items about to be removed.
public protocol SupportingReading: Sendable {
    /// What has been played, most recent first, up to `limit`; and how
    /// many items carry a watch date at all.
    func watchHistory(limit: Int) async throws -> WatchHistory

    /// What the Media Signal sweep concluded about an item; nil when it
    /// has not been through the sweep. A segment is given its video's.
    func signalSummary(itemID: UUID) async throws -> SignalSummary?

    /// Of these items, the videos with segments not saved as files of
    /// their own — which would go with them.
    func unsavedSegments(itemIDs: [UUID]) async throws -> [LibraryDatabase.UnsavedSegments]

    /// What Settings shows of the library's search strings: its formats,
    /// whether what is stored could be read, the categories a format can
    /// name, and one item to try a format on.
    func searchSettings() async throws -> SearchSettings
}

public struct SearchSettings: Codable, Equatable, Sendable {
    public var formats: SearchFormats
    /// The library holds formats this version cannot decode. `formats`
    /// is then empty, and must not be written over them unasked.
    public var storedFormatsUnreadable: Bool
    public var categories: [TagCategory]
    /// The item that sorts first, for the preview; nil in an empty library.
    public var sample: SearchSubject?

    public init(
        formats: SearchFormats, storedFormatsUnreadable: Bool, categories: [TagCategory], sample: SearchSubject?
    ) {
        self.formats = formats
        self.storedFormatsUnreadable = storedFormatsUnreadable
        self.categories = categories
        self.sample = sample
    }
}

public struct WatchHistory: Codable, Equatable, Sendable {
    public var items: [MediaItem]
    /// Every item with a watch date, however many are listed.
    public var total: Int

    public init(items: [MediaItem], total: Int) {
        self.items = items
        self.total = total
    }
}

// MARK: - On this Mac

extension LocalLibraryService {
    public func searchSettings() async throws -> SearchSettings {
        let first = try await library.writer.read { try MediaItem.order(sql: "relativePath").fetchOne($0) }
        return SearchSettings(
            formats: try library.searchFormats(),
            storedFormatsUnreadable: try library.storedSearchFormatsAreUnreadable(),
            categories: try library.vocabulary().map(\.category),
            sample: try first.flatMap { try library.searchSubject(for: $0.id) })
    }

    public func watchHistory(limit: Int) async throws -> WatchHistory {
        WatchHistory(items: try library.recentlyWatched(limit: limit), total: try library.watchedItemCount())
    }

    public func signalSummary(itemID: UUID) async throws -> SignalSummary? {
        guard let item = try await library.writer.read({ try MediaItem.fetchOne($0, key: itemID) }) else {
            return nil
        }
        return try library.signalSummary(for: item)
    }

    public func unsavedSegments(itemIDs: [UUID]) async throws -> [LibraryDatabase.UnsavedSegments] {
        try library.unsavedSegments(of: itemIDs)
    }
}
