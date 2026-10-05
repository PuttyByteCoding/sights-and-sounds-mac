import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The Organise window's plan, its moves and putting them back, as asked
/// of the library's service; and the job requests added for it and for
/// the Operations window.
@Suite struct OrganiseManagingTests {
    typealias Tag = SightsAndSoundsKit.Tag

    struct Fixture {
        let root: URL
        let library: LibraryDatabase
        let runner: JobRunner
        let service: LocalLibraryService
        let source: Source
        let a: MediaItem
        let b: MediaItem

        init(paused: Bool = false) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-organise-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["a.mp4", "b.mp4"] {
                try Data(name.utf8).write(to: root.appendingPathComponent(name))
            }
            library = try LibraryDatabase.openInMemory()
            runner = JobRunner(library: library, jobTypes: JobCatalog.all, paused: paused)
            service = LocalLibraryService(
                library: library, runner: runner, fileAccess: LiveFileAccess(discarding: .permanently))
            source = Source(name: "Here", rootPath: root.path)
            let band = TagCategory(name: "Band", sortOrder: 0)
            let alpha = Tag(tagCategoryID: band.id, name: "Alpha")
            a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4")
            b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4")
            try library.writer.write { [source, a, b] db in
                try source.insert(db)
                try band.insert(db)
                try alpha.insert(db)
                for row in [a, b] { try row.insert(db) }
            }
            try library.assignTag(alpha.id, to: [a.id])
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }

        func path(of item: MediaItem) throws -> String? {
            try library.writer.read { try MediaItem.fetchOne($0, key: item.id)?.relativePath }
        }
    }

    @Test func aPlanSaysWhereEachItemWouldGoOrWhyNot() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let plan = try await f.service.organisePlan(template: "%Band", itemIDs: [f.a.id, f.b.id])
        #expect(plan.map(\.itemID) == [f.a.id, f.b.id])
        #expect(plan[0].toFolder == "Alpha" && plan[0].reason == nil)
        #expect(plan[1].toFolder == nil, "an item with no band was given a folder")
        #expect(plan[1].reason != nil)
        #expect(plan.movableCount == 1)
        // Nothing moved for the asking.
        #expect(f.exists("a.mp4") && !f.exists("Alpha/a.mp4"))
        // And it crosses to another Mac as it is.
        #expect(try JSONDecoder().decode([ReorganizePlanEntry].self, from: JSONEncoder().encode(plan)) == plan)
    }

    @Test(.timeLimit(.minutes(1)))
    func movesAreMadeLoggedAndPutBackOneAtATime() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.moveSessions().isEmpty)

        let job = try #require(try await f.service.run(
            .reorganize(template: "%Band", itemIDs: [f.a.id, f.b.id]), wait: .settled))
        let settled = try #require(try await f.library.writer.read { try JobRecord.fetchOne($0, key: job.id) })
        #expect(settled.state == .succeeded, "\(settled.error ?? "")")
        #expect(f.exists("Alpha/a.mp4") && !f.exists("a.mp4"))
        #expect(try f.path(of: f.a) == "Alpha/a.mp4")
        #expect(f.exists("b.mp4"), "an item the template had no folder for was moved")

        let sessions = try await f.service.moveSessions()
        #expect(sessions.count == 1)
        let log = try #require(sessions.first?.logs.first)
        #expect(sessions.first?.logs.count == 1)
        #expect(log.mediaItemID == f.a.id)
        #expect(try JSONDecoder().decode(
            [LibraryDatabase.MoveSession].self, from: JSONEncoder().encode(sessions)) == sessions)

        try await f.service.revertMove(logID: log.id)
        #expect(f.exists("a.mp4") && !f.exists("Alpha/a.mp4"))
        #expect(try f.path(of: f.a) == "a.mp4")
        #expect(try await f.service.moveSessions().first?.revertibleCount == 0)
        // Put back once: a second time is refused.
        await #expect(throws: (any Error).self) { try await f.service.revertMove(logID: log.id) }
    }

    @Test(.timeLimit(.minutes(1)))
    func aWholeRunIsPutBack() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        _ = try await f.service.run(.reorganize(template: "%Band", itemIDs: [f.a.id]), wait: .settled)
        let session = try #require(try await f.service.moveSessions().first)

        let outcome = try await f.service.revertMoveSession(sessionID: session.id)
        #expect(outcome == MoveRevertOutcome(reverted: 1, failures: []))
        #expect(f.exists("a.mp4"))
        #expect(try f.path(of: f.a) == "a.mp4")
        // Nothing left to put back the second time.
        #expect(try await f.service.revertMoveSession(sessionID: session.id).reverted == 0)
    }

    /// The Operations window's two requests that the grid's own menu
    /// never made: text read with settings of its own, and a join of
    /// chosen files in a chosen order.
    @Test(.timeLimit(.minutes(1)))
    func theOperationsWindowsRequestsAreQueuedAsThoseJobs() async throws {
        let f = try Fixture(paused: true)
        defer { f.tearDown() }
        let text = try #require(try await f.service.run(
            .recogniseTextSampled(itemID: f.a.id, settings: OcrSettings(), sampleIntervalSeconds: 5), wait: .none))
        let join = try #require(try await f.service.run(
            .joinItems(sourceID: f.source.id, folderPath: "", itemIDs: [f.b.id, f.a.id]), wait: .none))
        let move = try #require(try await f.service.run(
            .reorganize(template: "%Band", itemIDs: [f.a.id]), wait: .none))
        #expect(text.kind == OcrJob.kind && join.kind == JoinJob.kind && move.kind == ReorganizeJob.kind)
        #expect(try await f.service.jobQueue(kind: ReorganizeJob.kind, startingQueue: true)
            == JobQueueState(pendingCount: 1, isPaused: true))
        #expect(try await f.service.jobQueue(kind: JoinJob.kind, startingQueue: false).pendingCount == 1)
        // Paused: none has run, and the files are where they were.
        #expect(f.exists("a.mp4") && f.exists("b.mp4"))
    }
}
