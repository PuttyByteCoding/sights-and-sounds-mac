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
