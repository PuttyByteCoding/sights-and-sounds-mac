import Foundation
import GRDB
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The Import window tags through the player's own panel. Its boxes used
/// to offer five plain matches that only a click could pick: no arrows,
/// nothing for Enter, no aliases. `ImportTagging` is what the panel
/// writes to there: what is staged for the import, not an item's tags.
@Suite @MainActor struct ImportTaggingTests {
    private struct Fixture {
        let library: LibraryDatabase
        let tagging: ImportTagging
        let venue: TagCategory
        let format: TagCategory
        let flags: TagCategory
        let venues: [SightsAndSoundsKit.Tag]
        let formats: [SightsAndSoundsKit.Tag]
        let flagTags: [SightsAndSoundsKit.Tag]
    }

    private func fixture() async throws -> Fixture {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportTagging")
        let venue = TagCategory(name: "Venue", sortOrder: 0)
        var format = TagCategory(name: "Format", sortOrder: 10)
        format.displayStyle = .radio
        var flags = TagCategory(name: "Flags", sortOrder: 20)
        flags.displayStyle = .checkboxes
        let venues = ["Fillmore", "Winterland"].map { SightsAndSoundsKit.Tag(tagCategoryID: venue.id, name: $0) }
        let formats = ["Audio", "Video"].map { SightsAndSoundsKit.Tag(tagCategoryID: format.id, name: $0) }
        let flagTags = [SightsAndSoundsKit.Tag(tagCategoryID: flags.id, name: "Rare")]
        let categories = [venue, format, flags]
        try await library.writer.write { db in
            for category in categories { try category.insert(db) }
            for tag in venues + formats + flagTags { try tag.insert(db) }
        }
        let service = LocalLibraryService(library: library, runner: JobRunner(library: library))
        let tagging = ImportTagging(service: service, libraryID: UUID())
        tagging.show(
            vocabulary: [
                CategoryTags(category: venue, tags: venues),
                CategoryTags(category: format, tags: formats),
                CategoryTags(category: flags, tags: flagTags),
            ],
            aliases: [:])
        return Fixture(
            library: library, tagging: tagging, venue: venue, format: format, flags: flags,
            venues: venues, formats: formats, flagTags: flagTags)
    }

    @Test func aPickStagesTheTagAndAnotherPickUnstagesIt() async throws {
        let f = try await fixture()
        f.tagging.toggleTag(f.venues[1].id)
        f.tagging.toggleTag(f.flagTags[0].id)
        #expect(f.tagging.hasTag(f.venues[1].id))
        #expect(f.tagging.draft.tagIDs == [f.venues[1].id, f.flagTags[0].id])
        // The panel's pills: staged tags by category, in vocabulary order.
        #expect(f.tagging.itemTags.map(\.category.name) == ["Venue", "Flags"])
        #expect(f.tagging.itemTags.first?.tags.map(\.name) == ["Winterland"])

        f.tagging.toggleTag(f.venues[1].id)
        #expect(!f.tagging.hasTag(f.venues[1].id))
        #expect(f.tagging.itemTags.map(\.category.name) == ["Flags"])
    }

    @Test func aRadioCategoryHoldsOneTag() async throws {
        let f = try await fixture()
        f.tagging.toggleTag(f.formats[0].id)
        f.tagging.toggleTag(f.venues[0].id)
        f.tagging.toggleTag(f.formats[1].id)
        #expect(f.tagging.draft.tagIDs == [f.venues[0].id, f.formats[1].id])
    }

    @Test func historyRecordsAppliesNewestFirstAndNotRemovals() async throws {
        let f = try await fixture()
        f.tagging.toggleTag(f.venues[0].id)
        f.tagging.toggleTag(f.venues[1].id)
        f.tagging.toggleTag(f.venues[0].id)  // a removal
        #expect(f.tagging.recentlyAppliedTagIDs == [f.venues[1].id, f.venues[0].id])
        f.tagging.toggleTag(f.venues[0].id)
        #expect(f.tagging.recentlyAppliedTagIDs == [f.venues[0].id, f.venues[1].id])
    }

    /// There is no playing item in Import, so no Tag Analysis row; the
    /// Universal field and every category are there.
    @Test func theRowsAreThePlayersWithoutTagAnalysis() async throws {
        let f = try await fixture()
        let rows = f.tagging.panelRows
        #expect(!rows.contains(.results))
        #expect(rows.contains(.universal))
        #expect(Set(rows.compactMap(\.categoryID)) == [f.venue.id, f.format.id, f.flags.id])
        #expect(f.tagging.checkboxCategory == nil)
        #expect(f.tagging.playerModel == nil)
    }

    /// Tab walks the fields you can type in: the checkbox and radio
    /// lists have none.
    @Test func tabWalksTheTypableFieldsAndWraps() async throws {
        let f = try await fixture()
        let walk = f.tagging.panelRows.filter { $0 == .universal || $0.categoryID == f.venue.id }
            .map(\.focusID)
        f.tagging.tagFieldCategoryID = walk[0]
        #expect(f.tagging.advanceTagField(reverse: false))
        #expect(f.tagging.tagFieldCategoryID == walk[1])
        #expect(f.tagging.advanceTagField(reverse: false))
        #expect(f.tagging.tagFieldCategoryID == walk[0])
        #expect(f.tagging.advanceTagField(reverse: true))
        #expect(f.tagging.tagFieldCategoryID == walk[1])
    }

    /// Every category's heading carries the chip, box or not; turning it
    /// on for a category with no box makes one.
    @Test func stickyIsPerCategoryAndKeepsThatCategorysTags() async throws {
        let f = try await fixture()
        #expect(f.tagging.sticky(for: f.venue.id) == false)
        f.tagging.setSticky(true, for: f.venue.id)
        #expect(f.tagging.sticky(for: f.venue.id) == true)
        #expect(f.tagging.boxes.count == 1)

        f.tagging.toggleTag(f.venues[0].id)
        f.tagging.toggleTag(f.formats[0].id)
        f.tagging.persistSticky(from: f.tagging.draft)
        // Only the sticky category's tags come back for the next import.
        #expect(f.tagging.stickyDraft().tagIDs == [f.venues[0].id])

        // A sticky tag since deleted does not come back as a dead id.
        f.tagging.show(
            vocabulary: [CategoryTags(category: f.venue, tags: [f.venues[1]])], aliases: [:])
        #expect(f.tagging.stickyDraft().tagIDs.isEmpty)
    }
}
