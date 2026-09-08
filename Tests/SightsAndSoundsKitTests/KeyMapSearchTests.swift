import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The `?` sheet's search: a row matches on what it is called or on the
/// keys either map binds it to, case-insensitively; a blank query is
/// the whole table.
@Suite struct KeyMapSearchTests {

    @Test func blankQueryIsTheWholeTable() {
        #expect(KeyMapStyle.comparison(matching: "") == KeyMapStyle.comparison)
        #expect(KeyMapStyle.comparison(matching: "   ") == KeyMapStyle.comparison)
    }

    @Test func matchesTheLabelCaseInsensitively() {
        let labels = KeyMapStyle.comparison(matching: "SEGMENT").map(\.label)
        #expect(labels.contains("Open / close a segment"))
        #expect(!labels.contains("Play / pause"))
    }

    @Test func matchesTheKeysOfEitherMap() {
        // "[" is the web map's segment key only; the row still matches.
        #expect(KeyMapStyle.comparison(matching: "[").map(\.label) == ["Open / close a segment"])
        #expect(KeyMapStyle.comparison(matching: "esc").map(\.label).contains("Release to video"))
    }

    @Test func nothingMatchesNothing() {
        #expect(KeyMapStyle.comparison(matching: "xyzzy").isEmpty)
    }

    @Test func theTableCoversTheKeysTheHandlerAnswersTo() {
        // Rows that used to be missing from the cheat sheet.
        let labels = KeyMapStyle.comparison.map(\.label)
        for needle in ["Mute", "Flag", "checkbox", "Bound", "start", "Keyboard map"] {
            #expect(labels.contains { $0.localizedCaseInsensitiveContains(needle) }, "\(needle)")
        }
    }
}
