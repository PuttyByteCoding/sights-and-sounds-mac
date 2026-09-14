import Foundation
import Testing

@testable import SightsAndSoundsApp

/// The web search URL: the template's placeholder takes the string,
/// percent-encoded so quotes and spaces survive the trip.
@Suite struct SearchCommandsTests {
    @Test func thePlaceholderTakesTheEncodedQuery() {
        let url = SearchWebURL.resolve(
            template: "https://duckduckgo.com/?q={query}", query: #""Ben Folds Five" 2019 & more"#)
        #expect(url?.absoluteString == "https://duckduckgo.com/?q=%22Ben%20Folds%20Five%22%202019%20%26%20more")
    }

    @Test func aTemplateWithoutThePlaceholderGetsTheQueryAppended() {
        #expect(SearchWebURL.resolve(template: "https://example.org/search?q=", query: "phish")?.absoluteString
            == "https://example.org/search?q=phish")
    }

    @Test func aBrokenTemplateIsNil() {
        #expect(SearchWebURL.resolve(template: "not a url {query}", query: "x") == nil)
        #expect(SearchWebURL.resolve(template: "", query: "x") == nil)
    }
}
