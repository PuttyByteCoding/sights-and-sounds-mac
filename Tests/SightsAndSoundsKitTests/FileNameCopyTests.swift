import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The "letters and numbers only" copy of a file name: spaces survive,
/// every other character becomes a space, nothing is collapsed or trimmed.
@Suite struct FileNameCopyTests {

    @Test func punctuationBecomesSpaces() {
        #expect("band_live-2019.mp4".lettersAndNumbersOnly == "band live 2019 mp4")
    }

    @Test func spacesAreKept() {
        #expect("Live at the Hall 2019.mkv".lettersAndNumbersOnly == "Live at the Hall 2019 mkv")
    }

    @Test func runsAreNotCollapsed() {
        #expect("a--b".lettersAndNumbersOnly == "a  b")
        #expect("(x)".lettersAndNumbersOnly == " x ")
    }

    @Test func unicodeLettersAndDigitsAreKept() {
        #expect("Café_Ünïcode_٣.mp4".lettersAndNumbersOnly == "Café Ünïcode ٣ mp4")
    }

    @Test func emptyStaysEmpty() {
        #expect("".lettersAndNumbersOnly == "")
    }
}
