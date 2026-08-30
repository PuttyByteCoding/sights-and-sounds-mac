import Foundation
import Testing

@testable import SightsAndSoundsKit

/// Tag counts under the active filter: "if I added this, how many would
/// survive". Every tag is counted under the WHOLE filter — including
/// tags in the same category as the terms doing the filtering.
@Suite struct FacetedCountTests {

    /// The headline case. Requiring one tag narrows every other tag's
    /// count to the overlap: SBD's number becomes "SBD *and* Band A".
    @Test func requiringATagNarrowsToTheOverlap() throws {
        let f = try FilterFixture()
        let unfiltered = try f.library.browseCounts(kinds: .video).byTag[f.sbd.id] ?? 0

        let filter = MediaFilter(required: [.tag(f.bandA.id)])
        let narrowed = try f.library.filteredTagCounts(kinds: .video, filter: filter)[f.sbd.id]

        #expect(narrowed != nil)
        #expect(narrowed! <= unfiltered)
        // The genuine intersection, not merely a smaller number.
        let both = try f.library.mediaItems(
            matching: MediaFilter(required: [.tag(f.bandA.id), .tag(f.sbd.id)]),
            kinds: .video).count
        #expect(narrowed == both)
    }

    /// Tags in the SAME category narrow too, which is the whole point of
    /// counting under the whole filter. Two tags of a category nothing
    /// carries together read zero, and that zero is the truth: adding
    /// this to what is already required yields nothing.
    @Test func tagsInTheFilteredCategoryNarrowAsWell() throws {
        let f = try FilterFixture()
        let filter = MediaFilter(required: [.tag(f.bandA.id)])
        let counts = try f.library.filteredTagCounts(kinds: .video, filter: filter)

        let both = try f.library.mediaItems(
            matching: MediaFilter(required: [.tag(f.bandA.id), .tag(f.bandB.id)]),
            kinds: .video).count
        #expect(counts[f.bandB.id] == both)
    }

    /// An excluded tag reads zero, because its own exclusion guarantees
    /// it: no surviving item carries it. Also the literal truth.
    @Test func anExcludedTagReadsZero() throws {
        let f = try FilterFixture()
        let filter = MediaFilter(excluded: [.tag(f.bandA.id)])
        let counts = try f.library.filteredTagCounts(kinds: .video, filter: filter)
        #expect(counts[f.bandA.id] == 0)
    }

    /// Adding a second required term narrows further, never widens.
    @Test func addingATermOnlyNarrows() throws {
        let f = try FilterFixture()
        let one = try f.library.filteredTagCounts(
            kinds: .video, filter: MediaFilter(required: [.tag(f.bandA.id)]))
        let two = try f.library.filteredTagCounts(
            kinds: .video,
            filter: MediaFilter(required: [.tag(f.bandA.id), .tag(f.sbd.id)]))
        for (id, count) in two {
            #expect(count <= (one[id] ?? 0))
        }
    }

    /// Zero is present, not missing. The sidebar strikes and sinks zeros,
    /// and "no matching items" is a different fact from "no data" — a
    /// missing key would fall back to the library-wide count and read as
    /// though the filter had not applied.
    @Test func tagsWithNothingSurvivingAreZeroNotAbsent() throws {
        let f = try FilterFixture()
        let filter = MediaFilter(required: [.tag(f.bandA.id), .tag(f.bandB.id)])
        let counts = try f.library.filteredTagCounts(kinds: .video, filter: filter)
        #expect(counts[f.sbd.id] == 0)
        #expect(counts.keys.contains(f.sbd.id))
        // Every tag in the library is accounted for, not just matched ones.
        #expect(counts.keys.contains(f.aud.id))
    }

    /// No filter, no work: the sidebar falls back to the baseline counts.
    @Test func anEmptyFilterReturnsNothingToOverride() throws {
        let f = try FilterFixture()
        #expect(try f.library.filteredTagCounts(kinds: .video, filter: MediaFilter()).isEmpty)
    }
}
