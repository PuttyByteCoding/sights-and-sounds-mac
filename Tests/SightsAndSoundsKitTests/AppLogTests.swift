import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The unified log: levels, the ring cap, categories, and the job
/// runner's lifecycle adoption.
@Suite(.serialized) struct AppLogTests {

    @Test func levelsOrderAndRingCap() {
        let log = AppLog()
        log.debug("t", "d")
        log.info("t", "i")
        log.warning("t", "w")
        log.error("t", "e")
        let snapshot = log.snapshot()
        #expect(snapshot.map(\.level) == [.debug, .info, .warning, .error])
        #expect(LogLevel.debug < .info && LogLevel.warning < .error)

        for index in 0..<(AppLog.capacity + 50) {
            log.info("bulk", "entry \(index)")
        }
        let capped = log.snapshot()
        #expect(capped.count == AppLog.capacity)
        // Oldest entries fell off; the newest survived.
        #expect(capped.last?.message == "entry \(AppLog.capacity + 49)")
        #expect(!capped.contains { $0.message == "d" })
    }

    @Test func categoriesAreDistinctAndSorted() {
        let log = AppLog()
        log.info("zeta", "1")
        log.info("alpha", "2")
        log.info("zeta", "3")
        #expect(log.categories() == ["alpha", "zeta"])
    }

    @Test func jobLifecycleIsLogged() async throws {
        struct NoteJob: Job {
            static let kind = "test.note"
            init(payload: Data?) throws {}
            func run(_ context: JobContext) async throws {
                await context.setSummary("did the thing")
            }
        }
        AppLog.shared.clear()
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library)
        await runner.register(NoteJob.self)
        _ = try await runner.enqueue(NoteJob.self)
        try await runner.runPending()

        let jobLines = AppLog.shared.snapshot().filter { $0.category == "jobs" }
        #expect(jobLines.contains { $0.message.contains("test.note: started") })
        #expect(jobLines.contains { $0.message.contains("succeeded — did the thing") })
    }

    @Test func failuresLogAtErrorLevel() async throws {
        struct SadJob: Job {
            static let kind = "test.sad"
            init(payload: Data?) throws {}
            struct Nope: Error, CustomStringConvertible { var description: String { "nope" } }
            func run(_ context: JobContext) async throws { throw Nope() }
        }
        AppLog.shared.clear()
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library)
        await runner.register(SadJob.self)
        _ = try await runner.enqueue(SadJob.self)
        try await runner.runPending()

        let failure = AppLog.shared.snapshot().first {
            $0.category == "jobs" && $0.level == .error
        }
        #expect(failure?.message.contains("nope") == true)
    }
}
