import Foundation
import Testing

@testable import SightsAndSoundsKit

/// Pasting a list of aliases into the tag sheet: one per line or
/// separated by commas, semicolons or tabs; sloppy whitespace trimmed;
/// blanks dropped; duplicates (case-insensitive) kept once, in the
/// first spelling seen, and never repeating what the tag already has.
@Suite struct AliasListTests {

    @Test func oneAliasPerLine() {
        #expect(AliasList.parse("SBD\nSoundboard\nBoard") == ["SBD", "Soundboard", "Board"])
    }

    @Test func commasSemicolonsAndTabsAlsoSeparate() {
        #expect(AliasList.parse("SBD, Soundboard;Board\tDesk") == ["SBD", "Soundboard", "Board", "Desk"])
    }

    @Test func sloppyWhitespaceIsTrimmedAndBlanksDropped() {
        #expect(AliasList.parse("  SBD \n\n\t Soundboard\u{00A0}\n , \r\n") == ["SBD", "Soundboard"])
    }

    @Test func duplicatesWithinThePasteKeepTheFirstSpelling() {
        #expect(AliasList.parse("SBD\nsbd\nSoundboard\nSBD") == ["SBD", "Soundboard"])
    }

    @Test func entriesTheTagAlreadyHasAreSkipped() {
        #expect(AliasList.parse("SBD\nSoundboard\nBoard", excluding: ["soundboard", "Board"]) == ["SBD"])
    }

    @Test func aSingleTypedAliasStillWorks() {
        #expect(AliasList.parse(" Soundboard ") == ["Soundboard"])
        #expect(AliasList.parse("   ") == [])
    }
}
