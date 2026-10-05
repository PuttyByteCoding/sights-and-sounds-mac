import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// Tag Analysis, as asked of a library's service: one video's analysis
/// with what the window needs beside it, the rules, and the schemas.
@Suite struct AnalysisManagingTests {
    typealias Tag = SightsAndSoundsKit.Tag

    struct Fixture {
        let library: LibraryDatabase
        let service: LocalLibraryService
        let source: Source
        let taper = TagCategory(name: "Taper")
        let named: MediaItem
        let plain: MediaItem

        init() async throws {
            library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Analysis")
            service = LocalLibraryService(library: library)
            let source = Source(name: "S", rootPath: TestRoots.unreachable("analysis"))
            self.source = source
            named = MediaItem(
                sourceID: source.id, kind: .video, relativePath: "show-with_MikeJones-a.mp4", needsReview: false)
            plain = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", needsReview: false)
            try await library.writer.write { [taper, named, plain] db in
                try source.insert(db)
                try taper.insert(db)
                for item in [named, plain] { try item.insert(db) }
                try Tag(tagCategoryID: taper.id, name: "Mike Jones").insert(db)
            }
        }
    }

    private func rule(_ matcher: RuleMatcher, _ actions: [RuleAction] = []) -> RuleEngine.Rule {
        RuleEngine.Rule(id: UUID(), matcher: matcher, actions: actions)
    }

    @Test func oneVideosAnalysisComesWithItsRowItsRulesAndTheCategories() async throws {
        let f = try await Fixture()
        let ignore = rule(.valueStartsWith(prefix: "show"), [.ignore])
        try await f.service.saveAnalysisRule(ignore)

        let answer = try await f.service.itemAnalysis(itemID: f.named.id)
        #expect(answer.item?.id == f.named.id)
        #expect(answer.rules == [ignore])
        #expect(answer.categories.map(\.name) == ["Taper"])
        #expect(answer.analysis.existing.contains { $0.tag.name == "Mike Jones" })
        #expect(answer.analysis == (try f.library.analyzeItem(f.named.id, rules: [ignore])))

        // A video that has left the library is an empty answer, not an error.
        let gone = try await f.service.itemAnalysis(itemID: UUID())
        #expect(gone.item == nil && gone.analysis == .empty)
    }

    @Test func aVideoLookedAtIsStamped() async throws {
        let f = try await Fixture()
        try await f.service.markAnalyzed(itemID: f.named.id)
        let stamped = try await f.library.writer.read { try TagAnalysisState.fetchAll($0) }
        #expect(stamped.map(\.mediaItemID) == [f.named.id])
        #expect(stamped.first?.analyzerVersion == ItemAnalysis.analyzerVersion)
    }

    @Test func theSweepStateSaysWhatIsUnreadAndWhatIsWaiting() async throws {
        let f = try await Fixture()
        let before = try await f.service.metadataSweepState(itemID: f.named.id)
        #expect(before == ItemSweepState(isUnswept: true, waitingJob: nil))

        // Read once: no longer unswept. Reset: unswept again.
        try f.library.recordMetadataPairs(itemID: f.named.id, pairs: [(name: "artist", value: "Alpha")])
        let direct = try f.library.unsweptCount(in: [f.named.id]) > 0
        #expect(try await f.service.metadataSweepState(itemID: f.named.id).isUnswept == direct)
        try await f.service.resetMetadataSweep(itemIDs: [f.named.id])
        #expect(try await f.service.metadataSweepState(itemID: f.named.id).isUnswept)
        #expect(try f.library.unsweptCount(in: [f.named.id]) == 1)
    }

