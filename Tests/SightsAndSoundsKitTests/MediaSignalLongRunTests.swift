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

/// A value a test shares between a stage's closure and its expectations.
final class OSAllocatedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
}
