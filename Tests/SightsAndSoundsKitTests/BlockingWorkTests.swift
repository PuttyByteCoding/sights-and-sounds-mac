import Foundation
import Testing

@testable import SightsAndSoundsKit

/// Blocking work — a tool run, a whole-file read — runs on a thread of
/// its own. On the cooperative pool it holds one of the few threads
/// every task in the app shares (one per core; three on CI) for as long
/// as the tool runs, and a handful of slow files stall everything else.
@Suite struct BlockingWorkTests {
    @Test func manyBlockingCallsDoNotQueueBehindThePool() async throws {
        let calls = 128
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<calls {
                    group.addTask {
                        try await Blocking.run { usleep(500_000) }
                    }
                }
                try await group.waitForAll()
            }
        }
        // On the pool, 128 half-second blocks take (128 / threads) × 0.5 s — at least 2 s on any Mac.
        #expect(elapsed < .seconds(1.5), "took \(elapsed)")
    }

    @Test func itReturnsTheValueAndThrowsTheError() async throws {
        #expect(try await Blocking.run { 21 * 2 } == 42)
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await Blocking.run { throw Boom() } }
    }
}
