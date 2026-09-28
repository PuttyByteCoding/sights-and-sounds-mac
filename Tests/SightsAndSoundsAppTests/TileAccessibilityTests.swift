import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A tile's states are drawn — a dimmed offline tile, the deletion
/// mark, the won't-play badge, the star, the duplicate flag — and
/// VoiceOver heard only the file name. The states are its value.
@Suite struct TileAccessibilityTests {
    private func item(
        favorite: Bool = false, marked: Bool = false, issue: Bool = false, review: Bool = false
    ) -> MediaItem {
        var item = MediaItem(sourceID: UUID(), kind: .video, relativePath: "a.mp4", needsReview: review)
        item.isFavorite = favorite
        item.markedForDeletion = marked
        item.playbackIssue = issue
        return item
    }

    @Test func aPlainOnlineTileHasNoValue() {
        #expect(TileAccessibility.value(for: item(), online: true, duplicate: false) == "")
    }

    @Test func everyDrawnStateIsSaid() {
        let value = TileAccessibility.value(
            for: item(favorite: true, marked: true, issue: true, review: true), online: false, duplicate: true)
        #expect(value == "offline, marked for deletion, won't play, favourite, needs review, possible duplicate")
    }
}
