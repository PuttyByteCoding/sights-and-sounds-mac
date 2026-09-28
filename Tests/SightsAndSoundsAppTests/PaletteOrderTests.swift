import Testing

@testable import SightsAndSoundsApp

/// The palette draws its rows grouped (GO TO, FILTER, TAG, DO, VIEW).
/// The keyboard must walk them in that same order: it used to walk the
/// score order, so ⏎ could run a row that was not the top one on screen
/// and ↓ jumped between sections.
@Suite @MainActor struct PaletteOrderTests {
    private func command(_ group: PaletteCommand.Group, _ title: String) -> PaletteCommand {
        PaletteCommand(group: group, title: title, symbol: "circle") {}
    }

    @Test func theKeyboardOrderIsTheScreenOrder() {
        let commands = [
            command(.do, "Export Copy"),  // prefix match: scores highest
            command(.goTo, "Next export"),  // word match
            command(.view, "Show exports"),  // word match
        ]
        let ordered = PaletteCommand.ordered(commands, query: "ex", recents: [])
        #expect(ordered.map(\.title) == ["Next export", "Export Copy", "Show exports"])
    }

    @Test func withinAGroupTheBestMatchComesFirst() {
        let commands = [command(.do, "Reindex everything"), command(.do, "Export Copy")]
        let ordered = PaletteCommand.ordered(commands, query: "ex", recents: [])
        #expect(ordered.map(\.title) == ["Export Copy", "Reindex everything"])
    }

    @Test func recentsLeadTheirOwnGroup() {
        let commands = [command(.goTo, "Tag Manager"), command(.do, "Shuffle"), command(.do, "Export Copy")]
        let recents = [commands[2].id]
        let ordered = PaletteCommand.ordered(commands, query: "", recents: recents)
        #expect(ordered.map(\.title) == ["Tag Manager", "Export Copy", "Shuffle"])
    }
}
