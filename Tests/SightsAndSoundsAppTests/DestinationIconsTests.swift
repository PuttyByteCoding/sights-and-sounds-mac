import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The toolbar, the menu bar and the command palette all send you to the
/// same handful of places. Each place gets ONE name and ONE symbol, or
/// the three surfaces drift apart — which is how Tag Manager and Tag
/// Analysis ended up sharing `tag.square`, and how Log wore one icon in
/// the toolbar and another in the palette.
@Suite @MainActor struct DestinationIconsTests {
    @Test func noTwoDestinationsShareASymbol() {
        var seen: [String: Destination] = [:]
        for destination in Destination.allCases {
            if let other = seen[destination.symbol] {
                Issue.record(
                    "\(destination) and \(other) both use \(destination.symbol)")
            }
            seen[destination.symbol] = destination
        }
    }

    @Test func everyDestinationNamesItsWindowTheWayTheWindowNamesItself() {
        for destination in Destination.allCases {
            guard let kind = destination.auxKind else { continue }
            #expect(
                destination.title == kind.title,
                "\(destination) is titled \(destination.title) but its window is \(kind.title)")
        }
    }
}

/// The player's four flag buttons drew bare Unicode — ★ ⟳ ⚠ ⌫ — with no
/// text and no symbol. Each one now names itself, and the names and
/// symbols agree with what the command palette calls the same flags.
@Suite @MainActor struct PlayerFlagLabelsTests {
    @Test func everyFlagHasAVisibleTitle() {
        for flag in PlayerToggleFlag.allCases {
            #expect(!flag.buttonTitle.isEmpty, "\(flag) has no title")
        }
    }

    @Test func noTwoFlagsShareASymbol() {
        let symbols = PlayerToggleFlag.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count, "flag symbols repeat: \(symbols)")
    }
}
