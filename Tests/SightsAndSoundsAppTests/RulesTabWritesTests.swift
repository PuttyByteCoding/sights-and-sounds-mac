import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The Rules tab's writes are requests that take their time. Order is
/// the engine, so two pressed one after the other must land that way
/// round even when the first is slow to be answered.
@Suite @MainActor struct RulesTabWritesTests {
    private func rule(_ key: String) -> RuleEngine.Rule {
        RuleEngine.Rule(id: UUID(), matcher: .keyEquals(key: key), actions: [])
    }

    @Test func twoMovesLandInTheOrderTheyWerePressed() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Rules")
        let a = rule("a"), b = rule("b"), c = rule("c")
        for one in [a, b, c] { try library.saveAnalysisRule(one) }
        let stub = StubLibraryService(LocalLibraryService(library: library))
        let model = RulesTabModel(service: stub)
        await model.reload()
        #expect(model.rules.map(\.id) == [a.id, b.id, c.id])

        // The first move is slow to be answered; the second is pressed
        // meanwhile. c up then a down is c, a, b; the other way round
        // is b, c, a.
        stub.delay("moveAnalysisRule(id:up:)", by: .milliseconds(300))
        let first = Task { await model.move(c, up: true) }
        let second = Task { await model.move(a, up: false) }
        await first.value
        await second.value

        #expect(try library.analysisRules().map(\.id) == [c.id, a.id, b.id])
        #expect(model.rules.map(\.id) == [c.id, a.id, b.id])
        #expect(model.loadError == nil)
    }

    @Test func aWriteThatFailsIsSaidAndTheListStays() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Rules")
        let a = rule("a")
        try library.saveAnalysisRule(a)
        let stub = StubLibraryService(LocalLibraryService(library: library))
        let model = RulesTabModel(service: stub)
        await model.reload()

        stub.fail("deleteAnalysisRule(id:)")
        await model.delete(a)
        #expect(model.loadError != nil)
        #expect(model.rules.map(\.id) == [a.id])
        #expect(try library.analysisRules().count == 1)
    }
}
