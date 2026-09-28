import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Every tile reads the model's listing on every render — its context
/// menu asks for the selected items, the grid for the visible ones, the
/// window for the offline ones — and one click re-renders every tile.
/// Each of those used to filter the whole listing per read. Reading
/// them costs nothing now; changing the listing is what recomputes.
@Suite @MainActor struct GridListingReadCostTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<800 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test func readingTheListingRepeatedlyIsCheap() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Big grid")
        let online = Source(name: "Here", rootPath: FileManager.default.temporaryDirectory.path)
        let offline = Source(name: "Gone", rootPath: "/Volumes/SAS-Test-Not-Here-\(UUID().uuidString)")
        try await library.writer.write { db in
            try online.insert(db)
            try offline.insert(db)
            for n in 0..<20_000 {
                try MediaItem(sourceID: n % 10 == 0 ? offline.id : online.id, kind: .video,
                              relativePath: "bulk/\(n).mp4", needsReview: false).insert(db)
            }
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 20_000 && !model.offlineItems.isEmpty }
        model.hideOfflineItems = true
        let picked = Array(model.visibleItems.prefix(12))
        for item in picked { model.click(item.id, extend: true, range: false) }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<3_000 {
                _ = model.visibleItems.count
                _ = model.offlineItems.count
                _ = model.selectedItems.count
            }
        }
        #expect(elapsed < .seconds(1), "3,000 reads took \(elapsed)")

        // And the answers are the same ones.
        #expect(model.visibleItems.count == 18_000)
        #expect(model.offlineItems.count == 2_000)
        #expect(model.selectedItems.map(\.id) == picked.map(\.id))
    }
}
