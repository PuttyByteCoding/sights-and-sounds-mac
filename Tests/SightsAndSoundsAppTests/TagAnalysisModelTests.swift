import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The companion's model follows the session it was given: a new item
/// on the session is a reload, results land back on the session, and
/// applying goes through the session's hook.
@Suite @MainActor struct TagAnalysisModelTests {

    private func makeSession() async throws -> (TagAnalysisSession, [MediaItem], TagCategory) {
        let (session, items, taper, _) = try await makeSessionAndLibrary()
        return (session, items, taper)
    }

    private func makeSessionAndLibrary() async throws -> (
        TagAnalysisSession, [MediaItem], TagCategory, LibraryDatabase
    ) {
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
        let session = TagAnalysisSession(libraryID: UUID(), service: LocalLibraryService(library: library))
        return (session, items, taper, library)
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
        let (session, items, taper, library) = try await makeSessionAndLibrary()
        var applied: [String] = []
        session.apply = { tag, done in
            applied.append(tag.name)
            done()
        }
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)

        let mike = try #require(session.analysis.existing.first?.tag)
        model.applyNow(mike)
        try await settle(model)
        await model.applyNew(value: "New Person", categoryID: taper.id)
        try await settle(model)

        #expect(applied == ["Mike Jones", "New Person"])
        #expect(model.tagsAppliedThisPass == 2)
        let names = try library.vocabulary().flatMap(\.tags).map(\.name)
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

    /// The automatic metadata sweep is held back only by a metadata sweep
    /// of that video still waiting. A text scan held it back too, and when
    /// a tag write cleared the video's sweep mid-scan, nothing asked for
    /// the sweep again: the tags from before the write stayed on screen.
    @Test func aTextScanDoesNotHoldBackTheMetadataSweep() async throws {
        let (session, items, _) = try await makeSession()
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)

        model.beginSweep(for: items[0].id, .textScan)
        #expect(model.isWaitingOnJob, "the header and buttons still show the scan")
        #expect(!model.isWaitingOnMetadataSweep, "a text scan held back the metadata sweep")
        model.beginSweep(for: items[0].id, .metadataSweep)
        #expect(model.isWaitingOnMetadataSweep)
        model.finishSweep(for: items[0].id, .metadataSweep)
        #expect(!model.isWaitingOnMetadataSweep)
        #expect(model.isWaitingOnJob, "the text scan is still waiting")
        model.finishSweep(for: items[0].id, .textScan)
        #expect(!model.isWaitingOnJob)
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

    // MARK: - Through the service

    private func makeStubbedSession() async throws -> (
        TagAnalysisSession, StubLibraryService, [MediaItem], TagCategory, LibraryDatabase
    ) {
        let (_, items, taper, library) = try await makeSessionAndLibrary()
        let stub = StubLibraryService(LocalLibraryService(library: library))
        // As for a library another Mac holds: nothing here may reach
        // for a file.
        stub.filesAreOnThisMac = false
        return (TagAnalysisSession(libraryID: UUID(), service: stub), stub, items, taper, library)
    }

    /// Everything the companion shows and writes is asked of the
    /// library's service, so it is the same for a library on another Mac.
    @Test func theCompanionAsksTheServiceForEverything() async throws {
        let (session, stub, items, taper, library) = try await makeStubbedSession()
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        #expect(stub.calls("itemAnalysis(itemID:)") == 1)
        #expect(model.currentItem?.id == items[0].id)
        #expect(model.categories.map(\.name) == ["Taper"])
        #expect(model.analysis.existing.contains { $0.tag.name == "Mike Jones" })

        await model.applyNew(value: "New Person", categoryID: taper.id)
        try await settle(model)
        #expect(stub.calls("ensureTag(named:inCategory:)") == 1)
        let candidate = try #require(model.allRows.first?.candidate)
        await model.ignoreRule(for: candidate)
        try await settle(model)
        #expect(try library.analysisRules().map(\.actions) == [[.ignore]])
        #expect(model.rules.count == 1, "the analysis was not read again under the new rule")

        // Walking on stamps the video left behind.
        session.playerDidShow(itemID: items[1].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        for _ in 0..<200 where stub.answered("markAnalyzed(itemID:)") == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let stamped = try await library.writer.read { try TagAnalysisState.fetchAll($0) }
        #expect(stamped.map(\.mediaItemID) == [items[0].id])
        #expect(model.loadError == nil)
    }

    /// Two readings of one video can be answered out of order — more so
    /// from another Mac. The older answer, arriving last, used to be the
    /// one left on screen.
    @Test func anOlderAnswerArrivingLastDoesNotLand() async throws {
        let (session, stub, items, taper, library) = try await makeStubbedSession()
        let model = TagAnalysisModel(session: session)
        // The first reading is made at once and its answer held back.
        stub.holdAnswer("itemAnalysis(itemID:)", by: .milliseconds(600))
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<200 where stub.calls("itemAnalysis(itemID:)") == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        // The library changes, and a second reading sees it.
        try await library.writer.write { try Tag(tagCategoryID: taper.id, name: "show").insert($0) }
        model.reload()
        for _ in 0..<200 where !model.analysis.existing.contains(where: { $0.tag.name == "show" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.analysis.existing.contains { $0.tag.name == "show" })
        // The first reading's answer arrives now, and is not shown.
        try await Task.sleep(for: .milliseconds(800))
        #expect(model.analysis.existing.contains { $0.tag.name == "show" }, "the older answer replaced the newer")
        #expect(session.analysis == model.analysis)
        #expect(!model.isLoading)
    }

    /// Applying is the player's write, and reading the video again is
    /// another request: sent side by side, the reading could get in
    /// first and show the row still Undecided. It waits to be told the
    /// write has landed.
    @Test func theVideoIsReadAgainOnlyOnceTheTagHasLanded() async throws {
        let (session, stub, items, _, _) = try await makeStubbedSession()
        var landed: [@MainActor () -> Void] = []
        session.apply = { _, done in landed.append(done) }
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        let readings = stub.calls("itemAnalysis(itemID:)")

        let mike = try #require(session.analysis.existing.first?.tag)
        model.applyNow(mike)
        try await Task.sleep(for: .milliseconds(150))
        #expect(stub.calls("itemAnalysis(itemID:)") == readings, "read again before the write had landed")
        #expect(model.tagsAppliedThisPass == 1)

        try #require(landed.count == 1)
        landed[0]()
        try await settle(model)
        #expect(stub.calls("itemAnalysis(itemID:)") == readings + 1)
    }

    @Test func aReadingThatFailsSaysSoAndStopsWaiting() async throws {
        let (session, stub, items, _, _) = try await makeStubbedSession()
        stub.fail("itemAnalysis(itemID:)")
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        #expect(model.loadError != nil)
        #expect(session.analysis == .empty && !session.isAnalyzing)
    }

    /// Whether a video needs its sweep is asked of the service, which
    /// takes a moment: one question at a time per video, or walking away
    /// and back in that moment queued the sweep twice.
    @Test func aVideoIsAskedAboutOnceAtATime() async throws {
        let (session, _, items, _, _) = try await makeStubbedSession()
        let model = TagAnalysisModel(session: session)
        #expect(model.beginSweepQuestion(for: items[0].id))
        #expect(!model.beginSweepQuestion(for: items[0].id))
        #expect(model.beginSweepQuestion(for: items[1].id), "another video is its own question")
        model.endSweepQuestion(for: items[0].id)
        #expect(model.beginSweepQuestion(for: items[0].id))
    }
}
