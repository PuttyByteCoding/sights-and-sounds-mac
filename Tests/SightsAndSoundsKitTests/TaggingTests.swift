import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 4a: the name formatter (ported table), tagging operations,
/// single-select enforcement, focus exclusivity, key bindings.
@Suite struct TaggingTests {

    // MARK: Formatter — ported cases from the web app's tests

    @Test func textFormats() {
        #expect(TagNameFormatter.format("Live Show", textFormat: .noFormatting) == "Live Show")
        #expect(TagNameFormatter.format("Live Show", textFormat: .allLowercase) == "live show")
        #expect(TagNameFormatter.format("Live Show", textFormat: .allUppercase) == "LIVE SHOW")
        // ALL-CAPS words normalize too — predictable, unlike locale title case.
        #expect(TagNameFormatter.format("LIVE SHOW", textFormat: .titleCase) == "Live Show")
        #expect(TagNameFormatter.format("", textFormat: .titleCase) == "")
    }

    @Test func separatorsRunBeforeTheCasePass() {
        #expect(TagNameFormatter.format(
            "dave--matthews_.band", textFormat: .titleCase, separatorsToSpaces: true
        ) == "Dave Matthews Band")
        // Leading/trailing separators trim; runs collapse.
        #expect(TagNameFormatter.format(
            "_hello-world-", textFormat: .noFormatting, separatorsToSpaces: true
        ) == "hello world")
        // Off by default: separators survive.
        #expect(TagNameFormatter.format("a-b", textFormat: .titleCase) == "A-b")
    }

    // MARK: Tag operations

    @Test func ensureTagNormalizesAndDeduplicates() throws {
        let f = try FilterFixture()
        try f.library.writer.write { db in
            var band = f.band
            band.textFormat = .titleCase
            band.separatorsToSpaces = true
            try band.update(db)
        }
        let created = try f.library.ensureTag(named: "the-copper-FOXES", inCategory: f.band.id)
        #expect(created.name == "The Copper Foxes")
        // Same name, any casing/separators → the same tag, not a duplicate.
        let again = try f.library.ensureTag(named: "THE COPPER FOXES", inCategory: f.band.id)
        #expect(again.id == created.id)
    }

    @Test func favoriteAndNotesRoundTrip() throws {
        let f = try FilterFixture()
        try f.library.setTagFavorite(f.bandA.id, true)
        try f.library.setTagNotes(f.bandA.id, "founding lineup only")
        var fetched = try f.library.writer.read { try Tag.fetchOne($0, key: f.bandA.id) }
        #expect(fetched?.isFavorite == true)
        #expect(fetched?.notes == "founding lineup only")
        try f.library.setTagFavorite(f.bandA.id, false)
        try f.library.setTagNotes(f.bandA.id, "")
        fetched = try f.library.writer.read { try Tag.fetchOne($0, key: f.bandA.id) }
        #expect(fetched?.isFavorite == false)
        #expect(fetched?.notes == "")
    }

    @Test func renameRefusesCollision() throws {
        let f = try FilterFixture()
        try f.library.renameTag(f.bandA.id, to: "Band Alpha")
        #expect(throws: (any Error).self) {
            // "band b" collides case-insensitively with existing Band B.
            try f.library.renameTag(f.bandA.id, to: "band b")
        }
    }

    @Test func singleSelectCategoryReplacesOnAssign() throws {
        let f = try FilterFixture()
        // Recording Type in the fixture allows multiple; flip it off.
        try f.library.writer.write { db in
            var recType = f.recordingType
            recType.allowMultiple = false
            try recType.update(db)
        }
        // show1995 already carries SBD; assigning AUD must replace it.
        try f.library.assignTag(f.aud.id, to: f.show1995.id)
        let tags = try f.library.tags(of: f.show1995.id)
        let recTypeTags = tags.first { $0.category.id == f.recordingType.id }?.tags ?? []
        #expect(recTypeTags.map(\.name) == ["AUD"])
        // The Band tag is untouched.
        #expect(tags.contains { $0.category.id == f.band.id })
    }

    @Test func multiSelectCategoryAccumulates() throws {
        let f = try FilterFixture()
        try f.library.assignTag(f.bandB.id, to: f.show1995.id)
        let bands = try f.library.tags(of: f.show1995.id)
            .first { $0.category.id == f.band.id }?.tags ?? []
        #expect(Set(bands.map(\.name)) == ["Band A", "Band B"])
    }

    @Test func toggleRoundTrips() throws {
        let f = try FilterFixture()
        #expect(try f.library.toggleTag(f.bandB.id, on: f.show2001.id) == false)  // had it
        #expect(try f.library.toggleTag(f.bandB.id, on: f.show2001.id) == true)
    }

    @Test func deleteTagSweepsLinks() throws {
        let f = try FilterFixture()
        try f.library.deleteTag(f.bandA.id)
        let remaining = try f.library.writer.read {
            try MediaItemTag.filter(sql: "tagID = ?", arguments: [f.bandA.id]).fetchCount($0)
        }
        #expect(remaining == 0)
        // Items themselves survive.
        #expect(try f.names(MediaFilter()).contains("a.mp4"))
    }

    // MARK: Category configuration

    /// Default focus is gone entirely: focus is the first visible
    /// category by sort order, so there is no flag two categories can
    /// hold at once and no cascade to police it.
    @Test func displayStyleReplacesTheCheckboxBoolean() throws {
        let f = try FilterFixture()
        var band = f.band
        band.displayStyle = .checkboxes
        try f.library.updateCategory(band)
        let stored = try f.library.vocabulary().first { $0.category.id == f.band.id }?.category
        #expect(stored?.displayStyle == .checkboxes)
        #expect(stored?.displayAsCheckboxes == true)
    }

    // MARK: Key bindings

    @Test func bindingsRoundTripAndReplace() throws {
        let f = try FilterFixture()
        try f.library.setKeyBinding("F1", tagID: f.sbd.id, advance: true)
        try f.library.setKeyBinding("B", tagID: f.aud.id)  // letter canonicalizes lowercase
        #expect(try f.library.keyBindings().map(\.key) == ["F1", "b"])

        // Rebinding a key replaces its target.
        try f.library.setKeyBinding("F1", tagID: f.bandA.id)
        let f1 = try f.library.keyBindings().first { $0.key == "F1" }
        #expect(f1?.tagID == f.bandA.id && f1?.advance == false)
    }

    @Test func fixedPlayerKeysAreNotBindable() throws {
        let f = try FilterFixture()
        for key in ["f", "r", "d", "w", " ", "5", "F5", "F10", "t", "u", "k", "g", "i"] {
            #expect(throws: (any Error).self) {
                try f.library.setKeyBinding(key, tagID: f.sbd.id)
            }
        }
    }

    @Test func deletingBoundTagSweepsBinding() throws {
        let f = try FilterFixture()
        try f.library.setKeyBinding("F2", tagID: f.sbd.id)
        try f.library.deleteTag(f.sbd.id)
        #expect(try f.library.keyBindings().isEmpty)
    }
}
