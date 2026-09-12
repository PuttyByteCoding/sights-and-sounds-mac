import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Pasted title case without its spaces gets them back; anything that
/// does not look like that is left alone.
@Suite struct TitleCaseSplitTests {
    @Test func aRunOfCapitalisedWordsIsSplit() {
        #expect("ThisExampleHere".splittingTitleCaseWords == "This Example Here")
        #expect("BenFolds".splittingTitleCaseWords == "Ben Folds")
        #expect("AlpineValleyMusicTheatre".splittingTitleCaseWords == "Alpine Valley Music Theatre")
    }

    @Test func anAcronymStaysWhole() {
        #expect("DMBLive".splittingTitleCaseWords == "DMB Live")
        #expect("LiveAtDMB".splittingTitleCaseWords == "Live At DMB")
        #expect("ACDC".splittingTitleCaseWords == "ACDC")
    }

    @Test func whatDoesNotLookLikeTitleCaseIsUntouched() {
        #expect("Phish".splittingTitleCaseWords == "Phish")
        #expect("iPhone".splittingTitleCaseWords == "iPhone")
        #expect("Ben Folds".splittingTitleCaseWords == "Ben Folds")
        #expect("ben folds".splittingTitleCaseWords == "ben folds")
        #expect("".splittingTitleCaseWords == "")
    }

    @Test func eachWordIsJudgedOnItsOwnAndDigitsStartAWord() {
        #expect("BenFolds live".splittingTitleCaseWords == "Ben Folds live")
        #expect("Phish2019Fall".splittingTitleCaseWords == "Phish2019 Fall")
    }
}
