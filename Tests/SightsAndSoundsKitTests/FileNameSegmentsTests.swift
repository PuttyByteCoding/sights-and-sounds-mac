import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The pieces between underscores, as the tags they would be typed as.
@Suite struct FileNameSegmentsTests {
    @Test func piecesBetweenUnderscoresAreOfferedSplitFromTitleCase() {
        #expect(FileNameSegments.pieces(of: "sdg_BenFoldsFive_OnStage_tonight.mp4")
            == ["sdg", "Ben Folds Five", "On Stage", "tonight"])
    }

    @Test func aNameWithoutUnderscoresHasNoPieces() {
        #expect(FileNameSegments.pieces(of: "Ben Folds - Live.mp4").isEmpty)
        #expect(FileNameSegments.pieces(of: "BenFoldsFive.mp4").isEmpty)
    }

    @Test func emptyPiecesAndTheExtensionAreDropped() {
        #expect(FileNameSegments.pieces(of: "__a__b_.flac") == ["a", "b"])
        #expect(FileNameSegments.pieces(of: "a_b.tar.gz") == ["a", "b.tar"])
    }
}
