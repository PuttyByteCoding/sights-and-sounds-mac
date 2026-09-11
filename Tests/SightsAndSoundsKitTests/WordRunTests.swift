import Foundation
import Testing
@testable import SightsAndSoundsKit

/// What a double-click on a file name selects: the words between the
/// special characters.
@Suite struct WordRunTests {
    private func run(_ text: String, on needle: String) -> String {
        let at = text.range(of: needle)!.lowerBound
        return String(text[text.wordRun(at: at)])
    }

    @Test func spacesJoinWordsAndPunctuationSeparatesThem() {
        let name = "2019-07-04 Phish - Alpine Valley - AUD.mp4"
        #expect(run(name, on: "Alpine") == "Alpine Valley")
        #expect(run(name, on: "Valley") == "Alpine Valley")
        #expect(run(name, on: "07") == "07")
        // Between the dashes, "04 Phish" is one run: a space joins.
        #expect(run(name, on: "Phish") == "04 Phish")
        #expect(run(name, on: "AUD") == "AUD")
        #expect(run(name, on: "mp4") == "mp4")
    }

    @Test func underscoresDotsAndBracketsAreWalls() {
        #expect(run("show-with_BenFolds-in-seattle.mp4", on: "BenFolds") == "BenFolds")
        #expect(run("[AUD] Wilco (live).mkv", on: "live") == "live")
        #expect(run("[AUD] Wilco (live).mkv", on: "Wilco") == "Wilco")
    }

    @Test func aClickOnAWallSelectsJustTheWall() {
        #expect(run("a-b", on: "-") == "-")
        #expect(run("a - b", on: " ") == "a")  // the space beside a is inside a's run
        #expect(run("a-  -b", on: "  ") == " ")
    }

    @Test func utf16OffsetsAgreeWithCharacterIndexes() {
        let name = "Motörhead - Ace of Spades.flac"
        let offset = ("Motörhead - Ace" as NSString).length - 1
        let range = name.wordRun(atUTF16Offset: offset)
        #expect((name as NSString).substring(with: range) == "Ace of Spades")
        #expect(name.wordRun(atUTF16Offset: 99).length == 0)
    }
}
