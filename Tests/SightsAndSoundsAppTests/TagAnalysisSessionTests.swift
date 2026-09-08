import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The handshake between a player and its companion: what each side
/// writes, and when the session is finished with.
@Suite @MainActor struct TagAnalysisSessionTests {

    private func makeSession() throws -> TagAnalysisSession {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Session")
        return TagAnalysisSession(libraryID: UUID(), library: library)
    }

    @Test func aFreshSessionHasAnOpenPlayerAndNoCompanion() throws {
        let session = try makeSession()
        #expect(session.playerIsOpen)
        #expect(!session.companionIsOpen)
        #expect(session.itemID == nil)
        #expect(session.analysis == .empty)
        #expect(!session.isAnalyzing)
        #expect(!session.isFinished)
    }

    @Test func thePlayerWritesTheItemAndPosition() throws {
        let session = try makeSession()
        let id = UUID()
        session.playerDidShow(itemID: id, position: (index: 2, count: 41))
        #expect(session.itemID == id)
        #expect(session.position?.index == 2)
        #expect(session.position?.count == 41)
    }

    @Test func theCompanionWritesTheAnalysisAndTheInFlightFlag() throws {
        let session = try makeSession()
        session.companionDidOpen()
        #expect(session.companionIsOpen)
        session.companionWillReload()
        #expect(session.isAnalyzing)
        let analysis = ItemAnalysis(
            suggested: [], existing: [], unmapped: [], md5s: [], matchedSchemas: [],
            readerReports: [], truncated: true, provenance: [])
        session.companionDidReload(analysis)
        #expect(!session.isAnalyzing)
        #expect(session.analysis.truncated)
    }

    @Test func closingTheCompanionClearsItsHalf() throws {
        let session = try makeSession()
        session.companionDidOpen()
        session.companionWillReload()
        session.companionDidClose()
        #expect(!session.companionIsOpen)
        #expect(!session.isAnalyzing)
        #expect(session.analysis == .empty)
        #expect(!session.isFinished)  // the player is still up
    }

    @Test func theSessionIsFinishedOnlyWhenBothSidesHaveClosed() throws {
        let session = try makeSession()
        session.companionDidOpen()
        session.playerDidClose()
        #expect(!session.playerIsOpen)
        #expect(!session.isFinished)
        session.companionDidClose()
        #expect(session.isFinished)
    }

    @Test func theRegistryHandsBackTheSameSessionAndReleasesAFinishedOne() throws {
        let app = AppModel()
        let session = try makeSession()
        app.registerAnalysisSession(session)
        #expect(app.analysisSession(for: session.id) === session)
        app.releaseAnalysisSessionIfFinished(session.id)
        #expect(app.analysisSession(for: session.id) === session)  // still open
        session.playerDidClose()
        session.companionDidClose()
        app.releaseAnalysisSessionIfFinished(session.id)
        #expect(app.analysisSession(for: session.id) == nil)
    }
}
