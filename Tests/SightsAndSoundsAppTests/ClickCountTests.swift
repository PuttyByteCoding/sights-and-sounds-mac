import Testing

@testable import SightsAndSoundsApp

/// One handler reads the click's own count, the way Finder does: the
/// first click selects at once, the second opens. Two stacked tap
/// gestures made SwiftUI hold every single click for the double-click
/// interval, so selecting always lagged.
@Suite struct ClickCountTests {
    @Test func theFirstClickIsASingleAndTheSecondADouble() {
        #expect(ClickKind(clickCount: 1) == .single)
        #expect(ClickKind(clickCount: 2) == .double)
    }

    /// A third click in a row is still an open, not a select.
    @Test func moreClicksStillOpen() {
        #expect(ClickKind(clickCount: 3) == .double)
    }

    /// No event to read (a synthetic tap) counts as a single click.
    @Test func noCountIsASingleClick() {
        #expect(ClickKind(clickCount: nil) == .single)
        #expect(ClickKind(clickCount: 0) == .single)
    }
}
