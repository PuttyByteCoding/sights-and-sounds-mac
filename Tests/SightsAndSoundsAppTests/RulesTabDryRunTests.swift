import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The Rules tab's dry run walks the candidate queue. It ran on the main
/// actor once per keystroke; it now runs off it, one walk at a time, and
/// only an answer for the draft still on screen lands.
@Suite @MainActor struct RulesTabDryRunTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    private func model() throws -> RulesTabModel {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Rules")
        let model = RulesTabModel(library: library)
        model.addRule()
        return model
    }

    @Test func theDryRunAnswersForTheNewestDraft() async throws {
        let model = try model()
        for _ in 0..<3 {
            model.updateDraft { $0 = RuleEngine.Rule(id: $0.id, matcher: $0.matcher, actions: $0.actions + [.ignore]) }
        }
        try await waitUntil { model.dryRun?.actionCount == 3 }
        // Nothing older lands afterwards.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.dryRun?.actionCount == 3)
    }

    /// Edits further apart than the settle each start a walk. The walk
    /// cannot be stopped, so a later edit must not start a second one
    /// beside it, and the answer on screen must still end on the newest
    /// draft.
    @Test func editsSlowerThanTheSettleEndOnTheNewestDraft() async throws {
        let model = try model()
        for _ in 0..<3 {
            model.updateDraft { $0 = RuleEngine.Rule(id: $0.id, matcher: $0.matcher, actions: $0.actions + [.ignore]) }
            try await Task.sleep(for: .milliseconds(250))
        }
        try await waitUntil { model.dryRun?.actionCount == 3 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.dryRun?.actionCount == 3)
    }

    /// Counts walks in flight and holds each one long enough for the
    /// next edit to arrive while it runs.
    final class SlowWalks: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var mostAtOnce = 0
        private(set) var total = 0

        func walk(_ library: LibraryDatabase, _ rule: RuleEngine.Rule) throws -> RuleDryRun {
            lock.withLock { running += 1; total += 1; mostAtOnce = max(mostAtOnce, running) }
            defer { lock.withLock { running -= 1 } }
            Thread.sleep(forTimeInterval: 0.4)
            return try library.dryRun(rule)
        }
    }

    /// Edits arriving while a slow walk runs never start a second walk
    /// beside it, and the answer ends on the newest draft.
    @Test func aSlowWalkIsNeverJoinedByASecond() async throws {
        let model = try model()
        let walks = SlowWalks()
        model.walkDryRun = walks.walk
        for _ in 0..<3 {
            model.updateDraft { $0 = RuleEngine.Rule(id: $0.id, matcher: $0.matcher, actions: $0.actions + [.ignore]) }
            try await Task.sleep(for: .milliseconds(250))
        }
        try await waitUntil { model.dryRun?.actionCount == 3 }
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.dryRun?.actionCount == 3)
        #expect(walks.mostAtOnce == 1)
    }

    /// A model whose new rule's first (fast) answer has landed and whose
    /// later walks are slow; the answer on screen is cleared.
    private func modelWithSlowWalks() async throws -> (RulesTabModel, SlowWalks, RuleEngine.Rule) {
        let model = try model()
        try await waitUntil { model.dryRun != nil }
        let rule = try #require(model.draft)
        let walks = SlowWalks()
        model.walkDryRun = walks.walk
        model.selectedID = nil
        model.draft = nil
        model.refreshDryRun()
        #expect(model.dryRun == nil)
        return (model, walks, rule)
    }

    /// Clearing the subject while a walk runs: the walk's answer is for a
    /// rule no longer on screen, so it must not land.
    @Test func aWalkForARuleNoLongerShownDoesNotLand() async throws {
        let (model, walks, rule) = try await modelWithSlowWalks()
        model.selectedID = rule.id
        model.draft = rule
        model.refreshDryRun()
        try await waitUntil { walks.total == 1 }
        model.selectedID = nil
        model.draft = nil
        model.refreshDryRun()
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.dryRun == nil)
    }

    /// An edit still settling when a walk ends: the older draft's answer
    /// must not show in the meantime.
    @Test func anAnswerForAnOlderDraftDoesNotLand() async throws {
        let (model, walks, rule) = try await modelWithSlowWalks()
        model.selectedID = rule.id
        model.draft = rule
        model.refreshDryRun()
        try await waitUntil { walks.total == 1 }
        // The walk ends ~400 ms after it began; this edit settles 150 ms
        // after it is made, so after the walk has ended.
        try await Task.sleep(for: .milliseconds(300))
        model.updateDraft { $0 = RuleEngine.Rule(id: $0.id, matcher: $0.matcher, actions: $0.actions + [.ignore]) }
        for _ in 0..<150 where model.dryRun == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.dryRun?.actionCount == 1, "the first answer to land was for the older draft")
    }

    @Test func applyRunsAndReportsWithoutBlocking() async throws {
        let model = try model()
        model.updateDraft { $0 = RuleEngine.Rule(id: $0.id, matcher: .keyEquals(key: "artist"), actions: [.ignore]) }
        model.saveDraft()
        model.applySelected()
        #expect(model.isApplying)
        try await waitUntil { !model.isApplying && model.lastApplied != nil }
        #expect(model.loadError == nil)
    }
}
