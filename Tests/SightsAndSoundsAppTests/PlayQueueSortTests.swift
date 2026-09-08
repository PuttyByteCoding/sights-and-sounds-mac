import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Sorting re-orders the snapshot in place: the definition is not
/// re-run, the rows are the same rows, only their order changes.
@Suite @MainActor struct PlayQueueSortTests {
    private func item(_ path: String, size: Int64, seconds: Double?) -> MediaItem {
        var item = MediaItem(sourceID: UUID(), kind: .video, relativePath: path, needsReview: false)
        item.fileSize = size
        item.durationSeconds = seconds
        return item
    }

    private var items: [MediaItem] {
        [
            item("shows/b.mp4", size: 30, seconds: 300),
            item("a.mp4", size: 10, seconds: nil),
            item("shows/c.mp4", size: 20, seconds: 100),
        ]
    }

    @Test func queueOrderIsTheDefinitionsOrder() {
        #expect(PlayQueue.sorted(items, by: .definition).map(\.relativePath)
            == ["shows/b.mp4", "a.mp4", "shows/c.mp4"])
    }

    @Test func nameAndPathSortAlphabetically() {
        #expect(PlayQueue.sorted(items, by: .fileName).map(\.fileName) == ["a.mp4", "b.mp4", "c.mp4"])
        #expect(PlayQueue.sorted(items, by: .relativePath).map(\.relativePath)
            == ["a.mp4", "shows/b.mp4", "shows/c.mp4"])
    }

    @Test func sizeAndDurationSortLargestAndLongestFirstWithUnknownsLast() {
        #expect(PlayQueue.sorted(items, by: .largestFirst).map(\.fileSize) == [30, 20, 10])
        #expect(PlayQueue.sorted(items, by: .longestFirst).map(\.relativePath)
            == ["shows/b.mp4", "shows/c.mp4", "a.mp4"])
    }

    @Test func aShuffleIsStableForItsSeedAndANewSeedIsANewDeal() {
        let many = (0..<40).map { item("v\($0).mp4", size: Int64($0), seconds: nil) }
        let one = PlayQueue.sorted(many, by: .random(seed: 7)).map(\.id)
        let again = PlayQueue.sorted(many, by: .random(seed: 7)).map(\.id)
        let other = PlayQueue.sorted(many, by: .random(seed: 8)).map(\.id)
        #expect(one == again)
        #expect(one != other)
        #expect(Set(one) == Set(many.map(\.id)))
        #expect(one != many.map(\.id))
    }

    @Test func theQueueExposesTheSortedRowsAsVisibleAndKeepsTheSnapshot() {
        let queue = PlayQueue(definition: .explicit(ids: [], name: "Test"), items: items)
        #expect(queue.visible.map(\.relativePath) == ["shows/b.mp4", "a.mp4", "shows/c.mp4"])
        queue.sort = .fileName
        #expect(queue.visible.map(\.fileName) == ["a.mp4", "b.mp4", "c.mp4"])
        #expect(queue.ids == queue.visible.map(\.id))
        #expect(queue.items.map(\.relativePath) == ["shows/b.mp4", "a.mp4", "shows/c.mp4"])
        #expect(QueueSort.shuffled().isShuffled)
    }
}
