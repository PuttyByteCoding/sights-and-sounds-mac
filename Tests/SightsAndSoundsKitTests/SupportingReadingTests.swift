import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The smaller reads around the grid and the player, and the two job
/// requests added with them, as asked of the library's service.
@Suite struct SupportingReadingTests {
    struct Fixture {
        let root: URL
        let library: LibraryDatabase
        let runner: JobRunner
        let service: LocalLibraryService
        let a: MediaItem
        let b: MediaItem
        let c: MediaItem

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-supporting-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["a.mp4", "b.mp4", "c.mp4"] {
                try Data(name.utf8).write(to: root.appendingPathComponent(name))
            }
            library = try LibraryDatabase.openInMemory()
            runner = JobRunner(library: library, jobTypes: JobCatalog.all)
            service = LocalLibraryService(library: library, runner: runner)
            let source = Source(name: "Here", rootPath: root.path)
            a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", durationSeconds: 600)
            b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", durationSeconds: 600)
            c = MediaItem(sourceID: source.id, kind: .video, relativePath: "c.mp4", durationSeconds: 600)
            try library.writer.write { [a, b, c] db in
                try source.insert(db)
                for row in [a, b, c] { try row.insert(db) }
            }
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func historyIsMostRecentFirstWithItsTrueSize() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.watchHistory(limit: 10) == WatchHistory(items: [], total: 0))

        try f.library.recordPlaybackStart(itemID: f.a.id, at: Date(timeIntervalSince1970: 100))
        try f.library.recordPlaybackStart(itemID: f.c.id, at: Date(timeIntervalSince1970: 300))
        try f.library.recordPlaybackStart(itemID: f.b.id, at: Date(timeIntervalSince1970: 200))
        let all = try await f.service.watchHistory(limit: 10)
        #expect(all.items.map(\.id) == [f.c.id, f.b.id, f.a.id])
        #expect(all.total == 3)
        // Cut to the limit, the size is still the whole history's.
        let two = try await f.service.watchHistory(limit: 2)
        #expect(two.items.map(\.id) == [f.c.id, f.b.id])
        #expect(two.total == 3)
    }

    @Test func anItemNotSweptHasNoSummary() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.signalSummary(itemID: f.a.id) == nil)
        #expect(try await f.service.signalSummary(itemID: UUID()) == nil)
    }

    /// A summary crosses to another Mac as it is.
    @Test func aSummarySurvivesBeingSent() throws {
        let summary = SignalSummary(
            origins: [SignalSummary.Line(
                category: "VHS-like", confidence: 0.82, isFact: false, evidence: ["Head-switching noise at the bottom edge."])],
            history: [SignalSummary.Line(
                category: "Re-encoded here", confidence: 1, isFact: true, evidence: ["This app wrote the file."])])
        let sent = try JSONDecoder().decode(SignalSummary.self, from: JSONEncoder().encode(summary))
        #expect(sent == summary)
        #expect(sent.origins.first?.phrase == "Probably VHS-like")
        #expect(sent.history.first?.phrase == "Re-encoded here")
    }

    @Test func whatWouldGoWithAVideoIsItsUnsavedSegments() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.unsavedSegments(itemIDs: [f.a.id, f.b.id]).isEmpty)
        #expect(try await f.service.unsavedSegments(itemIDs: []).isEmpty)

        let song = try f.library.createEmbeddedClip(
            parentID: f.a.id, name: "Song", startSeconds: 10, endSeconds: 20, role: .song)
        let found = try await f.service.unsavedSegments(itemIDs: [f.a.id, f.b.id])
        #expect(found == [LibraryDatabase.UnsavedSegments(
            parentID: f.a.id, parentFileName: "a.mp4", segmentIDs: [song.id])])
        // And it crosses to another Mac as it is.
        let sent = try JSONDecoder().decode(
            [LibraryDatabase.UnsavedSegments].self, from: JSONEncoder().encode(found))
        #expect(sent == found)
    }

    /// Taking items out of the library leaves their files where they are.
    @Test(.timeLimit(.minutes(1)))
    func itemsAreRemovedFromTheLibraryAndTheirFilesStay() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let job = try #require(try await f.service.run(
            .removeFromLibrary(itemIDs: [f.a.id, f.b.id], writeTagsFirst: false), wait: .settled))
        let settled = try #require(try await f.library.writer.read { try JobRecord.fetchOne($0, key: job.id) })
        #expect(settled.state == .succeeded, "\(settled.error ?? "")")
        let left = try await f.library.writer.read { try MediaItem.fetchAll($0).map(\.id) }
        #expect(left == [f.c.id])
        for name in ["a.mp4", "b.mp4", "c.mp4"] {
            #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(name).path), "\(name) went")
        }
    }

    /// Hurrying a job that is not waiting — done, or never there — is
    /// only a wait, and one that ends.
    @Test(.timeLimit(.minutes(1)))
    func hurryingAJobThatIsNotQueuedIsOnlyAWait() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try await f.service.runNextAndWait(jobID: UUID())
        let done = try #require(try await f.service.run(
            .removeFromLibrary(itemIDs: [f.c.id], writeTagsFirst: false), wait: .settled))
        try await f.service.runNextAndWait(jobID: done.id)

        // A service made without the library's runner cannot do either.
        let bare = LocalLibraryService(library: f.library)
        await #expect(throws: ServiceError.noJobRunner) { try await bare.runNextAndWait(jobID: UUID()) }
    }
}
