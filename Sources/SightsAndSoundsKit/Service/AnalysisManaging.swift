import Foundation
import GRDB

/// Tag Analysis: what one video's evidence says, the rules that sort
/// it, and the JSON shapes the library knows. The reading is done where
/// the files are; a window on another Mac is given what was found.
public protocol AnalysisManaging: Sendable {
    // MARK: One video

    /// Every reader over one video, the rules over what they read, and
    /// what the window needs beside it — as one answer.
    func itemAnalysis(itemID: UUID) async throws -> ItemAnalysisAnswer

    /// The video has been looked at, under this build's analyzer.
    func markAnalyzed(itemID: UUID) async throws

    /// Whether the video's embedded metadata has still to be read, and
    /// the sweep already waiting to read it.
    func metadataSweepState(itemID: UUID) async throws -> ItemSweepState

    /// Forget that these videos' metadata was read, so the next sweep
    /// reads it again.
    func resetMetadataSweep(itemIDs: [UUID]) async throws

    // MARK: Rules

    /// The rules, in the order they are applied.
    func analysisRules() async throws -> [RuleEngine.Rule]
    func saveAnalysisRule(_ rule: RuleEngine.Rule) async throws
    func deleteAnalysisRule(id: UUID) async throws
    func moveAnalysisRule(id: UUID, up: Bool) async throws

    /// The first rule that already fires on this string, if any.
    func ruleCovering(key: String?, value: String) async throws -> RuleEngine.Rule?

    /// What a rule would match, without writing anything. It need not
    /// be a saved rule: the editor asks about its draft.
    func dryRun(of rule: RuleEngine.Rule) async throws -> RuleDryRun

    /// Several rules' dry runs over one reading of the candidates.
    func dryRuns(of rules: [RuleEngine.Rule]) async throws -> [UUID: RuleDryRun]

    /// Carry out one rule over the whole library.
    func applyAnalysisRule(_ rule: RuleEngine.Rule) async throws -> RuleApplication

    // MARK: Schemas

    func jsonSchemas() async throws -> [JsonSchemaDefinition]

    /// Save a schema: the one with this id under a new name or new keys,
    /// or a new one when `id` is nil.
    func saveJsonSchema(id: UUID?, named name: String, keys: [SchemaKey]) async throws -> JsonSchemaDefinition
    func deleteJsonSchema(id: UUID) async throws
}

/// One video's analysis, with the rules it was run under and what the
/// window names things by.
public struct ItemAnalysisAnswer: Codable, Equatable, Sendable {
    /// The video's row; nil when it has left the library.
    public var item: MediaItem?
    public var rules: [RuleEngine.Rule]
    public var categories: [TagCategory]
    public var analysis: ItemAnalysis

    public init(item: MediaItem?, rules: [RuleEngine.Rule], categories: [TagCategory], analysis: ItemAnalysis) {
        self.item = item
        self.rules = rules
        self.categories = categories
        self.analysis = analysis
    }
}

public struct ItemSweepState: Codable, Equatable, Sendable {
    /// The video's embedded metadata has not been read.
    public var isUnswept: Bool
    /// A sweep of it already in the queue.
    public var waitingJob: UUID?

    public init(isUnswept: Bool, waitingJob: UUID?) {
        self.isUnswept = isUnswept
        self.waitingJob = waitingJob
    }
}

// MARK: - On this Mac

extension LocalLibraryService {
    public func itemAnalysis(itemID: UUID) async throws -> ItemAnalysisAnswer {
        let rules = try library.analysisRules()
        let categories = try library.vocabulary().map(\.category)
        let analysis = try library.analyzeItem(itemID, rules: rules, fileAccess: fileAccess)
        let item = try await library.writer.read { try MediaItem.fetchOne($0, key: itemID) }
        return ItemAnalysisAnswer(item: item, rules: rules, categories: categories, analysis: analysis)
    }

    public func markAnalyzed(itemID: UUID) async throws {
        try library.markAnalyzed(itemID)
    }

    public func metadataSweepState(itemID: UUID) async throws -> ItemSweepState {
        ItemSweepState(
            isUnswept: try library.unsweptCount(in: [itemID]) > 0,
            waitingJob: try library.pendingMetadataSweep(of: itemID))
    }

    public func resetMetadataSweep(itemIDs: [UUID]) async throws {
        try library.resetMetadataSweep(itemIDs: itemIDs)
    }

    public func analysisRules() async throws -> [RuleEngine.Rule] {
        try library.analysisRules()
    }

    public func saveAnalysisRule(_ rule: RuleEngine.Rule) async throws {
        try library.saveAnalysisRule(rule)
    }

    public func deleteAnalysisRule(id: UUID) async throws {
        try library.deleteAnalysisRule(id)
    }

    public func moveAnalysisRule(id: UUID, up: Bool) async throws {
        try library.moveAnalysisRule(id, up: up)
    }

    public func ruleCovering(key: String?, value: String) async throws -> RuleEngine.Rule? {
        try library.ruleCovering(key: key, value: value)
    }

    public func dryRun(of rule: RuleEngine.Rule) async throws -> RuleDryRun {
        try library.dryRun(rule)
    }

    public func dryRuns(of rules: [RuleEngine.Rule]) async throws -> [UUID: RuleDryRun] {
        try library.dryRuns(for: rules)
    }

    public func applyAnalysisRule(_ rule: RuleEngine.Rule) async throws -> RuleApplication {
        try library.applyAnalysisRule(rule)
    }

    public func jsonSchemas() async throws -> [JsonSchemaDefinition] {
        try library.jsonSchemas()
    }

    public func saveJsonSchema(
        id: UUID?, named name: String, keys: [SchemaKey]
    ) async throws -> JsonSchemaDefinition {
        try library.saveJsonSchema(id: id, named: name, keys: keys)
    }

    public func deleteJsonSchema(id: UUID) async throws {
        try library.deleteJsonSchema(id)
    }
}
