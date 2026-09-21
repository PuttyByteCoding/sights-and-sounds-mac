import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// A sweep that runs unattended for days meets every bad file a library
/// has. Each of these is a way one file, or one unplugged drive, could
/// cost the whole run.
@Suite struct MediaSignalLongRunTests {

    /// A stage that does whatever the test hands it.
    struct ScriptedStage: SignalStage {
        var name = "scripted"
        var version = 1
        var kinds: Set<MediaKind> = [.video]
        var pass = 0
        var body: @Sendable (SignalStageInput) async throws -> SignalFindings

        func examine(_ file: SignalStageInput) async throws -> SignalFindings { try await body(file) }
    }

    /// Reachable until told otherwise.
    final class Drive: FileAccess, @unchecked Sendable {
        private let lock = NSLock()
        private var online = true
        func unplug() { lock.withLock { online = false } }
        func isReachable(_ url: URL) -> Bool { lock.withLock { online } }
        func contentsOfDirectory(at url: URL) throws -> [URL] { [] }
        func allFiles(under url: URL) throws -> [URL] { [] }
        func fileSize(at url: URL) throws -> Int64 { 0 }
        func readFile(at url: URL, chunk: (Data) throws -> Void) throws {}
        func moveFile(at url: URL, to destination: URL) throws {}
        func removeFile(at url: URL) throws {}
    }

    private func library(items: Int = 1) async throws -> (LibraryDatabase, [MediaItem]) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "LongRun")
        let source = Source(name: "S", rootPath: TestRoots.unreachable("long-run"))
        let made = (0..<items).map {
            MediaItem(sourceID: source.id, kind: .video, relativePath: "clip\($0).mp4", needsReview: false)
        }
        try await library.writer.write { db in
            try source.insert(db)
            for item in made { try item.insert(db) }
        }
        return (library, made)
    }

    private func context(_ library: LibraryDatabase, cancelled: @escaping @Sendable () -> Bool = { false }) -> JobContext {
        JobContext(
            library: library, jobID: UUID(), progressHandler: { _, _ in },
            cancellationCheck: { cancelled() }, summaryHandler: { _ in })
    }

    @Test func aFileThatCrashesTheAppIsNotExaminedAgainOnRelaunch() async throws {
        let (library, items) = try await library()
        // What the database holds while the stage is running is what a
        // crash would leave behind.
        let during = OSAllocatedBox<[SignalStageState]>([])
        let stage = ScriptedStage { _ in
            during.set(try library.signalStageStates(itemID: items[0].id))
            return SignalFindings()
        }
        try await MediaSignalJob(stages: [stage], fileAccess: Drive()).run(context(library))

        let marker = try #require(during.get().first { $0.stage == "scripted" })
        #expect(marker.failureMessage?.contains("interrupted") == true)
        // A marker with a failure message is not missing work: the file
        // that killed the app is reported, not retried on every launch.
        #expect(try library.itemsNeedingSignalStages([stage]).isEmpty)
        // And once the stage does finish, the marker is the ordinary one.
        let after = try #require(try library.signalStageStates(itemID: items[0].id).first { $0.stage == "scripted" })
        #expect(after.failureMessage == nil)
    }

    @Test func stoppingTheSweepLeavesNoMarkerOnTheFileInFlight() async throws {
        let (library, items) = try await library()
        let stop = OSAllocatedBox(false)
        let stage = ScriptedStage { file in
            stop.set(true)
            try await file.checkCancellation()
            return SignalFindings()
        }
        await #expect(throws: CancellationError.self) {
            try await MediaSignalJob(stages: [stage], fileAccess: Drive())
                .run(context(library, cancelled: { stop.get() }))
        }
        #expect(try library.signalStageStates(itemID: items[0].id).isEmpty)
        #expect(try library.itemsNeedingSignalStages([stage]).count == 1)
    }

    @Test func aStageThatNeverReturnsIsGivenUpOnAndTheSweepGoesOn() async throws {
        let (library, items) = try await library(items: 2)
        let stage = ScriptedStage { file in
            if file.url.lastPathComponent == "clip0.mp4" {
                // A decoder blocked on a damaged file: nothing wakes it.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
            var findings = SignalFindings()
            findings.measure("timing.frameCount", 1)
            return findings
        }
        var job = MediaSignalJob(stages: [stage], fileAccess: Drive())
        job.stageTimeout = { _ in 0.3 }
        try await job.run(context(library))

        let stuck = try #require(try library.signalStageStates(itemID: items[0].id).first { $0.stage == "scripted" })
        #expect(stuck.failureMessage?.contains("gave up") == true)
        #expect(try library.signalMeasurements(itemID: items[1].id).count == 1)
    }

    @Test func aDriveUnpluggedMidRunStopsTheSweepInsteadOfFailingEveryFile() async throws {
        let (library, items) = try await library(items: 3)
        let drive = Drive()
        let stage = ScriptedStage { file in
            if file.url.lastPathComponent == "clip1.mp4" {
                drive.unplug()
                throw SignalStageError("AVFoundation cannot open this file")
            }
            return SignalFindings()
        }
        await #expect(throws: MediaSignalJob.SourceWentOffline.self) {
            try await MediaSignalJob(stages: [stage], fileAccess: drive).run(context(library))
        }
        // The first file is done; the one in flight and the one after it
        // carry no marker at all, so they are examined when the drive is back.
        #expect(try library.signalStageStates(itemID: items[0].id).contains { $0.stage == "scripted" })
        #expect(try library.signalStageStates(itemID: items[1].id).isEmpty)
        #expect(try library.signalStageStates(itemID: items[2].id).isEmpty)
    }

    @Test func aFileThatFailsOnADriveStillThereIsMarkedAsBefore() async throws {
        let (library, items) = try await library()
        let stage = ScriptedStage { _ in throw SignalStageError("not a movie") }
        try await MediaSignalJob(stages: [stage], fileAccess: Drive()).run(context(library))
        let state = try #require(try library.signalStageStates(itemID: items[0].id).first { $0.stage == "scripted" })
        #expect(state.failureMessage == "not a movie")
    }
}

