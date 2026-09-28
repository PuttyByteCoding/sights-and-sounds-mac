import Foundation
import Testing

@testable import SightsAndSoundsKit

/// A decoder stuck inside a damaged file never returns, so a stage that
/// times out is left behind, still blocked. It must be left behind on a
/// thread of its own: on the shared pool, a few damaged files in one
/// sweep used up every thread, and after that every async task in the
/// app waited for decoders that were never coming back — forty stuck
/// stages took twelve seconds just to be given up on, in rounds.
@Suite struct SignalStageThreadTests {
    /// Where a stage's work ran: the dispatch queue label of its thread.
    /// The cooperative pool's threads carry `…cooperative`.
    final class Where: @unchecked Sendable {
        private let lock = NSLock()
        private var labels: [String] = []
        func note() {
            let label = String(cString: __dispatch_queue_get_label(nil))
            lock.withLock { labels.append(label) }
        }
        var all: [String] { lock.withLock { labels } }
    }

    struct RecordingStage: SignalStage {
        var name = "recording"
        var version = 1
        var kinds: Set<MediaKind> = [.video]
        var pass = 0
        let seen: Where
        func examine(_ file: SignalStageInput) async throws -> SignalFindings {
            seen.note()
            await Task.yield()
            seen.note()  // and after a suspension, too
            return SignalFindings()
        }
    }

    struct StuckStage: SignalStage {
        var name = "stuck"
        var version = 1
        var kinds: Set<MediaKind> = [.video]
        var pass = 0
        func examine(_ file: SignalStageInput) async throws -> SignalFindings {
            sleep(10)
            return SignalFindings()
        }
    }

    private let input = SignalStageInput(url: URL(fileURLWithPath: "/tmp/sas-stage.mp4"), kind: .video)

    @Test func aStageNeverRunsOnTheCooperativePool() async throws {
        let seen = Where()
        _ = try await MediaSignalJob.examine(input, with: RecordingStage(seen: seen), givingUpAfter: 5)
        #expect(seen.all.count == 2)
        #expect(!seen.all.contains { $0.contains("cooperative") }, "ran on: \(seen.all)")
    }

    @Test func aStuckStageIsGivenUpOn() async throws {
        let clock = ContinuousClock()
        var gaveUp = false
        let elapsed = await clock.measure {
            do {
                _ = try await MediaSignalJob.examine(input, with: StuckStage(), givingUpAfter: 0.1)
            } catch is MediaSignalJob.StageGaveUp {
                gaveUp = true
            } catch {}
        }
        // Given up on, not waited out: the stage would have taken ten
        // seconds. Generous on time — a loaded machine runs timers late.
        #expect(gaveUp)
        #expect(elapsed < .seconds(8), "giving up took \(elapsed)")
    }
}
