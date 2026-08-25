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
    private let jobRunner: JobRunner
    private let onWorkFinished: () -> Void
    // nonisolated(unsafe): only appended in init and drained in deinit;
    // NotificationCenter removal is thread-safe.
    nonisolated(unsafe) private var mountObservers: [any NSObjectProtocol] = []

    /// Sources with an import in flight, and their progress line.
    private(set) var importStatus: [UUID: String] = [:]

    init(
        libraryID: UUID, library: LibraryDatabase, runner: JobRunner,
        onWorkFinished: @escaping () -> Void = {}
    ) {
        self.libraryID = libraryID
        self.library = library
        self.libraryName = (try? library.info()?.name) ?? "Library"
        self.jobRunner = runner
        self.onWorkFinished = onWorkFinished
        refreshAll()

        // Mount/unmount drives online-state transitions and wakes the
        // workers — the reachability check stays the fallback truth.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            mountObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshAll()
                    self?.onWorkFinished()
                }
            })
        }
    }

    deinit {
        for observer in mountObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
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

    // MARK: - Sources & import

    func addSource(at url: URL) {
        do {
            let source = Source(name: url.lastPathComponent, rootPath: url.path)
            try library.writer.write { try source.insert($0) }
            refreshAll()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Scan a source for new files. Serialized by the job runner; progress
    /// surfaces beside the source row; the grid refreshes when done.
    func importSource(_ source: Source) {
        guard importStatus[source.id] == nil else { return }
        importStatus[source.id] = "queued…"
        Task {
            do {
                await jobRunner.register(ImportJob.self)
                let record = try await ImportJob.enqueue(on: jobRunner, sourceID: source.id)
                let drain = Task { try await jobRunner.runPending() }

                // Poll the job row for progress until it settles.
                var settled = false
                while !settled {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let row = try await library.writer.read({
                        try JobRecord.fetchOne($0, key: record.id)
                    }) else { break }
                    switch row.state {
                    case .queued:
                        importStatus[source.id] = "queued…"
                    case .running:
                        if let total = row.progressTotal, total > 0 {
                            importStatus[source.id] = "\(row.progressCurrent)/\(total)"
                        } else {
                            importStatus[source.id] = "scanning…"
                        }
                    case .succeeded, .failed, .cancelled:
                        settled = true
                        if row.state == .failed, let error = row.error {
                            errorMessage = "Import failed: \(error)"
                        }
                    }
                }
                _ = try? await drain.value
            } catch {
                errorMessage = "\(error)"
            }
            importStatus[source.id] = nil
            refreshAll()
            // Import finishing is a worker signal: new rows want hashes
            // and thumbnails.
            onWorkFinished()
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
