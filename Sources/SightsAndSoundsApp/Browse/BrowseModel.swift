import Foundation
import SwiftUI
import SightsAndSoundsKit

/// Per-category tags for the filter panel.
struct CategoryTags: Identifiable {
    var id: UUID { category.id }
    let category: TagCategory
    let tags: [Tag]
}

/// One library window's state: the active filter, its results, and the
/// sidebar data. All reads go through the library's own handle — nothing
/// here can see another library.
@Observable @MainActor
final class BrowseModel {
    let libraryID: UUID
    let library: LibraryDatabase
    let libraryName: String

    var kind: MediaKind = .video { didSet { refreshAll() } }
    var filter = MediaFilter() { didSet { refreshItems() } }
    var selectedFolderPath: String?

    private(set) var items: [MediaItem] = []
    private(set) var folderTree: [FolderNode] = []
    private(set) var vocabulary: [CategoryTags] = []
    private(set) var sources: [Source] = []
    private(set) var onlineSourceIDs: Set<UUID> = []
    var errorMessage: String?

    private let fileAccess: any FileAccess = LiveFileAccess()

    init(libraryID: UUID, library: LibraryDatabase) {
        self.libraryID = libraryID
        self.library = library
        self.libraryName = (try? library.info()?.name) ?? "Library"
        refreshAll()
    }

    func refreshAll() {
        do {
            sources = try library.sources()
            onlineSourceIDs = Set(
                sources.filter { $0.enabled && $0.isOnline(using: fileAccess) }.map(\.id))
            vocabulary = try library.vocabulary()
                .filter { !$0.category.hiddenFromBrowse }
                .map { CategoryTags(category: $0.category, tags: $0.tags) }
            folderTree = FolderTreeBuilder.build(from: try library.folderCounts(kind: kind))
            refreshItems()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func refreshItems() {
        do {
            items = try library.mediaItems(matching: filter, kind: kind)
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Sidebar actions

    func selectFolder(_ path: String?) {
        selectedFolderPath = path
        filter.selectSubtree(path)
    }

    func clearFilter() {
        selectedFolderPath = nil
        filter = MediaFilter()
    }

    func setSourceEnabled(_ source: Source, _ enabled: Bool) {
        do {
            try library.writer.write { db in
                var updated = source
                updated.enabled = enabled
                try updated.update(db)
            }
            refreshAll()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Item helpers

    func source(for item: MediaItem) -> Source? {
        sources.first { $0.id == item.sourceID }
    }

    func isOnline(_ item: MediaItem) -> Bool {
        onlineSourceIDs.contains(item.sourceID)
    }

    /// Absolute file URL, or nil while the item's source is offline.
    func fileURL(for item: MediaItem) -> URL? {
        guard isOnline(item), let source = source(for: item) else { return nil }
        return URL(fileURLWithPath: source.rootPath, isDirectory: true)
            .appendingPathComponent(item.relativePath)
    }
}
