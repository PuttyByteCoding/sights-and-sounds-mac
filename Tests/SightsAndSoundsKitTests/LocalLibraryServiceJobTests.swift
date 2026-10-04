import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The jobs a Browse window asks its library to run. A request names the
/// work; the service queues the job that does it on the library's one
/// runner, with the payload that job's own `enqueue` writes. Whether the
/// caller waits is the caller's business, said with the request.
@Suite struct LocalLibraryServiceJobTests {
    struct Fixture {
        let library: LibraryDatabase
        let runner: JobRunner
        let service: LocalLibraryService
        let source: Source
        let item: MediaItem

        /// A paused runner queues and runs nothing, so the queue can be
        /// looked at.
        init(paused: Bool = true) async throws {
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Jobs")
            let source = Source(name: "Here", rootPath: "/tmp/sas-service-jobs-\(UUID().uuidString)")
            let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "set/a.mp4", needsReview: false)
            try await library.writer.write { db in
                try source.insert(db)
                try item.insert(db)
            }
            self.library = library
            self.source = source
            self.item = item
            runner = JobRunner(library: library, paused: paused)
            service = LocalLibraryService(library: library, runner: runner)
        }

        func jobs(kind: String? = nil) throws -> [JobRecord] {
            try library.writer.read { db in
                try JobRecord.order(sql: "createdAt, rowid").fetchAll(db)
            }.filter { kind == nil || $0.kind == kind }
        }

