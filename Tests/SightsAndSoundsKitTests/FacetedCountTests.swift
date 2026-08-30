import Foundation
import Testing

@testable import SightsAndSoundsKit

/// Tag counts under the active filter — "if I added this, how many would
/// survive" — and the facet-scoping that keeps them useful.
@Suite struct FacetedCountTests {

    /// A fresh library where the co-occurrence is the point: every item
    /// carries Band A; only some also carry SBD.
    private func fixture() throws -> (LibraryDatabase, FilterFixture) {
        let f = try FilterFixture()
        return (f.library, f)
    }

    /// The headline case. Requiring one tag narrows the counts of tags in
    /// OTHER categories to the overlap, which is the whole request:
    /// SBD's number becomes "SBD *and* Band A", not "SBD".
    @Test func requiringATagNarrowsOtherCategoriesToTheOverlap() throws {
        let (library, f) = try fixture()
        let unfiltered = try library.browseCounts(kinds: .video).byTag[f.sbd.id] ?? 0

        let filter = MediaFilter(required: [.tag(f.bandA.id)])
        let narrowed = try library.filteredTagCounts(kinds: .video, filter: filter)[f.sbd.id]

        #expect(narrowed != nil)
        #expect(narrowed! <= unfiltered)
        // And it is the genuine intersection, not a coincidence of size.
        let both = try library.mediaItems(
            matching: MediaFilter(required: [.tag(f.bandA.id), .tag(f.sbd.id)]),
            kinds: .video).count
        #expect(narrowed == both)
    }

    /// The trap this design exists to avoid: requiring Band A must NOT
    /// zero every other Band tag, or the category collapses into a column
    /// of zeros and you can never switch from one band to another.
    @Test func aCategoryStaysBrowsableWhileItIsBeingFiltered() throws {
        let (library, f) = try fixture()
        let filter = MediaFilter(required: [.tag(f.bandA.id)])
        let counts = try library.filteredTagCounts(kinds: .video, filter: filter)

        // Band B is in the SAME category as the required tag. Counted
        // under the whole filter it would be 0; scoped, it reports what
        // switching to it would actually give.
        let bandB = try library.mediaItems(
            matching: MediaFilter(required: [.tag(f.bandB.id)]), kinds: .video).count
        #expect(counts[f.bandB.id] == bandB)
    }

    /// Same reason, other direction: an excluded tag's own exclusion
    /// would otherwise guarantee it reads zero, which tells you nothing.
    @Test func anExcludedTagStillReportsARealNumber() throws {
        let (library, f) = try fixture()
        let filter = MediaFilter(excluded: [.tag(f.bandA.id)])
        let counts = try library.filteredTagCounts(kinds: .video, filter: filter)

        let bandA = try library.mediaItems(
            matching: MediaFilter(required: [.tag(f.bandA.id)]), kinds: .video).count
        #expect(counts[f.bandA.id] == bandA)
    }

    /// Filters in OTHER categories still narrow a category's tags — only
    /// its own terms are dropped, not the whole filter.
    @Test func otherCategoriesStillNarrow() throws {
        let (library, f) = try fixture()
        let plain = try library.filteredTagCounts(
            kinds: .video, filter: MediaFilter(required: [.tag(f.bandA.id)]))
        let alsoSBD = try library.filteredTagCounts(
            kinds: .video,
            filter: MediaFilter(required: [.tag(f.bandA.id), .tag(f.sbd.id)]))
        // Band B is scoped away from the Band term either way, but the
        // Recording Type term applies to it in the second case.
        #expect((alsoSBD[f.bandB.id] ?? 0) <= (plain[f.bandB.id] ?? 0))
    }

    /// Zero is present, not missing. The sidebar strikes and sinks zeros,
    /// and "no matching items" is a different fact from "no data".
    @Test func tagsWithNothingSurvivingAreZeroNotAbsent() throws {
        let (library, f) = try fixture()
        let filter = MediaFilter(required: [.tag(f.bandA.id), .tag(f.bandB.id)])
        let counts = try library.filteredTagCounts(kinds: .video, filter: filter)
        #expect(counts[f.sbd.id] == 0)
        #expect(counts.keys.contains(f.sbd.id))
    }

    /// No filter, no work: the sidebar falls back to the baseline counts.
    @Test func anEmptyFilterReturnsNothingToOverride() throws {
        let (library, _) = try fixture()
        #expect(try library.filteredTagCounts(kinds: .video, filter: MediaFilter()).isEmpty)
    }
}
