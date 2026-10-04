import Foundation
import Testing

@testable import SightsAndSoundsApp

/// Writes to a library are requests that take their time, so a window
/// sends them one at a time in the order they were asked for, and the
/// app can wait for every one in flight before it quits.
@Suite(.serialized) @MainActor struct WriteQueueTests {
    /// What ran, in the order it ran.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.withLock { entries.append(entry) } }
        var all: [String] { lock.withLock { entries } }
    }

    struct Boom: Error {}

    @Test func writesRunInTheOrderTheyWereQueued() async {
        let queue = WriteQueue()
        let log = Log()
        // The first takes its time; the second, queued behind it, must
        // not overtake it.
        queue.send({
            try await Task.sleep(for: .milliseconds(200))
            log.add("first")
        })
        let second = await queue.run { log.add("second") }
        #expect((try? second.get()) != nil)
        #expect(log.all == ["first", "second"])
    }

    @Test func aWriteReturnsWhatItsWorkReturned() async {
        let queue = WriteQueue()
        let result = await queue.run { 7 }
        #expect((try? result.get()) == 7)
    }

    @Test func aFailedWriteDoesNotStopTheOnesAfterIt() async {
        let queue = WriteQueue()
        let failed: Result<Int, any Error> = await queue.run { throw Boom() }
        let after = await queue.run { 7 }
        #expect((try? failed.get()) == nil)
        #expect((try? after.get()) == 7)
    }

    @Test func settleAllWaitsForEveryQueue() async {
        let one = WriteQueue(), two = WriteQueue()
        let log = Log()
        one.send({
            try await Task.sleep(for: .milliseconds(150))
            log.add("one")
        })
        two.send({
            try await Task.sleep(for: .milliseconds(150))
            log.add("two")
        })
        await WriteQueue.settleAll()
        #expect(Set(log.all) == ["one", "two"])
    }

    /// A window that closes lets go of its queue; what it had already
    /// sent — where the video was stopped — still lands.
    @Test func aQueueLetGoOfStillFinishesWhatItWasSent() async {
        let log = Log()
        do {
            let queue = WriteQueue()
            queue.send({
                try await Task.sleep(for: .milliseconds(100))
                log.add("sent")
            })
        }
        await WriteQueue.settleAll()
        #expect(log.all == ["sent"])
    }

    @Test func aSentWriteThatFailsSaysSo() async {
        let queue = WriteQueue()
        var said: String?
        queue.send({ throw Boom() }, failed: { said = "\($0)" })
        await WriteQueue.settleAll()
        #expect(said?.contains("Boom") == true)
    }

    /// Something queued while the wait is under way is waited for too.
    @Test func settleAllWaitsForWritesQueuedWhileItWaits() async {
        let queue = WriteQueue()
        let log = Log()
        queue.send({
            try await Task.sleep(for: .milliseconds(100))
            log.add("first")
        })
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            queue.send({
                try await Task.sleep(for: .milliseconds(100))
                log.add("late")
            })
        }
        try? await Task.sleep(for: .milliseconds(50))
        await WriteQueue.settleAll()
        #expect(log.all == ["first", "late"])
    }

    @Test func settleAllReturnsAtOnceWithNothingInFlight() async {
        await WriteQueue.settleAll()
        #expect(WriteQueue.inFlightCount == 0)
    }

    /// A quit must not hang on a library that has stopped answering.
    @Test func aBoundedWaitGivesUp() async {
        let queue = WriteQueue()
        let log = Log()
        queue.send({
            try await Task.sleep(for: .milliseconds(600))
            log.add("slow")
        })
        let began = ContinuousClock.now
        await WriteQueue.settleAll(within: .milliseconds(80))
        #expect(ContinuousClock.now - began < .milliseconds(500))
        #expect(log.all.isEmpty)
        // And it is still waited for by a wait with no limit.
        await WriteQueue.settleAll()
        #expect(log.all == ["slow"])
    }

    @Test func aBoundedWaitReturnsAsSoonAsEverythingHasSettled() async {
        let queue = WriteQueue()
        queue.send({ try await Task.sleep(for: .milliseconds(60)) })
        let began = ContinuousClock.now
        await WriteQueue.settleAll(within: .seconds(5))
        #expect(ContinuousClock.now - began < .seconds(2))
    }
}
