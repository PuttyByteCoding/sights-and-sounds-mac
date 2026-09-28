import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The recipe editor rebuilds its preview — every rule's intermediate
/// string — on each keystroke. A regex rule used to compile its pattern
/// again for every value, for every rule prefix; one pattern compiles
/// once.
@Suite(.serialized) struct SearchRegexCompileTests {
    @Test func aPatternCompilesOnceHoweverOftenItRuns() {
        let pattern = "[0-9]{4}-\(UUID().uuidString.prefix(6))"
        let recipe = SearchRecipe(
            parts: [SearchPart(kind: .fileName(includesExtension: false, splitsPieces: true))],
            rules: [
                SearchRule(kind: .replace(from: pattern, to: "", regex: true)),
                SearchRule(kind: .exclude("x", keep: .none, regex: false)),
                SearchRule(kind: .replace(from: "_", to: " ")),
            ])
        let subject = SearchSubject(fileName: "a_b_c_d_e_f_g_1999-show.mp4", tags: [])
        let before = RegexCache.shared.compilations

        for _ in 0..<20 {
            _ = SearchStringBuilder.stringsAfterEachRule(recipe: recipe, subject: subject)
        }

        #expect(RegexCache.shared.compilations - before == 1)
    }
}
