import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Media type as a filter with several values, and the sidebar numbers
/// that label it. The rule under test throughout: relaxing
/// one-kind-at-a-time is fine, losing the guard is not.
@Suite struct BrowseKindsAndCountsTests {

    @Test func severalKindsListTogether() throws {
        let f = try FilterFixture()
        let both = try f.names(MediaFilter(), kinds: .all)
        #expect(both == f.allVisibleVideoNames.union(["e.flac"]))
    }

    @Test func oneKindStillExcludesTheOther() throws {
        let f = try FilterFixture()
        #expect(try f.names(MediaFilter(), kinds: .video) == f.allVisibleVideoNames)
        #expect(try f.names(MediaFilter(), kinds: .audio) == ["e.flac"])
    }

    /// The guard moved into the query; it did not go away. An empty
    /// selection is unrepresentable, so no listing path can compile to
    /// "every kind" by omission.
    @Test func aKindSelectionIsNeverEmpty() {
        #expect(MediaKinds([]).kinds == [.video])
        #expect(MediaKinds([.audio, .video]).ordered == [.video, .audio])
    }

    @Test func theLastKindWillNotTurnOff() {
        var kinds = MediaKinds.all
        let removedVideo = kinds.toggle(.video)
        #expect(removedVideo)
        #expect(kinds.kinds == [.audio])
        // Refused, and says so — the sidebar shows the refusal rather
        // than appearing to have ignored the click.
        let removedTheLast = kinds.toggle(.audio)
        #expect(!removedTheLast)
        #expect(kinds.kinds == [.audio])
    }

    @Test func compiledSQLNamesEverySelectedKind() throws {
        let f = try FilterFixture()
        let compiled = FilterCompiler.compile(filter: MediaFilter(), kinds: .all)
        #expect(compiled.sql.contains("mediaItem.kind IN (?, ?)"))
        #expect(try f.library.mediaItems(matching: MediaFilter(), kinds: .all).count
            == f.allVisibleVideoNames.count + 1)
    }

    // MARK: - Counts

    /// The counts and the listing they label share one baseline —
    /// including auto-hide, so "All Items" cannot read one higher than
    /// the grid beneath it.
    @Test func totalMatchesTheListingItLabels() throws {
        let f = try FilterFixture()
        let counts = try f.library.browseCounts(kinds: .video)
        #expect(counts.total == f.allVisibleVideoNames.count)
        #expect(counts.bySource[f.mainSource.id] == counts.total)
    }

    @Test func perTagCountsMatchRequiringThatTag() throws {
        let f = try FilterFixture()
        let counts = try f.library.browseCounts(kinds: .video)
        for tag in [f.bandA, f.bandB, f.sbd, f.aud, f.secret] {
            let listed = try f.names(MediaFilter(required: [.tag(tag.id)])).count
            #expect(counts.byTag[tag.id, default: 0] == listed)
        }
        // Including the hidden-by-default tag, whose row exists precisely
        // so you can go and find those items.
        #expect(counts.byTag[f.secret.id] == 1)
    }

    /// Zero is a value: a tag with nothing under these kinds keeps its
    /// row and reads zero, dimmed, rather than vanishing (#96).
    @Test func aTagWithNothingUnderTheseKindsCountsZeroRatherThanDisappearing() throws {
        let f = try FilterFixture()
        let counts = try f.library.browseCounts(kinds: .audio)
        #expect(counts.byTag[f.bandA.id] == 1)
        #expect(counts.byTag[f.sbd.id, default: 0] == 0)
    }

    @Test func missingCountsMatchTheMissingTerm() throws {
        let f = try FilterFixture()
        let counts = try f.library.browseCounts(kinds: .video)
        for category in [f.band, f.recordingType] {
            let listed = try f.names(
                MediaFilter(required: [.missingCategory(category.id)])).count
            #expect(counts.missingByCategory[category.id, default: 0] == listed)
        }
    }

    @Test func statusCountsMatchTheStatusTerm() throws {
        let f = try FilterFixture()
        let counts = try f.library.browseCounts(kinds: .video)
        for flag in StatusFlag.allCases {
            let listed = try f.names(MediaFilter(required: [.status(flag)])).count
            #expect(counts.byStatus[flag, default: 0] == listed)
        }
    }

    /// The media-type rows count across every kind: an unselected kind
    /// must read what is behind it, not zero.
    @Test func perKindCountsIgnoreTheSelection() throws {
        let f = try FilterFixture()
        let counts = try f.library.browseCounts(kinds: .video)
        #expect(counts.byKind[.audio] == 1)
        #expect(counts.byKind[.video] == f.allVisibleVideoNames.count)
    }

    // MARK: - Category colour

    @Test func categoriesAreDealtDistinctHues() throws {
        let library = try LibraryDatabase.openInMemory()
        for name in ["Band", "Venue", "Year"] {
            try library.createCategory(TagCategory(name: name))
        }
        let indexes = try library.vocabulary().map(\.category.colorIndex)
        #expect(Set(indexes).count == 3)
    }

    /// An explicit colour survives creation — the picker in the
    /// Categories window sets one, and the dealer must not overwrite it.
    @Test func anExplicitColourIsKept() throws {
        let library = try LibraryDatabase.openInMemory()
        try library.createCategory(TagCategory(name: "Band", colorIndex: 4))
        #expect(try library.vocabulary().first?.category.colorIndex == 4)
    }
}
