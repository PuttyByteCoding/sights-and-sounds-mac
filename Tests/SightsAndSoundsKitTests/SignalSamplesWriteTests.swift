import Foundation
import Testing

@testable import SightsAndSoundsKit

/// Writing a sample ran ffmpeg through the blocking call: every encode of a
/// generation that takes minutes held a cooperative-pool thread on a
/// semaphore, and cancelling the generation stopped nothing until ffmpeg
/// exited on its own. It goes through the async, cancellable call now.
@Suite(.writesVideo) struct SignalSamplesWriteTests {
    @Test(.timeLimit(.minutes(1)))
    func cancellingAWriteStopsTheTool() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-sample-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Stands in for an encode that takes a while.
        let tool = dir.appendingPathComponent("slow-ffmpeg")
        // `exec`, so terminating it ends the sleep and not only a shell
        // whose child keeps the output open.
        try "#!/bin/sh\nexec sleep 10\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let sample = try #require(SignalSamples.all.first)

        let clock = ContinuousClock()
        let start = clock.now
        let writing = Task {
            try await SignalSamples.write(sample, into: dir.appendingPathComponent("out"), ffmpeg: tool.path)
        }
        try await Task.sleep(for: .milliseconds(300))
        writing.cancel()
        _ = try? await writing.value
        #expect(clock.now - start < .seconds(5), "the tool ran on after the write was cancelled")
    }
}
