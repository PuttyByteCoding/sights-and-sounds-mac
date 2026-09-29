import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The Rules tab's dry run walks the candidate queue. It ran on the main
/// actor once per keystroke; it now runs off it, and each edit cancels
/// the last run, so the answer on screen is always the newest draft's.
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
