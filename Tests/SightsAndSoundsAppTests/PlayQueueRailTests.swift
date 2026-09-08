import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Narrowing is view state over the snapshot: required tags hide rows,
/// counts come from the queue's own items, and the snapshot is untouched.
@Suite @MainActor struct PlayQueueRailTests {
    private let phish = UUID(), sbd = UUID(), aud = UUID()

    private func item(_ path: String) -> MediaItem {
        MediaItem(sourceID: UUID(), kind: .video, relativePath: path, needsReview: false)
    }

    private func queue() -> (PlayQueue, [MediaItem]) {
        let items = [item("a.mp4"), item("b.mp4"), item("c.mp4")]
        let q = PlayQueue(definition: .explicit(ids: items.map(\.id), name: "Test"), items: items)
        q.apply(membership: [
            items[0].id: [phish, sbd],
            items[1].id: [phish],
            items[2].id: [aud],
        ])
        return (q, items)
    }

    @Test func countsAreOverTheQueuesItems() {
        let (q, _) = queue()
        #expect(q.tagCounts == [phish: 2, sbd: 1, aud: 1])
    }

    @Test func requiredTagsNarrowTheVisibleRowsAndNotTheSnapshot() {
        let (q, items) = queue()
        q.requiredTagIDs = [phish]
        #expect(q.visible.map(\.id) == [items[0].id, items[1].id])
        q.requiredTagIDs = [phish, sbd]
        #expect(q.visible.map(\.id) == [items[0].id])
        #expect(q.items.count == 3)
        q.requiredTagIDs = []
        #expect(q.visible.count == 3)
    }

    @Test func narrowingComposesWithTheSort() {
        let (q, items) = queue()
        q.requiredTagIDs = [phish]
        q.sort = .random(seed: 3)
        #expect(Set(q.visible.map(\.id)) == [items[0].id, items[1].id])
    }

    @Test func aRequiredTagThatNoLongerOccursIsDroppedOnRecount() {
        let (q, items) = queue()
        q.requiredTagIDs = [sbd]
        q.apply(membership: [items[0].id: [phish], items[1].id: [phish], items[2].id: [aud]])
        #expect(q.requiredTagIDs.isEmpty)
        #expect(q.visible.count == 3)
    }
}