    @Test func tagsNamedInLinesOfTextAreFound() async throws {
        let f = try await Fixture()
        try f.library.addAlias("Jonesy", toTag: try #require(try f.library.vocabulary().flatMap(\.tags).first).id)
        let lines = ["recorded by Mike Jones", "nothing here", "thanks Jonesy and Mike Jones"]
        let found = try await f.service.existingTags(inLines: lines)
        #expect(found == (try f.library.existingTags(inLines: lines)))
        // One finding per tag, in the first line that names it.
        #expect(found.map(\.tag.name) == ["Mike Jones"])
        #expect(found.first?.foundIn == "recorded by Mike Jones")
        #expect(try await f.service.existingTags(inLines: ["thanks Jonesy"]).first?.matchedText == "Jonesy")
        #expect(try await f.service.existingTags(inLines: []).isEmpty)
    }

    @Test func rulesAreKeptInOrderAndFoundByWhatTheyCover() async throws {
        let f = try await Fixture()
        let first = rule(.keyEquals(key: "artist"), [.assignCategory(category: "Taper")])
        let second = rule(.valueStartsWith(prefix: "The "), [.stripPrefix(prefix: "The ")])
        try await f.service.saveAnalysisRule(first)
        try await f.service.saveAnalysisRule(second)
        #expect(try await f.service.analysisRules() == [first, second])

        try await f.service.moveAnalysisRule(id: second.id, up: true)
        #expect(try await f.service.analysisRules().map(\.id) == [second.id, first.id])

        #expect(try await f.service.ruleCovering(key: "artist", value: "Alpha")?.id == first.id)
        #expect(try await f.service.ruleCovering(key: nil, value: "The Band")?.id == second.id)
        #expect(try await f.service.ruleCovering(key: nil, value: "nothing") == nil)

        try await f.service.deleteAnalysisRule(id: second.id)
        #expect(try await f.service.analysisRules() == [first])
    }

    @Test func aDryRunCountsAndApplyingWrites() async throws {
        let f = try await Fixture()
        try f.library.recordMetadataPairs(itemID: f.named.id, pairs: [(name: "artist", value: "Alpha")])
        try f.library.recordMetadataPairs(itemID: f.plain.id, pairs: [(name: "artist", value: "Beta")])
        let assign = rule(.keyEquals(key: "artist"), [.assignCategory(category: "Taper")])
        let other = rule(.keyEquals(key: "venue"), [.ignore])

        // A draft, never saved, is answered as a saved one would be.
        let run = try await f.service.dryRun(of: assign)
        #expect(run == (try f.library.dryRun(assign)))
        #expect(run.matchedCandidates == 2 && run.affectedItems == 2 && run.actionCount == 1)
        let runs = try await f.service.dryRuns(of: [assign, other])
        #expect(runs[assign.id] == run)
        #expect(runs[other.id]?.isEmpty == true)

        let applied = try await f.service.applyAnalysisRule(assign)
        #expect(applied.itemsUpdated == 2 && applied.unknownCategories.isEmpty)
        let names = try f.library.vocabulary().flatMap(\.tags).map(\.name).sorted()
        #expect(names == ["Alpha", "Beta", "Mike Jones"])
    }

    @Test func schemasAreSavedRenamedAndDeleted() async throws {
        let f = try await Fixture()
        let saved = try await f.service.saveJsonSchema(id: nil, named: "Notes", keys: [SchemaKey(key: "venue")])
        // (Not the whole row: its date is kept to the millisecond.)
        let listed = try await f.service.jsonSchemas()
        #expect(listed.map(\.id) == [saved.id] && listed.first?.keys == [SchemaKey(key: "venue")])

        let renamed = try await f.service.saveJsonSchema(
            id: saved.id, named: "Show Notes", keys: [SchemaKey(key: "venue"), SchemaKey(key: "city")])
        #expect(renamed.id == saved.id)
        let after = try await f.service.jsonSchemas()
        #expect(after.map(\.name) == ["Show Notes"] && after.first?.keys.map(\.key) == ["venue", "city"])

        try await f.service.deleteJsonSchema(id: saved.id)
        #expect(try await f.service.jsonSchemas().isEmpty)
    }

    /// What crosses to another Mac is the stored form of a rule, so a
    /// matcher or action this build does not know survives the trip.
    @Test func aRuleAndAnAnalysisSurviveBeingSent() async throws {
        let f = try await Fixture()
        let rules = [
            rule(.keyEquals(key: "artist"), [.assignCategory(category: "Taper"), .onlyIfTrue]),
            rule(.valueStartsWith(prefix: "The "), [.stripPrefix(prefix: "The "), .setKind(kind: "tag")]),
            rule(.numericRange(min: 1900, max: 2100), [.ignore]),
            rule(.pathRootStartsWith(root: "Shows"), [.hidePrefix]),
            rule(.unknown(type: "fromALaterBuild"), [.unknown(type: "alsoLater")]),
        ]
        let sent = try JSONDecoder().decode([RuleEngine.Rule].self, from: JSONEncoder().encode(rules))
        #expect(sent == rules)

        let answer = try await f.service.itemAnalysis(itemID: f.named.id)
        #expect(!answer.analysis.readerReports.isEmpty)
        let back = try JSONDecoder().decode(ItemAnalysisAnswer.self, from: JSONEncoder().encode(answer))
        #expect(back == answer)
    }
}
