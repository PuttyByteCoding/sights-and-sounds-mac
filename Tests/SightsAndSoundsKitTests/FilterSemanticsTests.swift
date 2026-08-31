import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The three-way filter semantics matrix, mirrored from the web app's
/// `MatchesFilter` / `VideoFilterTranslator` behavior — but every case here
/// runs entirely in SQL.
@Suite struct FilterSemanticsTests {

    // MARK: Baseline

    @Test func emptyFilterShowsEverythingExceptHiddenAndSpent() throws {
        let f = try FilterFixture()
        // hiddenShow (auto-hide) and spentClipRow (clipExported) are absent.
        #expect(try f.names(MediaFilter()) == f.allVisibleVideoNames)
    }

    @Test func kindHardFilterSeparatesAudio() throws {
        let f = try FilterFixture()
        #expect(try f.names(MediaFilter(), kinds: .audio) == ["e.flac"])
        // bandA is on both a video and the audio item; kind still separates.
        let byTag = MediaFilter(required: [.tag(f.bandA.id)])
        #expect(try f.names(byTag, kinds: .video) == ["a.mp4", "b.mp4"])
        #expect(try f.names(byTag, kinds: .audio) == ["e.flac"])
    }

    // MARK: Slots

    @Test func requiredTermsAllMustMatch() throws {
        let f = try FilterFixture()
        let filter = MediaFilter(required: [.tag(f.bandA.id), .tag(f.sbd.id)])
        #expect(try f.names(filter) == ["a.mp4"])
    }

    @Test func optionalTermsAtLeastOneMustMatch() throws {
        let f = try FilterFixture()
        let filter = MediaFilter(optional: [.tag(f.sbd.id), .tag(f.aud.id)])
        #expect(try f.names(filter) == ["a.mp4", "b.mp4"])
    }

    @Test func excludedTermsNoneMayMatch() throws {
        let f = try FilterFixture()
        let filter = MediaFilter(required: [.tag(f.bandA.id)], excluded: [.tag(f.aud.id)])
        #expect(try f.names(filter) == ["a.mp4"])
    }

    @Test func slotsCombine() throws {
        let f = try FilterFixture()
        // In shows/ subtree, carrying either recording type, not AUD.
        let filter = MediaFilter(
            required: [.subtree("shows")],
            optional: [.tag(f.sbd.id), .tag(f.aud.id)],
            excluded: [.tag(f.aud.id)])
        #expect(try f.names(filter) == ["a.mp4"])
    }

    // MARK: Folder terms — the fixed in-memory exception

    @Test func folderMatchesExactDirectoryOnly() throws {
        let f = try FilterFixture()
        #expect(try f.names(MediaFilter(required: [.folder("shows/1995")])) == ["a.mp4"])
    }

    @Test func folderIsCaseInsensitiveAndNormalized() throws {
        let f = try FilterFixture()
        #expect(try f.names(MediaFilter(required: [.folder("SHOWS/1995")])) == ["a.mp4"])
        #expect(try f.names(MediaFilter(required: [.folder("shows/1995/")])) == ["a.mp4"])
        #expect(try f.names(MediaFilter(required: [.folder("shows\\1995")])) == ["a.mp4"])
    }

    @Test func subtreeMatchesFolderAndBelow() throws {
        let f = try FilterFixture()
        let filter = MediaFilter(required: [.subtree("shows/1995")])
        #expect(try f.names(filter) == ["a.mp4", "b.mp4"])
    }

    @Test func emptySubtreeIsWholeLibrary() throws {
        let f = try FilterFixture()
        #expect(try f.names(MediaFilter(required: [.subtree("")])) == f.allVisibleVideoNames)
    }

    @Test func subtreeEscapesLikeWildcards() throws {
        let f = try FilterFixture()
        // The old stack's regression: an unescaped `_` either matched nothing
        // or matched `myxband`. Exact escape semantics under test.
        let filter = MediaFilter(required: [.subtree("shows/my_band")])
        #expect(try f.names(filter) == ["f.mp4"])
    }

    // MARK: Missing

    @Test func missingCategoryMatchesItemsWithoutTagsFromIt() throws {
        let f = try FilterFixture()
        let filter = MediaFilter(required: [.missingCategory(f.recordingType.id)])
        // Everything visible except the two items carrying a recording type.
        #expect(try f.names(filter) == f.allVisibleVideoNames.subtracting(["a.mp4", "b.mp4"]))
    }

    // MARK: Status flags

    @Test func statusFlags() throws {
        let f = try FilterFixture()
        #expect(try f.names(MediaFilter(required: [.status(.needsReview)])) == ["h.mp4"])
        #expect(try f.names(MediaFilter(required: [.status(.favorite)])) == ["h.mp4"])
        #expect(try f.names(MediaFilter(required: [.status(.embedded)])) == ["i.mp4"])
        #expect(try f.names(MediaFilter(required: [.status(.exported)])) == ["k.mp4"])
        #expect(try f.names(MediaFilter(required: [.status(.edited)])) == ["j.mp4"])
        // The umbrella: embedded OR user-marked OR exported.
        #expect(try f.names(MediaFilter(required: [.status(.clip)])) == ["i.mp4", "j.mp4", "k.mp4"])
    }

    // MARK: Auto-hide

