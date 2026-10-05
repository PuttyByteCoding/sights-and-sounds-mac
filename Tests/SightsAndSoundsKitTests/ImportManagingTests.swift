import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// Import, as asked of a library's service: what is under a source's
/// folder, what the window keeps, and the import itself as a job whose
/// row can be read and which can be stopped.
@Suite struct ImportManagingTests {
    struct Fixture {
        let root: URL
        let library: LibraryDatabase
        let runner: JobRunner
        let service: LocalLibraryService
        let source: Source
        let away: Source

        /// Three files under a source, one of them already in the library.
        init(paused: Bool = false) async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-import-service-\(UUID().uuidString)", isDirectory: true)
            for path in ["set/a.mp4", "set/b.mp4", "other/c.m4a", "other/notes.xyz"] {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(path.utf8).write(to: url)
            }
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Import")
            let source = Source(name: "Here", rootPath: root.path)
            let away = Source(name: "Away", rootPath: root.path + "-away")
            let known = MediaItem(sourceID: source.id, kind: .video, relativePath: "set/a.mp4", needsReview: false)
            try await library.writer.write { db in
                for row in [source, away] { try row.insert(db) }
                try known.insert(db)
            }
            self.library = library
            self.source = source
            self.away = away
            runner = JobRunner(library: library, paused: paused)
            service = LocalLibraryService(library: library, runner: runner)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }

