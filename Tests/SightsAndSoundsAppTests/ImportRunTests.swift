import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Cancel stops the whole import. A per-folder import is one job per
/// folder; Cancel used to stop only the job in flight, and every later
/// folder was enqueued and imported anyway.
@Suite @MainActor struct ImportRunTests {
    @Test func cancelDuringTheFirstFolderImportsNoLaterFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["one/a.mp4", "two/b.mp4", "three/c.mp4"] {
            try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent(path), seconds: 1, variant: 0)
        }
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportRun")
        let source = Source(name: "Here", rootPath: root.path)
        try await library.writer.write { try source.insert($0) }
        let run = ImportRun(runner: JobRunner(library: library), library: library)

        var finished = false
        run.start(
            sourceID: source.id,
            groups: [.init(paths: ["one/a.mp4"]), .init(paths: ["two/b.mp4"]), .init(paths: ["three/c.mp4"])]
        ) { _ in finished = true }
        for _ in 0..<400 where run.running == nil { try await Task.sleep(for: .milliseconds(5)) }
        run.cancel()
        for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(25)) }

        #expect(finished)
        let imported = try await library.writer.read { try MediaItem.fetchAll($0).map(\.relativePath) }
        #expect(!imported.contains("two/b.mp4"))
        #expect(!imported.contains("three/c.mp4"))
    }

    /// Cancel pressed before the first job exists still stops the run —
    /// it used to do nothing until a job had been enqueued.
    @Test func cancelBeforeTheFirstJobStopsEverything() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportRunEarly")
        let source = Source(name: "Here", rootPath: "/tmp/sas-import-run-\(UUID().uuidString)")
        try await library.writer.write { try source.insert($0) }
        let run = ImportRun(runner: JobRunner(library: library), library: library)

        var finished = false
        run.start(sourceID: source.id, groups: [.init(paths: ["a.mp4"])]) { _ in finished = true }
        run.cancel()
        for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(25)) }

        let jobs = try await library.writer.read { try JobRecord.fetchCount($0) }
        #expect(jobs == 0)
    }

    /// "Run in background" leaves the Import window usable while the run
    /// goes on. Import stayed armed there — it only looked at the window's
    /// step — and a second click started a second run over the same files
    /// and orphaned the first one's Cancel. The run says whether it is
    /// still going.
    @Test func aRunSaysItIsRunningUntilItFinishes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-run-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 1, variant: 0)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "ImportRunLive")
        let source = Source(name: "Here", rootPath: root.path)
        try await library.writer.write { try source.insert($0) }
        let run = ImportRun(runner: JobRunner(library: library), library: library)
        #expect(!run.isRunning)

        var finished = false
        run.start(sourceID: source.id, groups: [.init(paths: ["a.mp4"])]) { _ in finished = true }
        #expect(run.isRunning)
        for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(25)) }

        #expect(finished)
        #expect(!run.isRunning)
    }
}

