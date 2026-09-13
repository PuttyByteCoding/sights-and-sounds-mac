import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Esc unwinds EXACTLY ONE layer of the player, and the stack ends at
/// the video: an open mark, then the focus zone, then nothing. The
/// window is not a layer — Esc never leaves the player.
@Suite @MainActor struct PlayerEscapeTests {
    private func makeModel() throws -> PlayerModel {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Escape")
        return PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: UUID(),
                definition: .listing(filter: MediaFilter(), kinds: .video, ordering: .relativePath),
                playlist: []),
            library: library, appDatabase: nil)
    }

    @Test func anOpenSegmentMarkIsTheFirstLayer() throws {
        let model = try makeModel()
        model.zone = .segments
        model.pendingSegmentStart = 12

        #expect(model.unwindOneLayer())
        #expect(model.pendingSegmentStart == nil)
        #expect(model.zone == .segments, "one layer, not two: the zone is untouched")
    }

    @Test func anOpenHideBlockIsAlsoTheFirstLayer() throws {
        let model = try makeModel()
        model.zone = .tags
        model.pendingBlockStart = 3

        #expect(model.unwindOneLayer())
        #expect(model.pendingBlockStart == nil)
        #expect(model.zone == .tags)
    }

    @Test func aPanelZoneReleasesToTheVideo() throws {
        let model = try makeModel()
        model.zone = .queue

        #expect(model.unwindOneLayer())
        #expect(model.zone == .video)
    }

    @Test func theVideoZoneWithNothingOpenIsTheBottomOfTheStack() throws {
        let model = try makeModel()
        model.zone = .video

        #expect(!model.unwindOneLayer(), "nothing to unwind — and nothing to leave")
        #expect(model.zone == .video)
    }
}
