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

/// How a queue's snapshot is ordered on screen — in place, never by
/// re-running the definition. "Queue order" is the order the
/// definition produced; the rest mirror the browse Sort menu. Full
/// Path is not offered: the snapshot has no source names to group by.
enum QueueSort: Hashable, Sendable {
    case definition
    case fileName
    case relativePath
    case largestFirst
    case longestFirst
    /// Stable for a seed, so ←/→ walk the same deal until Shuffle is
    /// chosen again.
    case random(seed: Int)

    var label: String {
        switch self {
        case .definition: "Queue order"
        case .fileName: "Name"
        case .relativePath: "Path"
        case .largestFirst: "File Size (largest first)"
        case .longestFirst: "Duration (longest first)"
        case .random: "Shuffled"
        }
    }

    static func shuffled() -> QueueSort {
        .random(seed: Int.random(in: 0..<1_000_000_000))
    }

    var isShuffled: Bool {
        if case .random = self { return true }
        return false
    }
}

/// A player's queue: the definition and the rows it produced. Owned by
/// one player, dies with its window. The player never receives a new
/// list from outside; it asks the queue to refresh.
@Observable @MainActor
final class PlayQueue {
    private(set) var definition: QueueDefinition
    /// The snapshot, in the order the definition produced.
    private(set) var items: [MediaItem]
    /// The order on screen. Sorting never re-runs the definition.
    var sort: QueueSort = .definition

    var title: String { definition.title }
    /// The snapshot under the sort — what the strip shows and ←/→ walk.
    var visible: [MediaItem] { Self.sorted(items, by: sort) }
    var ids: [UUID] { visible.map(\.id) }

    /// Pure, so it is tested without a queue. Unknown durations sort
    /// last under Duration; ties fall back to the path so the order is
    /// total.
    static func sorted(_ items: [MediaItem], by sort: QueueSort) -> [MediaItem] {
        switch sort {
        case .definition:
            return items
        case .fileName:
            return items.sorted {
                switch $0.fileName.localizedStandardCompare($1.fileName) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: $0.relativePath < $1.relativePath
                }
            }
        case .relativePath:
            return items.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        case .largestFirst:
            return items.sorted { ($1.fileSize, $0.relativePath) < ($0.fileSize, $1.relativePath) }
        case .longestFirst:
            return items.sorted {
                (-($0.durationSeconds ?? -1), $0.relativePath)
                    < (-($1.durationSeconds ?? -1), $1.relativePath)
            }
        case .random(let seed):
            // A keyed mix of the id — the same seed always deals the same
            // order; quality only needs to look shuffled.
            return items.sorted { Self.dealKey($0.id, seed: seed) < Self.dealKey($1.id, seed: seed) }
        }
    }

    private static func dealKey(_ id: UUID, seed: Int) -> UInt64 {
        let bytes = id.uuid
        var x = UInt64(seed) &+ 0x9E37_79B9_7F4A_7C15
        for byte in [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
                     bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15] {
            x = (x ^ UInt64(byte)) &* 0xBF58_476D_1CE4_E5B9
            x ^= x >> 31
        }
        return x
    }

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
