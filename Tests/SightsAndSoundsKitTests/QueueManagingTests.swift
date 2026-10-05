import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The library's queue, as Background Tasks asks about it and steers
/// it through the library's service.
@Suite struct QueueManagingTests {
    struct Fixture {
        let library: LibraryDatabase
        let runner: JobRunner
        let service: LocalLibraryService
        let item: MediaItem

        /// A paused queue holds what is queued, so it can be looked at.
        init(paused: Bool = true) async throws {
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Queue")
            let source = Source(name: "Here", rootPath: TestRoots.unreachable("queue"))
            let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
            try await library.writer.write { db in
                try source.insert(db)
                try item.insert(db)
            }
            self.library = library
            self.item = item
            runner = JobRunner(library: library, paused: paused)
            service = LocalLibraryService(library: library, runner: runner)
        }

        func kinds(_ state: JobState) throws -> [String] {
            try library.writer.read { db in
                try JobRecord.filter(sql: "state = ?", arguments: [state.rawValue]).fetchAll(db)
            }.map(\.kind).sorted()
        }
    }

    @Test func theLaneIsTheNewestJobsAndThePause() async throws {
        let f = try await Fixture()
        for kind in [SweepKind.contentHash, .metadata, .signal] {
            try await f.service.startSweep(kind, after: .nothing)
        }
        let lane = try await f.service.jobLane(limit: 2)
        #expect(lane.jobs.count == 2)
        #expect(lane.isPaused == true)
        #expect(try await f.service.jobLane(limit: 40).jobs.count == 3)

        try await f.service.setQueuePaused(false)
        #expect(try await f.service.jobLane(limit: 0) == JobLane(jobs: [], isPaused: false))

        // A service made without the runner has no queue to speak of.
        let jobless = LocalLibraryService(library: f.library)
        #expect(try await jobless.jobLane(limit: 40).isPaused == nil)
        await #expect(throws: ServiceError.noJobRunner) { try await jobless.setQueuePaused(true) }

        let sent = try JSONDecoder().decode(JobLane.self, from: JSONEncoder().encode(lane))
        #expect(sent.jobs.map(\.id) == lane.jobs.map(\.id) && sent.isPaused == lane.isPaused)
    }

    @Test func aJobIsMovedAheadRetriedAndCleared() async throws {
        let f = try await Fixture()
        try await f.service.startSweep(.contentHash, after: .nothing)
        try await f.service.startSweep(.metadata, after: .nothing)
        let last = try #require(try await f.service.jobLane(limit: 40).jobs.first { $0.kind == MetadataSweepJob.kind })
        try await f.service.moveJobToFront(id: last.id)
        let next = try await f.library.writer.read { db in
            try JobRecord.filter(sql: "state = 'queued'").order(sql: "priority DESC, createdAt, rowid").fetchOne(db)
        }
        #expect(next?.id == last.id, "the job moved ahead is not the next to run")

        // Cancelled is finished: retried it is queued again, cleared it is gone.
        try await f.service.cancelJob(id: last.id)
        #expect(try await f.service.job(id: last.id)?.state == .cancelled)
        try await f.service.retryJob(id: last.id)
        #expect(try f.kinds(.queued).contains(MetadataSweepJob.kind))
        try await f.service.cancelJob(id: last.id)
        let cancelledBefore = try f.kinds(.cancelled).count
        #expect(cancelledBefore >= 1)
        try await f.service.clearFinishedJobs()
        #expect(try f.kinds(.cancelled).isEmpty)
        #expect(try f.kinds(.queued).contains(ContentHashJob.kind), "a queued job was cleared with the finished")
    }

    @Test func eachSweepQueuesItsOwnJobsOnce() async throws {
        let f = try await Fixture()
        for kind in SweepKind.allCases {
            try await f.service.startSweep(kind, after: .nothing)
            try await f.service.startSweep(kind, after: .nothing)
        }
        #expect(try f.kinds(.queued) == SweepKind.allCases.flatMap(\.jobKinds).sorted())
        #expect(SweepKind.allCases.filter { !$0.canRetry } == [.duplicates])
        #expect(SweepKind.allCases.filter { !$0.canRecalculate } == [.duplicates])
    }

    @Test func theStatusesAreTheLibrarysOwnCounts() async throws {
        let f = try await Fixture()
        let statuses = try await f.service.sweepStatuses()
        #expect(statuses[.contentHash] == (try f.library.contentHashStatus()))
        #expect(statuses[.fingerprint] == (try f.library.fingerprintStatus()))
        #expect(statuses[.metadata] == (try f.library.metadataSweepStatus()))
        #expect(statuses[.signal] == (try f.library.signalStatus()))
        #expect(statuses[.thumbnails] != nil && statuses[.duplicates] == nil)
        #expect(statuses[.contentHash]?.missing == 1)

        let sent = try JSONDecoder().decode([SweepKind: SweepStatus].self, from: JSONEncoder().encode(statuses))
        #expect(sent == statuses)
    }

    /// Retry forgets what failed; recalculate forgets the data itself.
    @Test func aSweepForgetsWhatItIsToldToFirst() async throws {
        let f = try await Fixture()
        try await f.library.writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET contentHash = 'abc' WHERE id = ?", arguments: [f.item.id])
        }
        #expect(try await f.service.sweepStatuses()[.contentHash]?.missing == 0)
        try await f.service.startSweep(.contentHash, after: .forgetFailures)
        #expect(try await f.service.sweepStatuses()[.contentHash]?.missing == 0, "a retry forgot the data")
        try await f.service.startSweep(.contentHash, after: .forgetEverything)
        #expect(try await f.service.sweepStatuses()[.contentHash]?.missing == 1)
        // Nothing to forget for the duplicate check, whatever is asked.
        try await f.service.startSweep(.duplicates, after: .forgetEverything)
        #expect(try f.kinds(.queued).contains(HashDuplicateSweepJob.kind))
    }
}
