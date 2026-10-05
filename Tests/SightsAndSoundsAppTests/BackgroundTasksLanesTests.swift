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

    /// A Mac that is asleep takes ten seconds to be given up on, and
    /// every lane used to wait for it. Its lane says so when the time
    /// allowed is up and the others have theirs; and while its question
    /// is still unanswered it is not asked again beside itself.
    ///
    /// The slow library is held at a gate rather than given a delay, so
    /// nothing here depends on how fast the machine is: the reading
    /// returns while the gate is shut, which it could not if it waited.
    @Test(.timeLimit(.minutes(1)))
    func aLibrarySlowToAnswerDoesNotHoldTheOthers() async throws {
        func library(_ name: String) throws -> LocalLibraryService {
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: name)
            return LocalLibraryService(library: library)
        }
        let quickID = UUID(), slowID = UUID()
        let open = [
            AppModel.OpenLibrary(id: quickID, name: "Quick", service: try library("Quick"), isRemote: false),
            AppModel.OpenLibrary(id: slowID, name: "Slow — Another Mac", service: try library("Slow"), isRemote: true),
        ]
        let slow = open[1].service
        let gate = SlowLibrary(slow)
        defer { gate.open() }
        let asking: @Sendable (any LibraryService) async -> JobLane? = { service in
            if service as AnyObject === slow as AnyObject { await gate.hold() }
            return try? await service.jobLane(limit: 40)
        }

        // Long enough for the quick one however busy the machine is; the
        // slow one never answers, so this returns when the time is up.
        let first = await BackgroundTasksView.lanes(
            for: open, tasksPaused: true, answerWithin: .seconds(4), asking: asking)
        #expect(!gate.isOpen, "nothing was waited for: the gate was never opened")
        #expect(first.map(\.isAnswering) == [true, false])
        #expect(first[0].isPaused, "a library with no queue yet starts as the app's switch says")
        #expect(gate.arrivals == 1)

        // Asked again while the first question is still out: not a second one.
        let second = await BackgroundTasksView.lanes(
            for: open, tasksPaused: true, answerWithin: .milliseconds(100), asking: asking)
        #expect(second[1].isAnswering == false)
        #expect(gate.arrivals == 1, "the library was asked again beside its unanswered question")

        // Once it has answered, a later reading asks afresh and has it.
        gate.open()
        var third: [BackgroundTasksView.Lane] = []
        for _ in 0..<40 where third.last?.isAnswering != true {
            third = await BackgroundTasksView.lanes(
                for: open, tasksPaused: true, answerWithin: .seconds(4), asking: asking)
        }
        #expect(third.map(\.isAnswering) == [true, true])
        // That answer was the first question's, kept for whoever asked
        // next. With it used, the library is asked afresh.
        for _ in 0..<40 where gate.arrivals < 2 {
            _ = await BackgroundTasksView.lanes(
                for: open, tasksPaused: true, answerWithin: .seconds(4), asking: asking)
        }
        #expect(gate.arrivals >= 2, "an answered question was never asked again")
    }

    /// Holds whoever asks the slow library until the gate is opened.
    final class SlowLibrary: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var count = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []
        init(_ service: any LibraryService) {}
        var isOpen: Bool { lock.withLock { opened } }
        var arrivals: Int { lock.withLock { count } }
        func open() {
            let held = lock.withLock {
                opened = true
                defer { waiting = [] }
                return waiting
            }
            for one in held { one.resume() }
        }
        func hold() async {
            await withCheckedContinuation { (one: CheckedContinuation<Void, Never>) in
                let goNow = lock.withLock {
                    count += 1
                    if opened { return true }
                    waiting.append(one)
                    return false
                }
                if goNow { one.resume() }
            }
        }
    }

    /// Settings is pointed at any library on this Mac, open or shut.
    /// Choosing one opens it and nothing more: no runner is built,
    /// because nothing in Settings starts work.
    @Test func settingsAsksALibraryWithoutStartingItsQueue() async throws {
        let app = AppModel()
        let ref = try register(app, "Settings")
        app.refresh()
        #expect(app.librariesForSettings.contains(AppModel.SettingsLibrary(id: ref.id, name: "Settings")))
        #expect(app.openLibrary(for: ref.id) == nil)

        let service = try app.settingsService(for: ref.id)
        #expect(app.existingRunner(for: ref.id) == nil)
        try await service.setExtensionOverrides(video: ["mkv"], audio: nil)
        #expect(try await service.libraryInfo()?.videoExtensionsOverride == ["mkv"])
        #expect(try app.library(for: ref.id).info()?.videoExtensionsOverride == ["mkv"])
        let search = try await service.searchSettings()
        #expect(search.formats == .empty && search.sample == nil)
        #expect(app.existingRunner(for: ref.id) == nil)

        #expect(throws: (any Error).self) { _ = try app.settingsService(for: UUID()) }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