    @Test func hiddenTagSuppressesByDefault() throws {
        let f = try FilterFixture()
        #expect(try !f.names(MediaFilter()).contains("d.mp4"))
    }

    @Test func referencingHiddenTagExemptsIt() throws {
        let f = try FilterFixture()
        #expect(try f.names(MediaFilter(required: [.tag(f.secret.id)])) == ["d.mp4"])
        let viaOptional = MediaFilter(optional: [.tag(f.secret.id), .tag(f.bandB.id)])
        #expect(try f.names(viaOptional) == ["c.mp4", "d.mp4"])
    }

    @Test func excludingHiddenTagStillHidesItsItems() throws {
        let f = try FilterFixture()
        // Referencing exempts from auto-hide, but the excluded slot then
        // removes the same rows — net result identical to the empty filter.
        let filter = MediaFilter(excluded: [.tag(f.secret.id)])
        #expect(try f.names(filter) == f.allVisibleVideoNames)
    }
}

/// Saved filters: round trip, same-name replacement, stale terms.
@Suite struct SavedFilterTests {
    @Test func aFilterRoundTripsWithEveryTermKind() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Filters")
        let tagID = UUID(), categoryID = UUID()
        let original = MediaFilter(
            required: [.tag(tagID), .subtree("shows/2024")],
            optional: [.status(.favorite), .folder("shows")],
            excluded: [.missingCategory(categoryID)],
            searchText: "newport")

        let saved = try library.saveFilter(named: "Good SBDs", original)
        let loaded = try #require(try library.savedFilters().first)
        #expect(loaded.id == saved.id)
        #expect(loaded.name == "Good SBDs")
        #expect(loaded.filter == original)
    }

    @Test func savingTheSameNameReplacesNotDuplicates() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Filters")
        let first = try library.saveFilter(named: "Favorites", MediaFilter(searchText: "a"))
        // Case-insensitively the same name — one row, updated in place,
        // same identity so anything holding the id stays valid.
        let second = try library.saveFilter(named: "favorites", MediaFilter(searchText: "b"))
        #expect(second.id == first.id)

        let all = try library.savedFilters()
        #expect(all.count == 1)
        #expect(all.first?.filter?.searchText == "b")
    }

    @Test func deletingRemovesAndBlankNamesAreRefused() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Filters")
        let saved = try library.saveFilter(named: "Doomed", MediaFilter())
        try library.deleteSavedFilter(saved.id)
        #expect(try library.savedFilters().isEmpty)
        #expect(throws: Error.self) {
            try library.saveFilter(named: "   ", MediaFilter())
        }
    }
}

extension SavedFilterTests {
    @Test func renamingChangesTheLabelAndRefusesRivals() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Filters")
        let keep = try library.saveFilter(named: "Favorites", MediaFilter(searchText: "a"))
        let other = try library.saveFilter(named: "SBDs", MediaFilter(searchText: "b"))

        try library.renameSavedFilter(keep.id, to: "Best Shows")
        let renamed = try #require(try library.savedFilters().first { $0.id == keep.id })
        #expect(renamed.name == "Best Shows")
        #expect(renamed.filter?.searchText == "a")  // the filter itself untouched

        // A rival's name is refused, not merged — case-insensitively.
        #expect(throws: Error.self) {
            try library.renameSavedFilter(keep.id, to: "sbds")
        }
        // Renaming to your OWN name (case change only) is fine.
        try library.renameSavedFilter(other.id, to: "sbds")
        #expect(try library.savedFilters().contains { $0.name == "sbds" })
    }
}

/// The analyzed marker and its three status filters.
@Suite struct AnalyzedMarkerTests {
    @Test func markingStampsTheCurrentVersionAndUpserts() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Marker")
        let source = Source(name: "S", rootPath: "/tmp/marker")
        try await library.writer.write { try source.insert($0) }
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { try item.insert($0) }

        try library.markAnalyzed(item.id)
        try library.markAnalyzed(item.id)  // advancing back and forth — one row
        let states = try await library.writer.read { try TagAnalysisState.fetchAll($0) }
        #expect(states.count == 1)
        #expect(states.first?.analyzerVersion == ItemAnalysis.analyzerVersion)
    }

    @Test func theThreeStatusPredicatesPartitionTheLibrary() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Marker")
        let source = Source(name: "S", rootPath: "/tmp/marker")
        try await library.writer.write { try source.insert($0) }

        func insert(_ path: String) async throws -> MediaItem {
            let item = MediaItem(
                sourceID: source.id, kind: .video, relativePath: path, needsReview: false)
            try await library.writer.write { try item.insert($0) }
            return item
        }
        let current = try await insert("current.mp4")
        let stale = try await insert("stale.mp4")
        _ = try await insert("never.mp4")

        try library.markAnalyzed(current.id)
        // An item visited under an OLDER analyzer.
        try await library.writer.write { db in
            try TagAnalysisState(
                mediaItemID: stale.id,
                analyzerVersion: ItemAnalysis.analyzerVersion - 1
            ).upsert(db)
        }

        func count(_ flag: StatusFlag) async throws -> Int {
            try await library.writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM mediaItem WHERE \(FilterCompiler.Baseline.status(flag))"
                ) ?? 0
            }
        }
        #expect(try await count(.analyzedCurrent) == 1)
        #expect(try await count(.analyzedStale) == 1)
        #expect(try await count(.neverAnalyzed) == 1)
    }
}
