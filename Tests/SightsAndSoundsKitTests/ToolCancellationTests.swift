import Foundation
import Testing
@testable import SightsAndSoundsKit

/// A job that runs a tool for an hour has to be stoppable, and a tool
/// that stops early — cancelled or failed — must not leave half a file
/// in the library for the next scan to import.
@Suite struct ToolCancellationTests {

    private func tool(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tool = dir.appendingPathComponent("tool")
        try "#!/bin/bash\n\(body)\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private func cleanUp(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingStopsTheToolInsteadOfWaitingItOut() async throws {
        let sleeper = try tool("sleep 600")
        defer { cleanUp(sleeper.deletingLastPathComponent()) }
        let started = ContinuousClock.now

        await #expect(throws: CancellationError.self) {
            _ = try await ProcessRunner.run(sleeper.path, [], isCancelled: { true })
        }

        #expect(started.duration(to: .now) < .seconds(20))
    }

    @Test(.timeLimit(.minutes(1)))
    func aToolThatIsNotCancelledRunsToItsEnd() async throws {
        let quick = try tool("echo done")
        defer { cleanUp(quick.deletingLastPathComponent()) }

        let output = try await ProcessRunner.run(quick.path, [], isCancelled: { false })

        #expect(output.status == 0)
        #expect(output.stdoutText == "done\n")
    }

    /// The stand-in writes half a file to its last argument, then fails —
    /// what an encode does when the disk fills or the input turns bad.
    @Test(.timeLimit(.minutes(1)))
    func aFailedToolLeavesNothingWhereItsOutputWasGoing() async throws {
        let failing = try tool(#"printf 'half a file' > "${@: -1}"; exit 1"#)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { cleanUp(failing.deletingLastPathComponent(), folder) }
        let output = folder.appendingPathComponent("show (h264).mp4")

        await #expect(throws: FfmpegTool.FfmpegError.self) {
            try await FfmpegTool.produce(
                output, arguments: ["-i", "in.mp4"], tool: failing.path,
                fileAccess: LiveFileAccess(), isCancelled: { false })
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFinishedToolsOutputArrivesWhole() async throws {
        let working = try tool(#"printf 'a whole file' > "${@: -1}""#)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { cleanUp(working.deletingLastPathComponent(), folder) }
        let output = folder.appendingPathComponent("show (h264).mp4")

        try await FfmpegTool.produce(
            output, arguments: ["-i", "in.mp4"], tool: working.path,
            fileAccess: LiveFileAccess(), isCancelled: { false })

        #expect(try String(contentsOf: output, encoding: .utf8) == "a whole file")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["show (h264).mp4"])
    }
}
