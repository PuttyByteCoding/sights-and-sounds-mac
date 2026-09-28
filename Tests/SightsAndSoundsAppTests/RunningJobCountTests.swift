import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Quitting while background tasks run asks first. The count it asks
/// about is jobs running in a library whose runner exists this session;
/// a row left "running" by a crash in a library nothing has opened is
/// not running, and must not hold up a quit.
@Suite @MainActor struct RunningJobCountTests {
    private func registered(_ app: AppModel, _ name: String) throws -> LibraryRef {
        let url = AppSettingsStore.testScratch.appendingPathComponent("running-\(UUID().uuidString).sqlite")
        let library = try LibraryDatabase.open(at: url)
        try library.ensureInfo(name: name)
        let ref = try #require(app.appDatabase).register(library)
        try library.close()
        app.refresh()
        return ref
    }

    private func insertJob(_ library: LibraryDatabase, _ state: JobState) throws {
        var job = JobRecord(kind: "test.job")
        job.state = state
        try library.writer.write { try job.insert($0) }
    }

    @Test func onlyJobsInLibrariesWithARunnerCount() throws {
        let app = AppModel()
        let live = try registered(app, "Live")
        let idle = try registered(app, "Idle")
        #expect(app.runningJobCount() == 0)

        let library = try app.library(for: live.id)
        _ = try app.runner(for: live.id)
        try insertJob(library, .running)
        try insertJob(library, .queued)
        try insertJob(library, .succeeded)
        #expect(app.runningJobCount() == 1)

        // A crash leftover in a library with no runner this session.
        let other = try LibraryDatabase.open(at: URL(fileURLWithPath: idle.filePath))
        try insertJob(other, .running)
        try other.close()
        #expect(app.runningJobCount() == 1)
    }
}
