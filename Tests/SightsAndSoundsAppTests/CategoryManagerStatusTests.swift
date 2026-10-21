import Foundation
import SwiftUI
import Testing

@testable import SightsAndSoundsApp

/// The Tag Manager's two lines — a notice and an error — and the two
/// ways an inspector field commits.
@Suite @MainActor struct CategoryManagerStatusTests {
    /// A merge that worked is a notice, not an error: it carries no
    /// failure wording, and its text is what the toast will show.
    @Test func aMergeThatWorkedIsANoticeNotAnError() {
        let text = CategoryManagerView.mergeNotice(sources: 3)
        #expect(text == "3 tags merged — names kept as aliases")
        #expect(!text.localizedCaseInsensitiveContains("could not"))
        // Shown for a moment, not until dismissed — and long enough to read.
        #expect(CategoryManagerView.noticeDuration >= .seconds(3))
        #expect(CategoryManagerView.noticeDuration <= .seconds(6))
    }

    /// The cluster header keeps the count and the winner's name apart,
    /// so the table can uppercase one and not the other.
    @Test func aClusterHeaderKeepsTheWinnersNameAsTyped() {
        let row = TagTableRow(clusterCount: 2, winner: "northlight sessions")
        #expect(row.tag == nil)
        #expect(row.clusterHeader == .init(count: 2, winner: "northlight sessions"))
        #expect(row.id == "header:northlight sessions")
    }

    /// A field writes when focus leaves it with something typed; a glance
    /// in and out, or focus arriving, writes nothing.
    @Test func aFieldCommitsOnLosingFocusOnlyWhenItChanged() {
        #expect(FieldCommit.onFocusChange(from: true, to: false, text: "Venue", stored: "Venu"))
        #expect(!FieldCommit.onFocusChange(from: true, to: false, text: "Venue", stored: "Venue"))
        #expect(!FieldCommit.onFocusChange(from: false, to: true, text: "Venue", stored: "Venu"))
        #expect(!FieldCommit.onFocusChange(from: false, to: false, text: "Venue", stored: "Venu"))
    }
}
