import Foundation
@testable import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The app's runner for a library handles every job the Kit can queue —
/// including a repair queued in an earlier session.
@Suite @MainActor struct RunnerJobTypesTests {
    @Test func theLibraryRunnerHandlesEveryCataloguedKind() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-runner-kinds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LibraryDatabase.open(at: folder.appendingPathComponent("L.sqlite"))
        try library.ensureInfo(name: "Kinds")
        let app = AppModel()
        let ref = try #require(app.appDatabase).register(library)
        app.refresh()
        let runner = try app.runner(for: ref.id)
        for type in JobCatalog.all {
            #expect(await runner.handles(kind: type.kind), "\(type.kind)")
        }
    }
}
