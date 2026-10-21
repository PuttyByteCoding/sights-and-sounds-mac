import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// A write-back run is the unit of undo. Nothing links a snapshot to its
/// run, so the run's pre-write snapshots are found by time, and a file
/// counts as restored once a pre-restore snapshot — which only a restore
/// takes — exists for it from after the run began.
@Suite struct TagWriteRunRevertTests {
    struct Fixture {
        let root: URL
        let library: LibraryDatabase
        let service: LocalLibraryService
        let a: MediaItem
        let b: MediaItem

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-run-revert-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = try LibraryDatabase.open(at: root.appendingPathComponent("Runs.sqlite"))
            try library.ensureInfo(name: "Runs")
            service = LocalLibraryService(library: library, fileAccess: LiveFileAccess(discarding: .permanently))
            let source = Source(name: "Here", rootPath: root.path)
            a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", fileSize: 10)
            b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", fileSize: 20)
            try library.writer.write { [a, b] db in
                try source.insert(db)
                try a.insert(db)
                try b.insert(db)
            }
        }

        func tearDown() {
            try? library.close()
            try? FileManager.default.removeItem(at: root)
        }

        /// A finished run that wrote these items, each with its pre-write
        /// snapshot taken while the run ran. Timestamps are whole seconds
        /// so the database's millisecond precision cannot reorder them.
        @discardableResult
        func run(writing items: [MediaItem], startedAt: Date, failing: [MediaItem] = []) throws -> (TagWriteRun, [UUID]) {
            var run = TagWriteRun(startedAt: startedAt, scopeDescription: "test", totalFiles: items.count + failing.count)
            run.finishedAt = startedAt.addingTimeInterval(10)
            run.writtenCount = items.count
            run.failedCount = failing.count
            var snapshotIDs: [UUID] = []
            try library.writer.write { [run] db in
                try run.insert(db)
                for (index, item) in items.enumerated() {
                    let snapshot = EmbeddedTagSnapshot(
                        mediaItemID: item.id, capturedAt: startedAt.addingTimeInterval(Double(index + 1)),
                        source: .preWrite, tagsJSON: "{}")
                    try snapshot.insert(db)
                    snapshotIDs.append(snapshot.id)
                    try TagWriteRunFile(
                        tagWriteRunID: run.id, mediaItemID: item.id, filePath: item.relativePath,
                        status: .written).insert(db)
                }
                for item in failing {
                    try TagWriteRunFile(
                        tagWriteRunID: run.id, mediaItemID: item.id, filePath: item.relativePath,
                        status: .failed, error: "refused").insert(db)
                }
            }
            return (run, snapshotIDs)
        }

        func snapshot(_ item: MediaItem, _ source: SnapshotSource, at date: Date) throws {
            try library.writer.write { db in
                try EmbeddedTagSnapshot(mediaItemID: item.id, capturedAt: date, source: source, tagsJSON: "{}").insert(db)
            }
        }

        func reverts() async throws -> [TagWriteRunRevert] {
            try #require(try await service.maintenanceSnapshot(includingBackups: false).runReverts)
        }
    }

    private let noon = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func aRunKnowsItsOwnPreWriteSnapshotsAndNotAnotherRuns() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        // An earlier run over the same files, with its own snapshots.
        try f.run(writing: [f.a, f.b], startedAt: noon.addingTimeInterval(-3_600))
        let (run, mine) = try f.run(writing: [f.a, f.b], startedAt: noon, failing: [])
        let reverts = try await f.reverts()
        let revert = try #require(reverts.first { $0.runID == run.id })
        #expect(Set(revert.snapshotIDs) == Set(mine), "picked up another run's snapshots, or missed its own")
        #expect(revert.restoredCount == 0)
        #expect(revert.state == .applied)
        #expect(reverts.count == 2, "one answer per run shown")
    }

    /// A file that failed has no snapshot to put back — only written files
    /// are offered.
    @Test func onlyWrittenFilesAreRestorable() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let (run, mine) = try f.run(writing: [f.a], startedAt: noon, failing: [f.b])
        let revert = try #require(try await f.reverts().first { $0.runID == run.id })
        #expect(revert.snapshotIDs == mine)
        #expect(revert.snapshotIDs.count == 1)
    }

    /// A restore takes a pre-restore snapshot; one per file after the run
    /// began is what "reverted" means — and half of them is "partly".
    @Test func restoresAfterTheRunMarkItRevertedFileByFile() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let (run, _) = try f.run(writing: [f.a, f.b], startedAt: noon)
        // A restore from BEFORE this run is not this run's.
        try f.snapshot(f.a, .preRestore, at: noon.addingTimeInterval(-60))
        #expect(try await f.reverts().first { $0.runID == run.id }?.state == .applied)

        try f.snapshot(f.a, .preRestore, at: noon.addingTimeInterval(120))
        let half = try #require(try await f.reverts().first { $0.runID == run.id })
        #expect(half.restoredCount == 1)
        #expect(half.state == .partlyReverted)

        try f.snapshot(f.b, .preRestore, at: noon.addingTimeInterval(180))
        let whole = try #require(try await f.reverts().first { $0.runID == run.id })
        #expect(whole.restoredCount == 2)
        #expect(whole.state == .reverted)
    }

    /// The answer crosses to another Mac as it is; a Mac that does not
    /// give one leaves the field nil rather than failing the snapshot.
    @Test func theRevertsCrossToAnotherMacAndAnOlderMacLeavesThemOut() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.run(writing: [f.a], startedAt: noon)
        let snapshot = try await f.service.maintenanceSnapshot(includingBackups: false)
        let sent = try JSONDecoder().decode(MaintenanceSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(sent == snapshot)
        #expect(sent.runReverts?.count == 1)

        let older = MaintenanceSnapshot(findings: [], backups: nil, runs: [], stagedCount: 0, reclaimableBytes: 0)
        let decoded = try JSONDecoder().decode(MaintenanceSnapshot.self, from: JSONEncoder().encode(older))
        #expect(decoded.runReverts == nil)
    }
}