/// The order the work is done in, and who it makes wait.
@Suite struct MediaSignalOrderTests {
    typealias ScriptedStage = MediaSignalLongRunTests.ScriptedStage

    private func library(items: Int) async throws -> (LibraryDatabase, [MediaItem]) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Order")
        let source = Source(name: "S", rootPath: TestRoots.unreachable("order"))
        let made = (0..<items).map {
            MediaItem(sourceID: source.id, kind: .video, relativePath: "clip\($0).mp4", needsReview: false)
        }
        try await library.writer.write { db in
            try source.insert(db)
            for item in made { try item.insert(db) }
        }
        return (library, made)
    }

    private func context(_ library: LibraryDatabase, summary: OSAllocatedBox<String> = .init("")) -> JobContext {
        JobContext(
            library: library, jobID: UUID(), progressHandler: { _, _ in },
            cancellationCheck: { false }, summaryHandler: { summary.set($0) })
    }

    private func stage(_ name: String, pass: Int, log: OSAllocatedBox<[String]>) -> ScriptedStage {
        var stage = ScriptedStage { file in
            log.set(log.get() + ["\(name) \(file.url.lastPathComponent)"])
            return SignalFindings()
        }
        stage.name = name
        stage.pass = pass
        return stage
    }

    @Test func theCheapStagesCoverTheWholeLibraryBeforeAnySlowOneStarts() async throws {
        let (library, _) = try await library(items: 3)
        let log = OSAllocatedBox<[String]>([])
        let stages: [any SignalStage] = [
            stage("declared", pass: 0, log: log), stage("timing", pass: 0, log: log),
            stage("sequences", pass: 2, log: log),
        ]
        try await MediaSignalJob(stages: stages, fileAccess: MediaSignalLongRunTests.Drive()).run(context(library))
        #expect(log.get() == [
            // One visit per file for everything cheap, so a file is not
            // opened twice where once would do...
            "declared clip0.mp4", "timing clip0.mp4", "declared clip1.mp4", "timing clip1.mp4",
            "declared clip2.mp4", "timing clip2.mp4",
            // ...and only then the slow pass.
            "sequences clip0.mp4", "sequences clip1.mp4", "sequences clip2.mp4",
        ])
        #expect(try library.itemsNeedingSignalStages(stages).isEmpty)
    }

    @Test func theSweepStepsAsideWhenAnotherJobIsWaitingAndQueuesItsOwnReturn() async throws {
        let (library, items) = try await library(items: 3)
        let log = OSAllocatedBox<[String]>([])
        var slow = stage("slow", pass: 1, log: log)
        let inner = slow.body
        slow.body = { file in
            // Somebody asks for a clip export while the first file is open.
            if file.url.lastPathComponent == "clip0.mp4" {
                try await library.writer.write { try JobRecord(kind: "clip.export").insert($0) }
            }
            return try await inner(file)
        }
        let summary = OSAllocatedBox("")
        let payload = try JSONEncoder().encode(MediaSignalJob.Payload(itemIDs: items.map(\.id)))
        var job = try MediaSignalJob(payload: payload)
        job.stages = [slow]
        job.fileAccess = MediaSignalLongRunTests.Drive()
        try await job.run(context(library, summary: summary))

        #expect(log.get() == ["slow clip0.mp4"])  // finished what it had open, then stopped
        let queued = try await library.writer.read { db in
            try JobRecord.filter(sql: "state = 'queued'").order(sql: "createdAt, rowid").fetchAll(db)
        }
        // The export first, then the sweep's return, carrying the same scope.
        #expect(queued.map(\.kind) == ["clip.export", MediaSignalJob.kind])
        #expect(queued.last?.payload == payload)
        #expect(summary.get().contains("stepped aside"))
        #expect(try library.itemsNeedingSignalStages([slow]).count == 2)
    }

    @Test func aScopedSweepDoesNotHandTheLaneBackToTheSweepItInterrupted() async throws {
        let (library, items) = try await library(items: 2)
        // The whole-library sweep's return is already waiting.
        try await library.writer.write { try JobRecord(kind: MediaSignalJob.kind).insert($0) }
        let log = OSAllocatedBox<[String]>([])
        var job = try MediaSignalJob(payload: JSONEncoder().encode(MediaSignalJob.Payload(itemIDs: items.map(\.id))))
        job.stages = [stage("slow", pass: 1, log: log)]
        job.fileAccess = MediaSignalLongRunTests.Drive()
        try await job.run(context(library))
        #expect(log.get().count == 2)  // ran to its end
        let queued = try await library.writer.read { try JobRecord.filter(sql: "state = 'queued'").fetchCount($0) }
        #expect(queued == 1)  // and queued nothing more
    }

    @Test func withNothingWaitingTheSweepRunsToTheEndAndQueuesNothing() async throws {
        let (library, _) = try await library(items: 2)
        let log = OSAllocatedBox<[String]>([])
        try await MediaSignalJob(stages: [stage("slow", pass: 1, log: log)], fileAccess: MediaSignalLongRunTests.Drive())
            .run(context(library))
        #expect(log.get().count == 2)
        let queued = try await library.writer.read { try JobRecord.filter(sql: "state = 'queued'").fetchCount($0) }
        #expect(queued == 0)
    }
}

/// A value a test shares between a stage's closure and its expectations.
final class OSAllocatedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
}
