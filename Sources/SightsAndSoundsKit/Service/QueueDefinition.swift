import Foundation
import GRDB

/// What a queue IS, as a thing that can be run again. A player's queue
/// is the snapshot the definition produced when the player opened;
/// Refresh runs the definition again. Nothing else changes a queue.
public enum QueueDefinition: Codable, Hashable, Sendable {
    /// The library window's listing at the moment of opening.
    case listing(filter: MediaFilter, kinds: MediaKinds, ordering: MediaOrdering)
    /// Every item wearing one tag — the Tag Pivot window.
    case tag(id: UUID, name: String)
    /// What has been watched, most recent first.
    case history
    /// A fixed set — a selection, a compare pair, a History row.
    case explicit(ids: [UUID], name: String)

    public var title: String {
        switch self {
        case .listing(let filter, _, _): filter.isEmpty ? "All items" : "Filtered listing"
        case .tag(_, let name): "Tag: \(name)"
        case .history: "History"
        case .explicit(_, let name): name
        }
    }
}

extension LibraryDatabase {
    /// These items, in the order given, minus any that no longer exist.
    public func items(ids: [UUID]) throws -> [MediaItem] {
        guard !ids.isEmpty else { return [] }
        let rows: [MediaItem] = try writer.read { db -> [MediaItem] in
            try MediaItem.fetchAll(db, keys: ids)
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// A queue definition, as rows.
    public func queueItems(_ definition: QueueDefinition) throws -> [MediaItem] {
        switch definition {
        case .listing(let filter, let kinds, let ordering):
            try mediaItems(matching: filter, kinds: kinds, orderedBy: ordering)
        case .tag(let id, _):
            try items(withTag: id, limit: 10_000).items
        case .history:
            try recentlyWatched()
        case .explicit(let ids, _):
            try items(ids: ids)
        }
    }
}
