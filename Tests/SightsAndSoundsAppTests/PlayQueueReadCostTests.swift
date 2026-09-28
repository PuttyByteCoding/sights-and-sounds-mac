import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The transport reads the queue several times per playhead tick, four
/// ticks a second. `visible` re-narrowed and re-sorted the whole listing
/// on every read — under Name or Shuffle, localized sorts of thousands
/// of rows, over and over. Reading it costs nothing; changing what it
/// depends on is what sorts.
@Suite @MainActor struct PlayQueueReadCostTests {
    private func queue(_ count: Int) -> PlayQueue {
        let source = UUID()
        let items = (0..<count).map { n in
            MediaItem(sourceID: source, kind: .video, relativePath: "show \(count - n)/track \(n).mp4", needsReview: false)
        }
        return PlayQueue(definition: .explicit(ids: items.map(\.id), name: "Big"), items: items)
    }

    @Test func readingTheQueueRepeatedlyDoesNotReSort() {
        let queue = queue(20_000)
        queue.sort = .fileName
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<1_000 { _ = queue.visible.count; _ = queue.ids.count }
        }
        #expect(elapsed < .seconds(1), "1,000 reads took \(elapsed)")
    }

    @Test func theOrderStillFollowsEveryChange() {
        let queue = queue(50)
        queue.sort = .fileName
        let byName = queue.visible.map(\.fileName)
        #expect(byName == byName.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        queue.sort = .definition
        #expect(queue.visible.first?.relativePath == "show 50/track 0.mp4")
        let tag = UUID()
        let first = queue.visible[0].id
        queue.apply(membership: [first: [tag]])
        queue.requiredTagIDs = [tag]
        #expect(queue.ids == [first])
    }
}
