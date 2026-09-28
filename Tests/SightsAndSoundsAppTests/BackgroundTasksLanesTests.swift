import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The Background Tasks window polls once a second. It must read only
/// libraries something already opened: it used to open every registered
/// library on each tick — on the main actor, retrying a missing drive
/// every second, and building job runners (which can start queued work)
/// for libraries nobody had opened.
@Suite @MainActor struct BackgroundTasksLanesTests {
    private func register(_ app: AppModel, _ name: String) throws -> LibraryRef {
        let url = AppSettingsStore.testScratch
            .appendingPathComponent("lanes-\(UUID().uuidString).sqlite")
        let library = try LibraryDatabase.open(at: url)
        try library.ensureInfo(name: name)
        let ref = try #require(app.appDatabase).register(library)
        try library.close()
        return ref
    }

    @Test func onlyOpenLibrariesGetALaneAndNothingElseIsOpened() async throws {
        let app = AppModel()
        let open = try register(app, "Open")
        let shut = try register(app, "Shut")
        app.refresh()
        _ = try app.library(for: open.id)

        let lanes = await BackgroundTasksView.lanes(of: app)

        #expect(lanes.map(\.id).contains(open.id))
        #expect(!lanes.map(\.id).contains(shut.id))
        #expect(app.openLibrary(for: shut.id) == nil)
    }
}
