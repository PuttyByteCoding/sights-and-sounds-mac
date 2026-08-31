import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Storing, ordering and dry-running rules. Order is the engine, so most
/// of what matters here is that the stored order is the fold order.
@Suite struct RuleStoreTests {

    private func makeLibrary() async throws -> (LibraryDatabase, Source) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Rules")
        let source = Source(name: "S", rootPath: "/tmp/rules")
        try await library.writer.write { try source.insert($0) }
        return (library, source)
    }

    private func rule(_ matcher: RuleMatcher, _ actions: [RuleAction] = []) -> RuleEngine.Rule {
        RuleEngine.Rule(id: UUID(), matcher: matcher, actions: actions)
    }

    @discardableResult
    private func itemWithPairs(
        _ library: LibraryDatabase, _ source: Source, path: String,
        _ pairs: [(name: String, value: String)]
    ) async throws -> MediaItem {
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: path, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        try library.recordMetadataPairs(itemID: item.id, pairs: pairs)
        return item
    }

    @Test func aSavedRuleRoundTripsThroughTheWireFormat() async throws {
        let (library, _) = try await makeLibrary()
        let original = rule(
            .keyEquals(key: "band"),
            [.stripPrefix(prefix: "The "), .assignCategory(category: "Band")])
        try library.saveAnalysisRule(original)

        let loaded = try library.analysisRules()
        #expect(loaded == [original])
    }

    @Test func savingTwiceUpdatesRatherThanDuplicates() async throws {
        let (library, _) = try await makeLibrary()
        var subject = rule(.keyEquals(key: "band"))
        try library.saveAnalysisRule(subject)
        subject = RuleEngine.Rule(
            id: subject.id, matcher: .keyEquals(key: "artist"), actions: [.ignore])
        try library.saveAnalysisRule(subject)

        let loaded = try library.analysisRules()
        #expect(loaded.count == 1)
        #expect(loaded.first?.matcher == .keyEquals(key: "artist"))
        #expect(loaded.first?.actions == [.ignore])
    }

    @Test func newRulesAppendAndOrderIsTheFoldOrder() async throws {
        let (library, _) = try await makeLibrary()
        let first = rule(.keyEquals(key: "a"))
        let second = rule(.keyEquals(key: "b"))
        let third = rule(.keyEquals(key: "c"))
        for one in [first, second, third] { try library.saveAnalysisRule(one) }

        #expect(try library.analysisRules().map(\.id) == [first.id, second.id, third.id])

        try library.moveAnalysisRule(third.id, up: true)
        #expect(try library.analysisRules().map(\.id) == [first.id, third.id, second.id])

        // A move at the end is a no-op, not an error — the buttons are
        // always present and disabling them is the view's business.
        try library.moveAnalysisRule(first.id, up: true)
        #expect(try library.analysisRules().map(\.id) == [first.id, third.id, second.id])
    }

    @Test func orderIsStoredDenselyAfterAMove() async throws {
        let (library, _) = try await makeLibrary()
        let ids = (0..<3).map { _ in UUID() }
        for id in ids {
            try library.saveAnalysisRule(
                RuleEngine.Rule(id: id, matcher: .keyEquals(key: "k"), actions: []))
        }
        try library.moveAnalysisRule(ids[2], up: true)

        // Dense from zero: a gap is invisible on screen and survives into
        // every later insert.
        #expect(try library.analysisRuleRecords().map(\.sortOrder) == [0, 1, 2])
    }

    @Test func deletingLeavesTheRest() async throws {
        let (library, _) = try await makeLibrary()
        let keep = rule(.keyEquals(key: "keep"))
        let drop = rule(.keyEquals(key: "drop"))
        try library.saveAnalysisRule(keep)
        try library.saveAnalysisRule(drop)

        try library.deleteAnalysisRule(drop.id)
        #expect(try library.analysisRules().map(\.id) == [keep.id])
    }

    // MARK: - Dry run

    @Test func dryRunCountsCandidatesAndDistinctItems() async throws {
        let (library, source) = try await makeLibrary()
        try await itemWithPairs(library, source, path: "a.mp4", [
            ("band", "Miles Davis"), ("band", "Bill Evans"),
        ])
        try await itemWithPairs(library, source, path: "b.mp4", [("band", "Miles Davis")])
        try await itemWithPairs(library, source, path: "c.mp4", [("album", "Kind of Blue")])

        let result = try library.dryRun(rule(.keyEquals(key: "band"), [.assignCategory(category: "Band")]))
        // Two distinct strings under the key…
        #expect(result.matchedCandidates == 2)
        // …across two items, not three: the counts overlap and summing
        // them would overstate the blast radius.
        #expect(result.affectedItems == 2)
        #expect(result.metadataMatches == 2)
        #expect(result.actionCount == 1)
    }

    @Test func dryRunOfARuleThatMatchesNothingIsEmpty() async throws {
        let (library, source) = try await makeLibrary()
        try await itemWithPairs(library, source, path: "a.mp4", [("band", "Miles Davis")])

        let result = try library.dryRun(rule(.keyEquals(key: "nothing")))
        #expect(result.isEmpty)
        #expect(result.affectedItems == 0)
    }

    @Test func dryRunReportsHowManyMatchesAreNotMetadata() async throws {
        let (library, source) = try await makeLibrary()
        try await itemWithPairs(library, source, path: "Live/a.mp4", [("band", "Live Aid")])

        // valueStartsWith fires on the metadata value AND the path
        // segment. The sentence naming "metadata pairs" is only the whole
        // truth when these two numbers agree, so both are reported.
        let result = try library.dryRun(rule(.valueStartsWith(prefix: "Live")))
        #expect(result.matchedCandidates == 2)
        #expect(result.metadataMatches == 1)
    }

    @Test func dryRunIsUnaffectedByTheOtherStoredRules() async throws {
        let (library, source) = try await makeLibrary()
        try await itemWithPairs(library, source, path: "a.mp4", [("band", "Miles Davis")])
        // A stored rule that would drop the candidate entirely.
        try library.saveAnalysisRule(rule(.keyEquals(key: "band"), [.ignore]))

        // The question is "what does THIS rule fire on", not "what
        // survives the whole fold" — otherwise every rule authored after
        // a broad ignore rule would dry-run as matching nothing.
        let result = try library.dryRun(rule(.keyEquals(key: "band"), [.assignCategory(category: "Band")]))
        #expect(result.matchedCandidates == 1)
    }

    // MARK: - Make a rule from this

    @Test func aKeyedCandidateBecomesAKeyEqualsMatcher() async throws {
        let (library, source) = try await makeLibrary()
        try await itemWithPairs(library, source, path: "a.mp4", [("band", "Miles Davis")])
        let candidate = try #require(try library.tagCandidates(sources: [.metadata]).first)

        #expect(LibraryDatabase.matcher(forNewRuleFrom: candidate) == .keyEquals(key: "band"))
    }

    @Test func anUnkeyedCandidateFallsBackToItsValue() async throws {
        let (library, source) = try await makeLibrary()
        try await itemWithPairs(library, source, path: "Concerts/a.mp4", [])
        let candidate = try #require(try library.tagCandidates(sources: [.path]).first)

        #expect(candidate.key == nil)
        #expect(
            LibraryDatabase.matcher(forNewRuleFrom: candidate)
                == .valueStartsWith(prefix: "Concerts"))
    }

    @Test func anAlreadyCoveredCandidateNamesTheRuleToOpen() async throws {
        let (library, source) = try await makeLibrary()
        try await itemWithPairs(library, source, path: "a.mp4", [("band", "Miles Davis")])
        let covering = rule(.keyEquals(key: "band"), [.assignCategory(category: "Band")])
        try library.saveAnalysisRule(covering)

        let candidate = try #require(try library.tagCandidates(sources: [.metadata]).first)
        // Spec §4: open that rule rather than adding a rival.
        #expect(try library.ruleCovering(candidate)?.id == covering.id)
        #expect(candidate.coveredByRuleID == nil)  // computed with no rules passed
    }
}

