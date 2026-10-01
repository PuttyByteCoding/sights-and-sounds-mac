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

    /// "Waiting — tasks are paused" is for a scan waiting on its own job.
    /// Every reload sets `isLoading` too, for analysis that never touches
    /// the queue; keyed on that, a paused queue flashed the message on each
    /// item change and decision.
    @Test func onlyAScanCountsAsWaitingOnAJob() async throws {
        let (session, items, _) = try await makeSession()
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.isWaitingOnJob, "an ordinary reload counted as waiting on a job")
        try await settle(model)

        model.beginSweep(for: items[0].id)
        #expect(model.isWaitingOnJob)
        model.finishSweep(for: items[0].id)
        #expect(!model.isWaitingOnJob)
        try await settle(model)
    }

    /// A reload ends by clearing `isLoading`, and opening the companion or
    /// walking to the next video reloads at the same moment as the
    /// automatic sweep begins: the wait was hidden, the header showed the
    /// unswept counts and Rescan came back on, mid-sweep. And one flag
    /// could not hold two sweeps: the first to finish cleared it for both.
    @Test func aWaitOutlastsReloadsAndCountsEachSweep() async throws {
        let (session, items, _) = try await makeSession()
        let model = TagAnalysisModel(session: session)
        model.beginSweep(for: items[0].id)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        #expect(model.isWaitingOnJob, "a reload ended the wait for a sweep still queued")

        model.beginSweep(for: items[0].id)
        model.finishSweep(for: items[0].id)
        #expect(model.isWaitingOnJob, "the first sweep to finish ended the wait for both")
        model.finishSweep(for: items[0].id)
        #expect(!model.isWaitingOnJob)
        try await settle(model)
    }

    /// A wait is the video's it was begun for. Counted for the window, a
    /// minutes-long OCR scan of one video held every video walked to after
    /// it on "scanning…", with both scan buttons off.
    @Test func aWaitBelongsToItsVideo() async throws {
        let (session, items, _) = try await makeSession()
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        model.beginSweep(for: items[0].id)

        session.playerDidShow(itemID: items[1].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        #expect(!model.isWaitingOnJob, "another video's scan held this one")

        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        #expect(model.isWaitingOnJob, "back on the video, its scan is still waiting")
        model.finishSweep(for: items[0].id)
        try await settle(model)
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