        func paths() throws -> [String] {
            try library.writer.read { try MediaItem.fetchAll($0) }.map(\.relativePath).sorted()
        }
    }

    @Test func aScanListsWhatIsThereAgainstWhatTheLibraryHas() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let outcome = try await f.service.scanSource(sourceID: f.source.id)
        #expect(outcome == (try await MediaScanner.scan(source: f.source, library: f.library))
            .with(scannedAt: outcome.scannedAt))
        #expect(outcome.candidates.map(\.relativePath).sorted() == ["other/c.m4a", "set/a.mp4", "set/b.mp4"])
        #expect(outcome.candidates.filter(\.isKnown).map(\.relativePath) == ["set/a.mp4"])
        #expect(outcome.skippedByExtension == ["xyz": 1])
        // Nothing is written by looking.
        #expect(try f.paths() == ["set/a.mp4"])

        // It survives being sent.
        let sent = try JSONDecoder().decode(ScanOutcome.self, from: JSONEncoder().encode(outcome))
        #expect(sent.candidates == outcome.candidates && sent.skippedByExtension == outcome.skippedByExtension)

        await #expect(throws: ServiceError.noSuchSource) {
            try await f.service.scanSource(sourceID: UUID())
        }
        await #expect(throws: (any Error).self) {
            try await f.service.scanSource(sourceID: f.away.id)
        }
    }

    @Test func theOverviewCountsEachSourceAndSaysWhichCanBeReached() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let overview = try await f.service.importOverview()
        #expect(overview.itemCounts == [f.source.id: 1])
        #expect(overview.online == [f.source.id: true, f.away.id: false])
        #expect(overview.history.isEmpty && !overview.hasOverride)
        #expect(overview.videoExtensions.contains("mp4") && overview.audioExtensions.contains("m4a"))
        #expect(!overview.videoExtensions.contains("xyz"))

        // An extension enabled here is this library's own, and video.
        try await f.service.enableExtension("xyz")
        let after = try await f.service.importOverview()
        #expect(after.hasOverride)
        #expect(after.videoExtensions == (overview.videoExtensions + ["xyz"]).sorted())
        #expect(after.audioExtensions == overview.audioExtensions)
        let rescanned = try await f.service.scanSource(sourceID: f.source.id)
        #expect(rescanned.candidates.contains { $0.relativePath == "other/notes.xyz" })

        let sent = try JSONDecoder().decode(ImportOverview.self, from: JSONEncoder().encode(after))
        #expect(sent == after)
    }

    @Test func theBoxesAreTheLibrarysToKeep() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.importBoxes().isEmpty)
        let boxes = [
            ImportBox(source: .category(UUID()), sticky: true, stickyTagIDs: [UUID()]),
            ImportBox(source: .itemField(UUID()), stickyValue: "1995"),
        ]
        try await f.service.setImportBoxes(boxes)
        #expect(try await f.service.importBoxes() == boxes)
        #expect(try f.library.importBoxes() == boxes)
    }

    /// A path can be spelled inside a source and lead out of it, through
    /// a link someone put there. A scan never lists such a file, so an
    /// import that names one — as another Mac could — leaves it out.
    @Test(.timeLimit(.minutes(1)))
    func aLinkOutOfTheSourceIsNotFollowed() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let outside = f.root.deletingLastPathComponent()
            .appendingPathComponent("sas-import-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appendingPathComponent("x.mp4"))
        try FileManager.default.createSymbolicLink(
            at: f.root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: f.root.appendingPathComponent("set/alias.mp4"),
            withDestinationURL: outside.appendingPathComponent("x.mp4"))

        #expect(MediaPath.isReallyInside(f.root, file: f.root.appendingPathComponent("set/b.mp4")))
        #expect(MediaPath.isReallyInside(f.root, file: f.root.appendingPathComponent("set/not-there.mp4")))
        #expect(!MediaPath.isReallyInside(f.root, file: f.root.appendingPathComponent("link/x.mp4")))
        #expect(!MediaPath.isReallyInside(f.root, file: f.root.appendingPathComponent("set/alias.mp4")))
        #expect(!MediaPath.isReallyInside(f.root, file: outside.appendingPathComponent("x.mp4")))
        // The file is there to be reached, were the link followed.
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("link/x.mp4").path))

        // The scan lists neither, and the import takes neither.
        let listed = try await f.service.scanSource(sourceID: f.source.id).candidates.map(\.relativePath)
        #expect(!listed.contains("link/x.mp4") && !listed.contains("set/alias.mp4"))
        _ = try await f.service.run(
            .importFiles(
                sourceID: f.source.id, relativePaths: ["link/x.mp4", "set/alias.mp4", "set/b.mp4"], staging: nil),
            wait: .settled)
        #expect(try f.paths() == ["set/a.mp4", "set/b.mp4"])
    }

    @Test func aFileThatCannotBeReadProbesEmpty() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        // The fixture's files are not media: there is nothing to measure.
        #expect(try await f.service.probeFile(sourceID: f.source.id, relativePath: "set/b.mp4") == ProbeResult())
        await #expect(throws: ServiceError.noSuchSource) {
            try await f.service.probeFile(sourceID: UUID(), relativePath: "set/b.mp4")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func anImportIsAJobWhoseRowSaysHowItWent() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let queued = try #require(
            try await f.service.run(
                .importFiles(sourceID: f.source.id, relativePaths: ["set/b.mp4", "other/c.m4a"], staging: nil),
                wait: .settled))
        let row = try #require(try await f.service.job(id: queued.id))
        #expect(row.kind == ImportJob.kind && row.state == .succeeded)
        #expect(try f.paths() == ["other/c.m4a", "set/a.mp4", "set/b.mp4"])
        #expect(try await f.service.importOverview().history.map(\.id) == [queued.id])
        #expect(try await f.service.job(id: UUID()) == nil)
    }

    /// Queued and not started: the caller may yet take it back, and
    /// starts the queue itself.
    @Test(.timeLimit(.minutes(1)))
    func aJobCanBeQueuedWithoutStartingTheQueue() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let request = JobRequest.importFiles(sourceID: f.source.id, relativePaths: ["set/b.mp4"], staging: nil)
        let held = try #require(try await f.service.run(request, wait: .queued))
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await f.service.job(id: held.id)?.state == .queued, "the queue was started for it")
        try await f.service.cancelJob(id: held.id)

        let wanted = try #require(try await f.service.run(request, wait: .queued))
        let state = try await f.service.jobQueue(kind: ImportJob.kind, startingQueue: true)
        #expect(state.pendingCount == 1)
        for _ in 0..<400 where try await f.service.job(id: wanted.id)?.state != .succeeded {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try await f.service.job(id: wanted.id)?.state == .succeeded)
        #expect(try f.paths() == ["set/a.mp4", "set/b.mp4"])
    }

    /// The signal an import ends with: each worker queued once, however
    /// often it is said, on the Mac that has the files.
    @Test func wakingTheWorkersQueuesEachOnce() async throws {
        let f = try await Fixture(paused: true)
        defer { f.tearDown() }
        try await f.service.wakeWorkers()
        try await f.service.wakeWorkers()
        let kinds = try await f.library.writer.read { try JobRecord.fetchAll($0) }.map(\.kind).sorted()
        #expect(kinds == [
            ContentHashJob.kind, FingerprintCaptureJob.kind, FingerprintMatchSweepJob.kind,
            HashDuplicateSweepJob.kind, ThumbnailBatchJob.kind,
        ].sorted())
        let jobless = LocalLibraryService(library: f.library)
        await #expect(throws: ServiceError.noJobRunner) { try await jobless.wakeWorkers() }
    }

    @Test(.timeLimit(.minutes(1)))
    func aQueuedImportThatIsCancelledImportsNothing() async throws {
        let f = try await Fixture(paused: true)
        defer { f.tearDown() }
        let queued = try #require(
            try await f.service.run(
                .importFiles(sourceID: f.source.id, relativePaths: ["set/b.mp4"], staging: nil), wait: .none))
        try await f.service.cancelJob(id: queued.id)
        #expect(try await f.service.job(id: queued.id)?.state == .cancelled)
        #expect(try f.paths() == ["set/a.mp4"])

        // A service made without the runner cannot stop anything, and says so.
        let jobless = LocalLibraryService(library: f.library)
        await #expect(throws: ServiceError.noJobRunner) {
            try await jobless.cancelJob(id: queued.id)
        }
    }
}

private extension ScanOutcome {
    func with(scannedAt: Date) -> ScanOutcome {
        var copy = self
        copy.scannedAt = scannedAt
        return copy
    }
}