/// Applying a rule. The value the tag takes is the FOLDED one, which is
/// the whole reason `stripPrefix` pairs with `assignCategory`.
@Suite struct RuleApplicationTests {

    private func makeLibrary() async throws -> (LibraryDatabase, Source, TagCategory) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Applying")
        let source = Source(name: "S", rootPath: "/tmp/applying")
        let category = TagCategory(name: "Band")
        try await library.writer.write { db in
            try source.insert(db)
            try category.insert(db)
        }
        return (library, source, category)
    }

    @discardableResult
    private func itemWithPairs(
        _ library: LibraryDatabase, _ source: Source, path: String,
        _ pairs: [(name: String, value: String)]
    ) async throws -> MediaItem {
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: path, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        try library.recordMetadataPairs(itemID: item.id, pairs: pairs)
        return item
    }

    @Test func theTagTakesTheFoldedValueNotTheRawOne() async throws {
        let (library, source, category) = try await makeLibrary()
        let item = try await itemWithPairs(
            library, source, path: "a.mp4", [("band", "The Beatles")])

        let result = try library.applyAnalysisRule(
            RuleEngine.Rule(
                id: UUID(), matcher: .keyEquals(key: "band"),
                actions: [.stripPrefix(prefix: "The "), .assignCategory(category: "Band")]))

        #expect(result.itemsUpdated == 1)
        // "Beatles", not "The Beatles" — using the raw string would make
        // every prefix rule a no-op that still reported success.
        let names = try library.tags(of: item.id).flatMap(\.tags).map(\.name)
        #expect(names == ["Beatles"])
        _ = category
    }

    @Test func itemsUpdatedCountsDistinctItems() async throws {
        let (library, source, _) = try await makeLibrary()
        // One item carrying two values under the same key: two candidates,
        // one item.
        try await itemWithPairs(
            library, source, path: "a.mp4", [("band", "Miles Davis"), ("band", "Bill Evans")])

        let result = try library.applyAnalysisRule(
            RuleEngine.Rule(
                id: UUID(), matcher: .keyEquals(key: "band"),
                actions: [.assignCategory(category: "Band")]))
        #expect(result.itemsUpdated == 1)
    }

    @Test func anIgnoreRuleRecordsDecisionsAndWritesNoTags() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await itemWithPairs(
            library, source, path: "a.mp4", [("encoder", "Lavf58")])

        let result = try library.applyAnalysisRule(
            RuleEngine.Rule(id: UUID(), matcher: .keyEquals(key: "encoder"), actions: [.ignore]))
        #expect(result.candidatesIgnored == 1)
        #expect(result.itemsUpdated == 0)
        #expect(try library.tags(of: item.id).isEmpty)
        #expect(try library.tagCandidates().isEmpty)
    }

    @Test func aRuleNamingAnUnknownCategoryReportsRatherThanInventingOne() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await itemWithPairs(
            library, source, path: "a.mp4", [("venue", "Newport")])

        let result = try library.applyAnalysisRule(
            RuleEngine.Rule(
                id: UUID(), matcher: .keyEquals(key: "venue"),
                actions: [.assignCategory(category: "Venue")]))

        // A category is a deliberate object with an order and a colour.
        #expect(result.unknownCategories == ["Venue"])
        #expect(result.itemsUpdated == 0)
        #expect(try library.tags(of: item.id).isEmpty)
        // And the candidate is still there to be decided by hand.
        #expect(try library.tagCandidates().count == 1)
    }

    @Test func aRuleWithNoActionsWritesNothing() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await itemWithPairs(
            library, source, path: "a.mp4", [("band", "Miles Davis")])

        let result = try library.applyAnalysisRule(
            RuleEngine.Rule(id: UUID(), matcher: .keyEquals(key: "band"), actions: []))
        #expect(result == RuleApplication(
            itemsUpdated: 0, candidatesIgnored: 0, unknownCategories: []))
        #expect(try library.tags(of: item.id).isEmpty)
    }
}
