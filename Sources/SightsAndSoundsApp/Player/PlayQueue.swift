import Foundation
import GRDB
import Observation
import SightsAndSoundsKit

/// What a queue IS, as a thing that can be run again. A player's queue
/// is the snapshot the definition produced when the player opened;
/// Refresh runs the definition again. Nothing else changes a queue.
enum QueueDefinition: Hashable, Sendable {
    /// The library window's listing at the moment of opening.
    case listing(filter: MediaFilter, kinds: MediaKinds, ordering: MediaOrdering)
    /// Every item wearing one tag — the Tag Pivot window.
    case tag(id: UUID, name: String)
    /// What has been watched, most recent first.
    case history
    /// A fixed set — a selection, a compare pair, a Recently Watched row.
    case explicit(ids: [UUID], name: String)

    var title: String {
        switch self {
        case .listing(let filter, _, _): filter.isEmpty ? "All items" : "Filtered listing"
        case .tag(_, let name): "Tag: \(name)"
        case .history: "Recently Watched"
        case .explicit(_, let name): name
        }
    }
}

/// A player's queue: the definition and the rows it produced. Owned by
/// one player, dies with its window. The player never receives a new
/// list from outside; it asks the queue to refresh.
@Observable @MainActor
final class PlayQueue {
    private(set) var definition: QueueDefinition
    private(set) var items: [MediaItem]

    var title: String { definition.title }
    var ids: [UUID] { items.map(\.id) }

    init(definition: QueueDefinition, items: [MediaItem]) {
        self.definition = definition
        self.items = items
    }

    /// Run the definition once and hold the result.
    static func make(_ definition: QueueDefinition, library: LibraryDatabase) throws -> PlayQueue {
        PlayQueue(definition: definition, items: try run(definition, library: library))
    }

    /// The definition, as rows. Nonisolated so a refresh can run it off
    /// the main actor; the caller hands the rows to `apply`.
    nonisolated static func run(
        _ definition: QueueDefinition, library: LibraryDatabase
    ) throws -> [MediaItem] {
        switch definition {
        case .listing(let filter, let kinds, let ordering):
            return try library.mediaItems(matching: filter, kinds: kinds, orderedBy: ordering)
        case .tag(let id, _):
            return try library.items(withTag: id, limit: 10_000).items
        case .history:
            return try library.recentlyWatched()
        case .explicit(let ids, _):
            // The given order, minus anything that no longer exists.
            let rows: [MediaItem] = try library.writer.read { db -> [MediaItem] in
                try MediaItem.fetchAll(db, keys: ids)
            }
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        }
    }

    /// The library window's Refresh: the grid's current definition
    /// becomes this queue's, then a refresh catches the queue up.
    func replaceDefinition(_ definition: QueueDefinition) {
        self.definition = definition
    }

    /// A refresh landed.
    func apply(_ items: [MediaItem]) {
        self.items = items
    }
}
