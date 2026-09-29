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

    /// Walks that wait at a gate the test opens, so an edit is made
    /// while a walk is certainly still running, however loaded the
    /// machine. Once opened the gate stays open.
    final class GatedWalks: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var isOpen = false
        private var running = 0
        private var counts = (started: 0, finished: 0, mostAtOnce: 0)

        var started: Int { lock.withLock { counts.started } }
        var finished: Int { lock.withLock { counts.finished } }
        var mostAtOnce: Int { lock.withLock { counts.mostAtOnce } }

        func open() {
            lock.withLock { isOpen = true }
            gate.signal()
        }

        func walk(_ library: LibraryDatabase, _ rule: RuleEngine.Rule) throws -> RuleDryRun {
            let wait = lock.withLock {
                running += 1
                counts.started += 1
                counts.mostAtOnce = max(counts.mostAtOnce, running)
                return !isOpen
            }
            if wait {
                _ = gate.wait(timeout: .now() + 10)   // never strand a pool thread
                gate.signal()   // let any later walk through too
            }
            defer { lock.withLock { running -= 1; counts.finished += 1 } }
            return try library.dryRun(rule)
        }
    }

    /// A model whose new rule's first answer has landed, whose later walks
    /// wait at a gate, and whose rule is re-shown with its answer cleared
    /// and a gated walk under way.
    private func modelWithAGatedWalk() async throws -> (RulesTabModel, GatedWalks) {
        let model = try model()
        try await waitUntil { model.dryRun != nil }
        let rule = try #require(model.draft)
        let walks = GatedWalks()
        model.walkDryRun = walks.walk
        model.selectedID = nil
        model.draft = nil
        model.refreshDryRun()
        #expect(model.dryRun == nil)
        model.selectedID = rule.id
        model.draft = rule
        model.refreshDryRun()
        try await waitUntil { walks.started == 1 }
        return (model, walks)
    }

    private func addAnAction(_ model: RulesTabModel) {
        model.updateDraft { $0 = RuleEngine.Rule(id: $0.id, matcher: $0.matcher, actions: $0.actions + [.ignore]) }
    }

    /// Edits whose settle ends while a walk runs never start a second
    /// walk beside it, and the answer ends on the newest draft.
    @Test func aRunningWalkIsNeverJoinedByASecond() async throws {
        let (model, walks) = try await modelWithAGatedWalk()
        for _ in 0..<3 {
            addAnAction(model)
            try await Task.sleep(for: .milliseconds(200))   // past the settle
        }
        #expect(walks.started == 1, "an edit started a walk beside the running one")
        walks.open()
        try await waitUntil { model.dryRun?.actionCount == 3 }
        #expect(walks.mostAtOnce == 1)
        #expect(walks.started == 2, "one more walk, for the newest draft")
    }

    /// Clearing the subject while a walk runs: the walk's answer is for a
    /// rule no longer on screen, so it must not land.
    @Test func aWalkForARuleNoLongerShownDoesNotLand() async throws {
        let (model, walks) = try await modelWithAGatedWalk()
        model.selectedID = nil
        model.draft = nil
        model.refreshDryRun()
        walks.open()
        try await waitUntil { walks.finished == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.dryRun == nil)
    }

    /// An edit still settling when a walk ends: the older draft's answer
    /// must not show in the meantime.
    @Test func anAnswerForAnOlderDraftDoesNotLand() async throws {
        let (model, walks) = try await modelWithAGatedWalk()
        addAnAction(model)
        walks.open()
        try await waitUntil { model.dryRun != nil }
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
