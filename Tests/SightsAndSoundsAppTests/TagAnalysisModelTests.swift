import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The companion's model follows the session it was given: a new item
/// on the session is a reload, results land back on the session, and
/// applying goes through the session's hook.
@Suite @MainActor struct TagAnalysisModelTests {

    private func makeSession() async throws -> (TagAnalysisSession, [MediaItem], TagCategory) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Companion")
        let source = Source(name: "S", rootPath: "/tmp/companion-\(UUID().uuidString)")
        let taper = TagCategory(name: "Taper")
        let items = ["show-with_MikeJones-a.mp4", "b.mp4"].map {
            MediaItem(sourceID: source.id, kind: .video, relativePath: $0, needsReview: false)
        }
        try await library.writer.write { db in
            try source.insert(db)
            try taper.insert(db)
            for item in items { try item.insert(db) }
            try Tag(tagCategoryID: taper.id, name: "Mike Jones").insert(db)
        }
        return (TagAnalysisSession(libraryID: UUID(), library: library), items, taper)
    }

    private func settle(_ model: TagAnalysisModel) async throws {
        for _ in 0..<400 where model.isLoading {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!model.isLoading)
    }

    @Test func aNewItemOnTheSessionReloadsAndPublishesTheAnalysis() async throws {
        let (session, items, _) = try await makeSession()
        let model = TagAnalysisModel(session: session)
        #expect(session.companionIsOpen)

        session.playerDidShow(itemID: items[0].id, position: (index: 0, count: 2))
        // Observation delivers on the next turn of the main actor.
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)

        #expect(model.currentItemID == items[0].id)
        #expect(model.positionText == "1 of 2")
        #expect(session.analysis.existing.contains { $0.tag.name == "Mike Jones" })
        #expect(!session.isAnalyzing)
    }

    @Test func applyingGoesThroughTheSessionHookAndCountsThePass() async throws {
        let (session, items, taper) = try await makeSession()
        var applied: [String] = []
        session.apply = { applied.append($0.name) }
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)

        let mike = try #require(session.analysis.existing.first?.tag)
        model.applyNow(mike)
        try await settle(model)
        model.applyNew(value: "New Person", categoryID: taper.id)
        try await settle(model)

        #expect(applied == ["Mike Jones", "New Person"])
        #expect(model.tagsAppliedThisPass == 2)
        let names = try session.library.vocabulary().flatMap(\.tags).map(\.name)
        #expect(names.contains("New Person"))
    }

    @Test func movingToAnotherItemCountsAVisitAndClearsTheSelection() async throws {
        let (session, items, _) = try await makeSession()
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        model.select(model.allRows.first?.id)
        model.searchText = "mike"

        session.playerDidShow(itemID: items[1].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)

        #expect(model.videosVisitedThisPass == 2)
        #expect(model.selectedCandidateID == nil)
        #expect(model.searchText == "")
        #expect(model.currentItemID == items[1].id)
    }

    @Test func closingClearsTheSessionsHalf() async throws {
        let (session, items, _) = try await makeSession()
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)

        model.close()
        #expect(!session.companionIsOpen)
        #expect(session.analysis == .empty)
    }
}