        func job(_ id: UUID) throws -> JobRecord {
            try #require(try library.writer.read { try JobRecord.fetchOne($0, key: id) })
        }
    }

    private func object(_ payload: Data?) throws -> NSDictionary? {
        guard let payload else { return nil }
        return try JSONSerialization.jsonObject(with: payload) as? NSDictionary
    }

    /// Each request against the job's own `enqueue`, on a second library:
    /// the same kind and the same payload, defaults included.
    @Test func eachRequestQueuesTheJobItsOwnEnqueueWould() async throws {
        let f = try await Fixture()
        let other = try await Fixture()
        let snapshot = UUID()
        let direct: [(JobRequest, JobRecord)] = [
            // The library sweeps first: one asked for while a scoped sweep
            // of its kind is pending is folded into it, as it always was.
            (.validation, try await other.runner.enqueue(ValidationJob.self)),
            (.metadataSweep(itemIDs: nil), try await other.runner.enqueue(MetadataSweepJob.self)),
            (.recogniseText(itemID: f.item.id),
             try await OcrJob.enqueue(on: other.runner, itemID: f.item.id)),
            (.joinFolder(sourceID: f.source.id, folderPath: "set"),
             try await JoinJob.enqueue(on: other.runner, sourceID: f.source.id, folderPath: "set")),
            (.writeTags(itemIDs: [f.item.id], scope: "one item"),
             try await WritebackJob.enqueue(on: other.runner, itemIDs: [f.item.id], scopeDescription: "one item")),
            (.restoreSnapshot(snapshot),
             try await RestoreTagsJob.enqueue(on: other.runner, snapshotID: snapshot)),
            (.remux(itemID: f.item.id, mode: .optimize),
             try await RemuxJob.enqueue(on: other.runner, itemID: f.item.id, mode: .optimize)),
            (.encode(itemID: f.item.id, preset: EncodeJob.Preset.allCases[0]),
             try await EncodeJob.enqueue(on: other.runner, itemID: f.item.id, preset: EncodeJob.Preset.allCases[0])),
            (.exportClip(clipID: f.item.id),
             try await ClipExportJob.enqueue(on: other.runner, clipID: f.item.id)),
            (.removeBlocks(itemID: f.item.id),
             try await BlockRemovalJob.enqueue(on: other.runner, itemID: f.item.id)),
            (.metadataSweep(itemIDs: [f.item.id]),
             try await MetadataSweepJob.enqueue(on: other.runner, itemIDs: [f.item.id])),
            (.examine(itemIDs: [f.item.id]),
             try await MediaSignalJob.enqueue(on: other.runner, itemIDs: [f.item.id])),
        ]
        for (request, expected) in direct {
            let record = try #require(try await f.service.run(request, wait: .none), "\(request)")
            #expect(record.kind == expected.kind, "\(request)")
            #expect(try object(record.payload) == object(expected.payload), "\(request)")
            #expect(try f.job(record.id).state == .queued)
        }
        #expect(try f.jobs().count == direct.count)
    }

    /// A sweep of the whole library is a signal, not a command: asked
    /// for again while one is pending, nothing more is queued.
    @Test func aLibrarySweepIsQueuedOnceHoweverOftenAsked() async throws {
        let f = try await Fixture()
        for request in [JobRequest.validation, .metadataSweep(itemIDs: nil)] {
            #expect(try await f.service.run(request, wait: .none) != nil)
            #expect(try await f.service.run(request, wait: .none) == nil, "\(request) was queued twice")
        }
        #expect(try f.jobs(kind: ValidationJob.kind).count == 1)
        #expect(try f.jobs(kind: MetadataSweepJob.kind).count == 1)
    }

    /// A pending library sweep must not swallow the small one somebody
    /// is waiting on.
    @Test func aScopedSweepIsItsOwnJobWhileALibrarySweepIsPending() async throws {
        let f = try await Fixture()
        _ = try await f.service.run(.metadataSweep(itemIDs: nil), wait: .none)
        #expect(try await f.service.run(.metadataSweep(itemIDs: [f.item.id]), wait: .none) != nil)
        #expect(try f.jobs(kind: MetadataSweepJob.kind).count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func waitingReturnsOnceTheJobHasRun() async throws {
        let f = try await Fixture(paused: false)
        let record = try #require(try await f.service.run(.validation, wait: .settled))
        #expect(try f.job(record.id).state == .succeeded)
    }

    /// Somebody is waiting on it: next after the job running, not behind
    /// everything queued before it.
    @Test(.timeLimit(.minutes(1)))
    func aJobSomebodyWaitsOnGoesToTheFront() async throws {
        let f = try await Fixture()
        let earlier = try #require(try await f.service.run(.examine(itemIDs: [f.item.id]), wait: .none))
        let waiting = Task { try await f.service.run(.recogniseText(itemID: f.item.id), wait: .settled) }
        var waitedOn: JobRecord?
        for _ in 0..<800 where waitedOn == nil || waitedOn?.priority == 0 {
            try await Task.sleep(for: .milliseconds(10))
            waitedOn = try f.jobs(kind: OcrJob.kind).first
        }
        #expect((waitedOn?.priority ?? 0) > (try f.job(earlier.id).priority))
        waiting.cancel()
        _ = try? await waiting.value
    }

    @Test(.timeLimit(.minutes(1)))
    func waitingOnALibrarySweepAlreadyPendingWaitsForThatOne() async throws {
        let f = try await Fixture()
        let pending = try await f.runner.enqueue(ValidationJob.self)
        let waiting = Task { try await f.service.run(.validation, wait: .settled) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(try f.jobs(kind: ValidationJob.kind).count == 1)

        await f.runner.setPaused(false)
        await f.runner.startDraining()
        #expect(try await waiting.value == nil, "it queued a sweep of its own")
        #expect(try f.job(pending.id).state == .succeeded)
    }

    @Test func requestsSurviveEncodingAndDecoding() throws {
        let requests: [JobRequest] = [
            .recogniseText(itemID: UUID()), .joinFolder(sourceID: UUID(), folderPath: "set"),
            .writeTags(itemIDs: [UUID()], scope: "one"), .restoreSnapshot(UUID()),
            .remux(itemID: UUID(), mode: .optimize), .encode(itemID: UUID(), preset: EncodeJob.Preset.allCases[0]),
            .exportClip(clipID: UUID()), .removeBlocks(itemID: UUID()), .metadataSweep(itemIDs: nil),
            .metadataSweep(itemIDs: [UUID()]), .examine(itemIDs: [UUID()]), .validation,
        ]
        for request in requests {
            #expect(try JSONDecoder().decode(JobRequest.self, from: JSONEncoder().encode(request)) == request)
        }
        for wait in [JobWait.none, .settled] {
            #expect(try JSONDecoder().decode(JobWait.self, from: JSONEncoder().encode(wait)) == wait)
        }
    }
}
