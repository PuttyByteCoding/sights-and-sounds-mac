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
        // Nor is a runner built for the one that is open: a runner can
        // start queued work, and looking is not asking for that.
        #expect(app.existingRunner(for: open.id) == nil)
        #expect(lanes.first { $0.id == open.id }?.isAnswering == true)
    }

    /// A lane's pause is its own queue's once it has one, and the app's
    /// switch until then — what the queue would start as.
    @Test func aLaneSaysItsOwnQueuesPause() async throws {
        let app = AppModel()
        let ref = try register(app, "Paused")
        app.refresh()
        _ = try app.library(for: ref.id)
        #expect(await BackgroundTasksView.lanes(of: app).first { $0.id == ref.id }?.isPaused == false)

        try await app.service(for: ref.id).setQueuePaused(true)
        let lane = try #require(await BackgroundTasksView.lanes(of: app).first { $0.id == ref.id })
        #expect(lane.isPaused)
        #expect(await app.existingRunner(for: ref.id)?.isPaused == true)
    }

    /// The lane's jobs are the library's, asked of its service, and what
    /// is done to one from the window is done to the library's queue.
    @Test func aLanesJobsAreSteeredThroughTheService() async throws {
        let app = AppModel()
        let ref = try register(app, "Steered")
        app.refresh()
        _ = try app.library(for: ref.id)
        let service = try app.service(for: ref.id)
        try await service.setQueuePaused(true)
        try await service.startSweep(.contentHash, after: .nothing)
        try await service.startSweep(.metadata, after: .nothing)

        let lane = try #require(await BackgroundTasksView.lanes(of: app).first { $0.id == ref.id })
        #expect(lane.queued == 2 && lane.running == nil)
        let job = try #require(lane.jobs.first)
        try await service.cancelJob(id: job.id)
        try await service.clearFinishedJobs()
        let after = try #require(await BackgroundTasksView.lanes(of: app).first { $0.id == ref.id })
        #expect(after.jobs.map(\.id) == lane.jobs.map(\.id).filter { $0 != job.id })
    }

    /// A sweep's row waits for its own jobs, asked of the service on a
    /// timer: it returns once none is pending, and not before.
    @Test(.timeLimit(.minutes(1)))
    func aSweepsRowWaitsForItsOwnJobs() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Sweeps")
        let runner = JobRunner(library: library, paused: true)
        let stub = StubLibraryService(LocalLibraryService(library: library, runner: runner))
        try await stub.startSweep(.duplicates, after: .nothing)

        let done = Flag()
        let wait = Task {
            try await SweepPanel.waitUntilNonePending(of: .duplicates, on: stub, every: .milliseconds(20))
            done.set()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!done.isSet, "the wait ended while the sweep was still queued")

        try await stub.setQueuePaused(false)
        try await wait.value
        #expect(done.isSet)
        // Both of the check's jobs were waited for, not just the first.
        #expect(stub.calls("jobQueue(kind:startingQueue:)") >= 3)
        let left = try await library.writer.read { db in
            try JobRecord.filter(sql: "state IN ('queued', 'running')").fetchCount(db)
        }
        #expect(left == 0)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
