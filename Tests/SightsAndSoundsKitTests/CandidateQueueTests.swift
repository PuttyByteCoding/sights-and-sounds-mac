import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The candidate queue: the three sources reaching one list, the two
/// exclusions (already a tag, already decided), and the one thing that is
/// deliberately NOT excluded — a string a rule would drop.
@Suite struct CandidateQueueTests {

    private func makeLibrary() async throws -> (LibraryDatabase, Source) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Candidates")
        let source = Source(name: "S", rootPath: "/tmp/candidates")
        try await library.writer.write { try source.insert($0) }
        return (library, source)
    }

    @discardableResult
    private func insertItem(
        _ library: LibraryDatabase, _ source: Source, path: String
    ) async throws -> MediaItem {
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: path, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return item
    }

    private func rule(_ matcher: RuleMatcher, _ actions: [RuleAction]) -> RuleEngine.Rule {
        RuleEngine.Rule(id: UUID(), matcher: matcher, actions: actions)
    }

    // MARK: - Counting

    @Test func metadataPairsCountDistinctItems() async throws {
        let (library, source) = try await makeLibrary()
        let a = try await insertItem(library, source, path: "a.mp4")
        let b = try await insertItem(library, source, path: "b.mp4")
        let c = try await insertItem(library, source, path: "c.mp4")

        for item in [a, b, c] {
            try library.recordMetadataPairs(
                itemID: item.id, pairs: [("artist", "Miles Davis")])
        }
        try library.recordMetadataPairs(itemID: a.id, pairs: [
            ("artist", "Miles Davis"), ("album", "Kind of Blue"),
        ])

        let candidates = try library.tagCandidates(sources: [.metadata])
        let miles = try #require(candidates.first { $0.value == "Miles Davis" })
        #expect(miles.itemCount == 3)
        #expect(miles.key == "artist")
        // Commonest first — the whole point of the bulk bar.
        #expect(candidates.first?.value == "Miles Davis")
        #expect(candidates.contains { $0.value == "Kind of Blue" && $0.itemCount == 1 })
    }

    @Test func pathSegmentInOneFolderCountsThatFolderOnce() async throws {
        let (library, source) = try await makeLibrary()
        // "live" appears TWICE in this one path. The number is "items the
        // string appears in", not occurrences, so it must count once.
        try await insertItem(library, source, path: "live/1994/live/a.mp4")
        try await insertItem(library, source, path: "live/1994/live/b.mp4")

        let candidates = try library.tagCandidates(sources: [.path])
        let live = try #require(candidates.first { $0.value == "live" })
        #expect(live.itemCount == 2)
        #expect(live.key == nil)  // a directory name has no enclosing key
    }

    @Test func onScreenLinesGroupByText() async throws {
        let (library, source) = try await makeLibrary()
        let a = try await insertItem(library, source, path: "a.mp4")
        let b = try await insertItem(library, source, path: "b.mp4")
        try await library.writer.write { db in
            try OcrTextLine(mediaItemID: a.id, timeSeconds: 1, text: "Newport").insert(db)
            try OcrTextLine(mediaItemID: a.id, timeSeconds: 9, text: "Newport").insert(db)
            try OcrTextLine(mediaItemID: b.id, timeSeconds: 3, text: "Newport").insert(db)
        }

        let candidates = try library.tagCandidates(sources: [.onScreen])
        let newport = try #require(candidates.first { $0.value == "Newport" })
        // Two items, though three lines: DISTINCT mediaItemID.
        #expect(newport.itemCount == 2)
    }

    // MARK: - Exclusions

    @Test func stringMatchingATagOrItsAliasIsNotACandidate() async throws {
        let (library, source) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        let category = TagCategory(name: "Artist")
        let tag = Tag(tagCategoryID: category.id, name: "Miles Davis")
        try await library.writer.write { db in
            try category.insert(db)
            try tag.insert(db)
            try TagAlias(tagID: tag.id, alias: "Miles").insert(db)
        }
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("artist", "Miles Davis"),  // a tag name
            ("artist", "Miles"),        // one of its aliases — also not news
            ("artist", "Bill Evans"),   // neither
        ])

        let values = try library.tagCandidates(sources: [.metadata]).map(\.value)
        #expect(values == ["Bill Evans"])
    }

    @Test func ignoredCandidateStaysIgnoredUntilCleared() async throws {
        let (library, source) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [("comment", "ripped by xyz")])

        let candidate = try #require(try library.tagCandidates(sources: [.metadata]).first)
        try library.decide(candidate, as: .ignored)
        #expect(try library.tagCandidates(sources: [.metadata]).isEmpty)

        // The queue is DERIVED, so re-recording the same pair must not
        // resurrect it — that is what keying the decision by
        // (source, key, value) instead of a row id buys.
        try library.recordMetadataPairs(itemID: item.id, pairs: [("comment", "ripped by xyz")])
        #expect(try library.tagCandidates(sources: [.metadata]).isEmpty)

        try library.clearDecision(for: candidate)
        #expect(try library.tagCandidates(sources: [.metadata]).count == 1)
    }

    // MARK: - Rules

    @Test func ruleSuppressedCandidateIsMarkedButStillListed() async throws {
        let (library, source) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [("encoder", "Lavf58")])

        let ignoreEncoder = rule(.keyEquals(key: "encoder"), [.ignore])
        let candidates = try library.tagCandidates(sources: [.metadata], rules: [ignoreEncoder])

        // Shown, not removed: a mis-authored ignore rule has to be
        // diagnosable rather than invisible.
        let encoder = try #require(candidates.first { $0.value == "Lavf58" })
        #expect(encoder.suppressedByRule == "key \"encoder\"")
        #expect(encoder.coveredByRuleID == ignoreEncoder.id)
    }

    @Test func assignedCategoryIsCarriedOntoTheCandidate() async throws {
        let (library, source) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [("artist", "Bill Evans")])

        let candidates = try library.tagCandidates(
            sources: [.metadata],
            rules: [rule(.keyEquals(key: "artist"), [.assignCategory(category: "Artist")])])
        #expect(candidates.first?.suggestedCategory == "Artist")
        #expect(candidates.first?.suppressedByRule == nil)
    }

    @Test func hiddenRootRuleRemovesThePrefixFromPathCandidates() async throws {
        let (library, source) = try await makeLibrary()
        try await insertItem(library, source, path: "Archive/Concerts/a.mp4")

        let hide = rule(.pathRootStartsWith(root: "Archive"), [.hidePrefix])
        let values = Set(
            try library.tagCandidates(sources: [.path], rules: [hide]).map(\.value))
        #expect(values.contains("Concerts"))
        #expect(!values.contains("Archive"))
    }

    // MARK: - Sweep state

    @Test func itemWithNoMetadataIsNotSweptTwice() async throws {
        let (library, source) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        #expect(try library.itemsNeedingMetadataSweep().count == 1)

        // No pairs at all — the marker is the only thing that stops this
        // item being re-probed on every run forever.
        try library.recordMetadataPairs(itemID: item.id, pairs: [])
        #expect(try library.itemsNeedingMetadataSweep().isEmpty)

        let state = try await library.writer.read { try MetadataSweepState.fetchOne($0, key: item.id) }
        #expect(state != nil)
        #expect(state?.failureMessage == nil)
    }

    @Test func failedSweepRecordsTheReasonAndStillMarksTheItem() async throws {
        let (library, source) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [], failure: "ffprobe failed")

        #expect(try library.itemsNeedingMetadataSweep().isEmpty)
        let state = try await library.writer.read { try MetadataSweepState.fetchOne($0, key: item.id) }
        #expect(state?.failureMessage == "ffprobe failed")
    }

    @Test func resweepReplacesRatherThanAccumulates() async throws {
        let (library, source) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [("artist", "Old")])
        try library.recordMetadataPairs(itemID: item.id, pairs: [("artist", "New")])

        let values = try library.tagCandidates(sources: [.metadata]).map(\.value)
        #expect(values == ["New"])
    }

    @Test func blankValuesNeverBecomeCandidates() async throws {
        let (library, source) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("artist", "   "), ("album", "\n"), ("title", " Real "),
        ])

        let values = try library.tagCandidates(sources: [.metadata]).map(\.value)
        #expect(values == ["Real"])  // trimmed, and the blanks are gone
    }
}
