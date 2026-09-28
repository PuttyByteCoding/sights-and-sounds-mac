import Foundation
import Testing

@testable import SightsAndSoundsKit

/// A decoder stuck inside a damaged file never returns, so a stage that
/// times out is left behind, still blocked. It must be left behind on a
/// thread of its own: on the shared pool, a few damaged files in one
/// sweep used up every thread, and after that every async task in the
/// app — database observation, the UI's tasks, the other job lanes —
/// waited for decoders that were never coming back.
@Suite(.serialized) struct SignalStageThreadTests {
    /// Blocks its thread for real, the way a stuck decode does.
    struct StuckStage: SignalStage {
        var name = "stuck"
        var version = 1
        var kinds: Set<MediaKind> = [.video]
        var pass = 0
        func examine(_ file: SignalStageInput) async throws -> SignalFindings {
            sleep(3)
            return SignalFindings()
        }
    }

    /// Forty stuck stages, each given 50 ms: all forty are given up on
    /// at once. On the pool, the stuck decodes held every thread — even
    /// the timers that give up on them could not run until a decode
    /// finished, so forty took a dozen seconds, in rounds.
    @Test func stuckStagesAreGivenUpOnWithoutStarvingThePool() async throws {
        let input = SignalStageInput(url: URL(fileURLWithPath: "/tmp/sas-stuck.mp4"), kind: .video)
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<40 {
                    group.addTask {
                        _ = try? await MediaSignalJob.examine(input, with: StuckStage(), givingUpAfter: 0.05)
                    }
                }
            }
        }
        #expect(elapsed < .seconds(1.5), "giving up took \(elapsed)")

        // Still stuck, all of them — and the pool answers at once.
        let answered = await clock.measure { _ = await Task.detached { 1 }.value }
        #expect(answered < .milliseconds(500), "a trivial task waited \(answered)")
    }
}
