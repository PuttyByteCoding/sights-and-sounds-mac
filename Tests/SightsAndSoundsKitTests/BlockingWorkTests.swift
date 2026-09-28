import Foundation
import Testing

@testable import SightsAndSoundsKit

/// Blocking work — a tool run, a whole-file read — runs on a thread of
/// its own. On the cooperative pool it holds one of the few threads
/// every task in the app shares (one per core; three on CI) for as long
/// as the tool runs, and a handful of slow files stall everything else.
@Suite struct BlockingWorkTests {
    /// Where the work ran: the dispatch queue label of its thread. The
    /// cooperative pool's threads carry `…cooperative`. (A timing test
    /// here was flaky: the full suite crowds the pool the test's own
    /// tasks resume on.)
    @Test func blockingWorkNeverRunsOnTheCooperativePool() async throws {
        let label: String = try await Blocking.run { () -> String in
            String(cString: __dispatch_queue_get_label(nil))
        }
        #expect(!label.contains("cooperative"), "ran on \(label)")
    }

    @Test func itReturnsTheValueAndThrowsTheError() async throws {
        let answer: Int = try await Blocking.run { () -> Int in 21 * 2 }
        #expect(answer == 42)
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await Blocking.run { () throws -> Int in throw Boom() }
        }
    }
}
